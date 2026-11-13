/*============================================================================
  tools.test.ts — get_sales_summary: the summary's month arithmetic, and that
  it reads enough months whatever `months` asks for.

      deno test --allow-env supabase/functions/
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import type { McpCaller } from '../_shared/mcpAuth.ts'
import { SALES_SUMMARY_MONTHS, summariseSalesMonths, TOOLS_BY_NAME } from './tools.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function eq(got: unknown, want: unknown, what: string): void {
  assert(
    JSON.stringify(got) === JSON.stringify(want),
    `${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  )
}

/** 'yyyy-mm-01' for month `m` (0-based, may overflow) of year `y`. */
function monthStart(y: number, m: number): string {
  return new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 10)
}

/**
 * report_sales_by_month rows, oldest first, for the `count` months ending
 * with `now`'s month. Revenue depends only on the year, so every expected
 * figure below is a count of months times a round number.
 */
function salesRows(now: Date, count: number, revenueForYear: (y: number) => number) {
  const rows = []
  for (let back = count - 1; back >= 0; back--) {
    const month = monthStart(now.getUTCFullYear(), now.getUTCMonth() - back)
    rows.push({
      sales_month: month,
      revenue: revenueForYear(Number(month.slice(0, 4))),
      qty: 1,
      invoice_count: 1,
      account_count: 1,
    })
  }
  return rows
}

const byYear = (y: number) => ({ 2024: 50, 2025: 100, 2026: 200, 2027: 400 })[y] ?? 0

Deno.test('summary: mid-October, 25 months of rows', () => {
  const now = new Date(Date.UTC(2026, 9, 13))
  const s = summariseSalesMonths(salesRows(now, 25, byYear), now)
  eq(s.this_month, 200, 'this_month (Oct 2026)')
  eq(s.last_month, 200, 'last_month (Sep 2026)')
  eq(s.same_month_last_year, 100, 'same_month_last_year (Oct 2025)')
  eq(s.this_month_vs_last_year_pct, 100, 'this month vs last year')
  eq(s.quarter_to_date, 200, 'QTD (Oct)')
  eq(s.quarter_to_date_last_year, 100, 'QTD last year')
  eq(s.year_to_date, 2000, 'YTD (Jan-Oct 2026)')
  eq(s.year_to_date_last_year, 1000, 'YTD last year (Jan-Oct 2025)')
  eq(s.ytd_vs_last_year_pct, 100, 'YTD vs last year')
})

Deno.test('summary: the bug — 13 months of rows make last year one month', () => {
  // What get_sales_summary(months=13) used to sum: Oct 2025 alone.
  const now = new Date(Date.UTC(2026, 9, 13))
  const s = summariseSalesMonths(salesRows(now, 13, byYear), now)
  eq(s.year_to_date_last_year, 100, 'thirteen months: last year is October only')
  eq(s.ytd_vs_last_year_pct, 1900, 'and the comparison is nonsense')
})

Deno.test('summary: December needs 24 months, inside SALES_SUMMARY_MONTHS', () => {
  const now = new Date(Date.UTC(2026, 11, 20))
  assert(SALES_SUMMARY_MONTHS >= 24, 'reads at least Jan last year .. Dec this year')
  const s = summariseSalesMonths(salesRows(now, SALES_SUMMARY_MONTHS, byYear), now)
  eq(s.year_to_date, 2400, 'YTD: twelve months of 2026')
  eq(s.year_to_date_last_year, 1200, 'YTD last year: all twelve months of 2025')
  eq(s.quarter_to_date, 600, 'QTD: Oct-Dec')
  eq(s.quarter_to_date_last_year, 300, 'QTD last year')
})

Deno.test('summary: January looks back across the year boundary', () => {
  const now = new Date(Date.UTC(2027, 0, 5))
  const s = summariseSalesMonths(salesRows(now, 25, byYear), now)
  eq(s.this_month, 400, 'this_month (Jan 2027)')
  eq(s.last_month, 200, 'last_month (Dec 2026)')
  eq(s.year_to_date, 400, 'YTD: January only')
  eq(s.year_to_date_last_year, 200, 'YTD last year: January 2026')
})

