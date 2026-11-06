import { useEffect, useRef, useState, type FormEvent } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Tables } from './types/database'

type Settings = Pick<
  Tables<'tenant'>,
  'currency_code' | 'locale' | 'time_zone' | 'date_format' | 'fiscal_year_start_month' | 'required_asset_fields' | 'asset_tag_pattern' | 'coverage_expiring_days' | 'obligation_due_soon_days'
>
type DbError = { code?: string; message?: string }

// Same lists as the checks in migration 2_5_tenant_settings_columns.
const dateFormats = ['dd-MM-yyyy', 'dd/MM/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'dd MMM yyyy'] as const
const optionalAssetFields = ['serial_number', 'manufacturer', 'model', 'location', 'purchase_date', 'purchase_value', 'in_service_date'] as const

// A date in one of the tenant date formats. Month names follow the tenant locale.
export function formatDate(date: Date, format: string, locale: string): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return format
    .replace('yyyy', String(date.getFullYear()))
    .replace('MMM', new Intl.DateTimeFormat(locale, { month: 'short' }).format(date))
    .replace('MM', pad(date.getMonth() + 1))
    .replace('dd', pad(date.getDate()))
}

function errorMessage(error: DbError): string {
  const e = t.settings.errors
  if (error.code === '42501') return e.noPermission
  if (error.code === '22023') return e.timeZone
  if (error.code === '23514') return e.invalid
  return e.generic
}

// Preview and save errors from preview_asset_tag and set_asset_tag_pattern (migrations 3_1, 3_8).
export function tagErrorMessage(error: DbError): string {
  const e = t.settings.tag.errors
  if (error.code === '23514') return e.format
  if (error.code === '22023') return error.message?.includes('location code') ? e.needsLocation : e.needsCategory
  if (error.code === '42501') return e.noPermission
  return e.generic
}

export const tagParts = ['{LOC}', '{CAT}', '{DATE:yyyymm}', '{SEQ:4}'] as const
const partKey = (p: string) => p.slice(1).split(/[:}]/)[0] as keyof typeof t.settings.tag.partHelp

