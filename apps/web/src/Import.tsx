import { useEffect, useRef, useState } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Json, Tables } from './types/database'
import { sheetXlsx, type XlsxCell } from './xlsx'

type Batch = Pick<Tables<'import_batch'>, 'id' | 'file_name' | 'sheet_name' | 'sheet_names' | 'header_row' | 'columns' | 'row_count' | 'warnings' | 'status' | 'created_at' | 'mapping' | 'mapping_template_id' | 'summary' | 'outcome' | 'value_suggestions'>
export type Target = { target: string; label: string; kind: string; required: boolean; category_id: string | null }
type Template = Pick<Tables<'import_mapping_template'>, 'id' | 'name' | 'headers' | 'targets'>
// source: how the target was chosen; 'user' once the person changes it here. confidence: AI entries only (10.3).
export type Entry = { target: string; source: 'template' | 'rules' | 'ai' | 'user'; confidence?: number }
type Warning = { code: keyof typeof t.import.warnings; row?: number; column: number }
type Upload = { state: 'idle' } | { state: 'sending'; percent: number } | { state: 'reading' } | { state: 'failed'; error: string }

const PREVIEW_ROWS = 20
const HEADER_SCAN = 20 // the service looks for the header row among the first 20 rows (8.2 I4)

// Same as normalise in services/api/src/mapping.ts: templates match on this, not on the column letter.
export const normalise = (s: string) => s.toLowerCase().replace(/&/g, 'and').replace(/[^\p{L}\p{N}]/gu, '')
// Headers the parser named itself ("Column C") were blank in the file.
const isBlank = (c: string) => /^Column [A-Z]{1,3}$/.test(c)

// The template row for a saved mapping: normalised header -> target, ignored columns left out.
export function templateOf(columns: string[], mapping: Entry[]) {
  const named = columns.map((c, i) => ({ c, e: mapping[i] })).filter(({ c }) => !isBlank(c))
  return {
    headers: named.map(({ c }) => normalise(c)),
    targets: Object.fromEntries(named.filter(({ e }) => e && e.target !== 'ignore').map(({ c, e }) => [normalise(c), e!.target])),
  }
}

// Applies a template the user picked; a target this user may not set, or one already taken, becomes ignore.
export function applyTemplate(columns: string[], targets: Record<string, string>, catalog: Target[]): Entry[] {
  const allowed = new Set(catalog.map((c) => c.target))
  const used = new Set<string>()
  return columns.map((c) => {
    const target = targets[normalise(c)]
    if (!target || !allowed.has(target) || used.has(target)) return { target: 'ignore', source: 'template' }
    used.add(target)
    return { target, source: 'template' }
  })
}

// 10.3: AI targets go only to columns still "not mapped" by the rules, and only to a field not taken meanwhile.
export function mergeAi(current: Entry[], ai: Entry[]): Entry[] {
  const taken = new Set(current.map((e) => e.target))
  return current.map((e, i) => {
    const a = ai[i]
    if (a?.source !== 'ai' || e.source !== 'rules' || e.target !== 'ignore' || taken.has(a.target)) return e
    taken.add(a.target)
    return a
  })
}

// 10.3: a refusal the user can act on gets a line; no add-on, no right or AI off stay silent (no AI shown).
export function aiError(code?: string): string | undefined {
  const e = t.import.mapping.aiErrors
  return code && code in e ? e[code as keyof typeof e] : undefined
}

async function aiMapping(batchId: string): Promise<{ mapping?: Entry[] | null; error?: string }> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const r = await fetch(`${import.meta.env.VITE_API_URL}/imports/${batchId}/ai-mapping`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } }).catch(() => null)
  return ((await r?.json().catch(() => ({}))) ?? {}) as { mapping?: Entry[] | null; error?: string }
}

export function saveError(message: string): string {
  const e = t.import.mapping.errors
  if (/required/.test(message)) return e.required
  if (/twice/.test(message)) return e.twice
  if (/not allowed|not found|batch is/.test(message)) return e.stale
  return e.generic
}

// Excel column letters, for warnings ("column E").
export const columnLetter = (i: number): string => (i < 0 ? '' : columnLetter(Math.floor(i / 26) - 1) + String.fromCharCode(65 + (i % 26)))

export function uploadError(status: number, code?: string): string {
  const e = t.import.errors
  if (code && code in e) return e[code as keyof typeof e]
  if (status === 401 || status === 403) return e.forbidden
  if (status === 413) return e.file_limits
  return e.generic
}

// XHR, not fetch: fetch has no upload progress. The token goes in a header; the service checks it (8.1).
function send(file: File, token: string, opts: { sheet?: string; headerRow?: number }, onProgress: (percent: number) => void) {
  return new Promise<{ status: number; body: { batch_id?: string; error?: string } }>((resolve) => {
    const xhr = new XMLHttpRequest()
    const q = new URLSearchParams()
    if (opts.sheet) q.set('sheet', opts.sheet)
    if (opts.headerRow) q.set('header_row', String(opts.headerRow))
    xhr.open('POST', `${import.meta.env.VITE_API_URL}/imports${q.size ? `?${q}` : ''}`)
    xhr.setRequestHeader('Authorization', `Bearer ${token}`)
    xhr.setRequestHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
    xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name))
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(Math.round((e.loaded / e.total) * 100))
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) as object } catch { /* not JSON */ }
      resolve({ status: xhr.status, body })
    }
    xhr.onerror = () => resolve({ status: 0, body: {} })
    xhr.send(file)
  })
}

