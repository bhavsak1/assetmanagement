// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetsPage, listArgs, nextCursor, savedFilters, viewFilters, type Filters } from './Assets'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  writes: [] as unknown[],
  rpc: [] as { fn: string; args: Record<string, unknown> }[],
}))

// Same chain mock as Categories.test; writes record their payload. rpc records name and arguments.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    for (const m of ['insert', 'update'])
      q[m] = (v: unknown) => {
        key = `${table}:write`
        db.writes.push(v)
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args: Record<string, unknown>) => {
    db.rpc.push({ fn, args })
    return Promise.resolve(db.results[fn] ?? { data: [], error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const none: Filters = { q: '', status: '', category_id: '', location_id: '' }
const categories = [{ id: 'c1', parent_id: null, name: 'Machines' }]
const locations = [
  { id: 'l1', parent_id: null, name: 'Pune' },
  { id: 'l2', parent_id: 'l1', name: 'Plant 1' },
]
const asset = (n: number) => ({
  id: `id${n}`,
  tag: `AST-${String(n).padStart(5, '0')}`,
  name: `Asset ${String(n).padStart(3, '0')}`,
  category_id: 'c1',
  location_id: 'l2',
  status: n === 1 ? 'in_stock' : 'active',
  updated_at: `2026-10-22T06:00:${String(n % 60).padStart(2, '0')}+00:00`,
})

test('filters become list_assets arguments; empty ones are left out', () => {
  expect(listArgs(none, 'name')).toEqual({ p_sort: 'name', p_limit: 51 })
  expect(listArgs({ q: ' pump ', status: 'in_stock', category_id: 'c1', location_id: 'l1' }, 'tag', { value: 'AST-1', id: 'x' })).toEqual({
    p_term: 'pump',
    p_status: 'in_stock',
    p_category_id: 'c1',
    p_location_id: 'l1',
    p_sort: 'tag',
    p_after_value: 'AST-1',
    p_after_id: 'x',
    p_limit: 51,
  })
})

test('the next-page cursor is the sort value and id of the 50th row, only when a 51st exists', () => {
  const page = Array.from({ length: 51 }, (_, i) => asset(i + 1)) as never[]
  expect(nextCursor(page, 'name')).toEqual({ value: 'Asset 050', id: 'id50' })
  expect(nextCursor(page, 'tag')).toEqual({ value: 'AST-00050', id: 'id50' })
  expect(nextCursor(page, 'updated')).toEqual({ value: '2026-10-22T06:00:50+00:00', id: 'id50' })
  expect(nextCursor(page.slice(0, 50), 'name')).toBeUndefined()
})

test('a saved view round trip keeps its filters and drops what no longer exists', () => {
  const f: Filters = { q: ' pump ', status: 'in_stock', category_id: 'c1', location_id: 'l2' }
  const saved = savedFilters(f)
  expect(saved).toEqual({ q: 'pump', status: 'in_stock', category_id: 'c1', location_id: 'l2' })
  expect(viewFilters(saved, categories, locations)).toEqual({ ...f, q: 'pump' })
  expect(savedFilters(none)).toEqual({})
  expect(viewFilters({ category_id: 'gone', status: 'lost', extra: 1 }, categories, locations)).toEqual(none)
})

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.writes = []
  db.rpc = []
  db.results = {
    asset_category: { data: categories, error: null },
    location: { data: locations, error: null },
    list_assets: { data: Array.from({ length: 51 }, (_, i) => asset(i + 1)), error: null },
    count_assets: { data: 1284, error: null },
    saved_view: { data: [{ id: 'v1', name: 'Spares', filters: { status: 'in_stock', location_id: 'l1' }, sort: 'tag' }], error: null },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
  vi.restoreAllMocks()
})

async function render(canSaveViews = true, canCreate = false, canEdit = false) {
  await act(async () =>
    root.render(
      <MemoryRouter>
        <AssetsPage tenantId="ta" canSaveViews={canSaveViews} canCreate={canCreate} canEdit={canEdit} />
      </MemoryRouter>,
    ),
  )
}
const lastList = () => db.rpc.filter((c) => c.fn === 'list_assets').at(-1)?.args
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)!
const select = (label: string) => container.querySelector<HTMLSelectElement>(`select[aria-label="${label}"]`)!
async function choose(label: string, value: string) {
  const s = select(label)
  s.value = value
  await act(async () => s.dispatchEvent(new Event('change', { bubbles: true })))
}

test('the list shows rows, status tags, place and count; Next and Previous page by cursor', async () => {
  await render()
  expect(container.textContent).toContain('1,284 assets')
  expect(container.querySelectorAll('tbody tr')).toHaveLength(50)
  expect(container.querySelector('.tag.status.neutral')?.textContent).toBe(t.assets.statuses.in_stock)
  expect(container.textContent).toContain('Plant 1 · Pune')
  expect(container.textContent).toContain('Showing 1–50 of 1,284')
  await act(async () => button(t.assets.next).click())
  expect(lastList()).toMatchObject({ p_after_value: 'Asset 050', p_after_id: 'id50' })
  expect(container.textContent).toContain('Showing 51–100 of 1,284')
  await act(async () => button(t.assets.previous).click())
  expect(lastList()).not.toHaveProperty('p_after_id')
})

test('a filter change goes back to the first page', async () => {
  await render()
  await act(async () => button(t.assets.next).click())
  await choose(t.assets.status, 'in_stock')
  expect(lastList()).toEqual({ p_status: 'in_stock', p_sort: 'name', p_limit: 51 })
})

test('typed search and a filter picked before the pause both apply', async () => {
  await render()
  const box = container.querySelector<HTMLInputElement>('input[type="search"]')!
  // React tracks the input value; set it through the native setter so onChange sees the change.
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(box, 'pump')
  await act(async () => box.dispatchEvent(new Event('input', { bubbles: true })))
  await choose(t.assets.status, 'in_stock')
  await act(async () => new Promise((r) => setTimeout(r, 350)))
  expect(lastList()).toEqual({ p_term: 'pump', p_status: 'in_stock', p_sort: 'name', p_limit: 51 })
})

test('empty list shows the empty state', async () => {
  db.results.list_assets = { data: [], error: null }
  db.results.count_assets = { data: 0, error: null }
  await render()
  expect(container.textContent).toContain(t.assets.none)
  expect(button(t.assets.next).disabled).toBe(true)
})

test('saved views: open applies filters and sort, save stores them, delete soft deletes', async () => {
  await render()
  await choose(t.assets.views.label, 'v1')
  expect(lastList()).toEqual({ p_status: 'in_stock', p_location_id: 'l1', p_sort: 'tag', p_limit: 51 })

  vi.spyOn(window, 'prompt').mockReturnValue('  My spares ')
  db.results['saved_view:write'] = { data: [{ id: 'v2' }], error: null }
  await act(async () => button(t.assets.views.save).click())
  expect(db.writes.at(-1)).toEqual({
    tenant_id: 'ta',
    entity: 'asset',
    name: 'My spares',
    filters: { status: 'in_stock', location_id: 'l1' },
    sort: 'tag',
  })

  await choose(t.assets.views.label, 'v1')
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  await act(async () => button(t.assets.views.delete).click())
  expect(db.writes.at(-1)).toHaveProperty('deleted_at')
})

test('without write access there is no Save view button', async () => {
  await render(false)
  expect([...container.querySelectorAll('button')].map((b) => b.textContent)).not.toContain(t.assets.views.save)
})

test('Add asset shows only with asset_core.create; rows link to edit only with update', async () => {
  await render()
  expect(container.textContent).not.toContain(t.assets.add)
  expect(container.querySelector('tbody a')?.getAttribute('href')).toBe('/assets/id1')
  act(() => root.unmount())
  root = createRoot(container)
  await render(true, true, true)
  expect(container.querySelector('a.btn-main')?.getAttribute('href')).toBe('/assets/new')
  expect(container.querySelector('tbody a')?.getAttribute('href')).toBe('/assets/id1/edit')
})