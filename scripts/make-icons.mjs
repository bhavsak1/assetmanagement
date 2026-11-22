// 11.5: render apps/web/public/icon.svg to the PWA PNGs with headless Edge (or Chrome). No npm dependency.
// Run once after changing icon.svg: node scripts/make-icons.mjs   (set BROWSER to the browser path if needed)
// Edge's launcher can exit before the PNG is on disk: wait a second before checking the files.
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const pub = resolve(import.meta.dirname, '../apps/web/public')
const svg = readFileSync(join(pub, 'icon.svg'), 'utf8')
const browser = process.env.BROWSER ?? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
const teal = '#0B6E6E' // --color-primary

// full: teal edge to edge with the logo inside the maskable safe zone (Android masks, iOS rounds).
const icons = [
  { file: 'icon-192.png', size: 192, full: false },
  { file: 'icon-512.png', size: 512, full: false },
  { file: 'icon-maskable-512.png', size: 512, full: true },
  { file: 'apple-touch-icon.png', size: 180, full: true },
]

const dir = mkdtempSync(join(tmpdir(), 'assetly-icons-'))
for (const { file, size, full } of icons) {
  const inner = full ? Math.round(size * 0.8) : size
  const html = join(dir, `${file}.html`)
  writeFileSync(
    html,
    `<html><body style="margin:0;width:${size}px;height:${size}px;display:grid;place-items:center;background:${full ? teal : 'transparent'}">` +
      `<div style="width:${inner}px;height:${inner}px">${svg.replace('<svg ', '<svg width="100%" height="100%" ')}</div></body></html>`,
  )
  execFileSync(browser, [
    '--headless',
    '--disable-gpu',
    '--hide-scrollbars',
    '--default-background-color=00000000',
    `--window-size=${size},${size}`,
    `--screenshot=${join(pub, file)}`,
    pathToFileURL(html).href,
  ])
  console.log('wrote', file)
}
