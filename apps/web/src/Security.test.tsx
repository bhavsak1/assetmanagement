// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { groupCode, securityError, SecurityPage, toCsv } from './Security'
import { t } from './i18n'

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  rpc: vi.fn(),
  writes: [] as { table: string; op: string; values: unknown }[],
}))

// Awaiting a chain gives the table's result; insert and update are recorded. rpc() returns db.rpc's result.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order', 'single', 'limit']) q[m] = () => q
    for (const op of ['insert', 'update'])
      q[op] = (values: unknown) => {
        db.writes.push({ table, op, values })
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[table] ?? { data: [{ id: 'new' }], error: null })
    return q
  }
  return { supabase: { from: chain, rpc: (...args: unknown[]) => Promise.resolve(db.rpc(...args)) } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

const s = t.security
let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.writes = []
  db.results = {
    security_group: { data: [{ id: 'g1', code: 'plant_manager', name: 'Plant Manager', group_type: 'role' }], error: null },
    security_domain: {
      data: [
        { id: 'd1', code: 'asset_core', description: 'Asset register records', domain_operation: [{ id: 'o-update', code: 'update', sort_order: 3 }, { id: 'o-view', code: 'view', sort_order: 1 }] },
        { id: 'd2', code: 'asset_lifecycle', description: 'Lifecycle', domain_operation: [{ id: 'o-exec', code: 'execute', sort_order: 1 }] },
        { id: 'd3', code: 'rls_sample', description: 'Template', domain_operation: [{ id: 'o-rls', code: 'view', sort_order: 1 }] },
      ],
      error: null,
    },
    group_domain_policy: { data: [{ domain_operation_id: 'o-view' }], error: null },
    user_group_assignment: {
      data: [{ id: 'a1', user_id: 'u1', security_group_id: 'g1', scope_profile_id: null, effective_from: '2026-10-01T00:00:00Z', effective_to: null }],
      error: null,
    },
    scope_profile: { data: [{ id: 'p1', name: 'Pune plant' }], error: null },
    scope_profile_rule: { data: [{ id: 'r1', scope_profile_id: 'p1', dimension: 'location', location_id: 'l1', category_id: null }], error: null },
    location: { data: [{ id: 'l1', parent_id: null, name: 'Pune' }], error: null },
    asset_category: { data: [], error: null },
    policy_change_set: { data: [], error: null },
    policy_change_set_item: { data: [], error: null },
  }
  db.rpc.mockReset().mockImplementation((name: string) =>
    name === 'security_members' ? { data: [{ user_id: 'u1', display_name: 'Priya', email: 'priya@example.com', status: 'active' }], error: null } : { data: null, error: null },
  )
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(canView: boolean, canManage: boolean) {
  await act(async () => root.render(<SecurityPage tenantId="ta" canView={canView} canManage={canManage} />))
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text)
const box = (op: string) => [...container.querySelectorAll('label.op')].find((l) => l.textContent === op)!.querySelector('input')!

test('groupCode follows the code check and avoids live codes', () => {
  expect(groupCode('Pune Plant Manager', [])).toBe('g_pune_plant_manager')
  expect(groupCode('Pune Plant Manager', ['g_pune_plant_manager'])).toBe('g_pune_plant_manager_2')
  expect(groupCode('  ', [])).toMatch(/^[a-z][a-z0-9_]*$/)
})

test('database errors map to one message each', () => {
  expect(securityError({ code: '42501', message: 'last security admin' })).toBe(s.errors.lastAdmin)
  expect(securityError({ code: '42501', message: 'not allowed' })).toBe(s.errors.noPermission)
  expect(securityError({ code: '23503', message: 'security group is assigned' })).toBe(s.errors.groupAssigned)
  expect(securityError({ code: '23505' })).toBe(s.errors.duplicate)
})

test('without view: nothing shown', async () => {
  await render(false, false)
  expect(container.textContent).toContain(s.noAccess)
  expect(container.querySelector('table')).toBeNull()
})

test('grid: each domain shows its own operations; view only is read-only', async () => {
  await render(true, false)
  expect(container.textContent).toContain('Plant Manager · domain policies')
  const rows = [...container.querySelectorAll('tbody th')].map((th) => th.textContent)
  expect(rows).toEqual([s.domains.asset_core, s.domains.asset_lifecycle])
  const ops = [...container.querySelectorAll('tbody tr')][0]!.querySelectorAll('label.op')
  expect([...ops].map((l) => l.textContent)).toEqual([s.ops.view, s.ops.update])
  expect(box(s.ops.view).checked).toBe(true)
  expect(box(s.ops.view).disabled).toBe(true)
  expect(button(s.save)).toBeUndefined()
})

test('grid: Save sends the whole set to set_group_policies', async () => {
  await render(true, true)
  expect(button(s.save)!.disabled).toBe(true)
  await act(async () => box(s.ops.execute).click())
  await act(async () => box(s.ops.view).click())
  expect(container.textContent).toContain(s.groups.unsaved)
  await act(async () => button(s.save)!.click())
  expect(db.rpc).toHaveBeenCalledWith('set_group_policies', { p_group_id: 'g1', p_operation_ids: ['o-exec'] })
})

test('grid: the lock-out refusal is shown', async () => {
  await render(true, true)
  db.rpc.mockReturnValue({ data: null, error: { code: '42501', message: 'last security admin' } })
  await act(async () => box(s.ops.view).click())
  await act(async () => button(s.save)!.click())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(s.errors.lastAdmin)
})

test('assignments: member names and a scope picker that updates the assignment', async () => {
  await render(true, true)
  await act(async () => button(s.tabs.assignments)!.click())
  expect(container.textContent).toContain('Priya')
  const picker = container.querySelector<HTMLSelectElement>(`select[aria-label="${s.assignments.scope}"]`)!
  expect(picker.value).toBe('')
  picker.value = 'p1'
  await act(async () => picker.dispatchEvent(new Event('change', { bubbles: true })))
  expect(db.writes).toContainEqual({ table: 'user_group_assignment', op: 'update', values: { scope_profile_id: 'p1' } })
})

test('scope profiles: rules and assigned count', async () => {
  db.results.user_group_assignment = {
    data: [{ id: 'a1', user_id: 'u1', security_group_id: 'g1', scope_profile_id: 'p1', effective_from: '2026-10-01T00:00:00Z', effective_to: null }],
    error: null,
  }
  await render(true, false)
  await act(async () => button(s.tabs.profiles)!.click())
  expect(container.textContent).toContain(`Pune ${s.profiles.andBelow}`)
  expect(container.textContent).toContain(s.profiles.users.replace('{n}', '1'))
})

// 6.4: a draft that adds asset_core update to Plant Manager.
function withDraft() {
  db.results.policy_change_set = {
    data: [
      { id: 'cs2', status: 'draft', created_by: 'u1', activated_by: null, activated_at: null, created_at: '2026-11-01T10:00:00Z' },
      { id: 'cs1', status: 'activated', created_by: 'u1', activated_by: 'u1', activated_at: '2026-10-30T10:00:00Z', created_at: '2026-10-30T09:00:00Z' },
    ],
    error: null,
  }
  db.results.policy_change_set_item = { data: [{ policy_change_set_id: 'cs2', security_group_id: 'g1', operation_ids: ['o-view', 'o-update'] }], error: null }
  const diff = [{ security_group_id: 'g1', group_name: 'Plant Manager', domain_code: 'asset_core', operation_code: 'update', change: 'add' }]
  db.rpc.mockImplementation((name: string) =>
    name === 'security_members'
      ? { data: [{ user_id: 'u1', display_name: 'Priya', email: 'priya@example.com', status: 'active' }], error: null }
      : name === 'change_set_diff'
        ? { data: diff, error: null }
        : { data: null, error: null },
  )
}

test('draft: banner, Draft tag, the drafted set in the grid, and Revert sends the live set', async () => {
  withDraft()
  await render(true, true)
  expect(container.querySelector('[role="status"]')?.textContent).toBe(s.changes.pending.replace('{n}', '1'))
  expect(button(s.changes.review)).toBeDefined()
  expect(container.textContent).toContain(s.groups.draft)
  expect(box(s.ops.update).checked).toBe(true)
  await act(async () => button(s.groups.revert)!.click())
  expect(db.rpc).toHaveBeenCalledWith('set_group_policies', { p_group_id: 'g1', p_operation_ids: ['o-view'] })
})

test('change sets: the diff, Activate and Discard, and the history', async () => {
  withDraft()
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  await render(true, true)
  await act(async () => button(s.changes.review)!.click())
  expect(container.textContent).toContain(`${s.changes.add} ${s.domains.asset_core} · ${s.ops.update}`)
  expect(container.textContent).toContain(s.changes.draftedBy.replace('{name}', 'Priya'))
  expect(container.textContent).toContain(s.changes.statuses.activated)
  await act(async () => button(s.changes.activate)!.click())
  expect(db.rpc).toHaveBeenCalledWith('activate_change_set', { p_change_set_id: 'cs2' })
  await act(async () => button(s.changes.discard)!.click())
  expect(db.rpc).toHaveBeenCalledWith('discard_change_set', { p_change_set_id: 'cs2' })
})

test('change sets: view only sees the draft but cannot activate', async () => {
  withDraft()
  await render(true, false)
  expect(container.querySelector('[role="status"]')).not.toBeNull()
  expect(button(s.changes.review)).toBeUndefined()
  await act(async () => button(s.tabs.changes)!.click())
  expect(container.textContent).toContain(s.domains.asset_core)
  expect(button(s.changes.activate)).toBeUndefined()
})

test('csv: every cell quoted, quotes doubled, formulas defused', () => {
  expect(toCsv([['Name', 'Note'], ['Priya "P"', '=SUM(A1)']])).toBe(['"Name","Note"', `"Priya ""P""","'=SUM(A1)"`].join('\r\n'))
})

test('access review: rows with sensitive fields, filtered by domain', async () => {
  ;(db.results.security_domain as { data: unknown[] }).data.push({ id: 'd4', code: 'asset_financials', kind: 'field', description: 'Money', domain_operation: [{ id: 'o-fin', code: 'view', sort_order: 1 }] })
  db.results.group_domain_policy = { data: [{ security_group_id: 'g1', domain_operation_id: 'o-fin' }], error: null }
  await render(true, false)
  await act(async () => button(s.tabs.review)!.click())
  const cells = [...container.querySelectorAll('tbody td')].map((td) => td.textContent)
  expect(cells).toEqual(['Priya', 'priya@example.com', s.review.memberStatuses.active, 'Plant Manager', s.assignments.tenantWide, '2026-10-01', s.assignments.open, s.review.states.active, s.domains.asset_financials])
  const filter = container.querySelector<HTMLSelectElement>(`select[aria-label="${s.review.domain}"]`)!
  expect(filter.querySelector('optgroup')!.label).toBe(s.review.sensitive)
  filter.value = 'asset_lifecycle'
  await act(async () => filter.dispatchEvent(new Event('change', { bubbles: true })))
  expect(container.textContent).toContain(s.review.none)
  expect(button(s.review.export)!.disabled).toBe(true)
})

test('explainer: verdict and the reason per assignment', async () => {
  await render(true, false)
  await act(async () => button(s.explain.open)!.click())
  db.rpc.mockImplementation((name: string) =>
    name === 'explain_access'
      ? {
          data: [
            { group_name: 'Plant Manager', scope_profile_name: 'Pune plant', effective_from: '2026-10-01T00:00:00Z', effective_to: null, outcome: 'out_of_scope', draft: 'add', note: null },
            { group_name: null, outcome: 'denied', draft: null, note: null },
          ],
          error: null,
        }
      : { data: [], error: null },
  )
  const member = container.querySelector<HTMLSelectElement>('select[name="user"]')!
  member.value = 'u1'
  await act(async () => container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  expect(db.rpc).toHaveBeenCalledWith('explain_access', { p_user_id: 'u1', p_domain: 'asset_core', p_operation: 'view', p_asset_id: undefined })
  expect(container.querySelector('[role="status"]')!.textContent).toContain(s.explain.cannot.replace('{name}', 'Priya').replace('{op}', s.ops.view.toLowerCase()).replace('{domain}', s.domains.asset_core))
  expect(container.textContent).toContain(s.explain.outcomes.out_of_scope)
  expect(container.textContent).toContain(s.explain.drafts.add)
})

test('explainer: an asset tag the caller cannot see is not found', async () => {
  db.results.asset_view = { data: [], error: null }
  await render(true, false)
  await act(async () => button(s.explain.open)!.click())
  container.querySelector<HTMLSelectElement>('select[name="user"]')!.value = 'u1'
  container.querySelector<HTMLInputElement>('input[name="tag"]')!.value = 'MUM-1'
  await act(async () => container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(s.explain.assetNotFound)
  expect(db.rpc).not.toHaveBeenCalledWith('explain_access', expect.anything())
})

// 9.2: integration users and API keys.
const KEY = 'asly_AbCdEfGhIjKl_' + 'x'.repeat(43)
function integrationRpc() {
  db.rpc.mockReset().mockImplementation((name: string) => {
    if (name === 'security_members')
      return {
        data: [
          { user_id: 'u1', display_name: 'Priya', email: 'priya@example.com', status: 'active', kind: 'person' },
          { user_id: 'i1', display_name: 'ERP sync', email: 'i1@integration.invalid', status: 'active', kind: 'integration' },
        ],
        error: null,
      }
    if (name === 'api_keys')
      return { data: [{ id: 'k1', user_id: 'i1', name: 'Main', prefix: 'AbCdEfGhIjKl', expires_at: '2999-01-01T00:00:00Z', revoked_at: null, last_used_at: null, created_at: '2026-11-05T00:00:00Z' }], error: null }
    if (name === 'create_api_key') return { data: [{ id: 'k2', key: KEY }], error: null }
    return { data: 'ok', error: null }
  })
}

test('integrations: the tab needs api_keys.view', async () => {
  integrationRpc()
  await render(true, true)
  expect(button(s.tabs.integrations)).toBeUndefined()
})

test('integrations: lists users and keys, shows a new key once, revokes', async () => {
  integrationRpc()
  await act(async () => root.render(<SecurityPage tenantId="ta" canView canManage canViewKeys canManageKeys />))
  await act(async () => button(s.tabs.integrations)!.click())
  expect(container.textContent).toContain(`ERP sync ${s.integrations.tag}`)
  expect(container.textContent).not.toContain('i1@integration.invalid')
  expect(container.textContent).toContain('asly_AbCdEfGhIjKl_…')

  await act(async () => button(s.integrations.newKey)!.click())
  container.querySelector<HTMLInputElement>('form input[name="name"]')!.value = 'Nightly'
  await act(async () => container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  expect(db.rpc).toHaveBeenCalledWith('create_api_key', expect.objectContaining({ p_user_id: 'i1', p_name: 'Nightly' }))
  expect(container.querySelector('[role="status"] code')?.textContent).toBe(KEY)
  await act(async () => button(s.integrations.done)!.click())
  expect(container.textContent).not.toContain(KEY)

  vi.spyOn(window, 'confirm').mockReturnValue(true)
  await act(async () => button(s.integrations.revoke)!.click())
  expect(db.rpc).toHaveBeenCalledWith('revoke_api_key', { p_key_id: 'k1' })
})

test('integrations: view only has no buttons', async () => {
  integrationRpc()
  await act(async () => root.render(<SecurityPage tenantId="ta" canView canManage={false} canViewKeys canManageKeys={false} />))
  await act(async () => button(s.tabs.integrations)!.click())
  expect(button(s.integrations.add)).toBeUndefined()
  expect(button(s.integrations.newKey)).toBeUndefined()
  expect(button(s.integrations.revoke)).toBeUndefined()
})
