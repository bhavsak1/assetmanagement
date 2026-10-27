import { Fragment, useEffect, useState, type FormEvent } from 'react'
import { Link, useSearchParams } from 'react-router'
import { formatDate } from './Settings'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Database, Tables } from './types/database'

type Coverage = Tables<'coverage_view'>
type Line = Database['public']['Functions']['asset_coverage']['Returns'][number]
type Vendor = { id: string; name: string; is_active: boolean }
type AssetRef = { id: string; tag: string; name: string }
type Linked = AssetRef & { linkId?: string }
type Tenant = Pick<Tables<'tenant'>, 'currency_code' | 'time_zone' | 'date_format' | 'locale' | 'coverage_expiring_days'>
type Can = (domain: string, operation: string) => boolean
type DbError = { code?: string; message?: string }
export type Tab = 'all' | 'warranty' | 'amc' | 'expiring'
export type Cursor = { end: string; id: string }

const c = t.coverage
const PAGE = 50
// C1 system types; warranty and extended warranty form the warranty group (data-model-goal4 §21).
export const types = ['warranty', 'extended_warranty', 'amc', 'other'] as const
export const groups = ['warranty', 'amc', 'other'] as const
const tone: Record<string, string> = { active: 'ok', expiring: 'warn', expired: 'error', future: 'neutral' }
const rank = ['active', 'expiring', 'future', 'expired']
const typeLabel = (s: string | null) => (c.types as Record<string, string>)[s ?? ''] ?? s ?? ''

// Plain dates as YYYY-MM-DD. "Today" is the tenant's (C7), so the day counts match the status the view computed.
export const tenantToday = (timeZone: string, now = new Date()) =>
  new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
const utc = (d: string) => Date.UTC(Number(d.slice(0, 4)), Number(d.slice(5, 7)) - 1, Number(d.slice(8, 10)))
export const daysBetween = (from: string, to: string) => Math.round((utc(to) - utc(from)) / 86400000)
export const addDays = (d: string, n: number) => new Date(utc(d) + n * 86400000).toISOString().slice(0, 10)

// The status tag text: "Active", "Expires in 24 d", "Expires today", "Expired 3 d ago", "Starts in 5 d".
export function statusText(status: string | null, start: string | null, end: string | null, today: string): string {
  if (status === 'future' && start) return c.status.startsIn.replace('{n}', String(daysBetween(today, start)))
  if (status === 'expiring' && end) {
    const n = daysBetween(today, end)
    return n === 0 ? c.status.expiresToday : c.status.expiresIn.replace('{n}', String(n))
  }
  if (status === 'expired' && end) return c.status.expiredAgo.replace('{n}', String(daysBetween(end, today)))
  return (c.status as Record<string, string>)[status ?? ''] ?? status ?? ''
}

// Tab to the coverage_view filter: a type group or the live status.
export function tabFilter(tab: Tab): { types?: string[]; status?: string } {
  if (tab === 'warranty') return { types: ['warranty', 'extended_warranty'] }
  if (tab === 'amc') return { types: ['amc'] }
  if (tab === 'expiring') return { status: 'expiring' }
  return {}
}

// Keyset cursor after the last row shown, when the page came back full.
export function nextCursor(rows: Coverage[]): Cursor | undefined {
  const last = rows[PAGE - 1]
  return rows.length > PAGE && last?.end_date && last.id ? { end: last.end_date, id: last.id } : undefined
}

// The responsible vendor: the best row over all groups, ranked as asset_coverage() ranks within one.
export function bestLine(lines: Line[]): Line | undefined {
  return [...lines].sort((a, b) => rank.indexOf(a.status) - rank.indexOf(b.status) || b.end_date.localeCompare(a.end_date))[0]
}

export function coverageError(e: DbError): string {
  const m = e.message ?? ''
  if (e.code === '42501') return c.errors.noPermission
  if (m.includes('vendor')) return c.errors.vendor
  if (e.code === '23505') return c.errors.duplicateAsset
  if (m.includes('deleted or not found')) return c.errors.assetGone
  if (m.includes('end_date')) return c.errors.dates
  return c.errors.generic
}

