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
  paid for a regeneration almost every morning.

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
/** Headlines kept from a reply; the prompt asks for 3 to 5. */
const MAX_HEADLINES = 5

const ACCOUNT_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, revenue_ytd, ' +
  'revenue_prior_ytd, revenue_trailing_12m, last_invoice_date, backlog_amount, ' +
  'yoy_change_amount'

/**
 * One ranked slice of the book. `customer_key` is the final ORDER BY term
 * so ties (whole pages of $0 accounts) rank deterministically — a boundary
 * row that reshuffles on identical data flips the context hash, which turns
 * a free cached return into a paid regeneration. `count: 'exact'` makes the
 * response carry the total number of matching rows, not just the slice.
 */
function accountSlice(client: SupabaseClient, sort: string, ascending: boolean) {
  return client
    .from('v_territory_account_yoy')
    .select(ACCOUNT_COLUMNS, { count: 'exact' })
    .order(sort, { ascending, nullsFirst: false })
    .order('customer_key', { ascending: true })
}

/**
 * Single-row unwrap with the same tolerance rule as rows(): only a relation
 * that is not migrated yet may be absent; anything else throws rather than
 * blanking a slice out of the hash.
 */
// deno-lint-ignore no-explicit-any
function rowOrNull(result: { data: any; error: any }, label: string): Row | null {
  return (rows(result, label) as Row[])[0] ?? null
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

export type TerritoryBuilt = {
  /** Hashed. */
  context: Row
  /** Not hashed: the clock and the warehouse watermark. */
  asOf: { data_through: string | null }
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
  const yearNow = today.getUTCFullYear()
  const cutoff90 = new Date(
    Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - DORMANT_DAYS),
  ).toISOString().slice(0, 10)

  const [
    totalsRes,
    goalRes,
    topRes,
    upRes,
    downRes,
    dormantRes,
    recentRes,
    skuNowRes,
    skuPriorRes,
    freshRes,
  ] = await Promise.all([
    // Unfiltered on purpose, here and below — RLS is the territory filter
    // (025); report_territory_summary() is security invoker for that reason.
    client.rpc('report_territory_summary').maybeSingle(),
    client
      .from('v_my_goal_rollup')
      .select('accounts_with_goal, accounts_behind, target_total, attainment_pct, expected_pct')
      .eq('period_year', yearNow)
      .maybeSingle(),
    // The ranking slice only needs its rows; the counts below are on the
    // three lists whose totals the brief reports.
    client
      .from('v_territory_account_yoy')
      .select(ACCOUNT_COLUMNS)
      .order('revenue_ytd', { ascending: false, nullsFirst: false })
      .order('customer_key', { ascending: true })
      .gt('revenue_ytd', 0)
      .limit(TOP_ACCOUNTS),
    accountSlice(client, 'yoy_change_amount', false)
      .gt('yoy_change_amount', 0)
      .limit(MOVERS),
    accountSlice(client, 'yoy_change_amount', true)
      .lt('yoy_change_amount', 0)
      .limit(MOVERS),
    // Gone quiet: meaningful trailing-12-month business, but the last
    // invoice is older than the cutoff. Biggest recent history first.
    accountSlice(client, 'revenue_trailing_12m', false)
      .lt('last_invoice_date', cutoff90)
      .gte('revenue_trailing_12m', DORMANT_MIN_TRAILING_12M)
      .limit(DORMANT),
    // Secondary sort keys everywhere a LIMIT can split a tie — same hash
    // stability reason as accountSlice().
    client
      .from('v_territory_recent_orders')
      .select('*')
      .order('order_date', { ascending: false })
      .order('order_id', { ascending: true })
      .limit(15),
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
    client.from('v_data_freshness').select('*').maybeSingle(),
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
      asOf: { data_through: null },
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
  const slim = (a: Row) => {
    remember(a.customer_key, a.customer_name)
    return {
      customer_key: a.customer_key ?? null,
      name: a.customer_name ?? a.customer_key,
      city: a.sold_to_city ?? null,
      state: a.sold_to_state ?? null,
      revenue_ytd: round(a.revenue_ytd),
      revenue_prior_ytd: round(a.revenue_prior_ytd),
      backlog_amount: round(a.backlog_amount),
      last_invoice_date: a.last_invoice_date ?? null,
    }
  }

  const slimSku = (s: Row) => ({
    part_id: s.part_id ?? null,
    description: s.part_description ?? null,
    family: s.product_family ?? null,
    chambering: s.chambering ?? null,
    revenue: round(s.revenue),
    qty: round(s.qty),
  })

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

  // The goal tile's own row. Null when no account in the book carries a
  // goal (CRM or ERP) — then `goal` is omitted rather than reported as $0.
  const goalRow = rowOrNull(goalRes, 'v_my_goal_rollup')
  const goal =
    goalRow && num(goalRow.accounts_with_goal) > 0
      ? {
          target: round(goalRow.target_total),
          attainment_pct: pctOrNull(goalRow.attainment_pct),
          expected_pct: pctOrNull(goalRow.expected_pct),
          accounts_with_goal: Math.round(num(goalRow.accounts_with_goal)),
          accounts_behind_pace: Math.round(num(goalRow.accounts_behind)),
        }
      : null

  // A slice's `count` is the number of rows that matched before the LIMIT.
  const countOf = (res: { count?: number | null }, fallback: number) =>
    typeof res.count === 'number' ? res.count : fallback

  const topAccounts = (rows(topRes, 'v_territory_account_yoy/top') as Row[]).map(slim)
  const moversUp = (rows(upRes, 'v_territory_account_yoy/up') as Row[]).map(slim)
  const moversDown = (rows(downRes, 'v_territory_account_yoy/down') as Row[]).map(slim)
  const dormant = (rows(dormantRes, 'v_territory_account_yoy/dormant') as Row[]).map(slim)

  const context = {
    account_count: accountCount,
    accounts_with_revenue_ytd: Math.round(num(totals.accounts_with_ytd_revenue)),
    totals: {
      revenue_ytd: round(totals.revenue_ytd),
      revenue_prior_ytd: round(totals.revenue_prior_ytd),
      revenue_trailing_12m: round(totals.revenue_trailing_12m),
      goal: goal ? goal.target : 0,
      open_order_value: round(totals.open_order_value),
      backlog_amount: round(totals.backlog_amount),
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
    top_skus: (rows(skuNowRes, 'v_territory_sku_sales/now') as Row[]).map(slimSku),
    top_skus_last_year: (rows(skuPriorRes, 'v_territory_sku_sales/prior') as Row[]).map(slimSku),
    recent_orders: (rows(recentRes, 'v_territory_recent_orders') as Row[]).map((o) => {
      remember(o.customer_key, o.customer_name)
      return {
        customer_key: o.customer_key ?? null,
        account: o.customer_name ?? o.customer_key,
        order_date: o.order_date ?? null,
        amount: round(o.order_amount),
        has_backlog: o.has_backlog === true,
      }
    }),
  }

  return {
    context,
    asOf: { data_through: (fresh?.data_through as string | null) ?? null },
    subjects,
  }
}

/** Whole days from an ISO date to `today`. */
function daysSince(isoDate: unknown, today: Date): number | null {
  if (typeof isoDate !== 'string' || !isoDate) return null
  const then = Date.parse(isoDate.slice(0, 10) + 'T00:00:00Z')
  if (!Number.isFinite(then)) return null
  const now = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
  return Math.floor((now - then) / 86_400_000)
}

/** What the model reads: the hashed context plus today's figures. */
export function territoryPromptPayload(built: TerritoryBuilt, today = new Date()): Row {
  const dormant = Array.isArray(built.context.dormant) ? (built.context.dormant as Row[]) : []
  return {
    ...built.context,
    dormant: dormant.map((a) => ({
      ...a,
      days_since_invoice: daysSince(a.last_invoice_date, today),
    })),
    data_through: built.asOf.data_through,
    today: today.toISOString().slice(0, 10),
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
 * impossible) is kept as prose with no items rather than thrown away.
 */
export function parseBriefOutput(
  text: string,
  subjects: Record<string, string>,
): { content: string; items: BriefItems | null } {
  let parsed: { content?: unknown; headlines?: unknown }
  try {
    parsed = JSON.parse(text)
  } catch {
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
