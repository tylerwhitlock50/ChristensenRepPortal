/**
 * Unit tests for lib/fetchAll.ts — paging past PostgREST's max-rows.
 *
 * Run with:  npm run test:unit -- fetchAll
 *
 * The fake below behaves like a postgrest-js builder: lazy (nothing "runs"
 * until awaited), a Headers object carrying `Prefer: count=exact` when the
 * caller asked for a count, a server-side row cap, and a count that is only
 * returned when the request still asks for one. Asserted: every row comes
 * back once and in order, the count is requested once, windows after the
 * first overlap in time when the total is known, and the old sequential
 * walk still covers the no-count and short-window cases.
 */
import { fetchAllRows } from '../../src/lib/fetchAll'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

interface Source {
  rows: number[]
  cap: number
  /** Called with the window when a request "arrives"; may mutate rows. */
  onRequest?: (from: number) => void
}

function makeSource(src: Source, withCount: boolean) {
  const log = { requests: 0, counted: 0, inFlight: 0, maxInFlight: 0 }
  const page = (from: number, to: number) => {
    const headers = new Headers(withCount ? { Prefer: 'count=exact' } : {})
    return {
      headers,
      then<A, B>(
        onOk: (v: { data: number[]; error: null; count: number | null }) => A,
        onErr?: (e: unknown) => B,
      ) {
        log.requests++
        log.inFlight++
        log.maxInFlight = Math.max(log.maxInFlight, log.inFlight)
        src.onRequest?.(from)
        const counting = /count=exact/.test(headers.get('Prefer') ?? '')
        if (counting) log.counted++
        const end = Math.min(to + 1, from + src.cap)
        const result = {
          data: src.rows.slice(from, end),
          error: null,
          count: counting ? src.rows.length : null,
        }
        return new Promise((r) => setTimeout(r, 5))
          .then(() => {
            log.inFlight--
            return result
          })
          .then(onOk, onErr)
      },
    }
  }
  return { page, log }
}

const range = (n: number) => Array.from({ length: n }, (_, i) => i)
const inOrder = (rows: number[], n: number) =>
  rows.length === n && rows.every((v, i) => v === i)

/* --- small sets: one request, as before ---------------------------------- */
{
  const { page, log } = makeSource({ rows: range(42), cap: 1000 }, true)
  const rows = await fetchAllRows(page)
  t('a rep-sized book is one request', [rows.length, log.requests], [42, 1])
}
{
  const { page, log } = makeSource({ rows: [], cap: 1000 }, true)
  t('empty set', [(await fetchAllRows(page)).length, log.requests], [0, 1])
}
{
  const { page, log } = makeSource({ rows: range(1000), cap: 1000 }, true)
  t('exactly one full page with a count stops at once', [(await fetchAllRows(page)).length, log.requests], [1000, 1])
}

/* --- big sets with a count: parallel, counted once ----------------------- */
{
  const { page, log } = makeSource({ rows: range(20_689), cap: 1000 }, true)
  const rows = await fetchAllRows(page)
  t('admin book: every row once, in order', inOrder(rows, 20_689), true)
  t('admin book: 21 windows', log.requests, 21)
  t('admin book: counted on the first page only', log.counted, 1)
  t('admin book: up to four windows in flight', log.maxInFlight, 4)
}
{
  const { page, log } = makeSource({ rows: range(2_500), cap: 1000 }, true)
  const rows = await fetchAllRows(page)
  t('2,500 rows: in order', inOrder(rows, 2_500), true)
  t('2,500 rows: three requests', log.requests, 3)
}

/* --- server cap below the window ----------------------------------------- */
{
  const { page, log } = makeSource({ rows: range(2_300), cap: 500 }, true)
  const rows = await fetchAllRows(page)
  t('max-rows 500: every row once, in order', inOrder(rows, 2_300), true)
  t('max-rows 500: windows of 500', log.requests, 5)
}

/* --- no count: the old sequential walk ----------------------------------- */
{
  const { page, log } = makeSource({ rows: range(2_300), cap: 1000 }, false)
  const rows = await fetchAllRows(page)
  t('no count: every row once, in order', inOrder(rows, 2_300), true)
  t('no count: three sequential requests', [log.requests, log.maxInFlight], [3, 1])
}
{
  const { page, log } = makeSource({ rows: range(2_000), cap: 1000 }, false)
  const rows = await fetchAllRows(page)
  t('no count, exact multiple: one extra empty page', [rows.length, log.requests], [2_000, 3])
}

/* --- a window comes back short: fall back, never leave a gap ------------- */
{
  const src: Source = { rows: range(3_500), cap: 1000 }
  // Rows vanish just as the second window is read (e.g. a delete mid-walk).
  src.onRequest = (from) => {
    if (from === 1000 && src.rows.length === 3_500) src.rows = src.rows.slice(0, 1_400)
  }
  const { page } = makeSource(src, true)
  const rows = await fetchAllRows(page)
  t('short window: no duplicates', new Set(rows).size, rows.length)
  t('short window: still in order', rows.every((v, i) => i === 0 || v > rows[i - 1]), true)
  t('short window: ends at what exists', rows.length, 1_400)
}

/* --- errors -------------------------------------------------------------- */
{
  let calls = 0
  const boom = { code: '57014', message: 'canceling statement due to statement timeout' }
  const page = (from: number) => {
    calls++
    return Promise.resolve(
      from >= 2000
        ? { data: null, error: boom, count: null }
        : { data: range(1000), error: null, count: 5_000 },
    )
  }
  let thrown: unknown = null
  try {
    await fetchAllRows(page)
  } catch (e) {
    thrown = e
  }
  t('a failed window rejects with its error', thrown, boom)
  t('…after the first page plus at most one round of windows', calls <= 5, true)
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
