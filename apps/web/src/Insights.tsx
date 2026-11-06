// Story 10.7: Insights and Ask Assetly (data-model-goal10.md §5.4, owner answers D7.1 to D7.8). A question goes to
// POST /insights/ask; the chips are drawn by this code from the returned query, never from model text. Editing a
// chip re-runs through POST /insights/run with no model call, so the chip editor is also the manual path when the
// AI is off, refused or at its cap. The service enforces every right; this screen only shows what comes back.
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useLocation } from 'react-router'
import { t } from './i18n'
import { toCsv } from './Security'
import { supabase } from './supabase'

const v = t.insights

type Field = { key: string; label: string; type: string; ops: string[]; options?: string[] }
type Subject = { key: string; label: string; fields: Field[] }
type Filter = { field: string; op: string; value?: unknown }
export type Query = {
  subject: string
  fields?: string[]
  filters?: Filter[]
  group_by?: { field: string; bucket?: 'month' | 'quarter' | 'year' }[]
  measures?: { fn: 'count' | 'sum' | 'avg' | 'min' | 'max'; field?: string }[]
  sort?: { field: string; dir?: 'asc' | 'desc' }[]
  limit?: number
}
type Column = { key: string; label: string; type: string }
type Option = { id: string; label: string }
type Choice = { filter: number; value: string; options: Option[] }
type Reply = {
  error?: string
  ai_call_id?: string
  query?: Query | null
  columns?: Column[]
  rows?: unknown[][]
  needs_choice?: Choice[]
  resolved?: { filter: number; value: string; match: Option }[]
  cannot_answer?: boolean
}

async function api(path: string, body?: unknown): Promise<{ status: number; json: Reply & { subjects?: Subject[] } }> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const r = await fetch(`${import.meta.env.VITE_API_URL}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: `Bearer ${token}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }).catch(() => null)
  return { status: r?.status ?? 0, json: ((await r?.json().catch(() => ({}))) ?? {}) as Reply }
}

export function message(code?: string): string {
  const m = v.messages
  return code && code in m ? m[code as keyof typeof m] : m.failed
}

const fill = (s: string, vars: Record<string, string | number>) => s.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? ''))

// D7.8: labels by key from the translation file; custom fields (data) keep the catalog label.
export function fieldLabel(subject: string, key: string, catalog?: Subject[]): string {
  const fields = v.fields as Record<string, Record<string, string>>
  return fields[subject]?.[key] ?? catalog?.find((s) => s.key === subject)?.fields.find((f) => f.key === key)?.label ?? key
}
const optionLabel = (o: string) => (v.options as Record<string, string>)[o] ?? o

function show(x: unknown, labels: Record<string, string>): string {
  if (typeof x === 'boolean') return x ? v.yes : v.no
  if (Array.isArray(x)) return x.map((y) => show(y, labels)).join(', ')
  return typeof x === 'string' ? labels[x] ?? optionLabel(x) : String(x)
}

export function filterText(subject: string, f: Filter, labels: Record<string, string>, catalog?: Subject[]): string {
  const label = fieldLabel(subject, f.field, catalog)
  const c = v.chip
  switch (f.op) {
    case 'within_next_days': case 'within_last_days': case 'older_than_days':
      return `${label}: ${fill(c[f.op], { n: String(f.value) })}`
    case 'is_empty':
      return `${label}: ${f.value ? c.empty : c.notEmpty}`
    case 'between': {
      const [a, b] = f.value as unknown[]
      return `${label}: ${fill(c.between, { a: show(a, labels), b: show(b, labels) })}`
    }
    default:
      return `${label}: ${(v.ops as Record<string, string>)[f.op] ?? f.op} ${show(f.value, labels)}`
  }
}

function measureLabel(subject: string, m: { fn: string; field?: string }, catalog?: Subject[]): string {
  const fn = (v.fn as Record<string, string>)[m.fn] ?? m.fn
  return m.field ? `${fn} ${fieldLabel(subject, m.field, catalog).toLowerCase()}` : fn
}

export function columnLabel(q: Query, c: Column, catalog?: Subject[]): string {
  if (c.type === 'currency') return v.currency
  const m = (q.measures?.length ? q.measures : [{ fn: 'count' as const }]).find((x) => (x.field ? `${x.fn}_${x.field}` : x.fn) === c.key)
  return m && (q.measures?.length || q.group_by?.length) ? measureLabel(q.subject, m, catalog) : fieldLabel(q.subject, c.key, catalog)
}

