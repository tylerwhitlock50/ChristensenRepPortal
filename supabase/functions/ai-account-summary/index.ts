/*============================================================================
  ai-account-summary

  Justification for existing at all (TECH_STACK §3.2): it holds
  OPENAI_API_KEY. Nothing else about it needs a server.

  Flow (TECH_STACK §5.1, followed in order):

    1. CORS preflight.
    2. Build a Supabase client WITH THE CALLER'S JWT — never service_role.
    3. Verify access by calling has_account_access(customer_key) AS THE USER.
    4. Build a compact JSON context from fixed, single-customer queries.
    5. Degrade gracefully BEFORE spending a token: too little activity → say so.
    6. SHA-256 the context; if it matches ai_summaries.context_hash, return
       the cached row instantly and for free.
    7. Enforce a per-user daily call limit and a per-account cooldown.
    8. One OpenAI call — gpt-5-mini, automatic prompt caching on the system
       message.
    9. Upsert into public.ai_summaries with model, context_hash,
       prompt_version, generated_at.

  The most important line in this file is the one that is NOT here: there is
  no serviceClient() import. A server component that reads account data with
  service_role "on behalf of" a rep moves the security boundary out of
  Postgres and into this file, where it will eventually leak (TECH_STACK
  constraint #2). Every query below runs under the caller's own RLS, so the
  worst this function can do is show a rep something they could already read
  through PostgREST themselves.

  PII (TECH_STACK §5.1): the context deliberately excludes public.contacts
  entirely — no buyer names, phone numbers or email addresses — and carries no
  author identity on notes, visits or actions. A revenue trend does not need
  to know who the buyer is, so it is never sent.
============================================================================*/

import { fail, json, preflight } from '../_shared/cors.ts'
import {
  HttpError,
  readJson,
  requireCaller,
  requirePost,
  userClient,
} from '../_shared/supabase.ts'
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { PROMPT_VERSION, SYSTEM_PROMPT } from './prompt.ts'

/*----------------------------------------------------------------------------
  Configuration
----------------------------------------------------------------------------*/

/**
 * Re-exported so the prompt version stays importable from the function's
 * entrypoint. It is defined next to the prompt text in prompt.ts, which is
 * what makes the two impossible to desync — see that file's header for why
 * the prompt is a module rather than the prompt.md it used to be.
 *
 * Stamped onto every ai_summaries row (TECH_STACK §5.2) and folded into the
 * context hash, so tuning the prompt re-baselines every account instead of
 * leaving a mix of old and new summaries that nobody can tell apart.
 */
export { PROMPT_VERSION }

/**
 * gpt-5-mini. This is summarisation over a small, well-structured context —
 * full gpt-5 is not worth the cost per account, and reps hit this button a
 * lot.
 *
 * Overridable without a redeploy, because the model id is folded into the
 * context hash below: changing it re-baselines every cached summary exactly
 * once, which is the same property prompt_version has. Set OPENAI_MODEL to
 * try a different one and the next generation per account picks it up.
 */
const MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-5-mini'

/**
 * On the gpt-5 family this budget covers REASONING TOKENS AS WELL AS the
 * visible reply, and reasoning tokens are spent first. The briefing itself is
 * ~150 words (~250 tokens), but a budget sized to that would be swallowed
 * whole by reasoning and return an empty message with finish_reason
 * 'length' — which is why this is 2000 and not 900. Headroom here is not
 * wasted spend: unused budget is never billed.
 */
const MAX_COMPLETION_TOKENS = 2000

/**
 * The design called for a low-temperature, deterministic summary. gpt-5
 * reasoning models reject a non-default `temperature` outright, so that
 * intent is expressed as minimal reasoning effort plus a prescriptive prompt
 * and the context-hash cache — which makes a repeated ask literally the same
 * bytes rather than merely a similar sample. Raise to 'low' or 'medium' if
 * summaries come back shallow.
 */
const REASONING_EFFORT = Deno.env.get('OPENAI_REASONING_EFFORT') ?? 'minimal'

const OPENAI_TIMEOUT_MS = 60_000

function envInt(name: string, fallback: number): number {
  const raw = Deno.env.get(name)
  const parsed = raw ? Number.parseInt(raw, 10) : NaN
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
}

/** "An internal tool with an unmetered LLM button is a bill waiting to happen." */
const DAILY_LIMIT = envInt('AI_SUMMARY_DAILY_LIMIT', 25)

/** Below this many invoice lines AND with no notes, we never call the API. */
const MIN_INVOICE_LINES = envInt('AI_SUMMARY_MIN_INVOICE_LINES', 5)

