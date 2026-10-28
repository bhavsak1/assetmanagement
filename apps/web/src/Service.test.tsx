// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { ObligationsTab } from './Obligations'
import { CompletionForm, dateOk, serviceError, ServiceHistoryTab } from './Service'

const db = vi.hoisted(() => ({ results: {} as Record<string, unknown>, writes: [] as unknown[], calls: [] as { fn: string; args: unknown }[] }))

// Every builder call returns the chain; awaiting it gives the table's result. Writes switch to '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order', 'in']) q[m] = () => q
    q.update = (v: unknown) => {
      db.writes.push(v)
      key = `${table}:write`
      return q
    }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  return {
    supabase: {
      from: chain,
      rpc: (fn: string, args: unknown) => {
        db.calls.push({ fn, args })
        return chain(`rpc:${fn}`)
      },
    },
  }
})

// 5.2b: the dialog's uploads; the real AttachmentsTab stays for the history rows.
const upload = vi.hoisted(() => vi.fn(() => Promise.resolve(true)))
vi.mock('./Attachments', async (orig) => ({ ...(await orig<typeof import('./Attachments')>()), uploadAttachment: upload }))

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
const s = t.service

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = { tenant: { data: [{ time_zone: 'UTC', date_format: 'yyyy-MM-dd', locale: 'en-IN', currency_code: 'INR' }], error: null } }
  db.writes = []
  db.calls = []
  upload.mockClear()
  upload.mockResolvedValue(true)
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const button = (name: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === name)
const today = new Date().toISOString().slice(0, 10)
const only = (...allowed: string[]) => (dom: string, op: string) => allowed.includes(`${dom}.${op}`)

test('dateOk: today and 366 days back, not tomorrow or 367 back', () => {
  expect(dateOk('2026-10-28', '2026-10-28')).toBe(true)
  expect(dateOk('2025-10-27', '2026-10-28')).toBe(true)
  expect(dateOk('2025-10-26', '2026-10-28')).toBe(false)
  expect(dateOk('2026-10-29', '2026-10-28')).toBe(false)
  expect(dateOk('', '2026-10-28')).toBe(false)
})

test('serviceError maps the action codes', () => {
  expect(serviceError({ code: '42501' })).toBe(s.errors.noPermission)
  expect(serviceError({ code: '22023', message: 'a paused obligation cannot be completed' })).toBe(s.errors.paused)
  expect(serviceError({ code: '22023', message: 'done_on must be within' })).toBe(s.errors.date)
  expect(serviceError({ code: '23514', message: 'vendor_id: vendor is inactive' })).toBe(s.errors.vendor)
  expect(serviceError({})).toBe(s.errors.generic)
})

test('record completion: service type, no cost permission; date defaults to today; sends the action', async () => {
  const done = vi.fn()
  await act(async () =>
    root.render(<CompletionForm obligation={{ id: 'o1', tenant_id: 'ta', name: 'Quarterly service', obligation_type: 'service' }} can={only('obligation.complete')} onDone={done} onCancel={() => {}} />),
  )
  expect(container.querySelector<HTMLInputElement>('input[name="done_on"]')!.value).toBe(today)
  expect(container.querySelector('select[name="outcome"]')).toBeNull()
  expect(container.querySelector('input[name="cost"]')).toBeNull()
  expect(container.querySelector('input[name="certificate_expiry"]')).toBeNull()
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.calls.at(-1)).toEqual({ fn: 'complete_obligation', args: expect.objectContaining({ p_obligation_id: 'o1', p_done_on: today }) })
  expect(db.calls.at(-1)?.args).not.toHaveProperty('p_cost', expect.anything())
  expect(done).toHaveBeenCalled()
})

test('record completion: certificate with cost permission shows outcome, expiry, cost in the tenant currency', async () => {
  await act(async () =>
    root.render(
      <CompletionForm
        obligation={{ id: 'o2', tenant_id: 'ta', name: 'Lift certificate', obligation_type: 'certificate' }}
        can={only('obligation.complete', 'service_values.view', 'service_values.update')}
        onDone={() => {}}
        onCancel={() => {}}
      />,
    ),
  )
  expect(container.querySelector('select[name="outcome"]')).not.toBeNull()
  expect(container.querySelector('input[name="certificate_expiry"]')).not.toBeNull()
  expect(container.querySelector<HTMLSelectElement>('select[name="cost_currency"]')!.value).toBe('INR')
  const date = container.querySelector<HTMLInputElement>('input[name="done_on"]')!
  date.value = '2999-01-01'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.textContent).toContain(s.errors.date)
  expect(db.calls).toHaveLength(0)
})

const row = {
  id: 'r1', obligation_id: 'o1', obligation_name: 'Quarterly service', done_on: '2026-10-20', outcome: 'pass', done_by_user_id: 'u1', done_by_name: 'Ravi',
  vendor_id: null, vendor_name: null, certificate_expiry: null, notes: 'Belt changed', cost_amount: 1250, cost_currency: 'INR', advanced: true,
}

test('service history: cost masked and no actions without the operations', async () => {
  db.results['rpc:service_history'] = { data: [{ ...row, cost_amount: null, cost_currency: null }], error: null }
  await act(async () => root.render(<ServiceHistoryTab tenantId="ta" assetId="a1" can={only('service_record.view')} />))
  expect(container.textContent).toContain('Quarterly service')
  expect(container.textContent).toContain('Ravi')
  expect(container.textContent).toContain(t.coverage.hidden)
  expect(button(s.undo)).toBeUndefined()
  expect(button(s.edit)).toBeUndefined()
})

