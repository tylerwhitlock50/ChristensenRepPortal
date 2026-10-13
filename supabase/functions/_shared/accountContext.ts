/*============================================================================
  _shared/accountContext.ts

  The account context payload, and the hashing that decides whether it is
  worth paying to regenerate.

  Extracted from ai-account-summary/index.ts verbatim when the nightly batch
  arrived. Two callers now build this context — a rep pressing "Summarize"
  and a scheduled job — and if they ever built it differently the context
  hash would stop meaning anything: the same account would look "changed" to
  one path and unchanged to the other, and the cache would thrash while
  producing summaries that disagree.

  buildContext() already took its client as the first argument, so this was a
  move rather than a rewrite. That is the whole point: the two paths differ in
  exactly one expression — which SupabaseClient they pass — and nothing else.
  It also means every read below must answer the SAME for the account's rep
  and for service_role: security_invoker views and invoker RPCs over
  account-scoped RLS (service_role bypasses it, the rep passes it). Never a
  definer function gated on has_account_access() — that returns nothing to
  service_role, and every account would hash "changed" after each batch run
  (supabase/tests/20261013_intel_ai.sql pins the parity).

  On PII (TECH_STACK §5.1): the context deliberately excludes public.contacts
  entirely and carries no author identity on notes, visits or actions. Keep it
  that way. A revenue trend does not need to know who the buyer is.

  ── Hashed vs "as of today" (prompt v4) ────────────────────────────────────
  Two outputs, and the split is the cache:

    context   what the hash covers. Data only: raw dates, never day counts,
              and every query window anchored to a month boundary, so the
              same data on another day of the same month hashes the same.
    asOf      day counts and anything else that moves with the clock
              (goal pace, revenue for the same window last year). Added to
              the model's input by promptPayload(), never hashed.

  Before v4 days_since_last_order sat inside the hash, so every account
  looked "changed" every morning: the batch paid for every target every
  night and a rep's Summarize never hit the cache on a new day. The prompt
  now writes dates rather than day counts, so a cached brief does not go
  stale by sitting. accountContext.test.ts proves the hash holds across days.

  ── Where the numbers come from (v4) ───────────────────────────────────────
    open order value / late      erp.agg_account_rollup (exact, nightly) —
                                 not a sum over 400 capped order lines
    orders, cadence              v_account_recent_order_headers: one row per
                                 ORDER, so a big dealer's lines do not crowd
                                 out its order history
    product mix                  report_account_family_mix(): the same
                                 months of both years, not YTD vs all of
                                 last year
    goal                         v_account_goal_progress (portal goal wins,
                                 ERP fallback) — what the goal panel shows
    in-stock reorders, backlog   report_reorder_candidates(),
    lines, resolved outcomes     v_backlog_by_sku, recommendations
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { HttpError } from './supabase.ts'
import { isMissingRelation } from './ai.ts'

export const MONTHS_OF_HISTORY = 24
export const RECENT_ORDERS = 5
export const RECENT_NOTES = 5
/** Orders read for cadence: this month and the twelve before it. */
export const ORDER_WINDOW_MONTHS = 12
/** In-stock reorders and backlog lines the brief can name. */
export const TOP_REORDERS = 5
export const TOP_BACKLOG_LINES = 5
/** Resolved recommendations from this month and the six before it. */
export const RESOLVED_MONTHS = 6
/** Same-window revenue last year above which a family at $0 now is "stopped". */
export const STOPPED_FAMILY_MIN = 2_000

/*----------------------------------------------------------------------------
  Small helpers
----------------------------------------------------------------------------*/

/**
 * The generated Database type does not describe `erp`, and Deno does not
 * typecheck on deploy — cast once here rather than at every call site.
 */
// deno-lint-ignore no-explicit-any
export function erp(client: SupabaseClient): any {
  // deno-lint-ignore no-explicit-any
  return (client as any).schema('erp')
}

export function round(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value ?? 0)
  return Number.isFinite(n) ? Math.round(n) : 0
}

export function isoDaysAgo(days: number): string {
  const d = new Date()
  d.setUTCDate(d.getUTCDate() - days)
  return d.toISOString().slice(0, 10)
}

export function monthKey(isoDate: string): string {
  return isoDate.slice(0, 7)
}

