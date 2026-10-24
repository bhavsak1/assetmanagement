// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { searchFilter, taxField, vendorError, VendorsPage } from './Vendors'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  calls: [] as { table: string; m: string; args: unknown[] }[],
}))

// Chain mock: every call is recorded; writes resolve from '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order', 'or', 'contains', 'limit', 'in', 'insert', 'update'])
      q[m] = (...args: unknown[]) => {
        db.calls.push({ table, m, args })
        if (m === 'insert' || m === 'update') key = `${table}:write`
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string) => Promise.resolve(db.results[fn] ?? { data: [], error: null })
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const domains = [
  { id: 'd-core', code: 'vendor_core' },
  { id: 'd-tax', code: 'vendor_tax_ids' },
]
const field = (key: string, label: string, domain: string, sort: number) => ({
  id: `f-${key}`, tenant_id: 'ta', entity: 'vendor', category_id: null, key, label, type: 'text', options: [], unit: null,
  pattern: null, is_required: false, sort_order: sort, security_domain_id: domain, is_active: true,
  created_at: '', updated_at: '', created_by: null, updated_by: null, deleted_at: null,
})
const fields = [field('rating', 'Rating', 'd-core', 0), field('pan', 'PAN', 'd-tax', 2), field('gstin', 'GSTIN', 'd-tax', 1)]
const vendor = {
  id: 'v1', tenant_id: 'ta', name: 'Siemens India', code: 'SIE', roles: ['oem', 'om'], phone: null, email: null, website: null,
  address: null, notes: null, is_active: true, custom_values: { gstin: '27AAAAA0000A1Z5', rating: 'A' },
  created_at: '', updated_at: '', created_by: null, updated_by: null,
}

test('search text becomes a safe or() filter on name and code', () => {
  expect(searchFilter('  ')).toBeUndefined()
  expect(searchFilter('atlas')).toBe('name.ilike.*atlas*,code.ilike.*atlas*')
  // or() syntax and ilike wildcards are dropped, so they cannot change the filter.
  expect(searchFilter('a,b)*%_c')).toBe('name.ilike.*a b    c*,code.ilike.*a b    c*')
})

test('the tax column is the first active vendor_tax_ids field by sort order', () => {
  expect(taxField(fields, domains)?.key).toBe('gstin')
  expect(taxField([fields[0]!], domains)).toBeUndefined()
})

test('database errors map to one message, naming the field by its label', () => {
  expect(vendorError({ code: '23505', message: 'vendor_name_uq' }, fields)).toBe(t.vendors.errors.duplicateName)
  expect(vendorError({ code: '23505', message: 'vendor_code_uq' }, fields)).toBe(t.vendors.errors.duplicateCode)
  expect(vendorError({ code: '22023', message: 'custom field gstin does not match its format' }, fields)).toBe(
    t.vendors.errors.format.replace('{name}', 'GSTIN'),
  )
  expect(vendorError({ code: '42501', message: 'no permission to change custom field pan' }, fields)).toBe(
    t.vendors.errors.fieldPermission.replace('{name}', 'PAN'),
  )
  expect(vendorError({ code: '23502', message: 'missing mandatory fields: gstin, rating' }, fields)).toBe(
    t.vendors.errors.required.replace('{names}', 'GSTIN, Rating'),
  )
})

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.calls = []
  db.results = {
    field_definition: { data: fields, error: null },
    field_domains: { data: domains, error: null },
    vendor_view: { data: [vendor], error: null },
    vendor_contact: { data: [{ id: 'c1', vendor_id: 'v1', name: 'Service Desk', phone: '+91 20 0000 0002', email: null, title: null, is_primary: true }], error: null },
  }
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(grants: string[]) {
  const can = (d: string, o: string) => grants.includes(`${d}.${o}`)
  await act(async () => root.render(<VendorsPage tenantId="ta" can={can} />))
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)
const all = ['vendor_core.view', 'vendor_core.create', 'vendor_core.update', 'vendor_tax_ids.view', 'vendor_tax_ids.update', 'category_config.manage']

