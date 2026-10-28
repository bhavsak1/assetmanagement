// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetFormPage, customPayload, fieldErrors, lineFields, requiredNames, validate, validateLines, warrantyError } from './AssetForm'
import { t } from './i18n'
import type { Tables } from './types/database'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  writes: [] as unknown[],
  rpcs: [] as [string, unknown][],
}))

// Same chain mock as Assets.test: awaiting gives the table's result; writes record their payload.
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
  const rpc = (fn: string, args: unknown) => {
    db.rpcs.push([fn, args])
    return Promise.resolve(db.results[fn] ?? { data: [], error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

type Field = Tables<'field_definition'>
const field = (key: string, over: Partial<Field> = {}): Field => ({
  id: `f-${key}`,
  tenant_id: 'ta',
  entity: 'asset',
  category_id: null,
  key,
  label: key,
  type: 'text',
  options: [],
  unit: null,
  pattern: null,
  is_required: false,
  sort_order: 0,
  security_domain_id: 'd-core',
  is_active: true,
  created_at: '',
  updated_at: '',
  created_by: null,
  updated_by: null,
  deleted_at: null,
  ...over,
})
const categories = [
  { id: 'c1', parent_id: null, name: 'Machines', is_active: true },
  { id: 'c2', parent_id: 'c1', name: 'CNC', is_active: true },
  { id: 'c3', parent_id: null, name: 'Vehicles', is_active: true },
]
const fields = [
  field('own', { category_id: 'c2', sort_order: 0 }),
  field('parent_b', { category_id: 'c1', sort_order: 1 }),
  field('parent_a', { category_id: 'c1', sort_order: 0 }),
  field('every', { category_id: null }),
  field('plate', { category_id: 'c3' }),
  field('old', { category_id: 'c2', is_active: false }),
]

test('the form takes the category line: every-asset fields, then furthest ancestor first, by sort order', () => {
  expect(lineFields(fields, categories, 'c2').map((f) => f.key)).toEqual(['every', 'parent_a', 'parent_b', 'own'])
  expect(lineFields(fields, categories, 'c3').map((f) => f.key)).toEqual(['every', 'plate'])
  expect(lineFields(fields, categories, '').map((f) => f.key)).toEqual(['every'])
})

test('required markers follow the 2.5 rules and M2', () => {
  const line = [field('a', { is_required: true }), field('b', { is_required: true, security_domain_id: 'd-fin' })]
  const canWrite = (f: Field) => f.security_domain_id === 'd-core'
  const rules = ['serial_number', 'location', 'purchase_value']
  expect([...requiredNames({ line, tenantRequired: rules, editing: false, canWrite, canMoney: true })].sort()).toEqual(
    ['category_id', 'custom.a', 'location_id', 'name', 'purchase_value', 'serial_number'].sort(),
  )
  // Edit: location changes only by transfer. No money grant: purchase value is skipped.
  expect([...requiredNames({ line, tenantRequired: rules, editing: true, canWrite, canMoney: false })].sort()).toEqual(
    ['category_id', 'custom.a', 'name', 'serial_number'].sort(),
  )
})

test('client checks: required, number, quantity', () => {
  const line = [field('kw', { type: 'number' })]
  const errors = validate({ name: '', category_id: 'c1', quantity: '0', 'custom.kw': 'abc' }, new Set(['name', 'category_id']), line)
  expect(errors).toEqual({ name: t.assetForm.errors.required, quantity: t.assetForm.errors.quantity, 'custom.kw': t.assetForm.errors.number })
})

test('database errors map to the field they are about', () => {
  const e = t.assetForm.errors
  expect(fieldErrors({ code: '23502', message: 'missing mandatory fields: inspect_no, location, serial_number' })).toEqual({
    'custom.inspect_no': e.required,
    location_id: e.required,
    serial_number: e.required,
  })
  expect(fieldErrors({ code: '22023', message: 'custom field rated_kw needs a number value' })).toEqual({ 'custom.rated_kw': e.invalid })
  expect(fieldErrors({ code: '42501', message: 'no permission to change custom field cost_rate' })).toEqual({ 'custom.cost_rate': e.noPermissionField })
  expect(fieldErrors({ code: '42501', message: 'no permission to change purchase value' })).toEqual({ purchase_value: e.noPermissionField })
  expect(fieldErrors({ code: '23505', message: 'duplicate key value violates unique constraint "asset_tag_uq"' })).toEqual({ tag: e.tagDuplicate })
  expect(fieldErrors({ code: '22023', message: 'the tag pattern needs a category code: add one to the category or type a tag' })).toEqual({ tag: e.tagNeedsCode })
  expect(fieldErrors({ code: '23514', message: 'assets can nest at most 5 levels deep' })).toEqual({ parent: e.parentDepth })
  expect(fieldErrors({ code: '23514', message: 'an asset cannot be inside itself' })).toEqual({ parent: e.parentCycle })
  expect(fieldErrors({ code: '23514', message: 'category is inactive or deleted' })).toEqual({ category_id: e.categoryInactive })
  expect(fieldErrors({ code: '42501', message: 'new row violates row-level security policy' })).toEqual({ '': e.noPermission })
})

test('custom values sent: edits to writable fields only; stored values of other fields go back unchanged', () => {
  const line = [field('kw', { type: 'number' }), field('ro'), field('note')]
  const canWrite = (f: Field) => f.key !== 'ro'
  // asset_view already removed hidden keys, so `stored` never holds them and they are never sent.
  const stored = { kw: 15, ro: 'x', note: 'n', plate: 'MH12' }
  expect(customPayload(stored, { 'custom.kw': '20', 'custom.ro': 'changed', 'custom.note': '' }, line, canWrite)).toEqual({ kw: 20, ro: 'x', plate: 'MH12' })
})

let root: Root
let container: HTMLDivElement
const can = (d: string, o: string) => ['asset_core.view', 'asset_core.update'].includes(`${d}.${o}`)

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.writes = []
  db.rpcs = []
  db.results = {
    tenant: { data: [{ currency_code: 'INR', required_asset_fields: ['location'] }], error: null },
    asset_category: { data: categories, error: null },
    location: { data: [{ id: 'l1', parent_id: null, name: 'Pune', active: true }], error: null },
    field_definition: {
      data: [
        field('rated_kw', { type: 'number', category_id: 'c1', is_required: true }),
        field('fluid', { type: 'list', category_id: 'c1', options: [{ code: 'oil', label: 'Oil', is_active: true }] }),
        field('cost_rate', { type: 'number', security_domain_id: 'd-fin' }),
        field('plate', { category_id: 'c3' }),
      ],
      error: null,
    },
    field_domains: { data: [{ id: 'd-core', code: 'asset_core' }, { id: 'd-fin', code: 'asset_financials' }], error: null },
    asset_view: {
      data: [
        {
          id: 'a1', tag: 'AST-00001', name: 'Lathe 04', category_id: 'c1', location_id: 'l1', status: 'active', quantity: 1,
          parent_asset_id: null, criticality: null, serial_number: null, manufacturer: null, model: null, purchase_date: null,
          in_service_date: null, purchase_value: null, purchase_currency: null, custom_values: { rated_kw: 15, plate: 'MH12' },
        },
      ],
      error: null,
    },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function renderEdit() {
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={['/assets/a1/edit']}>
        <Routes>
          <Route path="/assets/:assetId/edit" element={<AssetFormPage tenantId="ta" can={can} />} />
          <Route path="/assets" element={<p>list</p>} />
        </Routes>
      </MemoryRouter>,
    ),
  )
}
const fieldEl = (name: string) => container.querySelector(`[data-field="${name}"]`)
async function type(name: string, value: string) {
  const el = container.querySelector<HTMLInputElement>(`[name="${name}"]`)!
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(el, value)
  await act(async () => el.dispatchEvent(new Event('input', { bubbles: true })))
}
const submit = () => act(async () => container.querySelector('form')!.requestSubmit())

test('edit as a planner: no money, hidden field not shown or sent, required marker, update payload', async () => {
  await renderEdit()
  expect(fieldEl('purchase_value')).toBeNull()
  expect(fieldEl('custom.cost_rate')).toBeNull()
  expect(fieldEl('custom.rated_kw')?.textContent).toContain('rated_kw *')
  expect(fieldEl('custom.fluid')?.textContent).not.toContain('*')
  // Location is not required on edit (it changes by transfer) and is read-only.
  expect(fieldEl('location_id')?.textContent).not.toContain('*')
  expect(container.querySelector<HTMLSelectElement>('[name="location_id"]')?.disabled).toBe(true)
  expect(container.querySelector<HTMLInputElement>('[name="tag"]')?.disabled).toBe(true)

  await type('custom.rated_kw', '20')
  await submit()
  const sent = db.writes[0] as Record<string, unknown>
  expect(sent).not.toHaveProperty('purchase_value')
  expect(sent).not.toHaveProperty('purchase_currency')
  expect(sent).not.toHaveProperty('tag')
  expect(sent).not.toHaveProperty('location_id')
  expect(sent.custom_values).toEqual({ rated_kw: 20, plate: 'MH12' })
  expect(container.textContent).toBe('list')
})

test('a database error shows on its field', async () => {
  db.results['asset:write'] = { data: null, error: { code: '23502', message: 'missing mandatory fields: fluid' } }
  await renderEdit()
  await submit()
  expect(fieldEl('custom.fluid')?.textContent).toContain(t.assetForm.errors.required)
  expect(fieldEl('custom.rated_kw')?.textContent).not.toContain(t.assetForm.errors.required)
})

test('create: status offers the category set narrowed to In Stock and Active ones, first Active preselected', async () => {
  const st = (id: string, label: string, system_status: string) => ({ id, code: id, label, system_status, tone: 'ok', is_active: true, deleted_at: null })
  db.results.asset_status = { data: [st('s-is', 'In store', 'in_stock'), st('s-run', 'Running', 'active'), st('s-sb', 'Standby', 'active'), st('s-bd', 'Breakdown', 'under_maintenance')], error: null }
  db.results.category_statuses = { data: ['s-is', 's-run', 's-sb', 's-bd'], error: null }
  const canCreate = (d: string, o: string) => ['asset_core.view', 'asset_core.create'].includes(`${d}.${o}`)
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={['/assets/new']}>
        <Routes>
          <Route path="/assets/new" element={<AssetFormPage tenantId="ta" can={canCreate} />} />
        </Routes>
      </MemoryRouter>,
    ),
  )
  const status = container.querySelector<HTMLSelectElement>('[name="status_id"]')!
  expect([...status.options].map((o) => o.textContent)).toEqual(['In store', 'Running', 'Standby'])
  expect(status.value).toBe('s-run')
  expect(fieldErrors({ code: '23514', message: "status is inactive or not in the category's status set" })).toEqual({ status_id: t.assetForm.errors.statusNotInSet })
})

