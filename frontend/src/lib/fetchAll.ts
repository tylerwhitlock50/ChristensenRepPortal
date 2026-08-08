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
 * Pass `{ count: 'exact' }` to .select() when you can: the reported total
 * lets a full final page finish without one extra empty-page round trip,
 * and it also keeps the loop correct if max-rows is ever set BELOW the
 * window size (a short page then no longer looks like the last one).
 */

/** One .range() window per request — matches Supabase's default max-rows. */
const PAGE_SIZE = 1000

interface PageResult<Row> {
  data: Row[] | null
  error: unknown
  count?: number | null
}

export async function fetchAllRows<Row>(
  page: (from: number, to: number) => PromiseLike<PageResult<Row>>,
): Promise<Row[]> {
  const rows: Row[] = []
  let total: number | null = null

  for (;;) {
    const from = rows.length
    const { data, error, count } = await page(from, from + PAGE_SIZE - 1)
    if (error) throw error

    const batch = data ?? []
    rows.push(...batch)
    if (typeof count === 'number') total = count

    if (batch.length === 0) return rows
    if (total != null) {
      if (rows.length >= total) return rows
    } else if (batch.length < PAGE_SIZE) {
      return rows
    }
  }
}