Deno.test('summary: months with no invoices are absent, not zero', () => {
  const now = new Date(Date.UTC(2026, 9, 13))
  const rows = salesRows(now, 25, byYear).filter(
    (r) => !['2026-10', '2025-10', '2025-09'].includes(r.sales_month.slice(0, 7)),
  )
  const s = summariseSalesMonths(rows, now)
  eq(s.this_month, null, 'no invoices this month yet')
  eq(s.this_month_vs_last_year_pct, null, 'no comparison without both months')
  eq(s.quarter_to_date, null, 'QTD with no month in it')
  eq(s.year_to_date_last_year, 800, 'last-year YTD skips the two empty months')
})

/* --- the handler: what it asks for, and what it returns ------------------- */

/**
 * A db whose report_sales_by_month answers like the SQL function: the
 * `p_months` months ending with the current month, out of 48 months of data.
 */
function fakeDb(now: Date) {
  const calls: Record<string, unknown>[] = []
  const all = salesRows(now, 48, (y) => y)
  const db = {
    rpc(name: string, params: Record<string, unknown>) {
      assert(name === 'report_sales_by_month', `rpc name ${name}`)
      calls.push(params)
      const p = Math.min(Math.max(Number(params.p_months), 1), 48)
      const since = monthStart(now.getUTCFullYear(), now.getUTCMonth() - (p - 1))
      return Promise.resolve({ data: all.filter((r) => r.sales_month >= since), error: null })
    },
  }
  return { db: db as unknown as SupabaseClient, calls }
}

const caller = {} as unknown as McpCaller
const tool = TOOLS_BY_NAME.get('get_sales_summary')!

type SummaryResult = {
  months_requested: number
  summary: Record<string, unknown>
  months: { month: string; revenue: number }[]
}

Deno.test('handler: months=13 still reads 25 and returns 13', async () => {
  const now = new Date()
  const { db, calls } = fakeDb(now)
  const res = (await tool.handler({ months: 13 }, { db, caller })) as SummaryResult
  eq(calls.map((c) => c.p_months), [SALES_SUMMARY_MONTHS], 'p_months')
  eq(res.months_requested, 13, 'months_requested')
  eq(res.months.length, 13, 'series length')
  eq(res.months[0].month, monthStart(now.getUTCFullYear(), now.getUTCMonth() - 12).slice(0, 7), 'oldest month')
  eq(res.months[12].month, monthStart(now.getUTCFullYear(), now.getUTCMonth()).slice(0, 7), 'newest month')

  // Revenue is the year number, so last year's YTD is (month+1) × (year-1).
  const y = now.getUTCFullYear()
  const m = now.getUTCMonth()
  eq(res.summary.year_to_date_last_year, (m + 1) * (y - 1), 'YTD last year spans Jan..this month')
  eq(res.summary.year_to_date, (m + 1) * y, 'YTD')

  // Same summary as the default call.
  const { db: db25 } = fakeDb(now)
  const full = (await tool.handler({}, { db: db25, caller })) as SummaryResult
  eq(res.summary, full.summary, 'summary does not depend on months')
})

Deno.test('handler: months=1 returns one month', async () => {
  const now = new Date()
  const { db, calls } = fakeDb(now)
  const res = (await tool.handler({ months: 1 }, { db, caller })) as SummaryResult
  eq(calls.map((c) => c.p_months), [SALES_SUMMARY_MONTHS], 'p_months')
  eq(res.months.map((r) => r.month), [monthStart(now.getUTCFullYear(), now.getUTCMonth()).slice(0, 7)], 'series')
})

Deno.test('handler: 25 and more read and return exactly what was asked', async () => {
  for (const months of [25, 36, 48]) {
    const now = new Date()
    const { db, calls } = fakeDb(now)
    const res = (await tool.handler({ months }, { db, caller })) as SummaryResult
    eq(calls.map((c) => c.p_months), [months], `p_months for ${months}`)
    eq(res.months.length, months, `series length for ${months}`)
  }
})

/* --- whoami: capabilities for order drafting ------------------------------ */

