// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { LocationsPage, moveTargets } from './Locations'
import { t } from './i18n'
import { buildTree } from './tree'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
}))

// Same mock as Categories.test: awaiting the chain gives the table's result; writes use '<table>:write'.
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
  return { supabase: { from: chain } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const loc = (id: string, name: string, parent_id: string | null = null, active = true) => ({
  id,
  name,
  parent_id,
  active,
  code: null,
  location_type: null,
})
// Pune > Plant 1 > Line A, Pune > Warehouse, Nashik (inactive)
const rows = [loc('p1', 'Plant 1', 'pune'), loc('la', 'Line A', 'p1'), loc('pune', 'Pune'), loc('wh', 'Warehouse', 'pune'), loc('nsk', 'Nashik', null, false)]

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = { location: { data: rows, error: null } }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

test('the tree builds from flat location rows', () => {
  expect(buildTree(rows).map(({ row, depth }) => `${depth}:${row.name}`)).toEqual(['0:Nashik', '0:Pune', '1:Plant 1', '2:Line A', '1:Warehouse'])
})

test('the move picker leaves out the location, its descendants, and inactive parents', () => {
  const names = (id: string) => moveTargets(rows, rows.find((r) => r.id === id)!).map(({ row }) => row.name)
  expect(names('p1')).toEqual(['Pune', 'Warehouse'])
  expect(names('pune')).toEqual([])
  // An inactive location may sit under an inactive one.
  expect(names('nsk')).toEqual(['Pune', 'Plant 1', 'Line A', 'Warehouse'])
})

async function render(canManage: boolean) {
  await act(async () => root.render(<LocationsPage tenantId="ta" canManage={canManage} />))
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)

test('only the top level shows until a node is expanded', async () => {
  await render(false)
  expect(container.textContent).toContain('Pune')
  expect(container.textContent).not.toContain('Plant 1')
  await act(async () => container.querySelector<HTMLButtonElement>(`[aria-label="${t.locations.expand.replace('{name}', 'Pune')}"]`)!.click())
  expect(container.textContent).toContain('Plant 1')
  expect(container.textContent).not.toContain('Line A')
})

test('without manage: no add, edit or move actions', async () => {
  await render(false)
  expect(button(t.locations.addLocation)).toBeUndefined()
  expect(button(t.locations.editLocation)).toBeUndefined()
  expect(button(t.locations.move)).toBeUndefined()
})

test('a write the database refuses shows the permission message', async () => {
  db.results['location:write'] = { data: null, error: { code: '42501', message: 'new row violates row-level security policy' } }
  await render(true)
  await act(async () => button(t.locations.addLocation)!.click())
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Mumbai'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.locations.errors.noPermission)
})

test('a cycle the database refuses shows its own message', async () => {
  db.results['location:write'] = { data: null, error: { code: '23514', message: 'a location cannot move under itself or its own descendant' } }
  await render(true)
  await act(async () => button(t.locations.move)!.click())
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.locations.errors.cycle)
})