export function cell(c: Column, x: unknown): string {
  if (x === null || x === undefined) return '—'
  if (typeof x === 'boolean') return x ? v.yes : v.no
  if (Array.isArray(x)) return x.map((y) => optionLabel(String(y))).join(', ')
  if (c.type === 'number' || c.type === 'money') return Number(x).toLocaleString()
  if (c.type === 'enum') return optionLabel(String(x))
  return String(x)
}

// The value typed in the filter editor, in the type the compiler expects. Undefined when it cannot be one.
export function parseValue(f: Field, op: string, a: string, b: string): unknown {
  const one = (s: string): unknown => {
    const x = s.trim()
    if (!x) return undefined
    if (f.type === 'number' || f.type === 'money') return Number.isFinite(Number(x)) ? Number(x) : undefined
    if (f.type === 'boolean') return x === 'true'
    return x
  }
  if (op === 'is_empty') return a === 'true'
  if (op === 'within_next_days' || op === 'within_last_days' || op === 'older_than_days') return /^\d+$/.test(a.trim()) ? Number(a) : undefined
  if (op === 'between') {
    const p = [one(a), one(b)]
    return p.every((x) => x !== undefined) ? p : undefined
  }
  if (op === 'in') {
    const p = a.split(',').map(one).filter((x) => x !== undefined)
    return p.length ? p : undefined
  }
  return one(a)
}

function FilterEditor({ subject, fields, filter, onApply, onCancel }: { subject: string; fields: Field[]; filter?: Filter; onApply: (f: Filter) => void; onCancel: () => void }) {
  const [key, setKey] = useState(filter?.field ?? fields[0]?.key ?? '')
  const f = fields.find((x) => x.key === key)
  const [op, setOp] = useState(filter?.op ?? f?.ops[0] ?? 'eq')
  const start = Array.isArray(filter?.value) ? filter.value : [filter?.value]
  const [a, setA] = useState(op === 'between' ? String(start[0] ?? '') : start.filter((x) => x !== undefined).map(String).join(', '))
  const [b, setB] = useState(op === 'between' ? String(start[1] ?? '') : '')
  if (!f) return null
  const value = parseValue(f, op, a, b)
  const days = op === 'within_next_days' || op === 'within_last_days' || op === 'older_than_days'
  const kind = days ? 'number' : f.type === 'date' ? 'date' : f.type === 'number' || f.type === 'money' ? 'number' : 'text'
  const pick = op === 'is_empty' || f.type === 'boolean' ? ['true', 'false'] : (f.type === 'enum' || f.type === 'tags') && op !== 'in' ? f.options ?? [] : null

  function submit(e: FormEvent) {
    e.preventDefault()
    if (value !== undefined) onApply({ field: key, op, value })
  }
  return (
    <form className="card filter-editor" onSubmit={submit}>
      <label className="field">
        {v.field}
        <select value={key} onChange={(e) => { setKey(e.target.value); setOp(fields.find((x) => x.key === e.target.value)?.ops[0] ?? 'eq'); setA(''); setB('') }}>
          {fields.map((x) => <option key={x.key} value={x.key}>{fieldLabel(subject, x.key, [{ key: subject, label: '', fields }])}</option>)}
        </select>
      </label>
      <label className="field">
        {v.op}
        <select value={op} onChange={(e) => { setOp(e.target.value); setA(''); setB('') }}>
          {f.ops.map((o) => <option key={o} value={o}>{(v.ops as Record<string, string>)[o] ?? o}</option>)}
        </select>
      </label>
      <label className="field">
        {v.value}
        {pick ? (
          <select value={a} onChange={(e) => setA(e.target.value)}>
            <option value="" />
            {pick.map((o) => <option key={o} value={o}>{o === 'true' ? v.yes : o === 'false' ? v.no : optionLabel(o)}</option>)}
          </select>
        ) : (
          <input type={kind} value={a} onChange={(e) => setA(e.target.value)} />
        )}
        {op === 'in' && <span className="hint">{v.listHint}</span>}
      </label>
      {op === 'between' && (
        <label className="field">
          {v.value}
          <input type={kind} value={b} onChange={(e) => setB(e.target.value)} />
        </label>
      )}
      <div className="actions">
        <button className="btn btn-main" type="submit" disabled={value === undefined}>{v.apply}</button>
        <button className="btn" type="button" onClick={onCancel}>{v.cancel}</button>
      </div>
    </form>
  )
}

