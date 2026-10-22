// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { CategoriesPage, inheritedCode, parseOptions, validateField } from './Categories'
import { t } from './i18n'
import { codeFrom, groupStatuses, inheritedSet } from './Statuses'
import { buildTree } from './tree'

const st = (id: string, label: string, system_status: string, code = id, is_active = true) => ({
  id,
  code,
  label,
  system_status,
  tone: 'neutral',
  is_active,
  deleted_at: null,
})
const statusRows = [
  st('s_cal', 'Awaiting calibration', 'under_maintenance', 'awaiting_calibration'),
  st('s_um', 'Under maintenance', 'under_maintenance', 'under_maintenance'),
  st('s_run', 'Running', 'active', 'running'),
  st('s_act', 'Active', 'active', 'active'),
  st('s_old', 'Old', 'active', 'old', false),
  st('s_in', 'In Stock', 'in_stock', 'in_stock'),
]

const db = vi.hoisted(() => ({
  results: {} as Record<string, unknown>,
  writes: [] as unknown[],
}))

// Every query builder call returns the same chain; awaiting it gives the table's mocked result.
// Writes (insert, update) switch the chain to '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order']) q[m] = () => q
    for (const m of ['insert', 'update'])
      q[m] = (v: unknown) => {
        db.writes.push(v)
        key = `${table}:write`
        return q
      }
    q.then = (resolve: (v: unknown) => void) => resolve(db.results[key] ?? { data: [], error: null })
    return q
  }
  return { supabase: { from: chain, rpc: () => chain('rpc') } }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = {
    asset_category: {
      data: [
        { id: 'c1', parent_id: null, name: 'Pumps', code: 'PMP', is_active: true, status_ids: ['s_run', 's_um'] },
        { id: 'c2', parent_id: 'c1', name: 'Booster pumps', code: null, is_active: true, status_ids: null },
      ],
      error: null,
    },
    asset_status: { data: statusRows, error: null },
    rpc: { data: [{ id: 'd1', code: 'asset_core' }], error: null },
  }
  db.writes = []
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const cat = (id: string, name: string, parent_id: string | null = null, code: string | null = null, status_ids: string[] | null = null) => ({
  id,
  name,
  parent_id,
  code,
  is_active: true,
  status_ids,
})

test('the tree builds from flat rows: parents before children, by name, orphans at the top', () => {
  const rows = [cat('b', 'Lathes', 'm'), cat('m', 'Machine tools'), cat('a', 'CNC machines', 'm'), cat('u', 'Utilities'), cat('o', 'Orphan', 'gone')]
  expect(buildTree(rows).map(({ row, depth }) => `${depth}:${row.name}`)).toEqual([
    '0:Machine tools',
    '1:CNC machines',
    '1:Lathes',
    '0:Orphan',
    '0:Utilities',
  ])
})

test('the field form validates key and type', () => {
  const ok = { key: 'rated_kw', label: 'Rated power', type: 'number', options: [], domainId: 'd1' }
  expect(validateField(ok)).toBeUndefined()
  expect(validateField({ ...ok, key: 'Rated kW' })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, key: '1st' })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, key: 'a'.repeat(64) })).toBe(t.categories.errors.key)
  expect(validateField({ ...ok, type: 'money' })).toBe(t.categories.errors.type)
  expect(validateField({ ...ok, type: 'list' })).toBe(t.categories.errors.optionsRequired)
  expect(validateField({ ...ok, domainId: '' })).toBe(t.categories.errors.domain)
})

test('list options parse, and a removed option stays as inactive', () => {
  const existing = [{ code: 'oil', label: 'Oil', is_active: true }, { code: 'gas', label: 'Gas', is_active: true }]
  expect(parseOptions('oil = Mineral oil\nwater', existing)).toEqual([
    { code: 'oil', label: 'Mineral oil', is_active: true },
    { code: 'water', label: 'water', is_active: true },
    { code: 'gas', label: 'Gas', is_active: false },
  ])
})

async function render(canManage: boolean) {
  await act(async () => root.render(<CategoriesPage tenantId="ta" canManage={canManage} />))
}
const buttons = () => [...container.querySelectorAll('button')].map((b) => b.textContent)

test('without manage: no add or edit actions', async () => {
  await render(false)
  expect(container.textContent).toContain('Pumps')
  expect(buttons()).not.toContain(t.categories.addCategory)
  expect(buttons()).not.toContain(t.categories.addField)
  expect(buttons()).not.toContain(t.categories.editCategory)
})

test('a write the database refuses shows the permission message', async () => {
  db.results['asset_category:write'] = { data: null, error: { code: '42501', message: 'new row violates row-level security policy' } }
  await render(true)
  const add = [...container.querySelectorAll('button')].find((b) => b.textContent === t.categories.addCategory)!
  await act(async () => add.click())
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.noPermission)
})

