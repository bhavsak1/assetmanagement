import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { t } from './i18n'
import { supabase } from './supabase'
import { buildTree } from './tree'
import type { Database, Tables } from './types/database'

type Asset = Tables<'asset_view'>
type Option = { id: string; parent_id: string | null; name: string }
type SavedView = Pick<Tables<'saved_view'>, 'id' | 'name' | 'filters' | 'sort'>
export type Sort = 'name' | 'tag' | 'updated'
export type Filters = { q: string; status: string; category_id: string; location_id: string }
export type Cursor = { value: string; id: string }

const PAGE = 50
const emptyFilters: Filters = { q: '', status: '', category_id: '', location_id: '' }
// System statuses (data-model-goal3 §3) and their tag colours from tokens.css.
export const statuses = ['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'] as const
export const statusTone: Record<string, string> = {
  in_stock: 'neutral',
  active: 'ok',
  under_maintenance: 'warn',
  inactive: 'neutral',
  disposed: 'error',
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
    ...(f.category_id && { p_category_id: f.category_id }),
    ...(f.location_id && { p_location_id: f.location_id }),
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
export function viewFilters(saved: SavedView['filters'], categories: Option[], locations: Option[]): Filters {
  const s = (saved && typeof saved === 'object' && !Array.isArray(saved) ? saved : {}) as Record<string, unknown>
  const str = (v: unknown) => (typeof v === 'string' ? v : '')
  const known = (v: unknown, rows: Option[]) => (rows.some((r) => r.id === v) ? str(v) : '')
  return {
    q: str(s.q),
    status: (statuses as readonly string[]).includes(str(s.status)) ? str(s.status) : '',
    category_id: known(s.category_id, categories),
    location_id: known(s.location_id, locations),
  }
}

// Only the filters that are set, as the saved_view.filters object.
export function savedFilters(f: Filters): Record<string, string> {
  return Object.fromEntries(Object.entries({ ...f, q: f.q.trim() }).filter(([, v]) => v))
}

const isSort = (v: string): v is Sort => v === 'name' || v === 'tag' || v === 'updated'

export function AssetsPage({ tenantId, canSaveViews, canCreate }: { tenantId: string; canSaveViews: boolean; canCreate: boolean }) {
  const [filters, setFilters] = useState<Filters>(emptyFilters)
  const [sort, setSort] = useState<Sort>('name')
  // The search box applies after a short pause, not on every key.
  const [typed, setTyped] = useState('')
  // Cursors of the pages before the current one, so Previous goes back without offsets.
  const [pages, setPages] = useState<Cursor[]>([])
  const [after, setAfter] = useState<Cursor>()
  // Keyed by the request, so a new filter or page shows Loading until its own rows arrive.
  const [loaded, setLoaded] = useState<{ key: string; rows: Asset[] }>()
  const [total, setTotal] = useState<number>()
  const [categories, setCategories] = useState<Option[]>([])
  const [locations, setLocations] = useState<Option[]>([])
  const [views, setViews] = useState<SavedView[]>([])
  const [viewId, setViewId] = useState('')
  const [error, setError] = useState<string>()
  const [reloadViews, setReloadViews] = useState(0)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('asset_category').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name').is('deleted_at', null),
    ]).then(([c, l]) => {
      if (!live) return
      setCategories(c.data ?? [])
      setLocations(l.data ?? [])
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
    void supabase.rpc('list_assets', args).then(({ data, error }) => {
      if (!live) return
      setLoaded({ key, rows: data ?? [] })
      setError(error ? t.assets.errors.load : undefined)
    })
    return () => {
      live = false
    }
    // key holds every argument; args itself is a new object each render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])
  const rows = loaded?.key === key ? loaded.rows : undefined

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
    const f = viewFilters(v.filters, categories, locations)
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

  const shown = rows?.slice(0, PAGE) ?? []
  const next = rows && nextCursor(rows, sort)
  const first = pages.length * PAGE + 1
  const nameOf = (list: Option[], id: string | null) => list.find((r) => r.id === id)
  const place = (id: string | null) => {
    const l = nameOf(locations, id)
    const parent = l && nameOf(locations, l.parent_id)
    return l ? (parent ? `${l.name} · ${parent.name}` : l.name) : '—'
  }
  const count = total === undefined ? '' : total > 10000 ? t.assets.manyCount : total.toLocaleString()

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
        <TreeSelect label={t.assets.location} all={t.assets.allLocations} rows={locations} value={filters.location_id} onChange={(v) => pick('location_id', v)} />
        <TreeSelect label={t.assets.category} all={t.assets.allCategories} rows={categories} value={filters.category_id} onChange={(v) => pick('category_id', v)} />
        <select className="filter" aria-label={t.assets.status} value={filters.status} onChange={(e) => pick('status', e.target.value)}>
          <option value="">{t.assets.allStatuses}</option>
          {statuses.map((s) => (
            <option key={s} value={s}>
              {t.assets.statuses[s]}
            </option>
          ))}
        </select>
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
        <div className="spacer" />
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
                    {a.status && <span className={`tag status ${statusTone[a.status] ?? 'neutral'}`}>{t.assets.statuses[a.status as (typeof statuses)[number]] ?? a.status}</span>}
                  </td>
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

function TreeSelect({ label, all, rows, value, onChange }: { label: string; all: string; rows: Option[]; value: string; onChange: (v: string) => void }) {
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