function whoamiDb() {
  const b: Record<string, unknown> = {
    select: () => b,
    eq: () => b,
    is: () => b,
    maybeSingle: () => Promise.resolve({ data: { data_through: '2026-11-10' }, error: null }),
    then: (ok: (v: unknown) => unknown) => Promise.resolve({ data: null, error: null, count: 3 }).then(ok),
  }
  return { from: () => b } as unknown as SupabaseClient
}

Deno.test('whoami: capabilities report the order-drafting gate', async () => {
  const who = TOOLS_BY_NAME.get('whoami')!
  const me = { fullName: 'Pilot', role: 'admin' } as unknown as McpCaller

  const off = (await who.handler({}, { db: whoamiDb(), caller: me })) as { capabilities: Record<string, unknown> }
  eq(off.capabilities.mcp_orders, false, 'no access info → off')
  assert(!('write_scope_active' in off.capabilities), 'no write_scope_active any more')

  const on = (await who.handler({}, {
    db: whoamiDb(),
    caller: me,
    orders: { mcp_orders: true, order_tools_listed: true, reason: null },
  })) as { capabilities: Record<string, unknown> }
  eq(on.capabilities.mcp_orders, true, 'on')
  assert(/never submit/.test(String(on.capabilities.order_drafting)), 'says it never submits')
  assert(/submits them in the portal/.test(String(on.capabilities.order_drafting)), 'says who submits')

  const url = (await who.handler({}, {
    db: whoamiDb(),
    caller: me,
    orders: { mcp_orders: false, order_tools_listed: false, reason: 'not on the list' },
  })) as { capabilities: Record<string, unknown> }
  eq(url.capabilities.order_drafting_off_because, 'not on the list', 'reason passed through')
})

