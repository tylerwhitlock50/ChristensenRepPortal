/**
 * Bundle budget — runs after every `npm run build` (the "postbuild" script),
 * so a Vercel build fails before a slower app reaches a rep's phone.
 *
 *   node scripts/check-bundle.mjs [distDir]
 *
 * Always prints what a cold open costs: the entry chunk, everything
 * index.html preloads with it (the JS that must arrive before anything
 * paints), the CSS, and the account page's own chunks on top of that. Fails
 * only when the ENTRY CHUNK, gzipped, is over ENTRY_BUDGET_KB — the number
 * that crept up unnoticed last time (an image compressor riding in via the
 * header badge). The other numbers are for reading, not for failing on.
 *
 * Sizes are gzip at zlib's default level, the same figure `vite build`
 * prints. Raising the budget is a deliberate one-line change here, with the
 * reason in the commit.
 */
import { readFileSync, readdirSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { gzipSync } from 'node:zlib'

/**
 * Measured 2026-10-13 at 37.8 kB after the speed work (it was 55.9 kB before
 * the image compressor left the entry), plus ~15% headroom.
 */
const ENTRY_BUDGET_KB = 43.5

const dist = resolve(process.argv[2] ?? 'dist')
const assets = join(dist, 'assets')
const html = readFileSync(join(dist, 'index.html'), 'utf8')

const kb = (bytes) => bytes / 1000
const fmt = (bytes) => `${kb(bytes).toFixed(2)} kB`
const gz = (file) => gzipSync(readFileSync(join(assets, file))).length

/** Static `import … from "./x.js"` / `import "./x.js"` edges of one chunk. */
function staticImports(file) {
  const code = readFileSync(join(assets, file), 'utf8')
  const out = new Set()
  const re = /(?:^|[;\n}])\s*import\s*(?:[\w$*{}\s,]+?\s*from\s*)?["']\.\/([^"']+\.js)["']/g
  for (let m; (m = re.exec(code)); ) out.add(m[1])
  return [...out]
}

/** A chunk plus everything it statically pulls in, minus `skip`. */
function closure(start, skip = new Set()) {
  const seen = new Set()
  const stack = [...start]
  while (stack.length) {
    const file = stack.pop()
    if (seen.has(file) || skip.has(file)) continue
    seen.add(file)
    stack.push(...staticImports(file))
  }
  return seen
}

const assetName = (href) => href.replace(/^\/?assets\//, '')
const entry = assetName(/<script[^>]*type="module"[^>]*src="([^"]+)"/.exec(html)?.[1] ?? '')
const preloads = [...html.matchAll(/<link[^>]*rel="modulepreload"[^>]*href="([^"]+)"/g)].map((m) =>
  assetName(m[1]),
)
const css = [...html.matchAll(/<link[^>]*rel="stylesheet"[^>]*href="(\/assets\/[^"]+)"/g)].map((m) =>
  assetName(m[1]),
)

if (!entry) {
  console.error('[bundle] no entry <script type="module"> in dist/index.html')
  process.exit(1)
}

const files = readdirSync(assets)
const entryClosure = closure([entry, ...preloads])
const entryGz = gz(entry)
const criticalGz = [...entryClosure].reduce((sum, f) => sum + gz(f), 0)
const cssGz = css.reduce((sum, f) => sum + gz(f), 0)

const rows = [
  ['entry chunk', entry, entryGz],
  ['critical-path JS', `${entryClosure.size} chunks`, criticalGz],
  ['entry CSS', css.join(', '), cssGz],
]
const accountView = files.find((f) => /^AccountView-.*\.js$/.test(f))
if (accountView) {
  const extra = closure([accountView], entryClosure)
  rows.push([
    'account page on top',
    `${accountView} + ${extra.size - 1} shared`,
    [...extra].reduce((sum, f) => sum + gz(f), 0),
  ])
}

console.log('\n[bundle] gzip sizes')
if (!process.env.VITE_SUPABASE_URL) {
  // lib/supabase.ts throws at load without it, so the build folds the
  // client away and the totals below come out ~50 kB light.
  console.log('  (VITE_SUPABASE_URL unset: supabase-js was dropped from this build, so\n' +
    '   the totals understate what a deploy ships; the entry chunk is unaffected)')
}
for (const [label, what, bytes] of rows) {
  console.log(`  ${label.padEnd(20)} ${fmt(bytes).padStart(10)}   ${what}`)
}

if (kb(entryGz) > ENTRY_BUDGET_KB) {
  console.error(
    `\n[bundle] entry chunk is ${fmt(entryGz)} gzip, over the ${ENTRY_BUDGET_KB} kB budget.\n` +
      '  Something heavy is being imported from the shell, the router or a store\n' +
      '  on every page load. Find it (npx vite-bundle-visualizer, or a sourcemap\n' +
      '  build) and import it where it is used, or raise ENTRY_BUDGET_KB in\n' +
      '  scripts/check-bundle.mjs on purpose.',
  )
  process.exit(1)
}
console.log(`  entry budget ${ENTRY_BUDGET_KB} kB: ok\n`)
