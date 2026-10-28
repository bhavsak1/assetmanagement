import { useEffect, useRef, useState, type ChangeEvent } from 'react'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Database, TablesInsert } from './types/database'

type Attachment = Database['public']['Functions']['asset_attachments']['Returns'][number]
type Can = (domain: string, operation: string) => boolean

const x = t.assetDetail.attachments
// Same limits as the 'attachments' bucket (migration 3_6_attachment_storage). Storage is the truth; this is fast feedback.
export const MAX_BYTES = 10 * 1024 * 1024
export const TYPES = [
  'image/jpeg', 'image/png', 'image/webp', 'image/heic',
  'application/pdf',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain', 'text/csv',
]
// Opened in a new tab; everything else downloads (Content-Disposition: attachment). HEIC does not show in most browsers.
const INLINE = ['image/jpeg', 'image/png', 'image/webp']

// The reason a file cannot be uploaded, or undefined when it can.
export function checkFile(f: { type: string; size: number }): string | undefined {
  if (!TYPES.includes(f.type)) return x.badType
  if (f.size > MAX_BYTES) return x.tooBig
  if (f.size === 0) return x.empty
}

export const fileSize = (n: number) => (n < 1024 * 1024 ? x.kb.replace('{n}', String(Math.max(1, Math.round(n / 1024)))) : x.mb.replace('{n}', (n / 1024 / 1024).toFixed(1)))

// shortcut: supabase-js upload has no progress events, so this posts to the same Storage endpoint with XHR.
// Upgrade to TUS (resumable) if large files or bad networks become common.
function put(path: string, file: File, token: string, onProgress: (p: number) => void): Promise<boolean> {
  return new Promise((resolve) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', `${import.meta.env.VITE_SUPABASE_URL}/storage/v1/object/attachments/${path}`)
    xhr.setRequestHeader('Authorization', `Bearer ${token}`)
    xhr.setRequestHeader('apikey', import.meta.env.VITE_SUPABASE_ANON_KEY)
    xhr.setRequestHeader('Content-Type', file.type)
    xhr.setRequestHeader('x-upsert', 'false')
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total)
    xhr.onload = () => resolve(xhr.status >= 200 && xhr.status < 300)
    xhr.onerror = () => resolve(false)
    xhr.send(file)
  })
}

// 5.2b: files on an asset (3.6) or on a service record. The path's entity segment and the permissions differ.
export type Entity = 'asset' | 'service_record'
const KIND = {
  asset: { domain: 'asset_attachment', remove: 'delete' },
  service_record: { domain: 'service_record', remove: 'update' },
} as const
const pathOf = (tenantId: string, entity: Entity, entityId: string, id: string) => `${tenantId}/${entity}/${entityId}/${id}`

// Z6: the file first, then its row. A failed row leaves an unreadable orphan, never a row without a file.
// mime_type and size_bytes are not in the insert grant: the database trigger copies them from the stored file.
export async function uploadAttachment(tenantId: string, entity: Entity, entityId: string, file: File, onProgress: (p: number) => void): Promise<boolean> {
  const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
  const id = crypto.randomUUID()
  if (!(await put(pathOf(tenantId, entity, entityId, id), file, token, onProgress))) return false
  const row = { id, tenant_id: tenantId, file_name: file.name.slice(-255) }
  const { error } =
    entity === 'asset'
      ? await supabase.from('asset_attachment').insert({ ...row, asset_id: entityId } as TablesInsert<'asset_attachment'>)
      : await supabase.from('service_record_attachment').insert({ ...row, service_record_id: entityId } as TablesInsert<'service_record_attachment'>)
  return !error
}

export function AttachmentsTab({ tenantId, entity = 'asset', entityId, can, timeZone }: { tenantId: string; entity?: Entity; entityId: string; can: Can; timeZone?: string }) {
  const [rows, setRows] = useState<Attachment[]>()
  const [error, setError] = useState<string>()
  const [progress, setProgress] = useState<number>()
  const [version, setVersion] = useState(0)
  const input = useRef<HTMLInputElement>(null)
  const k = KIND[entity]
  const path = (id: string) => pathOf(tenantId, entity, entityId, id)

  useEffect(() => {
    let live = true
    const list =
      entity === 'asset'
        ? supabase.rpc('asset_attachments', { p_asset_id: entityId })
        : supabase.rpc('service_record_attachments', { p_service_record_id: entityId })
    void list.then(({ data, error }) => {
      if (!live) return
      setRows(data ?? [])
      if (error) setError(x.loadError)
    })
    return () => {
      live = false
    }
  }, [entity, entityId, version])

  async function upload(ev: ChangeEvent<HTMLInputElement>) {
    const file = ev.target.files?.[0]
    ev.target.value = ''
    if (!file) return
    const bad = checkFile(file)
    setError(bad)
    if (bad) return
    setProgress(0)
    const ok = await uploadAttachment(tenantId, entity, entityId, file, setProgress)
    setProgress(undefined)
    if (!ok) setError(x.uploadError)
    setVersion((v) => v + 1)
  }

  async function open(r: Attachment) {
    const inline = INLINE.includes(r.mime_type)
    // Opened before the await, so pop-up blockers allow it.
    const tab = inline ? window.open('', '_blank') : null
    const { data, error } = await supabase.storage.from('attachments').createSignedUrl(path(r.id), 60, inline ? undefined : { download: r.file_name })
    if (error || !data) {
      tab?.close()
      setError(x.openError)
    } else if (tab) {
      tab.opener = null
      tab.location.href = data.signedUrl
    } else window.location.assign(data.signedUrl)
  }

  async function remove(r: Attachment) {
    if (!window.confirm(x.deleteConfirm.replace('{name}', r.file_name))) return
    const { error } = await supabase.from(entity === 'asset' ? 'asset_attachment' : 'service_record_attachment').update({ deleted_at: new Date().toISOString() }).eq('id', r.id)
    if (error) setError(x.deleteError)
    setVersion((v) => v + 1)
  }

  if (rows === undefined) return <p className="muted" role="status">{t.assetDetail.loading}</p>
  const when = (iso: string) => new Date(iso).toLocaleString(undefined, { timeZone, dateStyle: 'medium', timeStyle: 'short' })
  return (
    <div className="stack detail">
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {can(k.domain, 'create') && (
        <div className="page-head">
          <span className="muted">{x.limits}</span>
          <div className="spacer" />
          {progress !== undefined && <progress value={progress} max={1} aria-label={x.uploading} />}
          <input ref={input} type="file" hidden accept={TYPES.join(',')} onChange={(ev) => void upload(ev)} />
          <button className="btn btn-main" type="button" disabled={progress !== undefined} onClick={() => input.current?.click()}>
            {x.upload}
          </button>
        </div>
      )}
      <section className="card list table-wrap">
        {rows.length === 0 ? (
          <p className="muted">{x.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{x.name}</th>
                <th>{x.size}</th>
                <th>{x.by}</th>
                <th>{x.when}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>
                    <button className="row-link" type="button" onClick={() => void open(r)}>
                      {r.file_name}
                    </button>
                  </td>
                  <td>{fileSize(r.size_bytes)}</td>
                  <td>{r.uploaded_by ?? t.assetDetail.history.formerMember}</td>
                  <td>{when(r.created_at)}</td>
                  <td className="actions">
                    {can(k.domain, k.remove) && (
                      <button className="btn" type="button" onClick={() => void remove(r)}>
                        {x.delete}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  )
}
