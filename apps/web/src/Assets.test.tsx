// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetsPage, coverageCell, listArgs, nextCursor, savedFilters, urlFilters, viewFilters, type Filters } from './Assets'
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

const none: Filters = { q: '', status: '', status_id: '', category_id: '', location_id: '', vendor_id: '', coverage: '' }
const statusRows = [
  { id: 's-active', code: 'active', label: 'Active', system_status: 'active', tone: 'ok', is_active: true, deleted_at: null },
  { id: 's-spare', code: 'spare', label: 'Spare', system_status: 'in_stock', tone: 'warn', is_active: true, deleted_at: null },
]
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
  expect(listArgs({ q: ' pump ', status: 'in_stock', status_id: '', category_id: 'c1', location_id: 'l1', vendor_id: 'v1', coverage: 'expiring' }, 'tag', { value: 'AST-1', id: 'x' })).toEqual({
    p_term: 'pump',
    p_status: 'in_stock',
    p_category_id: 'c1',
    p_location_id: 'l1',
    p_vendor_id: 'v1',
    p_coverage: 'expiring',
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
  const f: Filters = { q: ' pump ', status: 'in_stock', status_id: '', category_id: 'c1', location_id: 'l2', vendor_id: '', coverage: '' }
  const saved = savedFilters(f)
  expect(saved).toEqual({ q: 'pump', status: 'in_stock', category_id: 'c1', location_id: 'l2' })
  expect(viewFilters(saved, categories, locations)).toEqual({ ...f, q: 'pump' })
  expect(savedFilters(none)).toEqual({})
  expect(viewFilters({ category_id: 'gone', status: 'lost', extra: 1 }, categories, locations)).toEqual(none)
  // 3.7: a tenant status is kept while it exists; old views (system status only) are unchanged.
  expect(viewFilters({ status_id: 's-spare' }, categories, locations, statusRows)).toEqual({ ...none, status_id: 's-spare' })
  expect(viewFilters({ status_id: 'gone' }, categories, locations, statusRows)).toEqual(none)
  // 4.1b: a vendor is kept while it exists.
  expect(viewFilters({ vendor_id: 'v1' }, categories, locations, [], [{ id: 'v1' }])).toEqual({ ...none, vendor_id: 'v1' })
  expect(viewFilters({ vendor_id: 'gone' }, categories, locations, [], [{ id: 'v1' }])).toEqual(none)
  // 4.4: a coverage value is kept when known; views saved before 4.4 have none.
  expect(viewFilters({ coverage: 'none' }, categories, locations)).toEqual({ ...none, coverage: 'none' })
  expect(viewFilters({ coverage: 'lease' }, categories, locations)).toEqual(none)
})

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.writes = []
  db.rpc = []
  localStorage.clear()
  db.results = {
    asset_category: { data: categories, error: null },
    location: { data: locations, error: null },
    list_assets: { data: Array.from({ length: 51 }, (_, i) => asset(i + 1)), error: null },
    count_assets: { data: 1284, error: null },
    saved_view: { data: [{ id: 'v1', name: 'Spares', filters: { status: 'in_stock', location_id: 'l1' }, sort: 'tag' }], error: null },
    tenant: { data: [{ time_zone: 'Asia/Kolkata' }], error: null },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
  vi.restoreAllMocks()
})

