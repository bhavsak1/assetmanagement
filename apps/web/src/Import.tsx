import { useEffect, useState } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Json, Tables } from './types/database'

type Batch = Pick<Tables<'import_batch'>, 'id' | 'file_name' | 'sheet_name' | 'sheet_names' | 'header_row' | 'columns' | 'row_count' | 'warnings' | 'status' | 'created_at' | 'mapping' | 'mapping_template_id' | 'summary'>
export type Target = { target: string; label: string; kind: string; required: boolean; category_id: string | null }
type Template = Pick<Tables<'import_mapping_template'>, 'id' | 'name' | 'headers' | 'targets'>
// source: how the target was chosen; 'user' once the person changes it here.
export type Entry = { target: string; source: 'template' | 'rules' | 'ai' | 'user' }
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
    .select('id, file_name, sheet_name, sheet_names, header_row, columns, row_count, warnings, status, created_at, mapping, mapping_template_id, summary')
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
  const m = t.import.mapping

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

type Summary = { ok: number; warning: number; error: number; create_assets: number; create_coverages: number; skip: number; validated_at: string }
type Message = { col?: number; code: string; params?: Record<string, Json> }
type Issue = { row: number; warn: boolean; col?: number; text: string; value: string }
const ISSUES = 200
// Same list as import_validate: these never make a row an error.
const WARNINGS = ['currency_defaulted', 'possible_duplicate']

// One message in words. Messages hold a code and fixed params, never cell text (8.4 §15.5).
export function messageText(m: Message, catalog: Target[]): string {
  const codes = t.import.check.codes
  const text = m.code in codes ? codes[m.code as keyof typeof codes] : m.code
  return Object.entries(m.params ?? {}).reduce(
    (s, [k, v]) => s.replaceAll(`{${k}}`, k === 'field' ? (catalog.find((f) => f.target === v)?.label ?? String(v)) : String(v)),
    text,
  )
}

// 8.4: the row check and dry run. The full review grid is 8.5.
function CheckCard({ batch, catalog, canRun, onChecked }: { batch: Batch; catalog: Target[]; canRun: boolean; onChecked: () => void }) {
  const [issues, setIssues] = useState<Issue[]>()
  const [state, setState] = useState<'idle' | 'running' | 'failed'>('idle')
  const c = t.import.check
  const s = batch.summary as Summary | null

  useEffect(() => {
    if (!s) return
    let live = true
    void supabase
      .from('import_row')
      .select('row_number, messages, cells')
      .eq('batch_id', batch.id)
      .in('result', ['error', 'warning'])
      .order('row_number')
      .limit(ISSUES)
      .then(({ data }) => {
        if (!live) return
        const list = (data ?? []).flatMap((r) =>
          ((r.messages ?? []) as Message[]).map((m) => ({
            row: r.row_number,
            warn: WARNINGS.includes(m.code),
            col: m.col,
            text: messageText(m, catalog),
            value: m.col === undefined ? '' : cellText((r.cells as Json[])[m.col]),
          })))
        setIssues(list.slice(0, ISSUES))
      })
    return () => {
      live = false
    }
  }, [batch.id, s, catalog])

  async function run() {
    setState('running')
    const { error } = await supabase.rpc('import_validate', { p_batch_id: batch.id })
    setState(error ? 'failed' : 'idle')
    if (!error) onChecked()
  }

  return (
    <div className="card stack">
      <div className="page-head">
        <div>
          <h2>{c.title}</h2>
          <p className="muted">{c.subtitle}</p>
        </div>
        {canRun && (
          <button type="button" className="btn" disabled={state === 'running'} onClick={() => void run()}>
            {s ? c.again : c.run}
          </button>
        )}
      </div>
      {state === 'running' && <p role="status">{c.running}</p>}
      {state === 'failed' && <p className="field-error" role="alert">{c.failed}</p>}
      {s && (
        <>
          <dl className="facts">
            <dt>{c.ok}</dt>
            <dd>{s.ok}</dd>
            <dt>{c.warning}</dt>
            <dd>{s.warning}</dd>
            <dt>{c.error}</dt>
            <dd>{s.error}</dd>
          </dl>
          <p>
            {c.dryRun
              .replace('{assets}', String(s.create_assets))
              .replace('{coverages}', String(s.create_coverages))
              .replace('{skip}', String(s.skip))}
          </p>
          <p className="hint">{c.asOf.replace('{when}', new Date(s.validated_at).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }))}</p>
          {issues && !issues.length && <p className="save-ok">{c.none}</p>}
          {!!issues?.length && (
            <div className="table-wrap">
              <p className="muted">{c.issues.replace('{n}', String(issues.length))}</p>
              <table>
                <thead>
                  <tr>
                    <th>{c.row}</th>
                    <th>{c.column}</th>
                    <th>{c.problem}</th>
                    <th>{c.value}</th>
                  </tr>
                </thead>
                <tbody>
                  {issues.map((x, i) => (
                    <tr key={i}>
                      <td>{x.row}</td>
                      <td>{x.col === undefined ? '' : `${columnLetter(x.col)} · ${batch.columns[x.col]}`}</td>
                      <td>
                        <span className={x.warn ? 'tag warn' : 'tag error'}>{x.warn ? c.warningTag : c.errorTag}</span> {x.text}
                      </td>
                      <td className="muted">{x.value}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function BatchView({ tenantId, batch, catalog, canRun, onSaved, onHeaderRow }: {
  tenantId: string
  batch: Batch
  catalog: Target[] | undefined
  canRun: boolean
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

  const live = batch.status === 'staged' || batch.status === 'mapped' || batch.status === 'validated'
  return (
    <>
      {live && <Steps at={batch.status === 'staged' ? 1 : 2} />}
      {live && catalog && rows?.batchId === batch.id && (
        <MappingStep
          tenantId={tenantId}
          key={`${batch.id}-${batch.status}`}
          batch={batch}
          catalog={catalog}
          sample={rows.list[0]?.cells as Json[] | undefined}
          canRun={canRun}
          onSaved={onSaved}
          onHeaderRow={onHeaderRow}
        />
      )}
      {(batch.status === 'mapped' || batch.status === 'validated') && (
        <CheckCard key={`check-${batch.id}-${batch.status}`} batch={batch} catalog={catalog ?? []} canRun={canRun} onChecked={onSaved} />
      )}
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
      {live && (
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
      <p className="hint">{s.next}</p>
    </div>
    </>
  )
}

// Stories 8.2 to 8.4: upload, staged rows, column mapping and the row check. Review and commit are 8.5 and 8.6.
export function ImportPage({ tenantId, canRun }: { tenantId: string; canRun: boolean }) {
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
