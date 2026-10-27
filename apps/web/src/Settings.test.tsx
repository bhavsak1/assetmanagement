// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { SettingsPage, formatDate, tagErrorMessage } from './Settings'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: vi.fn(),
}))

// Same mock as Locations.test: awaiting the chain gives the table's result. rpc() returns db.rpc's result.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
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
  asset_tag_pattern: 'AST-{SEQ:5}',
  coverage_expiring_days: 60,
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
    p_coverage_expiring_days: 60,
  })
  // Shown in the button row, and gone once the user edits again.
  expect(container.querySelector('button[type="submit"]')!.parentElement!.querySelector('[role="status"]')?.textContent).toContain(t.settings.saved)
  await act(async () => field<HTMLSelectElement>('currency').dispatchEvent(new Event('change', { bubbles: true })))
  expect(container.querySelector('[role="status"]')).toBeNull()
})

test('a refused save shows the permission message', async () => {
  db.rpc.mockReturnValue({ data: null, error: { code: '42501', message: 'not allowed to change tenant settings' } })
  await render(true, true)
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.settings.errors.noPermission)
})

// React tracks a controlled input's value, so set it through the native setter, then fire input.
function type(el: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(el, value)
  el.dispatchEvent(new Event('input', { bubbles: true }))
}
const previews = () => db.rpc.mock.calls.filter(([name]) => name === 'preview_asset_tag')
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)

test('tag errors map to their messages', () => {
  const e = t.settings.tag.errors
  expect(tagErrorMessage({ code: '23514' })).toBe(e.format)
  expect(tagErrorMessage({ code: '22023', message: 'the tag pattern needs a location code: set a location' })).toBe(e.needsLocation)
  expect(tagErrorMessage({ code: '22023', message: 'the tag pattern needs a category code: add one' })).toBe(e.needsCategory)
  expect(tagErrorMessage({ code: '42501' })).toBe(e.noPermission)
  expect(tagErrorMessage({ code: 'XX000' })).toBe(e.generic)
})

test('a part chip inserts at the cursor', async () => {
  await render(true, true)
  const input = field<HTMLInputElement>('tagPattern')
  expect(input.value).toBe('AST-{SEQ:5}')
  input.setSelectionRange(0, 3)
  await act(async () => button('{CAT}')!.click())
  expect(input.value).toBe('{CAT}-{SEQ:5}')
})

test('the sample comes from preview_asset_tag, debounced', async () => {
  vi.useFakeTimers()
  try {
    db.rpc.mockImplementation((name: string) => (name === 'preview_asset_tag' ? { data: 'CNC-0001', error: null } : { data: null, error: null }))
    await render(true, true)
    const input = field<HTMLInputElement>('tagPattern')
    await act(async () => type(input, '{CAT}'))
    await act(async () => type(input, '{CAT}-{SEQ:4}'))
    await act(async () => vi.advanceTimersByTime(299))
    expect(previews()).toHaveLength(0)
    await act(async () => vi.advanceTimersByTime(1))
    expect(previews()).toEqual([['preview_asset_tag', { p_pattern: '{CAT}-{SEQ:4}', p_location_id: undefined, p_category_id: undefined }]])
    expect(container.textContent).toContain('CNC-0001')
  } finally {
    vi.useRealTimers()
  }
})

test('a refused preview shows the mapped message', async () => {
  vi.useFakeTimers()
  try {
    db.rpc.mockReturnValue({ data: null, error: { code: '23514', message: 'invalid tag pattern' } })
    await render(true, true)
    await act(async () => vi.advanceTimersByTime(300))
    expect(container.textContent).toContain(t.settings.tag.errors.format)
  } finally {
    vi.useRealTimers()
  }
})

test('manage: save sends the pattern to set_asset_tag_pattern', async () => {
  await render(true, true)
  await act(async () => type(field<HTMLInputElement>('tagPattern'), '{CAT}-{SEQ:4}'))
  await act(async () => button(t.settings.tag.save)!.click())
  expect(db.rpc).toHaveBeenCalledWith('set_asset_tag_pattern', { p_pattern: '{CAT}-{SEQ:4}' })
  expect(container.textContent).toContain(t.settings.tag.saved)
})

test('view only: tag pattern read-only, no chips, no save, sample still shown', async () => {
  await render(true, false)
  expect(field<HTMLInputElement>('tagPattern').disabled).toBe(true)
  expect(button('{CAT}')).toBeUndefined()
  expect(button(t.settings.tag.save)).toBeUndefined()
  expect(container.textContent).toContain(t.settings.tag.sample)
})
