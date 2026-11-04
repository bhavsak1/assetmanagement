import { useEffect, useState } from 'react'
import { Link, useLocation } from 'react-router'
import { showDate, tenantToday, useTenant } from './Coverage'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Tables } from './types/database'

// Story 9.1 (docs/data-model-goal9.md §11). No screen exists in docs/assetly-screens.html; this follows the shell
// and card styles. RLS returns only the user's own alerts that they may still see.
type Row = Pick<Tables<'notification'>, 'id' | 'event_type' | 'asset_id' | 'payload' | 'read_at' | 'created_at'>
type Payload = { name?: string; asset_name?: string; asset_tag?: string; next_due_date?: string; end_date?: string }
const n = t.notifications

const unreadCount = async () =>
  (await supabase.from('notification').select('id', { count: 'exact', head: true }).is('read_at', null)).count ?? 0

// The text of one alert, from its type and payload snapshot.
export function alertText(row: Pick<Row, 'event_type' | 'payload'>, date: (d?: string) => string) {
  const p = (row.payload ?? {}) as Payload
  const asset = (p.asset_name ?? '') + (p.asset_tag ? ` (${p.asset_tag})` : '')
  const text = n.events[row.event_type as keyof typeof n.events] ?? n.events.other
  return text.replace('{name}', p.name ?? '').replace('{asset}', asset).replace('{date}', date(p.next_due_date ?? p.end_date))
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
  const [rows, setRows] = useState<Row[]>()
  const [digest, setDigest] = useState<boolean>()
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    void supabase.from('notification').select('id, event_type, asset_id, payload, read_at, created_at')
      .order('created_at', { ascending: false }).limit(100)
      .then(({ data, error }) => live && (setRows(data ?? []), setFailed(!!error)))
    void supabase.from('tenant_membership').select('email_digest').eq('tenant_id', tenantId).eq('user_id', userId)
      .then(({ data }) => live && setDigest(data?.[0]?.email_digest))
    return () => {
      live = false
    }
  }, [tenantId, userId, reload])

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
  const unread = rows?.some((r) => !r.read_at)

  return (
    <>
      <title>{`${n.title} · ${t.app.name}`}</title>
      <div className="page-head">
        <h1>{n.title}</h1>
        <div className="spacer" />
        <button className="btn" type="button" disabled={!unread} onClick={() => void markRead()}>
          {n.markAll}
        </button>
      </div>
      <label className="check">
        <input type="checkbox" checked={digest ?? false} disabled={digest === undefined} onChange={(e) => void toggleDigest(e.target.checked)} />
        {n.emailDigest}
      </label>
      <p className="muted">{n.emailHint}</p>
      {failed && <p className="login-error" role="alert">{n.failed}</p>}
      <div className="card table-wrap list">
        {!rows ? null : rows.length === 0 ? (
          <p className="muted">{n.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{n.alert}</th>
                <th>{n.when}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className={r.read_at ? '' : 'unread'}>
                  <td>
                    <Link className="row-link" to={`/assets/${r.asset_id}`} onClick={() => void (r.read_at ? null : markRead([r.id]))}>
                      {alertText(r, date)}
                    </Link>
                    {!r.read_at && <span className="tag status warn">{n.new}</span>}
                  </td>
                  <td className="muted">{date(tenant ? tenantToday(tenant.time_zone, new Date(r.created_at)) : r.created_at.slice(0, 10))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}
