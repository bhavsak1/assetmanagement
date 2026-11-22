// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { foldAlerts, GROUPS, NotificationBell, NotificationsPage } from './Notifications'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  calls: [] as string[],
}))

// Chain mock: records each table call and its filters; resolves the table's result.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'in', 'order', 'limit', 'update']) {
      q[m] = (...args: unknown[]) => {
        db.calls.push(`${table}.${m}:${JSON.stringify(m === 'update' ? Object.keys(args[0] as object) : args.slice(0, 2))}`)
        return q
      }
    }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args: Record<string, unknown>) => {
    db.calls.push(`rpc.${fn}:${JSON.stringify(args)}`)
    return Promise.resolve({ data: args.p_on, error: null })
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
const n = t.notifications
const row = (id: string, read: boolean) => ({
  id, event_type: 'obligation.overdue', asset_id: `a-${id}`, read_at: read ? '2026-11-04T00:00:00Z' : null, created_at: '2026-11-04T03:00:00Z',
  payload: { name: 'Service', asset_name: 'Lathe', asset_tag: 'AST-1', next_due_date: '2026-11-01' },
})

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.calls = []
  db.results = {
    tenant: { data: [{ time_zone: 'Asia/Kolkata', date_format: 'dd-MM-yyyy', locale: 'en-IN', currency_code: 'INR', coverage_expiring_days: 60 }], error: null },
    notification: { data: [row('1', false), row('2', true)], count: 1, error: null },
    tenant_membership: { data: [{ email_digest: true }], error: null },
  }
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const render = async (el: React.ReactNode) => {
  await act(async () => root.render(<MemoryRouter>{el}</MemoryRouter>))
  await act(async () => {})
}

test('foldAlerts: repeats of one alert show once, newest first, unread if any copy is', () => {
  const old = { ...row('3', false), created_at: '2026-11-01T03:00:00Z' }
  const other = { ...row('4', true), payload: { ...row('4', true).payload, name: 'Calibration' } }
  const f = foldAlerts([{ ...row('2', true), asset_id: 'a-1' }, { ...old, asset_id: 'a-1' }, other])
  expect(f).toHaveLength(2)
  expect(f[0]).toMatchObject({ ids: ['2', '3'], unread: true })
  expect(f[0]!.row.id).toBe('2')
  expect(f[1]).toMatchObject({ ids: ['4'], unread: false })
})

test('bell shows the unread count and links to the page', async () => {
  await render(<NotificationBell tenantId="t1" />)
  const link = container.querySelector('a.bell')!
  expect(link.getAttribute('href')).toBe('/notifications')
  expect(link.getAttribute('aria-label')).toBe(n.bellUnread.replace('{count}', '1'))
  expect(db.calls).toContain('notification.is:["read_at",null]')
})

test('page lists alerts as rows in the tenant date format, unread marked for screen readers', async () => {
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  const rows = [...container.querySelectorAll('tbody tr')]
  expect(rows).toHaveLength(2)
  expect(rows[0]!.className).toBe('unread')
  expect(rows[0]!.textContent).toContain(n.types['obligation.overdue'])
  expect(rows[0]!.textContent).toContain('Lathe (AST-1)')
  expect(rows[0]!.textContent).toContain('01-11-2026')
  expect(rows[0]!.querySelector('.sr-only')!.textContent).toContain(n.unread)
  expect(rows[1]!.querySelector('.sr-only')).toBeNull()
  expect(rows[0]!.querySelector('a')!.getAttribute('href')).toBe('/assets/a-1')
  expect(db.calls).toContain('tenant_membership.eq:["user_id","u1"]')
})

test('tabs filter by type and show unread counts; unread only filters read_at', async () => {
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  const tabs = [...container.querySelectorAll('[role="tab"]')]
  expect(tabs.map((b) => b.textContent)).toEqual([`${n.tabs.all} · 1`, `${n.tabs.overdue} · 1`, `${n.tabs.due_soon} · 1`, `${n.tabs.coverage} · 1`])
  db.calls = []
  await act(async () => (tabs[3] as HTMLButtonElement).click())
  expect(db.calls).toContain(`notification.in:["event_type",${JSON.stringify(GROUPS.coverage)}]`)
  expect(tabs[3]!.getAttribute('aria-selected')).toBe('true')
  db.calls = []
  const only = [...container.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')][1]!
  await act(async () => only.click())
  expect(db.calls).toContain('notification.is:["read_at",null]')
})

test('mark all as read updates read_at only on unread rows', async () => {
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  const button = [...container.querySelectorAll('button')].find((b) => b.textContent === n.markAll)!
  db.calls = []
  await act(async () => button.click())
  expect(db.calls).toContain('notification.update:["read_at"]')
  expect(db.calls).toContain('notification.is:["read_at",null]')
})

test('the email switch calls set_email_digest', async () => {
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  const box = container.querySelector<HTMLInputElement>('input[type="checkbox"]')!
  expect(box.checked).toBe(true)
  await act(async () => box.click())
  expect(db.calls).toContain('rpc.set_email_digest:{"p_on":false}')
  expect(box.checked).toBe(false)
})

test('empty inbox', async () => {
  db.results.notification = { data: [], count: 0, error: null }
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  expect(container.textContent).toContain(n.none)
})
