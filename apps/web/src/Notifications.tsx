import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router'
import { showDate, tenantToday, useTenant } from './Coverage'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Tables } from './types/database'

// Story 9.1 (docs/data-model-goal9.md §11). No screen exists in docs/assetly-screens.html; this follows the shell
// and card styles. RLS returns only the user's own alerts that they may still see.
// Story 11.4 (DECIDE 1 to 3): tabs by type with unread counts, one row per alert (repeats folded), unread in bold.
type Row = Pick<Tables<'notification'>, 'id' | 'event_type' | 'asset_id' | 'payload' | 'read_at' | 'created_at'>
type Payload = { name?: string; asset_name?: string; asset_tag?: string; next_due_date?: string; end_date?: string }
const n = t.notifications

export const GROUPS = {
  overdue: ['obligation.overdue'],
  due_soon: ['obligation.due_soon'],
  coverage: ['coverage.expiring', 'coverage.expired'],
} as const
type Tab = 'all' | keyof typeof GROUPS
const TABS: Tab[] = ['all', 'overdue', 'due_soon', 'coverage']

const unreadCount = async (types?: readonly string[]) => {
  const q = supabase.from('notification').select('id', { count: 'exact', head: true }).is('read_at', null)
  return (await (types ? q.in('event_type', types) : q)).count ?? 0
}

export type Alert = { row: Row; ids: string[]; unread: boolean }

// The same alert for the same asset and item, raised again, shows once: the newest, unread if any copy is.
// Rows arrive newest first.
export function foldAlerts(rows: Row[]): Alert[] {
  const by = new Map<string, Alert>()
  for (const r of rows) {
    const p = (r.payload ?? {}) as Payload
    const key = `${r.event_type}|${r.asset_id}|${p.name ?? ''}`
    const a = by.get(key)
    if (a) {
      a.ids.push(r.id)
      a.unread ||= !r.read_at
    } else by.set(key, { row: r, ids: [r.id], unread: !r.read_at })
  }
  return [...by.values()]
}

// Top bar link with the unread count. Refreshes on page change and every 2 minutes while the tab is visible.
export function NotificationBell({ tenantId }: { tenantId: string }) {
  const { pathname } = useLocation()
  const [count, setCount] = useState(0)
  useEffect(() => {
    let live = true
    const load = () => void unreadCount().then((c) => live && setCount(c))
    load()
    const timer = setInterval(() => document.visibilityState === 'visible' && load(), 120_000)
    const onChange = () => load()
    window.addEventListener('notifications-changed', onChange)
    return () => {
      live = false
      clearInterval(timer)
      window.removeEventListener('notifications-changed', onChange)
    }
  }, [pathname, tenantId])
  const label = count ? n.bellUnread.replace('{count}', String(count)) : n.bell
  return (
    <Link className="btn bell" to="/notifications" aria-label={label} title={label}>
      {n.bell}
      {count > 0 && <span className="tag status warn">{count > 99 ? '99+' : count}</span>}
    </Link>
  )
}