/**
 * Second half of the cost ceiling. The context hash makes an unchanged
 * regenerate free, but a rep who adds a note and regenerates in a loop would
 * change the hash every time. One paid generation per account per cooldown
 * window bounds that without needing a new table.
 */
const COOLDOWN_SECONDS = envInt('AI_SUMMARY_COOLDOWN_SECONDS', 60)

const MONTHS_OF_HISTORY = 24
const RECENT_ORDERS = 5
const RECENT_NOTES = 5

const INSUFFICIENT_DATA_MESSAGE = 'Not enough activity to summarize'

/*----------------------------------------------------------------------------
  Small helpers
----------------------------------------------------------------------------*/

/**
 * The generated Database type does not describe `erp`, and Deno does not
 * typecheck on deploy — cast once here rather than at every call site.
 */
// deno-lint-ignore no-explicit-any
function erp(client: SupabaseClient): any {
  // deno-lint-ignore no-explicit-any
  return (client as any).schema('erp')
}

function round(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value ?? 0)
  return Number.isFinite(n) ? Math.round(n) : 0
}

function isoDaysAgo(days: number): string {
  const d = new Date()
  d.setUTCDate(d.getUTCDate() - days)
  return d.toISOString().slice(0, 10)
}

function monthKey(isoDate: string): string {
  return isoDate.slice(0, 7)
}

/** Deterministic key order, so an unchanged account always hashes the same. */
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    const source = value as Record<string, unknown>
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(source).sort()) out[key] = canonical(source[key])
    return out
  }
  return value
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

// deno-lint-ignore no-explicit-any
function rows(result: { data: any; error: any }, label: string): any[] {
  if (result.error) {
    console.error(`context query failed: ${label}`, result.error)
    // A missing slice of context is not worth failing the whole summary over —
    // the prompt is written to tolerate absent fields.
    return []
  }
  return result.data ?? []
}

/*----------------------------------------------------------------------------
  Context assembly — fixed queries, all filtered by customer_key (indexed).

  Every erp filter carries `customer_key` because an unfiltered fact-table scan
  costs ~756ms once the RLS predicate defeats the index (migration 010).
----------------------------------------------------------------------------*/

