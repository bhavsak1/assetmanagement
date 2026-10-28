import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { showDate, useTenant } from './Coverage'
import { t } from './i18n'
import { placeName } from './Maintenance'
import { StateTag } from './Obligations'
import { CompletionForm } from './Service'
import { supabase } from './supabase'
import { lineage } from './tree'
import type { Database } from './types/database'

// Story 5.4: the Dashboard (data-model-goal5.md §14). Tiles reuse count_assets (3.2, 4.4) and
// maintenance_counts (5.3); the upcoming list is the first rows of list_obligations; by location is
// location_asset_counts rolled up the loaded location tree.
type Can = (domain: string, operation: string) => boolean
type Fn = Database['public']['Functions']
type Open = Fn['list_obligations']['Returns'][number]
type Counts = Fn['maintenance_counts']['Returns'][number]
type LocationCount = Fn['location_asset_counts']['Returns'][number]
type Option = { id: string; parent_id: string | null; name: string }
export type Bar = { id: string | null; name: string; assets: number; overdue: number }

const d = t.dashboard
const UPCOMING = 5
const buckets = ['overdue', 'due_soon', 'scheduled'] as const

// The shown level: the top locations, but a lone top location with no assets of its own gives way to its
// children (a tenant with one "India" root sees its plants). Counts roll up to it; no location is its own bar.
export function locationBars(rows: Option[], counts: LocationCount[]): Bar[] {
  let level = rows.filter((r) => !r.parent_id || !rows.some((p) => p.id === r.parent_id))
  for (;;) {
    const only = level.length === 1 ? level[0] : undefined
    const kids = only && !counts.some((c) => c.location_id === only.id) ? rows.filter((r) => r.parent_id === only.id) : []
    if (!kids.length) break
    level = kids
  }
  const bars = new Map<string | null, Bar>(level.map((l) => [l.id, { id: l.id, name: placeName(rows, l.id), assets: 0, overdue: 0 }]))
  for (const c of counts) {
    const key = c.location_id ? lineage(rows, c.location_id).find((id) => bars.has(id)) : null
    if (key === undefined) continue
    const bar = bars.get(key) ?? bars.set(key, { id: null, name: d.noLocation, assets: 0, overdue: 0 }).get(key)!
    bar.assets += c.assets
    bar.overdue += c.overdue
  }
  return [...bars.values()].filter((b) => b.assets > 0).sort((a, b) => b.assets - a.assets || a.name.localeCompare(b.name))
}

type Loaded = { key: number; total?: number; counts?: Counts; expiring?: number; upcoming?: Open[]; bars?: LocationCount[] }

