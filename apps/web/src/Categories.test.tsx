// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { CategoriesPage, parseOptions, validateField } from './Categories'
import { t } from './i18n'
import { buildTree } from './tree'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
}))

// Every query builder call returns the same chain; awaiting it gives the table's mocked result.
// Writes (insert, update) switch the chain to '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    for (const m of ['insert', 'update'])
      q[m] = () => {
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
    asset_category: { data: [{ id: 'c1', parent_id: null, name: 'Pumps', is_active: true }], error: null },
    rpc: { data: [{ id: 'd1', code: 'asset_core' }], error: null },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const cat = (id: string, name: string, parent_id: string | null = null) => ({ id, name, parent_id, is_active: true })

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
