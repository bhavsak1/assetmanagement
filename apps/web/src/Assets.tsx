import { useEffect, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { daysBetween, groups, tenantToday, useTenant } from './Coverage'
import { t } from './i18n'
import { supabase } from './supabase'
import { buildTree } from './tree'
import type { Database, Tables } from './types/database'

type Asset = Tables<'asset_view'>
type Line = Database['public']['Functions']['asset_coverage']['Returns'][number]
type Option = { id: string; parent_id: string | null; name: string }
type SavedView = Pick<Tables<'saved_view'>, 'id' | 'name' | 'filters' | 'sort'>
export type Sort = 'name' | 'tag' | 'updated'
export type Filters = { q: string; status: string; status_id: string; category_id: string; location_id: string; vendor_id: string; coverage: string }
export type Status = Pick<Tables<'asset_status'>, 'id' | 'code' | 'label' | 'system_status' | 'tone' | 'is_active' | 'deleted_at'>
export type Cursor = { value: string; id: string }

const PAGE = 50
const emptyFilters: Filters = { q: '', status: '', status_id: '', category_id: '', location_id: '', vendor_id: '', coverage: '' }
// Coverage filter values (data-model-goal4 §33), one overall value per asset, as the column shows it.
export const coverageValues = ['active', 'expiring', 'out', 'none'] as const
const OPEN_KEY = 'assetly.assets.filtersOpen'
// Storage can be blocked (private mode, policy): the panel then starts closed and is not remembered.
const readOpen = () => {
  try {
    return localStorage.getItem(OPEN_KEY) === '1'
  } catch {
    return false
  }
}
// shortcut: read on each render, not on resize; enough because any click re-renders.
const isPhone = () => window.matchMedia?.('(max-width: 767px)').matches ?? false

// The Coverage cell: of the groups covering today, the one that ends first (the most urgent; ties go
// warranty, AMC, other). "Out of coverage" when contracts exist but none covers today; "None" when never covered.
export function coverageCell(lines: Line[], today: string): { text: string; tone: string } {
  const cc = t.assets.coverage.cell
  const order = groups as readonly string[]
  const best = lines
    .filter((l) => l.status === 'active' || l.status === 'expiring')
    .sort((a, b) => a.end_date.localeCompare(b.end_date) || order.indexOf(a.coverage_group) - order.indexOf(b.coverage_group))[0]
  if (!best) return lines.length ? { text: cc.out, tone: 'error' } : { text: cc.none, tone: 'neutral' }
  const days = daysBetween(today, best.end_date)
  const left =
    best.status === 'expiring'
      ? days === 0
        ? cc.today
        : cc.days.replace('{n}', String(days))
      : cc.months.replace('{n}', String(Math.max(1, Math.round(days / 30.44))))
  const group = (t.coverage.groups as Record<string, string>)[best.coverage_group] ?? best.coverage_group
  return { text: `${group} · ${left}`, tone: best.status === 'expiring' ? 'warn' : 'ok' }
}
// System statuses (data-model-goal3 §3) and their tag colours from tokens.css.
export const statuses = ['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'] as const
export const statusTone: Record<string, string> = {
  in_stock: 'neutral',
  active: 'ok',
  under_maintenance: 'warn',
  inactive: 'neutral',
  disposed: 'error',
}

// Tenant statuses (3.7), each mapped to a system status. Few rows per tenant: loaded whole.
export const loadStatuses = () => supabase.from('asset_status').select('id, code, label, system_status, tone, is_active, deleted_at').order('label')
const systemLabel = (s: string) => (t.assets.statuses as Record<string, string>)[s] ?? s
export const statusName = (statuses: Status[], id: string | null | undefined, system?: string | null) =>
  statuses.find((s) => s.id === id)?.label ?? (system ? systemLabel(system) : '—')

// The tag of an asset's status: the tenant status' label and tone, else the system status.
export function StatusTag({ statuses, id, system }: { statuses: Status[]; id: string | null | undefined; system: string | null | undefined }) {
  if (!id && !system) return null
  const s = statuses.find((x) => x.id === id)
  return <span className={`tag status ${s?.tone ?? statusTone[system ?? ''] ?? 'neutral'}`}>{statusName(statuses, id, system)}</span>
}

// Filters, sort and cursor to list_assets() arguments. Empty filters are left out (null in SQL).
// One more row than a page, so the page knows whether Next exists.
export function listArgs(f: Filters, sort: Sort, after?: Cursor): Database['public']['Functions']['list_assets']['Args'] {
  return {
    ...countArgs(f),
    p_sort: sort,
    ...(after && { p_after_value: after.value, p_after_id: after.id }),
    p_limit: PAGE + 1,
  }
}

export function countArgs(f: Filters): Database['public']['Functions']['count_assets']['Args'] {
  return {
    ...(f.q.trim() && { p_term: f.q.trim() }),
    ...(f.status && { p_status: f.status }),
    ...(f.status_id && { p_status_id: f.status_id }),
    ...(f.category_id && { p_category_id: f.category_id }),
    ...(f.location_id && { p_location_id: f.location_id }),
    ...(f.vendor_id && { p_vendor_id: f.vendor_id }),
    ...(f.coverage && { p_coverage: f.coverage }),
  }
}

// Keyset cursor after the last row shown: the sort column's value and the id that breaks ties.
export function nextCursor(rows: Asset[], sort: Sort): Cursor | undefined {
  const last = rows[Math.min(rows.length, PAGE) - 1]
  if (!last?.id || rows.length <= PAGE) return undefined
  const value = sort === 'name' ? last.name : sort === 'tag' ? last.tag : last.updated_at
  return value == null ? undefined : { value, id: last.id }
}

// A saved view back to filters. Ids of categories or locations that are gone, and unknown keys
// or statuses, are dropped: the view still opens, with fewer filters.
export function viewFilters(saved: SavedView['filters'], categories: Option[], locations: Option[], statusRows: Status[] = [], vendors: { id: string }[] = []): Filters {
  const s = (saved && typeof saved === 'object' && !Array.isArray(saved) ? saved : {}) as Record<string, unknown>
  const str = (v: unknown) => (typeof v === 'string' ? v : '')
  const known = (v: unknown, rows: Option[]) => (rows.some((r) => r.id === v) ? str(v) : '')
  return {
    q: str(s.q),
    status: (statuses as readonly string[]).includes(str(s.status)) ? str(s.status) : '',
    status_id: statusRows.some((r) => r.id === s.status_id && !r.deleted_at) ? str(s.status_id) : '',
    category_id: known(s.category_id, categories),
    location_id: known(s.location_id, locations),
    vendor_id: vendors.some((r) => r.id === s.vendor_id) ? str(s.vendor_id) : '',
    coverage: (coverageValues as readonly string[]).includes(str(s.coverage)) ? str(s.coverage) : '',
  }
}

// Only the filters that are set, as the saved_view.filters object.
export function savedFilters(f: Filters): Record<string, string> {
  return Object.fromEntries(Object.entries({ ...f, q: f.q.trim() }).filter(([, v]) => v))
}

// Filters from a link (5.4 Dashboard), read once on load: checked like a saved view, a location id by its shape.
export function urlFilters(params: URLSearchParams): Filters {
  const s = Object.fromEntries(params)
  return { ...viewFilters(s, [], []), location_id: /^[0-9a-f-]{36}$/i.test(s.location_id ?? '') ? (s.location_id ?? '') : '' }
}

const isSort = (v: string): v is Sort => v === 'name' || v === 'tag' || v === 'updated'

export function AssetsPage({ tenantId, canSaveViews, canCreate, canCoverage }: { tenantId: string; canSaveViews: boolean; canCreate: boolean; canCoverage: boolean }) {
  const [params] = useSearchParams()
  const [filters, setFilters] = useState<Filters>(() => urlFilters(params))
  // Filter panel (4.4): closed by default, remembered per browser. A phone never reopens it as a sheet on load.
  const [open, setOpen] = useState(() => readOpen() && !isPhone())
  const toggleRef = useRef<HTMLButtonElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const focusPanel = useRef(false)
  const tenant = useTenant()
  const [sort, setSort] = useState<Sort>('name')
  // The search box applies after a short pause, not on every key.
  const [typed, setTyped] = useState(filters.q)
  // Cursors of the pages before the current one, so Previous goes back without offsets.
  const [pages, setPages] = useState<Cursor[]>([])
  const [after, setAfter] = useState<Cursor>()
  // Keyed by the request, so a new filter or page shows Loading until its own rows arrive.
  const [loaded, setLoaded] = useState<{ key: string; rows: Asset[]; lines: Line[] }>()
  const [total, setTotal] = useState<number>()
  const [categories, setCategories] = useState<Option[]>([])
  const [locations, setLocations] = useState<Option[]>([])
  const [statusRows, setStatusRows] = useState<Status[]>([])
  // Vendor filter (4.1b B6): OEM or O&M. Few vendors per tenant (V5), loaded whole.
  const [vendors, setVendors] = useState<{ id: string; name: string }[]>([])
  const [views, setViews] = useState<SavedView[]>([])
  const [viewId, setViewId] = useState('')
  const [error, setError] = useState<string>()
  const [reloadViews, setReloadViews] = useState(0)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('asset_category').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name').is('deleted_at', null),
      loadStatuses(),
      supabase.from('vendor_view').select('id, name').order('name'),
    ]).then(([c, l, st, vn]) => {
      if (!live) return
      setCategories(c.data ?? [])
      setLocations(l.data ?? [])
      setStatusRows(st.data ?? [])
      setVendors((vn.data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '' })))
    })
    return () => {
      live = false
    }
  }, [])

  useEffect(() => {
    let live = true
    void supabase
      .from('saved_view')
      .select('id, name, filters, sort')
      .eq('entity', 'asset')
      .is('deleted_at', null)
      .order('name')
      .then(({ data }) => live && setViews(data ?? []))
    return () => {
      live = false
    }
  }, [reloadViews])

  // Functional update: a filter picked while the timer runs must not be undone by it.
  // No timer when the text already applies, or it would reset the page the user moved to.
  useEffect(() => {
    if (typed === filters.q) return
    const id = setTimeout(() => {
      setFilters((f) => ({ ...f, q: typed }))
      setPages([])
      setAfter(undefined)
    }, 300)
    return () => clearTimeout(id)
  }, [typed, filters.q])

  const args = listArgs(filters, sort, after)
  const key = JSON.stringify(args)
  useEffect(() => {
    let live = true
    void supabase.rpc('list_assets', args).then(async ({ data, error }) => {
      const rows = data ?? []
      // Coverage column: one asset_coverage() call with the page's ids (data-model-goal4 §21).
      const ids = rows.slice(0, PAGE).flatMap((r) => (r.id ? [r.id] : []))
      const lines = canCoverage && ids.length ? ((await supabase.rpc('asset_coverage', { p_asset_ids: ids })).data ?? []) : []
      if (!live) return
      setLoaded({ key, rows, lines })
      setError(error ? t.assets.errors.load : undefined)
    })
    return () => {
      live = false
    }
    // key holds every argument; args itself is a new object each render. Permissions can arrive after
    // the first load, so a change of canCoverage loads the page again with its coverage lines.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, canCoverage])
  const rows = loaded?.key === key ? loaded.rows : undefined
  const lines = loaded?.key === key ? loaded.lines : []

  // Focus moves into the panel when the user opens it, not when it opens restored on load.
  useEffect(() => {
    if (!open || !focusPanel.current) return
    focusPanel.current = false
    panelRef.current?.querySelector<HTMLElement>('select, button')?.focus()
  }, [open])

  // The count only changes with the filters, not with the page or sort.
  useEffect(() => {
    let live = true
    void supabase.rpc('count_assets', countArgs(filters)).then(({ data }) => live && setTotal(data ?? undefined))
    return () => {
      live = false
    }
  }, [filters])

  function apply(f: Filters, s: Sort = sort) {
    if (JSON.stringify(f) === JSON.stringify(filters) && s === sort) return
    setFilters(f)
    setSort(s)
    setPages([])
    setAfter(undefined)
  }

  function pick(key: keyof Filters, value: string) {
    setViewId('')
    apply({ ...filters, q: typed, [key]: value })
  }

  function openView(id: string) {
    setViewId(id)
    const v = views.find((x) => x.id === id)
    if (!v) return
    const f = viewFilters(v.filters, categories, locations, statusRows, vendors)
    setTyped(f.q)
    apply(f, isSort(v.sort) ? v.sort : 'name')
  }

  async function saveView() {
    const name = window.prompt(t.assets.views.namePrompt)?.trim()
    if (!name) return
    const { data, error } = await supabase
      .from('saved_view')
      .insert({ tenant_id: tenantId, entity: 'asset', name, filters: savedFilters({ ...filters, q: typed }), sort })
      .select('id')
    setError(error ? (error.code === '23505' ? t.assets.views.duplicate : t.assets.views.saveError) : undefined)
    if (data?.[0]) setViewId(data[0].id)
    setReloadViews((n) => n + 1)
  }

  async function deleteView() {
    const v = views.find((x) => x.id === viewId)
    if (!v || !window.confirm(t.assets.views.deleteConfirm.replace('{name}', v.name))) return
    const { data, error } = await supabase.from('saved_view').update({ deleted_at: new Date().toISOString() }).eq('id', v.id).select('id')
    setError(error || !data?.length ? t.assets.views.saveError : undefined)
    setViewId('')
    setReloadViews((n) => n + 1)
  }

  function setPanel(o: boolean) {
    setOpen(o)
    try {
      localStorage.setItem(OPEN_KEY, o ? '1' : '0')
    } catch {
      // Storage blocked: the panel still works, it is just not remembered.
    }
    if (o) focusPanel.current = true
    else toggleRef.current?.focus()
  }

  const shown = rows?.slice(0, PAGE) ?? []
  const next = rows && nextCursor(rows, sort)
  const first = pages.length * PAGE + 1
  const nameOf = (list: Option[], id: string | null) => list.find((r) => r.id === id)
  const place = (id: string | null) => {
    const l = nameOf(locations, id)
    const parent = l && nameOf(locations, l.parent_id)
    return l ? (parent ? `${l.name} · ${parent.name}` : l.name) : '—'
  }
  const tenantStatuses = statusRows.filter((s) => s.code !== s.system_status && !s.deleted_at)
  const count = total === undefined ? '' : total > 10000 ? t.assets.manyCount : total.toLocaleString()
  const p = t.assets.panel
  // The active filters (all but the search box, which stays visible), as removable chips.
  const chips = (
    [
      ['location_id', t.assets.location, nameOf(locations, filters.location_id)?.name],
      ['category_id', t.assets.category, nameOf(categories, filters.category_id)?.name],
      ['status', t.assets.status, filters.status && systemLabel(filters.status)],
      ['status_id', t.assets.status, statusRows.find((s) => s.id === filters.status_id)?.label],
      ['vendor_id', t.assets.vendor, vendors.find((x) => x.id === filters.vendor_id)?.name],
      ['coverage', t.assets.coverage.label, (t.assets.coverage.values as Record<string, string>)[filters.coverage]],
    ] as const
  ).flatMap(([k, label, value]) => (filters[k] ? [{ key: k, text: `${label}: ${value ?? filters[k]}` }] : []))
  const clearAll = () => {
    setViewId('')
    apply({ ...emptyFilters, q: typed })
  }
  const sheet = open && isPhone()

  return (
    <>
      <title>{`${t.pages.assets} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.assets}</h1>
          <span className="muted">{count && t.assets.subtitle.replace('{count}', count)}</span>
        </div>
        <div className="spacer" />
        {canCreate && (
          <Link className="btn btn-main" to="/assets/new">
            {t.assets.add}
          </Link>
        )}
      </div>
      <div className="page-head filters">
        <input
          className="search"
          type="search"
          placeholder={t.assets.filter}
          aria-label={t.assets.filter}
          value={typed}
          onChange={(e) => {
            setViewId('')
            setTyped(e.target.value)
          }}
        />
        <button ref={toggleRef} className="btn" type="button" aria-expanded={open} aria-controls="asset-filters" onClick={() => setPanel(!open)}>
          {p.filters}
          {chips.length > 0 && ` · ${chips.length}`} <span aria-hidden="true">{open ? '▴' : '▾'}</span>
        </button>
        <select className="filter" aria-label={t.assets.views.label} value={viewId} onChange={(e) => openView(e.target.value)}>
          <option value="">{t.assets.views.label}</option>
          {views.map((v) => (
            <option key={v.id} value={v.id}>
              {v.name}
            </option>
          ))}
        </select>
        {canSaveViews && (
          <button className="btn" type="button" onClick={() => void saveView()}>
            {t.assets.views.save}
          </button>
        )}
        {canSaveViews && viewId && (
          <button className="btn" type="button" onClick={() => void deleteView()}>
            {t.assets.views.delete}
          </button>
        )}
      </div>
      {!open && chips.length > 0 && (
        <div className="chips filter-chips">
          {chips.map((c) => (
            <span key={c.key} className="chip">
              {c.text}
              <button type="button" aria-label={p.remove.replace('{filter}', c.text)} onClick={() => pick(c.key, '')}>
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
          id="asset-filters"
          ref={panelRef}
          className={`filter-panel${sheet ? ' sheet' : ''}`}
          role={sheet ? 'dialog' : 'group'}
          aria-modal={sheet || undefined}
          aria-label={p.filters}
          onKeyDown={(e) => {
            if (e.key === 'Escape') setPanel(false)
          }}
        >
          <TreeSelect label={t.assets.location} all={t.assets.allLocations} rows={locations} value={filters.location_id} onChange={(v) => pick('location_id', v)} />
          <TreeSelect label={t.assets.category} all={t.assets.allCategories} rows={categories} value={filters.category_id} onChange={(v) => pick('category_id', v)} />
          {/* System statuses filter on status; tenant statuses (not the default rows) on status_id. */}
          <select
            className="filter"
            aria-label={t.assets.status}
            value={filters.status || filters.status_id}
            onChange={(e) => {
              const v = e.target.value
              const system = (statuses as readonly string[]).includes(v)
              setViewId('')
              apply({ ...filters, q: typed, status: system ? v : '', status_id: system ? '' : v })
            }}
          >
            <option value="">{t.assets.allStatuses}</option>
            {statuses.map((s) => (
              <option key={s} value={s}>
                {t.assets.statuses[s]}
              </option>
            ))}
            {tenantStatuses.length > 0 && (
              <optgroup label={t.assets.tenantStatuses}>
                {tenantStatuses.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label}
                  </option>
                ))}
              </optgroup>
            )}
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
          <select
            className="filter"
            aria-label={t.assets.sort}
            value={sort}
            onChange={(e) => {
              setViewId('')
              if (isSort(e.target.value)) apply({ ...filters, q: typed }, e.target.value)
            }}
          >
            {(['name', 'tag', 'updated'] as const).map((s) => (
              <option key={s} value={s}>
                {t.assets.sorts[s]}
              </option>
            ))}
          </select>
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
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <div className="card table-wrap list">
        {rows === undefined ? (
          <p className="muted" role="status">
            {t.assets.loading}
          </p>
        ) : shown.length === 0 ? (
          <p className="muted">{JSON.stringify(filters) === JSON.stringify(emptyFilters) ? t.assets.none : t.assets.noMatch}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{t.assets.col.tag}</th>
                <th>{t.assets.col.name}</th>
                <th>{t.assets.col.category}</th>
                <th>{t.assets.col.location}</th>
                <th>{t.assets.col.status}</th>
                {canCoverage && <th>{t.assets.coverage.label}</th>}
              </tr>
            </thead>
            <tbody>
              {shown.map((a) => (
                <tr key={a.id}>
                  <td className="muted">{a.tag}</td>
                  <td>
                    <Link className="row-link" to={`/assets/${a.id}`}>
                      {a.name}
                    </Link>
                  </td>
                  <td>{nameOf(categories, a.category_id)?.name ?? '—'}</td>
                  <td>{place(a.location_id)}</td>
                  <td>
                    <StatusTag statuses={statusRows} id={a.status_id} system={a.status} />
                  </td>
                  {canCoverage && <td>{tenant && <CoverageTag lines={lines.filter((l) => l.asset_id === a.id)} today={tenantToday(tenant.time_zone)} />}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      <div className="page-head muted">
        {shown.length > 0 && (
          <span>
            {t.assets.showing
              .replace('{from}', first.toLocaleString())
              .replace('{to}', (first + shown.length - 1).toLocaleString())
              .replace('{count}', count)}
          </span>
        )}
        <div className="spacer" />
        <button
          className="btn"
          type="button"
          disabled={pages.length === 0}
          onClick={() => {
            setAfter(pages.length > 1 ? pages[pages.length - 2] : undefined)
            setPages((p) => p.slice(0, -1))
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
            setPages((p) => [...p, next])
            setAfter(next)
          }}
        >
          {t.assets.next}
        </button>
      </div>
    </>
  )
}

export function CoverageTag({ lines, today }: { lines: Line[]; today: string }) {
  const c = coverageCell(lines, today)
  return <span className={`tag status ${c.tone}`}>{c.text}</span>
}

export function TreeSelect({ label, all, rows, value, onChange }: { label: string; all: string; rows: Option[]; value: string; onChange: (v: string) => void }) {
  return (
    <select className="filter" aria-label={label} value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">{all}</option>
      {buildTree(rows).map(({ row, depth }) => (
        <option key={row.id} value={row.id}>
          {`${'— '.repeat(depth)}${row.name}`}
        </option>
      ))}
    </select>
  )
}