/**
 * First day of the month `monthsBack` months before `today`'s, as
 * YYYY-MM-DD. Every window in the context starts on one of these, so a
 * window only moves when the month does.
 */
export function monthStart(today: Date, monthsBack = 0): string {
  return new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() - monthsBack, 1))
    .toISOString()
    .slice(0, 10)
}

/** Whole days from an ISO date to `today`; null for no date. */
export function daysSince(isoDate: string | null | undefined, today: Date): number | null {
  if (!isoDate) return null
  const then = Date.parse(String(isoDate).slice(0, 10) + 'T00:00:00Z')
  if (!Number.isFinite(then)) return null
  const now = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
  return Math.round((now - then) / 86_400_000)
}

/** Deterministic key order, so an unchanged account always hashes the same. */
export function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    const source = value as Record<string, unknown>
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(source).sort()) out[key] = canonical(source[key])
    return out
  }
  return value
}

export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

function contextUnavailable(): HttpError {
  return new HttpError(
    503,
    'context_unavailable',
    'Could not read the account data behind this summary. Try again in a moment.',
  )
}

/**
 * Tolerant ONLY of a relation that is not migrated yet (a stable absence —
 * it hashes the same every time, and the prompt tolerates absent fields).
 * Every other error THROWS: this context feeds the hash that decides
 * whether a regenerate is paid or cached, and a slice that vanishes on a
 * statement timeout makes the same unchanged account look "changed".
 */
