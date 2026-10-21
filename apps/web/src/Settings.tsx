import { useEffect, useState, type FormEvent } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Tables } from './types/database'

type Settings = Pick<
  Tables<'tenant'>,
  'currency_code' | 'locale' | 'time_zone' | 'date_format' | 'fiscal_year_start_month' | 'required_asset_fields'
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

// The current value stays pickable even if this browser's list does not have it.
const withValue = (list: string[], value: string) => (list.includes(value) ? list : [value, ...list])

export function SettingsPage({ tenantId, canView, canManage }: { tenantId: string; canView: boolean; canManage: boolean }) {
  const [settings, setSettings] = useState<Settings>()
  const [error, setError] = useState<string>()
  const [saveError, setSaveError] = useState<string>()
  const [saved, setSaved] = useState(false)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!canView) return
    let live = true
    void supabase
      .from('tenant')
      .select('currency_code, locale, time_zone, date_format, fiscal_year_start_month, required_asset_fields')
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
    }
    setSaving(true)
    const { error } = await supabase.rpc('update_tenant_settings', {
      p_currency_code: values.currency_code,
      p_locale: values.locale,
      p_time_zone: values.time_zone,
      p_date_format: values.date_format,
      p_fiscal_year_start_month: values.fiscal_year_start_month,
      p_required_asset_fields: values.required_asset_fields,
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
      {!canView && <p className="muted">{t.settings.noAccess}</p>}
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {s && (
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
    </>
  )
}