// The sample comes from the database, so it is the tag a real insert would get (no second renderer here).
function TagPatternCard({ initial, canManage }: { initial: string; canManage: boolean }) {
  const [pattern, setPatternValue] = useState(initial)
  const [saved, setSaved] = useState(initial)
  const [ok, setOk] = useState(false)
  const [locations, setLocations] = useState<{ id: string; name: string }[]>([])
  const [categories, setCategories] = useState<{ id: string; name: string }[]>([])
  const [locationId, setLocationId] = useState('')
  const [categoryId, setCategoryId] = useState('')
  const [sample, setSample] = useState<{ tag?: string; error?: string }>({})
  const [saveError, setSaveError] = useState<string>()
  const [saving, setSaving] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  // An edit after saving makes the "saved" message stale.
  const setPattern = (p: string) => {
    setPatternValue(p)
    setOk(false)
  }

  useEffect(() => {
    let live = true
    // RLS gives empty lists to a user who cannot view them; the sample then works without.
    void Promise.all([
      supabase.from('location').select('id, name').is('deleted_at', null).order('name'),
      supabase.from('asset_category').select('id, name').is('deleted_at', null).order('name'),
    ]).then(([l, c]) => {
      if (!live) return
      setLocations(l.data ?? [])
      setCategories(c.data ?? [])
    })
    return () => {
      live = false
    }
  }, [])

  useEffect(() => {
    let live = true
    const timer = setTimeout(() => {
      void supabase
        .rpc('preview_asset_tag', { p_pattern: pattern, p_location_id: locationId || undefined, p_category_id: categoryId || undefined })
        .then(({ data, error }) => {
          if (live) setSample(error ? { error: tagErrorMessage(error) } : { tag: data ?? '' })
        })
    }, 300)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [pattern, locationId, categoryId])

  function insert(part: string) {
    const el = input.current
    const at = el?.selectionStart ?? pattern.length
    const end = el?.selectionEnd ?? at
    setPattern(pattern.slice(0, at) + part + pattern.slice(end))
    el?.focus()
  }

  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    setSaveError(undefined)
    setSaving(true)
    const { error } = await supabase.rpc('set_asset_tag_pattern', { p_pattern: pattern })
    setSaving(false)
    if (error) return setSaveError(tagErrorMessage(error))
    setSaved(pattern)
    setOk(true)
  }

  return (
    <form className="card" onSubmit={save}>
      <h2>{t.settings.tag.title}</h2>
      <p className="muted">{t.settings.tag.newOnly}</p>
      <label className="field">
        {t.settings.tag.pattern}
        <input
          ref={input}
          name="tagPattern"
          value={pattern}
          onChange={(e) => setPattern(e.target.value)}
          disabled={!canManage}
          required
          maxLength={60}
          spellCheck={false}
          aria-describedby="tag-hint"
        />
        <span id="tag-hint" className="muted hint">
          {t.settings.tag.hint}
        </span>
      </label>
      {canManage && (
        <div className="chips" role="group" aria-label={t.settings.tag.parts}>
          {tagParts.map((p) => (
            <button key={p} className="btn" type="button" title={t.settings.tag.partHelp[partKey(p)]} onClick={() => insert(p)}>
              {p}
            </button>
          ))}
        </div>
      )}
      <ul className="muted hint">
        {tagParts.map((p) => (
          <li key={p}>
            <code>{p}</code> {t.settings.tag.partHelp[partKey(p)]}
          </li>
        ))}
      </ul>
      <label className="field">
        {t.settings.tag.sampleLocation}
        <select name="sampleLocation" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
          <option value="">{t.settings.tag.noSample}</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name}
            </option>
          ))}
        </select>
      </label>
      <label className="field">
        {t.settings.tag.sampleCategory}
        <select name="sampleCategory" value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
          <option value="">{t.settings.tag.noSample}</option>
          {categories.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </label>
      <div aria-live="polite">
        {sample.error ? (
          <p className="login-error">{sample.error}</p>
        ) : (
          <p>
            {t.settings.tag.sample}: <strong>{sample.tag}</strong>
          </p>
        )}
      </div>
      {canManage && (
        <div className="page-head">
          <div className="spacer" />
          {ok && (
            <span className="save-ok" role="status">
              ✓ {t.settings.tag.saved}
            </span>
          )}
          {saveError && (
            <span className="login-error save-error" role="alert">
              {saveError}
            </span>
          )}
          <button className="btn btn-main" type="submit" disabled={saving || saved === pattern}>
            {saving ? t.settings.saving : t.settings.tag.save}
          </button>
        </div>
      )}
    </form>
  )
}

// Shape of public.ai_usage() (migration 10_2_ai_usage). It returns jsonb, so the generated type is Json.
export type AiUsage = {
  cap_micro_usd: number
  spent_micro_usd: number
  features: { feature: string; calls: number; spent_micro_usd: number }[]
  calls: { id: string; created_at: string; user_name: string | null; feature: string; status: string; input_tokens: number | null; output_tokens: number | null; cost_micro_usd: number }[]
}

const usd = new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 6 })
export const microUsd = (micro: number) => usd.format(micro / 1e6)
const statusTone: Record<string, string> = { ok: 'ok', started: 'warn', error: 'error', lost: 'error' }

