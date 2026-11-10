// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { t } from './i18n'
import { cell, columnLabel, filterText, InsightsPage, message, parseValue, type Query } from './Insights'

// 10.8: insight_widget reads and writes go to Supabase under RLS; this fake records them.
const db = vi.hoisted(() => ({ rows: [] as Record<string, unknown>[], writes: [] as { op: string; body: unknown; id?: unknown }[] }))
vi.mock('./supabase', () => {
  const chain = (op: string, body?: unknown) => {
    const q = {
      select: () => q, is: () => q, order: () => q,
      eq: (_: string, id: unknown) => { db.writes.at(-1)!.id = id; return q },
      then: (ok: (r: unknown) => void) => ok(op === 'select' ? { data: db.rows, error: null } : { data: [{ id: 'w' }], error: null }),
    }
    if (op !== 'select') db.writes.push({ op, body })
    return q
  }
  return { supabase: {
    auth: { getSession: async () => ({ data: { session: { access_token: 'tok', user: { id: 'me' } } } }) },
    from: () => ({ select: () => chain('select'), insert: (b: unknown) => chain('insert', b), update: (b: unknown) => chain('update', b) }),
  } }
})

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
    const path = url.replace(/^.*?(\/insights|\/ai)/, '$1')
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
  replies['/ai/assist'] = [{ status: 200, body: { ai_call_id: 'c1', intent: 'search', query: pune, columns, rows, resolved: [] } }]
  await ask('Which assets at the Pune plant have AMC expiring in the next 60 days?')
  expect(calls.find((c) => c.path === '/ai/assist')!.body).toEqual({ message: 'Which assets at the Pune plant have AMC expiring in the next 60 days?' })
  expect(container.textContent).toContain(v.understood)
  expect(container.textContent).toContain('Location: in (and below) Pune')
  expect(container.textContent).toContain('AMC end: within the next 60 days')
  expect([...container.querySelectorAll('th')].map((th) => th.textContent)).toEqual(['Tag', 'Location', 'AMC end'])
  expect(container.querySelectorAll('tbody tr')).toHaveLength(2)
  expect(container.textContent).toContain(v.footer)

  replies['/insights/run'] = [{ status: 200, body: { columns, rows: rows.slice(0, 1), resolved: [] } }]
  await act(async () => button(`Remove ${'AMC end: within the next 60 days'}`).click())
  expect(calls.filter((c) => c.path === '/ai/assist')).toHaveLength(1)
  expect(calls.find((c) => c.path === '/insights/run')!.body).toEqual({ ...pune, filters: [pune.filters![0]] })
  expect(calls.find((c) => c.path === '/insights/outcome')!.body).toEqual({ ai_call_id: 'c1', outcome: 'edited' })
  expect(container.querySelectorAll('tbody tr')).toHaveLength(1)
})

test('at the cap the message shows and the chip editor still runs queries', async () => {
  await open()
  replies['/ai/assist'] = [{ status: 429, body: { error: 'ai_cap_reached' } }]
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

test('several matches: the user picks one, which runs with its id; unsupported shows our text only', async () => {
  await open()
  const options = [{ id: 'p1', label: 'Pune plant 1' }, { id: 'p2', label: 'Pune plant 2' }]
  replies['/ai/assist'] = [{ status: 200, body: { ai_call_id: 'c2', intent: 'search', query: pune, needs_choice: [{ filter: 0, value: 'Pune', options }], resolved: [] } },
    { status: 200, body: { ai_call_id: 'c3', intent: 'unsupported' } }]
  await ask('Pune AMC')
  expect(container.textContent).toContain('Which “Pune” did you mean?')
  replies['/insights/run'] = [{ status: 200, body: { columns, rows, resolved: [] } }]
  await act(async () => button('Pune plant 2').click())
  expect((calls.find((c) => c.path === '/insights/run')!.body as Query).filters![0]).toEqual({ field: 'location', op: 'in_place', value: 'p2' })
  expect(calls.find((c) => c.path === '/insights/outcome')!.body).toEqual({ ai_call_id: 'c2', outcome: 'ran' })
  expect(container.textContent).toContain('Location: in (and below) Pune plant 2')

  await ask('weather tomorrow?')
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.unsupported)
})

test('no access: the service says forbidden and the page says so', async () => {
  replies['/insights/catalog'] = [{ status: 403, body: { error: 'forbidden' } }]
  await open()
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.forbidden)
  expect(container.querySelector('.understood')).toBeNull()
})

