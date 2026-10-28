import { useEffect, useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import { statuses } from './Assets'
import { t } from './i18n'
import { supabase } from './supabase'
import { buildTree, lineage } from './tree'
import type { Database, Tables } from './types/database'

type Location = Pick<Tables<'location'>, 'id' | 'parent_id' | 'name' | 'code' | 'location_type' | 'active'>
type DbError = { code?: string; message?: string }
type Can = (domain: string, operation: string) => boolean
type StatusCount = Database['public']['Functions']['location_status_counts']['Returns'][number]
export type Counts = Record<(typeof statuses)[number] | 'overdue' | 'total', number>

const empty = (): Counts => ({ in_stock: 0, active: 0, under_maintenance: 0, inactive: 0, disposed: 0, overdue: 0, total: 0 })

// Story 5.5: a node's counts are its own plus every descendant's. location_status_counts is per asset
// location; the closure table is private, so the web rolls up the tree it already holds (5.4 pattern).
// location_id is null for assets with no location; the generated type cannot say so.
export function rollUp(rows: Location[], counts: (Omit<StatusCount, 'location_id'> & { location_id: string | null })[]): Map<string, Counts> {
  const out = new Map<string, Counts>()
  for (const c of counts) {
    if (!c.location_id) continue
    for (const id of lineage(rows, c.location_id)) {
      const n = out.get(id) ?? out.set(id, empty()).get(id)!
      for (const s of statuses) n[s] += c[s]
      n.overdue += c.overdue
      n.total += c.in_stock + c.active + c.under_maintenance + c.inactive + c.disposed
    }
  }
  return out
}

const num = (n?: number) => (n === undefined ? '…' : n > 10000 ? t.assets.manyCount : n.toLocaleString())

// Where a location may move, in tree order: not under itself or its own descendants (the database
// also refuses a cycle), and an active location not under an inactive one (2.3 rule L2).
export function moveTargets(rows: Location[], moving: Location): { row: Location; depth: number }[] {
  const tree = buildTree(rows)
  // Tree order puts a subtree right after its root, so the blocked rows are one run.
  const start = tree.findIndex((n) => n.row.id === moving.id)
  let end = start + 1
  while (end < tree.length && (tree[end]?.depth ?? 0) > (tree[start]?.depth ?? 0)) end++
  const blocked = new Set(tree.slice(start, end).map((n) => n.row.id))
  return tree.filter(({ row }) => !blocked.has(row.id) && (row.active || !moving.active))
}

// Postgres and PostgREST errors to one clear message each. The 2.3 triggers all raise 23514,
// so their message text picks the translation.
function errorMessage(error: DbError): string {
  const e = t.locations.errors
  const m = error.message ?? ''
  if (error.code === '42501') return e.noPermission
  if (error.code === '23505') return m.includes('location_code_uq') ? e.duplicateCode : e.duplicateName
  if (error.code === '23514') {
    if (m.includes('cannot move under itself')) return e.cycle
    if (m.includes('parent location is inactive')) return e.parentInactive
    if (m.includes('deactivate the child locations')) return e.childrenActive
    return e.invalid
  }
  return e.generic
}

type Editing = { kind: 'add'; parentId: string | null } | { kind: 'edit' } | { kind: 'move' }

export function LocationsPage({ tenantId, canManage, can }: { tenantId: string; canManage: boolean; can: Can }) {
  const [rows, setRows] = useState<Location[]>([])
  const [counts, setCounts] = useState<StatusCount[]>()
  // Counts read asset_view, so they need asset_core.view; overdue also obligation.view.
  const seeAssets = can('asset_core', 'view')
  const seeDue = seeAssets && can('obligation', 'view')
  const [selected, setSelected] = useState<string>()
  const [editing, setEditing] = useState<Editing>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)
  // Expanded nodes. Empty at first, so only the top level shows.
  const [open, setOpen] = useState<Set<string>>(new Set())

  useEffect(() => {
    let live = true
    void supabase
      .from('location')
      .select('id, parent_id, name, code, location_type, active')
      .is('deleted_at', null)
      .then(({ data, error }) => {
        if (!live) return
        setRows(data ?? [])
        if (error) setError(t.locations.errors.load)
      })
    return () => {
      live = false
    }
  }, [reload])

  useEffect(() => {
    if (!seeAssets) return
    let live = true
    void supabase.rpc('location_status_counts').then(({ data }) => live && setCounts(data ?? []))
    return () => {
      live = false
    }
  }, [seeAssets])

  const sums = counts && rollUp(rows, counts)
  const tree = buildTree(rows)
  const hasChildren = new Set(rows.map((r) => r.parent_id))
  // Skip every node below a collapsed one: tree order puts a subtree right after its root.
  const visible: typeof tree = []
  let hiddenBelow = Infinity
  for (const node of tree) {
    if (node.depth > hiddenBelow) continue
    hiddenBelow = open.has(node.row.id) ? Infinity : node.depth
    visible.push(node)
  }
  const current = rows.find((r) => r.id === selected) ?? tree[0]?.row
  const parents = current ? lineage(rows, current.id).slice(1).reverse() : []
  const path = parents.length ? parents.map((id) => rows.find((r) => r.id === id)?.name).join(' › ') : t.locations.topLevel
  const types = [...new Set(rows.flatMap((r) => (r.location_type ? [r.location_type] : [])))].sort()

  function toggle(id: string) {
    setOpen((s) => {
      const next = new Set(s)
      if (!next.delete(id)) next.add(id)
      return next
    })
  }

  async function run(write: PromiseLike<{ data: unknown[] | null; error: DbError | null }>) {
    setError(undefined)
    const { data, error } = await write
    // An update RLS filters out returns no rows and no error.
    if (error || !data?.length) {
      setError(errorMessage(error ?? { code: '42501' }))
      return
    }
    setEditing(undefined)
    setReload((n) => n + 1)
  }

  function startAdd(parentId: string | null) {
    if (parentId) setOpen((s) => new Set(s).add(parentId))
    setError(undefined)
    setEditing({ kind: 'add', parentId })
  }

  return (
    <>
      <title>{`${t.pages.locations} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.locations}</h1>
          <span className="muted">{t.locations.subtitle}</span>
        </div>
        <div className="spacer" />
        {canManage && (
          <button className="btn btn-main" type="button" onClick={() => startAdd(null)}>
            {t.locations.addLocation}
          </button>
        )}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <div className="split">
        <div className="card tree" role="list" aria-label={t.pages.locations}>
          {tree.length === 0 && <p className="muted">{t.locations.none}</p>}
          {visible.map(({ row, depth }) => (
            <div key={row.id} role="listitem" className="node" style={{ paddingLeft: depth * 16 }}>
              {hasChildren.has(row.id) ? (
                <button
                  type="button"
                  className="toggle"
                  aria-expanded={open.has(row.id)}
                  aria-label={(open.has(row.id) ? t.locations.collapse : t.locations.expand).replace('{name}', row.name)}
                  onClick={() => toggle(row.id)}
                >
                  {open.has(row.id) ? '▾' : '▸'}
                </button>
              ) : (
                <span className="toggle" />
              )}
              <button
                type="button"
                className={`li${row.id === current?.id ? ' on' : ''}`}
                aria-current={row.id === current?.id}
                onClick={() => {
                  setSelected(row.id)
                  setEditing(undefined)
                }}
              >
                {row.name}
                {!row.active && <span className="tag">{t.locations.inactive}</span>}
                {sums && (
                  <span className="node-count" aria-label={t.locations.counts.assets.replace('{n}', num(sums.get(row.id)?.total ?? 0))}>
                    {num(sums.get(row.id)?.total ?? 0)}
                  </span>
                )}
              </button>
            </div>
          ))}
        </div>
        <div className="stack">
          {editing?.kind === 'add' && (
            <LocationForm
              title={editing.parentId ? t.locations.addChild : t.locations.addLocation}
              parentName={rows.find((r) => r.id === editing.parentId)?.name}
              types={types}
              onCancel={() => setEditing(undefined)}
              onSave={(v) => run(supabase.from('location').insert({ ...v, parent_id: editing.parentId, tenant_id: tenantId }).select('id'))}
            />
          )}
          {editing?.kind === 'edit' && current && (
            <LocationForm
              key={current.id}
              title={t.locations.editLocation}
              row={current}
              types={types}
              onCancel={() => setEditing(undefined)}
              onSave={(v) => run(supabase.from('location').update(v).eq('id', current.id).select('id'))}
            />
          )}
          {editing?.kind === 'move' && current && (
            <MoveForm
              key={current.id}
              row={current}
              targets={moveTargets(rows, current)}
              onCancel={() => setEditing(undefined)}
              onSave={(parentId) => {
                if (parentId) setOpen((s) => new Set(s).add(parentId))
                return run(supabase.from('location').update({ parent_id: parentId }).eq('id', current.id).select('id'))
              }}
            />
          )}
          {current && (
            <div className="card">
              <div className="page-head">
                <h2>{current.name}</h2>
                {!current.active && <span className="tag">{t.locations.inactive}</span>}
                <div className="spacer" />
                {canManage && (
                  <>
                    <button className="btn" type="button" onClick={() => setEditing({ kind: 'edit' })}>
                      {t.locations.editLocation}
                    </button>
                    <button className="btn" type="button" onClick={() => setEditing({ kind: 'move' })}>
                      {t.locations.move}
                    </button>
                    <button className="btn" type="button" disabled={!current.active} onClick={() => startAdd(current.id)}>
                      {t.locations.addChild}
                    </button>
                  </>
                )}
              </div>
              <dl className="facts">
                <dt>{t.locations.parent}</dt>
                <dd>{path}</dd>
                <dt>{t.locations.code}</dt>
                <dd>{current.code ?? t.locations.noValue}</dd>
                <dt>{t.locations.type}</dt>
                <dd>{current.location_type ?? t.locations.noValue}</dd>
                <dt>{t.locations.status}</dt>
                <dd>{current.active ? t.locations.active : t.locations.inactive}</dd>
              </dl>
            </div>
          )}
          {current && seeAssets && (
            <div className="kpis" aria-label={t.locations.counts.title}>
              {[
                ...statuses.map((s) => ({ label: t.assets.statuses[s], value: s, to: `/assets?location_id=${current.id}&status=${s}`, tone: '' })),
                ...(seeDue ? [{ label: t.locations.counts.overdue, value: 'overdue' as const, to: `/maintenance?tab=overdue&location_id=${current.id}`, tone: 'error' }] : []),
              ].map((k) => {
                const v = num(sums && (sums.get(current.id) ?? empty())[k.value])
                return (
                  <Link key={k.value} className="card kpi" to={k.to} aria-label={t.dashboard.tileLink.replace('{label}', k.label).replace('{value}', v)}>
                    <span>{k.label}</span>
                    <b className={k.tone}>{v}</b>
                  </Link>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </>
  )
}

type LocationValues = Pick<Location, 'name' | 'code' | 'location_type'> & { active?: boolean }

function LocationForm({
  title,
  row,
  parentName,
  types,
  onSave,
  onCancel,
}: {
  title: string
  row?: Location
  parentName?: string
  types: string[]
  onSave: (v: LocationValues) => Promise<void>
  onCancel: () => void
}) {
  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const values: LocationValues = {
      name: String(form.get('name')).trim(),
      code: String(form.get('code')).trim() || null,
      location_type: String(form.get('type')).trim() || null,
    }
    void onSave(row ? { ...values, active: form.get('active') === 'on' } : values)
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>{title}</h2>
      {!row && (
        <p className="muted">
          {t.locations.parent}: {parentName ?? t.locations.topLevel}
        </p>
      )}
      <label className="field">
        {t.locations.name}
        <input name="name" defaultValue={row?.name} required maxLength={200} />
      </label>
      <label className="field">
        {t.locations.code}
        <input name="code" defaultValue={row?.code ?? ''} maxLength={50} />
      </label>
      <label className="field">
        {t.locations.type}
        <input name="type" defaultValue={row?.location_type ?? ''} list="location-types" maxLength={100} aria-describedby="type-hint" />
        <datalist id="location-types">
          {types.map((v) => (
            <option key={v} value={v} />
          ))}
        </datalist>
        <span id="type-hint" className="muted hint">
          {t.locations.typeHint}
        </span>
      </label>
      {row && (
        <label className="check">
          <input name="active" type="checkbox" defaultChecked={row.active} />
          {t.locations.active}
        </label>
      )}
      <FormButtons onCancel={onCancel} />
    </form>
  )
}

function MoveForm({
  row,
  targets,
  onSave,
  onCancel,
}: {
  row: Location
  targets: { row: Location; depth: number }[]
  onSave: (parentId: string | null) => Promise<void>
  onCancel: () => void
}) {
  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    void onSave(String(new FormData(e.currentTarget).get('parent')) || null)
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>{t.locations.moveTitle.replace('{name}', row.name)}</h2>
      <label className="field">
        {t.locations.newParent}
        <select name="parent" defaultValue={row.parent_id ?? ''}>
          <option value="">{t.locations.topLevel}</option>
          {targets.map(({ row: r, depth }) => (
            <option key={r.id} value={r.id}>
              {`${'— '.repeat(depth)}${r.name}`}
            </option>
          ))}
        </select>
        <span className="muted hint">{t.locations.moveHint}</span>
      </label>
      <FormButtons onCancel={onCancel} />
    </form>
  )
}

function FormButtons({ onCancel }: { onCancel: () => void }) {
  return (
    <div className="page-head">
      <div className="spacer" />
      <button className="btn" type="button" onClick={onCancel}>
        {t.locations.cancel}
      </button>
      <button className="btn btn-main" type="submit">
        {t.locations.save}
      </button>
    </div>
  )
}