test('4.1b vendor pickers: tagged vendors plus the stored one marked, sent on save; rule errors show on the field', async () => {
  db.results.category_vendors = { data: ['v1'], error: null }
  db.results.vendor_view = { data: [{ id: 'v1', name: 'Siemens', is_active: true }, { id: 'v2', name: 'Old works', is_active: false }], error: null }
  ;(db.results.asset_view as { data: Record<string, unknown>[] }).data[0]!.oem_vendor_id = 'v2'
  await renderEdit()
  const oem = container.querySelector<HTMLSelectElement>('[name="oem_vendor_id"]')!
  expect([...oem.options].map((o) => o.textContent)).toEqual([t.assetForm.none, 'Siemens', `Old works (${t.assetForm.vendorInactive})`])
  expect(oem.value).toBe('v2')
  const om = container.querySelector<HTMLSelectElement>('[name="om_vendor_id"]')!
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')!.set!.call(om, 'v1')
  await act(async () => om.dispatchEvent(new Event('change', { bubbles: true })))
  await submit()
  expect(db.writes[0]).toMatchObject({ oem_vendor_id: 'v2', om_vendor_id: 'v1' })
  expect(fieldErrors({ code: '23514', message: 'om_vendor_id: vendor is not tagged to this category' })).toEqual({ om_vendor_id: t.assetForm.errors.vendorNotTagged })
  expect(fieldErrors({ code: '23514', message: 'oem_vendor_id: vendor is inactive or not an oem vendor' })).toEqual({ oem_vendor_id: t.assetForm.errors.vendorInvalid })
})

