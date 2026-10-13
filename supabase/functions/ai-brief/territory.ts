/*============================================================================
  ai-brief/territory.ts — the 'territory.brief' action: its context, what
  the model is asked to return, and how that reply is checked.

  Split out of index.ts (which calls Deno.serve at import) so the pure parts
  can be unit tested: territory.test.ts.

  ── Context ────────────────────────────────────────────────────────────────
  The caller's whole book, compact. Ranking and totals happen IN POSTGRES,
  the same way the mcp function's get_territory_summary does it (see
  mcp/tools.ts):

    - totals come from report_territory_summary(), a true whole-book
      aggregate over v_territory_account_yoy (20260817120000);
    - each highlight list is its own ORDER BY … LIMIT on the view's SQL
      columns (yoy_change_amount is a column precisely so this can be an
      indexed ORDER BY rather than a JS sort);
    - the goal is v_my_goal_rollup — the row the Overview goal tile reads —
      so the brief and the tile can never disagree about pace.

  The previous shape read the view with no LIMIT, ordered by customer_key,
  and sorted in TypeScript. PostgREST caps every response at max-rows
  (1,000 on a default project) whatever the query asks for, so an admin's
  book — every active account — came back as an alphabetical prefix: the
  totals were short, "top accounts" were the biggest names among A–L, and
  the brief confidently described a territory that does not exist. A rep's
  few hundred accounts fit under the cap, which is why it only showed up on
  big books.

  Everything stays top-N sliced and rounded so the context is bounded (and
  cheap) even when the territory is the whole company. Every list carries
  its total match count so the model knows it is looking at an excerpt.

  ── Hashed vs as-of-today (v2.0.0) ─────────────────────────────────────────
  Same rule as the account brief (_shared/accountContext.ts): the hash
  covers data, not the clock. days_since_invoice and data_through (the
  newest invoice in the WHOLE warehouse, which moves every business day
  whether or not this book changed) are added to the model's input by
  territoryPromptPayload() and never hashed. They used to be, so the brief
  paid for a regeneration almost every morning. Goal pace (expected_pct and
  how many accounts are behind it) is computed against current_date, so it
  is as-of-today too.

  What still moves the hash without a new invoice in this book: the
  "same window last year" figures (revenue_prior_ytd and the movers built
  on it grow with last year's invoices on today's date), the 90-day dormant
  cutoff and the 14-day recent-orders window. Those ARE the brief, so a
  territory brief is still regenerated most business days; the saving is
  on the days nothing moved.

  ── What the brief was missing (v3.1.0) ───────────────────────────────────
  Briefs read wrong for reasons that were all on the input side:

    - Their figures had no date. Totals, top accounts, movers and the
      gone-quiet list are all rollups (erp.agg_account_rollup), rebuilt by
      the ETL's post-load step — the only date the model saw was
      data_through, the newest invoice in the FACT table. When the post-load
      stopped running (2026-10-03 to at least 10-13) the facts kept moving
      and the brief described Oct 2 numbers as "through Oct 9", Lipsey's
      (shipping daily) as "last invoice Oct 1". Now: the rollups' rebuild
      date, and "behind" decided from the load ledger (facts loaded after
      the rebuild, outside the run's own grace window) — never from invoice
      dates, which future-dated rows and quiet weeks get wrong. Behind, the
      first headline says so, and any "quiet" account that has invoiced
      since is re-checked against the facts and dropped. Last-invoice
      dates now ride only on quiet accounts.
    - "Recent orders" was the 15 newest headers, cancelled ones included,
      with no count: a fraction of a fortnight, read as all of it. Now: the
      count and value of EVERY uncancelled order in the window, plus the
      largest few.
    - backlog_amount has meant "past promise" since 20260901190100, while
      the prompt called it dollars on backorder, and accounts carried no
      open-order figure — a dealer down 99% with $1.5M on order read as
      gone. Accounts and totals now carry open_order_value and
      past_promise_amount, and open_orders_cover_drop decides "not shipped
      yet" vs a real drop in code.
    - Products were this year so far beside ALL of last year. Now families
      and real products over the same whole months of both years (a full
      prior year in January and February), named by period.
    - Percentages were the model's own arithmetic; now every one it may
      cite is computed here, and null on a base too small to mean anything.
    - Bookings, new accounts and channels were absent, and an admin got a
      "territory" brief about the whole company.

  The new reads (20261013160000) are optional: on a database without them
  the brief falls back to the old inputs, minus the claims they made
  possible. Hash: the rebuild date is hashed only while the figures are
  behind, so a healthy rebuild every night does not by itself buy a paid
  regeneration.

  ── Tappable headlines (v2.0.0) ────────────────────────────────────────────
  Every account in the context carries its customer_key, and the model
  returns strict JSON: the same prose `content` as before (the deployed
  SalesBriefCard parses it) plus `headlines[]`, each tagged with the one
  account it is about. parseBriefOutput() keeps a key only if it was in the
  context the model saw, and takes the account name from that context, so a
  chip can never point outside the caller's book or carry an invented name.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { HttpError } from '../_shared/supabase.ts'
import { isMissingRelation, round, rows } from '../_shared/ai.ts'

// deno-lint-ignore no-explicit-any
export type Row = Record<string, any>

/** How many accounts each highlight list names. */
const TOP_ACCOUNTS = 10
const MOVERS = 5
const DORMANT = 5
/** "Dormant": nothing invoiced in this many days, with real recent history. */
export const DORMANT_DAYS = 90
const DORMANT_MIN_TRAILING_12M = 5_000
/** Product families and products passed to the model. */
const MIX_FAMILIES = 12
const MIX_SKUS = 8
/** Headlines kept from a reply; the prompt asks for 3 to 5. */
const MAX_HEADLINES = 5
/** The business calendar every rollup window is computed in (20260901190000). */
const BUSINESS_TZ = 'America/Denver'
/**
 * Below these, a percentage change is noise ("up 41,493%" on a $2,026
 * base): the model is given null and told to use dollars.
 */