const loadTenant = () => supabase.from('tenant').select('currency_code, time_zone, date_format, locale, coverage_expiring_days')
const loadVendors = async (): Promise<Vendor[]> =>
  ((await supabase.from('vendor_view').select('id, name, is_active').order('name')).data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '', is_active: x.is_active ?? false }))

// Assets linked to the given contracts, by contract. Only links to assets this user sees come back (RLS).
async function loadLinks(coverageIds: string[]): Promise<Record<string, Linked[]>> {
  if (!coverageIds.length) return {}
  const links = (await supabase.from('coverage_asset').select('id, coverage_id, asset_id').in('coverage_id', coverageIds).is('deleted_at', null)).data ?? []
  const ids = [...new Set(links.map((l) => l.asset_id))]
  const assets = ids.length ? ((await supabase.from('asset_view').select('id, tag, name').in('id', ids)).data ?? []) : []
  const out: Record<string, Linked[]> = {}
  for (const l of links) {
    const a = assets.find((x) => x.id === l.asset_id)
    if (a) (out[l.coverage_id] ??= []).push({ id: l.asset_id, tag: a.tag ?? '', name: a.name ?? '', linkId: l.id })
  }
  return out
}

function useTenant() {
  const [tenant, setTenant] = useState<Tenant>()
  useEffect(() => {
    let live = true
    void loadTenant().then(({ data }) => live && setTenant(data?.[0]))
    return () => {
      live = false
    }
  }, [])
  return tenant
}

const showDate = (d: string | null | undefined, tn?: Tenant) =>
  !d ? '—' : tn ? formatDate(new Date(Number(d.slice(0, 4)), Number(d.slice(5, 7)) - 1, Number(d.slice(8, 10))), tn.date_format, tn.locale) : d

export function StatusTag({ row, today }: { row: { status: string | null; start_date: string | null; end_date: string | null }; today: string }) {
  return <span className={`tag status ${tone[row.status ?? ''] ?? 'neutral'}`}>{statusText(row.status, row.start_date, row.end_date, today)}</span>
}

function Hidden() {
  return <span className="tag">{c.hidden}</span>
}