function AiUsageTab({ usage, timeZone }: { usage: AiUsage; timeZone?: string }) {
  const a = t.settings.ai
  const label = (map: Record<string, string>, key: string) => map[key] ?? key
  const when = (iso: string) => new Date(iso).toLocaleString(undefined, { timeZone, dateStyle: 'medium', timeStyle: 'short' })
  const share = Math.min(1, usage.spent_micro_usd / usage.cap_micro_usd)
  return (
    <div className="stack">
      <section className="card">
        <h2>{a.spend}</h2>
        <p>
          <strong>{a.ofCap.replace('{spent}', microUsd(usage.spent_micro_usd)).replace('{cap}', microUsd(usage.cap_micro_usd))}</strong>
        </p>
        <span className="bar" role="meter" aria-label={a.spend} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(share * 100)}>
          <i style={{ width: `${share * 100}%` }} />
        </span>
        <p className="muted hint">{a.capHint}</p>
      </section>
      <section className="card">
        <h2>{a.perFeature}</h2>
        {usage.features.length === 0 ? (
          <p className="muted">{a.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{a.feature}</th>
                <th>{a.calls}</th>
                <th>{a.cost}</th>
              </tr>
            </thead>
            <tbody>
              {usage.features.map((f) => (
                <tr key={f.feature}>
                  <td>{label(a.features, f.feature)}</td>
                  <td>{f.calls.toLocaleString()}</td>
                  <td>{microUsd(f.spent_micro_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
      <section className="card">
        <h2>{a.last}</h2>
        {usage.calls.length === 0 ? (
          <p className="muted">{a.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{a.when}</th>
                <th>{a.who}</th>
                <th>{a.feature}</th>
                <th>{a.status}</th>
                <th>{a.tokens}</th>
                <th>{a.cost}</th>
              </tr>
            </thead>
            <tbody>
              {usage.calls.map((c) => (
                <tr key={c.id}>
                  <td>{when(c.created_at)}</td>
                  <td>{c.user_name ?? '—'}</td>
                  <td>{label(a.features, c.feature)}</td>
                  <td>
                    <span className={`tag ${statusTone[c.status] ?? ''}`}>{label(a.statuses, c.status)}</span>
                  </td>
                  <td>{c.input_tokens == null ? '—' : `${c.input_tokens.toLocaleString()} / ${(c.output_tokens ?? 0).toLocaleString()}`}</td>
                  <td>{microUsd(c.cost_micro_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  )
}

// The current value stays pickable even if this browser's list does not have it.
const withValue = (list: string[], value: string) => (list.includes(value) ? list : [value, ...list])

export function SettingsPage({ tenantId, canView, canManage, canViewAi = false }: { tenantId: string; canView: boolean; canManage: boolean; canViewAi?: boolean }) {
  const [settings, setSettings] = useState<Settings>()
  const [tab, setTab] = useState<'general' | 'ai'>('general')
  // null from ai_usage() means no right or no AI add-on: no tab (10.2).
  const [usage, setUsage] = useState<AiUsage | null>(null)
  const [error, setError] = useState<string>()
  const [saveError, setSaveError] = useState<string>()
  const [saved, setSaved] = useState(false)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!canView) return
    let live = true
    void supabase
      .from('tenant')
      .select('currency_code, locale, time_zone, date_format, fiscal_year_start_month, required_asset_fields, asset_tag_pattern, coverage_expiring_days, obligation_due_soon_days')
      .eq('id', tenantId)
      .then(({ data, error }) => {
        if (!live) return
        setSettings(data?.[0])
        if (error) setError(t.settings.errors.load)
      })
    return () => {
      live = false
    }
  }, [tenantId, canView])

  useEffect(() => {
    if (!canViewAi) return
    let live = true
    void supabase.rpc('ai_usage').then(({ data }) => {
      if (live) setUsage(data as AiUsage | null)
    })
    return () => {
      live = false
    }
  }, [tenantId, canViewAi])
  const shown = usage && canViewAi ? tab : 'general'

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    setSaveError(undefined)
    setSaved(false)
    const form = new FormData(e.currentTarget)
    const values: Settings = {
      currency_code: String(form.get('currency')),
      locale: String(form.get('locale')).trim(),
      time_zone: String(form.get('timeZone')),
      date_format: String(form.get('dateFormat')),
      fiscal_year_start_month: Number(form.get('fiscalMonth')),
      required_asset_fields: optionalAssetFields.filter((f) => form.get(f) === 'on'),
      asset_tag_pattern: settings?.asset_tag_pattern ?? '',
      coverage_expiring_days: Number(form.get('expiringDays')),
      obligation_due_soon_days: Number(form.get('dueSoonDays')),
    }
    setSaving(true)
    const { error } = await supabase.rpc('update_tenant_settings', {
      p_currency_code: values.currency_code,
      p_locale: values.locale,
      p_time_zone: values.time_zone,
      p_date_format: values.date_format,
      p_fiscal_year_start_month: values.fiscal_year_start_month,
      p_required_asset_fields: values.required_asset_fields,
      p_coverage_expiring_days: values.coverage_expiring_days,
      p_obligation_due_soon_days: values.obligation_due_soon_days,
    })
    setSaving(false)
    if (error) return setSaveError(errorMessage(error))
    setSettings(values)
    setSaved(true)
  }

  const s = settings
  const sample = new Date(2026, 2, 31)
  const months = Array.from({ length: 12 }, (_, i) =>
    new Intl.DateTimeFormat(s?.locale ?? 'en', { month: 'long' }).format(new Date(2026, i, 1)),
  )

  return (
    <>
      <title>{`${t.pages.settings} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.settings}</h1>
          <span className="muted">{t.settings.subtitle}</span>
        </div>
      </div>
      {usage && canViewAi && (
        <div className="tabs" role="tablist">
          {(['general', 'ai'] as const).map((k) => (
            <button key={k} type="button" role="tab" aria-selected={shown === k} className={shown === k ? 'on' : ''} onClick={() => setTab(k)}>
              {t.settings.tabs[k]}
            </button>
          ))}
        </div>
      )}
      {shown === 'ai' && usage && <AiUsageTab usage={usage} timeZone={settings?.time_zone} />}
      {shown === 'general' && !canView && <p className="muted">{t.settings.noAccess}</p>}
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {shown === 'general' && s && (
        // key: remount the uncontrolled inputs when the saved values come back.
        // onChange: an edit after saving makes the "saved" message stale.
        <form key={JSON.stringify(s)} className="stack" onSubmit={submit} onChange={() => setSaved(false)}>
          <fieldset className="card" disabled={!canManage}>
            <h2>{t.settings.regional}</h2>
            <label className="field">
              {t.settings.currency}
              <select name="currency" defaultValue={s.currency_code}>
                {withValue(Intl.supportedValuesOf('currency'), s.currency_code).map((c) => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
            <label className="field">
              {t.settings.locale}
              <input name="locale" defaultValue={s.locale} required pattern="[a-z]{2,3}(-[A-Z]{2})?" aria-describedby="locale-hint" />
              <span id="locale-hint" className="muted hint">
                {t.settings.localeHint}
              </span>
            </label>
            <label className="field">
              {t.settings.timeZone}
              <select name="timeZone" defaultValue={s.time_zone}>
                {withValue(Intl.supportedValuesOf('timeZone'), s.time_zone).map((z) => (
                  <option key={z}>{z}</option>
                ))}
              </select>
            </label>
            <label className="field">
              {t.settings.dateFormat}
              <select name="dateFormat" defaultValue={s.date_format}>
                {dateFormats.map((f) => (
                  <option key={f} value={f}>
                    {`${f} (${formatDate(sample, f, s.locale)})`}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              {t.settings.fiscalMonth}
              <select name="fiscalMonth" defaultValue={s.fiscal_year_start_month}>
                {months.map((m, i) => (
                  <option key={m} value={i + 1}>
                    {m}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              {t.settings.expiringDays}
              <input name="expiringDays" type="number" min={1} max={365} step={1} required defaultValue={s.coverage_expiring_days} aria-describedby="expiring-hint" />
              <span id="expiring-hint" className="muted hint">
                {t.settings.expiringDaysHint}
              </span>
            </label>
            <label className="field">
              {t.settings.dueSoonDays}
              <input name="dueSoonDays" type="number" min={1} max={365} step={1} required defaultValue={s.obligation_due_soon_days} aria-describedby="due-soon-hint" />
              <span id="due-soon-hint" className="muted hint">
                {t.settings.dueSoonDaysHint}
              </span>
            </label>
          </fieldset>
          <fieldset className="card" disabled={!canManage}>
            <h2>{t.settings.mandatory}</h2>
            <p className="muted">{t.settings.mandatoryHint}</p>
            {optionalAssetFields.map((f) => (
              <label key={f} className="check">
                <input name={f} type="checkbox" defaultChecked={s.required_asset_fields.includes(f)} />
                {t.settings.assetFields[f]}
              </label>
            ))}
          </fieldset>
          {canManage && (
            <div className="page-head">
              <div className="spacer" />
              {/* Next to the button, where the user is looking when they save. */}
              {saved && (
                <span className="save-ok" role="status">
                  ✓ {t.settings.saved}
                </span>
              )}
              {saveError && (
                <span className="login-error save-error" role="alert">
                  {saveError}
                </span>
              )}
              <button className="btn btn-main" type="submit" disabled={saving}>
                {saving ? t.settings.saving : t.settings.save}
              </button>
            </div>
          )}
        </form>
      )}
      {/* Own form and Save: a different action (set_asset_tag_pattern), and not a remount on the other save. */}
      {shown === 'general' && s && <TagPatternCard initial={s.asset_tag_pattern} canManage={canManage} />}
    </>
  )
}
