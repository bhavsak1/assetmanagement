// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { initials, readCollapsed, SEARCH_HITS, TopSearch, writeCollapsed } from './TopBar'

const db = vi.hoisted(() => ({ calls: [] as Record<string, unknown>[], rows: [] as unknown[] }))
vi.mock('./supabase', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      db.calls.push({ fn, ...args })
      return Promise.resolve({ data: db.rows, error: null })
    },
  },
}))

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  vi.useFakeTimers()
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.calls = []
  db.rows = [
    { id: 'a1', tag: 'PNE-0412', name: 'CNC Lathe 04', status: 'active', status_id: null },
    { id: 'a2', tag: 'PNE-0413', name: 'CNC Lathe 05', status: 'under_maintenance', status_id: null },
  ]
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
  vi.useRealTimers()
})

function Where() {
  const l = useLocation()
  return <output>{l.pathname + l.search}</output>
}

function render() {
  act(() =>
    root.render(
      <MemoryRouter initialEntries={['/dashboard']}>
        <TopSearch />
        <Routes>
          <Route path="*" element={<Where />} />
        </Routes>
      </MemoryRouter>,
    ),
  )
}

const input = () => container.querySelector<HTMLInputElement>('[role=combobox]')!
const where = () => container.querySelector('output')?.textContent
const options = () => [...container.querySelectorAll('[role=option]')].map((o) => o.textContent)

// React tracks the input value; set it the way a keystroke would.
function type(text: string) {
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!
  act(() => {
    input().focus()
    set.call(input(), text)
    input().dispatchEvent(new Event('input', { bubbles: true }))
  })
}
const key = (k: string) => act(() => input().dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })))
const settle = () => act(async () => vi.advanceTimersByTimeAsync(300))

test('initials: first and last name, one word, email fallback', () => {
  expect(initials('Krunal Bhavsar', 'k@x.in')).toBe('KB')
  expect(initials('  asha rao kulkarni ', null)).toBe('AK')
  expect(initials('Ravi', null)).toBe('RA')
  expect(initials('', 'priya.shah@example.com')).toBe('PS')
  expect(initials(null, null)).toBe('?')
  expect(initials('Élodie Ñúñez', null)).toBe('ÉÑ')
})

test('collapse choice: per user, and storage that throws is ignored', () => {
  localStorage.clear()
  writeCollapsed('u1', true)
  expect(readCollapsed('u1')).toBe(true)
  expect(readCollapsed('u2')).toBe(false)
  const get = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
    throw new Error('blocked')
  })
  const set = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
    throw new Error('blocked')
  })
  expect(readCollapsed('u1')).toBe(false)
  expect(() => writeCollapsed('u1', false)).not.toThrow()
  get.mockRestore()
  set.mockRestore()
})

test('search waits for 2 characters, asks list_assets for 6 as the user, and lists tag, name and status', async () => {
  render()
  type('P')
  await settle()
  expect(db.calls).toEqual([])
  expect(container.querySelector('[role=listbox]')).toBeNull()
  type('  PNE ')
  await settle()
  expect(db.calls).toEqual([{ fn: 'list_assets', p_term: 'PNE', p_limit: SEARCH_HITS }])
  expect(input().getAttribute('aria-expanded')).toBe('true')
  expect(options()).toEqual([
    `PNE-0412 CNC Lathe 04 ${t.assets.statuses.active}`,
    `PNE-0413 CNC Lathe 05 ${t.assets.statuses.under_maintenance}`,
    t.topbar.searchAll.replace('{q}', 'PNE'),
  ])
})

test('search input is cut to 100 characters before it is sent', async () => {
  render()
  type('x'.repeat(150))
  await settle()
  expect(db.calls[0]?.p_term).toBe('x'.repeat(100))
})

test('no match says so', async () => {
  db.rows = []
  render()
  type('zz')
  await settle()
  expect(container.querySelector('[role=listbox]')?.textContent).toContain(t.topbar.searchNone)
})

test('Enter with no row picked opens the Assets list filtered by the text', async () => {
  render()
  type('Lathe & co')
  await settle()
  key('Enter')
  expect(where()).toBe('/assets?q=Lathe%20%26%20co')
  expect(container.querySelector('[role=listbox]')).toBeNull()
})

test('arrow keys pick a row and Enter opens that asset; Esc closes the list', async () => {
  render()
  type('PNE')
  await settle()
  key('ArrowDown')
  key('ArrowDown')
  expect(input().getAttribute('aria-activedescendant')).toBe(container.querySelectorAll('[role=option]')[1]?.id)
  key('Escape')
  expect(container.querySelector('[role=listbox]')).toBeNull()
  key('ArrowDown')
  key('Enter')
  expect(where()).toBe('/assets/a1')
})

test('a click on a row opens it', async () => {
  render()
  type('PNE')
  await settle()
  act(() => container.querySelectorAll<HTMLLIElement>('[role=option]')[1]!.click())
  expect(where()).toBe('/assets/a2')
})