const MIN_PCT_BASE_ACCOUNT = 25_000
const MIN_PCT_BASE_PRODUCT = 5_000
/**
 * A fact load newer than the rollup rebuild by less than this is the
 * nightly run still in progress (the facts swap first, the rebuild is the
 * first post-load step) — not a rebuild that failed.
 */
const LOAD_GRACE_MS = 3 * 60 * 60_000

const ACCOUNT_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, revenue_ytd, ' +
  'revenue_prior_ytd, revenue_trailing_12m, last_invoice_date, open_order_value, ' +
  'backlog_amount, yoy_change_amount, first_invoice_date'
/** + channel (20261013160000), when the view has it. */
const ACCOUNT_COLUMNS_V3 = ACCOUNT_COLUMNS + ', channel'

/**
 * Single-row unwrap with the same tolerance rule as rows(): only a relation
 * that is not migrated yet may be absent; anything else throws rather than
 * blanking a slice out of the hash.
 */
// deno-lint-ignore no-explicit-any
function rowOrNull(result: { data: any; error: any }, label: string): Row | null {
  // .maybeSingle() answers with the row itself, not a one-row array —
  // indexing it with [0] read undefined, and the brief never saw the goal.
  const data = rows(result, label) as unknown
  if (Array.isArray(data)) return (data[0] as Row | undefined) ?? null
  return (data as Row | null) ?? null
}

/** A read that may not be migrated yet: null when it is missing. */
// deno-lint-ignore no-explicit-any
function optional(result: { data: any; error: any }, label: string): unknown {
  if (result.error && isMissingRelation(result.error)) {
    console.warn(`context read not deployed yet: ${label}`, result.error)
    return null
  }
  return rows(result, label)
}

function num(v: unknown): number {
  const n = Number(v ?? 0)
  return Number.isFinite(n) ? n : 0
}

/** A percentage as the view reports it (one decimal), or null when unknown. */
function pctOrNull(v: unknown): number | null {
  if (v == null) return null
  const n = Number(v)
  return Number.isFinite(n) ? Math.round(n * 10) / 10 : null
}

/**
 * Whole-number % change, or null when there is no base worth a percentage.
 * Every percentage the model may cite is computed here: a small model
 * dividing dollars itself is where "up 10%" became "up 9.8%" or worse.
 */
