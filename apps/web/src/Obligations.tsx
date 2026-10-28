import { Fragment, useEffect, useState, type FormEvent } from 'react'
import { addDays, showDate, tenantToday, terms, useTenant } from './Coverage'
import { t } from './i18n'
import { CompletionForm } from './Service'
import { supabase } from './supabase'
import { lineage } from './tree'
import type { Json, Tables, TablesInsert } from './types/database'

// Story 5.1b: the asset Obligations tab and the category defaults editor (data-model-goal5.md §7).
type Obligation = Tables<'obligation'>
type Can = (domain: string, operation: string) => boolean
type DbError = { code?: string; message?: string }
export type Rule = { name: string; obligation_type: string; interval_count: number; interval_unit: string; anchor: string }

const o = t.obligations
export const obligationTypes = ['service', 'calibration', 'inspection', 'certificate'] as const
export const units = ['day', 'week', 'month', 'year'] as const
const anchors = ['completion', 'fixed'] as const

// OQ-03: statutory items keep fixed dates; service counts from the last completion.
export const defaultAnchor = (type: string) => (type === 'service' ? 'completion' : 'fixed')

// "Every 3 months · from last completion".
export function ruleText(r: Pick<Rule, 'interval_count' | 'interval_unit' | 'anchor'>): string {
  const unit = r.interval_unit as (typeof units)[number]
  const every = r.interval_count === 1 ? o.everyOne.replace('{unit}', o.units[unit] ?? unit) : o.every.replace('{n}', String(r.interval_count)).replace('{unit}', o.unitsMany[unit] ?? unit)
  return `${every} · ${(o.anchors as Record<string, string>)[r.anchor] ?? r.anchor}`
}

const tones: Record<string, string> = { overdue: 'error', due_soon: 'warn', scheduled: 'ok', paused: 'neutral' }
export const stateTone = (state: string) => tones[state] ?? 'neutral'

// The same checks as the obligation columns (5.1). The database still checks.
export function validateRule(r: Rule): string | undefined {
  const name = r.name.trim()
  if (name.length < 1 || name.length > 80) return o.errors.name
  if (!(obligationTypes as readonly string[]).includes(r.obligation_type)) return o.errors.type
  if (!Number.isInteger(r.interval_count) || r.interval_count < 1 || r.interval_count > 999) return o.errors.interval
  if (!(units as readonly string[]).includes(r.interval_unit)) return o.errors.unit
  if (!(anchors as readonly string[]).includes(r.anchor)) return o.errors.anchor
  return undefined
}

// Category list: each rule valid, names unique ignoring case (as check_category_defaults).
export function validateRules(rules: Rule[]): string | undefined {
  for (const r of rules) {
    const bad = validateRule(r)
    if (bad) return bad
  }
  return new Set(rules.map((r) => r.name.trim().toLowerCase())).size === rules.length ? undefined : o.errors.duplicate
}

export function obligationError(e: DbError): string {
  if (e.code === '42501') return o.errors.noPermission
  if (e.code === '23505') return o.errors.duplicate
  if (e.code === '23514') return o.errors.invalid
  return o.errors.generic
}

// A date plus n units; months and years clamp to the month end (as Postgres: 31 Jan + 1 month = 28 Feb).
export function addStep(d: string, n: number, unit: string): string {
  if (unit === 'day' || unit === 'week') return addDays(d, unit === 'week' ? 7 * n : n)
  const months = unit === 'year' ? 12 * n : n
  const y = Number(d.slice(0, 4))
  const m = Number(d.slice(5, 7)) - 1 + months
  const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate()
  return new Date(Date.UTC(y, m, Math.min(Number(d.slice(8, 10)), last))).toISOString().slice(0, 10)
}

// O4: the first base + k × interval (k >= 1) on or after today. Each slot from the base, so no drift.
export function firstDue(base: string, count: number, unit: string, today: string): string {
  if (!(count >= 1)) return ''
  for (let k = 1; ; k++) {
    const d = addStep(base, k * count, unit)
    if (d >= today) return d
  }
}

const loadObligations = (assetId: string) =>
  supabase.from('obligation').select('*').eq('asset_id', assetId).is('deleted_at', null).order('next_due_date').order('name')

export function StateTag({ state }: { state: string }) {
  return <span className={`tag status ${stateTone(state)}`}>{(o.states as Record<string, string>)[state] ?? state}</span>
}

type AssetDates = { in_service_date: string | null; purchase_date: string | null }