async function loadBatches(): Promise<Batch[]> {
  const { data } = await supabase
    .from('import_batch')
    .select('id, file_name, sheet_name, sheet_names, header_row, columns, row_count, warnings, status, created_at, mapping, mapping_template_id, summary, outcome, value_suggestions')
    .order('created_at', { ascending: false })
    .limit(10)
  return data ?? []
}

async function loadRows(batchId: string): Promise<{ row_number: number; cells: Json }[]> {
  const { data } = await supabase
    .from('import_row')
    .select('row_number, cells')
    .eq('batch_id', batchId)
    .order('row_number')
    .limit(PREVIEW_ROWS)
  return data ?? []
}

// The blank import file comes from the service, which builds it from the same catalog (8.3 §14.8).
async function downloadTemplate(): Promise<boolean> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const r = await fetch(`${import.meta.env.VITE_API_URL}/imports/template`, { headers: { Authorization: `Bearer ${token}` } }).catch(() => null)
  if (!r?.ok) return false
  const a = document.createElement('a')
  a.href = URL.createObjectURL(await r.blob())
  a.download = 'assetly-import-template.xlsx'
  a.click()
  URL.revokeObjectURL(a.href)
  return true
}

function hintOf(f: Target): string {
  const h = t.import.fields.hints
  if (f.target in h) return h[f.target as keyof typeof h]
  return f.kind in h ? h[f.kind as keyof typeof h] : ''
}