async function renderCreate(canDo: (d: string, o: string) => boolean) {
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={['/assets/new']}>
        <Routes>
          <Route path="/assets/new" element={<AssetFormPage tenantId="ta" can={canDo} />} />
          <Route path="/assets" element={<p>list</p>} />
        </Routes>
      </MemoryRouter>,
    ),
  )
}
async function pick(name: string, value: string) {
  const el = container.querySelector<HTMLSelectElement>(`[name="${name}"]`)!
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')!.set!.call(el, value)
  await act(async () => el.dispatchEvent(new Event('change', { bubbles: true })))
}
const valueOf = (name: string) => container.querySelector<HTMLInputElement | HTMLSelectElement>(`[name="${name}"]`)?.value
const tick = (i = 0) => act(async () => container.querySelectorAll<HTMLInputElement>('.check input[type="checkbox"]')[i]!.click())
const createOnly = (d: string, o: string) => ['asset_core.view', 'asset_core.create'].includes(`${d}.${o}`)
const planner = (d: string, o: string) => createOnly(d, o) || ['coverage_contract.view', 'coverage_contract.create', 'coverage_contract.update'].includes(`${d}.${o}`)

test('4.5 warranty block: hidden without coverage_contract.create; the asset saves as a plain insert', async () => {
  await renderCreate(createOnly)
  expect(container.textContent).not.toContain(t.assetForm.addWarranty)
  await type('name', 'Pump 45')
  await pick('category_id', 'c3')
  await pick('location_id', 'l1')
  await submit()
  expect(db.rpcs.some(([fn]) => fn === 'create_asset_with_warranty')).toBe(false)
  expect(db.writes).toHaveLength(1)
})

