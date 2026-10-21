// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { SettingsPage, formatDate } from './Settings'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: vi.fn(),
}))

// Same mock as Locations.test: awaiting the chain gives the table's result. rpc() returns db.rpc's result.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq']) q[m] = () => q
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [], error: null })
    return q
  }
  return { supabase: { from: chain, rpc: (...args: unknown[]) => Promise.resolve(db.rpc(...args)) } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const tenant = {
  currency_code: 'INR',
  locale: 'en-IN',
  time_zone: 'Asia/Kolkata',
  date_format: 'dd-MM-yyyy',
  fiscal_year_start_month: 4,
  required_asset_fields: ['model'],
}

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = { tenant: { data: [tenant], error: null } }
  db.rpc.mockReset().mockReturnValue({ data: null, error: null })
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(canView: boolean, canManage: boolean) {
  await act(async () => root.render(<SettingsPage tenantId="ta" canView={canView} canManage={canManage} />))
}
const field = <T extends Element>(name: string) => container.querySelector<T>(`[name="${name}"]`)!

test('formatDate follows each tenant date format', () => {
  const d = new Date(2026, 2, 5)
  expect(formatDate(d, 'dd-MM-yyyy', 'en-IN')).toBe('05-03-2026')
  expect(formatDate(d, 'MM/dd/yyyy', 'en-US')).toBe('03/05/2026')
  expect(formatDate(d, 'yyyy-MM-dd', 'en-IN')).toBe('2026-03-05')
  expect(formatDate(d, 'dd MMM yyyy', 'en-GB')).toBe('05 Mar 2026')
})

test('without view: no settings shown', async () => {
  await render(false, false)
  expect(container.textContent).toContain(t.settings.noAccess)
  expect(container.querySelector('form')).toBeNull()
})

test('view only: values shown, inputs disabled, no save', async () => {
  await render(true, false)
  expect(field<HTMLSelectElement>('currency').value).toBe('INR')
  expect(field<HTMLSelectElement>('fiscalMonth').value).toBe('4')
  expect(field<HTMLInputElement>('model').checked).toBe(true)
  expect([...container.querySelectorAll('fieldset')].every((f) => f.disabled)).toBe(true)
  expect(container.querySelector('button[type="submit"]')).toBeNull()
})

test('manage: save sends every setting to update_tenant_settings', async () => {
  await render(true, true)
  field<HTMLSelectElement>('currency').value = 'USD'
  field<HTMLInputElement>('serial_number').checked = true
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.rpc).toHaveBeenCalledWith('update_tenant_settings', {
    p_currency_code: 'USD',
    p_locale: 'en-IN',
    p_time_zone: 'Asia/Kolkata',
    p_date_format: 'dd-MM-yyyy',
    p_fiscal_year_start_month: 4,
    p_required_asset_fields: ['serial_number', 'model'],
  })
  expect(container.querySelector('[role="status"]')?.textContent).toBe(t.settings.saved)
})

test('a refused save shows the permission message', async () => {
  db.rpc.mockReturnValue({ data: null, error: { code: '42501', message: 'not allowed to change tenant settings' } })
  await render(true, true)
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.settings.errors.noPermission)
})