export function changePct(now: unknown, prior: unknown, minBase = 1): number | null {
  const base = num(prior)
  if (base <= 0 || base < minBase) return null
  return Math.round(((num(now) - base) / base) * 100)
}

/** The business-calendar (Mountain) date of an instant, as YYYY-MM-DD. */
export function businessDate(instant: Date): string {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: BUSINESS_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(instant)
}

/** YYYY-MM-DD shifted by whole days (UTC arithmetic on a plain date). */
function shiftDays(isoDate: string, days: number): string {
  const d = new Date(isoDate + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

/**
 * The last month of the product-mix window, as YYYY-MM-01: the last
 * complete month before `anchor`'s — except when that leaves one month or
 * none of the current year (an anchor in January or February), where it is
 * December: last full year against the year before, rather than January
 * against January.
 */
export function productWindowEnd(anchor: string): string {
  const year = Number(anchor.slice(0, 4))
  const month = Number(anchor.slice(5, 7)) // 1..12
  if (month <= 2) return `${year - 1}-12-01`
  return `${year}-${String(month - 1).padStart(2, '0')}-01`
}

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December']

/** "January–September 2026" or "2025" for a whole year. */
function periodLabel(from: unknown, through: unknown): string | null {
  if (typeof from !== 'string' || typeof through !== 'string') return null
  const y = through.slice(0, 4)
  const m = Number(through.slice(5, 7))
  if (!m) return null
  if (m === 12) return y
  if (m === 1) return `January ${y}`
  return `January–${MONTHS[m - 1]} ${y}`
}

/** Where the book stands against goal pace TODAY — moves with the clock. */
export type GoalPace = { expected_pct: number | null; accounts_behind_pace: number }

export type TerritoryBuilt = {
  /** Hashed. */
  context: Row
  /** Not hashed: the clock, the warehouse watermark, goal pace and the
   *  recent-orders window start. */
  asOf: {
    data_through: string | null
    goal_pace: GoalPace | null
    recent_since?: string | null
    figures_as_of?: string | null
  }
  /** customer_key → account name, for every account in `context`. */
  subjects: Record<string, string>
  /** When set, respond insufficient_data without spending a token. */
  insufficient?: { message: string; reason: string }
}

export async function buildTerritoryContext(
  client: SupabaseClient,
  _subjectKey: string,
  today = new Date(),
): Promise<TerritoryBuilt> {
  // ── 1. When the figures are from, and whose book this is ──────────────────
  // Everything below that is a window (the dormant cutoff, the product mix)
  // is anchored on the day the rollups were rebuilt, not on the wall clock:
  // a rollup a week behind read against today's calendar is exactly how the
  // brief came to describe Oct 2 numbers as current.
  const [factsRes, freshRes, adminRes] = await Promise.all([
    client.rpc('report_territory_brief_facts').maybeSingle(),
    client.from('v_data_freshness').select('*').maybeSingle(),
    // View-as aware (effective user): an admin viewing as a rep gets that
    // rep's territory, worded as a territory.
    client.rpc('is_admin'),
  ])

  const factsData = optional(factsRes, 'report_territory_brief_facts')
  const facts = (Array.isArray(factsData) ? factsData[0] ?? null : factsData ?? null) as Row | null

  // Same rule as rows(): only a not-yet-migrated view may go missing
  // silently — a real error must not blank data_through.
  if (freshRes.error && !isMissingRelation(freshRes.error)) {
    console.error('context query failed: v_data_freshness', freshRes.error)
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the data behind this brief. Try again in a moment.',
    )
  }
  const fresh = (freshRes.data ?? null) as Row | null
  const dataThrough = typeof fresh?.data_through === 'string' ? fresh.data_through.slice(0, 10) : null

  const refreshedMs = facts?.figures_refreshed_at ? Date.parse(String(facts.figures_refreshed_at)) : NaN
  const figuresAsOf = Number.isFinite(refreshedMs) ? businessDate(new Date(refreshedMs)) : null
  // Behind = the fact tables the rollups are built from have loaded since
  // the rollups were rebuilt, and long enough ago that tonight's run is
  // not simply still going. From the load ledger, not from invoice dates:
  // a future-dated invoice or a quiet week must not decide it. Unknown (an
  // older v_data_freshness) is not behind.
  const factsLoadedMs = fresh?.facts_loaded_at ? Date.parse(String(fresh.facts_loaded_at)) : NaN
  const figuresBehind =
    Number.isFinite(refreshedMs) &&
    Number.isFinite(factsLoadedMs) &&
    factsLoadedMs > refreshedMs &&
    today.getTime() - factsLoadedMs > LOAD_GRACE_MS
  const anchor = figuresAsOf ?? businessDate(today)

  // A failed is_admin read is a territory, not an outage.
  const scope = !adminRes.error && adminRes.data === true ? 'company' : 'territory'

  const yearNow = Number(anchor.slice(0, 4))
  const cutoff = shiftDays(anchor, -DORMANT_DAYS)
  const mixThrough = productWindowEnd(anchor)

  // ── 2. The book ────────────────────────────────────────────────────────────
  // `channel` came with 20261013160000 — the same migration as the facts
  // function, so its presence says whether the view has the column.
  const columns = facts ? ACCOUNT_COLUMNS_V3 : ACCOUNT_COLUMNS
  // One ranked slice of the book. customer_key is the final ORDER BY term
  // so ties (whole pages of $0 accounts) rank deterministically — a
  // boundary row that reshuffles on identical data flips the context hash.
  // count: 'exact' carries the total number of matching rows.
  const slice = (sort: string, ascending: boolean, counted = true) =>
    client
      .from('v_territory_account_yoy')
      .select(columns, counted ? { count: 'exact' } : undefined)
      .order(sort, { ascending, nullsFirst: false })
      .order('customer_key', { ascending: true })

  const [
    totalsRes,
    goalRes,
    topRes,
    upRes,
    downRes,
    dormantRes,
    recentRes,
    mixRes,
    skuNowRes,
    skuPriorRes,
  ] = await Promise.all([
    // Unfiltered on purpose, here and below — RLS is the territory filter
    // (025); report_territory_summary() is security invoker for that reason.
    client.rpc('report_territory_summary').maybeSingle(),
    client
      .from('v_my_goal_rollup')
      .select('accounts_with_goal, accounts_behind, target_total, revenue_total, attainment_pct, expected_pct')
      .eq('period_year', yearNow)
      .maybeSingle(),
    slice('revenue_ytd', false, false).gt('revenue_ytd', 0).limit(TOP_ACCOUNTS),
    slice('yoy_change_amount', false).gt('yoy_change_amount', 0).limit(MOVERS),
    slice('yoy_change_amount', true).lt('yoy_change_amount', 0).limit(MOVERS),
    // Gone quiet: meaningful trailing-12-month business, but the last
    // invoice is older than the cutoff. Biggest recent history first.
    slice('revenue_trailing_12m', false)
      .lt('last_invoice_date', cutoff)
      .gte('revenue_trailing_12m', DORMANT_MIN_TRAILING_12M)
      .limit(DORMANT),
    // Only without the facts function (which counts every uncancelled
    // order and lists the largest): the old excerpt, now the largest rather
    // than the newest, with the slice's exact count.
    facts
      ? Promise.resolve({ data: [], error: null, count: null })
      : client
          .from('v_territory_recent_orders')
          .select('customer_key, customer_name, order_id, order_date, order_amount, has_backlog', {
            count: 'exact',
          })
          .order('order_amount', { ascending: false })
          .order('order_id', { ascending: true })
          .limit(8),
    client.rpc('report_territory_product_mix', {
      p_through_month: mixThrough,
      p_sku_limit: MIX_SKUS,
    }),
    // The old product lists: used only when the product mix is not
    // migrated yet. Cheap enough to read alongside rather than in a third
    // round trip.
    client
      .from('v_territory_sku_sales')
      .select('part_id, part_description, product_family, chambering, revenue, qty')
      .eq('sales_year', yearNow)
      .order('revenue', { ascending: false })
      .order('part_id', { ascending: true })
      .limit(15),
    client
      .from('v_territory_sku_sales')
      .select('part_id, part_description, product_family, chambering, revenue, qty')
      .eq('sales_year', yearNow - 1)
      .order('revenue', { ascending: false })
      .order('part_id', { ascending: true })
      .limit(15),
  ])

  // The totals are the spine of the brief: without them there is nothing
  // honest to write, so a missing RPC is an outage, not a tolerated absence
  // (an empty context would read as "no accounts" — a lie, cached).
  if (totalsRes.error) {
    console.error('context query failed: report_territory_summary', totalsRes.error)
    throw new HttpError(
      503,
      'context_unavailable',
      'Could not read the data behind this brief. Try again in a moment.',
    )
  }
  const totals = (totalsRes.data ?? null) as Row | null
  const accountCount = Math.round(num(totals?.accounts))

  if (!totals || accountCount === 0) {
    return {
      context: {},
      asOf: { data_through: null, goal_pace: null },
      subjects: {},
      insufficient: {
        message: 'No accounts in this territory yet.',
        reason: 'empty_book',
      },
    }
  }

  const subjects: Record<string, string> = {}
  const remember = (key: unknown, name: unknown) => {
    const k = typeof key === 'string' ? key : ''
    if (k && !(k in subjects)) subjects[k] = String(name ?? '') || k
  }

  // customer_key rides along so a headline can name the account it is about
  // (and be checked against this very list); it is not for the prose.
  // backlog_amount is the PAST-PROMISE share of open orders (20260901190100)
  // and is named for that here; open_order_value is everything still owed.
  // last_invoice_date only on gone-quiet accounts: on any other account it
  // is a rollup date the model has no reason to quote, and on a stale night
  // it is wrong ("Lipsey's last invoice Oct 1" while they shipped daily).
  const slim = (a: Row, withLastInvoice = false) => {
    remember(a.customer_key, a.customer_name)
    const change = num(a.revenue_ytd) - num(a.revenue_prior_ytd)
    return {
      customer_key: a.customer_key ?? null,
      name: a.customer_name ?? a.customer_key,
      ...(a.channel ? { channel: a.channel } : {}),
      city: a.sold_to_city ?? null,
      state: a.sold_to_state ?? null,
      revenue_ytd: round(a.revenue_ytd),
      revenue_prior_ytd: round(a.revenue_prior_ytd),
      change_pct: changePct(a.revenue_ytd, a.revenue_prior_ytd, MIN_PCT_BASE_ACCOUNT),
      open_order_value: round(a.open_order_value),
      past_promise_amount: round(a.backlog_amount),
      // A drop at least half covered by orders already placed: not shipped
      // yet, not gone. Decided here so "large" is never the model's call.
      open_orders_cover_drop: change < 0 && num(a.open_order_value) >= -change / 2,
      first_invoice_date: a.first_invoice_date ?? null,
      ...(withLastInvoice ? { last_invoice_date: a.last_invoice_date ?? null } : {}),
    }
  }

  // The goal tile's own row. Null when no account in the book carries a
  // goal (CRM or ERP) — then `goal` is omitted rather than reported as $0.
  // Target, attainment and the revenue it counts are data; expected_pct and
  // the behind-pace count are computed against current_date in
  // v_account_goal_progress, so they move on days nothing was invoiced —
  // asOf, never hashed.
  const goalRow = rowOrNull(goalRes, 'v_my_goal_rollup')
  const hasGoal = !!goalRow && num(goalRow.accounts_with_goal) > 0
  const goal = hasGoal
    ? {
        target: round(goalRow!.target_total),
        attainment_pct: pctOrNull(goalRow!.attainment_pct),
        accounts_with_goal: Math.round(num(goalRow!.accounts_with_goal)),
        // Attainment is THIS over the target — only the accounts with a
        // goal — not the book's revenue_ytd.
        revenue_toward_goal: round(goalRow!.revenue_total),
      }
    : null
  const goalPace: GoalPace | null = hasGoal
    ? {
        expected_pct: pctOrNull(goalRow!.expected_pct),
        accounts_behind_pace: Math.round(num(goalRow!.accounts_behind)),
      }
    : null

  // A slice's `count` is the number of rows that matched before the LIMIT.
  const countOf = (res: { count?: number | null }, fallback: number) =>
    typeof res.count === 'number' ? res.count : fallback

  const topAccounts = (rows(topRes, 'v_territory_account_yoy/top') as Row[]).map((a) => slim(a))
  const moversUp = (rows(upRes, 'v_territory_account_yoy/up') as Row[]).map((a) => slim(a))
  const moversDown = (rows(downRes, 'v_territory_account_yoy/down') as Row[]).map((a) => slim(a))
  let dormantRows = rows(dormantRes, 'v_territory_account_yoy/dormant') as Row[]

  // On a night the rollups are behind, a "gone quiet" account may well have
  // invoiced since they were rebuilt. Check the facts (current) for the few
  // listed and drop any that did — never call an active account quiet.
  if (figuresBehind && figuresAsOf && dormantRows.length) {
    // deno-lint-ignore no-explicit-any
    const since = await (client as any)
      .schema('erp')
      .from('fact_invoice_line')
      .select('customer_key')
      .in('customer_key', dormantRows.map((a) => a.customer_key))
      .gt('invoice_date', figuresAsOf)
      .limit(1000)
    if (since.error) {
      console.warn('dormant re-check failed; listing none', since.error)
      dormantRows = []
    } else {
      const active = new Set((since.data ?? []).map((r: Row) => r.customer_key))
      dormantRows = dormantRows.filter((a) => !active.has(a.customer_key))
    }
  }
  const dormant = dormantRows.map((a) => slim(a, true))

  let recentOrders: Row
  if (facts) {
    const largest = (Array.isArray(facts.largest_orders) ? facts.largest_orders : []) as Row[]
    recentOrders = {
      // Every uncancelled order in the window, not the excerpt below it.
      count: Math.round(num(facts.orders_14d_count)),
      total: round(facts.orders_14d_amount),
      largest: largest.map((o) => {
        remember(o.customer_key, o.customer_name)
        return {
          customer_key: o.customer_key ?? null,
          account: o.customer_name ?? o.customer_key,
          order_date: o.order_date ?? null,
          amount: round(o.amount),
          has_open_lines: o.has_open_lines === true,
        }
      }),
    }
  } else {
    const largest = (rows(recentRes, 'v_territory_recent_orders') as Row[]).map((o) => {
      remember(o.customer_key, o.customer_name)
      return {
        customer_key: o.customer_key ?? null,
        account: o.customer_name ?? o.customer_key,
        order_date: o.order_date ?? null,
        amount: round(o.order_amount),
        has_open_lines: o.has_backlog === true,
      }
    })
    recentOrders = {
      count: countOf(recentRes, largest.length),
      // Unknown without the facts function: omitted rather than summed
      // from an excerpt.
      total: null,
      largest,
    }
  }
  // The window's start moves every day, so it rides in asOf, not the hash;
  // the count and total move only when an order enters or leaves it.
  const recentSince =
    (facts?.orders_14d_since as string | undefined) ?? shiftDays(businessDate(today), -14)

  // Product mix over the same whole months of both years, when migrated.
  const mixRows = optional(mixRes, 'report_territory_product_mix') as Row[] | null
  let products: Row
  if (mixRows && mixRows.length) {
    const first = mixRows[0]
    const mixItem = (r: Row) => ({
      revenue: round(r.revenue),
      prior_revenue: round(r.prior_revenue),
      units: round(r.qty),
      prior_units: round(r.prior_qty),
      change_pct: changePct(r.revenue, r.prior_revenue, MIN_PCT_BASE_PRODUCT),
      revenue_since_period: round(r.revenue_after_period),
    })
    products = {
      product_mix: {
        this_period: periodLabel(first.period_start, first.period_end),
        prior_period: periodLabel(first.prior_start, first.prior_end),
        // SQL orders by the larger of the two windows, so a family that
        // sold last year and nothing this year survives the cut.
        families: mixRows
          .filter((r) => r.grain === 'family')
          .slice(0, MIX_FAMILIES)
          .map((r) => ({ family: r.product_family ?? null, ...mixItem(r) })),
        products: mixRows
          .filter((r) => r.grain === 'sku')
          .map((r) => ({
            part_id: r.part_id ?? null,
            description: r.part_description ?? null,
            family: r.product_family ?? null,
            chambering: r.chambering ?? null,
            ...mixItem(r),
          })),
      },
    }
  } else {
    const slimSku = (s: Row) => ({
      part_id: s.part_id ?? null,
      description: s.part_description ?? null,
      family: s.product_family ?? null,
      chambering: s.chambering ?? null,
      revenue: round(s.revenue),
      qty: round(s.qty),
    })
    // This year so far, and ALL of last year (v_territory_sku_sales is by
    // calendar year). Different windows: the name says so, and the prompt
    // forbids comparing their dollars.
    products = {
      top_skus: (rows(skuNowRes, 'v_territory_sku_sales/now') as Row[]).map(slimSku),
      top_skus_full_last_year: (rows(skuPriorRes, 'v_territory_sku_sales/prior') as Row[]).map(slimSku),
    }
  }

  const context = {
    scope,
    // Hashed only when the figures are behind: a healthy rebuild every
    // night must not by itself make the brief "changed" (a paid
    // regeneration); a brief written on behind figures is regenerated, with
    // the note, when that changes, and again once they catch up.
    figures_as_of: figuresBehind ? figuresAsOf : null,
    figures_behind_newer_invoices: figuresBehind,
    account_count: accountCount,
    accounts_with_revenue_ytd: Math.round(num(totals.accounts_with_ytd_revenue)),
    ...(facts
      ? {
          accounts_with_revenue_prior_ytd: Math.round(num(facts.accounts_with_revenue_prior_ytd)),
          new_accounts_this_year: Math.round(num(facts.new_accounts_ytd)),
          new_accounts_revenue_ytd: round(facts.new_accounts_revenue_ytd),
        }
      : {}),
    totals: {
      revenue_ytd: round(totals.revenue_ytd),
      revenue_prior_ytd: round(totals.revenue_prior_ytd),
      revenue_change_pct: changePct(totals.revenue_ytd, totals.revenue_prior_ytd),
      revenue_trailing_12m: round(totals.revenue_trailing_12m),
      open_order_value: round(totals.open_order_value),
      past_promise_amount: round(totals.backlog_amount),
      ...(facts
        ? {
            bookings_ytd: round(facts.bookings_ytd),
            bookings_prior_ytd: round(facts.bookings_prior_ytd),
            bookings_change_pct: changePct(facts.bookings_ytd, facts.bookings_prior_ytd),
          }
        : {}),
    },
    goal,
    top_accounts: topAccounts,
    movers_up: moversUp,
    movers_up_count: countOf(upRes, moversUp.length),
    movers_down: moversDown,
    movers_down_count: countOf(downRes, moversDown.length),
    dormant,
    dormant_count: countOf(dormantRes, dormant.length),
    dormant_after_days: DORMANT_DAYS,
    ...products,
    recent_orders: recentOrders,
  }

  return {
    context,
    asOf: {
      data_through: dataThrough,
      goal_pace: goalPace,
      recent_since: recentSince,
      figures_as_of: figuresAsOf,
    },
    subjects,
  }
}

/** Whole days from an ISO date to `today` (both business-calendar dates). */
function daysSince(isoDate: unknown, today: string): number | null {
  if (typeof isoDate !== 'string' || !isoDate) return null
  const then = Date.parse(isoDate.slice(0, 10) + 'T00:00:00Z')
  const now = Date.parse(today + 'T00:00:00Z')
  if (!Number.isFinite(then) || !Number.isFinite(now)) return null
  return Math.floor((now - then) / 86_400_000)
}

/**
 * What the model reads: the hashed context plus today's figures. `today`
 * is the business (Mountain) date, the calendar every window above is in —
 * the UTC date runs a day ahead every evening, exactly when briefs
 * regenerate. data_through stays in asOf: the model has no use for the
 * warehouse watermark now that the figures carry their own date.
 */
export function territoryPromptPayload(built: TerritoryBuilt, today = new Date()): Row {
  const day = businessDate(today)
  const dormant = Array.isArray(built.context.dormant) ? (built.context.dormant as Row[]) : []
  const goal = built.context.goal as Row | null | undefined
  const recent = built.context.recent_orders as Row | undefined
  return {
    ...built.context,
    ...(recent ? { recent_orders: { since: built.asOf.recent_since ?? null, ...recent } } : {}),
    // Today's pace goes back where the prompt describes it: on `goal`.
    goal: goal ? { ...goal, ...(built.asOf.goal_pace ?? {}) } : goal,
    dormant: dormant.map((a) => ({
      ...a,
      days_since_invoice: daysSince(a.last_invoice_date, day),
    })),
    today: day,
  }
}

/*----------------------------------------------------------------------------
  The reply
----------------------------------------------------------------------------*/

/** OpenAI response_format for the territory brief (strict json_schema). */
export const TERRITORY_BRIEF_FORMAT = {
  type: 'json_schema',
  json_schema: {
    name: 'territory_brief',
    strict: true,
    schema: {
      type: 'object',
      additionalProperties: false,
      required: ['content', 'headlines'],
      properties: {
        content: {
          type: 'string',
          description:
            'The whole brief exactly as the system prompt describes it: the ' +
            'word HEADLINES on its own line, the "• " bullets, a blank line, ' +
            'then the paragraphs. No customer keys in it.',
        },
        headlines: {
          type: 'array',
          description:
            'The same headline bullets as in content, in the same order, ' +
            'without the "• ".',
          items: {
            type: 'object',
            additionalProperties: false,
            required: ['text', 'customer_key'],
            properties: {
              text: { type: 'string' },
              customer_key: {
                type: ['string', 'null'],
                description:
                  'The customer_key of the ONE account this headline is about, ' +
                  'copied exactly from the input. null when it is about the ' +
                  'territory, a product, or more than one account.',
              },
            },
          },
        },
      },
    },
  },
} as const

export type BriefHeadline = {
  text: string
  customer_key: string | null
  account_name: string | null
}

export type BriefItems = { headlines: BriefHeadline[] }

/**
 * The model's reply → what gets stored. `content` is the prose the deployed
 * frontend renders; `items` is null unless at least one usable headline came
 * back. A customer_key survives only if it was in the context (`subjects`);
 * anything else — a typo, a key from another territory, an invented one —
 * becomes null, and the headline renders without a chip.
 *
 * A reply that is not JSON at all (strict json_schema makes that close to
 * impossible) is kept as prose with no items rather than thrown away; one
 * that starts as JSON and does not parse (cut off) is an error.
 */
export function parseBriefOutput(
  text: string,
  subjects: Record<string, string>,
): { content: string; items: BriefItems | null } {
  let parsed: { content?: unknown; headlines?: unknown }
  try {
    parsed = JSON.parse(text)
  } catch {
    // Half a JSON object is a reply cut off at the token ceiling, not
    // prose: stored, the rep would read `{"content":"HEADLINES\n• …` on the
    // Overview until tomorrow. Fail it — the card keeps the last brief.
    if (text.trimStart().startsWith('{')) {
      console.error('openai returned unparseable JSON (truncated?)', text.length)
      throw new HttpError(
        502,
        'ai_truncated',
        'The brief came back cut off. Try again in a moment.',
      )
    }
    console.warn('openai returned non-JSON under json_schema; using it as prose')
    return { content: text.trim(), items: null }
  }
  if (!parsed || typeof parsed !== 'object') {
    return { content: String(text).trim(), items: null }
  }

  const content = typeof parsed.content === 'string' ? parsed.content.trim() : ''
  if (!content) {
    throw new HttpError(502, 'ai_empty', 'The brief service returned nothing.')
  }

  const headlines: BriefHeadline[] = []
  for (const h of Array.isArray(parsed.headlines) ? parsed.headlines : []) {
    if (!h || typeof h !== 'object') continue
    const rawText = (h as { text?: unknown }).text
    const lineText = typeof rawText === 'string' ? rawText.replace(/^[•\-*]\s*/, '').trim() : ''
    if (!lineText) continue
    const rawKey = (h as { customer_key?: unknown }).customer_key
    const key = typeof rawKey === 'string' && Object.hasOwn(subjects, rawKey.trim()) ? rawKey.trim() : null
    headlines.push({
      text: lineText.slice(0, 200),
      customer_key: key,
      account_name: key ? subjects[key] : null,
    })
    if (headlines.length >= MAX_HEADLINES) break
  }

  return { content, items: headlines.length ? { headlines } : null }
}
