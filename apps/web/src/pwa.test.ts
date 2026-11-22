// @vitest-environment jsdom
// 11.5: the web manifest is valid, matches the tokens and i18n, and the QR scan link opens inside the app's scope.
import { expect, test, vi } from 'vitest'
import manifestText from '../public/manifest.webmanifest?raw'
import indexHtml from '../index.html?raw'
import icon192 from '../public/icon-192.png?inline'
import icon512 from '../public/icon-512.png?inline'
import iconMaskable from '../public/icon-maskable-512.png?inline'
import appleIcon from '../public/apple-touch-icon.png?inline'
import { scanUrl } from './AssetLabel'
import { t } from './i18n'

vi.mock('./supabase', () => ({ supabase: {} }))

const manifest = JSON.parse(manifestText) as {
  name: string
  short_name: string
  start_url: string
  scope: string
  display: string
  theme_color: string
  background_color: string
  icons: { src: string; sizes: string; type: string; purpose: string }[]
}

// PNG width and height sit at bytes 16 to 23 of the IHDR chunk.
const pngSize = (dataUrl: string) => {
  const b = atob(dataUrl.split(',')[1] ?? '')
  const u32 = (o: number) => ((b.charCodeAt(o) << 24) | (b.charCodeAt(o + 1) << 16) | (b.charCodeAt(o + 2) << 8) | b.charCodeAt(o + 3)) >>> 0
  expect(b.slice(1, 4)).toBe('PNG')
  return `${u32(16)}x${u32(20)}`
}

test('manifest has what Chrome needs to offer install', () => {
  expect(manifest.name).toBe(t.app.name)
  expect(manifest.short_name).toBe(t.app.name)
  expect(manifest.display).toBe('standalone')
  expect(manifest.start_url.startsWith(manifest.scope)).toBe(true)
  const sizes = manifest.icons.filter((i) => i.type === 'image/png').map((i) => `${i.sizes} ${i.purpose}`)
  expect(sizes).toEqual(expect.arrayContaining(['192x192 any', '512x512 any', '512x512 maskable']))
})

// Same values as --color-primary and --color-bg in tokens.css (vitest blanks CSS imports, so they are written here).
test('manifest colours match the design tokens', () => {
  expect(manifest.theme_color).toBe('#0B6E6E')
  expect(manifest.background_color).toBe('#F6F7F9')
  expect(indexHtml).toContain(`name="theme-color" content="${manifest.theme_color}"`)
})

test('icon files have the sizes the manifest and index.html claim', () => {
  expect(pngSize(icon192)).toBe('192x192')
  expect(pngSize(icon512)).toBe('512x512')
  expect(pngSize(iconMaskable)).toBe('512x512')
  expect(pngSize(appleIcon)).toBe('180x180')
  expect(indexHtml).toContain('rel="manifest" href="/manifest.webmanifest"')
  expect(indexHtml).toContain('rel="apple-touch-icon" href="/apple-touch-icon.png"')
  expect(indexHtml).toContain(`<title>${t.app.name}</title>`)
})

test('the QR scan link falls inside the installed app scope', () => {
  const scope = new URL(manifest.scope, window.location.origin)
  const scan = new URL(scanUrl('6f1c2d3e-0000-4000-8000-000000000001'))
  expect(scan.origin).toBe(scope.origin)
  expect(scan.pathname.startsWith(scope.pathname)).toBe(true)
})