test('4.5 warranty block: Start from the purchase date, vendor from the OEM, term fills End, one call saves both', async () => {
  db.results.category_vendors = { data: ['v1'], error: null }
  db.results.vendor_view = { data: [{ id: 'v1', name: 'Kirloskar', is_active: true }, { id: 'v2', name: 'Old works', is_active: false }], error: null }
  await renderCreate(planner)
  await tick()
  await type('name', 'Pump 45')
  await pick('category_id', 'c3')
  await pick('location_id', 'l1')
  await type('purchase_date', '2026-03-15')
  await pick('oem_vendor_id', 'v1')
  expect(valueOf('w.start_date')).toBe('2026-03-15')
  expect(valueOf('w.vendor_id')).toBe('v1')
  // Inactive vendors are not offered (C2).
  expect([...container.querySelector<HTMLSelectElement>('[name="w.vendor_id"]')!.options].map((o) => o.value)).toEqual(['', 'v1'])
  await pick('w.term', '24')
  expect(valueOf('w.end_date')).toBe('2028-03-14')
  await type('w.reference', 'WC-1')
  await submit()
  const calls = db.rpcs.filter(([fn]) => fn === 'create_asset_with_warranty')
  expect(calls).toHaveLength(1)
  expect(calls[0]![1]).toMatchObject({
    p_asset: { name: 'Pump 45', category_id: 'c3', location_id: 'l1', purchase_date: '2026-03-15', oem_vendor_id: 'v1', tenant_id: 'ta' },
    p_coverages: [{ coverage_type: 'warranty', vendor_id: 'v1', reference: 'WC-1', start_date: '2026-03-15', end_date: '2028-03-14' }],
  })
  expect(db.writes).toHaveLength(0)
  expect(container.textContent).toBe('list')
})

test('4.5 extended warranty: starts the day after the warranty ends, own term; a typed End survives a new Start', async () => {
  db.results.vendor_view = { data: [{ id: 'v1', name: 'Kirloskar', is_active: true }], error: null }
  await renderCreate(planner)
  await tick()
  await type('purchase_date', '2026-03-15')
  await pick('w.term', '12')
  await tick(1)
  expect(valueOf('x.start_date')).toBe('2027-03-15')
  await pick('x.term', '24')
  expect(valueOf('x.end_date')).toBe('2029-03-14')
  await type('w.end_date', '2027-06-30')
  expect(valueOf('x.start_date')).toBe('2027-07-01')
  await type('purchase_date', '2026-04-01')
  expect(valueOf('w.start_date')).toBe('2026-04-01')
  // Warranty End was typed, so it stays.
  expect(valueOf('w.end_date')).toBe('2027-06-30')
})

