/**
 * Runs every tests/unit/*.test.ts under vite-node, one file at a time.
 *
 *   npm run test:unit                 all of them
 *   npm run test:unit -- contacts     only files whose name contains "contacts"
 *
 * Replaces the old `vite-node a && vite-node b && …` chain in package.json, so
 * a new test file is picked up by dropping it in this directory — nobody edits
 * the script line, and two branches adding tests don't conflict there.
 *
 * Each test file is still a plain script that exits non-zero on failure (see
 * ffl.test.ts for the harness). This runs them all even when one fails, prints
 * a result per file, and exits non-zero if any failed.
 *
 * Several tests import lib/supabase.ts transitively, which throws at module
 * load without a URL and key. Nothing here talks to Supabase, so placeholders
 * are set when the environment doesn't already provide them.
 */
import { spawnSync } from 'node:child_process'
import { readdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..', '..')
const isWindows = process.platform === 'win32'

// npm puts a .cmd shim next to the POSIX one on Windows. Node refuses to spawn
// a .cmd without a shell (CVE-2024-27980), hence shell: true there and only
// there — and the quoting that a shell then needs.
const bin = join(root, 'node_modules', '.bin', isWindows ? 'vite-node.cmd' : 'vite-node')
const quote = (s) => (isWindows ? `"${s}"` : s)

const filters = process.argv.slice(2)
const files = readdirSync(here)
  .filter((f) => f.endsWith('.test.ts'))
  .filter((f) => filters.length === 0 || filters.some((x) => f.includes(x)))
  .sort()

if (files.length === 0) {
  console.error(`No tests/unit/*.test.ts matched ${filters.join(' ') || '(none found)'}`)
  process.exit(1)
}

const env = {
  ...process.env,
  VITE_SUPABASE_URL: process.env.VITE_SUPABASE_URL || 'https://example.supabase.co',
  VITE_SUPABASE_PUBLISHABLE_KEY: process.env.VITE_SUPABASE_PUBLISHABLE_KEY || 'placeholder',
}

const results = []
for (const file of files) {
  const path = join(here, file)
  console.log(`\n=== ${relative(root, path)}`)
  const r = spawnSync(quote(bin), [quote(path)], {
    cwd: root,
    env,
    stdio: 'inherit',
    shell: isWindows,
  })
  const ok = r.status === 0 && !r.error
  if (r.error) console.error(r.error.message)
  results.push({ file, ok })
}

console.log('\n--- unit test files')
for (const { file, ok } of results) console.log(`${ok ? 'PASS' : 'FAIL'}  ${file}`)
const failed = results.filter((r) => !r.ok).length
console.log(`${results.length - failed} passed, ${failed} failed`)
if (failed > 0) process.exit(1)