export function InsightsPage() {
  const location = useLocation()
  const box = useRef<HTMLTextAreaElement>(null)
  const [catalog, setCatalog] = useState<Subject[]>()
  const [question, setQuestion] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string>()
  const [query, setQuery] = useState<Query | null>(null)
  const [fromAi, setFromAi] = useState(false)
  const [call, setCall] = useState<{ id: string; edited: boolean }>()
  const [result, setResult] = useState<{ columns: Column[]; rows: unknown[][] }>()
  const [choices, setChoices] = useState<Choice[]>([])
  const [labels, setLabels] = useState<Record<string, string>>({})
  const [editing, setEditing] = useState<number | 'new' | null>(null)

  useEffect(() => {
    let live = true
    void api('/insights/catalog').then((r) => {
      if (!live) return
      if (r.status === 200) {
        setCatalog(r.json.subjects ?? [])
        setMsg(undefined)
      } else setMsg(r.json.error ?? 'failed')
    })
    return () => {
      live = false
    }
  }, [])
  // The top-bar "Ask Assetly" navigates here; each click focuses the box again.
  useEffect(() => box.current?.focus(), [location.key])

  function took(r: Reply) {
    setChoices(r.needs_choice ?? [])
    setLabels((l) => ({ ...l, ...Object.fromEntries((r.resolved ?? []).map((x) => [x.match.id, x.match.label])) }))
    setResult(r.rows && r.columns ? { columns: r.columns, rows: r.rows } : undefined)
  }

  async function ask(e: FormEvent) {
    e.preventDefault()
    if (!question.trim() || busy) return
    setBusy(true)
    setMsg(undefined)
    setEditing(null)
    const r = await api('/insights/ask', { question })
    setBusy(false)
    if (r.status !== 200) {
      setMsg(r.json.error ?? 'failed')
      if (r.json.query) setQuery(r.json.query)
      return
    }
    setCall(r.json.ai_call_id ? { id: r.json.ai_call_id, edited: false } : undefined)
    if (r.json.cannot_answer) {
      setMsg('cannot_answer')
      setQuery(null)
      setFromAi(false)
      setResult(undefined)
      setChoices([])
      return
    }
    setQuery(r.json.query ?? null)
    setFromAi(true)
    took(r.json)
    if (r.json.error) setMsg('partial')
  }

  async function run(q: Query, mark?: 'ran' | 'edited') {
    setQuery(q)
    setEditing(null)
    setBusy(true)
    setMsg(undefined)
    const r = await api('/insights/run', q)
    setBusy(false)
    if (r.status !== 200) {
      setMsg(r.json.error ?? 'failed')
      setResult(undefined)
      return
    }
    took(r.json)
    // §6.4: what the user did with the AI answer; edited is recorded once.
    if (call && mark && !(mark === 'edited' && call.edited)) {
      void api('/insights/outcome', { ai_call_id: call.id, outcome: mark })
      if (mark === 'edited') setCall({ ...call, edited: true })
    }
  }

  function choose(c: Choice, o: Option) {
    if (!query) return
    setLabels((l) => ({ ...l, [o.id]: o.label }))
    const filters = (query.filters ?? []).map((f, i) =>
      i !== c.filter ? f : { ...f, value: Array.isArray(f.value) ? f.value.map((x) => (x === c.value ? o.id : x)) : o.id })
    void run({ ...query, filters }, 'ran')
  }

  const subject = catalog?.find((s) => s.key === query?.subject)
  const drop = <K extends 'filters' | 'group_by' | 'measures' | 'sort'>(k: K, i: number) => {
    if (!query) return
    const list = (query[k] ?? []).filter((_, j) => j !== i)
    void run({ ...query, [k]: list.length ? list : undefined }, 'edited')
  }
  const kpis = result && query && !query.group_by?.length && query.measures?.length === 1

  function download() {
    if (!result || !query) return
    const cols = result.columns.map((c, i) => [c, i] as const).filter(([c]) => c.key !== 'id')
    const rows = [cols.map(([c]) => columnLabel(query, c, catalog)), ...result.rows.map((r) => cols.map(([c, i]) => cell(c, r[i])))]
    const url = URL.createObjectURL(new Blob([toCsv(rows)], { type: 'text/csv;charset=utf-8' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `${v.exportName}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <>
      <title>{`${t.pages.insights} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.insights}</h1>
          <span className="muted">{v.subtitle}</span>
        </div>
      </div>

      <form className="card ask" onSubmit={(e) => void ask(e)}>
        <label className="field">
          <textarea ref={box} aria-label={v.question} rows={2} maxLength={500} placeholder={v.placeholder} value={question} onChange={(e) => setQuestion(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); e.currentTarget.form?.requestSubmit() } }} />
        </label>
        <button className="btn btn-main" type="submit" disabled={busy || !question.trim() || !catalog}>{busy ? v.asking : v.ask}</button>
      </form>

      {msg && <p className="banner" role="alert">{message(msg)}</p>}

      {catalog && (
        <section className="card understood" aria-label={fromAi ? v.understood : v.manual}>
          <div className="page-head">
            <h2>{fromAi && query ? v.understood : v.manual}</h2>
            {fromAi && query && <span className="muted">{v.editHint}</span>}
          </div>
          <div className="chips filter-chips">
            <label className="field inline">
              {v.subject}
              <select value={query?.subject ?? ''} onChange={(e) => void run({ subject: e.target.value }, 'edited')}>
                {!query && <option value="" />}
                {catalog.map((s) => <option key={s.key} value={s.key}>{(v.subjects as Record<string, string>)[s.key] ?? s.label}</option>)}
              </select>
            </label>
            {query?.filters?.map((f, i) => {
              const text = filterText(query.subject, f, labels, catalog)
              return (
                <span key={i} className="chip">
                  <button type="button" className="btn-link" aria-label={fill(v.edit, { label: text })} onClick={() => setEditing(i)}>{text} ▾</button>
                  <button type="button" aria-label={fill(v.remove, { label: text })} onClick={() => drop('filters', i)}>×</button>
                </span>
              )
            })}
            {query?.group_by?.map((g, i) => {
              const text = `${fill(v.groupBy, { label: fieldLabel(query.subject, g.field, catalog) })}${g.bucket ? ` ${v.bucket[g.bucket]}` : ''}`
              return <span key={`g${i}`} className="chip">{text}<button type="button" aria-label={fill(v.remove, { label: text })} onClick={() => drop('group_by', i)}>×</button></span>
            })}
            {query?.measures?.map((m, i) => {
              const text = measureLabel(query.subject, m, catalog)
              return <span key={`m${i}`} className="chip">{text}<button type="button" aria-label={fill(v.remove, { label: text })} onClick={() => drop('measures', i)}>×</button></span>
            })}
            {query && subject && (
              <button type="button" className="btn" onClick={() => setEditing('new')}>{v.addFilter}</button>
            )}
          </div>
          {choices.map((c) => (
            <div key={`${c.filter}:${c.value}`} className="choice" role="group" aria-label={fill(v.choose, { value: c.value })}>
              <p>{c.options.length ? fill(v.choose, { value: c.value }) : fill(v.noMatch, { value: c.value })}</p>
              <div className="chips">
                {c.options.map((o) => <button key={o.id} type="button" className="btn" onClick={() => choose(c, o)}>{o.label}</button>)}
              </div>
            </div>
          ))}
          {editing !== null && query && subject && (
            <FilterEditor
              key={String(editing)}
              subject={subject.key}
              fields={subject.fields}
              filter={editing === 'new' ? undefined : query.filters?.[editing]}
              onCancel={() => setEditing(null)}
              onApply={(f) => {
                const list = [...(query.filters ?? [])]
                if (editing === 'new') list.push(f)
                else list[editing] = f
                void run({ ...query, filters: list }, 'edited')
              }}
            />
          )}
          {query && !result && !choices.length && (
            <div className="actions">
              <button className="btn btn-main" type="button" disabled={busy} onClick={() => void run(query, fromAi ? 'edited' : undefined)}>{busy ? v.running : v.run}</button>
            </div>
          )}
        </section>
      )}

      {kpis && result && (
        <div className="kpis">
          {result.rows.map((r, i) => {
            const cur = result.columns.findIndex((c) => c.type === 'currency')
            const m = result.columns.length - 1
            return (
              <div key={i} className="card kpi">
                <span>{columnLabel(query, result.columns[m]!, catalog)}</span>
                <b>{cur >= 0 ? `${String(r[cur] ?? '')} ` : ''}{cell(result.columns[m]!, r[m])}</b>
              </div>
            )
          })}
        </div>
      )}

      {result && query && (
        <div className="card table-wrap list">
          <div className="page-head">
            <span className="muted">{fill(v.rows, { n: result.rows.length })}</span>
            <div className="spacer" />
            <button className="btn" type="button" disabled={!result.rows.length} onClick={download}>{v.export}</button>
          </div>
          {result.rows.length === 0 ? (
            <p className="muted">{v.noRows}</p>
          ) : (
            <table>
              <thead>
                <tr>{result.columns.map((c) => (c.key === 'id' ? null : <th key={c.key}>{columnLabel(query, c, catalog)}</th>))}</tr>
              </thead>
              <tbody>
                {result.rows.map((r, i) => (
                  <tr key={i}>{result.columns.map((c, j) => (c.key === 'id' ? null : <td key={c.key}>{cell(c, r[j])}</td>))}</tr>
                ))}
              </tbody>
            </table>
          )}
          <p className="muted">{v.footer}</p>
        </div>
      )}
    </>
  )
}
