import { Fragment, useEffect, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { coverageValues, CoverageTag, TreeSelect, type Cursor } from './Assets'
import { AttachmentsTab } from './Attachments'
import { daysBetween, showDate, tenantToday, useTenant } from './Coverage'
import { t } from './i18n'
import { obligationTypes, ruleText, stateTone } from './Obligations'
import { CompletionForm } from './Service'
import { supabase } from './supabase'
import type { Database } from './types/database'

// Story 5.3: the Maintenance screen (data-model-goal5.md §13). Lists come from list_obligations and
// list_completions; tab and tile counts from maintenance_counts. The filter panel is the 4.4 Assets one.
type Can = (domain: string, operation: string) => boolean
type Fn = Database['public']['Functions']
type Open = Fn['list_obligations']['Returns'][number]
type Done = Fn['list_completions']['Returns'][number]
type Counts = Fn['maintenance_counts']['Returns'][number]
type Line = Fn['asset_coverage']['Returns'][number]
type Option = { id: string; parent_id: string | null; name: string }
export type Bucket = 'overdue' | 'due_soon' | 'scheduled' | 'completed'
export type Filters = { q: string; category_id: string; location_id: string; type: string; vendor_id: string; coverage: string }

const m = t.maintenance
const PAGE = 50
const buckets = ['overdue', 'due_soon', 'scheduled', 'completed'] as const
const emptyFilters: Filters = { q: '', category_id: '', location_id: '', type: '', vendor_id: '', coverage: '' }
const OPEN_KEY = 'assetly.maintenance.filtersOpen'
const readOpen = () => {
  try {
    return localStorage.getItem(OPEN_KEY) === '1'
  } catch {
    return false
  }
}
const isPhone = () => window.matchMedia?.('(max-width: 767px)').matches ?? false

// Filters to the RPC arguments shared by the lists and the counts. Empty filters are left out.
export function filterArgs(f: Filters): Fn['maintenance_counts']['Args'] {
  return {
    ...(f.q.trim() && { p_term: f.q.trim() }),
    ...(f.category_id && { p_category_id: f.category_id }),
    ...(f.location_id && { p_location_id: f.location_id }),
    ...(f.type && { p_type: f.type }),
    ...(f.vendor_id && { p_vendor_id: f.vendor_id }),
    ...(f.coverage && { p_coverage: f.coverage }),
  }
}

// One more row than a page, so the page knows whether Next exists.
export const pageArgs = (f: Filters, after?: Cursor) => ({ ...filterArgs(f), ...(after && { p_after_value: after.value, p_after_id: after.id }), p_limit: PAGE + 1 })

// Keyset cursor after the last row shown: next due on the open tabs, done date on Completed (§13.2).
export function nextCursor(rows: { id: string; next_due_date?: string; done_on?: string }[]): Cursor | undefined {
  const last = rows[PAGE - 1]
  if (rows.length <= PAGE || !last) return undefined
  return { value: last.next_due_date ?? last.done_on ?? '', id: last.id }
}

// "12 d overdue", "Due today", "In 5 d", counted from the tenant's today.
export function dueText(next: string, today: string): string {
  const d = daysBetween(today, next)
  return d < 0 ? m.overdue.replace('{n}', String(-d)) : d === 0 ? m.dueToday : m.dueIn.replace('{n}', String(d))
}

// Whole years and months since the in-service date, else the purchase date.
export function ageText(from: string | null | undefined, today: string): string {
  if (!from) return '—'
  const months = Math.max(0, (Number(today.slice(0, 4)) - Number(from.slice(0, 4))) * 12 + Number(today.slice(5, 7)) - Number(from.slice(5, 7)) - (today.slice(8) < from.slice(8) ? 1 : 0))
  const y = Math.floor(months / 12)
  return (y ? m.age.years.replace('{y}', String(y)) : m.age.months).replace('{m}', String(months % 12))
}

// "Plant 1 · Pune": the location and its parent, from the loaded tree.
export function placeName(list: Option[], id: string | null): string {
  const l = list.find((r) => r.id === id)
  const parent = l && list.find((r) => r.id === l.parent_id)
  return l ? (parent ? `${l.name} · ${parent.name}` : l.name) : '—'
}

const money = (v: number | null, c: string | null) => (v == null ? '—' : `${Number(v).toLocaleString()} ${c ?? ''}`)

export function MaintenancePage({ tenantId, can }: { tenantId: string; can: Can }) {
  const tenant = useTenant()
  const tabs = buckets.filter((b) => (b === 'completed' ? can('service_record', 'view') : can('obligation', 'view')))
  // ?tab= from a Dashboard link (5.4); a tab the user cannot see is ignored below.
  const [params] = useSearchParams()
  const [picked, setPicked] = useState(() => (params.get('tab') ?? undefined) as Bucket | undefined)
  const tab = picked && tabs.includes(picked) ? picked : tabs[0]
  const [filters, setFilters] = useState<Filters>(emptyFilters)
  const [typed, setTyped] = useState('')
  const [open, setOpen] = useState(() => readOpen() && !isPhone())
  const toggleRef = useRef<HTMLButtonElement>(null)
  const [pages, setPages] = useState<Cursor[]>([])
  const [after, setAfter] = useState<Cursor>()
  const [reload, setReload] = useState(0)
  const [loaded, setLoaded] = useState<{ key: string; rows: (Open | Done)[]; lines: Line[]; error: boolean }>()
  const [counts, setCounts] = useState<{ key: string; c?: Counts; out?: number }>()
  const [categories, setCategories] = useState<Option[]>([])
  const [locations, setLocations] = useState<Option[]>([])
  const [vendors, setVendors] = useState<{ id: string; name: string }[]>([])
  const [completing, setCompleting] = useState<Open>()
  const [files, setFiles] = useState<string>()
  const canCoverage = can('coverage_contract', 'view')

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('asset_category').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('vendor_view').select('id, name').order('name'),
    ]).then(([c, l, vn]) => {
      if (!live) return
      setCategories(c.data ?? [])
      setLocations(l.data ?? [])
      setVendors((vn.data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '' })))
    })
    return () => {
      live = false
    }
  }, [])

  useEffect(() => {
    if (typed === filters.q) return
    const id = setTimeout(() => apply({ ...filters, q: typed }), 300)
    return () => clearTimeout(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [typed, filters.q])

  const args = pageArgs(filters, after)
  const key = JSON.stringify([tab, args, reload])
  useEffect(() => {
    if (!tab) return
    let live = true
    const q = tab === 'completed' ? supabase.rpc('list_completions', args) : supabase.rpc('list_obligations', { ...args, p_bucket: tab })
    void q.then(async ({ data, error }) => {
      const rows: (Open | Done)[] = data ?? []
      // Coverage column: one asset_coverage() call with the page's asset ids (data-model-goal4 §21).
      const ids = [...new Set(rows.slice(0, PAGE).map((r) => r.asset_id))]
      const lines = canCoverage && ids.length ? ((await supabase.rpc('asset_coverage', { p_asset_ids: ids })).data ?? []) : []
      if (live) setLoaded({ key, rows, lines, error: !!error })
    })
    return () => {
      live = false
    }
    // key holds every argument.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, canCoverage])

  const countKey = JSON.stringify([filterArgs(filters), reload, canCoverage])
  useEffect(() => {
    let live = true
    const f = filterArgs(filters)
    void Promise.all([
      supabase.rpc('maintenance_counts', f),
      // The Out of coverage tile counts assets: the 4.4 count with the same asset filters (M5 a).
      canCoverage ? supabase.rpc('count_assets', { p_term: f.p_term, p_category_id: f.p_category_id, p_location_id: f.p_location_id, p_vendor_id: f.p_vendor_id, p_coverage: 'out' }) : undefined,
    ]).then(([c, out]) => live && setCounts({ key: countKey, c: c.data?.[0], out: out?.data ?? undefined }))
    return () => {
      live = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [countKey])

  function apply(f: Filters) {
    setFilters(f)
    setPages([])
    setAfter(undefined)
  }
  const pick = (k: keyof Filters, v: string) => apply({ ...filters, q: typed, [k]: v })
  function pickTab(b: Bucket) {
    setPicked(b)
    setPages([])
    setAfter(undefined)
    setFiles(undefined)
  }
  function setPanel(o: boolean) {
    setOpen(o)
    try {
      localStorage.setItem(OPEN_KEY, o ? '1' : '0')
    } catch {
      // Storage blocked: the panel still works, it is just not remembered.
    }
    if (!o) toggleRef.current?.focus()
  }

  if (!tab) return <h1>{t.pages.maintenance}</h1>
  const rows = loaded?.key === key ? loaded.rows : undefined
  const lines = loaded?.key === key ? loaded.lines : []
  const shown = rows?.slice(0, PAGE) ?? []
  const next = rows && nextCursor(rows)
  const c = counts?.key === countKey ? counts : undefined
  const num = (n?: number) => (n === undefined ? '…' : n > 10000 ? t.assets.manyCount : n.toLocaleString())
  const today = tenant ? tenantToday(tenant.time_zone) : ''
  const nameOf = (list: Option[], id: string | null) => list.find((r) => r.id === id)
  const place = (id: string | null) => placeName(locations, id)
  const types = t.obligations.types as Record<string, string>
  const chips = (
    [
      ['location_id', t.assets.location, nameOf(locations, filters.location_id)?.name],
      ['category_id', t.assets.category, nameOf(categories, filters.category_id)?.name],
      ['type', m.type, types[filters.type]],
      ['vendor_id', t.assets.vendor, vendors.find((x) => x.id === filters.vendor_id)?.name],
      ['coverage', t.assets.coverage.label, (t.assets.coverage.values as Record<string, string>)[filters.coverage]],
    ] as const
  ).flatMap(([k, label, value]) => (filters[k] ? [{ key: k, text: `${label}: ${value ?? filters[k]}` }] : []))
  const clearAll = () => apply({ ...emptyFilters, q: typed })
  const sheet = open && isPhone()
  const seeValue = can('asset_financials', 'view')
  const seeCost = can('service_values', 'view')
  const canComplete = can('obligation', 'complete')
  const p = t.assets.panel
  const first = pages.length * PAGE + 1
  const assetCell = (r: Open | Done) => (
    <td>
      <Link className="row-link" to={`/assets/${r.asset_id}`}>
        {r.asset_name}
      </Link>{' '}
      <span className="muted">{r.tag}</span>
    </td>
  )
  const assetCells = (r: Open | Done) => (
    <>
      <td>{place(r.location_id)}</td>
      {canCoverage && <td>{today && <CoverageTag lines={lines.filter((l) => l.asset_id === r.asset_id)} today={today} />}</td>}
      <td>{today && ageText(r.in_service_date ?? r.purchase_date, today)}</td>
      {seeValue && <td>{money(r.purchase_value, r.purchase_currency)}</td>}
    </>
  )

  return (
    <>
      <title>{`${t.pages.maintenance} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.maintenance}</h1>
          <span className="muted">{m.subtitle}</span>
        </div>
      </div>
      {can('obligation', 'view') && (
        <div className="kpis">
          <div className="card kpi">
            <span>{m.tiles.overdue}</span>
            <b className="error">{num(c?.c?.overdue)}</b>
          </div>
          <div className="card kpi">
            <span>{m.tiles.next7}</span>
            <b>{num(c?.c?.next_7)}</b>
          </div>
          <div className="card kpi">
            <span>{m.tiles.next30}</span>
            <b>{num(c?.c?.next_30)}</b>
          </div>
          {canCoverage && (
            <div className="card kpi">
              <span>{m.tiles.out}</span>
              <b>{num(c?.out)}</b>
            </div>
          )}
        </div>
      )}
      <div className="tabs" role="tablist">
        {tabs.map((b) => (
          <button key={b} type="button" role="tab" aria-selected={tab === b} className={tab === b ? 'on' : ''} onClick={() => pickTab(b)}>
            {m.tabs[b]} · {num(c?.c?.[b])}
          </button>
        ))}
      </div>
      <div className="page-head filters">
        <input className="search" type="search" placeholder={m.filter} aria-label={m.filter} value={typed} onChange={(e) => setTyped(e.target.value)} />
        <button ref={toggleRef} className="btn" type="button" aria-expanded={open} aria-controls="maintenance-filters" onClick={() => setPanel(!open)}>
          {p.filters}
          {chips.length > 0 && ` · ${chips.length}`} <span aria-hidden="true">{open ? '▴' : '▾'}</span>
        </button>
      </div>
      {!open && chips.length > 0 && (
        <div className="chips filter-chips">
          {chips.map((ch) => (
            <span key={ch.key} className="chip">
              {ch.text}
              <button type="button" aria-label={p.remove.replace('{filter}', ch.text)} onClick={() => pick(ch.key, '')}>
                ×
              </button>
            </span>
          ))}
          <button className="btn-link" type="button" onClick={clearAll}>
            {p.clearAll}
          </button>
        </div>
      )}
      {sheet && <div className="sheet-backdrop" onClick={() => setPanel(false)} />}
      {open && (
        <div
          id="maintenance-filters"
          className={`filter-panel${sheet ? ' sheet' : ''}`}
          role={sheet ? 'dialog' : 'group'}
          aria-modal={sheet || undefined}
          aria-label={p.filters}
          onKeyDown={(e) => e.key === 'Escape' && setPanel(false)}
        >
          <TreeSelect label={t.assets.location} all={t.assets.allLocations} rows={locations} value={filters.location_id} onChange={(v) => pick('location_id', v)} />
          <TreeSelect label={t.assets.category} all={t.assets.allCategories} rows={categories} value={filters.category_id} onChange={(v) => pick('category_id', v)} />
          <select className="filter" aria-label={m.type} value={filters.type} onChange={(e) => pick('type', e.target.value)}>
            <option value="">{m.allTypes}</option>
            {obligationTypes.map((x) => (
              <option key={x} value={x}>
                {types[x]}
              </option>
            ))}
          </select>
          {canCoverage && (
            <select className="filter" aria-label={t.assets.coverage.label} value={filters.coverage} onChange={(e) => pick('coverage', e.target.value)}>
              <option value="">{t.assets.coverage.all}</option>
              {coverageValues.map((v) => (
                <option key={v} value={v}>
                  {t.assets.coverage.values[v]}
                </option>
              ))}
            </select>
          )}
          {vendors.length > 0 && (
            <select className="filter" aria-label={t.assets.vendor} value={filters.vendor_id} onChange={(e) => pick('vendor_id', e.target.value)}>
              <option value="">{t.assets.allVendors}</option>
              {vendors.map((x) => (
                <option key={x.id} value={x.id}>
                  {x.name}
                </option>
              ))}
            </select>
          )}
          <div className="panel-actions">
            <button className="btn" type="button" onClick={clearAll} disabled={chips.length === 0}>
              {p.clearAll}
            </button>
            {sheet && (
              <button className="btn btn-main" type="button" onClick={() => setPanel(false)}>
                {p.apply}
              </button>
            )}
          </div>
        </div>
      )}
      {loaded?.key === key && loaded.error && (
        <p className="login-error" role="alert">
          {m.errors.load}
        </p>
      )}
      {completing && (
        <CompletionForm
          obligation={{ id: completing.id, tenant_id: tenantId, name: completing.name, obligation_type: completing.obligation_type }}
          can={can}
          onCancel={() => setCompleting(undefined)}
          onDone={() => {
            setCompleting(undefined)
            setReload((n) => n + 1)
          }}
        />
      )}
      <div className="card table-wrap list obligations">
        {rows === undefined ? (
          <p className="muted" role="status">
            {m.loading}
          </p>
        ) : shown.length === 0 ? (
          <p className="muted">{JSON.stringify(filters) === JSON.stringify(emptyFilters) ? m.none : m.noMatch}</p>
        ) : tab === 'completed' ? (
          <table>
            <thead>
              <tr>
                <th>{m.col.asset}</th>
                <th>{m.col.obligation}</th>
                <th>{m.col.done}</th>
                <th>{m.col.outcome}</th>
                <th>{m.col.doneBy}</th>
                {seeCost && <th>{m.col.cost}</th>}
                <th>{m.col.location}</th>
                {canCoverage && <th>{m.col.coverage}</th>}
                <th>{m.col.age}</th>
                {seeValue && <th>{m.col.value}</th>}
                <th>{m.col.files}</th>
              </tr>
            </thead>
            <tbody>
              {(shown as Done[]).map((r) => (
                <Fragment key={r.id}>
                  <tr>
                    {assetCell(r)}
                    <td>{r.obligation_name ?? '—'}</td>
                    <td>{showDate(r.done_on, tenant)}</td>
                    <td>{r.outcome ? t.service.outcomes[r.outcome as 'pass' | 'fail'] : '—'}</td>
                    <td>{r.vendor_name ?? r.done_by_name ?? '—'}</td>
                    {seeCost && <td>{money(r.cost_amount, r.cost_currency)}</td>}
                    {assetCells(r)}
                    <td>
                      <button className="btn" type="button" aria-expanded={files === r.id} onClick={() => setFiles(files === r.id ? undefined : r.id)}>
                        {t.service.files} · {r.attachments}
                      </button>
                    </td>
                  </tr>
                  {files === r.id && tenant && (
                    <tr>
                      <td colSpan={11}>
                        <AttachmentsTab tenantId={tenantId} entity="service_record" entityId={r.id} can={can} timeZone={tenant.time_zone} />
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{m.col.asset}</th>
                <th>{m.col.obligation}</th>
                <th>{m.col.due}</th>
                <th>{m.col.status}</th>
                <th>{m.col.location}</th>
                {canCoverage && <th>{m.col.coverage}</th>}
                <th>{m.col.age}</th>
                {seeValue && <th>{m.col.value}</th>}
                {canComplete && <th aria-label={m.col.actions} />}
              </tr>
            </thead>
            <tbody>
              {(shown as Open[]).map((r) => (
                <tr key={r.id}>
                  {assetCell(r)}
                  <td>
                    {r.name} <span className="muted">{ruleText(r)}</span>
                  </td>
                  <td>{showDate(r.next_due_date, tenant)}</td>
                  <td>{today && <span className={`tag status ${stateTone(r.due_state)}`}>{dueText(r.next_due_date, today)}</span>}</td>
                  {assetCells(r)}
                  {canComplete && (
                    <td className="actions">
                      <button className="btn btn-main" type="button" onClick={() => setCompleting(r)}>
                        {t.obligations.recordCompletion}
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      <div className="page-head muted">
        {shown.length > 0 && <span>{m.showing.replace('{from}', first.toLocaleString()).replace('{to}', (first + shown.length - 1).toLocaleString())}</span>}
        <div className="spacer" />
        <button
          className="btn"
          type="button"
          disabled={pages.length === 0}
          onClick={() => {
            setAfter(pages.length > 1 ? pages[pages.length - 2] : undefined)
            setPages((x) => x.slice(0, -1))
          }}
        >
          {t.assets.previous}
        </button>
        <button
          className="btn"
          type="button"
          disabled={!next}
          onClick={() => {
            if (!next) return
            setPages((x) => [...x, next])
            setAfter(next)
          }}
        >
          {t.assets.next}
        </button>
      </div>
    </>
  )
}
