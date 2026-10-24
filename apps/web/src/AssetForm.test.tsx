// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetFormPage, customPayload, fieldErrors, lineFields, requiredNames, validate } from './AssetForm'
import { t } from './i18n'
import type { Tables } from './types/database'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  writes: [] as unknown[],
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
  const rpc = (fn: string) => Promise.resolve(db.results[fn] ?? { data: [], error: null })
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
