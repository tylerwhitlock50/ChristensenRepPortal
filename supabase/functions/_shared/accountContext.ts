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

  On PII (TECH_STACK §5.1): the context deliberately excludes public.contacts
  entirely and carries no author identity on notes, visits or actions. Keep it
  that way. A revenue trend does not need to know who the buyer is.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { HttpError } from './supabase.ts'
import { isMissingRelation } from './ai.ts'

export const MONTHS_OF_HISTORY = 24
export const RECENT_ORDERS = 5
export const RECENT_NOTES = 5

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
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the account data behind this summary. Try again in a moment.',
    )
  }
  return result.data ?? []
}

/*----------------------------------------------------------------------------
  Context assembly — fixed queries, all filtered by customer_key (indexed).

  Every erp filter carries `customer_key` because an unfiltered fact-table scan
  costs ~756ms once the RLS predicate defeats the index (migration 010).
----------------------------------------------------------------------------*/

export type MonthlyRevenue = { month: string; revenue: number }

/**
 * Prefers the pre-aggregated `public.v_account_revenue_monthly` rollup view.
 * If it does not exist yet (the account-page views are a separate workstream)
 * it falls back to reading this ONE customer's invoice lines and bucketing
 * them here.
 *
 * The fallback is acceptable where the browser version would not be: it is a
 * single-customer, index-backed, date-bounded read on the server, not
 * thousands of rows shipped to a phone. When the view lands, this function
 * silently starts using it — nothing to change here.
 */
export async function fetchRevenueByMonth(
  client: SupabaseClient,
  customerKey: string,
): Promise<{ series: MonthlyRevenue[]; source: 'view' | 'fact_lines' }> {
  const since = isoDaysAgo(MONTHS_OF_HISTORY * 31)

  const viaView = await client
    .from('v_account_revenue_monthly')
    .select('month, revenue')
    .eq('customer_key', customerKey)
    .gte('month', since)
    .order('month', { ascending: true })
    .limit(MONTHS_OF_HISTORY)

  if (!viaView.error && viaView.data) {
    return {
      series: (viaView.data as Array<Record<string, unknown>>).map((r) => ({
        month: String(r.month ?? '').slice(0, 7),
        revenue: round(r.revenue),
      })),
      source: 'view',
    }
  }

  const viaFacts = await erp(client)
    .from('fact_invoice_line')
    .select('invoice_date, revenue')
    .eq('customer_key', customerKey)
    .gte('invoice_date', since)
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
    .slice(-MONTHS_OF_HISTORY)
    .map(([month, revenue]) => ({ month, revenue: round(revenue) }))

  return { series, source: 'fact_lines' }
}

/**
 * Align by CALENDAR month, never by array position.
 *
 * v_account_revenue_monthly omits months with no invoices ("Months with no
 * invoices are simply absent"), so the series is sparse. Slicing it by index
 * silently redefines the windows: a seasonal dealer invoicing in 8 of the last
 * 24 months has all 8 rows counted as "trailing 12 months" and an empty prior
 * window, so prior_12m_revenue is 0 and change_pct is null. With 18 present
 * months it reports a large fake swing on a flat account.
 *
 * prompt.ts tells the model these fields are literally the trailing twelve
 * months and the twelve before that, so a wrong number here becomes a
 * confident false statement in a rep's briefing.
 */
export function summariseRevenue(series: MonthlyRevenue[], today = new Date()) {
  const byMonth = new Map(series.map((r) => [r.month.slice(0, 7), r.revenue]))

  // 24 calendar-month keys ending with the current month, newest first.
  const monthKeys: string[] = []
  const cursor = new Date(
    Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1),
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
    trailing_12m_revenue: trailing,
    prior_12m_revenue: prior,
    change_pct: changePct,
    months_with_revenue: series.filter((r) => r.revenue > 0).length,
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
 * The buying-pattern block (prompt v3): cadence, typical order size, and the
 * calendar months this account historically buys in. Pure derivation over
 * data the context already fetched — no extra queries here.
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
  const lastDate = dates[dates.length - 1] ?? null
  const daysSinceLast = lastDate
    ? Math.round((Date.now() - new Date(lastDate).getTime()) / 86_400_000)
    : null

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
    orders_last_400d: dates.length,
    median_days_between_orders: gaps.length >= 2 ? round(median(gaps)) : null,
    days_since_last_order: daysSinceLast,
    median_order_amount: round(median(orders.map((o) => o.amount).filter((a) => a > 0))),
    peak_buying_months: peakMonths,
  }
}

