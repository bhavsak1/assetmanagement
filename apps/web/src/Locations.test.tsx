// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { LocationsPage, moveTargets, rollUp } from './Locations'
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
  const rpc = (fn: string) => Promise.resolve(db.results[fn] ?? { data: [], error: null })
  return { supabase: { from: chain, rpc } }
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

async function render(canManage: boolean, perms: string[] = []) {
  const can = (d: string, o: string) => perms.includes(`${d}.${o}`)
  await act(async () =>
    root.render(
      <MemoryRouter>
        <LocationsPage tenantId="ta" canManage={canManage} can={can} />
      </MemoryRouter>,
    ),
  )
}

const count = (location_id: string | null, s: Partial<Record<string, number>>) => ({
  location_id, in_stock: 0, active: 0, under_maintenance: 0, inactive: 0, disposed: 0, overdue: 0, ...s,
})
// Line A: 2 active, 1 overdue; Plant 1: 1 disposed; Warehouse: 12,000 in stock; one asset with no location.
const counts = [count('la', { active: 2, overdue: 1 }), count('p1', { disposed: 1 }), count('wh', { in_stock: 12000 }), count(null, { active: 1 })]

test('counts roll up to every ancestor; no location is left out', () => {
  const sums = rollUp(rows, counts)
  expect(sums.get('la')).toMatchObject({ active: 2, overdue: 1, total: 2 })
  expect(sums.get('p1')).toMatchObject({ active: 2, disposed: 1, overdue: 1, total: 3 })
  expect(sums.get('pune')).toMatchObject({ active: 2, disposed: 1, in_stock: 12000, overdue: 1, total: 12003 })
  expect(sums.get('nsk')).toBeUndefined()
})

test('the selected node shows status tiles with links, and each row its total', async () => {
  db.results.location_status_counts = { data: counts, error: null }
  await render(false, ['asset_core.view', 'obligation.view'])
  const tiles = [...container.querySelectorAll<HTMLAnchorElement>('a.kpi')]
  // Nashik is first in tree order and holds nothing: zero tiles still show.
  expect(tiles.map((a) => a.textContent)).toEqual([
    `${t.assets.statuses.in_stock}0`, `${t.assets.statuses.active}0`, `${t.assets.statuses.under_maintenance}0`,
    `${t.assets.statuses.inactive}0`, `${t.assets.statuses.disposed}0`, `${t.locations.counts.overdue}0`,
  ])
  await act(async () => [...container.querySelectorAll('button')].find((b) => b.textContent?.startsWith('Pune'))!.click())
  const pune = [...container.querySelectorAll<HTMLAnchorElement>('a.kpi')]
  expect(pune.map((a) => a.querySelector('b')!.textContent)).toEqual([t.assets.manyCount, '2', '0', '0', '1', '1'])
  expect(pune[1]!.getAttribute('href')).toBe('/assets?location_id=pune&status=active')
  expect(pune[5]!.getAttribute('href')).toBe('/maintenance?tab=overdue&location_id=pune')
  expect([...container.querySelectorAll('.node-count')].map((n) => n.textContent)).toEqual(['0', t.assets.manyCount])
})

test('without obligation.view: no overdue tile; without asset_core.view: no counts at all', async () => {
  db.results.location_status_counts = { data: counts, error: null }
  await render(false, ['asset_core.view'])
  expect(container.querySelectorAll('a.kpi')).toHaveLength(5)
  act(() => root.unmount())
  root = createRoot(container)
  await render(false)
  expect(container.querySelectorAll('a.kpi, .node-count')).toHaveLength(0)
})
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