export function NotificationsPage({ tenantId, userId }: { tenantId: string; userId: string }) {
  const tenant = useTenant()
  const [tab, setTab] = useState<Tab>('all')
  const [unreadOnly, setUnreadOnly] = useState(false)
  const [rows, setRows] = useState<Row[]>()
  const [counts, setCounts] = useState<Partial<Record<Tab, number>>>({})
  const [digest, setDigest] = useState<boolean>()
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    let q = supabase.from('notification').select('id, event_type, asset_id, payload, read_at, created_at')
    if (tab !== 'all') q = q.in('event_type', GROUPS[tab])
    if (unreadOnly) q = q.is('read_at', null)
    void q.order('created_at', { ascending: false }).limit(100)
      .then(({ data, error }) => live && (setRows(data ?? []), setFailed(!!error)))
    return () => {
      live = false
    }
  }, [tab, unreadOnly, reload])

  useEffect(() => {
    let live = true
    void Promise.all(TABS.map((k) => unreadCount(k === 'all' ? undefined : GROUPS[k])))
      .then((c) => live && setCounts(Object.fromEntries(TABS.map((k, i) => [k, c[i]]))))
    return () => {
      live = false
    }
  }, [reload])

  useEffect(() => {
    let live = true
    void supabase.from('tenant_membership').select('email_digest').eq('tenant_id', tenantId).eq('user_id', userId)
      .then(({ data }) => live && setDigest(data?.[0]?.email_digest))
    return () => {
      live = false
    }
  }, [tenantId, userId])

  const changed = () => {
    setReload((r) => r + 1)
    window.dispatchEvent(new Event('notifications-changed'))
  }
  const markRead = async (ids?: string[]) => {
    const q = supabase.from('notification').update({ read_at: new Date().toISOString() }).is('read_at', null)
    const { error } = await (ids ? q.in('id', ids) : q)
    setFailed(!!error)
    changed()
  }
  const toggleDigest = async (on: boolean) => {
    const { data, error } = await supabase.rpc('set_email_digest', { p_on: on })
    setFailed(!!error)
    if (!error) setDigest(data ?? on)
  }
  const date = (d?: string) => showDate(d, tenant)
  const alerts = rows && foldAlerts(rows)

  return (
    <>
      <title>{`${n.title} · ${t.app.name}`}</title>
      <div className="page-head">
        <h1>{n.title}</h1>
        <div className="spacer" />
        <button className="btn" type="button" disabled={!counts.all} onClick={() => void markRead()}>
          {n.markAll}
        </button>
      </div>
      <label className="check">
        <input type="checkbox" checked={digest ?? false} disabled={digest === undefined} onChange={(e) => void toggleDigest(e.target.checked)} />
        {n.emailDigest}
      </label>
      <p className="muted">{n.emailHint}</p>
      {failed && <p className="login-error" role="alert">{n.failed}</p>}
      <div className="tabs" role="tablist">
        {TABS.map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
            {n.tabs[k]}
            {!!counts[k] && ` · ${counts[k]}`}
          </button>
        ))}
      </div>
      <label className="check">
        <input type="checkbox" checked={unreadOnly} onChange={(e) => setUnreadOnly(e.target.checked)} />
        {n.unreadOnly}
      </label>
      <div className="card table-wrap list">
        {!alerts ? null : alerts.length === 0 ? (
          <p className="muted">{tab === 'all' && !unreadOnly ? n.none : n.noneHere}</p>
        ) : (
          <table className="alerts">
            <thead>
              <tr>
                <th>{n.alert}</th>
                <th>{n.asset}</th>
                <th>{n.due}</th>
                <th>{n.when}</th>
              </tr>
            </thead>
            <tbody>
              {alerts.map(({ row: r, ids, unread }) => {
                const p = (r.payload ?? {}) as Payload
                const type = n.types[r.event_type as keyof typeof n.types] ?? n.types.other
                const tone = r.event_type === 'obligation.overdue' || r.event_type === 'coverage.expired' ? 'error' : 'warn'
                return (
                  <tr key={r.id} className={unread ? 'unread' : ''}>
                    <td>
                      {unread && <span className="sr-only">{n.unread}: </span>}
                      <span className={`tag status ${tone}`}>{type}</span> {p.name}
                      {ids.length > 1 && <span className="muted"> · {n.repeats.replace('{n}', String(ids.length))}</span>}
                    </td>
                    <td>
                      <Link className="row-link" to={`/assets/${r.asset_id}`} onClick={() => void (unread ? markRead(ids) : null)}>
                        {p.asset_name}
                        {p.asset_tag && ` (${p.asset_tag})`}
                      </Link>
                    </td>
                    <td className="nowrap">{date(p.next_due_date ?? p.end_date)}</td>
                    <td className="muted nowrap">{date(tenant ? tenantToday(tenant.time_zone, new Date(r.created_at)) : r.created_at.slice(0, 10))}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}
