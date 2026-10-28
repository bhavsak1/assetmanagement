// @vitest-environment jsdom
import { act, useState } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import {
  addStep,
  CategoryDefaults,
  defaultAnchor,
  firstDue,
  inheritedDefaults,
  obligationError,
  ObligationsTab,
  ruleText,
  stateTone,
  validateRule,
  validateRules,
  type Defaults,
  type Rule,
} from './Obligations'

const db = vi.hoisted(() => ({ results: {} as Record<string, unknown>, writes: [] as unknown[] }))

// Every builder call returns the chain; awaiting it gives the table's result. Writes switch to '<table>:write'.
vi.mock('./supabase', () => {
  const chain = (table: string) => {
    let key = table
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'order', 'in']) q[m] = () => q
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
const o = t.obligations
const s = t.categories.defaults

let root: Root
let container: HTMLDivElement
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  db.results = { tenant: { data: [{ time_zone: 'UTC', date_format: 'YYYY-MM-DD', locale: 'en-IN', currency_code: 'INR' }], error: null } }
  db.writes = []
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const rule = (r: Partial<Rule> = {}): Rule => ({ name: 'Quarterly service', obligation_type: 'service', interval_count: 3, interval_unit: 'month', anchor: 'completion', ...r })

test('rule text', () => {
  expect(ruleText(rule())).toBe('Every 3 months · from last completion')
  expect(ruleText(rule({ interval_count: 1, interval_unit: 'year', anchor: 'fixed' }))).toBe('Every year · fixed dates')
  expect(ruleText(rule({ interval_count: 2, interval_unit: 'week' }))).toBe('Every 2 weeks · from last completion')
})

test('state tags map to the design tones', () => {
  expect(['overdue', 'due_soon', 'scheduled', 'paused', 'odd'].map(stateTone)).toEqual(['error', 'warn', 'ok', 'neutral', 'neutral'])
})

test('type picks the default anchor (OQ-03)', () => {
  expect(['service', 'calibration', 'inspection', 'certificate'].map(defaultAnchor)).toEqual(['completion', 'fixed', 'fixed', 'fixed'])
})

test('add and edit validation', () => {
  expect(validateRule(rule())).toBeUndefined()
  expect(validateRule(rule({ name: '  ' }))).toBe(o.errors.name)
  expect(validateRule(rule({ name: 'x'.repeat(81) }))).toBe(o.errors.name)
  expect(validateRule(rule({ obligation_type: 'audit' }))).toBe(o.errors.type)
  for (const n of [0, -1, 1.5, 1000, NaN]) expect(validateRule(rule({ interval_count: n }))).toBe(o.errors.interval)
  expect(validateRule(rule({ interval_unit: 'hour' }))).toBe(o.errors.unit)
  expect(validateRule(rule({ anchor: 'meter' }))).toBe(o.errors.anchor)
  expect(validateRules([rule(), rule({ name: 'QUARTERLY service ' })])).toBe(o.errors.duplicate)
  expect(validateRules([rule(), rule({ name: 'Calibration' })])).toBeUndefined()
})

test('error mapping', () => {
  expect(obligationError({ code: '42501' })).toBe(o.errors.noPermission)
  expect(obligationError({ code: '23505' })).toBe(o.errors.duplicate)
  expect(obligationError({ code: '23514' })).toBe(o.errors.invalid)
  expect(obligationError({ code: 'XX000' })).toBe(o.errors.generic)
})

test('steps clamp to month end and first due follows O4', () => {
  expect(addStep('2026-01-31', 1, 'month')).toBe('2026-02-28')
  expect(addStep('2024-02-29', 1, 'year')).toBe('2025-02-28')
  expect(addStep('2026-10-28', 2, 'week')).toBe('2026-11-11')
  // No drift: slot 2 from 31 Jan is 31 Mar, not 28 Mar.
  expect(addStep('2026-01-31', 2, 'month')).toBe('2026-03-31')
  // Old asset: first slot on or after today, never in the past.
  expect(firstDue('2024-01-15', 3, 'month', '2026-10-28')).toBe('2027-01-15')
  expect(firstDue('2026-10-28', 12, 'month', '2026-10-28')).toBe('2027-10-28')
  expect(firstDue('2026-07-28', 3, 'month', '2026-10-28')).toBe('2026-10-28')
})

const cats = [
  { id: 'm', parent_id: null, name: 'Machines', default_obligations: null, default_warranty_months: 24 },
  { id: 'c', parent_id: 'm', name: 'CNC', default_obligations: [rule(), rule({ name: 'Calibration', obligation_type: 'calibration', interval_count: 12, anchor: 'fixed' })], default_warranty_months: null },
  { id: 'l', parent_id: 'c', name: 'Lathes', default_obligations: [], default_warranty_months: null },
]

test('inherited defaults come from the nearest parent, each separately', () => {
  const d = inheritedDefaults(cats, 'c')
  expect([d.warranty, d.warrantyFrom, d.rules.length, d.rulesFrom]).toEqual([24, 'Machines', 2, 'CNC'])
  // [] stops inheritance.
  expect(inheritedDefaults(cats, 'l').rules).toEqual([])
  expect(inheritedDefaults(cats, '')).toMatchObject({ warranty: null, rules: [], rulesFrom: undefined })
})

function Harness({ start }: { start: Defaults }) {
  const [v, setV] = useState(start)
  return (
    <>
      <CategoryDefaults categories={cats} parentId="c" value={v} onChange={setV} />
      <output>{JSON.stringify(v)}</output>
    </>
  )
}
const value = () => JSON.parse(container.querySelector('output')!.textContent ?? '') as Defaults
const button = (name: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === name)!

test('category defaults: inherited shows the source; own copies, adds and removes rules', async () => {
  await act(async () => root.render(<Harness start={{ warranty: null, rules: null }} />))
  expect(container.textContent).toContain(s.inheritedFrom.replace('{name}', 'Machines').replace('{value}', '24 months'))
  expect(container.textContent).toContain(s.rulesFrom.replace('{name}', 'CNC'))
  expect(container.textContent).toContain('Every 12 months · fixed dates')
  expect(container.textContent).toContain(s.hint)

  const own = [...container.querySelectorAll<HTMLInputElement>('input[name="rules-mode"]')][1]!
  await act(async () => own.click())
  expect(value().rules?.map((r) => r.name)).toEqual(['Quarterly service', 'Calibration'])

  await act(async () => button(s.addRule).click())
  expect(value().rules).toHaveLength(3)
  // A new calibration rule switches to fixed dates.
  const type = container.querySelector<HTMLSelectElement>(`select[aria-label="${s.ruleLabel.replace('{n}', '3')} ${o.type}"]`)!
  await act(async () => {
    type.value = 'calibration'
    type.dispatchEvent(new Event('change', { bubbles: true }))
  })
  expect(value().rules?.[2]).toMatchObject({ obligation_type: 'calibration', anchor: 'fixed' })

  await act(async () => container.querySelector<HTMLButtonElement>(`button[aria-label="${s.remove} Quarterly service"]`)!.click())
  expect(value().rules?.map((r) => r.name)).toEqual(['Calibration', ''])
})

const ob = {
  id: 'o1', tenant_id: 'ta', asset_id: 'a1', name: 'Quarterly service', obligation_type: 'service', interval_count: 3, interval_unit: 'month', anchor: 'completion',
  first_due_date: '2026-10-01', last_done_date: null, next_due_date: '2026-10-01', due_state: 'overdue', due_state_until: null, is_active: true, notes: null,
}

test('obligations tab: read-only without permission', async () => {
  db.results.obligation = { data: [ob], error: null }
  const can = (dom: string, op: string) => dom === 'obligation' && op === 'view'
  await act(async () => root.render(<ObligationsTab tenantId="ta" assetId="a1" asset={{ in_service_date: null, purchase_date: null }} can={can} />))
  expect(container.textContent).toContain('Every 3 months · from last completion')
  expect(container.querySelector('.tag.status.error')?.textContent).toBe(o.states.overdue)
  expect(container.textContent).not.toContain(o.add)
  expect(container.textContent).not.toContain(o.pause)
  expect(button(o.recordCompletion).disabled).toBe(true)
})

test('obligations tab: empty state, add prefills first due and sends no derived columns, pause', async () => {
  const all = () => true
  await act(async () => root.render(<ObligationsTab tenantId="ta" assetId="a1" asset={{ in_service_date: '2020-01-10', purchase_date: null }} can={all} />))
  expect(container.textContent).toContain(o.none)
  await act(async () => button(o.add).click())
  const due = container.querySelector<HTMLInputElement>('input[name="first_due"]')!
  expect(due.value >= new Date().toISOString().slice(0, 10)).toBe(true)
  expect(due.value.slice(8)).toBe('10')
  const name = container.querySelector<HTMLInputElement>('input[name="name"]')!
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(name, 'Belt check')
    name.dispatchEvent(new Event('input', { bubbles: true }))
  })
  db.results['obligation:write'] = { data: [{ id: 'o2' }], error: null }
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(db.writes[0]).toMatchObject({ name: 'Belt check', tenant_id: 'ta', asset_id: 'a1', anchor: 'completion', last_done_date: null })
  expect(db.writes[0]).not.toHaveProperty('next_due_date')

  db.results.obligation = { data: [ob], error: null }
  await act(async () => root.render(<ObligationsTab tenantId="ta" assetId="a2" asset={{ in_service_date: null, purchase_date: null }} can={all} />))
  await act(async () => button(o.pause).click())
  expect(db.writes.at(-1)).toEqual({ is_active: false })
})