test('saved widgets: save the current query, open one to re-run it, share and remove only your own', async () => {
  db.rows = [
    { id: 'w1', name: 'Pune AMC', query: pune, shared: false, created_by: 'me' },
    { id: 'w2', name: 'Team view', query: { subject: 'asset' }, shared: true, created_by: 'someone' },
  ]
  db.writes = []
  await act(async () => root.render(<MemoryRouter><InsightsPage tenantId="t1" canSave canShare /></MemoryRouter>))
  replies['/ai/assist'] = [{ status: 200, body: { ai_call_id: 'c1', intent: 'search', query: pune, columns, rows, resolved: [] } }]
  await ask('Pune AMC')
  vi.stubGlobal('prompt', () => ' Pune AMC 2 ')
  await act(async () => button(v.widgets.save).click())
  expect(db.writes[0]).toEqual({ op: 'insert', body: { tenant_id: 't1', name: 'Pune AMC 2', query: pune } })
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.widget_saved)

  await act(async () => button(v.widgets.title).click())
  const items = [...container.querySelectorAll('.widgets li')]
  expect(items.map((li) => li.querySelector('.btn-link')!.textContent)).toEqual(['Pune AMC', 'Team view'])
  expect(items[1]!.textContent).toContain(v.widgets.shared)
  expect(items[1]!.querySelectorAll('.btn')).toHaveLength(0) // not ours: open only

  // Opening re-runs the stored query through /insights/run (no model call); a field the viewer lost is refused.
  replies['/insights/run'] = [{ status: 422, body: { error: 'field_not_allowed', at: 'fields/0' } }]
  await act(async () => button('Team view').click())
  expect(calls.at(-1)).toEqual({ path: '/insights/run', body: { subject: 'asset' } })
  expect(calls.filter((c) => c.path === '/ai/assist')).toHaveLength(1)
  expect(container.querySelector('[role="alert"]')!.textContent).toBe(v.messages.field_not_allowed)
  expect(container.querySelector('tbody')).toBeNull()

  await act(async () => button(v.widgets.share).click())
  expect(db.writes.at(-1)).toEqual({ op: 'update', body: { shared: true }, id: 'w1' })
  vi.stubGlobal('confirm', () => true)
  await act(async () => button('Remove Pune AMC').click())
  expect(db.writes.at(-1)).toMatchObject({ op: 'update', id: 'w1' })
  expect((db.writes.at(-1)!.body as { deleted_at: string }).deleted_at).toBeTruthy()
})

test('saved widgets: no save right, no Save as widget button', async () => {
  await open()
  replies['/ai/assist'] = [{ status: 200, body: { ai_call_id: 'c1', intent: 'search', query: pune, columns, rows, resolved: [] } }]
  await ask('Pune AMC')
  expect(button(v.widgets.save)).toBeUndefined()
  expect(button(v.export)).toBeDefined()
})

// 10.9: an action reply opens the user's own form with the draft in router state; nothing is written here.
function Shown() {
  const l = useLocation()
  return <p>{`${l.pathname} ${JSON.stringify((l.state as { draft?: { asset?: { id: string } } } | null)?.draft?.asset ?? null)}`}</p>
}
test('10.9 an action opens the form; several assets are picked first; none says so', async () => {
  await act(async () => root.render(
    <MemoryRouter initialEntries={['/insights']}>
      <Routes>
        <Route path="/insights" element={<InsightsPage />} />
        <Route path="*" element={<Shown />} />
      </Routes>
    </MemoryRouter>,
  ))
  const draft = { ai_call_id: 'c9', intent: 'update_asset', asset_text: 'PNE', values: { model: 'GA-37' }, notes: {},
    asset_choices: [{ id: 'a1', label: 'PNE-0188 · Pump' }, { id: 'a2', label: 'PNE-0412 · Lathe' }] }
  replies['/ai/assist'] = [{ status: 200, body: { ...draft, asset_choices: [] } }, { status: 200, body: draft }]
  await ask('set the model of PNE to GA-37')
  expect(container.querySelector('[role="alert"]')!.textContent).toBe('No asset matches “PNE”. Check the tag and try again.')
  await ask('set the model of PNE to GA-37')
  expect(container.textContent).toContain('Which asset did you mean by “PNE”?')
  await act(async () => button('PNE-0412 · Lathe').click())
  expect(container.textContent).toBe('/assets/a2/edit {"id":"a2","label":"PNE-0412 · Lathe"}')
  expect(calls.some((c) => c.path === '/insights/run')).toBe(false)
})