async function render(canSaveViews = true, canCreate = false, canCoverage = true) {
  await act(async () =>
    root.render(
      <MemoryRouter>
        <AssetsPage tenantId="ta" canSaveViews={canSaveViews} canCreate={canCreate} canCoverage={canCoverage} />
      </MemoryRouter>,
    ),
  )
}
const lastList = () => db.rpc.filter((c) => c.fn === 'list_assets').at(-1)?.args
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)!
const select = (label: string) => container.querySelector<HTMLSelectElement>(`select[aria-label="${label}"]`)!
const toggle = () => container.querySelector<HTMLButtonElement>('button[aria-controls="asset-filters"]')!
// The filter selects live in the panel: open it first when it is closed.
async function choose(label: string, value: string) {
  if (!select(label)) await act(async () => toggle().click())
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

test('tenant statuses: tag shows the tenant label and tone; the filter sends p_status_id', async () => {
  db.results.asset_status = { data: statusRows, error: null }
  db.results.list_assets = { data: [{ ...asset(1), status_id: 's-spare' }], error: null }
  await render()
  expect(container.querySelector('.tag.status.warn')?.textContent).toBe('Spare')
  // Default rows (code = system status) are the system options, not repeated in the group.
  await act(async () => toggle().click())
  expect([...select(t.assets.status).querySelectorAll('optgroup option')].map((o) => o.textContent)).toEqual(['Spare'])
  await choose(t.assets.status, 's-spare')
  expect(lastList()).toEqual({ p_status_id: 's-spare', p_sort: 'name', p_limit: 51 })
  await choose(t.assets.status, 'active')
  expect(lastList()).toEqual({ p_status: 'active', p_sort: 'name', p_limit: 51 })
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

test('Add asset shows only with asset_core.create; rows link to the detail page', async () => {
  await render()
  expect(container.textContent).not.toContain(t.assets.add)
  expect(container.querySelector('tbody a')?.getAttribute('href')).toBe('/assets/id1')
  act(() => root.unmount())
  root = createRoot(container)
  await render(true, true)
  expect(container.querySelector('a.btn-main')?.getAttribute('href')).toBe('/assets/new')
  expect(container.querySelector('tbody a')?.getAttribute('href')).toBe('/assets/id1')
})

// 4.4 coverage column: the group that ends first among those covering today; then out of coverage; then none.
const line = (coverage_group: string, status: string, end_date: string, asset_id = 'id1') =>
  ({ asset_id, coverage_group, status, end_date, start_date: '2025-01-01', coverage_id: 'k', vendor_id: 'v' })
test('coverage cell text and tone per case', () => {
  const today = '2026-10-27'
  expect(coverageCell([line('warranty', 'active', '2027-06-27')], today)).toEqual({ text: 'Warranty · 8 mo', tone: 'ok' })
  expect(coverageCell([line('warranty', 'active', '2027-06-27'), line('amc', 'expiring', '2026-11-20')], today)).toEqual({ text: 'AMC · 24 d', tone: 'warn' })
  expect(coverageCell([line('amc', 'expiring', '2026-10-27')], today)).toEqual({ text: 'AMC · today', tone: 'warn' })
  // Same end: warranty before AMC.
  expect(coverageCell([line('amc', 'active', '2027-10-27'), line('warranty', 'active', '2027-10-27')], today).text).toBe('Warranty · 12 mo')
  // Expired warranty, active AMC: still covered.
  expect(coverageCell([line('warranty', 'expired', '2026-01-01'), line('amc', 'active', '2027-03-27')], today).text).toBe('AMC · 5 mo')
  expect(coverageCell([line('warranty', 'expired', '2026-01-01'), line('amc', 'future', '2027-12-01')], today)).toEqual({ text: 'Out of coverage', tone: 'error' })
  expect(coverageCell([], today)).toEqual({ text: 'None', tone: 'neutral' })
})

test('the column comes from one asset_coverage call for the page; hidden without coverage view', async () => {
  db.results.list_assets = { data: [asset(1), asset(2)], error: null }
  db.results.asset_coverage = { data: [line('amc', 'expiring', '2999-01-01', 'id2')], error: null }
  await render()
  expect(db.rpc.filter((c) => c.fn === 'asset_coverage')).toEqual([{ fn: 'asset_coverage', args: { p_asset_ids: ['id1', 'id2'] } }])
  const cells = [...container.querySelectorAll('tbody tr')].map((r) => r.lastElementChild?.textContent)
  expect(cells[0]).toBe('None')
  expect(cells[1]).toMatch(/^AMC · \d+ d$/)
  act(() => root.unmount())
  root = createRoot(container)
  db.rpc = []
  await render(true, false, false)
  expect(container.querySelector('thead')?.textContent).not.toContain(t.assets.coverage.label)
  expect(db.rpc.some((c) => c.fn === 'asset_coverage')).toBe(false)
  // Permissions arrive after the first load: the page loads again with its coverage lines.
  await render(true, false, true)
  expect(db.rpc.filter((c) => c.fn === 'asset_coverage')).toHaveLength(1)
  expect([...container.querySelectorAll('tbody tr')].map((r) => r.lastElementChild?.textContent)[1]).toMatch(/^AMC · \d+ d$/)
})

const chipTexts = () => [...container.querySelectorAll('.chip')].map((c) => c.firstChild?.textContent)

test('panel: closed by default; coverage filter sends p_coverage; chips show and remove filters; Clear all', async () => {
  await render()
  expect(toggle().getAttribute('aria-expanded')).toBe('false')
  expect(container.querySelector('#asset-filters')).toBeNull()
  await choose(t.assets.coverage.label, 'expiring')
  expect(lastList()).toEqual({ p_coverage: 'expiring', p_sort: 'name', p_limit: 51 })
  expect(db.rpc.filter((c) => c.fn === 'count_assets').at(-1)?.args).toEqual({ p_coverage: 'expiring' })
  await choose(t.assets.location, 'l1')
  await act(async () => toggle().click())
  expect(toggle().getAttribute('aria-expanded')).toBe('false')
  expect(toggle().textContent).toContain(`${t.assets.panel.filters} · 2`)
  expect(chipTexts()).toEqual(['Location: Pune', 'Coverage: Expiring'])
  await act(async () => container.querySelector<HTMLButtonElement>('button[aria-label="Remove filter Location: Pune"]')!.click())
  expect(lastList()).toEqual({ p_coverage: 'expiring', p_sort: 'name', p_limit: 51 })
  expect(chipTexts()).toEqual(['Coverage: Expiring'])
  await act(async () => button(t.assets.panel.clearAll).click())
  expect(lastList()).toEqual({ p_sort: 'name', p_limit: 51 })
  expect(container.querySelectorAll('.chip')).toHaveLength(0)
  expect(toggle().textContent).not.toContain('·')
})

test('panel: aria-expanded, focus in and back, Esc closes, open state remembered', async () => {
  await render()
  await act(async () => toggle().click())
  expect(toggle().getAttribute('aria-expanded')).toBe('true')
  expect(container.querySelector('#asset-filters')!.contains(document.activeElement)).toBe(true)
  expect(localStorage.getItem('assetly.assets.filtersOpen')).toBe('1')
  // Reload: still open.
  act(() => root.unmount())
  root = createRoot(container)
  await render()
  expect(toggle().getAttribute('aria-expanded')).toBe('true')
  await act(async () => container.querySelector('#asset-filters')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })))
  expect(toggle().getAttribute('aria-expanded')).toBe('false')
  expect(document.activeElement).toBe(toggle())
  expect(localStorage.getItem('assetly.assets.filtersOpen')).toBe('0')
})

