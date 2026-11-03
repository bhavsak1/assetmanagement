import { useEffect, useState } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Json, Tables } from './types/database'

type Batch = Pick<Tables<'import_batch'>, 'id' | 'file_name' | 'sheet_name' | 'sheet_names' | 'header_row' | 'columns' | 'row_count' | 'warnings' | 'status' | 'created_at'>
type Warning = { code: keyof typeof t.import.warnings; row?: number; column: number }
type Upload = { state: 'idle' } | { state: 'sending'; percent: number } | { state: 'reading' } | { state: 'failed'; error: string }

const PREVIEW_ROWS = 20

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
function send(file: File, token: string, sheet: string | undefined, onProgress: (percent: number) => void) {
  return new Promise<{ status: number; body: { batch_id?: string; error?: string } }>((resolve) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', `${import.meta.env.VITE_API_URL}/imports${sheet ? `?sheet=${encodeURIComponent(sheet)}` : ''}`)
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
    .select('id, file_name, sheet_name, sheet_names, header_row, columns, row_count, warnings, status, created_at')
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

function cellText(v: Json | undefined): string {
  if (v === null || v === undefined) return ''
  return typeof v === 'object' ? JSON.stringify(v) : String(v)
}

function BatchView({ batch }: { batch: Batch }) {
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

  return (
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
      {batch.status === 'staged' && (
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
  )
}

// Story 8.2: upload and staged rows only. The full ImportReview screen (mapping, review, commit) is 8.5.
export function ImportPage({ tenantId, canRun }: { tenantId: string; canRun: boolean }) {
  const [file, setFile] = useState<File>()
  const [sheet, setSheet] = useState<string>()
  const [upload, setUpload] = useState<Upload>({ state: 'idle' })
  const [batches, setBatches] = useState<{ tenantId: string; list: Batch[] }>()
  const [selected, setSelected] = useState<string>()

  const refresh = () => loadBatches().then((list) => setBatches({ tenantId, list }))
  useEffect(() => {
    let live = true
    void loadBatches().then((list) => live && setBatches({ tenantId, list }))
    return () => {
      live = false
    }
  }, [tenantId])

  async function start(f: File, sheetName?: string) {
    setUpload({ state: 'sending', percent: 0 })
    const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
    const r = await send(f, token, sheetName, (percent) => setUpload(percent < 100 ? { state: 'sending', percent } : { state: 'reading' }))
    if (r.status !== 201 || !r.body.batch_id) return setUpload({ state: 'failed', error: uploadError(r.status, r.body.error) })
    setUpload({ state: 'idle' })
    setSelected(r.body.batch_id)
    await refresh()
  }

  const list = batches?.tenantId === tenantId ? batches.list : undefined
  const current = list?.find((b) => b.id === selected) ?? list?.[0]
  const busy = upload.state === 'sending' || upload.state === 'reading'

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
          {file && current && current.file_name === file.name && current.sheet_names.length > 1 && (
            <label className="field">
              <span>{t.import.otherSheet}</span>
              <select
                className="filter"
                value={sheet ?? current.sheet_name}
                disabled={busy}
                onChange={(e) => {
                  setSheet(e.target.value)
                  void start(file, e.target.value)
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
      {current && <BatchView batch={current} />}
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