type MonthlyRevenue = { month: string; revenue: number }

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
async function fetchRevenueByMonth(
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
function summariseRevenue(series: MonthlyRevenue[], today = new Date()) {
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
 * The buying-pattern block (prompt v2): cadence, typical order size, and the
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

async function buildContext(client: SupabaseClient, customerKey: string) {
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
      .order('order_date', { ascending: false })
      .limit(400),

    erp(client)
      .from('fact_shipment_line')
      .select('ship_date, shipped_revenue')
      .eq('customer_key', customerKey)
      .gte('ship_date', shipSince)
      .order('ship_date', { ascending: false })
      .limit(400),

    client
      .from('recommendations')
      .select('title, reason, priority, due_date, rule_key, status')
      .eq('customer_key', customerKey)
      .in('status', ['open', 'acted'])
      .order('created_at', { ascending: false })
      .limit(10),

    // Note bodies only — no created_by, no author name (§5.1).
    client
      .from('notes')
      .select('body, created_at')
      .eq('customer_key', customerKey)
      .order('created_at', { ascending: false })
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
      .limit(1)
      .maybeSingle(),

    client
      .from('actions')
      .select('action_type, action_date')
      .eq('customer_key', customerKey)
      .order('action_date', { ascending: false })
      .limit(50),

    // Product mix by family, this year vs last (v_sku_sales_by_account,
    // migration 025). Tolerated when the view is not applied yet — rows()
    // returns [] and the buying_patterns block simply has no mix.
    client
      .from('v_sku_sales_by_account')
      .select('product_family, sales_year, revenue')
      .eq('customer_key', customerKey),
  ])

  if (customerRes.error) {
    console.error('dim_customer read failed', customerRes.error)
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

/*----------------------------------------------------------------------------
  OpenAI
----------------------------------------------------------------------------*/

type OpenAIResponse = {
  choices?: Array<{
    message?: { content?: string | null; refusal?: string | null }
    finish_reason?: string
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    prompt_tokens_details?: { cached_tokens?: number }
    completion_tokens_details?: { reasoning_tokens?: number }
  }
  error?: { message?: string; type?: string; code?: string }
}

async function callOpenAI(systemPrompt: string, contextJson: string): Promise<string> {
  const apiKey = Deno.env.get('OPENAI_API_KEY')
  if (!apiKey) {
    throw new HttpError(
      500,
      'missing_env',
      'OPENAI_API_KEY is not set on this function.',
    )
  }

  /*
    Notes on this request shape, because three of them look like mistakes:

    - `max_completion_tokens`, not `max_tokens`. The gpt-5 family rejects
      `max_tokens` outright; it is the older parameter and is not merely
      deprecated here. See the MAX_COMPLETION_TOKENS note for why the number
      is much larger than the 150-word answer suggests.

    - There is NO `temperature`. gpt-5 reasoning models accept only the
      default and 400 on anything else. Determinism comes from the prompt,
      minimal reasoning effort and the context-hash cache instead.

    - The system prompt is the FIRST message and is byte-identical across
      every account. OpenAI caches prompt prefixes automatically above ~1024
      tokens — there is no cache_control field to set and nothing to opt into,
      but the ordering matters: anything account-specific placed before it
      would break the shared prefix for every other account. The prompt is
      ~1200 tokens today; trim it below ~1024 and caching silently stops.
      Watch usage.prompt_tokens_details.cached_tokens in the logs.
  */
  const body = {
    model: MODEL,
    max_completion_tokens: MAX_COMPLETION_TOKENS,
    reasoning_effort: REASONING_EFFORT,
    messages: [
      { role: 'system', content: systemPrompt },
      {
        role: 'user',
        content:
          'Write the account briefing for this dealer.\n\n<account_context>\n' +
          contextJson +
          '\n</account_context>',
      },
    ],
  }

  let res: Response
  try {
    res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
    })
  } catch (cause) {
    console.error('openai request failed', cause)
    throw new HttpError(
      504,
      'ai_unavailable',
      'The summary service did not respond. Try again in a moment.',
    )
  }

  if (!res.ok) {
    const detail = await res.text()
    console.error('openai returned', res.status, detail)
    throw new HttpError(
      res.status === 429 ? 429 : 502,
      res.status === 429 ? 'ai_rate_limited' : 'ai_error',
      res.status === 429
        ? 'The summary service is busy. Try again in a minute.'
        : 'The summary service returned an error.',
    )
  }

  const payload = (await res.json()) as OpenAIResponse
  const choice = payload.choices?.[0]

  // Check refusal before reading content: on a refusal `content` is null and
  // the reason lives in its own field.
  if (choice?.message?.refusal) {
    console.warn('openai refused', choice.message.refusal)
    throw new HttpError(
      502,
      'ai_refused',
      'The summary service declined to answer for this account.',
    )
  }

  const text = (choice?.message?.content ?? '').trim()

  if (!text) {
    // The specific failure worth naming: reasoning ate the whole budget and
    // nothing was left for the reply. Silently retrying would just burn the
    // same tokens again, so say what to change.
    if (choice?.finish_reason === 'length') {
      console.error('openai hit the token ceiling before replying', payload.usage)
      throw new HttpError(
        502,
        'ai_truncated',
        'The summary service ran out of tokens before answering. Raise ' +
          'MAX_COMPLETION_TOKENS or lower OPENAI_REASONING_EFFORT.',
      )
    }
    throw new HttpError(502, 'ai_empty', 'The summary service returned nothing.')
  }

  console.log('openai usage', {
    model: MODEL,
    finish_reason: choice?.finish_reason,
    input: payload.usage?.prompt_tokens,
    output: payload.usage?.completion_tokens,
    reasoning: payload.usage?.completion_tokens_details?.reasoning_tokens,
    cache_read: payload.usage?.prompt_tokens_details?.cached_tokens,
  })

  return text
}

/*----------------------------------------------------------------------------
  Handler
----------------------------------------------------------------------------*/

type RequestBody = { customer_key?: string }

type SummaryRow = {
  customer_key: string
  content: string
  model: string | null
  context_hash: string | null
  prompt_version: string | null
  generated_at: string
  generated_by: string | null
}

type Status = 'generated' | 'cached' | 'cooldown' | 'insufficient_data'

function respond(status: Status, summary: SummaryRow | null, extra = {}) {
  return json({ status, summary, ...extra })
}