test('panel: works with storage blocked', async () => {
  const blocked = () => {
    throw new Error('blocked')
  }
  vi.spyOn(Storage.prototype, 'getItem').mockImplementation(blocked)
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(blocked)
  await render()
  expect(toggle().getAttribute('aria-expanded')).toBe('false')
  await choose(t.assets.coverage.label, 'none')
  expect(toggle().getAttribute('aria-expanded')).toBe('true')
  expect(lastList()).toEqual({ p_coverage: 'none', p_sort: 'name', p_limit: 51 })
})

test('phone: filters open as a bottom sheet; Apply and the backdrop close it; not reopened on load', async () => {
  vi.stubGlobal('matchMedia', (q: string) => ({ matches: q === '(max-width: 767px)' }))
  localStorage.setItem('assetly.assets.filtersOpen', '1')
  try {
    await render()
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
    await act(async () => toggle().click())
    const sheet = container.querySelector('#asset-filters')!
    expect(sheet.getAttribute('role')).toBe('dialog')
    expect(sheet.getAttribute('aria-modal')).toBe('true')
    await choose(t.assets.coverage.label, 'out')
    await act(async () => button(t.assets.panel.apply).click())
    expect(container.querySelector('#asset-filters')).toBeNull()
    expect(lastList()).toEqual({ p_coverage: 'out', p_sort: 'name', p_limit: 51 })
    await act(async () => toggle().click())
    await act(async () => container.querySelector<HTMLElement>('.sheet-backdrop')!.click())
    expect(container.querySelector('#asset-filters')).toBeNull()
  } finally {
    vi.unstubAllGlobals()
  }
})

test('desktop panel is a group with no Apply button', async () => {
  await render()
  await act(async () => toggle().click())
  expect(container.querySelector('#asset-filters')?.getAttribute('role')).toBe('group')
  expect([...container.querySelectorAll('button')].map((b) => b.textContent)).not.toContain(t.assets.panel.apply)
})

test('a saved view loads into the chips, coverage included', async () => {
  db.results.saved_view = { data: [{ id: 'v1', name: 'Expiring in Pune', filters: { location_id: 'l1', coverage: 'expiring' }, sort: 'name' }], error: null }
  await render()
  await choose(t.assets.views.label, 'v1')
  expect(lastList()).toEqual({ p_location_id: 'l1', p_coverage: 'expiring', p_sort: 'name', p_limit: 51 })
  expect(chipTexts()).toEqual(['Location: Pune', 'Coverage: Expiring'])
})
test('filters from a Dashboard link: status, coverage and a location id shape; anything else dropped', () => {
  const id = '00000000-0000-0000-0000-00000054d001'
  expect(urlFilters(new URLSearchParams(`coverage=expiring&location_id=${id}&status=active`))).toEqual(
    expect.objectContaining({ coverage: 'expiring', location_id: id, status: 'active', category_id: '' }),
  )
  expect(urlFilters(new URLSearchParams('coverage=bad&location_id=x;drop&status=nope'))).toEqual(
    expect.objectContaining({ coverage: '', location_id: '', status: '' }),
  )
})
