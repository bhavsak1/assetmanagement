// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { alertText, NotificationBell, NotificationsPage } from './Notifications'

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

test('alertText: every event type, unknown types fall back', () => {
  const date = (d?: string) => d ?? ''
  expect(alertText(row('1', false), date)).toBe('Overdue: Service on Lathe (AST-1), due 2026-11-01')
  expect(alertText({ event_type: 'coverage.expired', payload: { asset_name: 'Boiler', end_date: '2026-10-31' } }, date))
    .toBe('Coverage expired: Boiler, ended 2026-10-31')
  expect(alertText({ event_type: 'x.y', payload: { asset_name: 'Boiler' } }, date)).toBe('Alert on Boiler')
})

test('bell shows the unread count and links to the page', async () => {
  await render(<NotificationBell tenantId="t1" />)
  const link = container.querySelector('a.bell')!
  expect(link.getAttribute('href')).toBe('/notifications')
  expect(link.getAttribute('aria-label')).toBe(n.bellUnread.replace('{count}', '1'))
  expect(db.calls).toContain('notification.is:["read_at",null]')
})

test('page lists alerts in the tenant date format, unread first marked new', async () => {
  await render(<NotificationsPage tenantId="t1" userId="u1" />)
  const rows = [...container.querySelectorAll('tbody tr')]
  expect(rows).toHaveLength(2)
  expect(rows[0]!.className).toBe('unread')
  expect(rows[0]!.textContent).toContain('Overdue: Service on Lathe (AST-1), due 01-11-2026')
  expect(rows[0]!.textContent).toContain(n.new)
  expect(rows[1]!.textContent).not.toContain(n.new)
  expect(rows[0]!.querySelector('a')!.getAttribute('href')).toBe('/assets/a-1')
  expect(db.calls).toContain('tenant_membership.eq:["user_id","u1"]')
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