test('service history: cost shown; undo asks, then calls the action; correction keeps the date', async () => {
  db.results['rpc:service_history'] = { data: [row], error: null }
  db.results.obligation = { data: [{ id: 'o1', obligation_type: 'service' }], error: null }
  await act(async () => root.render(<ServiceHistoryTab tenantId="ta" assetId="a1" can={only('service_record.view', 'service_record.update', 'service_values.view')} />))
  expect(container.textContent).toContain('1,250 INR')

  const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true)
  await act(async () => button(s.undo)!.click())
  expect(db.calls.filter((c) => c.fn === 'undo_completion')).toHaveLength(0)
  await act(async () => button(s.undo)!.click())
  expect(db.calls.filter((c) => c.fn === 'undo_completion')).toEqual([{ fn: 'undo_completion', args: { p_service_record_id: 'r1' } }])
  expect(db.calls.at(-1)?.fn).toBe('service_history')
  confirm.mockRestore()

  await act(async () => button(s.edit)!.click())
  expect(container.querySelector<HTMLInputElement>('input[name="done_on"]')!.disabled).toBe(true)
  await act(async () => container.querySelector('form')!.requestSubmit())
  // No service_values.update and no vendor list: only the notes go.
  expect(db.writes.at(-1)).toEqual({ notes: 'Belt changed' })
})

test('obligations tab: Record completion per row with obligation.complete, not on paused rows', async () => {
  const base = { tenant_id: 'ta', asset_id: 'a1', obligation_type: 'service', interval_count: 3, interval_unit: 'month', anchor: 'completion', first_due_date: '2026-10-01', last_done_date: null, next_due_date: '2026-10-01', due_state_until: null, is_active: true, notes: null }
  db.results.obligation = { data: [{ ...base, id: 'o1', name: 'Live', due_state: 'overdue' }, { ...base, id: 'o2', name: 'Off', due_state: 'paused', is_active: false }], error: null }
  await act(async () => root.render(<ObligationsTab tenantId="ta" assetId="a1" asset={{ in_service_date: null, purchase_date: null }} can={only('obligation.view', 'obligation.complete')} />))
  expect([...container.querySelectorAll('button')].filter((b) => b.textContent === t.obligations.recordCompletion)).toHaveLength(1)
  await act(async () => button(t.obligations.recordCompletion)!.click())
  expect(container.textContent).toContain(s.title.replace('{name}', 'Live'))
})

// 5.2b: files in the Record completion dialog upload straight after the save, with the new record's id.
const pickFiles = (...files: File[]) => Object.defineProperty(container.querySelector('input[name="files"]')!, 'files', { value: files, configurable: true })
const renderForm = (can: (dom: string, op: string) => boolean, done = () => {}) =>
  act(async () => root.render(<CompletionForm obligation={{ id: 'o1', tenant_id: 'ta', name: 'Quarterly service', obligation_type: 'service' }} can={can} onDone={done} onCancel={() => {}} />))

test('record completion: no file picker without service_record.create', async () => {
  await renderForm(only('obligation.complete'))
  expect(container.querySelector('input[name="files"]')).toBeNull()
})

test('record completion: a refused file type stops the save', async () => {
  await renderForm(only('obligation.complete', 'service_record.create'))
  pickFiles(new File(['<svg/>'], 'x.svg', { type: 'image/svg+xml' }))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.textContent).toContain(t.assetDetail.attachments.badType)
  expect(db.calls).toHaveLength(0)
})

test('record completion: files upload to the new record after the save', async () => {
  db.results['rpc:complete_obligation'] = { data: 'r9', error: null }
  const done = vi.fn()
  await renderForm(only('obligation.complete', 'service_record.create'), done)
  const pdf = new File(['%PDF'], 'Report.pdf', { type: 'application/pdf' })
  pickFiles(pdf)
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(upload).toHaveBeenCalledWith('ta', 'service_record', 'r9', pdf, expect.any(Function))
  expect(done).toHaveBeenCalled()
})

test('record completion: a failed upload keeps the dialog with only Close, so the save is not repeated', async () => {
  db.results['rpc:complete_obligation'] = { data: 'r9', error: null }
  upload.mockResolvedValue(false)
  const done = vi.fn()
  await renderForm(only('obligation.complete', 'service_record.create'), done)
  pickFiles(new File(['%PDF'], 'Report.pdf', { type: 'application/pdf' }))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.textContent).toContain(s.errors.fileAfterSave)
  expect(done).not.toHaveBeenCalled()
  expect(button(s.save)).toBeUndefined()
  await act(async () => button(s.close)!.click())
  expect(done).toHaveBeenCalled()
})

test('service history: Files opens the record attachments, upload only with service_record.create', async () => {
  db.results['rpc:service_history'] = { data: [row], error: null }
  await act(async () => root.render(<ServiceHistoryTab tenantId="ta" assetId="a1" can={only('service_record.view')} />))
  await act(async () => button(s.files)!.click())
  expect(db.calls.at(-1)).toEqual({ fn: 'service_record_attachments', args: { p_service_record_id: 'r1' } })
  expect(container.textContent).toContain(t.assetDetail.attachments.none)
  expect(button(t.assetDetail.attachments.upload)).toBeUndefined()
  await act(async () => button(s.files)!.click())
  expect(container.textContent).not.toContain(t.assetDetail.attachments.none)
})
