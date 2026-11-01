// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { groupCode, securityError, SecurityPage } from './Security'
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
    for (const m of ['select', 'eq', 'is', 'order', 'single']) q[m] = () => q
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
