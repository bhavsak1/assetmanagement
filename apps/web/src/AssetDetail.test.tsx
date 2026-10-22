// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetDetailPage, changes, historyTitle, moreCursor, type History } from './AssetDetail'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: [] as { fn: string; args: Record<string, unknown> }[],
}))

// Chain mock: awaiting a table query gives its result; rpc calls are recorded.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order', 'in']) q[m] = () => q
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [], error: null })
    return q
  }
  const rpc = (fn: string, args: Record<string, unknown>) => {
    db.rpc.push({ fn, args })
    const r = db.results[fn]
    return Promise.resolve(typeof r === 'function' ? (r as (a: unknown) => unknown)(args) : (r ?? { data: [], error: null }))
  }
  return { supabase: { from: chain, rpc } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const row = (n: number, over: Partial<History> = {}): History => ({
  id: `h${n}`,
  occurred_at: new Date(Date.UTC(2026, 9, 22, 10, 0, 100 - n)).toISOString(),
  action: 'update',
  actor_type: 'user',
  actor_name: 'Test User',
  old_data: { name: `Pump ${n}` },
  new_data: { name: `Pump ${n + 1}` },
  hidden_fields: [],
  ...over,
})

const label = (k: string) => k
const show = (_k: string, v: unknown) => (v === undefined || v === null ? '—' : String(v))

test('changes: changed fields old → new, custom keys, masked fields; bookkeeping columns skipped', () => {
  const r = row(1, {
    old_data: { name: 'A', updated_at: 'x', custom_values: { head_m: 30, rpm: 5 } },
    new_data: { name: 'B', updated_at: 'y', custom_values: { head_m: 31, rpm: 5 } },
    hidden_fields: ['purchase_value', 'custom.cost_rate'],
  })
  expect(changes(r, label, show)).toEqual([
    { field: 'name', from: 'A', to: 'B' },
    { field: 'custom.head_m', from: '30', to: '31' },
    { field: 'purchase_value', hidden: true },
    { field: 'custom.cost_rate', hidden: true },
  ])
})

test('changes: a create lists only the values that were set', () => {
  const r = row(1, { action: 'insert', old_data: null, new_data: { id: 'a', name: 'A', model: null, custom_values: {} } })
  expect(changes(r, label, show)).toEqual([{ field: 'name', from: '—', to: 'A' }])
  expect(historyTitle(r)).toBe(t.assetDetail.history.created)
  expect(historyTitle(row(2, { new_data: { status: 'inactive' } }))).toBe(t.assetDetail.history.statusChanged)
  expect(historyTitle(row(3))).toBe(t.assetDetail.history.updated)
})

test('moreCursor: only after a full page, from the last row shown', () => {
  const page = Array.from({ length: 51 }, (_, i) => row(i))
  expect(moreCursor(page)).toEqual({ p_before: page[49]!.occurred_at, p_before_id: 'h49' })
  expect(moreCursor(page.slice(0, 50))).toBeUndefined()
})

let container: HTMLDivElement
let root: Root

beforeEach(() => {
  db.rpc = []
  db.results = {
    asset_view: {
      data: [
        {
          id: 'a1', tenant_id: 'ta', tag: 'PNE-0412', name: 'CNC Lathe 04', category_id: 'c1', location_id: 'l2', status: 'active',
          status_reason: null, status_changed_at: null, quantity: 1, parent_asset_id: null, criticality: 'A', serial_number: 'SN1',
          manufacturer: 'Make', model: 'M1', purchase_date: '2026-01-05', purchase_value: null, purchase_currency: null,
          in_service_date: null, custom_values: { head_m: 30 }, created_at: '', updated_at: '', created_by: null, updated_by: null,
        },
      ],
      error: null,
    },
    asset_category: { data: [{ id: 'c1', parent_id: null, name: 'Machine tools', is_active: true }], error: null },
    location: { data: [{ id: 'l1', parent_id: null, name: 'Plant 1' }, { id: 'l2', parent_id: 'l1', name: 'Bay 3' }], error: null },
    field_definition: {
      data: [
        { id: 'f1', key: 'head_m', label: 'Head', unit: 'm', type: 'number', category_id: null, is_active: true, deleted_at: null, sort_order: 1, security_domain_id: 'd-core' },
        { id: 'f2', key: 'cost_rate', label: 'Cost rate', unit: null, type: 'number', category_id: null, is_active: true, deleted_at: null, sort_order: 2, security_domain_id: 'd-fin' },
      ],
      error: null,
    },
    field_domains: { data: [{ id: 'd-core', code: 'asset_core' }, { id: 'd-fin', code: 'asset_financials' }], error: null },
    tenant: { data: [{ time_zone: 'Asia/Kolkata' }], error: null },
  }
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(grants: string[]) {
  const can = (domain: string, op: string) => grants.includes(`${domain}.${op}`)
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={['/assets/a1']}>
        <Routes>
          <Route path="/assets/:assetId" element={<AssetDetailPage can={can} />} />
        </Routes>
      </MemoryRouter>,
    ),
  )
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)!

test('overview: paths, status tag, masked money and custom field show as Hidden, no Edit without update', async () => {
  await render(['asset_core.view'])
  expect(container.querySelector('h1')?.textContent).toContain('CNC Lathe 04')
  expect(container.querySelector('.tag.status.ok')?.textContent).toBe(t.assets.statuses.active)
  expect(container.textContent).toContain('Plant 1 › Bay 3')
  expect(container.textContent).toContain('30')
  expect([...container.querySelectorAll('.kv .tag')].map((x) => x.textContent)).toEqual([t.assetDetail.hidden, t.assetDetail.hidden])
  expect(container.textContent).not.toContain(t.assetDetail.edit)
  expect(button(t.assetDetail.tabs.coverage).disabled).toBe(true)
})

test('overview: Edit links to the form with update', async () => {
  await render(['asset_core.view', 'asset_core.update', 'asset_financials.view'])
  expect(container.querySelector('a.btn-main')?.getAttribute('href')).toBe('/assets/a1/edit')
  expect(container.querySelectorAll('.kv .tag')).toHaveLength(0)
})

test('audit: rows with actor and hidden values; Load more asks after the last row and appends', async () => {
  const first = Array.from({ length: 51 }, (_, i) => row(i))
  first[0] = row(0, { actor_type: 'system', actor_name: null as unknown as string, hidden_fields: ['purchase_value'] })
  db.results.asset_history = (args: { p_before?: string }) => ({ data: args.p_before ? [row(60, { actor_name: null as unknown as string })] : first, error: null })
  await render(['asset_core.view'])
  await act(async () => button(t.assetDetail.tabs.audit).click())
  expect(container.querySelectorAll('.history ol > li')).toHaveLength(50)
  expect(container.textContent).toContain(t.assetDetail.history.system)
  expect(container.textContent).toContain(`${t.settings.assetFields.purchase_value}: ${t.assetDetail.hidden}`)
  expect(container.textContent).toContain(`${t.assetForm.name}: Pump 1 → Pump 2`)
  await act(async () => button(t.assetDetail.history.more).click())
  expect(db.rpc.at(-1)?.args).toEqual({ p_asset_id: 'a1', p_limit: 51, p_before: first[49]!.occurred_at, p_before_id: 'h49' })
  expect(container.querySelectorAll('.history ol > li')).toHaveLength(51)
  expect(container.textContent).toContain(t.assetDetail.history.formerMember)
  expect(container.textContent).not.toContain(t.assetDetail.history.more)
})
