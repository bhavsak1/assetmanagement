// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { tenantToday } from './Coverage'
import { t } from './i18n'
import { ageText, dueText, filterArgs, MaintenancePage, nextCursor, pageArgs, type Filters } from './Maintenance'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: [] as { fn: string; args: Record<string, unknown> }[],
}))

// Same chain mock as Assets.test; rpc records name and arguments.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args: Record<string, unknown>) => {
    db.rpc.push({ fn, args })
    const r = db.results[`${fn}:${String(args.p_bucket ?? '')}`] ?? db.results[fn]
    return Promise.resolve(r ?? { data: [], error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
const m = t.maintenance
const none: Filters = { q: '', category_id: '', location_id: '', type: '', vendor_id: '', coverage: '' }
const today = tenantToday('UTC')
const day = (n: number) => new Date(Date.parse(today) + n * 86400000).toISOString().slice(0, 10)
const open = (n: number, due = day(-3)) => ({
  id: `o${n}`, asset_id: `a${n}`, name: `Service ${n}`, obligation_type: 'service', interval_count: 3, interval_unit: 'month', anchor: 'completion',
  next_due_date: due, last_done_date: null, due_state: 'overdue', tag: `AST-${n}`, asset_name: `Lathe ${n}`, location_id: 'l2', category_id: 'c1',
  in_service_date: '2020-01-15', purchase_date: null, purchase_value: null, purchase_currency: null,
})

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.rpc = []
  db.results = {
    tenant: { data: [{ time_zone: 'UTC', date_format: 'YYYY-MM-DD', locale: 'en-IN', currency_code: 'INR' }], error: null },
    location: { data: [{ id: 'l1', parent_id: null, name: 'Pune' }, { id: 'l2', parent_id: 'l1', name: 'Plant 1' }], error: null },
    asset_category: { data: [{ id: 'c1', parent_id: null, name: 'Machines' }], error: null },
    maintenance_counts: { data: [{ overdue: 9, due_soon: 14, scheduled: 12000, completed: 3, next_7: 4, next_30: 20 }], error: null },
    count_assets: { data: 23, error: null },
  }
  try {
    localStorage.clear()
  } catch {
    // ignore
  }
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(perms: string[], url = '/maintenance') {
  const can = (d: string, o: string) => perms.includes(`${d}.${o}`)
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={[url]}>
        <MaintenancePage tenantId="t1" can={can} />
      </MemoryRouter>,
    ),
  )
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent?.startsWith(text)) as HTMLButtonElement
const heads = () => [...container.querySelectorAll('th')].map((h) => h.textContent)
const lastRpc = (fn: string) => db.rpc.filter((r) => r.fn === fn).at(-1)?.args
const all = ['obligation.view', 'obligation.complete', 'service_record.view', 'asset_core.view', 'coverage_contract.view']

test('filters become RPC arguments; empty ones are left out; one extra row for Next', () => {
  expect(filterArgs(none)).toEqual({})
  expect(pageArgs({ q: ' lth ', category_id: 'c1', location_id: 'l1', type: 'inspection', vendor_id: 'v1', coverage: 'out' }, { value: '2026-10-01', id: 'x' })).toEqual({
    p_term: 'lth', p_category_id: 'c1', p_location_id: 'l1', p_type: 'inspection', p_vendor_id: 'v1', p_coverage: 'out',
    p_after_value: '2026-10-01', p_after_id: 'x', p_limit: 51,
  })
})

test('the cursor is the 50th row: next due on open tabs, done date on Completed', () => {
  const rows = Array.from({ length: 51 }, (_, i) => open(i + 1, day(i)))
  expect(nextCursor(rows)).toEqual({ value: day(49), id: 'o50' })
  expect(nextCursor(rows.slice(0, 50))).toBeUndefined()
  expect(nextCursor(Array.from({ length: 51 }, (_, i) => ({ id: `r${i + 1}`, done_on: day(-i) })))).toEqual({ value: day(-49), id: 'r50' })
})

test('days text and age', () => {
  expect(dueText(day(-12), today)).toBe('12 d overdue')
  expect(dueText(today, today)).toBe(m.dueToday)
  expect(dueText(day(5), today)).toBe('In 5 d')
  expect(ageText('2020-01-15', '2026-10-28')).toBe('6 y 9 mo')
  expect(ageText('2026-06-30', '2026-10-28')).toBe('3 mo')
  expect(ageText(null, today)).toBe('—')
})

test('tabs with counts, tiles, the Overdue rows; value and cost columns hidden without their domains', async () => {
  db.results['list_obligations:overdue'] = { data: [open(1, day(-12))], error: null }
  await render(all)
  expect([...container.querySelectorAll('[role=tab]')].map((b) => b.textContent)).toEqual(['Overdue · 9', 'Due soon · 14', 'Scheduled · 10,000+', 'Completed · 3'])
  expect([...container.querySelectorAll('.kpi')].map((k) => k.textContent)).toEqual(['Overdue9', 'Next 7 days4', 'Next 30 days20', 'Out of coverage23'])
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_limit: 51 })
  expect(lastRpc('count_assets')).toEqual(expect.objectContaining({ p_coverage: 'out' }))
  expect(container.querySelector('tbody')?.textContent).toContain('12 d overdue')
  expect(container.querySelector('tbody')?.textContent).toContain('Plant 1 · Pune')
  expect(heads()).not.toContain(m.col.value)
})

