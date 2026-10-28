import { useEffect, useState, type FormEvent } from 'react'
import { addDays, showDate, tenantToday, useTenant } from './Coverage'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Database, Tables } from './types/database'

// Story 5.2: Record completion and the Service history tab (data-model-goal5.md §12.7).
type Can = (domain: string, operation: string) => boolean
type DbError = { code?: string; message?: string }
type Obligation = Pick<Tables<'obligation'>, 'id' | 'name' | 'obligation_type'>
export type HistoryRow = Database['public']['Functions']['service_history']['Returns'][number]
type Vendor = { id: string; name: string }

const s = t.service
export const outcomes = ['pass', 'fail'] as const

export function serviceError(e: DbError): string {
  if (e.code === '42501') return s.errors.noPermission
  if (e.code === '22023') return e.message?.includes('paused') ? s.errors.paused : s.errors.date
  if (e.code === '23514') return e.message?.includes('vendor') ? s.errors.vendor : s.errors.invalid
  return s.errors.generic
}

// S3: not after today, at most 366 days back. The database checks the same.
export const dateOk = (d: string, today: string) => !!d && d <= today && d >= addDays(today, -366)

const loadVendors = async (): Promise<Vendor[]> =>
  ((await supabase.from('vendor_view').select('id, name').eq('is_active', true).order('name')).data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '' }))

// One form for a new completion and for a correction (S4: the date and the obligation stay; undo to change them).
export function CompletionForm({ obligation, row, can, onDone, onCancel }: { obligation: Obligation; row?: HistoryRow; can: Can; onDone: () => void; onCancel: () => void }) {
  const tenant = useTenant()
  const [vendors, setVendors] = useState<Vendor[]>([])
  const [error, setError] = useState<string>()
  const canCost = can('service_values', 'update') && can('service_values', 'view')
  useEffect(() => {
    let live = true
    if (can('vendor_core', 'view')) void loadVendors().then((v) => live && setVendors(v))
    return () => {
      live = false
    }
  }, [can])
  if (!tenant) return null
  const today = tenantToday(tenant.time_zone)
  const type = obligation.obligation_type

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const f = new FormData(e.currentTarget)
    const text = (k: string) => (f.get(k) == null ? null : String(f.get(k)).trim() || null)
    // Only fields the form shows are sent, so a correction never clears a value the user could not see.
    const shown = (...keys: string[]) => Object.fromEntries(keys.filter((k) => f.has(k)).map((k) => [k, text(k)]))
    const done = text('done_on') ?? ''
    if (!row && !dateOk(done, today)) return setError(s.errors.date)
    const cost = text('cost')
    if (cost !== null && !(Number(cost) >= 0)) return setError(s.errors.cost)
    const v: { notes?: string | null; outcome?: string | null; vendor_id?: string | null; certificate_expiry?: string | null; cost_amount?: number | null; cost_currency?: string | null } = {
      ...shown('notes', 'outcome', 'vendor_id', 'certificate_expiry'),
      ...(canCost && { cost_amount: cost === null ? null : Number(cost), cost_currency: cost === null ? null : text('cost_currency') }),
    }
    setError(undefined)
    const { error } = row
      ? // A correction keeps who did it unless a contractor is named or removed.
        await supabase.from('service_record').update(v).eq('id', row.id ?? '')
      : await supabase.rpc('complete_obligation', {
          p_obligation_id: obligation.id,
          p_done_on: done,
          p_notes: v.notes ?? undefined,
          p_outcome: v.outcome ?? undefined,
          p_vendor_id: v.vendor_id ?? undefined,
          p_certificate_expiry: v.certificate_expiry ?? undefined,
          p_cost: v.cost_amount ?? undefined,
          p_currency: v.cost_currency ?? undefined,
        })
    if (error) return setError(serviceError(error))
    onDone()
  }

  return (
    <form className="card" onSubmit={(e) => void submit(e)} noValidate>
      <h2>{(row ? s.editTitle : s.title).replace('{name}', obligation.name)}</h2>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <label className="field">
        {s.doneOn}
        <input name="done_on" type="date" defaultValue={row?.done_on ?? today} max={today} min={addDays(today, -366)} disabled={!!row} required />
        {row && <span className="muted hint">{s.dateLocked}</span>}
      </label>
      {type !== 'service' && (
        <label className="field">
          {s.outcome}
          <select name="outcome" defaultValue={row?.outcome ?? ''}>
            <option value="">{s.noOutcome}</option>
            {outcomes.map((x) => (
              <option key={x} value={x}>
                {s.outcomes[x]}
              </option>
            ))}
          </select>
        </label>
      )}
      {vendors.length > 0 && (
        <label className="field">
          {s.contractor}
          <select name="vendor_id" defaultValue={row?.vendor_id ?? ''}>
            <option value="">{s.doneByMe}</option>
            {vendors.map((x) => (
              <option key={x.id} value={x.id}>
                {x.name}
              </option>
            ))}
          </select>
        </label>
      )}
      {type === 'certificate' && (
        <label className="field">
          {s.certificateExpiry}
          <input name="certificate_expiry" type="date" defaultValue={row?.certificate_expiry ?? ''} />
        </label>
      )}
      {canCost && (
        <div className="rule-row">
          <label className="field">
            {s.cost}
            <input name="cost" type="number" min={0} step="0.01" inputMode="decimal" defaultValue={row?.cost_amount ?? ''} />
          </label>
          <label className="field">
            {s.currency}
            <select name="cost_currency" defaultValue={row?.cost_currency ?? tenant.currency_code}>
              {[...new Set([row?.cost_currency ?? tenant.currency_code, ...Intl.supportedValuesOf('currency')])].map((x) => (
                <option key={x} value={x}>
                  {x}
                </option>
              ))}
            </select>
          </label>
        </div>
      )}
      <label className="field">
        {s.notes}
        <textarea name="notes" rows={3} maxLength={2000} defaultValue={row?.notes ?? ''} />
      </label>
      <div className="page-head">
        <div className="spacer" />
        <button className="btn" type="button" onClick={onCancel}>
          {s.cancel}
        </button>
        <button className="btn btn-main" type="submit">
          {s.save}
        </button>
      </div>
    </form>
  )
}