async function handle(req: Request): Promise<Response> {
  requirePost(req)

  const body = await readJson<RequestBody>(req)
  const customerKey = (body.customer_key ?? '').trim()
  if (!customerKey) {
    throw new HttpError(400, 'missing_customer_key', 'customer_key is required.')
  }

  // The caller's JWT, forwarded. RLS applies to everything below.
  const client = userClient(req)
  const caller = await requireCaller(client)

  // Access is decided by Postgres, as the user — not by anything in this file.
  const access = await client.rpc('has_account_access', {
    p_customer_key: customerKey,
  })
  if (access.error) {
    console.error('has_account_access failed', access.error)
    throw new HttpError(500, 'access_check_failed', 'Could not verify access.')
  }
  if (access.data !== true) {
    // Same shape a rep would get hitting PostgREST directly: nothing.
    throw new HttpError(403, 'no_access', 'That account is not in your book.')
  }

  const existingRes = await client
    .from('ai_summaries')
    .select('*')
    .eq('customer_key', customerKey)
    .maybeSingle()
  const existing = (existingRes.data ?? null) as SummaryRow | null

  const built = await buildContext(client, customerKey)

  /*
    Graceful degradation, before a single token is spent (PRD acceptance
    criterion #7). A brand-new dealer with two invoice lines and no notes has
    nothing to summarise, and paying OpenAI to say so would be silly.
  */
  if (built.invoiceLineCount < MIN_INVOICE_LINES && built.noteCount === 0) {
    return respond('insufficient_data', null, {
      message: INSUFFICIENT_DATA_MESSAGE,
      reason: 'not_enough_activity',
    })
  }

  // Prompt version and model are part of the hash: tuning either one
  // invalidates every cached summary, which is what we want.
  const contextJson = JSON.stringify(canonical(built.context))
  const contextHash = await sha256Hex(
    JSON.stringify({
      prompt_version: PROMPT_VERSION,
      model: MODEL,
      context: contextJson,
    }),
  )

  // Nothing changed → return the cached copy instantly and for free.
  if (existing && existing.context_hash === contextHash) {
    return respond('cached', existing)
  }

  // Something changed, but not long enough ago to be worth paying for again.
  if (existing && COOLDOWN_SECONDS > 0) {
    const ageMs = Date.now() - new Date(existing.generated_at).getTime()
    if (ageMs >= 0 && ageMs < COOLDOWN_SECONDS * 1000) {
      return respond('cooldown', existing, {
        retry_after_seconds: Math.ceil((COOLDOWN_SECONDS * 1000 - ageMs) / 1000),
      })
    }
  }

  /*
    Per-user daily cap, counted from public.ai_usage_events (migration 028) —
    the per-generation ledger this comment used to wish for. The pool is
    shared with every other AI endpoint (ai-brief), which is the point: one
    cap, all AI spend. If the events table is not migrated yet the count
    errors, and we fall back to the old distinct-accounts count off
    ai_summaries rather than running unmetered.
  */
  if (DAILY_LIMIT > 0) {
    const startOfDay = new Date()
    startOfDay.setUTCHours(0, 0, 0, 0)
    let usage = await client
      .from('ai_usage_events')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', caller.id)
      .gte('created_at', startOfDay.toISOString())

    if (usage.error) {
      console.error('ai_usage_events count failed; falling back', usage.error)
      usage = await client
        .from('ai_summaries')
        .select('customer_key', { count: 'exact', head: true })
        .eq('generated_by', caller.id)
        .gte('generated_at', startOfDay.toISOString())
    }

    if (!usage.error && (usage.count ?? 0) >= DAILY_LIMIT) {
      throw new HttpError(
        429,
        'daily_limit_reached',
        `You have generated ${DAILY_LIMIT} summaries today. ` +
          'Cached summaries are still available.',
      )
    }
  }

  const content = await callOpenAI(SYSTEM_PROMPT, contextJson)

  // Ledger the paid call, tolerantly — a failed insert must not discard the
  // generation, but log loudly because it un-meters the cap.
  const usageInsert = await client
    .from('ai_usage_events')
    .insert({ user_id: caller.id, action: 'account.summary' })
  if (usageInsert.error) {
    console.error('ai_usage_events insert failed', usageInsert.error)
  }

  const row = {
    customer_key: customerKey,
    content,
    model: MODEL,
    context_hash: contextHash,
    prompt_version: PROMPT_VERSION,
    generated_at: new Date().toISOString(),
    generated_by: caller.id,
  }

  // Upsert under the caller's RLS — insert and update policies on
  // ai_summaries both gate on the same book membership we already checked.
  const saved = await client
    .from('ai_summaries')
    .upsert(row, { onConflict: 'customer_key' })
    .select('*')
    .single()

  if (saved.error) {
    // The summary is good even if caching it failed; hand it to the rep
    // rather than throwing away a paid call.
    console.error('ai_summaries upsert failed', saved.error)
    return respond('generated', row as SummaryRow, { cached: false })
  }

  console.log('summary generated', {
    customer_key: customerKey,
    revenue_source: built.revenueSource,
    invoice_lines: built.invoiceLineCount,
  })

  return respond('generated', saved.data as SummaryRow, { cached: true })
}

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  try {
    return await handle(req)
  } catch (err) {
    if (err instanceof HttpError) {
      return fail(err.status, err.code, err.message)
    }
    console.error('ai-account-summary unhandled error', err)
    return fail(500, 'internal_error', 'Could not build the summary.')
  }
})