test('5.1 category warranty default fills Term until the user picks one', async () => {
  db.results.category_defaults = { data: [{ default_warranty_months: 24 }], error: null }
  await renderCreate(planner)
  await tick()
  await type('purchase_date', '2026-03-15')
  await pick('category_id', 'c3')
  await tick(1)
  expect(db.rpcs).toContainEqual(['category_defaults', { p_category_id: 'c3' }])
  expect(valueOf('w.term')).toBe('24')
  expect(valueOf('w.end_date')).toBe('2028-03-14')
  await pick('w.term', '12')
  db.results.category_defaults = { data: [{ default_warranty_months: 36 }], error: null }
  await pick('category_id', 'c1')
  await tick(1)
  expect(valueOf('w.term')).toBe('12')
})

test('4.5 warranty errors: client checks and the database messages land on the block', async () => {
  const line = { coverage_type: 'warranty', vendor_id: 'v1', reference: null, start_date: '2026-03-15', end_date: '2028-03-14' }
  expect(validateLines([line])).toEqual({})
  expect(validateLines([{ ...line, vendor_id: '' }])).toEqual({ warranty: t.coverage.errors.vendorRequired })
  expect(validateLines([line, { ...line, end_date: '2026-01-01' }])).toEqual({ extended: t.coverage.errors.dates })
  expect(warrantyError({ message: 'vendor_id: vendor is inactive or not found' })).toEqual({ warranty: t.assetForm.errors.warrantyVendor })
  expect(warrantyError({ message: 'new row for relation "coverage" violates check constraint "coverage_check"' })).toEqual({ warranty: t.coverage.errors.dates })
  expect(warrantyError({ message: 'new row violates row-level security policy for table "coverage_asset"' })).toEqual({ warranty: t.assetForm.errors.warrantyNoPermission })
  // The asset's own errors still go to their fields.
  expect(warrantyError({ message: 'oem_vendor_id: vendor is not tagged to this category' })).toBeUndefined()
  expect(warrantyError({ message: 'missing mandatory fields: serial_number' })).toBeUndefined()

  db.results.create_asset_with_warranty = { data: null, error: { code: '23514', message: 'vendor_id: vendor is inactive or not found' } }
  db.results.vendor_view = { data: [{ id: 'v1', name: 'Kirloskar', is_active: true }], error: null }
  await renderCreate(planner)
  await tick()
  await type('name', 'Pump 45')
  await pick('category_id', 'c3')
  await pick('location_id', 'l1')
  await type('purchase_date', '2026-03-15')
  await pick('w.vendor_id', 'v1')
  await pick('w.term', '24')
  await submit()
  expect(container.textContent).toContain(t.assetForm.errors.warrantyVendor)
})

test('4.5 edit: the current warranty line with a link, no warranty inputs', async () => {
  db.results.asset_coverage = {
    data: [{ asset_id: 'a1', coverage_group: 'warranty', status: 'active', coverage_id: 'k1', vendor_id: 'v1', start_date: '2026-03-15', end_date: '2028-03-14' }],
    error: null,
  }
  // The tenant row also feeds the line's date format (one mock per table).
  db.results.tenant = { data: [{ currency_code: 'INR', required_asset_fields: [], time_zone: 'Asia/Kolkata', date_format: 'dd MMM yyyy', locale: 'en-IN' }], error: null }
  const viewer = (d: string, o: string) => can(d, o) || `${d}.${o}` === 'coverage_contract.view'
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={['/assets/a1/edit']}>
        <Routes>
          <Route path="/assets/:assetId/edit" element={<AssetFormPage tenantId="ta" can={viewer} />} />
        </Routes>
      </MemoryRouter>,
    ),
  )
  expect(fieldEl('warranty')?.querySelector('a')?.getAttribute('href')).toBe('/coverage?id=k1')
  expect(container.querySelector('[name="w.term"]')).toBeNull()
  expect(container.textContent).not.toContain(t.assetForm.addWarranty)
})
