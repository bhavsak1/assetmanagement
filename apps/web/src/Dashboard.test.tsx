// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { tenantToday } from './Coverage'
import { DashboardPage, locationBars } from './Dashboard'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: [] as { fn: string; args: Record<string, unknown> }[],
}))

// Same chain mock as Maintenance.test; rpc results by name, bucket or coverage.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args: Record<string, unknown> = {}) => {
    db.rpc.push({ fn, args })
    const r = db.results[`${fn}:${String(args.p_bucket ?? args.p_coverage ?? '')}`] ?? db.results[fn]
    return Promise.resolve(r ?? { data: [], error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
const d = t.dashboard
const today = tenantToday('UTC')
const open = (n: number, state: string) => ({
  id: `o${n}`, asset_id: `a${n}`, name: `Service ${n}`, obligation_type: 'service', interval_count: 1, interval_unit: 'year', anchor: 'completion',
  next_due_date: today, last_done_date: null, due_state: state, tag: `AST-${n}`, asset_name: `Lathe ${n}`, location_id: 'l2', category_id: 'c1',
  in_service_date: null, purchase_date: null, purchase_value: null, purchase_currency: null,
})
const locs = [
  { id: 'l1', parent_id: null, name: 'Pune' },
  { id: 'l2', parent_id: 'l1', name: 'Plant 1' },
  { id: 'l3', parent_id: 'l1', name: 'Warehouse' },
  { id: 'l4', parent_id: 'l2', name: 'Bay A' },
]

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.rpc = []
  db.results = {
    tenant: { data: [{ time_zone: 'UTC', date_format: 'YYYY-MM-DD', locale: 'en-IN', currency_code: 'INR', coverage_expiring_days: 45 }], error: null },
    location: { data: locs, error: null },
    'count_assets:': { data: 12000, error: null },
    'count_assets:expiring': { data: 17, error: null },
    maintenance_counts: { data: [{ overdue: 9, due_soon: 14, scheduled: 300, completed: 3, next_7: 4, next_30: 42 }], error: null },
    location_asset_counts: { data: [{ location_id: 'l4', assets: 5, overdue: 2 }, { location_id: 'l3', assets: 2, overdue: 0 }, { location_id: null, assets: 1, overdue: 0 }], error: null },
  }
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(perms: string[]) {
  const can = (dm: string, o: string) => perms.includes(`${dm}.${o}`)
  await act(async () =>
    root.render(
      <MemoryRouter>
        <DashboardPage tenantId="t1" can={can} />
      </MemoryRouter>,
    ),
  )
}
const all = ['asset_core.view', 'obligation.view', 'obligation.complete', 'coverage_contract.view']
const tiles = () => [...container.querySelectorAll<HTMLAnchorElement>('a.kpi')].map((a) => [a.getAttribute('aria-label'), a.getAttribute('href')])
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text) as HTMLButtonElement

test('tiles: values, the 10,000+ cap, links with filters, the tenant expiring days', async () => {
  await render(all)
  expect(tiles()).toEqual([
    ['Total assets: 10,000+', '/assets'],
    ['Due in 30 days: 42', '/maintenance?tab=due_soon'],
    ['Overdue service: 9', '/maintenance?tab=overdue'],
    ['Coverage expiring (45d): 17', '/assets?coverage=expiring'],
  ])
  expect(db.rpc.filter((r) => r.fn === 'count_assets').map((r) => r.args)).toEqual([{}, { p_coverage: 'expiring' }])
})

test('tiles and cards hidden without their domains', async () => {
  await render(['asset_core.view'])
  expect(tiles().map(([l]) => l)).toEqual(['Total assets: 10,000+'])
  expect(container.textContent).not.toContain(d.upcoming)
  expect(container.textContent).toContain(d.byLocation)
  expect(db.rpc.map((r) => r.fn)).not.toContain('maintenance_counts')
  act(() => root.unmount())
  root = createRoot(container)
  db.rpc = []
  await render(['obligation.view', 'coverage_contract.view'])
  expect(tiles()).toEqual([])
  expect(container.textContent).not.toContain(d.byLocation)
  expect(db.rpc).toEqual([])
})

test('upcoming: overdue, then due soon, then scheduled, five at most; Record completion refreshes it', async () => {
  db.results['list_obligations:overdue'] = { data: [open(1, 'overdue'), open(2, 'overdue')], error: null }
  db.results['list_obligations:due_soon'] = { data: [open(3, 'due_soon')], error: null }
  db.results['list_obligations:scheduled'] = { data: [4, 5, 6, 7, 8].map((n) => open(n, 'scheduled')), error: null }
  db.results.complete_obligation = { data: 'r9', error: null }
  await render(all)
  expect(db.rpc.filter((r) => r.fn === 'list_obligations').map((r) => r.args)).toEqual(
    ['overdue', 'due_soon', 'scheduled'].map((b) => ({ p_bucket: b, p_limit: 5 })),
  )
  const rows = [...container.querySelectorAll('tbody tr')]
  expect(rows.map((r) => r.querySelector('a')?.textContent)).toEqual(['Lathe 1', 'Lathe 2', 'Lathe 3', 'Lathe 4', 'Lathe 5'])
  expect(rows[2]?.textContent).toContain('Plant 1 · Pune')
  expect(rows[2]?.querySelector('.tag')?.textContent).toBe('Due soon')
  const lists = db.rpc.filter((r) => r.fn === 'list_obligations').length
  await act(async () => button(t.obligations.recordCompletion).click())
  await act(async () => container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  expect(db.rpc.filter((r) => r.fn === 'complete_obligation').at(-1)?.args).toEqual(expect.objectContaining({ p_obligation_id: 'o1' }))
  expect(container.querySelector('form')).toBeNull()
  expect(db.rpc.filter((r) => r.fn === 'list_obligations').length).toBe(lists + 3)
})

test('empty states', async () => {
  db.results.location_asset_counts = { data: [], error: null }
  await render(all)
  expect(container.textContent).toContain(d.noUpcoming)
  expect(container.textContent).toContain(d.noAssets)
  expect(container.querySelector('.actions')).toBeNull()
})

test('by location: a lone root steps down to its children; counts roll up; links to the Assets filter', async () => {
  await render(all)
  const items = [...container.querySelectorAll('.bars li')]
  expect(items.map((li) => li.textContent)).toEqual(['Plant 1 · Pune5 · 2 overdue', 'Warehouse · Pune2', `${d.noLocation}1`])
  expect(items[0]?.querySelector('a')?.getAttribute('href')).toBe('/assets?location_id=l2')
  expect(items[2]?.querySelector('a')).toBeNull()
  expect((items[1]?.querySelector('.bar i') as HTMLElement).style.width).toBe('40%')
})

test('locationBars: a root with its own assets stays; several roots show as they are', () => {
  expect(locationBars(locs, [{ location_id: 'l1', assets: 1, overdue: 0 }, { location_id: 'l4', assets: 3, overdue: 1 }])).toEqual([{ id: 'l1', name: 'Pune', assets: 4, overdue: 1 }])
  const two = [...locs, { id: 'm1', parent_id: null, name: 'Mumbai' }]
  expect(locationBars(two, [{ location_id: 'm1', assets: 2, overdue: 0 }, { location_id: 'l3', assets: 2, overdue: 0 }]).map((b) => b.name)).toEqual(['Mumbai', 'Pune'])
})