test('a duplicate name shows its own message', async () => {
  db.results['asset_category:write'] = { data: null, error: { code: '23505' } }
  await render(true)
  await act(async () => [...container.querySelectorAll('button')].find((b) => b.textContent === t.categories.editCategory)!.click())
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.duplicateName)
})

const click = (text: string) => act(async () => [...container.querySelectorAll('button')].find((b) => b.textContent === text)!.click())
function type(el: HTMLInputElement | HTMLSelectElement, value: string) {
  const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype
  Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(el, value)
  el.dispatchEvent(new Event(el instanceof HTMLSelectElement ? 'change' : 'input', { bubbles: true }))
}
const codeInput = () => container.querySelector<HTMLInputElement>('[name="code"]')!
const codeHint = () => container.querySelector('#code-hint')!.textContent

test('inheritedCode finds the nearest ancestor with a code', () => {
  const rows = [cat('m', 'Machines', null, 'MC'), cat('c', 'CNC', 'm'), cat('l', 'Lathes', 'c', 'LT')]
  expect(inheritedCode(rows, 'c')?.code).toBe('MC')
  expect(inheritedCode(rows, 'l')?.code).toBe('LT')
  expect(inheritedCode(rows, '')).toBeUndefined()
  expect(inheritedCode([cat('x', 'X')], 'x')).toBeUndefined()
})

test('category code: a bad code is refused before the write', async () => {
  await render(true)
  await click(t.categories.addCategory)
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => type(codeInput(), 'C N C'))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.code)
  expect(db.writes).toEqual([])
})

test('category code: saved as typed, and a duplicate shows its own message', async () => {
  db.results['asset_category:write'] = {
    data: null,
    error: { code: '23505', message: 'duplicate key value violates unique constraint "asset_category_code_uq"' },
  }
  await render(true)
  await click(t.categories.addCategory)
  container.querySelector<HTMLInputElement>('[name="name"]')!.value = 'Compressors'
  await act(async () => type(codeInput(), ' cnc '))
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.writes).toEqual([{ name: 'Compressors', parent_id: null, code: 'cnc', is_active: true, status_ids: null, tenant_id: 'ta' }])
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.categories.errors.duplicateCode)
})

test('category code: with none of its own, the hint shows the code {CAT} inherits', async () => {
  await render(true)
  await click('Booster pumps')
  await click(t.categories.editCategory)
  const inherits = t.categories.codeInherited.replace('{code}', 'PMP').replace('{name}', 'Pumps')
  expect(codeHint()).toContain(inherits)
  await act(async () => type(codeInput(), 'BP'))
  expect(codeHint()).not.toContain(inherits)
  await act(async () => type(codeInput(), ''))
  await act(async () => type(container.querySelector<HTMLSelectElement>('[name="parent"]')!, ''))
  expect(codeHint()).not.toContain(inherits)
})

// Story 3.7b: statuses card and status set picker.
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text || b.getAttribute('aria-label') === text)
const alert = () => container.querySelector('[role="alert"]')?.textContent
const statusForm = () => container.querySelector<HTMLFormElement>('form[aria-label]')!
const input = (name: string) => container.querySelector<HTMLInputElement>(`[name="${name}"]`)!
const select = (selector: string) => container.querySelector<HTMLSelectElement>(selector)!

test('statuses group by system status, default row first, then label', () => {
  const groups = groupStatuses(statusRows)
  expect(groups.map((g) => g.system)).toEqual(['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'])
  expect(groups[1]!.rows.map((r) => r.id)).toEqual(['s_act', 's_old', 's_run'])
  expect(groups[2]!.rows.map((r) => r.id)).toEqual(['s_um', 's_cal'])
  expect(codeFrom('Awaiting calibration')).toBe('awaiting_calibration')
  expect(codeFrom('2nd shift')).toBe('s_2nd_shift')
})

test('the card shows the groups and marks default rows', async () => {
  await render(true)
  const card = container.querySelector('.statuses')!
  expect([...card.querySelectorAll('tbody th')].map((th) => th.textContent)).toEqual(Object.values(t.assets.statuses))
  const rows = [...card.querySelectorAll('tbody tr:has(td)')].map((tr) => tr.textContent)
  expect(rows.find((r) => r?.startsWith('Active'))).toContain(t.categories.statuses.default)
  expect(rows.find((r) => r?.startsWith('Running'))).not.toContain(t.categories.statuses.default)
})

test('without manage: statuses are read-only', async () => {
  await render(false)
  expect(container.querySelector('.statuses')?.textContent).toContain('Running')
  expect(buttons()).not.toContain(t.categories.statuses.add)
  expect(buttons()).not.toContain(t.categories.edit)
})

test('add status: sends label, a code from the label, the system status and its tone', async () => {
  db.results['asset_status:write'] = { data: [{ id: 'new' }], error: null }
  await render(true)
  await click(t.categories.statuses.add)
  await act(async () => type(input('label'), 'Awaiting repair'))
  await act(async () => type(select('[name="system"]'), 'under_maintenance'))
  await act(async () => statusForm().requestSubmit())
  expect(db.writes).toEqual([
    { label: 'Awaiting repair', tone: 'warn', is_active: true, code: 'awaiting_repair', system_status: 'under_maintenance', tenant_id: 'ta' },
  ])
  expect(alert()).toBeUndefined()
})

