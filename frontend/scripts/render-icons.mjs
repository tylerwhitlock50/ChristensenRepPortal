/**
 * Renders the install icons in public/ from public/favicon.svg, with
 * Playwright's Chromium (already a dev dependency for the mobile tests).
 *
 *   node scripts/render-icons.mjs
 *
 * Re-run it whenever favicon.svg changes, and commit the PNGs: they are
 * build inputs, not build outputs, so a Vercel build never needs a browser.
 *
 * favicon.svg is the whole icon: the header's orange tick and an "RP"
 * monogram (drawn as paths, so no font is needed) on an ink tile, the
 * header color #12130F, with its own margins. The standard icons draw it
 * full-bleed. iOS paints a transparent apple-touch-icon black anyway, and
 * Android crops a maskable icon to whatever shape the launcher likes, so the
 * maskable one shrinks it onto more ink to keep the mark inside the central
 * safe circle.
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from '@playwright/test'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const pub = join(root, 'public')
const svg = readFileSync(join(pub, 'favicon.svg'), 'utf8')
const INK = '#12130F'

const icons = [
  { file: 'pwa-192x192.png', size: 192, mark: 1 },
  { file: 'pwa-512x512.png', size: 512, mark: 1 },
  { file: 'pwa-maskable-512x512.png', size: 512, mark: 0.84 },
  { file: 'apple-touch-icon-180x180.png', size: 180, mark: 1 },
  // The tab icon for browsers that skip an SVG favicon (older Safari).
  { file: 'favicon-32x32.png', size: 32, mark: 1 },
]

const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM || undefined,
})
const page = await browser.newPage({ deviceScaleFactor: 1 })
for (const { file, size, mark } of icons) {
  await page.setViewportSize({ width: size, height: size })
  await page.setContent(`<!doctype html>
    <html><body style="margin:0">
      <div style="width:${size}px;height:${size}px;background:${INK};display:grid;place-items:center">
        <div style="width:${Math.round(size * mark)}px;height:${Math.round(size * mark)}px;display:grid;place-items:center">
          ${svg.replace('<svg ', '<svg style="width:100%;height:100%" preserveAspectRatio="xMidYMid meet" ')}
        </div>
      </div>
    </body></html>`)
  await page.screenshot({ path: join(pub, file), clip: { x: 0, y: 0, width: size, height: size } })
  console.log(`wrote public/${file}`)
}
await browser.close()
