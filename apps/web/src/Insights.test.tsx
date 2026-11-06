// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { cell, columnLabel, filterText, InsightsPage, message, parseValue, type Query } from './Insights'

vi.mock('./supabase', () => ({ supabase: { auth: { getSession: async () => ({ data: { session: { access_token: 'tok' } } }) } } }))

const v = t.insights
const catalog = [{ key: 'asset', label: 'Assets', fields: [
  { key: 'tag', label: 'Tag', type: 'text', ops: ['eq', 'contains'] },
  { key: 'location', label: 'Location', type: 'ref', ops: ['eq', 'in_place'] },
  { key: 'amc_end', label: 'AMC end', type: 'date', ops: ['within_next_days', 'between'] },
  { key: 'criticality', label: 'Criticality', type: 'enum', ops: ['eq', 'in'], options: ['A', 'B', 'C'] },
  { key: 'custom.rated_kw', label: 'Rated kW', type: 'number', ops: ['gt'] },
] }]
const pune: Query = { subject: 'asset', fields: ['tag', 'location', 'amc_end'],
  filters: [{ field: 'location', op: 'in_place', value: 'Pune' }, { field: 'amc_end', op: 'within_next_days', value: 60 }] }
const columns = [{ key: 'id', label: 'id', type: 'text' }, { key: 'tag', label: 'Tag', type: 'text' },
  { key: 'location', label: 'Location', type: 'ref' }, { key: 'amc_end', label: 'AMC end', type: 'date' }]
const rows = [['i1', 'PNE-0188', 'Plant 1 · Pune', '2026-12-01'], ['i2', 'PNE-0412', 'Plant 1 · Pune', '2026-12-20']]

test('chips are drawn by our code from the query', () => {
  expect(filterText('asset', pune.filters![0]!, {})).toBe('Location: in (and below) Pune')
  expect(filterText('asset', pune.filters![1]!, {})).toBe('AMC end: within the next 60 days')
  expect(filterText('asset', { field: 'location', op: 'eq', value: 'u1' }, { u1: 'Plant 2 · Nashik' })).toBe('Location: is Plant 2 · Nashik')
  expect(filterText('asset', { field: 'custom.rated_kw', op: 'gt', value: 5 }, {}, catalog)).toBe('Rated kW: more than 5')
  expect(filterText('asset', { field: 'amc_end', op: 'between', value: ['2026-01-01', '2026-03-31'] }, {})).toBe('AMC end: between 2026-01-01 and 2026-03-31')
})

test('values, labels and messages', () => {
  const f = catalog[0]!.fields
  expect(parseValue(f[2]!, 'within_next_days', '60', '')).toBe(60)
  expect(parseValue(f[2]!, 'within_next_days', '6.5', '')).toBeUndefined()
  expect(parseValue(f[3]!, 'in', 'A, B,', '')).toEqual(['A', 'B'])
  expect(parseValue(f[4]!, 'gt', 'x', '')).toBeUndefined()
  expect(parseValue(f[2]!, 'between', '2026-01-01', '')).toBeUndefined()
  const sum: Query = { subject: 'asset', measures: [{ fn: 'sum', field: 'purchase_value' }] }
  expect(columnLabel(sum, { key: 'sum_purchase_value', label: 'sum Purchase value', type: 'money' })).toBe('Total purchase value')
  expect(columnLabel(sum, { key: 'purchase_value_currency', label: 'Currency', type: 'currency' })).toBe(v.currency)
  expect(cell({ key: 'x', label: '', type: 'enum' }, 'overdue')).toBe('Overdue')
  expect(cell({ key: 'x', label: '', type: 'text' }, null)).toBe('—')
  expect(message('ai_cap_reached')).toBe(v.messages.ai_cap_reached)
  expect(message('something new')).toBe(v.messages.failed)
})

// The page against a fake service.
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
let root: Root
let container: HTMLDivElement
let calls: { path: string; body: unknown }[]
let replies: Record<string, { status: number; body: unknown }[]>
beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
  calls = []
  replies = { '/insights/catalog': [{ status: 200, body: { subjects: catalog } }] }
  vi.stubGlobal('fetch', async (url: string, init?: RequestInit) => {
    const path = url.replace(/^.*?(\/insights)/, '$1')
    calls.push({ path, body: init?.body ? JSON.parse(String(init.body)) : undefined })
    const r = replies[path]?.shift() ?? { status: 204, body: {} }
    return { status: r.status, json: async () => r.body }
  })
})
afterEach(() => {
  act(() => root.unmount())
  container.remove()
  vi.unstubAllGlobals()
})