export function ObligationsTab({ tenantId, assetId, asset, can }: { tenantId: string; assetId: string; asset: AssetDates; can: Can }) {
  const tenant = useTenant()
  const [rows, setRows] = useState<Obligation[]>()
  const [editing, setEditing] = useState<{ row?: Obligation }>()
  const [completing, setCompleting] = useState<Obligation>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    void loadObligations(assetId).then(({ data, error }) => {
      if (!live) return
      setRows(data ?? [])
      if (error) setError(o.errors.load)
    })
    return () => {
      live = false
    }
  }, [assetId, reload])

  async function write(q: PromiseLike<{ data: unknown[] | null; error: DbError | null }>) {
    setError(undefined)
    const { data, error } = await q
    // An update RLS filters out returns no rows and no error.
    if (error || !data?.length) {
      setError(obligationError(error ?? { code: '42501' }))
      return false
    }
    setEditing(undefined)
    setReload((n) => n + 1)
    return true
  }

  if (!rows || !tenant) return <p className="muted" role="status">{o.loading}</p>
  const today = tenantToday(tenant.time_zone)
  const canUpdate = can('obligation', 'update')
  const canComplete = can('obligation', 'complete')
  const update = (id: string, v: Partial<Obligation>) => write(supabase.from('obligation').update(v).eq('id', id).select('id'))

  return (
    <div className="stack detail">
      <div className="page-head">
        <div className="spacer" />
        {can('obligation', 'create') && (
          <button className="btn btn-main" type="button" onClick={() => setEditing({})}>
            {o.add}
          </button>
        )}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {completing && (
        <CompletionForm
          obligation={completing}
          can={can}
          onCancel={() => setCompleting(undefined)}
          onDone={() => {
            setCompleting(undefined)
            setReload((n) => n + 1)
          }}
        />
      )}
      {editing && (
        <ObligationForm
          row={editing.row}
          base={asset.in_service_date ?? asset.purchase_date ?? today}
          today={today}
          onError={setError}
          onCancel={() => {
            setEditing(undefined)
            setError(undefined)
          }}
          onSave={(v) =>
            editing.row
              ? update(editing.row.id, v)
              : // next_due_date is set by trigger (no insert grant); the generated Insert type still requires it.
              write(supabase.from('obligation').insert({ ...v, tenant_id: tenantId, asset_id: assetId } as TablesInsert<'obligation'>).select('id'))
          }
        />
      )}
      <div className="card table-wrap list obligations">
        {rows.length === 0 ? (
          <div className="page-head">
            <p className="muted">{o.none}</p>
            <div className="spacer" />
            {can('obligation', 'create') && !editing && (
              <button className="btn" type="button" onClick={() => setEditing({})}>
                {o.add}
              </button>
            )}
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{o.col.name}</th>
                <th>{o.col.rule}</th>
                <th>{o.col.lastDone}</th>
                <th>{o.col.nextDue}</th>
                <th>{o.col.status}</th>
                {(canUpdate || canComplete) && <th aria-label={o.col.actions} />}
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>
                    {r.name} <span className="muted">{(o.types as Record<string, string>)[r.obligation_type] ?? r.obligation_type}</span>
                  </td>
                  <td>{ruleText(r)}</td>
                  <td>{showDate(r.last_done_date, tenant)}</td>
                  <td>{showDate(r.next_due_date, tenant)}</td>
                  <td>
                    <StateTag state={r.due_state} />
                  </td>
                  {(canUpdate || canComplete) && (
                    <td className="actions">
                      {/* Paused rows cannot be completed (complete_obligation refuses them too). */}
                      {canComplete && r.due_state !== 'paused' && (
                        <button className="btn btn-main" type="button" onClick={() => setCompleting(r)}>
                          {o.recordCompletion}
                        </button>
                      )}
                      {canUpdate && (
                        <>
                      <button className="btn" type="button" onClick={() => setEditing({ row: r })}>
                        {t.categories.edit}
                      </button>
                      <button className="btn" type="button" onClick={() => void update(r.id, { is_active: !r.is_active })}>
                        {r.is_active ? o.pause : o.resume}
                      </button>
                      <button
                        className="btn"
                        type="button"
                        onClick={() => window.confirm(o.removeConfirm.replace('{name}', r.name)) && void update(r.id, { deleted_at: new Date().toISOString() })}
                      >
                        {o.remove}
                      </button>
                        </>
                      )}
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

type Values = Rule & { first_due_date: string; notes: string | null; last_done_date?: string | null }

function ObligationForm({
  row,
  base,
  today,
  onSave,
  onCancel,
  onError,
}: {
  row?: Obligation
  base: string
  today: string
  onSave: (v: Values) => Promise<boolean>
  onCancel: () => void
  onError: (message: string) => void
}) {
  const [rule, setRule] = useState<Rule>({
    name: row?.name ?? '',
    obligation_type: row?.obligation_type ?? 'service',
    interval_count: row?.interval_count ?? 3,
    interval_unit: row?.interval_unit ?? 'month',
    anchor: row?.anchor ?? 'completion',
  })
  // A new rule suggests its first due (O4) until the user types one.
  const [due, setDue] = useState({ value: row?.first_due_date ?? firstDue(base, 3, 'month', today), byHand: !!row })
  const change = (ch: Partial<Rule>) => {
    const next = { ...rule, ...ch }
    setRule(next)
    if (!due.byHand) setDue({ value: firstDue(base, next.interval_count, next.interval_unit, today), byHand: false })
  }

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const bad = validateRule(rule) ?? (due.value ? undefined : o.errors.firstDue)
    if (bad) return onError(bad)
    const form = new FormData(e.currentTarget)
    const v: Values = { ...rule, name: rule.name.trim(), first_due_date: due.value, notes: String(form.get('notes')).trim() || null }
    // last_done_date is insert-only (5.1 grants); after that only complete_obligation (5.2) moves it.
    void onSave(row ? v : { ...v, last_done_date: String(form.get('last_done')) || null })
  }

  return (
    <form className="card" onSubmit={submit} noValidate>
      <h2>{row ? o.edit : o.add}</h2>
      <label className="field">
        {o.name}
        <input name="name" value={rule.name} maxLength={80} onChange={(e) => change({ name: e.target.value })} />
      </label>
      <label className="field">
        {o.type}
        <select name="type" value={rule.obligation_type} onChange={(e) => change({ obligation_type: e.target.value, anchor: defaultAnchor(e.target.value) })}>
          {obligationTypes.map((x) => (
            <option key={x} value={x}>
              {o.types[x]}
            </option>
          ))}
        </select>
      </label>
      <RuleInterval rule={rule} onChange={change} />
      <label className="field">
        {o.firstDue}
        <input name="first_due" type="date" value={due.value} aria-describedby="first-due-hint" onChange={(e) => setDue({ value: e.target.value, byHand: true })} />
        {!row && (
          <span id="first-due-hint" className="muted hint">
            {o.firstDueHint}
          </span>
        )}
      </label>
      <label className="field">
        {o.lastDone}
        <input name="last_done" type="date" defaultValue={row?.last_done_date ?? ''} disabled={!!row} max={today} aria-describedby={row ? 'last-done-hint' : undefined} />
        {row && (
          <span id="last-done-hint" className="muted hint">
            {o.lastDoneLocked}
          </span>
        )}
      </label>
      <label className="field">
        {o.notes}
        <textarea name="notes" rows={3} maxLength={2000} defaultValue={row?.notes ?? ''} />
      </label>
      <div className="page-head">
        <div className="spacer" />
        <button className="btn" type="button" onClick={onCancel}>
          {o.cancel}
        </button>
        <button className="btn btn-main" type="submit">
          {o.save}
        </button>
      </div>
    </form>
  )
}

// Every N unit, and the anchor. Shared by the asset form and the category defaults.
function RuleInterval({ rule, onChange, label = '' }: { rule: Rule; onChange: (ch: Partial<Rule>) => void; label?: string }) {
  return (
    <>
      <label className="field">
        {o.interval}
        <input type="number" min={1} max={999} step={1} aria-label={`${label}${o.interval}`} value={Number.isNaN(rule.interval_count) ? '' : rule.interval_count} onChange={(e) => onChange({ interval_count: e.target.valueAsNumber })} />
      </label>
      <label className="field">
        {o.unit}
        <select aria-label={`${label}${o.unit}`} value={rule.interval_unit} onChange={(e) => onChange({ interval_unit: e.target.value })}>
          {units.map((x) => (
            <option key={x} value={x}>
              {o.unitsMany[x]}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        {o.anchor}
        <select aria-label={`${label}${o.anchor}`} value={rule.anchor} onChange={(e) => onChange({ anchor: e.target.value })}>
          {anchors.map((x) => (
            <option key={x} value={x}>
              {o.anchors[x]}
            </option>
          ))}
        </select>
      </label>
    </>
  )
}

// Overview card, as the screens: name and state. Hidden when there are none.
export function ObligationsCard({ assetId, onRecord }: { assetId: string; onRecord?: () => void }) {
  const [rows, setRows] = useState<Obligation[]>([])
  useEffect(() => {
    let live = true
    void loadObligations(assetId).then(({ data }) => live && setRows(data ?? []))
    return () => {
      live = false
    }
  }, [assetId])
  if (rows.length === 0) return null
  return (
    <section className="card">
      <h2>{o.title}</h2>
      <dl className="kv">
        {rows.map((r) => (
          <Fragment key={r.id}>
            <dt>{r.name}</dt>
            <dd>
              <StateTag state={r.due_state} />
            </dd>
          </Fragment>
        ))}
      </dl>
      {onRecord && (
        <button className="btn btn-main block" type="button" onClick={onRecord}>
          {o.recordCompletion}
        </button>
      )}
    </section>
  )
}

// Category defaults (O2): each is null = inherit from the nearest parent that sets it.
type DefaultsCategory = { id: string; parent_id: string | null; name: string; default_obligations: Json | null; default_warranty_months: number | null }
export type Defaults = { warranty: number | null; rules: Rule[] | null }
export const asRules = (j: Json | null | undefined): Rule[] | null => (Array.isArray(j) ? (j as Rule[]) : null)

export function inheritedDefaults(categories: DefaultsCategory[], parentId: string) {
  const up = parentId ? lineage(categories, parentId).map((id) => categories.find((c) => c.id === id)) : []
  const w = up.find((c) => c?.default_warranty_months != null)
  const r = up.find((c) => c?.default_obligations != null)
  return { warranty: w?.default_warranty_months ?? null, warrantyFrom: w?.name, rules: asRules(r?.default_obligations) ?? [], rulesFrom: r?.name }
}

const blankRule = (): Rule => ({ name: '', obligation_type: 'service', interval_count: 3, interval_unit: 'month', anchor: 'completion' })

export function CategoryDefaults({ categories, parentId, value, onChange }: { categories: DefaultsCategory[]; parentId: string; value: Defaults; onChange: (v: Defaults) => void }) {
  const s = t.categories.defaults
  const up = inheritedDefaults(categories, parentId)
  const months = (n: number | null) => (n ? t.coverage.months.replace('{n}', String(n)) : s.noWarranty)
  const rules = value.rules
  const setRule = (i: number, ch: Partial<Rule>) => rules && onChange({ ...value, rules: rules.map((r, j) => (j === i ? { ...r, ...ch } : r)) })

  return (
    <fieldset className="field set">
      <legend>{s.title}</legend>
      <span className="muted hint">{s.hint}</span>
      <label className="field">
        {s.warranty}
        <select value={value.warranty ?? ''} onChange={(e) => onChange({ ...value, warranty: e.target.value === '' ? null : Number(e.target.value) })}>
          <option value="">{s.inheritWarranty}</option>
          <option value={0}>{s.noWarranty}</option>
          {terms.map((n) => (
            <option key={n} value={n}>
              {months(n)}
            </option>
          ))}
        </select>
        {value.warranty === null && (
          <span className="muted hint">{up.warrantyFrom ? s.inheritedFrom.replace('{name}', up.warrantyFrom).replace('{value}', months(up.warranty)) : s.inheritedNone}</span>
        )}
      </label>
      <b>{s.obligations}</b>
      <label className="check">
        <input type="radio" name="rules-mode" checked={rules === null} onChange={() => onChange({ ...value, rules: null })} />
        {s.inherit}
      </label>
      <label className="check">
        <input type="radio" name="rules-mode" checked={rules !== null} onChange={() => onChange({ ...value, rules: up.rules })} />
        {s.own}
      </label>
      {rules === null ? (
        <>
          <span className="muted hint">{up.rulesFrom ? s.rulesFrom.replace('{name}', up.rulesFrom) : s.inheritedNone}</span>
          <ul className="set-list">
            {up.rules.map((r) => (
              <li key={r.name}>
                {r.name} <span className="muted">{ruleText(r)}</span>
              </li>
            ))}
          </ul>
        </>
      ) : (
        <>
          {rules.length === 0 && <p className="muted hint">{s.noRules}</p>}
          {rules.map((r, i) => {
            const label = `${s.ruleLabel.replace('{n}', String(i + 1))} `
            return (
              <div key={i} className="rule-row">
                <label className="field">
                  {o.name}
                  <input aria-label={`${label}${o.name}`} value={r.name} maxLength={80} onChange={(e) => setRule(i, { name: e.target.value })} />
                </label>
                <label className="field">
                  {o.type}
                  <select aria-label={`${label}${o.type}`} value={r.obligation_type} onChange={(e) => setRule(i, { obligation_type: e.target.value, anchor: defaultAnchor(e.target.value) })}>
                    {obligationTypes.map((x) => (
                      <option key={x} value={x}>
                        {o.types[x]}
                      </option>
                    ))}
                  </select>
                </label>
                <RuleInterval rule={r} label={label} onChange={(ch) => setRule(i, ch)} />
                <button className="btn" type="button" aria-label={`${s.remove} ${r.name}`} onClick={() => onChange({ ...value, rules: rules.filter((_, j) => j !== i) })}>
                  {s.remove}
                </button>
              </div>
            )
          })}
          <div className="page-head">
            <button className="btn" type="button" disabled={rules.length >= 20} onClick={() => onChange({ ...value, rules: [...rules, blankRule()] })}>
              {s.addRule}
            </button>
          </div>
        </>
      )}
    </fieldset>
  )
}