export function DashboardPage({ tenantId, can }: { tenantId: string; can: Can }) {
  const tenant = useTenant()
  const [locations, setLocations] = useState<Option[]>([])
  const [reload, setReload] = useState(0)
  const [loaded, setLoaded] = useState<Loaded>()
  const [completing, setCompleting] = useState<Open>()
  // Every read joins asset_view, so each part also needs asset_core.view.
  const seeAssets = can('asset_core', 'view')
  const seeDue = seeAssets && can('obligation', 'view')
  const seeCoverage = seeAssets && can('coverage_contract', 'view')

  useEffect(() => {
    let live = true
    void supabase
      .from('location')
      .select('id, parent_id, name')
      .is('deleted_at', null)
      .then(({ data }) => live && setLocations(data ?? []))
    return () => {
      live = false
    }
  }, [])

  // Independent reads in parallel: the page waits for the slowest (maintenance_counts), not the sum (§14.3).
  useEffect(() => {
    let live = true
    const key = reload
    void Promise.all([
      seeAssets ? supabase.rpc('count_assets', {}) : undefined,
      seeDue ? supabase.rpc('maintenance_counts', {}) : undefined,
      seeCoverage ? supabase.rpc('count_assets', { p_coverage: 'expiring' }) : undefined,
      seeDue ? Promise.all(buckets.map((b) => supabase.rpc('list_obligations', { p_bucket: b, p_limit: UPCOMING }))) : undefined,
      seeAssets ? supabase.rpc('location_asset_counts') : undefined,
    ]).then(([total, counts, expiring, lists, bars]) => {
      if (!live) return
      setLoaded({
        key,
        total: total?.data ?? undefined,
        counts: counts?.data?.[0],
        expiring: expiring?.data ?? undefined,
        upcoming: lists?.flatMap((l) => l.data ?? []).slice(0, UPCOMING),
        bars: bars?.data ?? undefined,
      })
    })
    return () => {
      live = false
    }
  }, [reload, seeAssets, seeDue, seeCoverage])

  const now = loaded?.key === reload ? loaded : undefined
  const num = (n?: number) => (n === undefined ? '…' : n > 10000 ? t.assets.manyCount : n.toLocaleString())
  const tiles = [
    seeAssets && { label: d.tiles.total, value: now?.total, to: '/assets', tone: '' },
    seeDue && { label: d.tiles.due30, value: now?.counts?.next_30, to: '/maintenance?tab=due_soon', tone: '' },
    seeDue && { label: d.tiles.overdue, value: now?.counts?.overdue, to: '/maintenance?tab=overdue', tone: 'error' },
    seeCoverage && {
      label: d.tiles.expiring.replace('{n}', String(tenant?.coverage_expiring_days ?? 60)),
      value: now?.expiring,
      to: '/assets?coverage=expiring',
      tone: 'warn',
    },
  ].filter((x) => !!x)
  const bars = now?.bars && locationBars(locations, now.bars)
  const most = Math.max(1, ...(bars ?? []).map((b) => b.assets))
  const canComplete = can('obligation', 'complete')

  return (
    <>
      <title>{`${t.pages.dashboard} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.dashboard}</h1>
          <span className="muted">{d.subtitle}</span>
        </div>
        <div className="spacer" />
        {can('asset_core', 'create') && (
          <Link className="btn btn-main" to="/assets/new">
            {t.assets.add}
          </Link>
        )}
      </div>
      {tiles.length > 0 && (
        <div className="kpis">
          {tiles.map((k) => (
            <Link key={k.to} className="card kpi" to={k.to} aria-label={d.tileLink.replace('{label}', k.label).replace('{value}', num(k.value))}>
              <span>{k.label}</span>
              <b className={k.tone}>{num(k.value)}</b>
            </Link>
          ))}
        </div>
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
      <div className="dash">
        {seeDue && (
          <section className="card table-wrap upcoming">
            <div className="page-head">
              <h2>{d.upcoming}</h2>
              <div className="spacer" />
              <Link to="/maintenance">{d.viewAll}</Link>
            </div>
            {!now ? (
              <p className="muted" role="status">
                {d.loading}
              </p>
            ) : !now.upcoming?.length ? (
              <p className="muted">{d.noUpcoming}</p>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>{t.maintenance.col.asset}</th>
                    <th>{t.maintenance.col.location}</th>
                    <th>{t.maintenance.col.due}</th>
                    <th>{t.maintenance.col.status}</th>
                    {canComplete && <th aria-label={t.maintenance.col.actions} />}
                  </tr>
                </thead>
                <tbody>
                  {now.upcoming.map((r) => (
                    <tr key={r.id}>
                      <td>
                        <Link className="row-link" to={`/assets/${r.asset_id}`}>
                          {r.asset_name}
                        </Link>{' '}
                        <span className="muted">{r.name}</span>
                      </td>
                      <td className="muted">{placeName(locations, r.location_id)}</td>
                      <td>{showDate(r.next_due_date, tenant)}</td>
                      <td>
                        <StateTag state={r.due_state} />
                      </td>
                      {canComplete && (
                        <td className="actions">
                          <button className="btn" type="button" onClick={() => setCompleting(r)}>
                            {t.obligations.recordCompletion}
                          </button>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
        )}
        {seeAssets && (
          <section className="card by-location">
            <h2>{d.byLocation}</h2>
            {!bars ? (
              <p className="muted" role="status">
                {d.loading}
              </p>
            ) : bars.length === 0 ? (
              <p className="muted">{d.noAssets}</p>
            ) : (
              <ul className="plain-list bars">
                {bars.map((b) => (
                  <li key={b.id ?? ''}>
                    {b.id ? <Link to={`/assets?location_id=${b.id}`}>{b.name}</Link> : <span>{b.name}</span>}
                    <span className="bar" aria-hidden="true">
                      <i style={{ width: `${(b.assets / most) * 100}%` }} />
                    </span>
                    <span className="muted">
                      {b.assets.toLocaleString()}
                      {seeDue && b.overdue > 0 && <span className="error"> · {d.barOverdue.replace('{n}', b.overdue.toLocaleString())}</span>}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )}
      </div>
    </>
  )
}