test('the list shows roles, primary contact and the tax column; admins see Add and the fields card', async () => {
  await render(all)
  const row = container.querySelector('tbody tr')!
  expect(row.textContent).toContain('Siemens India')
  expect(row.textContent).toContain('OEMO&M')
  expect(row.textContent).toContain('Service Desk · +91 20 0000 0002')
  expect(row.textContent).toContain('27AAAAA0000A1Z5')
  expect(container.querySelector('thead')!.textContent).toContain('GSTIN')
  expect(button(t.vendors.add)).toBeDefined()
  expect(container.textContent).toContain(t.vendors.fields.title)
  // Primary contacts are read for the page's vendors in one query.
  expect(db.calls).toContainEqual({ table: 'vendor_contact', m: 'in', args: ['vendor_id', ['v1']] })
})

test('without vendor_tax_ids.view the tax column says Hidden; without create or manage, no Add and no fields card', async () => {
  await render(['vendor_core.view'])
  expect(container.querySelector('tbody tr')!.textContent).toContain(t.vendors.hidden)
  expect(button(t.vendors.add)).toBeUndefined()
  expect(container.textContent).not.toContain(t.vendors.fields.title)
})

test('the role and state filters go to the query', async () => {
  await render(all)
  const role = container.querySelector<HTMLSelectElement>(`select[aria-label="${t.vendors.col.roles}"]`)!
  role.value = 'supplier'
  await act(async () => role.dispatchEvent(new Event('change', { bubbles: true })))
  expect(db.calls).toContainEqual({ table: 'vendor_view', m: 'contains', args: ['roles', ['supplier']] })
  const state = container.querySelector<HTMLSelectElement>(`select[aria-label="${t.vendors.active}"]`)!
  state.value = 'inactive'
  await act(async () => state.dispatchEvent(new Event('change', { bubbles: true })))
  expect(db.calls).toContainEqual({ table: 'vendor_view', m: 'eq', args: ['is_active', false] })
})

test('saving an edit sends roles, active and the visible custom values to the base table', async () => {
  db.results['vendor:write'] = { data: [{ id: 'v1' }], error: null }
  await render(['vendor_core.view', 'vendor_core.update', 'vendor_tax_ids.view'])
  await act(async () => button('Siemens India')!.click())
  const supplier = [...container.querySelectorAll('label.check')].find((l) => l.textContent === t.vendors.roles.supplier)!.querySelector('input')!
  await act(async () => supplier.click())
  const active = container.querySelector<HTMLInputElement>('input[name="active"]')!
  await act(async () => active.click())
  // No vendor_tax_ids.update: the GSTIN input is read-only.
  expect(container.querySelector<HTMLInputElement>('input[name="custom.gstin"]')!.disabled).toBe(true)
  await act(async () => button(t.vendors.save)!.click())
  const update = db.calls.find((c) => c.table === 'vendor' && c.m === 'update')!.args[0] as Record<string, unknown>
  expect(update.roles).toEqual(['oem', 'om', 'supplier'])
  expect(update.is_active).toBe(false)
  expect(update.custom_values).toEqual({ gstin: '27AAAAA0000A1Z5', rating: 'A' })
})

test('a view-only user sees the vendor read-only and cannot edit contacts', async () => {
  await render(['vendor_core.view'])
  await act(async () => button('Siemens India')!.click())
  expect(container.querySelector('fieldset')!.disabled).toBe(true)
  expect(button(t.vendors.save)).toBeUndefined()
  expect(button(t.vendors.contacts.add)).toBeUndefined()
  expect(container.textContent).toContain('Service Desk')
})

test('adding a contact inserts it for the open vendor', async () => {
  db.results['vendor_contact:write'] = { data: [{ id: 'c2' }], error: null }
  await render(all)
  await act(async () => button('Siemens India')!.click())
  await act(async () => button(t.vendors.contacts.add)!.click())
  const forms = container.querySelectorAll('form')
  const contactForm = forms[forms.length - 1]!
  contactForm.querySelector<HTMLInputElement>('input[name="name"]')!.value = 'R. Kulkarni'
  await act(async () => contactForm.requestSubmit())
  const insert = db.calls.find((c) => c.table === 'vendor_contact' && c.m === 'insert')!.args[0] as Record<string, unknown>
  expect(insert).toMatchObject({ name: 'R. Kulkarni', vendor_id: 'v1', tenant_id: 'ta', is_primary: false })
})
