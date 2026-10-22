// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { CategoriesPage, inheritedCode, parseOptions, validateField } from './Categories'
import { t } from './i18n'
import { buildTree } from './tree'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  writes: [] as unknown[],
}))

// Every query builder call returns the same chain; awaiting it gives the table's mocked result.
// Writes (insert, update) switch the chain to '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    for (const m of ['insert', 'update'])
      q[m] = (v: unknown) => {
        db.writes.push(v)
        key = `${table}:write`
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  return { supabase: { from: chain, rpc: () => chain('rpc') } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = {
    asset_category: {
      data: [
        { id: 'c1', parent_id: null, name: 'Pumps', code: 'PMP', is_active: true },
        { id: 'c2', parent_id: 'c1', name: 'Booster pumps', code: null, is_active: true },
      ],
      error: null,
    },
    rpc: { data: [{ id: 'd1', code: 'asset_core' }], error: null },
  }
  db.writes = []
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const cat = (id: string, name: string, parent_id: string | null = null, code: string | null = null) => ({ id, name, parent_id, code, is_active: true })

test('the tree builds from flat rows: parents before children, by name, orphans at the top', () => {
  const rows = [cat('b', 'Lathes', 'm'), cat('m', 'Machine tools'), cat('a', 'CNC machines', 'm'), cat('u', 'Utilities'), cat('o', 'Orphan', 'gone')]
  expect(buildTree(rows).map(({ row, depth }) => `${depth}:${row.name}`)).toEqual([
    '0:Machine tools',
    '1:CNC machines',
    '1:Lathes',
    '0:Orphan',
    '0:Utilities',
  ])
})

test('the field form validates key and type', () => {
  const ok = { key: 'rated_kw', label: 'Rated power', type: 'number', options: [], domainId: 'd1' }
  expect(validateField(ok)).toBeUndefined()
  expect(validateField({ ...ok, key: 'Rated kW' })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, key: '1st' })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, key: 'a'.repeat(64) })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, type: 'money' })).toBe(t.categories.errors.type)
  expect(validateField({ ...ok, type: 'list' })).toBe(t.categories.errors.optionsRequired)
  expect(validateField({ ...ok, domainId: '' })).toBe(t.categories.errors.domain)
})

test('list options parse, and a removed option stays as inactive', () => {
  const existing = [{ code: 'oil', label: 'Oil', is_active: true }, { code: 'gas', label: 'Gas', is_active: true }]
  expect(parseOptions('oil = Mineral oil\nwater', existing)).toEqual([
    { code: 'oil', label: 'Mineral oil', is_active: true },
    { code: 'water', label: 'water', is_active: true },
    { code: 'gas', label: 'Gas', is_active: false },
  ])
})

async function render(canManage: boolean) {
  await act(async () => root.render(<CategoriesPage tenantId="ta" canManage={canManage} />))
}
const buttons = () => [...container.querySelectorAll('button')].map((b) => b.textContent)

test('without manage: no add or edit actions', async () => {
  await render(false)
  expect(container.textContent).toContain('Pumps')
  expect(buttons()).not.toContain(t.categories.addCategory)
  expect(buttons()).not.toContain(t.categories.addField)
  expect(buttons()).not.toContain(t.categories.editCategory)
})

test('a write the database refuses shows the permission message', async () => {
  db.results['asset_category:write'] = { data: null, error: { code: '42501', message: 'new row violates row-level security policy' } }
  await render(true)
  const add = [...container.querySelectorAll('button')].find((b) => b.textContent === t.categories.addCategory)!
  await act(async () => add.click())
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.noPermission)
})

test('a duplicate name shows its own message', async () => {
  db.results['asset_category:write'] = { data: null, error: { code: '23505' } }
  await render(true)
  await act(async () => [...container.querySelectorAll('button')].find((b) => b.textContent === t.categories.editCategory)!.click())
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.duplicateName)
})

const click = (text: string) => act(async () => [...container.querySelectorAll('button')].find((b) => b.textContent === text)!.click())
function type(el: HTMLInputElement | HTMLSelectElement, value: string) {
  const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype
  Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(el, value)
  el.dispatchEvent(new Event(el instanceof HTMLSelectElement ? 'change' : 'input', { bubbles: true }))
}
const codeInput = () => container.querySelector<HTMLInputElement>('[name="code"]')!
const codeHint = () => container.querySelector('#code-hint')!.textContent

test('inheritedCode finds the nearest ancestor with a code', () => {
  const rows = [cat('m', 'Machines', null, 'MC'), cat('c', 'CNC', 'm'), cat('l', 'Lathes', 'c', 'LT')]
  expect(inheritedCode(rows, 'c')?.code).toBe('MC')
  expect(inheritedCode(rows, 'l')?.code).toBe('LT')
  expect(inheritedCode(rows, '')).toBeUndefined()
  expect(inheritedCode([cat('x', 'X')], 'x')).toBeUndefined()
})

test('category code: a bad code is refused before the write', async () => {
  await render(true)
  await click(t.categories.addCategory)
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => type(codeInput(), 'C N C'))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.code)
  expect(db.writes).toEqual([])
})

test('category code: saved as typed, and a duplicate shows its own message', async () => {
  db.results['asset_category:write'] = {
    data: null,
    error: { code: '23505', message: 'duplicate key value violates unique constraint "asset_category_code_uq"' },
  }
  await render(true)
  await click(t.categories.addCategory)
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => type(codeInput(), ' cnc '))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.writes).toEqual([{ name: 'Compressors', parent_id: null, code: 'cnc', is_active: true, tenant_id: 'ta' }])
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.duplicateCode)
})

test('category code: with none of its own, the hint shows the code {CAT} inherits', async () => {
  await render(true)
  await click('Booster pumps')
  await click(t.categories.editCategory)
  const inherits = t.categories.codeInherited.replace('{code}', 'PMP').replace('{name}', 'Pumps')
  expect(codeHint()).toContain(inherits)
  await act(async () => type(codeInput(), 'BP'))
  expect(codeHint()).not.toContain(inherits)
  await act(async () => type(codeInput(), ''))
  await act(async () => type(container.querySelector<HTMLSelectElement>('[name="parent"]')!, ''))
  expect(codeHint()).not.toContain(inherits)
})