Deno.test('whoami: inside sales is told they may price and submit their own drafts', async () => {
  const who = TOOLS_BY_NAME.get('whoami')!
  const inside = { fullName: 'Inside', role: 'rep', realRole: 'order_entry' } as unknown as McpCaller
  const res = (await who.handler({}, { db: whoamiDb(), caller: inside })) as { user: { role: string }; access_note: string }
  eq(res.user.role, 'inside_sales', 'role label')
  assert(/every account/.test(res.access_note) && /read-only/.test(res.access_note), 'reads everything, changes nothing')
  assert(/prices/.test(res.access_note) && /your own drafts/.test(res.access_note), 'may set PO prices on own drafts')
  assert(/an admin submits anyone's/.test(res.access_note), 'D1')
})

/* --- lookup_order: exact hits first ------------------------------------- */

function lookupDb(rows: Record<string, unknown>[]) {
  const calls: Record<string, unknown>[] = []
  const db = {
    rpc: (_name: string, params: Record<string, unknown>) => {
      calls.push(params)
      return Promise.resolve({ data: rows, error: null })
    },
  } as unknown as SupabaseClient
  return { db, calls }
}

Deno.test('lookup_order: the exact order or PO comes first, marked, from the full page', async () => {
  const lookup = TOOLS_BY_NAME.get('lookup_order')!
  // Newest first, as lookup_orders returns them: two newer orders merely
  // contain "PORTAL-12"; the exact one is older.
  const rows = [
    { order_id: 'CO-9001', customer_po_number: 'PORTAL-1245', order_date: '2026-11-10', matched_on: 'po' },
    { order_id: 'CO-9000', customer_po_number: 'PORTAL-123', order_date: '2026-11-09', matched_on: 'po' },
    { order_id: 'CO-8000', customer_po_number: 'PO-77, portal-12', order_date: '2026-10-01', matched_on: 'po' },
  ]
  const { db, calls } = lookupDb(rows)
  const res = (await lookup.handler({ term: 'PORTAL-12', limit: 2 }, { db, caller })) as {
    orders: Record<string, unknown>[]
    exact_matches: number
    has_more: boolean
    note?: string
  }
  eq(calls[0], { p_term: 'PORTAL-12', p_limit: 100 }, 'read at the RPC cap, not at limit')
  eq(res.orders.map((o) => o.order_id), ['CO-8000', 'CO-9001'], 'exact first, then newest; cut to limit')
  eq([res.orders[0].exact, res.orders[1].exact], [true, undefined], 'only the exact row is marked')
  eq([res.exact_matches, res.has_more], [1, true], 'counts')
  assert(/exact: true/.test(String(res.note)), 'the note says which row is the number itself')

  const byOrder = lookupDb([
    { order_id: 'CO-77120', customer_po_number: 'X', matched_on: 'order' },
    { order_id: 'co-7712', customer_po_number: 'Y', matched_on: 'order' },
  ])
  const r2 = (await lookup.handler({ term: ' CO-7712 ' }, { db: byOrder.db, caller })) as { orders: Record<string, unknown>[] }
  eq(r2.orders.map((o) => [o.order_id, o.exact ?? false]), [['co-7712', true], ['CO-77120', false]], 'order id, any case')

  const none = lookupDb([])
  const r3 = (await lookup.handler({ term: 'nope' }, { db: none.db, caller })) as { matched: number; note: string }
  eq(r3.matched, 0, 'nothing')
  assert(/No order in your book matches/.test(r3.note), 'says so')
})

/* --- list_orders: an order's lines are paged ---------------------------- */

function linesDb(total: number) {
  const ranges: [number, number][] = []
  const orders: unknown[] = []
  const all = Array.from({ length: total }, (_, i) => ({
    line_num: i + 1, order_date: '2026-11-03', promise_date: '2026-12-01', part_id: `P-${i + 1}`, order_qty: 2,
  }))
  const db = {
    from() {
      let from = 0
      let to = total - 1
      let counted = false
      const b: Record<string, unknown> = {
        select: (_c: string, opts?: { count?: string }) => ((counted = opts?.count === 'exact'), b),
        eq: () => b,
        order: (...a: unknown[]) => (orders.push(a), b),
        range: (f: number, t: number) => (ranges.push([f, t]), (from = f), (to = t), b),
        then: (ok: (v: unknown) => unknown) =>
          Promise.resolve({ data: all.slice(from, to + 1), error: null, count: counted ? total : null }).then(ok),
      }
      return b
    },
  } as unknown as SupabaseClient
  return { db, ranges, orders }
}

type LinesResult = {
  order_id: string; order_date?: string; line_count: number; offset: number; returned: number
  has_more: boolean; next_offset?: number; lines: Record<string, unknown>[]
}

Deno.test('list_orders: the order_id drill-down honours limit / offset, has_more, order_date once', async () => {
  const list = TOOLS_BY_NAME.get('list_orders')!
  const a = linesDb(194)
  const r1 = (await list.handler({ customer_key: 'SPOR SOU1', order_id: 'EDI-00959', limit: 50 }, { db: a.db, caller })) as LinesResult
  eq(a.ranges, [[0, 49]], 'range 0-49')
  eq([r1.returned, r1.line_count, r1.has_more, r1.next_offset, r1.order_date], [50, 194, true, 50, '2026-11-03'], 'first page')
  assert(r1.lines.every((l) => !('order_id' in l) && !('order_date' in l)), 'order_id / order_date sent once')
  eq(a.orders, [['line_num', { ascending: true }], ['part_id', { ascending: true }]], 'stable order')

  const b = linesDb(194)
  const r2 = (await list.handler({ customer_key: 'SPOR SOU1', order_id: 'EDI-00959', limit: 50, offset: 150 }, { db: b.db, caller })) as LinesResult
  eq([r2.returned, r2.has_more, 'next_offset' in r2, r2.offset], [44, false, false, 150], 'last page')

  const c = linesDb(194)
  await list.handler({ customer_key: 'SPOR SOU1', order_id: 'EDI-00959' }, { db: c.db, caller })
  eq(c.ranges, [[0, 49]], 'no limit: 50 lines')
  const d = linesDb(194)
  await list.handler({ customer_key: 'SPOR SOU1', order_id: 'EDI-00959', limit: 500 }, { db: d.db, caller })
  eq(d.ranges, [[0, 99]], 'capped at 100')
})