// What a file may hold: the fields this user may set, from import_target_catalog (M2, M3).
function FieldList({ catalog }: { catalog: Target[] }) {
  const [failed, setFailed] = useState(false)
  const f = t.import.fields
  return (
    <div className="card stack">
      <div className="page-head">
        <div>
          <h2>{f.title}</h2>
          <p className="muted">{f.subtitle}</p>
        </div>
        <button type="button" className="btn" onClick={() => void downloadTemplate().then((ok) => setFailed(!ok))}>
          {f.download}
        </button>
      </div>
      {failed && <p className="field-error" role="alert">{f.downloadFailed}</p>}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{f.field}</th>
              <th>{f.needed}</th>
              <th>{f.format}</th>
            </tr>
          </thead>
          <tbody>
            {catalog.map((c) => (
              <tr key={c.target}>
                <td>{c.label}</td>
                <td>{c.required ? <span className="tag warn">{f.required}</span> : <span className="muted">{f.optional}</span>}</td>
                <td className="muted">{[hintOf(c), c.category_id ? f.byCategory : ''].filter(Boolean).join(' ')}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function Steps({ at }: { at: number }) {
  return (
    <ol className="steps">
      {t.import.steps.map((name, i) => (
        <li key={name} aria-current={i === at ? 'step' : undefined} className={i < at ? 'done' : undefined}>
          <span>{i < at ? '✓' : i + 1}</span>
          {name}
        </li>
      ))}
    </ol>
  )
}

function tagOf(e: Entry) {
  const m = t.import.mapping
  if (e.source === 'user') return <span className="tag">{m.changed}</span>
  if (e.target === 'ignore') return <span className="tag">{m.notMapped}</span>
  // Screens file, Import review: the confidence tag is green from 90%, amber below.
  if (e.source === 'ai') return <span className={`tag ${(e.confidence ?? 0) >= 0.9 ? 'ok' : 'warn'}`}>{m.aiSuggested.replace('{percent}', String(Math.round((e.confidence ?? 0) * 100)))}</span>
  return <span className="tag ok">{e.source === 'template' ? m.fromTemplate : m.matched}</span>
}

function MappingStep({ tenantId, batch, catalog, sample, canRun, onSaved, onHeaderRow }: {
  tenantId: string
  batch: Batch
  catalog: Target[]
  sample: Json[] | undefined
  canRun: boolean
  onSaved: () => void
  onHeaderRow?: (row: number) => void
}) {
  const [mapping, setMapping] = useState<Entry[]>(() =>
    batch.columns.map((_, i) => (batch.mapping as Entry[] | null)?.[i] ?? { target: 'ignore', source: 'rules' }))
  const [templateId, setTemplateId] = useState(batch.mapping_template_id)
  const [templates, setTemplates] = useState<Template[]>([])
  const [headerRow, setHeaderRow] = useState(batch.header_row)
  const [name, setName] = useState('')
  const [msg, setMsg] = useState<{ ok: boolean; text: string }>()
  const [ai, setAi] = useState<{ state: 'asking' } | { state: 'done'; n: number } | { state: 'failed'; text: string }>()
  const m = t.import.mapping

  // 10.3: once per staged batch, the service runs the chain again with the AI mapper last. It decides (add-on,
  // right, cap, saved template, unmapped columns). Nothing is stored until the user saves. The ref, not a live
  // flag, keeps it to one call under StrictMode's double effect.
  const asked = useRef(false)
  const askAi = canRun && batch.status === 'staged' && !batch.mapping_template_id
    && mapping.some((e) => e.source === 'rules' && e.target === 'ignore')
  useEffect(() => {
    if (!askAi || asked.current) return
    asked.current = true
    setAi({ state: 'asking' })
    void aiMapping(batch.id).then(({ mapping: got, error }) => {
      const n = got?.filter((e) => e.source === 'ai').length ?? 0
      const text = aiError(error)
      setAi(text ? { state: 'failed', text } : n ? { state: 'done', n } : undefined)
      if (got && n) setMapping((cur) => mergeAi(cur, got))
    })
  }, [askAi, batch.id])

  useEffect(() => {
    let live = true
    void supabase
      .from('import_mapping_template')
      .select('id, name, headers, targets')
      .is('deleted_at', null)
      .order('name')
      .then(({ data }) => live && setTemplates(data ?? []))
    return () => {
      live = false
    }
  }, [])

  const editable = canRun && (batch.status === 'staged' || batch.status === 'mapped' || batch.status === 'validated')
  const taken = new Set(mapping.map((e) => e.target))
  const missing = catalog.filter((c) => c.required && !c.target.startsWith('custom:') && !taken.has(c.target))

  async function save() {
    const { error } = await supabase.rpc('import_save_mapping', { p_batch_id: batch.id, p_mapping: mapping, p_template_id: templateId ?? undefined })
    if (error) return setMsg({ ok: false, text: saveError(error.message) })
    // V8: check the rows straight after a save, so the user sees one step. A failure leaves the batch
    // mapped, and the check card offers to run it again.
    setMsg({ ok: true, text: t.import.check.running })
    await supabase.rpc('import_validate', { p_batch_id: batch.id })
    onSaved()
  }

  async function keep() {
    const { error } = await supabase.from('import_mapping_template').insert({ tenant_id: tenantId, name: name.trim(), ...templateOf(batch.columns, mapping) })
    setMsg(error ? { ok: false, text: error.code === '23505' ? m.errors.nameTaken : m.errors.generic } : { ok: true, text: m.templateSaved })
    if (!error) setName('')
  }

  return (
    <div className="card stack">
      <h2>{m.title}</h2>
      <p className="muted">{batch.status === 'mapped' ? m.savedNote : m.subtitle}</p>
      {editable && (
        <div className="filters">
          {onHeaderRow && (
            <label className="field">
              <span>{m.headerRow}</span>
              <select className="filter" value={headerRow} onChange={(e) => setHeaderRow(Number(e.target.value))}>
                {Array.from({ length: HEADER_SCAN }, (_, i) => i + 1).map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
            </label>
          )}
          {onHeaderRow && headerRow !== batch.header_row && (
            <button type="button" className="btn" onClick={() => onHeaderRow(headerRow)}>
              {m.reread}
            </button>
          )}
          {templates.length > 0 && (
            <label className="field">
              <span>{m.applyTemplate}</span>
              <select
                className="filter"
                value=""
                onChange={(e) => {
                  const tpl = templates.find((x) => x.id === e.target.value)
                  if (!tpl) return
                  setMapping(applyTemplate(batch.columns, tpl.targets as Record<string, string>, catalog))
                  setTemplateId(tpl.id)
                }}
              >
                <option value="">{m.pickTemplate}</option>
                {templates.map((x) => (
                  <option key={x.id} value={x.id}>
                    {x.name}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
      )}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{m.column}</th>
              <th>{m.header}</th>
              <th>{m.sample}</th>
              <th>{m.target}</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {batch.columns.map((c, i) => (
              <tr key={i}>
                <td>{columnLetter(i)}</td>
                <td>{c}</td>
                <td className="muted">{cellText(sample?.[i])}</td>
                <td>
                  <select
                    className="filter"
                    aria-label={m.targetFor.replace('{column}', c)}
                    value={mapping[i]!.target}
                    disabled={!editable}
                    onChange={(e) => setMapping(mapping.map((x, j) => (j === i ? { target: e.target.value, source: 'user' } : x)))}
                  >
                    <option value="ignore">{m.ignore}</option>
                    {catalog.map((f) => (
                      <option key={f.target} value={f.target} disabled={f.target !== mapping[i]!.target && taken.has(f.target)}>
                        {f.label}
                      </option>
                    ))}
                  </select>
                </td>
                <td>{tagOf(mapping[i]!)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {ai?.state === 'asking' && <p role="status" className="muted">{m.aiAsking}</p>}
      {ai?.state === 'done' && <p role="status" className="hint">{m.aiDone.replace('{n}', String(ai.n))} {m.aiTemplateHint}</p>}
      {ai?.state === 'failed' && <p role="status" className="hint">{ai.text}</p>}
      {missing.length > 0 && <p className="hint">{m.missing.replace('{fields}', missing.map((f) => f.label).join(', '))}</p>}
      {msg && (
        <p className={msg.ok ? 'save-ok' : 'field-error'} role={msg.ok ? 'status' : 'alert'}>
          {msg.text}
        </p>
      )}
      {editable && (
        <div className="filters">
          <button type="button" className="btn btn-primary" disabled={missing.length > 0} onClick={() => void save()}>
            {m.save}
          </button>
          <label className="field">
            <span>{m.templateName}</span>
            <input value={name} maxLength={100} onChange={(e) => setName(e.target.value)} />
          </label>
          <button type="button" className="btn" disabled={!name.trim()} onClick={() => void keep()}>
            {m.saveTemplate}
          </button>
        </div>
      )}
    </div>
  )
}

function cellText(v: Json | undefined): string {
  if (v === null || v === undefined) return ''
  return typeof v === 'object' ? JSON.stringify(v) : String(v)
}

type Summary = { ok: number; warning: number; error: number; create_assets: number; create_coverages: number; skip: number; codes?: Record<string, number>; validated_at: string }
type Message = { col?: number; code: string; params?: Record<string, Json> }
type ReviewRow = { row_number: number; result: string | null; messages: Json; cells: Json; payload: Json }
type Show = 'attention' | 'error' | 'warning' | 'ok' | 'all'
const PAGE = 50
const READ = 1000 // PostgREST max_rows
// Same list as import_validate: these never make a row an error.
const WARNINGS = ['currency_defaulted', 'possible_duplicate']
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

// One message in words. Messages hold a code and fixed params, never cell text (8.4 §15.5).
export function messageText(m: Message, catalog: Target[]): string {
  const codes = t.import.check.codes
  const text = m.code in codes ? codes[m.code as keyof typeof codes] : m.code
  return Object.entries(m.params ?? {}).reduce(
    (s, [k, v]) => s.replaceAll(`{${k}}`, k === 'field' ? (catalog.find((f) => f.target === v)?.label ?? String(v)) : String(v)),
    text,
  )
}

// A code's name in the Problem filter: its words with the per-row parts left out.
export const codeName = (code: string) => messageText({ code }, []).replace(/\{\w+\}/g, '…')

// What commit (8.6) would do with the row: the payload is what it inserts (V2).
export function commitWill(payload: Json): string {
  const r = t.import.review
  if (!payload) return r.skip
  return (payload as { coverage?: Json }).coverage ? r.createWithWarranty : r.create
}

// The rows commit would skip, as in the file plus a Problems column, so they can be fixed and uploaded again (R2, R3).
export function errorRows(columns: string[], rows: { cells: Json; messages: Json }[], catalog: Target[]): XlsxCell[][] {
  return [
    [...columns, t.import.review.problems],
    ...rows.map((r) => [
      ...columns.map((_, i): XlsxCell => {
        const v = (r.cells as Json[])[i]
        if (v === undefined || v === null) return null
        return typeof v === 'object' ? JSON.stringify(v) : v
      }),
      ((r.messages ?? []) as Message[])
        .map((m) => (m.col === undefined ? '' : `${columnLetter(m.col)} · ${columns[m.col]}: `) + messageText(m, catalog))
        .join('\n'),
    ]),
  ]
}

async function downloadErrors(batch: Batch, catalog: Target[]): Promise<boolean> {
  const rows: { cells: Json; messages: Json }[] = []
  for (let from = 0; from < batch.row_count; from += READ) {
    const { data, error } = await supabase
      .from('import_row')
      .select('cells, messages')
      .eq('batch_id', batch.id)
      .eq('result', 'error')
      .order('row_number')
      .range(from, from + READ - 1)
    if (error) return false
    rows.push(...data)
    if (data.length < READ) break
  }
  const a = document.createElement('a')
  a.href = URL.createObjectURL(new Blob([sheetXlsx(batch.sheet_name.slice(0, 31), errorRows(batch.columns, rows, catalog))], { type: XLSX }))
  a.download = `${batch.file_name.replace(/\.xlsx$/i, '')}-errors.xlsx`
  a.click()
  URL.revokeObjectURL(a.href)
  return true
}

type Outcome = { created_assets: number; created_coverages: number; skipped: number; committed_at: string; undone?: number; blocked?: number }

export function actError(status: number, code?: string): string {
  const e = t.import.commit.errors
  if (code && code in e) return e[code as keyof typeof e]
  return status === 401 ? e.forbidden : e.generic
}

// 8.6: commit and undo go through the service, past the 8 s web timeout (K1). The SQL functions do every check.
async function act(batchId: string, action: 'commit' | 'undo'): Promise<{ error?: string }> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const r = await fetch(`${import.meta.env.VITE_API_URL}/imports/${batchId}/${action}`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } }).catch(() => null)
  if (r?.ok) return {}
  const body = (await r?.json().catch(() => ({}))) as { error?: string } | undefined
  return { error: actError(r?.status ?? 0, body?.error) }
}

// 8.6: what the commit did, and undo (K5 to K7).
function CommitCard({ batch, canUndo, onDone }: { batch: Batch; canUndo: boolean; onDone: () => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const [blocked, setBlocked] = useState<{ row_number: number; undo_blocked: string | null }[]>()
  const k = t.import.commit
  const o = batch.outcome as Outcome | null
  const when = (iso: string) => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })

  useEffect(() => {
    if (!o?.blocked) return
    let live = true
    void supabase
      .from('import_row')
      .select('row_number, undo_blocked')
      .eq('batch_id', batch.id)
      .not('undo_blocked', 'is', null)
      .is('undone_at', null)
      .order('row_number')
      .limit(PAGE)
      .then(({ data }) => live && setBlocked(data ?? []))
    return () => {
      live = false
    }
  }, [batch.id, o?.blocked])

  async function undo() {
    if (!window.confirm(k.undoConfirm)) return
    setBusy(true)
    setError(undefined)
    const r = await act(batch.id, 'undo')
    setBusy(false)
    if (r.error) return setError(r.error)
    onDone()
  }

  if (!o) return null
  return (
    <div className="card stack">
      <div className="page-head">
        <div>
          <h2>{batch.status === 'undone' ? k.undoneTitle : k.title}</h2>
          <p className="muted">{k.when.replace('{file}', batch.file_name).replace('{when}', when(o.committed_at))}</p>
        </div>
        {canUndo && (batch.status === 'committed' || !!o.blocked) && (
          <button type="button" className="btn" disabled={busy} onClick={() => void undo()}>
            {batch.status === 'undone' ? k.undoAgain : k.undo}
          </button>
        )}
      </div>
      {busy && <p role="status">{k.undoing}</p>}
      {error && <p className="field-error" role="alert">{error}</p>}
      <p>
        {k.done
          .replace('{assets}', String(o.created_assets))
          .replace('{coverages}', String(o.created_coverages))
          .replace('{skip}', String(o.skipped))}
      </p>
      {batch.status === 'undone' && <p>{k.undone.replace('{n}', String(o.undone ?? 0)).replace('{blocked}', String(o.blocked ?? 0))}</p>}
      {!!blocked?.length && (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t.import.check.row}</th>
                <th>{k.why}</th>
              </tr>
            </thead>
            <tbody>
              {blocked.map((b) => (
                <tr key={b.row_number}>
                  <td>{b.row_number}</td>
                  <td>{k.blocked[b.undo_blocked as keyof typeof k.blocked] ?? b.undo_blocked}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

// 8.5: the Review step of the ImportReview screen. 8.4 results per row, paged and filtered on the server (R4).
function ReviewCard({ batch, catalog, canRun, canCommit, onChecked, onRemap }: {
  batch: Batch
  catalog: Target[]
  canRun: boolean
  canCommit: boolean
  onChecked: () => void
  onRemap?: () => void
}) {
  const [show, setShow] = useState<Show>('attention')
  const [code, setCode] = useState('')
  const [page, setPage] = useState(0)
  const [rows, setRows] = useState<{ key: string; list: ReviewRow[]; count: number }>()
  const [state, setState] = useState<'idle' | 'running' | 'failed' | 'downloadFailed' | 'committing'>('idle')
  const [commitError, setCommitError] = useState<string>()
  const c = t.import.check
  const r = t.import.review
  const s = batch.summary as Summary | null
  const key = `${batch.id}|${show}|${code}|${page}`

  useEffect(() => {
    if (!s) return
    let live = true
    let q = supabase.from('import_row').select('row_number, result, messages, cells, payload', { count: 'exact' }).eq('batch_id', batch.id)
    if (show === 'attention') q = q.in('result', ['error', 'warning'])
    else if (show !== 'all') q = q.eq('result', show)
    if (code) q = q.contains('messages', JSON.stringify([{ code }]))
    void q
      .order('row_number')
      .range(page * PAGE, page * PAGE + PAGE - 1)
      .then(({ data, count }) => live && setRows({ key, list: data ?? [], count: count ?? 0 }))
    return () => {
      live = false
    }
  }, [batch.id, s, show, code, page, key])

  async function commit() {
    setState('committing')
    setCommitError(undefined)
    const r = await act(batch.id, 'commit')
    setState('idle')
    if (r.error) return setCommitError(r.error)
    onChecked()
  }

  async function run() {
    setState('running')
    const { error } = await supabase.rpc('import_validate', { p_batch_id: batch.id })
    setState(error ? 'failed' : 'idle')
    if (!error) onChecked()
  }

  const shown = rows?.key === key ? rows : undefined
  const lines = (shown?.list ?? []).flatMap((x) => {
    const msgs = ((x.messages ?? []) as Message[]).filter((m) => !code || m.code === code)
    return (msgs.length ? msgs : [undefined]).map((m, i) => ({ x, m, first: i === 0 }))
  })
  const codes = Object.entries(s?.codes ?? {}).sort((a, b) => b[1] - a[1])
  const tone = (result: string | null) => (result === 'error' ? 'tag error' : result === 'warning' ? 'tag warn' : 'tag ok')

  return (
    <div className="card stack">
      <div className="page-head">
        <div>
          <h2>{r.title}</h2>
          <p className="muted">{r.subtitle.replace('{file}', batch.file_name)}</p>
        </div>
        <div className="filters">
          {canRun && onRemap && (
            <button type="button" className="btn" onClick={onRemap}>
              {r.backToMapping}
            </button>
          )}
          {!!s?.error && (
            <button type="button" className="btn" onClick={() => void downloadErrors(batch, catalog).then((ok) => setState(ok ? 'idle' : 'downloadFailed'))}>
              {r.downloadErrors}
            </button>
          )}
          {canRun && (
            <button type="button" className="btn" disabled={state === 'running' || state === 'committing'} onClick={() => void run()}>
              {s ? c.again : c.run}
            </button>
          )}
          {canCommit && batch.status === 'validated' && !!s?.create_assets && (
            <button type="button" className="btn btn-primary" disabled={state === 'running' || state === 'committing'} onClick={() => void commit()}>
              {t.import.commit.button.replace('{n}', String(s.create_assets))}
            </button>
          )}
        </div>
      </div>
      {state === 'committing' && <p role="status">{t.import.commit.committing}</p>}
      {commitError && <p className="field-error" role="alert">{commitError}</p>}
      {state === 'running' && <p role="status">{c.running}</p>}
      {state === 'failed' && <p className="field-error" role="alert">{c.failed}</p>}
      {state === 'downloadFailed' && <p className="field-error" role="alert">{r.downloadFailed}</p>}
      {s && (
        <>
          <div className="kpis">
            <div className="card kpi">
              <span>{r.accepted}</span>
              <b>{s.ok}</b>
            </div>
            <div className="card kpi">
              <span>{r.attention}</span>
              <b className="warn">{s.warning}</b>
            </div>
            <div className="card kpi">
              <span>{r.rejected}</span>
              <b className="error">{s.error}</b>
            </div>
          </div>
          <p>
            {c.dryRun
              .replace('{assets}', String(s.create_assets))
              .replace('{coverages}', String(s.create_coverages))
              .replace('{skip}', String(s.skip))}{' '}
            {r.noUpdates}
          </p>
          <p className="hint">{c.asOf.replace('{when}', new Date(s.validated_at).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }))}</p>
          <div className="filters">
            <label className="field">
              <span>{r.show}</span>
              <select
                className="filter"
                value={show}
                onChange={(e) => {
                  setShow(e.target.value as Show)
                  setPage(0)
                  if (e.target.value === 'ok') setCode('')
                }}
              >
                {(Object.keys(r.shows) as Show[]).map((k) => (
                  <option key={k} value={k}>
                    {r.shows[k]}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              <span>{r.problem}</span>
              <select
                className="filter"
                value={code}
                disabled={show === 'ok'}
                onChange={(e) => {
                  setCode(e.target.value)
                  setPage(0)
                }}
              >
                <option value="">{r.allProblems}</option>
                {codes.map(([k, n]) => (
                  <option key={k} value={k}>
                    {`${codeName(k)} (${n})`}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {shown && !shown.count && <p className="save-ok">{show === 'attention' && !code ? c.none : r.noRows}</p>}
          {!!shown?.count && (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>{c.row}</th>
                    <th>{r.result}</th>
                    <th>{c.column}</th>
                    <th>{c.problem}</th>
                    <th>{c.value}</th>
                    <th>{r.commitWill}</th>
                  </tr>
                </thead>
                <tbody>
                  {lines.map(({ x, m, first }, i) => (
                    <tr key={`${x.row_number}-${i}`}>
                      <td>{first ? x.row_number : ''}</td>
                      <td>{first && <span className={tone(x.result)}>{r.results[x.result as keyof typeof r.results]}</span>}</td>
                      <td>{m?.col === undefined ? '' : `${columnLetter(m.col)} · ${batch.columns[m.col]}`}</td>
                      <td>
                        {m && (
                          <>
                            <span className={WARNINGS.includes(m.code) ? 'tag warn' : 'tag error'}>{WARNINGS.includes(m.code) ? c.warningTag : c.errorTag}</span>{' '}
                            {messageText(m, catalog)}
                          </>
                        )}
                      </td>
                      <td className="muted">{m?.col === undefined ? '' : cellText((x.cells as Json[])[m.col])}</td>
                      <td>{first ? commitWill(x.payload) : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {!!shown?.count && (
            <div className="filters">
              <span className="muted">
                {r.range
                  .replace('{from}', String(page * PAGE + 1))
                  .replace('{to}', String(Math.min(shown.count, page * PAGE + PAGE)))
                  .replace('{n}', String(shown.count))}
              </span>
              <div className="spacer" />
              <button type="button" className="btn" disabled={page === 0} onClick={() => setPage(page - 1)}>
                {t.assets.previous}
              </button>
              <button type="button" className="btn" disabled={(page + 1) * PAGE >= shown.count} onClick={() => setPage(page + 1)}>
                {t.assets.next}
              </button>
            </div>
          )}
        </>
      )}
    </div>
  )
}

// 10.4: AI value matches for category, location, vendor and status values the check could not find. The service
// suggests existing records only; the user accepts (the pick or another candidate) or rejects, and every row with
// that value follows. Without the add-on, or when AI fails, nothing shows here and the rows stay as checked.
export type ValueMatch = { column: 'category' | 'location' | 'vendor' | 'status'; raw: string; target_id: string; confidence?: number; reason?: string; status: 'suggested' | 'accepted' | 'rejected'; candidates: { id: string; label: string }[] }
async function aiValues(batchId: string): Promise<{ values?: ValueMatch[]; error?: string }> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const r = await fetch(`${import.meta.env.VITE_API_URL}/imports/${batchId}/ai-values`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } }).catch(() => null)
  return ((await r?.json().catch(() => ({}))) ?? {}) as { values?: ValueMatch[]; error?: string }
}
export const ACCEPT_ALL = 0.9

// What import_decide_values stores: the AI pick keeps its confidence and reason; another candidate is the user's.
export function decision(v: ValueMatch, targetId: string, status: 'accepted' | 'rejected') {
  const ai = targetId === v.target_id
  return { column: v.column, raw: v.raw, target_id: targetId, status, confidence: ai ? v.confidence : undefined, reason: ai ? v.reason : undefined }
}

function ValuesCard({ batch, onChecked }: { batch: Batch; onChecked: () => void }) {
  const [values, setValues] = useState<ValueMatch[]>()
  const [pick, setPick] = useState<Record<string, string>>({})
  const [msg, setMsg] = useState<{ ok: boolean; text: string }>()
  const [busy, setBusy] = useState(false)
  const v = t.import.values
  // One call per check result (the key changes with validated_at); the ref keeps it to one under StrictMode.
  const asked = useRef(false)
  useEffect(() => {
    if (asked.current) return
    asked.current = true
    void aiValues(batch.id).then(({ values: got, error }) => {
      const text = aiError(error)
      if (text) setMsg({ ok: false, text })
      setValues(got ?? [])
    })
  }, [batch.id])

  const keyOf = (x: ValueMatch) => `${x.column}|${x.raw}`
  async function decide(list: ReturnType<typeof decision>[]) {
    setBusy(true)
    const { error } = await supabase.rpc('import_decide_values', { p_batch_id: batch.id, p_decisions: list })
    if (error) {
      setBusy(false)
      return setMsg({ ok: false, text: v.failed })
    }
    // A decision makes the batch mapped again (V8); check the rows straight away, as after a mapping save.
    setMsg({ ok: true, text: t.import.check.running })
    await supabase.rpc('import_validate', { p_batch_id: batch.id })
    onChecked()
  }

  if (!values?.length) return msg ? <p className="hint">{msg.text}</p> : null
  const high = values.filter((x) => x.status === 'suggested' && (x.confidence ?? 0) >= ACCEPT_ALL)
  return (
    <div className="card stack">
      <div className="page-head">
        <div>
          <h2>{v.title}</h2>
          <p className="muted">{v.subtitle}</p>
        </div>
        <button type="button" className="btn" disabled={busy || !high.length} onClick={() => void decide(high.map((x) => decision(x, x.target_id, 'accepted')))}>
          {v.acceptAll}
        </button>
      </div>
      {msg && (
        <p className={msg.ok ? 'save-ok' : 'field-error'} role={msg.ok ? 'status' : 'alert'}>
          {msg.text}
        </p>
      )}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{v.field}</th>
              <th>{v.inFile}</th>
              <th>{v.match}</th>
              <th>{v.confidence}</th>
              <th>{v.reason}</th>
              <th>{v.decision}</th>
            </tr>
          </thead>
          <tbody>
            {values.map((x) => {
              const chosen = pick[keyOf(x)] ?? x.target_id
              const ai = chosen === x.target_id && x.confidence !== undefined
              return (
                <tr key={keyOf(x)}>
                  <td>{v.fields[x.column]}</td>
                  <td>{x.raw}</td>
                  <td>
                    <select className="filter" aria-label={`${v.match}: ${x.raw}`} value={chosen} disabled={busy} onChange={(e) => setPick({ ...pick, [keyOf(x)]: e.target.value })}>
                      {x.candidates.map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.label}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td>
                    {ai ? (
                      <span className={`tag ${(x.confidence ?? 0) >= ACCEPT_ALL ? 'ok' : 'warn'}`}>{t.import.mapping.aiSuggested.replace('{percent}', String(Math.round((x.confidence ?? 0) * 100)))}</span>
                    ) : (
                      <span className="tag">{t.import.mapping.changed}</span>
                    )}
                  </td>
                  <td>{ai && x.reason ? v.reasons[x.reason as keyof typeof v.reasons] : ''}</td>
                  <td>
                    {x.status !== 'suggested' && <span className={`tag ${x.status === 'accepted' ? 'ok' : ''}`}>{v.statuses[x.status]}</span>}{' '}
                    {(x.status !== 'accepted' || chosen !== x.target_id) && (
                      <button type="button" className="btn" disabled={busy} onClick={() => void decide([decision(x, chosen, 'accepted')])}>
                        {v.accept}
                      </button>
                    )}{' '}
                    {x.status !== 'rejected' && (
                      <button type="button" className="btn" disabled={busy} onClick={() => void decide([decision(x, x.target_id, 'rejected')])}>
                        {v.reject}
                      </button>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <p className="hint">{v.notFound}</p>
    </div>
  )
}

function BatchView({ tenantId, batch, catalog, canRun, canCommit, canUndo, canReview = false, onSaved, onHeaderRow }: {
  tenantId: string
  batch: Batch
  catalog: Target[] | undefined
  canRun: boolean
  canCommit: boolean
  canUndo: boolean
  canReview?: boolean
  onSaved: () => void
  onHeaderRow?: (row: number) => void
}) {
  const [rows, setRows] = useState<{ batchId: string; list: { row_number: number; cells: Json }[] }>()
  useEffect(() => {
    let live = true
    void loadRows(batch.id).then((list) => live && setRows({ batchId: batch.id, list }))
    return () => {
      live = false
    }
  }, [batch.id])
  const warnings = (batch.warnings ?? {}) as { list?: Warning[]; total?: number }
  const s = t.import.summary

  // R6: once checked, the mapping card opens only through Back to mapping; a save checks again and closes it.
  const [remapFor, setRemapFor] = useState<string>()
  const remap = remapFor === batch.id || batch.status !== 'validated'
  const live = batch.status === 'staged' || batch.status === 'mapped' || batch.status === 'validated'
  const done = batch.status === 'committed' || batch.status === 'undone'
  return (
    <>
      {(live || done) && <Steps at={done ? 4 : batch.status === 'staged' || remapFor === batch.id ? 1 : 2} />}
      {live && remap && catalog && rows?.batchId === batch.id && (
        <MappingStep
          tenantId={tenantId}
          key={`${batch.id}-${batch.status}`}
          batch={batch}
          catalog={catalog}
          sample={rows.list[0]?.cells as Json[] | undefined}
          canRun={canRun}
          onSaved={() => {
            setRemapFor(undefined)
            onSaved()
          }}
          onHeaderRow={onHeaderRow}
        />
      )}
      {canReview && batch.status === 'validated' && (!!batch.value_suggestions || ['not_found', 'ambiguous'].some((k) => (batch.summary as Summary | null)?.codes?.[k])) && (
        <ValuesCard key={`values-${batch.id}-${(batch.summary as Summary | null)?.validated_at}`} batch={batch} onChecked={onSaved} />
      )}
      {(batch.status === 'mapped' || batch.status === 'validated') && (
        <ReviewCard
          key={`review-${batch.id}-${batch.status}`}
          batch={batch}
          catalog={catalog ?? []}
          canRun={canRun}
          canCommit={canCommit}
          onChecked={onSaved}
          onRemap={batch.status === 'validated' && remapFor !== batch.id ? () => setRemapFor(batch.id) : undefined}
        />
      )}
      {done && <CommitCard key={`commit-${batch.id}-${batch.status}`} batch={batch} canUndo={canUndo} onDone={onSaved} />}
    <div className="card stack">
      <h2>{batch.file_name}</h2>
      <dl className="facts">
        <dt>{s.sheet}</dt>
        <dd>{batch.sheet_name}</dd>
        <dt>{s.headerRow}</dt>
        <dd>{batch.header_row}</dd>
        <dt>{s.columns}</dt>
        <dd>{batch.columns.length}</dd>
        <dt>{s.rows}</dt>
        <dd>{batch.row_count}</dd>
        <dt>{s.status}</dt>
        <dd>{t.import.status[batch.status as keyof typeof t.import.status] ?? batch.status}</dd>
      </dl>
      {!!warnings.total && (
        <div>
          <h3>{s.warnings.replace('{n}', String(warnings.total))}</h3>
          <ul>
            {(warnings.list ?? []).map((w, i) => (
              <li key={i}>
                {t.import.warnings[w.code]
                  ?.replaceAll('{row}', String(w.row ?? ''))
                  .replaceAll('{column}', columnLetter(w.column))}
              </li>
            ))}
          </ul>
        </div>
      )}
      {(live || done) && (
        <div className="table-wrap">
          <p className="muted">{s.preview.replace('{n}', String(Math.min(PREVIEW_ROWS, batch.row_count)))}</p>
          <table>
            <thead>
              <tr>
                <th>{s.row}</th>
                {batch.columns.map((c, i) => (
                  <th key={i}>{c}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows?.batchId === batch.id &&
                rows.list.map((r) => (
                  <tr key={r.row_number}>
                    <td>{r.row_number}</td>
                    {batch.columns.map((_, i) => (
                      <td key={i}>{cellText((r.cells as Json[])[i])}</td>
                    ))}
                  </tr>
                ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
    </>
  )
}

// Stories 8.2 to 8.6: upload, staged rows, column mapping, the row check, the review, commit and undo.
export function ImportPage({ tenantId, canRun, canCommit = false, canUndo = false, canReview = false }: { tenantId: string; canRun: boolean; canCommit?: boolean; canUndo?: boolean; canReview?: boolean }) {
  const [file, setFile] = useState<File>()
  const [sheet, setSheet] = useState<string>()
  const [upload, setUpload] = useState<Upload>({ state: 'idle' })
  const [batches, setBatches] = useState<{ tenantId: string; list: Batch[] }>()
  const [selected, setSelected] = useState<string>()
  const [catalog, setCatalog] = useState<{ tenantId: string; list: Target[] }>()

  const refresh = () => loadBatches().then((list) => setBatches({ tenantId, list }))
  useEffect(() => {
    let live = true
    void loadBatches().then((list) => live && setBatches({ tenantId, list }))
    void supabase.rpc('import_target_catalog').then(({ data }) => live && setCatalog({ tenantId, list: data ?? [] }))
    return () => {
      live = false
    }
  }, [tenantId])

  async function start(f: File, sheetName?: string, headerRow?: number) {
    setUpload({ state: 'sending', percent: 0 })
    const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
    const r = await send(f, token, { sheet: sheetName, headerRow }, (percent) => setUpload(percent < 100 ? { state: 'sending', percent } : { state: 'reading' }))
    if (r.status !== 201 || !r.body.batch_id) return setUpload({ state: 'failed', error: uploadError(r.status, r.body.error) })
    setUpload({ state: 'idle' })
    setSelected(r.body.batch_id)
    await refresh()
  }

  const list = batches?.tenantId === tenantId ? batches.list : undefined
  const current = list?.find((b) => b.id === selected) ?? list?.[0]
  const busy = upload.state === 'sending' || upload.state === 'reading'
  const fields = catalog?.tenantId === tenantId ? catalog.list : undefined
  // The browser still holds the file, so a new header row is a re-upload (M10; the service keeps no file, I6).
  const sameFile = !!file && current?.file_name === file.name

  return (
    <>
      <title>{`${t.import.title} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.import.title}</h1>
          <p className="muted">{t.import.subtitle}</p>
        </div>
      </div>
      {canRun && (
        <div className="card stack">
          <label className="field">
            <span>{t.import.file}</span>
            <input
              type="file"
              accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
              disabled={busy}
              onChange={(e) => {
                const f = e.target.files?.[0]
                setFile(f)
                setSheet(undefined)
                if (f) void start(f)
              }}
            />
          </label>
          <p className="hint">{t.import.limits}</p>
          {upload.state === 'sending' && (
            <progress max={100} value={upload.percent} aria-label={t.import.sending}>
              {upload.percent}%
            </progress>
          )}
          {upload.state === 'reading' && <p role="status">{t.import.reading}</p>}
          {upload.state === 'failed' && <p className="field-error" role="alert">{upload.error}</p>}
          {sameFile && current && current.sheet_names.length > 1 && (
            <label className="field">
              <span>{t.import.otherSheet}</span>
              <select
                className="filter"
                value={sheet ?? current.sheet_name}
                disabled={busy}
                onChange={(e) => {
                  setSheet(e.target.value)
                  void start(file!, e.target.value)
                }}
              >
                {current.sheet_names.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
      )}
      {canRun && fields && !current && <FieldList catalog={fields} />}
      {current && (
        <BatchView
          tenantId={tenantId}
          batch={current}
          catalog={fields}
          canRun={canRun}
          canCommit={canCommit}
          canUndo={canUndo}
          canReview={canReview}
          onSaved={() => void refresh()}
          onHeaderRow={sameFile ? (row) => void start(file!, current.sheet_name, row) : undefined}
        />
      )}
      {canRun && fields && current && <FieldList catalog={fields} />}
      {list && list.length > 1 && (
        <div className="card">
          <h2>{t.import.recent}</h2>
          <ul className="list">
            {list.map((b) => (
              <li key={b.id}>
                <button type="button" className="row-link" onClick={() => setSelected(b.id)} aria-current={b.id === current?.id}>
                  {t.import.recentRow.replace('{file}', b.file_name).replace('{sheet}', b.sheet_name).replace('{n}', String(b.row_count))}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
      {list && !list.length && <p className="muted">{t.import.none}</p>}
    </>
  )
}