async function open() {
  await act(async () => root.render(<MemoryRouter><InsightsPage /></MemoryRouter>))
}
async function ask(question: string) {
  const box = container.querySelector('textarea')!
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')!.set!.call(box, question)
    box.dispatchEvent(new Event('input', { bubbles: true }))
  })
  await act(async () => container.querySelector<HTMLFormElement>('form.ask')!.requestSubmit())
}
const button = (text: string) => [...container.querySelectorAll('button')].find((b) => b.textContent === text || b.getAttribute('aria-label') === text)!

test('review point: the question gives the chips and the rows; removing a chip re-runs without the model', async () => {
  await open()
  expect(document.activeElement).toBe(container.querySelector('textarea'))
  replies['/insights/ask'] = [{ status: 200, body: { ai_call_id: 'c1', query: pune, columns, rows, resolved: [] } }]
  await ask('Which assets at the Pune plant have AMC expiring in the next 60 days?')
  expect(calls.find((c) => c.path === '/insights/ask')!.body).toEqual({ question: 'Which assets at the Pune plant have AMC expiring in the next 60 days?' })
  expect(container.textContent).toContain(v.understood)
  expect(container.textContent).toContain('Location: in (and below) Pune')
  expect(container.textContent).toContain('AMC end: within the next 60 days')
  expect([...container.querySelectorAll('th')].map((th) => th.textContent)).toEqual(['Tag', 'Location', 'AMC end'])
  expect(container.querySelectorAll('tbody tr')).toHaveLength(2)
  expect(container.textContent).toContain(v.footer)

  replies['/insights/run'] = [{ status: 200, body: { columns, rows: rows.slice(0, 1), resolved: [] } }]
  await act(async () => button(`Remove ${'AMC end: within the next 60 days'}`).click())
  expect(calls.filter((c) => c.path === '/insights/ask')).toHaveLength(1)
  expect(calls.find((c) => c.path === '/insights/run')!.body).toEqual({ ...pune, filters: [pune.filters![0]] })
  expect(calls.find((c) => c.path === '/insights/outcome')!.body).toEqual({ ai_call_id: 'c1', outcome: 'edited' })
  expect(container.querySelectorAll('tbody tr')).toHaveLength(1)
})

test('at the cap the message shows and the chip editor still runs queries', async () => {
  await open()
  replies['/insights/ask'] = [{ status: 429, body: { error: 'ai_cap_reached' } }]
  await ask('anything')
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.ai_cap_reached)
  expect(container.textContent).toContain(v.manual)
  replies['/insights/run'] = [{ status: 200, body: { columns, rows, resolved: [] } }]
  const select = container.querySelector<HTMLSelectElement>('.understood select')!
  await act(async () => {
    select.value = 'asset'
    select.dispatchEvent(new Event('change', { bubbles: true }))
  })
  expect(calls.find((c) => c.path === '/insights/run')!.body).toEqual({ subject: 'asset' })
  expect(container.querySelectorAll('tbody tr')).toHaveLength(2)
  expect(calls.some((c) => c.path === '/insights/outcome')).toBe(false)
})

test('several matches: the user picks one, which runs with its id; cannot_answer shows our text only', async () => {
  await open()
  const options = [{ id: 'p1', label: 'Pune plant 1' }, { id: 'p2', label: 'Pune plant 2' }]
  replies['/insights/ask'] = [{ status: 200, body: { ai_call_id: 'c2', query: pune, needs_choice: [{ filter: 0, value: 'Pune', options }], resolved: [] } },
    { status: 200, body: { ai_call_id: 'c3', cannot_answer: true } }]
  await ask('Pune AMC')
  expect(container.textContent).toContain('Which “Pune” did you mean?')
  replies['/insights/run'] = [{ status: 200, body: { columns, rows, resolved: [] } }]
  await act(async () => button('Pune plant 2').click())
  expect((calls.find((c) => c.path === '/insights/run')!.body as Query).filters![0]).toEqual({ field: 'location', op: 'in_place', value: 'p2' })
  expect(calls.find((c) => c.path === '/insights/outcome')!.body).toEqual({ ai_call_id: 'c2', outcome: 'ran' })
  expect(container.textContent).toContain('Location: in (and below) Pune plant 2')

  await ask('weather tomorrow?')
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.cannot_answer)
})

test('no access: the service says forbidden and the page says so', async () => {
  replies['/insights/catalog'] = [{ status: 403, body: { error: 'forbidden' } }]
  await open()
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.forbidden)
  expect(container.querySelector('.understood')).toBeNull()
})
