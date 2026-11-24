/**
 * The published Terms of Use and Privacy Policy
 * (supabase/migrations/20261124090100_legal_documents_v1.sql) render with the
 * portal's own Markdown subset exactly as written: every numbered section
 * heading survives, no paragraph is hard-wrapped (the renderer would turn the
 * wrap into a line break), no Markdown is left over as literal characters,
 * and links stay inside the portal or go to http(s).
 *
 * A new version gets the same checks by adding its file to FILES.
 *
 * Run with:  npm run test:unit -- legalDocuments
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderMarkdown } from '../../src/lib/markdown'

const here = dirname(fileURLToPath(import.meta.url))
const FILES = ['20261124090100_legal_documents_v1.sql']

let pass = 0
let fail = 0
function t(label: string, ok: boolean, detail = '') {
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}${detail ? `  ${detail}` : ''}`)
  }
}

/** The text between the next pair of $tag$ dollar quotes, from `from`. */
function quoted(sql: string, tag: string, from = 0): { text: string; end: number } | null {
  const mark = `$${tag}$`
  const open = sql.indexOf(mark, from)
  if (open < 0) return null
  const start = open + mark.length
  const close = sql.indexOf(mark, start)
  if (close < 0) return null
  return { text: sql.slice(start, close), end: close + mark.length }
}

const LEFTOVER = /\*\*|(^|\s)\*\S|`|^#{1,6}\s|\]\(/m

for (const file of FILES) {
  const sql = readFileSync(join(here, '..', '..', '..', 'supabase', 'migrations', file), 'utf8')
  let at = 0
  for (const key of ['terms', 'privacy']) {
    const title = quoted(sql, 'title', at)
    const summary = title ? quoted(sql, 'summary', title.end) : null
    const body = summary ? quoted(sql, key, summary.end) : null
    t(`${file} ${key}: title, summary and body are present`, !!(title && summary && body))
    if (!title || !summary || !body) continue
    at = body.end

    for (const [part, source] of [
      ['summary', summary.text],
      ['body', body.text],
    ] as const) {
      const html = renderMarkdown(source)
      const wrapped = html.split('\n').filter((l) => l.startsWith('<p>') && l.includes('<br>'))
      t(`${key} ${part}: no paragraph is hard-wrapped`, wrapped.length === 0, wrapped[0]?.slice(0, 80))
      const text = html.replace(/<[^>]+>/g, '')
      const left = LEFTOVER.exec(text)
      t(`${key} ${part}: no Markdown left over`, !left, left ? text.slice(Math.max(0, left.index - 30), left.index + 30) : '')
      const hrefs = [...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1])
      t(`${key} ${part}: links are http(s) or in the portal`, hrefs.every((h) => /^(https?:\/\/|\/)/.test(h)))
    }

    const sections = [...body.text.matchAll(/^## (\d+)\. /gm)].map((m) => Number(m[1]))
    t(
      `${key}: sections are numbered 1..N in order`,
      sections.length > 5 && sections.every((n, i) => n === i + 1),
      sections.join(','),
    )
    const html = renderMarkdown(body.text)
    t(`${key}: every section number shows in the rendered text`, sections.every((n) => html.includes(`<h3>${n}. `)))
    t(`${key}: no title line inside the body`, !/^# /m.test(body.text))
  }
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