// deno-lint-ignore no-explicit-any
export function rows(result: { data: any; error: any }, label: string): any[] {
  if (result.error) {
    if (isMissingRelation(result.error)) {
      console.warn(`context relation not deployed yet: ${label}`, result.error)
      return []
    }
    console.error(`context query failed: ${label}`, result.error)
    throw contextUnavailable()
  }
  const data = result.data
  if (Array.isArray(data)) return data
  return data ? [data] : []
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>

/*----------------------------------------------------------------------------
  Revenue series
----------------------------------------------------------------------------*/

export type MonthlyRevenue = { month: string; revenue: number }

/**
 * Reads the nightly (customer, month) rollup, erp.agg_customer_month
 * (20260817160000) — the source of public.v_account_revenue_monthly since
 * 20261013110000, with the same memo filter. Read directly rather than
 * through that view because the view stops at 24 months (this one and 23
 * before) and this needs 25: MONTHS_OF_HISTORY whole months plus this one,
 * so summariseRevenue() can compare the last twelve COMPLETE months with
 * the twelve before them (the model is shown the newest MONTHS_OF_HISTORY
 * of them, see assembleContext). RLS on the rollup is "read own
 * agg_customer_month" (is_admin() or my_customer_keys()); service_role
 * bypasses it — the same rows for the batch and the rep, as the hash needs.
 *
 * If the rollup is not there (a database older than 20260817160000) it
 * falls back to this ONE customer's invoice lines, bucketed here: a
 * single-customer, index-backed, date-bounded read on the server. Only a
 * missing relation falls back; any other error (a timeout, a permission
 * problem) throws like every other context read — the fallback is a
 * different computation, and a hash built on it for one request would look
 * "changed" and pay for a regeneration.
 *
 * The window starts on a month boundary, so it does not shift under an
 * unchanged account from one day to the next.
 */
export async function fetchRevenueByMonth(
  client: SupabaseClient,
  customerKey: string,
  today = new Date(),
): Promise<{ series: MonthlyRevenue[]; source: 'rollup' | 'fact_lines' }> {
  const since = monthStart(today, MONTHS_OF_HISTORY)

  const viaRollup = await erp(client)
    .from('agg_customer_month')
    .select('sales_month, revenue')
    .eq('customer_key', customerKey)
    .gte('sales_month', since)
    .order('sales_month', { ascending: true })
    .limit(MONTHS_OF_HISTORY + 1)

  if (viaRollup.error && !isMissingRelation(viaRollup.error)) {
    console.error('context query failed: agg_customer_month', viaRollup.error)
    throw contextUnavailable()
  }

  if (!viaRollup.error && viaRollup.data) {
    return {
      series: (viaRollup.data as Array<Record<string, unknown>>).map((r) => ({
        month: String(r.sales_month ?? '').slice(0, 7),
        revenue: round(r.revenue),
      })),
      source: 'rollup',
    }
  }

  // Memo lines out, as the rollup leaves them.
  const viaFacts = await erp(client)
    .from('fact_invoice_line')
    .select('invoice_date, revenue')
    .eq('customer_key', customerKey)
    .gte('invoice_date', since)
    .not('is_memo', 'is', true)
    .order('invoice_date', { ascending: true })
    .limit(10_000)

  const buckets = new Map<string, number>()
  for (const row of rows(viaFacts, 'fact_invoice_line/revenue')) {
    const date = row.invoice_date as string | null
    if (!date) continue
    const key = monthKey(date)
    buckets.set(key, (buckets.get(key) ?? 0) + Number(row.revenue ?? 0))
  }

  const series = Array.from(buckets.entries())
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .slice(-(MONTHS_OF_HISTORY + 1))
    .map(([month, revenue]) => ({ month, revenue: round(revenue) }))

  return { series, source: 'fact_lines' }
}

/**
 * Align by CALENDAR month, never by array position.
 *
 * The monthly rollup (like v_account_revenue_monthly over it) omits months
 * with no invoices, so the series is sparse. Slicing it by index
 * silently redefines the windows: a seasonal dealer invoicing in 8 of the last
 * 24 months has all 8 rows counted as "trailing 12 months" and an empty prior
 * window, so prior_12m_revenue is 0 and change_pct is null. With 18 present
 * months it reports a large fake swing on a flat account.
 *
 * prompt.ts tells the model these fields are literally the twelve months
 * through `through_month` and the twelve before that, so a wrong number here
 * becomes a confident false statement in a rep's briefing.
 *
 * WHOLE months only: the current month is still being invoiced, so a
 * window that included it compared eleven and a bit months with twelve and
 * read every flat account as down (by up to a twelfth early in the month).
 * The windows end at last month; they still move once a month, not daily.
 */
export function summariseRevenue(series: MonthlyRevenue[], today = new Date()) {
  const byMonth = new Map(series.map((r) => [r.month.slice(0, 7), r.revenue]))

  // 24 calendar-month keys ending with LAST month, newest first.
  const monthKeys: string[] = []
  const cursor = new Date(
    Date.UTC(today.getUTCFullYear(), today.getUTCMonth() - 1, 1),
  )
  for (let i = 0; i < 24; i++) {
    monthKeys.push(cursor.toISOString().slice(0, 7))
    cursor.setUTCMonth(cursor.getUTCMonth() - 1)
  }

  const sumWindow = (keys: string[]) =>
    round(keys.reduce((acc, k) => acc + (byMonth.get(k) ?? 0), 0))

  const trailing = sumWindow(monthKeys.slice(0, 12))
  const prior = sumWindow(monthKeys.slice(12, 24))
  const changePct =
    prior > 0 ? Math.round(((trailing - prior) / prior) * 100) : null

  return {
    through_month: monthKeys[0],
    trailing_12m_revenue: trailing,
    prior_12m_revenue: prior,
    change_pct: changePct,
    months_with_revenue: monthKeys.filter((k) => (byMonth.get(k) ?? 0) > 0).length,
  }
}

/** Median of a non-empty number array; 0 for empty. */
function median(values: number[]): number {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
]

/**
 * The buying-pattern block: cadence, typical order size, and the calendar
 * months this account historically buys in. Pure derivation over data the
 * context already fetched — no extra queries here, and no day counts: how
 * long ago the last order was is an as-of-today figure (see header).
 */
function summariseBuyingPatterns(
  orders: Array<{ date: string | null; amount: number }>,
  series: MonthlyRevenue[],
) {
  // Cadence: gaps between DISTINCT order dates, oldest→newest. Same-day
  // orders are one buying event as far as cadence is concerned.
  const dates = [...new Set(orders.map((o) => o.date).filter((d): d is string => !!d))].sort()
  const gaps: number[] = []
  for (let i = 1; i < dates.length; i++) {
    const days = Math.round(
      (new Date(dates[i]).getTime() - new Date(dates[i - 1]).getTime()) / 86_400_000,
    )
    if (days > 0) gaps.push(days)
  }

  // Seasonality: revenue share by calendar month across the 24-month series.
  const byCalMonth = new Array<number>(12).fill(0)
  let total = 0
  for (const r of series) {
    const m = Number(r.month.slice(5, 7)) - 1
    if (m >= 0 && m < 12) {
      byCalMonth[m] += r.revenue
      total += r.revenue
    }
  }
  const peakMonths =
    total > 0
      ? byCalMonth
          .map((rev, i) => ({ month: MONTH_NAMES[i], share: rev / total }))
          .filter((m) => m.share >= 0.15)
          .sort((a, b) => b.share - a.share)
          .slice(0, 3)
          .map((m) => m.month)
      : []

  return {
    order_days_in_window: dates.length,
    median_days_between_orders: gaps.length >= 2 ? round(median(gaps)) : null,
    median_order_amount: round(median(orders.map((o) => o.amount).filter((a) => a > 0))),
    peak_buying_months: peakMonths,
  }
}

/**
 * Product mix by family over the SAME months of both years, from
 * report_account_family_mix(). "Stopped" is decided here, deterministically,
 * so the model never infers it from two numbers it might misread: a family
 * is stopped only when it had real revenue in last year's window, none in
 * this year's, and none since the window closed — the window ends at the
 * last complete month, so without `revenue_after_period` a family bought
 * last week read as stopped.
 */
export function summariseMix(mixRows: Row[]) {
  if (mixRows.length === 0) return null
  const first = mixRows[0]
  // Not part of the comparison (and not in the context): only the stopped
  // test reads it. Absent on an earlier draft of 20261013140002 → 0.
  const boughtSince = new Map<string, number>(
    mixRows.map((r) => [
      String(r.product_family ?? '').trim() || '(none)',
      Number(r.revenue_after_period ?? 0),
    ]),
  )
  const families = mixRows
    .map((r) => ({
      family: String(r.product_family ?? '').trim() || '(none)',
      revenue_this_period: round(r.revenue),
      revenue_same_period_last_year: round(r.prior_revenue),
      units_this_period: round(r.qty),
      units_same_period_last_year: round(r.prior_qty),
    }))
    .sort(
      (a, b) =>
        Math.max(b.revenue_this_period, b.revenue_same_period_last_year) -
          Math.max(a.revenue_this_period, a.revenue_same_period_last_year) ||
        a.family.localeCompare(b.family),
    )
  const ym = (v: unknown) => String(v ?? '').slice(0, 7) || null
  return {
    this_period: { from: ym(first.period_start), through: ym(first.period_end) },
    same_period_last_year: { from: ym(first.prior_start), through: ym(first.prior_end) },
    families: families.slice(0, 8),
    stopped_families: families
      .filter((f) => f.revenue_same_period_last_year >= STOPPED_FAMILY_MIN && f.revenue_this_period <= 0)
      .filter((f) => !((boughtSince.get(f.family) ?? 0) > 0))
      .map((f) => f.family),
    new_families: families
      .filter((f) => f.revenue_this_period >= STOPPED_FAMILY_MIN && f.revenue_same_period_last_year <= 0)
      .map((f) => f.family),
  }
}

/*----------------------------------------------------------------------------
  Context assembly — fixed queries, all filtered by customer_key (indexed).

  Every erp filter carries `customer_key` because an unfiltered fact-table scan
  costs ~756ms once the RLS predicate defeats the index (migration 010).
----------------------------------------------------------------------------*/

/** Everything buildContext reads, before any derivation. */
export type ContextInputs = {
  customer: Row
  invoiceLineCount: number
  revenue: { series: MonthlyRevenue[]; source: 'rollup' | 'fact_lines' }
  /** One row per order, newest first: order_id, order_date, bookings. */
  orders: Row[]
  /** First day of the orders window. */
  ordersSince: string
  /** erp.agg_account_rollup, or null when the account has no row. */
  rollup: Row | null
  /** v_account_goal_progress for the current year, or null. */
  goal: Row | null
  backlog: Row[]
  reorders: Row[]
  mix: Row[]
  openRecs: Row[]
  resolvedRecs: Row[]
  notes: Row[]
  visit: Row | null
  actions: Row[]
  lastShipDate: string | null
}

export async function fetchContextInputs(
  client: SupabaseClient,
  customerKey: string,
  today = new Date(),
): Promise<ContextInputs> {
  const ordersSince = monthStart(today, ORDER_WINDOW_MONTHS)
  const resolvedSince = monthStart(today, RESOLVED_MONTHS)
  // The last COMPLETE month: comparing a partial month with a whole one
  // reads as a decline every month until the 31st.
  const mixThrough = monthStart(today, 1)
  const yearNow = today.getUTCFullYear()

  const [
    customerRes,
    invoiceCountRes,
    revenue,
    orderRes,
    rollupRes,
    goalRes,
    backlogRes,
    reorderRes,
    mixRes,
    shipmentRes,
    recRes,
    resolvedRes,
    noteRes,
    visitRes,
    actionRes,
  ] = await Promise.all([
    erp(client)
      .from('dim_customer')
      .select(
        'customer_key, customer_name, sold_to_city, sold_to_state, ' +
          'assigned_sales_rep_name, customer_type, territory, active_flag, ' +
          'account_open_date, last_order_date, yearly_sales_goal',
      )
      .eq('customer_key', customerKey)
      .maybeSingle(),

    // Lifetime line count — the graceful-degradation gate (see below).
    erp(client)
      .from('fact_invoice_line')
      .select('invoice_id', { count: 'exact', head: true })
      .eq('customer_key', customerKey),

    fetchRevenueByMonth(client, customerKey, today),

    // One row per ORDER (018/035), so 400 is 400 orders — not 400 lines,
    // which a big dealer used to fill with a few weeks of history.
    client
      .from('v_account_recent_order_headers')
      .select('order_id, order_date, bookings')
      .eq('customer_key', customerKey)
      .gte('order_date', ordersSince)
      // Secondary key wherever a LIMIT can split a tie: without it the row
      // set at the boundary is nondeterministic and the hash flaps.
      .order('order_date', { ascending: false })
      .order('order_id', { ascending: true })
      .limit(400),

    // Exact whole-account totals from the nightly rollup (20260901190100):
    // open_order_value = everything still owed, backlog_amount = the LATE
    // part of it (promise date passed).
    erp(client)
      .from('agg_account_rollup')
      .select(
        'revenue_ytd, revenue_prior_ytd, last_invoice_date, open_order_value, ' +
          'backlog_amount, open_order_count, last_order_date',
      )
      .eq('customer_key', customerKey)
      .maybeSingle(),

    // The goal panel's own row: portal goal first, ERP goal as fallback
    // (20260817140000). 'crm' sorts before 'erp'.
    client
      .from('v_account_goal_progress')
      .select(
        'period_year, target_amount, goal_source, revenue_to_date, ' +
          'attainment_pct, expected_pct, on_track, gap_to_pace, pace_basis',
      )
      .eq('customer_key', customerKey)
      .eq('period_year', yearNow)
      .order('goal_source', { ascending: true })
      .limit(1),

    client
      .from('v_backlog_by_sku')
      .select(
        'part_key, part_id, part_description, product_family, backlog_qty, ' +
          'backlog_amount, earliest_promise_date, earliest_desired_ship_date',
      )
      .eq('customer_key', customerKey)
      // Credit / discount lines carry negative amounts; they are not
      // something the dealer is waiting on.
      .gt('backlog_amount', 0)
      .order('backlog_amount', { ascending: false })
      .order('part_key', { ascending: true })
      .limit(TOP_BACKLOG_LINES),

    // SECURITY INVOKER (20261013100000 / 20261013140002): same rows for
    // the rep and for service_role. Already ordered due-first with part_key
    // as the last tie-break.
    client.rpc('report_reorder_candidates', {
      p_customer_key: customerKey,
      p_limit: TOP_REORDERS,
    }),

    client.rpc('report_account_family_mix', {
      p_customer_key: customerKey,
      p_through_month: mixThrough,
    }),

    // NULLS LAST: a 19000101 sentinel key makes ship_date NULL, and
    // Postgres sorts NULL first on a descending sort by default.
    erp(client)
      .from('fact_shipment_line')
      .select('ship_date')
      .eq('customer_key', customerKey)
      .order('ship_date', { ascending: false, nullsFirst: false })
      .order('packlist_id', { ascending: true })
      .order('line_num', { ascending: true })
      .limit(1),

    client
      .from('recommendations')
      .select('title, reason, priority, due_date, rule_key, status')
      .eq('customer_key', customerKey)
      .in('status', ['open', 'acted'])
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(10),

    // What came of recent observations — "they ordered after the March
    // call" is context; who closed it is not (§5.1: no author identity).
    client
      .from('recommendations')
      .select('title, status, outcome, outcome_note, closed_at')
      .eq('customer_key', customerKey)
      .in('status', ['closed', 'dismissed'])
      .gte('closed_at', resolvedSince)
      .order('closed_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(5),

    // Note bodies only — no created_by, no author name (§5.1).
    client
      .from('notes')
      .select('body, created_at')
      .eq('customer_key', customerKey)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(RECENT_NOTES),

    // Structured survey answers only — no user_id.
    client
      .from('visits')
      .select(
        'visit_date, visit_type, inventory_level, store_condition, ' +
          'display_quality, staff_knowledge, store_traffic, ' +
          'competitor_promos, competition_seen, comments',
      )
      .eq('customer_key', customerKey)
      .order('visit_date', { ascending: false })
      .order('id', { ascending: false })
      .limit(1)
      .maybeSingle(),

    client
      .from('actions')
      .select('action_type, action_date')
      .eq('customer_key', customerKey)
      .order('action_date', { ascending: false })
      .order('id', { ascending: false })
      .limit(50),
  ])

  // These bypass rows() (single-row / count shapes) but feed the same
  // hash — same rule: a real error must fail the build, not blank a slice.
  if (customerRes.error) {
    console.error('dim_customer read failed', customerRes.error)
    throw contextUnavailable()
  }
  if (invoiceCountRes.error) {
    // A zero here flips the insufficient-data gate; never fake it.
    console.error('fact_invoice_line count failed', invoiceCountRes.error)
    throw contextUnavailable()
  }
  if (visitRes.error && !isMissingRelation(visitRes.error)) {
    console.error('visits read failed', visitRes.error)
    throw contextUnavailable()
  }

  return {
    customer: (customerRes.data ?? {}) as Row,
    invoiceLineCount: (invoiceCountRes.count as number | null) ?? 0,
    revenue,
    orders: rows(orderRes, 'v_account_recent_order_headers'),
    ordersSince,
    rollup: rows(rollupRes, 'agg_account_rollup')[0] ?? null,
    goal: rows(goalRes, 'v_account_goal_progress')[0] ?? null,
    backlog: rows(backlogRes, 'v_backlog_by_sku'),
    reorders: rows(reorderRes, 'report_reorder_candidates'),
    mix: rows(mixRes, 'report_account_family_mix'),
    openRecs: rows(recRes, 'recommendations/open'),
    resolvedRecs: rows(resolvedRes, 'recommendations/resolved'),
    notes: rows(noteRes, 'notes'),
    visit: (visitRes.data ?? null) as Row | null,
    actions: rows(actionRes, 'actions'),
    lastShipDate: (rows(shipmentRes, 'fact_shipment_line')[0]?.ship_date as string | null) ?? null,
  }
}

/** The newest of several ISO dates (string compare is date order). */
function latest(...dates: Array<unknown>): string | null {
  let out: string | null = null
  for (const d of dates) {
    if (typeof d !== 'string' || !d) continue
    const day = d.slice(0, 10)
    if (!out || day > out) out = day
  }
  return out
}

function pctOrNull(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? Math.round(n * 10) / 10 : null
}

function iso(today: Date): string {
  return today.toISOString().slice(0, 10)
}

/**
 * The pure half: inputs → { context (hashed), asOf (not) }. No I/O and no
 * clock except `today`, so the hash-stability test can call it directly.
 */
export function assembleContext(input: ContextInputs, today = new Date()) {
  const customer = input.customer
  const rollup = input.rollup
  const todayIso = iso(today)

  const orders = input.orders.map((o) => ({
    date: (o.order_date as string | null) ?? null,
    amount: Number(o.bookings ?? 0),
  }))
  // Newest first from the query; re-sorted so a caller's order can't matter.
  const recentOrders = [...orders]
    .sort((a, b) => ((a.date ?? '') < (b.date ?? '') ? 1 : (a.date ?? '') > (b.date ?? '') ? -1 : 0))
    .slice(0, RECENT_ORDERS)
    .map((o) => ({ order_date: o.date, amount: round(o.amount) }))

  // Same harmonization as v_account_list/v_account_summary (migration 015):
  // dim_customer.last_order_date is unmaintained in the ERP and mostly NULL,
  // so take the newest date any source has seen.
  const lastOrderDate = latest(
    customer.last_order_date,
    recentOrders[0]?.order_date,
    rollup?.last_order_date,
  )

  // Goal: the panel's row when there is one; else the ERP yearly goal
  // straight off the customer (a database without the goal view).
  const yearNow = today.getUTCFullYear()
  const revenueYtd = rollup ? round(rollup.revenue_ytd) : null
  const erpGoal = Number(customer.yearly_sales_goal ?? 0)
  const goal = input.goal
    ? {
        year: Number(input.goal.period_year),
        target: round(input.goal.target_amount),
        source: input.goal.goal_source === 'crm' ? 'portal' : 'erp',
        revenue_to_date: round(input.goal.revenue_to_date),
        attainment_pct: pctOrNull(input.goal.attainment_pct),
      }
    : erpGoal > 0
      ? {
          year: yearNow,
          target: round(erpGoal),
          source: 'erp',
          revenue_to_date: revenueYtd ?? 0,
          attainment_pct: revenueYtd != null ? pctOrNull((100 * revenueYtd) / erpGoal) : null,
        }
      : null

  const actionRows = input.actions
  const lastAction = actionRows[0]
  const visit = input.visit

  // The series reaches one month further back than the model is shown, for
  // revenue_summary's whole-month windows (see fetchRevenueByMonth).
  const seriesFrom = monthStart(today, MONTHS_OF_HISTORY - 1).slice(0, 7)
  const shownSeries = input.revenue.series.filter((r) => r.month.slice(0, 7) >= seriesFrom)

  const context = {
    account: {
      name: customer.customer_name ?? null,
      city: customer.sold_to_city ?? null,
      state: customer.sold_to_state ?? null,
      assigned_rep: customer.assigned_sales_rep_name ?? null,
      customer_type: customer.customer_type ?? null,
      territory: customer.territory ?? null,
      active: customer.active_flag ?? null,
      account_open_date: customer.account_open_date ?? null,
      last_order_date: lastOrderDate,
      last_invoice_date: (rollup?.last_invoice_date as string | null) ?? null,
    },
    goal,
    revenue_ytd: revenueYtd,
    revenue_by_month: shownSeries,
    revenue_summary: summariseRevenue(input.revenue.series, today),
    buying_patterns: {
      orders_since: input.ordersSince,
      ...summariseBuyingPatterns(orders, shownSeries),
      mix: summariseMix(input.mix),
    },
    orders: {
      recent: recentOrders,
      // Exact, from the nightly rollup. Null (not 0) when the account has
      // no rollup row, so the model writes around it instead of "$0 owed".
      open_order_value: rollup ? round(rollup.open_order_value) : null,
      past_promise_amount: rollup ? round(rollup.backlog_amount) : null,
      open_order_count: rollup ? round(rollup.open_order_count) : null,
    },
    backlog_lines: input.backlog.map((b) => ({
      part: b.part_id ?? b.part_key ?? null,
      description: b.part_description ?? null,
      family: b.product_family ?? null,
      units: round(b.backlog_qty),
      amount: round(b.backlog_amount),
      promise_date: b.earliest_promise_date ?? null,
      production_date: b.earliest_desired_ship_date ?? null,
    })),
    // Stock QUANTITY is left out on purpose: it moves daily and would make
    // an unchanged account hash "changed". So is whether today's stock
    // covers their last order (as_of_today.stock_covers_last_order): it
    // flips whenever stock crosses that size, with no news from the dealer.
    in_stock_reorders: input.reorders.map((r) => ({
      part: r.part_id ?? r.part_key ?? null,
      description: r.part_description ?? null,
      family: r.product_family ?? null,
      chambering: r.chambering ?? null,
      last_bought_month: String(r.last_bought_month ?? '').slice(0, 7) || null,
      units_last_time: round(r.last_qty),
      months_bought_in_3_years: round(r.months_with_buys),
      typical_months_between_buys:
        r.median_months_between_buys == null ? null : Number(r.median_months_between_buys),
      next_buy_expected_month: r.expected_next_month ? String(r.expected_next_month).slice(0, 7) : null,
      due_now: r.is_due === true,
    })),
    shipments: {
      last_ship_date: input.lastShipDate,
    },
    open_recommendations: input.openRecs.map((r) => ({
      title: r.title,
      reason: r.reason,
      priority: r.priority,
      due_date: r.due_date,
      status: r.status,
    })),
    recently_resolved: input.resolvedRecs.map((r) => ({
      title: r.title,
      status: r.status,
      outcome: r.outcome ?? null,
      outcome_note: r.outcome_note ? String(r.outcome_note).slice(0, 400) : null,
      closed_on: r.closed_at ? String(r.closed_at).slice(0, 10) : null,
    })),
    recent_activity: {
      last_action_date: lastAction?.action_date ?? null,
      last_action_type: lastAction?.action_type ?? null,
    },
    notes: input.notes.map((n) => ({
      created_at: String(n.created_at ?? '').slice(0, 10),
      body: String(n.body ?? '').slice(0, 1200),
    })),
    last_visit: visit
      ? {
          visit_date: visit.visit_date,
          visit_type: visit.visit_type,
          inventory_level: visit.inventory_level,
          store_condition: visit.store_condition,
          display_quality: visit.display_quality,
          staff_knowledge: visit.staff_knowledge,
          store_traffic: visit.store_traffic,
          competitor_promos: visit.competitor_promos,
          competition_seen: visit.competition_seen,
          comments: visit.comments,
        }
      : null,
  }

  // Everything below moves with the calendar. Never hashed.
  const ninetyDaysAgo = (() => {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()))
    d.setUTCDate(d.getUTCDate() - 90)
    return d.toISOString().slice(0, 10)
  })()
  const asOf = {
    date: todayIso,
    days_since_last_order: daysSince(lastOrderDate, today),
    days_since_last_invoice: daysSince(context.account.last_invoice_date, today),
    days_since_last_ship: daysSince(input.lastShipDate, today),
    actions_last_90d: actionRows.filter((a) => String(a.action_date ?? '') >= ninetyDaysAgo).length,
    // agg_account_rollup.revenue_prior_ytd: last year up to the same DATE,
    // so it grows by a day every day.
    revenue_same_period_last_year: rollup ? round(rollup.revenue_prior_ytd) : null,
    goal_pace: input.goal
      ? {
          expected_pct_by_today: pctOrNull(input.goal.expected_pct),
          on_pace: input.goal.on_track ?? null,
          dollars_ahead_of_pace: input.goal.gap_to_pace == null ? null : round(input.goal.gap_to_pace),
          pace_basis: input.goal.pace_basis ?? null,
        }
      : null,
    backlog_lines_past_promise: context.backlog_lines.filter(
      (b) => b.promise_date && String(b.promise_date) < todayIso,
    ).length,
    // The in_stock_reorders parts whose stock today would cover an order
    // the size of their last one.
    stock_covers_last_order: input.reorders
      .filter((r) => Number(r.ats_qty ?? 0) >= Number(r.last_qty ?? 0))
      .map((r) => r.part_id ?? r.part_key ?? null),
  }

  return { context, asOf }
}

export type AccountContext = ReturnType<typeof assembleContext>['context']
export type AccountAsOf = ReturnType<typeof assembleContext>['asOf']

/** What the model reads: the hashed context plus today's figures. */
export function promptPayload(context: AccountContext, asOf: AccountAsOf) {
  return { ...context, as_of_today: asOf }
}

export async function buildContext(
  client: SupabaseClient,
  customerKey: string,
  today = new Date(),
) {
  const inputs = await fetchContextInputs(client, customerKey, today)
  const { context, asOf } = assembleContext(inputs, today)
  return {
    context,
    asOf,
    invoiceLineCount: inputs.invoiceLineCount,
    noteCount: inputs.notes.length,
    revenueSource: inputs.revenue.source,
  }
}
