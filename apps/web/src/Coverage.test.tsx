// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { addDays, bestLine, CoverageCard, CoveragePage, nextCursor, statusText, tabFilter, tenantToday } from './Coverage'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  calls: [] as { table: string; m: string; args: unknown[] }[],
}))

// Chain mock: every call is recorded. Writes resolve from '<table>:write', a status filter from '<table>:status=<s>'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'neq', 'is', 'in', 'or', 'order', 'limit', 'insert', 'update'])
      q[m] = (...args: unknown[]) => {
        db.calls.push({ table, m, args })
        if (m === 'insert' || m === 'update') key = `${table}:write`
        if (m === 'eq' && args[0] === 'status' && `${table}:status=${String(args[1])}` in db.results) key = `${table}:status=${String(args[1])}`
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args?: unknown) => {
    db.calls.push({ table: 'rpc', m: fn, args: [args] })
    return Promise.resolve(db.results[fn] ?? { data: [], error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const today = '2026-10-27'
const row = {
  id: 'c1', tenant_id: 'ta', coverage_type: 'warranty', vendor_id: 'v1', reference: 'W-1', start_date: '2025-11-01', end_date: '2026-10-31',
  contract_value: 1000, contract_currency: 'INR', renews_coverage_id: null, notes: null, status: 'expiring',
  created_at: '', updated_at: '', created_by: null, updated_by: null,
}

test('status text counts days from the tenant today', () => {
  expect(statusText('active', '2026-01-01', '2027-12-31', today)).toBe(t.coverage.status.active)
  expect(statusText('expiring', '2026-01-01', '2026-11-20', today)).toBe('Expires in 24 d')
  expect(statusText('expiring', '2026-01-01', today, today)).toBe(t.coverage.status.expiresToday)
  expect(statusText('expired', '2025-01-01', '2026-10-24', today)).toBe('Expired 3 d ago')
  expect(statusText('future', '2026-11-01', '2027-10-31', today)).toBe('Starts in 5 d')
  expect(tenantToday('Asia/Kolkata', new Date('2026-10-26T19:00:00Z'))).toBe('2026-10-27')
  expect(tenantToday('UTC', new Date('2026-10-26T19:00:00Z'))).toBe('2026-10-26')
  expect(addDays('2026-12-31', 1)).toBe('2027-01-01')
})

test('tabs filter by type group or status; the best line picks the responsible vendor', () => {
  expect(tabFilter('all')).toEqual({})
  expect(tabFilter('warranty')).toEqual({ types: ['warranty', 'extended_warranty'] })
  expect(tabFilter('amc')).toEqual({ types: ['amc'] })
  expect(tabFilter('expiring')).toEqual({ status: 'expiring' })
  const line = (g: string, status: string, end: string, vendor: string) => ({ asset_id: 'a1', coverage_group: g, status, coverage_id: g, vendor_id: vendor, start_date: '2025-01-01', end_date: end })
  expect(bestLine([line('warranty', 'expired', '2026-01-01', 'v1'), line('amc', 'active', '2027-01-01', 'v2')])?.vendor_id).toBe('v2')
  expect(bestLine([])).toBeUndefined()
  expect(nextCursor(Array.from({ length: 51 }, (_, i) => ({ ...row, id: `c${i}` })))).toEqual({ end: '2026-10-31', id: 'c49' })
  expect(nextCursor([row])).toBeUndefined()
})

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.calls = []
  db.results = {
    tenant: { data: [{ currency_code: 'INR', time_zone: 'Asia/Kolkata', date_format: 'yyyy-MM-dd', locale: 'en-IN', coverage_expiring_days: 30 }], error: null },
    vendor_view: { data: [{ id: 'v1', name: 'Siemens India', is_active: true }, { id: 'v2', name: 'Old Co', is_active: false }], error: null },
    coverage_view: { data: [row], error: null },
    'coverage_view:status=active': { count: 318, data: null, error: null },
    'coverage_view:status=expiring': { count: 17, data: null, error: null },
    'coverage_view:status=expired': { count: 41, data: null, error: null },
    coverage_asset: { data: [{ id: 'l1', coverage_id: 'c1', asset_id: 'a1' }, { id: 'l2', coverage_id: 'c1', asset_id: 'a2' }], error: null },
    asset_view: { data: [{ id: 'a1', tag: 'PNE-0412', name: 'CNC Lathe 04' }, { id: 'a2', tag: 'PNE-0413', name: 'CNC Lathe 05' }], error: null },
    'coverage:write': { data: [{ id: 'c9' }], error: null },
    'coverage_asset:write': { data: [{ id: 'l9' }], error: null },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const admin = ['coverage_contract.view', 'coverage_contract.create', 'coverage_contract.update', 'coverage_contract.delete', 'coverage_values.view', 'coverage_values.update', 'vendor_core.view']
const planner = ['coverage_contract.view', 'coverage_contract.create', 'coverage_contract.update', 'vendor_core.view']

async function render(grants: string[], path = '/coverage') {
  const can = (d: string, o: string) => grants.includes(`${d}.${o}`)
  await act(async () => root.render(<MemoryRouter initialEntries={[path]}><CoveragePage tenantId="ta" can={can} /></MemoryRouter>))
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)
const field = <T extends HTMLElement>(name: string) => container.querySelector<T>(`[name="${name}"]`)!
const writes = (table: string, m: string) => db.calls.filter((c) => c.table === table && c.m === m).map((c) => c.args[0])

test('cards count by status, the table shows first asset +n, scope, vendor and status', async () => {
  await render(admin)
  const cards = [...container.querySelectorAll('.kpi')].map((k) => k.textContent)
  expect(cards).toEqual(['Active318', 'Expiring in 30 days17', 'Expired41'])
  const tr = container.querySelector('tbody tr')!
  expect(tr.textContent).toContain('CNC Lathe 04 +1')
  expect(tr.textContent).toContain('2 assets')
  expect(tr.textContent).toContain('Siemens India')
  expect(tr.textContent).toContain('2026-10-31')
  expect(tr.querySelector('.tag.warn')).not.toBeNull()
  await act(async () => button(t.coverage.tabs.warranty)!.click())
  expect(db.calls).toContainEqual({ table: 'coverage_view', m: 'in', args: ['coverage_type', ['warranty', 'extended_warranty']] })
  await act(async () => button(t.coverage.tabs.expiring)!.click())
  expect(db.calls).toContainEqual({ table: 'coverage_view', m: 'eq', args: ['status', 'expiring'] })
})

test('without coverage_values view the value is Hidden; a planner can still edit and save without sending it', async () => {
  await render(planner, '/coverage?id=c1')
  expect(container.querySelector('[name="contract_value"]')).toBeNull()
  expect(container.textContent).toContain(t.coverage.hidden)
  expect(container.querySelector('fieldset')!.disabled).toBe(false)
  expect(button(t.coverage.delete)).toBeUndefined()
  await act(async () => container.querySelector('form')!.requestSubmit())
  const sent = writes('coverage', 'update')[0] as Record<string, unknown>
  expect(sent).not.toHaveProperty('contract_value')
  expect(sent.vendor_id).toBe('v1')
})

test('with coverage_values the value shows; read-only users get a disabled form and no buttons', async () => {
  await render(admin, '/coverage?id=c1')
  expect(field<HTMLInputElement>('contract_value').value).toBe('1000')
  act(() => root.unmount())
  root = createRoot(container)
  await render(['coverage_contract.view', 'coverage_values.view', 'vendor_core.view'], '/coverage?id=c1')
  expect(button(t.coverage.add)).toBeUndefined()
  expect(button(t.coverage.renew)).toBeUndefined()
  expect(button(t.coverage.save)).toBeUndefined()
  expect(container.querySelector('fieldset')!.disabled).toBe(true)
  expect(button(t.coverage.removeAsset)).toBeUndefined()
})

test('renew prefills the next period, keeps the link and the assets', async () => {
  await render(admin, '/coverage?id=c1')
  await act(async () => button(t.coverage.renew)!.click())
  expect(container.textContent).toContain(t.coverage.renewTitle)
  expect(field<HTMLInputElement>('start_date').value).toBe('2026-11-01')
  expect(field<HTMLInputElement>('end_date').value).toBe('2027-10-31')
  expect(field<HTMLSelectElement>('vendor_id').value).toBe('v1')
  await act(async () => container.querySelector('form')!.requestSubmit())
  const sent = writes('coverage', 'insert')[0] as Record<string, unknown>
  expect(sent).toMatchObject({ renews_coverage_id: 'c1', start_date: '2026-11-01', end_date: '2027-10-31', coverage_type: 'warranty' })
  expect(writes('coverage_asset', 'insert')[0]).toEqual([
    { tenant_id: 'ta', coverage_id: 'c9', asset_id: 'a1' },
    { tenant_id: 'ta', coverage_id: 'c9', asset_id: 'a2' },
  ])
})

test('the asset picker adds and removes links, saved as inserts and soft deletes', async () => {
  db.results.list_assets = { data: [{ id: 'a3', tag: 'PNE-0500', name: 'Boiler B-1' }], error: null }
  await render(admin, '/coverage?id=c1')
  const box = container.querySelector<HTMLInputElement>(`input[aria-label="${t.coverage.findAsset}"]`)!
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(box, 'boiler')
  await act(async () => box.dispatchEvent(new Event('input', { bubbles: true })))
  await act(async () => new Promise((r) => setTimeout(r, 350)))
  expect(db.calls).toContainEqual({ table: 'rpc', m: 'list_assets', args: [{ p_term: 'boiler', p_sort: 'name', p_limit: 10 }] })
  await act(async () => button(t.coverage.addAsset)!.click())
  await act(async () => [...container.querySelectorAll('button')].filter((b) => b.textContent === t.coverage.removeAsset)[0]!.click())
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(writes('coverage_asset', 'insert')[0]).toEqual([{ tenant_id: 'ta', coverage_id: 'c9', asset_id: 'a3' }])
  expect(db.calls).toContainEqual({ table: 'coverage_asset', m: 'in', args: ['id', ['l1']] })
})

test('add for an asset starts with that asset; no Add without create', async () => {
  db.results.asset_view = { data: [{ id: 'a1', tag: 'PNE-0412', name: 'CNC Lathe 04' }], error: null }
  await render(admin, '/coverage?asset=a1')
  expect(container.querySelector('h2')?.textContent).toBe(t.coverage.add)
  expect(container.querySelector('section')!.textContent).toContain('PNE-0412')
  act(() => root.unmount())
  root = createRoot(container)
  await render(['coverage_contract.view'])
  expect(button(t.coverage.add)).toBeUndefined()
})

test('the asset detail card shows each group, None when never covered, and the responsible vendor', async () => {
  db.results.asset_coverage = {
    data: [{ asset_id: 'a1', coverage_group: 'warranty', status: 'active', coverage_id: 'c1', vendor_id: 'v1', start_date: '2025-01-01', end_date: '2028-01-31' }],
    error: null,
  }
  const can = (d: string, o: string) => admin.includes(`${d}.${o}`)
  await act(async () => root.render(<MemoryRouter><CoverageCard assetId="a1" can={can} /></MemoryRouter>))
  const text = container.textContent
  expect(text).toContain(`${t.coverage.groups.warranty}${t.coverage.status.active} to 2028-01-31`)
  expect(text).toContain(`${t.coverage.groups.amc}${t.coverage.status.none}`)
  expect(text).not.toContain(t.coverage.groups.other)
  expect(text).toContain(`${t.coverage.vendor}Siemens India`)
})
