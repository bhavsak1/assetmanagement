// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AttachmentsTab, checkFile, fileSize, MAX_BYTES } from './Attachments'
import { t } from './i18n'

const x = t.assetDetail.attachments
const db = vi.hoisted(() => ({ inserts: [] as unknown[], insertError: null as unknown, list: [] as unknown[] }))

vi.mock('./supabase', () => ({
  supabase: {
    rpc: () => Promise.resolve({ data: db.list, error: null }),
    from: () => ({
      insert: (row: unknown) => {
        db.inserts.push(row)
        return Promise.resolve({ error: db.insertError })
      },
    }),
    auth: { getSession: () => Promise.resolve({ data: { session: { access_token: 'tok' } } }) },
  },
}))

// XHR stand-in: records each upload and answers 200.
const sent: { url: string; headers: Record<string, string> }[] = []
class FakeXhr {
  url = ''
  status = 200
  headers: Record<string, string> = {}
  upload: { onprogress?: (e: { lengthComputable: boolean; loaded: number; total: number }) => void } = {}
  onload?: () => void
  onerror?: () => void
  open(_m: string, url: string) {
    this.url = url
  }
  setRequestHeader(k: string, v: string) {
    this.headers[k] = v
  }
  send() {
    sent.push({ url: this.url, headers: this.headers })
    this.upload.onprogress?.({ lengthComputable: true, loaded: 1, total: 2 })
    this.onload?.()
  }
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true, XMLHttpRequest: FakeXhr })

test('checkFile: allowed types up to 10 MB, nothing empty', () => {
  expect(checkFile({ type: 'application/pdf', size: 1000 })).toBeUndefined()
  expect(checkFile({ type: 'image/jpeg', size: MAX_BYTES })).toBeUndefined()
  expect(checkFile({ type: 'image/jpeg', size: MAX_BYTES + 1 })).toBe(x.tooBig)
  expect(checkFile({ type: 'image/svg+xml', size: 10 })).toBe(x.badType)
  expect(checkFile({ type: 'text/html', size: 10 })).toBe(x.badType)
  expect(checkFile({ type: '', size: 10 })).toBe(x.badType)
  expect(checkFile({ type: 'text/plain', size: 0 })).toBe(x.empty)
})

test('fileSize: KB under 1 MB, MB above', () => {
  expect(fileSize(10)).toBe('1 KB')
  expect(fileSize(2048)).toBe('2 KB')
  expect(fileSize(3 * 1024 * 1024)).toBe('3.0 MB')
})

let container: HTMLDivElement
let root: Root

beforeEach(() => {
  db.inserts = []
  db.insertError = null
  db.list = [{ id: 'f1', file_name: 'Manual.pdf', mime_type: 'application/pdf', size_bytes: 2048, created_at: '2026-10-22T10:00:00Z', uploaded_by: 'Test User' }]
  sent.length = 0
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(grants: string[]) {
  const can = (domain: string, op: string) => grants.includes(`${domain}.${op}`)
  await act(async () => root.render(<AttachmentsTab tenantId="ta" assetId="a1" can={can} timeZone="Asia/Kolkata" />))
}
const buttons = () => [...container.querySelectorAll('button')].map((b) => b.textContent)

async function pick(file: File) {
  const input = container.querySelector<HTMLInputElement>('input[type="file"]')!
  Object.defineProperty(input, 'files', { value: [file], configurable: true })
  await act(async () => input.dispatchEvent(new Event('change', { bubbles: true })))
}

test('list: name, size, uploader; no Upload or Delete with view only', async () => {
  await render(['asset_attachment.view'])
  expect(container.textContent).toContain('Manual.pdf')
  expect(container.textContent).toContain('2 KB')
  expect(container.textContent).toContain('Test User')
  expect(buttons()).not.toContain(x.upload)
  expect(buttons()).not.toContain(x.delete)
})

test('upload: a refused type shows a message and sends nothing', async () => {
  await render(['asset_attachment.view', 'asset_attachment.create'])
  await pick(new File(['<svg/>'], 'x.svg', { type: 'image/svg+xml' }))
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(x.badType)
  expect(sent).toHaveLength(0)
  expect(db.inserts).toHaveLength(0)
})

test('upload: file to the tenant path first, then its row', async () => {
  await render(['asset_attachment.view', 'asset_attachment.create', 'asset_attachment.delete'])
  expect(buttons()).toContain(x.delete)
  await pick(new File(['%PDF'], 'Manual v2.pdf', { type: 'application/pdf' }))
  expect(sent).toHaveLength(1)
  const id = (db.inserts[0] as { id: string }).id
  expect(sent[0]!.url).toMatch(new RegExp(`/storage/v1/object/attachments/ta/asset/a1/${id}$`))
  expect(sent[0]!.headers).toMatchObject({ Authorization: 'Bearer tok', 'Content-Type': 'application/pdf', 'x-upsert': 'false' })
  expect(db.inserts[0]).toEqual({ id, tenant_id: 'ta', asset_id: 'a1', file_name: 'Manual v2.pdf' })
  expect(container.querySelector('[role="alert"]')).toBeNull()
})

test('upload: a refused row shows the upload error', async () => {
  db.insertError = { code: '42501' }
  await render(['asset_attachment.view', 'asset_attachment.create'])
  await pick(new File(['%PDF'], 'a.pdf', { type: 'application/pdf' }))
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(x.uploadError)
})
