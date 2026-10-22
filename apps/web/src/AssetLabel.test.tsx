// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter, Route, Routes } from 'react-router'
import { encode } from 'uqr'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AssetLabelPage } from './AssetLabel'
import { t } from './i18n'

const db = vi.hoisted(() => ({ assets: [] as { id: string; tag: string; name: string }[] }))

vi.mock('./supabase', () => {
  const q: Record<string, unknown> = {}
  for (const m of ['from', 'select', 'eq']) q[m] = () => q
  q.then = (resolve: (v: unknown) => void) => resolve({ data: db.assets, error: null })
  return { supabase: q }
})

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

async function render(id: string) {
  await act(async () =>
    root.render(
      <MemoryRouter initialEntries={[`/assets/${id}/label`]}>
        <Routes>
          <Route path="/assets/:assetId/label" element={<AssetLabelPage />} />
        </Routes>
      </MemoryRouter>,
    ),
  )
}

test('label: tag, name and a QR that encodes the scan URL', async () => {
  db.assets = [{ id: 'a1', tag: 'PMP-0001', name: 'Cooling pump' }]
  await render('a1')
  const label = container.querySelector('.qr-label')!
  expect(label.querySelector('b')?.textContent).toBe('PMP-0001')
  expect(label.textContent).toContain('Cooling pump')
  // Every dark module of the grid for the expected URL is a rect, and nothing else is.
  const { data } = encode(`${window.location.origin}/q/a1`, { ecc: 'M' })
  const want = data.flatMap((row, y) => row.flatMap((on, x) => (on ? [`${x}.${y}`] : [])))
  const got = [...label.querySelectorAll('svg rect[x]')].map((r) => `${r.getAttribute('x')}.${r.getAttribute('y')}`)
  expect(got).toEqual(want)
  expect(label.querySelector('svg')?.getAttribute('aria-label')).toBe(t.assetDetail.label.qr)
})

test('label of an id the user cannot see: not found, no QR', async () => {
  db.assets = []
  await render('other')
  expect(container.textContent).toBe(t.assetDetail.notFound)
  expect(container.querySelector('svg')).toBeNull()
})