test('purchase value shows with asset_financials.view; Completed shows cost only with service_values.view', async () => {
  db.results['list_obligations:overdue'] = { data: [{ ...open(1), purchase_value: 1000, purchase_currency: 'INR' }], error: null }
  db.results.list_completions = { data: [{ id: 'r1', obligation_id: 'o1', asset_id: 'a1', done_on: day(-1), outcome: 'pass', done_by_name: 'Ravi', vendor_id: null, vendor_name: null,
    cost_amount: null, cost_currency: null, attachments: 2, obligation_name: 'Service 1', obligation_type: 'service', tag: 'AST-1', asset_name: 'Lathe 1',
    location_id: 'l2', category_id: 'c1', in_service_date: null, purchase_date: null, purchase_value: null, purchase_currency: null }], error: null }
  await render([...all, 'asset_financials.view'])
  expect(heads()).toContain(m.col.value)
  expect(container.querySelector('tbody')?.textContent).toContain('1,000 INR')
  await act(async () => button(m.tabs.completed).click())
  expect(lastRpc('list_completions')).toEqual({ p_limit: 51 })
  expect(heads()).not.toContain(m.col.cost)
  expect(container.querySelector('tbody')?.textContent).toContain('Ravi')
  expect(button(t.service.files).textContent).toBe(`${t.service.files} · 2`)
})

test('without service_record.view there is no Completed tab; without obligation.view only Completed', async () => {
  await render(['obligation.view', 'asset_core.view'])
  expect([...container.querySelectorAll('[role=tab]')].map((b) => b.textContent?.split(' · ')[0])).toEqual(['Overdue', 'Due soon', 'Scheduled'])
  expect(container.querySelector('.actions')).toBeNull()
  act(() => root.unmount())
  root = createRoot(container)
  await render(['service_record.view'])
  expect([...container.querySelectorAll('[role=tab]')].map((b) => b.textContent?.split(' · ')[0])).toEqual(['Completed'])
})

test('a filter goes to the list and the counts, and shows as a chip', async () => {
  await render(all)
  await act(async () => button(t.assets.panel.filters).click())
  const type = container.querySelector(`select[aria-label="${m.type}"]`) as HTMLSelectElement
  type.value = 'inspection'
  await act(async () => type.dispatchEvent(new Event('change', { bubbles: true })))
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_type: 'inspection', p_limit: 51 })
  expect(lastRpc('maintenance_counts')).toEqual({ p_type: 'inspection' })
  await act(async () => button(t.assets.panel.filters).click())
  expect(container.querySelector('.chip')?.textContent).toContain('Type: Inspection')
  expect(container.textContent).toContain(m.noMatch)
})

test('Next sends the cursor, Previous goes back', async () => {
  db.results['list_obligations:overdue'] = { data: Array.from({ length: 51 }, (_, i) => open(i + 1, day(-60 + i))), error: null }
  await render(all)
  await act(async () => button(t.assets.next).click())
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_after_value: day(-11), p_after_id: 'o50', p_limit: 51 })
  await act(async () => button(t.assets.previous).click())
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_limit: 51 })
})

test('Record completion from a row opens the 5.2 dialog; saving reloads the rows and the counts', async () => {
  db.results['list_obligations:overdue'] = { data: [open(1)], error: null }
  db.results.complete_obligation = { data: 'r9', error: null }
  await render(all)
  const lists = db.rpc.filter((r) => r.fn === 'list_obligations').length
  const counts = db.rpc.filter((r) => r.fn === 'maintenance_counts').length
  await act(async () => button(t.obligations.recordCompletion).click())
  expect(container.querySelector('form h2')?.textContent).toBe(t.service.title.replace('{name}', 'Service 1'))
  await act(async () => container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  expect(lastRpc('complete_obligation')).toEqual(expect.objectContaining({ p_obligation_id: 'o1', p_done_on: today }))
  expect(container.querySelector('form')).toBeNull()
  expect(db.rpc.filter((r) => r.fn === 'list_obligations').length).toBe(lists + 1)
  expect(db.rpc.filter((r) => r.fn === 'maintenance_counts').length).toBe(counts + 1)
})

test('loading, then empty', async () => {
  await render(all)
  expect(container.textContent).toContain(m.none)
})

test('?tab= from a Dashboard link opens that tab; a tab the user cannot see falls back', async () => {
  await render(all, '/maintenance?tab=due_soon')
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'due_soon', p_limit: 51 })
  act(() => root.unmount())
  root = createRoot(container)
  await render(['obligation.view', 'asset_core.view'], '/maintenance?tab=completed')
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_limit: 51 })
})

test('?location_id= from a Locations tile filters the list and counts; a bad id is dropped', async () => {
  const id = '00000000-0000-0000-0000-0000000000a2'
  await render(all, `/maintenance?tab=overdue&location_id=${id}`)
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_location_id: id, p_limit: 51 })
  expect(lastRpc('maintenance_counts')).toMatchObject({ p_location_id: id })
  act(() => root.unmount())
  root = createRoot(container)
  await render(all, '/maintenance?location_id=x')
  expect(lastRpc('list_obligations')).toEqual({ p_bucket: 'overdue', p_limit: 51 })
})
