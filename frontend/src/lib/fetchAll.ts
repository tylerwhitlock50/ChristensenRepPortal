/**
 * PostgREST caps every response at the project's max-rows setting (1,000 on
 * a default Supabase project) no matter what .limit() asks for — a query
 * that "returns everything" silently returns the first thousand rows. Any
 * read that can exceed that (territory-wide intel, admin rollups) must page.
 *
 * fetchAllRows() walks .range() windows until the result set is complete.
 * The caller provides one page of the query for a given window; the query
 * MUST carry a deterministic, total ORDER BY (unique column or a tiebreaker
 * chain ending in one), otherwise rows can repeat or vanish across page
 * boundaries.
 *
 * Pass `{ count: 'exact' }` to .select() when you can. The total from the
 * first page lets the remaining windows go out side by side (PARALLEL at a
 * time) instead of one round trip after another, which is most of the wait
 * for an admin's 20-window book on LTE. It also keeps the walk correct if
 * max-rows is ever set BELOW the window size (a short page then no longer
 * looks like the last one). The count is asked for once: it is stripped from
 * every page after the first, so Postgres does not recount the whole
 * RLS-filtered set for each window.
 *
 * Without a count the walk is sequential, exactly as before.
 */

/** One .range() window per request — matches Supabase's default max-rows. */
const PAGE_SIZE = 1000
/** Windows in flight at once once the total is known. */
const PARALLEL = 4

interface PageResult<Row> {
  data: Row[] | null
  error: unknown
  count?: number | null
}

/** The bit of a postgrest-js builder this file touches: its request headers. */
interface WithHeaders {
  headers?: {
    get(name: string): string | null
    set(name: string, value: string): void
    delete(name: string): void
  }
}

/**
 * Drop `count=…` from a not-yet-sent builder's Prefer header. A builder is
 * lazy (nothing goes out until it is awaited), so this changes the request
 * itself. Anything that isn't a postgrest-js builder passes through as is.
 */
function withoutCount<T>(query: T): T {
  const headers = (query as WithHeaders | null)?.headers
  const prefer = typeof headers?.get === 'function' ? headers.get('Prefer') : null
  if (!headers || !prefer) return query
  const rest = prefer
    .split(',')
    .map((p) => p.trim())
    .filter((p) => p && !/^count=/i.test(p))
  if (rest.length) headers.set('Prefer', rest.join(','))
  else headers.delete('Prefer')
  return query
}

export async function fetchAllRows<Row>(
  page: (from: number, to: number) => PromiseLike<PageResult<Row>>,
): Promise<Row[]> {
  const first = await page(0, PAGE_SIZE - 1)
  if (first.error) throw first.error
  const rows: Row[] = [...(first.data ?? [])]
  const total = typeof first.count === 'number' ? first.count : null

  if (rows.length === 0) return rows
  if (total == null) {
    return rows.length < PAGE_SIZE ? rows : walk(page, rows, null)
  }
  if (rows.length >= total) return rows

  // The first page's length is the real window: a server capped below
  // PAGE_SIZE answers every window with that many rows.
  const window = rows.length
  const starts: number[] = []
  for (let from = window; from < total; from += window) starts.push(from)

  const results = new Array<PageResult<Row> | undefined>(starts.length)
  let next = 0
  let failed = false
  async function worker() {
    // After one window fails the whole read has failed: don't send the rest.
    while (!failed && next < starts.length) {
      const i = next++
      const from = starts[i]
      results[i] = await withoutCount(page(from, from + window - 1))
      if (results[i]!.error) {
        failed = true
        throw results[i]!.error
      }
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(PARALLEL, starts.length) }, worker),
  )

  // Stitch in order. A window that came back short (rows deleted between
  // requests, or a lower cap than the first page showed) leaves a gap in
  // everything after it, so those are dropped and the rest is walked one
  // page at a time from the first gap — slower, never wrong.
  for (let i = 0; i < starts.length; i++) {
    const batch = results[i]!.data ?? []
    rows.push(...batch)
    const expected = Math.min(window, total - starts[i])
    if (batch.length < expected) {
      return batch.length === 0 ? rows : walk(page, rows, total)
    }
  }
  return rows
}

/** The original one-window-at-a-time loop, continuing from `rows`. */
async function walk<Row>(
  page: (from: number, to: number) => PromiseLike<PageResult<Row>>,
  rows: Row[],
  total: number | null,
): Promise<Row[]> {
  for (;;) {
    const from = rows.length
    const { data, error } = await withoutCount(page(from, from + PAGE_SIZE - 1))
    if (error) throw error

    const batch = data ?? []
    rows.push(...batch)

    if (batch.length === 0) return rows
    if (total != null) {
      if (rows.length >= total) return rows
    } else if (batch.length < PAGE_SIZE) {
      return rows
    }
  }
}