export function ServiceHistoryTab({ assetId, can }: { assetId: string; can: Can }) {
  const tenant = useTenant()
  const [rows, setRows] = useState<HistoryRow[]>()
  const [types, setTypes] = useState<Record<string, string>>({})
  const [editing, setEditing] = useState<HistoryRow>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.rpc('service_history', { p_asset_id: assetId }),
      supabase.from('obligation').select('id, obligation_type').eq('asset_id', assetId),
    ]).then(([h, ob]) => {
      if (!live) return
      setRows(h.data ?? [])
      setTypes(Object.fromEntries((ob.data ?? []).map((x) => [x.id, x.obligation_type])))
      if (h.error) setError(s.errors.load)
    })
    return () => {
      live = false
    }
  }, [assetId, reload])

  if (!rows || !tenant) return <p className="muted" role="status">{s.loading}</p>
  const canUpdate = can('service_record', 'update')
  const seeCost = can('service_values', 'view')
  const done = () => {
    setEditing(undefined)
    setReload((n) => n + 1)
  }
  async function undo(r: HistoryRow) {
    if (!window.confirm(s.undoConfirm.replace('{name}', r.obligation_name ?? '').replace('{date}', showDate(r.done_on, tenant)))) return
    const { error } = await supabase.rpc('undo_completion', { p_service_record_id: r.id ?? '' })
    if (error) return setError(serviceError(error))
    done()
  }

  return (
    <div className="stack detail">
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {editing && (
        <CompletionForm
          obligation={{ id: editing.obligation_id ?? '', name: editing.obligation_name ?? '', obligation_type: types[editing.obligation_id ?? ''] ?? 'service' }}
          row={editing}
          can={can}
          onDone={done}
          onCancel={() => setEditing(undefined)}
        />
      )}
      <div className="card table-wrap list service">
        {rows.length === 0 ? (
          <p className="muted">{s.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{s.col.date}</th>
                <th>{s.col.obligation}</th>
                <th>{s.col.outcome}</th>
                <th>{s.col.doneBy}</th>
                <th>{s.col.cost}</th>
                <th>{s.col.notes}</th>
                {canUpdate && <th aria-label={s.col.actions} />}
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{showDate(r.done_on, tenant)}</td>
                  <td>
                    {r.obligation_name ?? '—'}
                    {r.certificate_expiry && <span className="muted"> {s.expires.replace('{date}', showDate(r.certificate_expiry, tenant))}</span>}
                  </td>
                  <td>{r.outcome ? <span className={`tag status ${r.outcome === 'pass' ? 'ok' : 'error'}`}>{s.outcomes[r.outcome as (typeof outcomes)[number]]}</span> : '—'}</td>
                  <td>{r.vendor_name ?? r.done_by_name ?? (r.vendor_id ? s.contractorHidden : '—')}</td>
                  <td>{!seeCost ? <span className="tag">{t.coverage.hidden}</span> : r.cost_amount == null ? '—' : `${Number(r.cost_amount).toLocaleString()} ${r.cost_currency ?? ''}`}</td>
                  <td>{r.notes ?? ''}</td>
                  {canUpdate && (
                    <td className="actions">
                      <button className="btn" type="button" onClick={() => setEditing(r)}>
                        {s.edit}
                      </button>
                      <button className="btn" type="button" onClick={() => void undo(r)}>
                        {s.undo}
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  )
}