export function CoveragePage({ tenantId, can }: { tenantId: string; can: Can }) {
  const [params, setParams] = useSearchParams()
  const [tab, setTab] = useState<Tab>('all')
  const [after, setAfter] = useState<Cursor>()
  const [rows, setRows] = useState<Coverage[]>()
  const [more, setMore] = useState<Cursor>()
  const [links, setLinks] = useState<Record<string, Linked[]>>({})
  const [counts, setCounts] = useState<Record<string, number>>({})
  // undefined until loaded: the form's vendor default needs its option to exist on first render.
  const [vendors, setVendors] = useState<Vendor[]>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)
  // ?id= opens a contract, ?asset= starts a new one for that asset (asset detail links).
  const openId = params.get('id')
  const forAsset = params.get('asset')
  const [open, setOpen] = useState<{ row?: Coverage; renew?: Coverage; assets?: Linked[] }>()
  const tenant = useTenant()
  const today = tenant ? tenantToday(tenant.time_zone) : ''

  useEffect(() => {
    let live = true
    void loadVendors().then((v) => live && setVendors(v))
    return () => {
      live = false
    }
  }, [reload])

  useEffect(() => {
    let live = true
    const head = { count: 'exact', head: true } as const
    void Promise.all(['active', 'expiring', 'expired'].map((s) => supabase.from('coverage_view').select('id', head).eq('status', s))).then((r) => {
      if (live) setCounts({ active: r[0]?.count ?? 0, expiring: r[1]?.count ?? 0, expired: r[2]?.count ?? 0 })
    })
    return () => {
      live = false
    }
  }, [reload])

  useEffect(() => {
    let live = true
    const f = tabFilter(tab)
    // Soonest end first on Expiring, latest end first elsewhere; (tenant_id, end_date, id) serves both.
    const asc = tab === 'expiring'
    let q = supabase.from('coverage_view').select('*')
    if (f.types) q = q.in('coverage_type', f.types)
    if (f.status) q = q.eq('status', f.status)
    if (after) q = q.or(`end_date.${asc ? 'gt' : 'lt'}.${after.end},and(end_date.eq.${after.end},id.${asc ? 'gt' : 'lt'}.${after.id})`)
    void q
      .order('end_date', { ascending: asc })
      .order('id', { ascending: asc })
      .limit(PAGE + 1)
      .then(async ({ data, error }) => {
        const page = data ?? []
        const l = await loadLinks(page.slice(0, PAGE).map((r) => r.id ?? ''))
        if (!live) return
        setRows((old) => [...(after ? (old ?? []) : []), ...page.slice(0, PAGE)])
        setLinks((old) => ({ ...(after ? old : {}), ...l }))
        setMore(nextCursor(page))
        setError(error ? c.errors.load : undefined)
      })
    return () => {
      live = false
    }
  }, [tab, after, reload])

  useEffect(() => {
    let live = true
    if (openId)
      void supabase
        .from('coverage_view')
        .select('*')
        .eq('id', openId)
        .then(({ data }) => live && setOpen(data?.[0] ? { row: data[0] } : undefined))
    else if (forAsset)
      void supabase
        .from('asset_view')
        .select('id, tag, name')
        .eq('id', forAsset)
        .then(({ data }) => live && setOpen({ assets: (data ?? []).map((a) => ({ id: a.id ?? '', tag: a.tag ?? '', name: a.name ?? '' })) }))
    return () => {
      live = false
    }
  }, [openId, forAsset, reload])

  function pickTab(next: Tab) {
    setTab(next)
    setAfter(undefined)
  }
  const refresh = () => {
    setAfter(undefined)
    setReload((n) => n + 1)
  }
  const show = (id: string) => {
    setParams({ id })
    setOpen(undefined)
  }
  const close = () => {
    setParams({})
    setOpen(undefined)
  }
  const vendorName = (id: string | null) => (can('vendor_core', 'view') ? (vendors?.find((v) => v.id === id)?.name ?? c.formerVendor) : <Hidden />)

  return (
    <>
      <title>{`${t.pages.coverage} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.coverage}</h1>
          <span className="muted">{c.subtitle}</span>
        </div>
        <div className="spacer" />
        {can('coverage_contract', 'create') && (
          <button className="btn btn-main" type="button" onClick={() => setOpen({})}>
            {c.add}
          </button>
        )}
      </div>
      <div className="kpis">
        <div className="card kpi">
          <span>{c.cards.active}</span>
          <b>{counts.active ?? '—'}</b>
        </div>
        <div className="card kpi">
          <span>{c.cards.expiring.replace('{n}', String(tenant?.coverage_expiring_days ?? ''))}</span>
          <b className="warn">{counts.expiring ?? '—'}</b>
        </div>
        <div className="card kpi">
          <span>{c.cards.expired}</span>
          <b className="error">{counts.expired ?? '—'}</b>
        </div>
      </div>
      {open && tenant && vendors && (
        <CoveragePanel
          key={`${open.row?.id ?? 'new'}-${open.renew?.id ?? ''}`}
          row={open.row}
          renew={open.renew}
          assets={open.assets}
          tenantId={tenantId}
          tenant={tenant}
          today={today}
          vendors={vendors}
          can={can}
          onSaved={(id) => {
            refresh()
            show(id)
          }}
          onRenew={(row, assets) => setOpen({ renew: row, assets })}
          onOpen={show}
          onDeleted={() => {
            refresh()
            close()
          }}
          onClose={close}
        />
      )}
      <div className="tabs" role="tablist">
        {(['all', 'warranty', 'amc', 'expiring'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => pickTab(k)}>
            {c.tabs[k]}
          </button>
        ))}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <div className="card table-wrap list detail">
        {rows === undefined ? (
          <p className="muted" role="status">
            {c.loading}
          </p>
        ) : rows.length === 0 ? (
          <p className="muted">{tab === 'all' ? c.none : c.noMatch}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{c.col.type}</th>
                <th>{c.col.asset}</th>
                <th>{c.col.scope}</th>
                <th>{c.col.vendor}</th>
                <th>{c.col.start}</th>
                <th>{c.col.end}</th>
                <th>{c.col.status}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const l = links[r.id ?? ''] ?? []
                return (
                  <tr key={r.id}>
                    <td>
                      <button className="row-link" type="button" onClick={() => show(r.id ?? '')}>
                        {typeLabel(r.coverage_type)}
                      </button>
                      {r.reference && <span className="muted"> {r.reference}</span>}
                    </td>
                    <td>{l[0] ? `${l[0].name}${l.length > 1 ? ` ${c.plus.replace('{n}', String(l.length - 1))}` : ''}` : '—'}</td>
                    <td>{l.length === 1 ? c.scopeOne : l.length ? c.scope.replace('{n}', String(l.length)) : c.noAssets}</td>
                    <td>{vendorName(r.vendor_id)}</td>
                    <td>{showDate(r.start_date, tenant)}</td>
                    <td>{showDate(r.end_date, tenant)}</td>
                    <td>{today && <StatusTag row={r} today={today} />}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
      {more && (
        <div className="page-head">
          <div className="spacer" />
          <button className="btn" type="button" onClick={() => setAfter(more)}>
            {c.more}
          </button>
        </div>
      )}
    </>
  )
}

// Add, view, edit and renew one contract, with its assets.
function CoveragePanel(props: {
  row?: Coverage
  renew?: Coverage
  assets?: Linked[]
  tenantId: string
  tenant: Tenant
  today: string
  vendors: Vendor[]
  can: Can
  onSaved: (id: string) => void
  onRenew: (row: Coverage, assets: Linked[]) => void
  onOpen: (id: string) => void
  onDeleted: () => void
  onClose: () => void
}) {
  const { row, renew, tenant, can } = props
  const base = row ?? renew
  const editable = row ? can('coverage_contract', 'update') : can('coverage_contract', 'create')
  // C5: a renewal starts the day after the old end and runs as long.
  const start = renew?.end_date ? addDays(renew.end_date, 1) : (row?.start_date ?? '')
  const end = renew?.start_date && renew.end_date ? addDays(start, daysBetween(renew.start_date, renew.end_date)) : (row?.end_date ?? '')
  // The trigger needs both to change the value (as purchase value, 3.3).
  const seeMoney = can('coverage_values', 'view')
  const canMoney = editable && seeMoney && can('coverage_values', 'update')
  const [links, setLinks] = useState<Linked[]>(props.assets ?? [])
  const [initial, setInitial] = useState<Linked[]>([])
  const [renewedBy, setRenewedBy] = useState<Coverage[]>([])
  const [error, setError] = useState<string>()
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!row?.id) return
    let live = true
    void Promise.all([loadLinks([row.id]), supabase.from('coverage_view').select('*').eq('renews_coverage_id', row.id)]).then(([l, r]) => {
      if (!live) return
      setLinks(l[row.id ?? ''] ?? [])
      setInitial(l[row.id ?? ''] ?? [])
      setRenewedBy(r.data ?? [])
    })
    return () => {
      live = false
    }
  }, [row?.id])

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const text = (k: string) => String(form.get(k) ?? '').trim() || null
    const value = text('contract_value')
    const payload = {
      coverage_type: String(form.get('coverage_type')),
      vendor_id: text('vendor_id') ?? '',
      reference: text('reference'),
      start_date: text('start_date') ?? '',
      end_date: text('end_date') ?? '',
      notes: text('notes'),
      ...(canMoney && { contract_value: value === null ? null : Number(value), contract_currency: value === null ? null : text('contract_currency') }),
    }
    if (!payload.vendor_id) return setError(c.errors.vendorRequired)
    if (!payload.start_date || !payload.end_date || payload.end_date < payload.start_date) return setError(c.errors.dates)
    if (value !== null && !(Number(value) >= 0)) return setError(c.errors.value)
    setBusy(true)
    setError(undefined)
    const write = row?.id
      ? await supabase.from('coverage').update(payload).eq('id', row.id).select('id')
      : await supabase.from('coverage').insert({ ...payload, tenant_id: props.tenantId, renews_coverage_id: renew?.id ?? null }).select('id')
    const id = write.data?.[0]?.id
    if (write.error || !id) {
      setBusy(false)
      return setError(coverageError(write.error ?? { code: '42501' }))
    }
    // Links: add new ones first, so the contract stays visible while old ones go (OQ-26).
    const added = links.filter((l) => !l.linkId)
    const removed = initial.filter((l) => !links.some((x) => x.linkId === l.linkId)).map((l) => l.linkId ?? '')
    const ins = added.length
      ? await supabase.from('coverage_asset').insert(added.map((l) => ({ tenant_id: props.tenantId, coverage_id: id, asset_id: l.id }))).select('id')
      : { error: null }
    const del = !ins.error && removed.length ? await supabase.from('coverage_asset').update({ deleted_at: new Date().toISOString() }).in('id', removed).select('id') : { error: null }
    setBusy(false)
    if (ins.error || del.error) return setError(coverageError(ins.error ?? del.error ?? {}))
    props.onSaved(id)
  }

  async function remove() {
    if (!row?.id || !window.confirm(c.deleteConfirm)) return
    const { data, error } = await supabase.from('coverage').update({ deleted_at: new Date().toISOString() }).eq('id', row.id).select('id')
    if (error || !data?.length) return setError(coverageError(error ?? { code: '42501' }))
    props.onDeleted()
  }

  const vendorOk = (v: Vendor) => v.is_active || v.id === base?.vendor_id
  return (
    <div className="card">
      <form onSubmit={(e) => void submit(e)} noValidate>
        <div className="page-head">
          <h2>{renew ? c.renewTitle : row ? (editable ? c.edit : c.view) : c.add}</h2>
          <div className="spacer" />
          {row && can('coverage_contract', 'create') && (
            <button className="btn" type="button" onClick={() => props.onRenew(row, initial.map((l) => ({ id: l.id, tag: l.tag, name: l.name })))}>
              {c.renew}
            </button>
          )}
          {row && can('coverage_contract', 'delete') && (
            <button className="btn" type="button" onClick={() => void remove()}>
              {c.delete}
            </button>
          )}
          <button className="btn" type="button" onClick={props.onClose}>
            {c.close}
          </button>
        </div>
        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}
        {(renew ?? (row?.renews_coverage_id ? row : undefined)) && (
          <p className="muted">
            {c.renews}{' '}
            <button className="row-link" type="button" onClick={() => props.onOpen((renew?.id ?? row?.renews_coverage_id) as string)}>
              {renew ? `${typeLabel(renew.coverage_type)} ${showDate(renew.start_date, tenant)} – ${showDate(renew.end_date, tenant)}` : c.previous}
            </button>
          </p>
        )}
        {renewedBy.length > 0 && (
          <p className="muted">
            {c.renewedBy}{' '}
            {renewedBy.map((r) => (
              <button key={r.id} className="row-link" type="button" onClick={() => props.onOpen(r.id ?? '')}>
                {`${showDate(r.start_date, tenant)} – ${showDate(r.end_date, tenant)} `}
              </button>
            ))}
          </p>
        )}
        {row && (
          <p>
            <StatusTag row={row} today={props.today} />
          </p>
        )}
        <fieldset disabled={!editable} className="form-grid plain">
          <label className="field">
            {c.type}
            <select name="coverage_type" defaultValue={base?.coverage_type ?? 'warranty'}>
              {types.map((x) => (
                <option key={x} value={x}>
                  {c.types[x]}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            {c.vendor}
            {/* C2: active vendors; the stored one stays, marked, if it was deactivated since. */}
            <select name="vendor_id" defaultValue={base?.vendor_id ?? ''} required>
              <option value="">{c.chooseVendor}</option>
              {props.vendors.filter(vendorOk).map((v) => (
                <option key={v.id} value={v.id}>
                  {v.is_active ? v.name : `${v.name} (${t.vendors.inactive})`}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            {c.reference}
            <input name="reference" defaultValue={row?.reference ?? ''} maxLength={100} />
          </label>
          <label className="field">
            {c.start}
            <input name="start_date" type="date" defaultValue={start} required />
          </label>
          <label className="field">
            {c.end}
            <input name="end_date" type="date" defaultValue={end} required />
          </label>
          {seeMoney ? (
            <>
              <label className="field">
                {c.value}
                <input name="contract_value" type="number" min="0" step="0.01" defaultValue={row?.contract_value ?? ''} disabled={!canMoney} />
              </label>
              <label className="field">
                {c.currency}
                <select name="contract_currency" defaultValue={row?.contract_currency ?? tenant.currency_code} disabled={!canMoney}>
                  {[...new Set([row?.contract_currency ?? tenant.currency_code, ...Intl.supportedValuesOf('currency')])].map((x) => (
                    <option key={x}>{x}</option>
                  ))}
                </select>
              </label>
            </>
          ) : (
            <div className="field">
              {c.value}
              <Hidden />
            </div>
          )}
          <label className="field">
            {c.notes}
            <textarea name="notes" rows={3} defaultValue={base?.notes ?? ''} maxLength={2000} />
          </label>
        </fieldset>
        <AssetLinks links={links} editable={editable && can('coverage_contract', 'update')} onChange={setLinks} />
        {editable && (
          <div className="page-head">
            <div className="spacer" />
            <button className="btn" type="button" onClick={props.onClose}>
              {c.cancel}
            </button>
            <button className="btn btn-main" type="submit" disabled={busy}>
              {c.save}
            </button>
          </div>
        )}
      </form>
    </div>
  )
}

// The contract's assets (C3), with a search picker on the 3.2 list helper. Saved with the contract.
export function AssetLinks({ links, editable, onChange }: { links: Linked[]; editable: boolean; onChange: (l: Linked[]) => void }) {
  const [term, setTerm] = useState('')
  const [found, setFound] = useState<AssetRef[]>([])

  useEffect(() => {
    if (!term.trim()) return
    let live = true
    const id = setTimeout(() => {
      void supabase.rpc('list_assets', { p_term: term.trim(), p_sort: 'name', p_limit: 10 }).then(({ data }) => {
        if (live) setFound((data ?? []).map((a) => ({ id: a.id ?? '', tag: a.tag ?? '', name: a.name ?? '' })))
      })
    }, 300)
    return () => {
      live = false
      clearTimeout(id)
    }
  }, [term])

  return (
    <section aria-label={c.assets}>
      <h2>{c.assets}</h2>
      <div className="table-wrap">
        <table>
          <tbody>
            {links.length === 0 && (
              <tr>
                <td className="muted">{c.noAssets}</td>
              </tr>
            )}
            {links.map((l) => (
              <tr key={l.id}>
                <td>
                  <Link className="row-link" to={`/assets/${l.id}`}>
                    {l.tag}
                  </Link>{' '}
                  {l.name}
                </td>
                {editable && (
                  <td className="actions">
                    <button className="btn" type="button" onClick={() => onChange(links.filter((x) => x.id !== l.id))}>
                      {c.removeAsset}
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {editable && (
        <>
          <input className="search" type="search" placeholder={c.findAsset} aria-label={c.findAsset} value={term} onChange={(e) => setTerm(e.target.value)} />
          {term.trim() && (
            <ul className="plain-list">
              {found
                .filter((a) => !links.some((l) => l.id === a.id))
                .map((a) => (
                  <li key={a.id}>
                    <button className="btn" type="button" onClick={() => onChange([...links, a])}>
                      {c.addAsset}
                    </button>{' '}
                    {a.tag} {a.name}
                  </li>
                ))}
            </ul>
          )}
        </>
      )}
    </section>
  )
}

// Asset detail (Overview): one line per group from asset_coverage(), "None" when never covered, and the vendor.
export function CoverageCard({ assetId, can }: { assetId: string; can: Can }) {
  const tenant = useTenant()
  const [lines, setLines] = useState<Line[]>()
  const [vendors, setVendors] = useState<Vendor[]>([])

  useEffect(() => {
    let live = true
    void Promise.all([supabase.rpc('asset_coverage', { p_asset_ids: [assetId] }), loadVendors()]).then(([l, v]) => {
      if (!live) return
      setLines(l.data ?? [])
      setVendors(v)
    })
    return () => {
      live = false
    }
  }, [assetId])

  if (!lines || !tenant) return null
  const today = tenantToday(tenant.time_zone)
  const best = bestLine(lines)
  return (
    <section className="card">
      <h2>{c.title}</h2>
      <dl className="kv">
        {groups
          .filter((g) => g !== 'other' || lines.some((l) => l.coverage_group === g))
          .map((g) => {
            const l = lines.find((x) => x.coverage_group === g)
            return (
              <Fragment key={g}>
                <dt>{c.groups[g]}</dt>
                <dd>
                  {l ? (
                    <>
                      <StatusTag row={l} today={today} /> <span className="muted">{c.to.replace('{date}', showDate(l.end_date, tenant))}</span>
                    </>
                  ) : (
                    <span className="tag status neutral">{c.status.none}</span>
                  )}
                </dd>
              </Fragment>
            )
          })}
        <dt>{c.vendor}</dt>
          <dd>
            {!best ? (
              '—'
            ) : can('vendor_core', 'view') ? (
              <Link className="row-link" to={`/vendors?id=${best.vendor_id}`}>
                {vendors.find((v) => v.id === best.vendor_id)?.name ?? c.formerVendor}
              </Link>
            ) : (
              <Hidden />
            )}
          </dd>
      </dl>
    </section>
  )
}

// Asset detail Coverage tab: every live contract of the asset, linked to the Coverage page.
export function CoverageTab({ assetId, can }: { assetId: string; can: Can }) {
  const tenant = useTenant()
  const [rows, setRows] = useState<Coverage[]>()

  useEffect(() => {
    let live = true
    void supabase
      .from('coverage_asset')
      .select('coverage_id')
      .eq('asset_id', assetId)
      .is('deleted_at', null)
      .then(async ({ data }) => {
        const ids = (data ?? []).map((x) => x.coverage_id)
        const r = ids.length ? ((await supabase.from('coverage_view').select('*').in('id', ids).order('end_date', { ascending: false })).data ?? []) : []
        if (live) setRows(r)
      })
    return () => {
      live = false
    }
  }, [assetId])

  if (!rows || !tenant) return <p className="muted" role="status">{c.loading}</p>
  const today = tenantToday(tenant.time_zone)
  return (
    <div className="stack detail">
      {can('coverage_contract', 'create') && (
        <div className="page-head">
          <div className="spacer" />
          <Link className="btn btn-main" to={`/coverage?asset=${assetId}`}>
            {c.add}
          </Link>
        </div>
      )}
      <div className="card table-wrap list">
        {rows.length === 0 ? (
          <p className="muted">{c.noneForAsset}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{c.col.type}</th>
                <th>{c.col.start}</th>
                <th>{c.col.end}</th>
                <th>{c.col.status}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>
                    <Link className="row-link" to={`/coverage?id=${r.id}`}>
                      {typeLabel(r.coverage_type)}
                    </Link>
                    {r.reference && <span className="muted"> {r.reference}</span>}
                  </td>
                  <td>{showDate(r.start_date, tenant)}</td>
                  <td>{showDate(r.end_date, tenant)}</td>
                  <td>
                    <StatusTag row={r} today={today} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  )
}
