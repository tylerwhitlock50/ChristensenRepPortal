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