export async function buildContext(client: SupabaseClient, customerKey: string) {
  const orderSince = isoDaysAgo(400)
  const shipSince = isoDaysAgo(180)

  const [
    customerRes,
    invoiceCountRes,
    revenue,
    orderRes,
    shipmentRes,
    recRes,
    noteRes,
    visitRes,
    actionRes,
    skuMixRes,
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

    fetchRevenueByMonth(client, customerKey),

    erp(client)
      .from('fact_order_line')
      .select('order_id, order_date, bookings, backlog_amount, order_status_desc')
      .eq('customer_key', customerKey)
      .gte('order_date', orderSince)
      // Secondary keys everywhere a LIMIT can split a tie: without them the
      // row set at the boundary is nondeterministic and the context hash
      // flaps on identical data.
      .order('order_date', { ascending: false })
      .order('order_id', { ascending: true })
      .order('line_num', { ascending: true })
      .limit(400),

    erp(client)
      .from('fact_shipment_line')
      .select('ship_date, shipped_revenue')
      .eq('customer_key', customerKey)
      .gte('ship_date', shipSince)
      .order('ship_date', { ascending: false })
      .order('packlist_id', { ascending: true })
      .order('line_num', { ascending: true })
      .limit(400),

    client
      .from('recommendations')
      .select('title, reason, priority, due_date, rule_key, status')
      .eq('customer_key', customerKey)
      .in('status', ['open', 'acted'])
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(10),

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

    // Product mix by family, this year vs last (v_sku_sales_by_account,
    // migration 025). Tolerated when the view is not applied yet — rows()
    // returns [] and the buying_patterns block simply has no mix.
    client
      .from('v_sku_sales_by_account')
      .select('product_family, sales_year, revenue')
      .eq('customer_key', customerKey)
      // Deterministic row order → deterministic tie-breaks in topFamilies()
      // (stable sort falls back to first-seen order).
      .order('sales_year', { ascending: true })
      .order('product_family', { ascending: true }),
  ])

  // These three bypass rows() (single-row / count shapes) but feed the same
  // hash — same rule: a real error must fail the build, not blank a slice.
  if (customerRes.error) {
    console.error('dim_customer read failed', customerRes.error)
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the account data behind this summary. Try again in a moment.',
    )
  }
  if (invoiceCountRes.error) {
    // A zero here flips the insufficient-data gate; never fake it.
    console.error('fact_invoice_line count failed', invoiceCountRes.error)
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the account data behind this summary. Try again in a moment.',
    )
  }
  if (visitRes.error && !isMissingRelation(visitRes.error)) {
    console.error('visits read failed', visitRes.error)
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the account data behind this summary. Try again in a moment.',
    )
  }
  const customer = (customerRes.data ?? {}) as Record<string, unknown>
  const invoiceLineCount = (invoiceCountRes.count as number | null) ?? 0

  // Order lines roll up to orders here rather than in the prompt — the model
  // should be reading a handful of orders, not hundreds of lines.
  const orderTotals = new Map<string, { date: string | null; amount: number }>()
  let openBacklog = 0
  for (const line of rows(orderRes, 'fact_order_line')) {
    openBacklog += Number(line.backlog_amount ?? 0)
    const id = String(line.order_id ?? '')
    if (!id) continue
    const existing = orderTotals.get(id)
    const amount = Number(line.bookings ?? 0)
    if (existing) {
      existing.amount += amount
    } else {
      orderTotals.set(id, {
        date: (line.order_date as string | null) ?? null,
        amount,
      })
    }
  }
  const allOrders = Array.from(orderTotals.values())
  const recentOrders = allOrders
    .sort((a, b) => ((a.date ?? '') < (b.date ?? '') ? 1 : -1))
    .slice(0, RECENT_ORDERS)
    .map((o) => ({ order_date: o.date, amount: round(o.amount) }))

  // Product mix by family, this year vs last, top 6 families each.
  const yearNow = new Date().getUTCFullYear()
  const mixByYear = new Map<number, Map<string, number>>()
  for (const r of rows(skuMixRes, 'v_sku_sales_by_account')) {
    const year = Number(r.sales_year ?? 0)
    if (year !== yearNow && year !== yearNow - 1) continue
    const family = String(r.product_family ?? '').trim() || '(none)'
    const byFamily = mixByYear.get(year) ?? new Map<string, number>()
    byFamily.set(family, (byFamily.get(family) ?? 0) + Number(r.revenue ?? 0))
    mixByYear.set(year, byFamily)
  }
  const topFamilies = (year: number) =>
    Array.from(mixByYear.get(year)?.entries() ?? [])
      .sort((a, b) => b[1] - a[1])
      .slice(0, 6)
      .map(([family, rev]) => ({ family, revenue: round(rev) }))

  const buyingPatterns = {
    ...summariseBuyingPatterns(allOrders, revenue.series),
    mix_this_year: topFamilies(yearNow),
    mix_last_year: topFamilies(yearNow - 1),
  }

  const shipmentLines = rows(shipmentRes, 'fact_shipment_line')
  const ninetyDaysAgo = isoDaysAgo(90)
  let shipped90 = 0
  let lastShipDate: string | null = null
  for (const line of shipmentLines) {
    const date = (line.ship_date as string | null) ?? null
    if (date && (!lastShipDate || date > lastShipDate)) lastShipDate = date
    if (date && date >= ninetyDaysAgo) shipped90 += Number(line.shipped_revenue ?? 0)
  }

  const actionRows = rows(actionRes, 'actions')
  const lastAction = actionRows[0]
  const actions90 = actionRows.filter(
    (a) => String(a.action_date ?? '') >= ninetyDaysAgo,
  ).length

  const noteRows = rows(noteRes, 'notes') as Array<Record<string, unknown>>
  const visit = (visitRes.data ?? null) as Record<string, unknown> | null

  // Same harmonization as v_account_list/v_account_summary (migration 015):
  // dim_customer.last_order_date is unmaintained in the ERP and mostly NULL,
  // so take the newest date we actually saw in order history when it's later.
  // recentOrders is sorted newest-first; ISO dates compare as strings.
  const dimLastOrder = (customer.last_order_date as string | null) ?? null
  const factLastOrder = recentOrders[0]?.order_date ?? null
  const lastOrderDate =
    dimLastOrder && factLastOrder
      ? dimLastOrder > factLastOrder
        ? dimLastOrder
        : factLastOrder
      : (factLastOrder ?? dimLastOrder)

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
      yearly_sales_goal: customer.yearly_sales_goal
        ? round(customer.yearly_sales_goal)
        : null,
    },
    revenue_by_month: revenue.series,
    revenue_summary: summariseRevenue(revenue.series),
    buying_patterns: buyingPatterns,
    orders: {
      recent: recentOrders,
      open_backlog_amount: round(openBacklog),
    },
    shipments: {
      last_ship_date: lastShipDate,
      shipped_last_90d: round(shipped90),
    },
    open_recommendations: rows(recRes, 'recommendations').map((r) => ({
      title: r.title,
      reason: r.reason,
      priority: r.priority,
      due_date: r.due_date,
      status: r.status,
    })),
    recent_activity: {
      last_action_date: lastAction?.action_date ?? null,
      last_action_type: lastAction?.action_type ?? null,
      actions_last_90d: actions90,
    },
    notes: noteRows.map((n) => ({
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

  return {
    context,
    invoiceLineCount,
    noteCount: noteRows.length,
    revenueSource: revenue.source,
  }
}