test('rename, tone and deactivate send one update; a default row cannot be deactivated', async () => {
  db.results['asset_status:write'] = { data: [{ id: 's_run' }], error: null }
  await render(true)
  await act(async () => button(`${t.categories.edit} Active`)!.click())
  expect(input('active').disabled).toBe(true)
  await click(t.categories.cancel)
  await act(async () => button(`${t.categories.edit} Running`)!.click())
  expect(input('code').disabled).toBe(true)
  await act(async () => type(input('label'), 'Running hot'))
  await act(async () => input('active').click())
  await act(async () => type(select('[name="tone"]'), 'error'))
  await act(async () => statusForm().requestSubmit())
  expect(db.writes).toEqual([{ label: 'Running hot', tone: 'error', is_active: false }])
})

test.each([
  [{ code: '23505', message: 'duplicate key value violates unique constraint "asset_status_label_uq"' }, t.categories.errors.duplicateStatusLabel],
  [{ code: '23505', message: 'duplicate key value violates unique constraint "asset_status_tenant_id_code_key"' }, t.categories.errors.duplicateStatusCode],
  [{ code: '22023', message: 'the default status of a system status cannot be deactivated' }, t.categories.errors.defaultStatus],
  [{ code: '42501', message: 'permission denied' }, t.categories.errors.noPermission],
])('a status write error maps to its message (%#)', async (error, message) => {
  db.results['asset_status:write'] = { data: null, error }
  await render(true)
  await act(async () => button(`${t.categories.edit} Running`)!.click())
  await act(async () => statusForm().requestSubmit())
  expect(alert()).toBe(message)
})

test('a set the trigger refuses shows the set message', async () => {
  db.results['asset_category:write'] = { data: null, error: { code: '23514', message: 'status set has an unknown or inactive status' } }
  await render(true)
  await click(t.categories.editCategory)
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(alert()).toBe(t.categories.errors.setInvalid)
})

test('inheritedSet: the nearest ancestor set, else every active status in system order', () => {
  const rows = [cat('m', 'Machines', null, null, ['s_run']), cat('c', 'CNC', 'm'), cat('x', 'Loose')]
  expect(inheritedSet(rows, statusRows, 'c')).toMatchObject({ ids: ['s_run'], from: { id: 'm' } })
  expect(inheritedSet(rows, statusRows, 'x')).toEqual({ ids: ['s_in', 's_act', 's_run', 's_cal', 's_um'], from: undefined })
})

const setItems = () => [...container.querySelectorAll('.set-list li')].map((li) => li.querySelector('.tag')!.textContent)
const radio = (label: string) => [...container.querySelectorAll('label.check')].find((l) => l.textContent === label)!.querySelector('input')!

test('picker: a child inherits and names the source; its own set starts from that and saves in order', async () => {
  db.results['asset_category:write'] = { data: [{ id: 'c2' }], error: null }
  await render(true)
  await click('Booster pumps')
  await click(t.categories.editCategory)
  expect(radio(t.categories.statusSet.inherit).checked).toBe(true)
  expect(container.querySelector('#set-source')!.textContent).toBe(t.categories.statusSet.inheritedFrom.replace('{name}', 'Pumps'))
  expect(setItems()).toEqual(['Running', 'Under maintenance'])
  expect(button(t.categories.statusSet.remove)).toBeUndefined()

  await act(async () => radio(t.categories.statusSet.own).click())
  expect(setItems()).toEqual(['Running', 'Under maintenance'])
  await act(async () => button(`${t.categories.moveDown} Running`)!.click())
  await act(async () => type(select(`[aria-label="${t.categories.statusSet.addLabel}"]`), 's_in'))
  await click(t.categories.statusSet.add)
  expect(setItems()).toEqual(['Under maintenance', 'Running', 'In Stock'])
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.writes).toEqual([{ name: 'Booster pumps', parent_id: 'c1', code: null, is_active: true, status_ids: ['s_um', 's_run', 's_in'] }])
})

test('picker: a set with no start status is refused before the write; back to inherit saves null', async () => {
  db.results['asset_category:write'] = { data: [{ id: 'c1' }], error: null }
  await render(true)
  await click(t.categories.editCategory)
  expect(radio(t.categories.statusSet.own).checked).toBe(true)
  await act(async () => button(`${t.categories.statusSet.remove} Running`)!.click())
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(alert()).toBe(t.categories.errors.setStart)
  expect(db.writes).toEqual([])
  await act(async () => radio(t.categories.statusSet.inherit).click())
  expect(container.querySelector('#set-source')!.textContent).toBe(t.categories.statusSet.inheritedAll)
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.writes).toEqual([{ name: 'Pumps', parent_id: null, code: 'PMP', is_active: true, status_ids: null }])
})
