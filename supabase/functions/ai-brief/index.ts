/*============================================================================
  ai-brief — the AI Actions endpoint (one function, a whitelisted registry).

  Product rule: AI interactions are DETERMINISTIC ACTIONS over the data the
  user is currently viewing — 'territory.brief' today; 'territory.revenue',
  'intel.backlog', 'account.buying_pattern' tomorrow. The client sends an
  action name and (optionally) a subject key, never a prompt. Unknown
  action → 400. Adding an action is a registry entry below plus a button in
  the client; no new function, no schema change.

  Inherited architecture from ai-account-summary, unchanged on purpose:

  - The caller's JWT, never service_role. Every context query below runs
    under the caller's own RLS, so a territory brief is by construction the
    caller's book and nothing else — there is no separate access check to
    get wrong.
  - The four-stage cost ladder, per (user, action, subject):
      1. degradation gate (empty book → insufficient_data, zero tokens)
      2. context hash (unchanged data → cached row, free — this is what
         makes the Overview's auto-generate-each-morning safe)
      3. cooldown (default 300s, AI_BRIEF_COOLDOWN_SECONDS)
      4. daily cap counted from public.ai_usage_events (the honest
         per-generation ledger 028 added; AI_BRIEF_DAILY_LIMIT, default 25)
  - Prompts are modules with versions folded into the hash.

  Storage: public.ai_briefs, PK (user_id, action, subject_key). RLS lets the
  caller write only their own rows.
============================================================================*/

import { fail, json, preflight } from '../_shared/cors.ts'
import {
  HttpError,
  readJson,
  requireCaller,
  requirePost,
  userClient,
} from '../_shared/supabase.ts'
import {
  MODEL,
  callOpenAI,
  canonical,
  envInt,
  isMissingRelation,
  isoDaysAgo,
  round,
  rows,
  sha256Hex,
} from '../_shared/ai.ts'
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { TERRITORY_BRIEF_PROMPT, TERRITORY_BRIEF_VERSION } from './prompts.ts'

const COOLDOWN_SECONDS = envInt('AI_BRIEF_COOLDOWN_SECONDS', 300)
const DAILY_LIMIT = envInt('AI_BRIEF_DAILY_LIMIT', 25)

/*----------------------------------------------------------------------------
  Action registry
----------------------------------------------------------------------------*/

type BuiltContext = {
  context: unknown
  /** When set, respond insufficient_data without spending a token. */
  insufficient?: { message: string; reason: string }
}

type ActionDef = {
  promptVersion: string
  systemPrompt: string
  /** The user-turn framing line ahead of the JSON context. */
  userIntro: string
  buildContext: (client: SupabaseClient, subjectKey: string) => Promise<BuiltContext>
}

const ACTIONS: Record<string, ActionDef> = {
  'territory.brief': {
    promptVersion: TERRITORY_BRIEF_VERSION,
    systemPrompt: TERRITORY_BRIEF_PROMPT,
    userIntro: 'Write the morning territory briefing.',
    buildContext: buildTerritoryContext,
  },
}

/*----------------------------------------------------------------------------
  territory.brief context — the caller's whole book, compact.

  Ranking and totals happen IN POSTGRES, the same way the mcp function's
  get_territory_summary does it (see mcp/tools.ts):

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
----------------------------------------------------------------------------*/

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>

/** How many accounts each highlight list names. */
const TOP_ACCOUNTS = 10
const MOVERS = 5
const DORMANT = 5
/** "Dormant": nothing invoiced in this many days, with real recent history. */
const DORMANT_DAYS = 90
const DORMANT_MIN_TRAILING_12M = 5_000

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

async function buildTerritoryContext(
  client: SupabaseClient,
  _subjectKey: string,
): Promise<BuiltContext> {
  const yearNow = new Date().getUTCFullYear()
  const cutoff90 = isoDaysAgo(DORMANT_DAYS)

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
    accountSlice(client, 'revenue_ytd', false).gt('revenue_ytd', 0).limit(TOP_ACCOUNTS),
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
      insufficient: {
        message: 'No accounts in this territory yet.',
        reason: 'empty_book',
      },
    }
  }

  const slim = (a: Row) => ({
    name: a.customer_name ?? a.customer_key,
    city: a.sold_to_city ?? null,
    state: a.sold_to_state ?? null,
    revenue_ytd: round(a.revenue_ytd),
    revenue_prior_ytd: round(a.revenue_prior_ytd),
    backlog_amount: round(a.backlog_amount),
    last_invoice_date: a.last_invoice_date ?? null,
  })

  const today = new Date()
  const dormant = (rows(dormantRes, 'v_territory_account_yoy/dormant') as Row[]).map(
    (a) => ({
      ...slim(a),
      days_since_invoice: Math.floor(
        (today.getTime() - new Date(String(a.last_invoice_date)).getTime()) /
          86_400_000,
      ),
    }),
  )

  const slimSku = (s: Row) => ({
    part_id: s.part_id ?? null,
    description: s.part_description ?? null,
    family: s.product_family ?? null,
    chambering: s.chambering ?? null,
    revenue: round(s.revenue),
    qty: round(s.qty),
  })

  // Same rule as rows(): only a not-yet-migrated view may go missing
  // silently — a real error must not blank data_through out of the hash.
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
    recent_orders: (rows(recentRes, 'v_territory_recent_orders') as Row[]).map((o) => ({
      account: o.customer_name ?? o.customer_key,
      order_date: o.order_date ?? null,
      amount: round(o.order_amount),
      has_backlog: o.has_backlog === true,
    })),
    data_through: fresh?.data_through ?? null,
  }

  return { context }
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

/*----------------------------------------------------------------------------
  Handler
----------------------------------------------------------------------------*/

type RequestBody = { action?: string; subject_key?: string }

type BriefRow = {
  user_id: string
  action: string
  subject_key: string
  content: string
  model: string | null
  context_hash: string | null
  prompt_version: string | null
  generated_at: string
}

type Status = 'generated' | 'cached' | 'cooldown' | 'insufficient_data'

function respond(status: Status, brief: BriefRow | null, extra = {}) {
  return json({ status, brief, ...extra })
}

async function handle(req: Request): Promise<Response> {
  requirePost(req)

  const body = await readJson<RequestBody>(req)
  const actionKey = (body.action ?? '').trim()
  const subjectKey = (body.subject_key ?? '').trim()

  const action = ACTIONS[actionKey]
  if (!action) {
    // Deterministic by design — an unknown action is a client bug, not a
    // prompt to improvise with.
    throw new HttpError(400, 'unknown_action', `Unknown action: ${actionKey || '(none)'}`)
  }

  // The caller's JWT, forwarded. RLS applies to everything below — which is
  // the whole access story: territory context is the caller's book because
  // Postgres says so, not because this file filtered it.
  const client = userClient(req)
  const caller = await requireCaller(client)

  const existingRes = await client
    .from('ai_briefs')
    .select('*')
    .eq('user_id', caller.id)
    .eq('action', actionKey)
    .eq('subject_key', subjectKey)
    .maybeSingle()
  const existing = (existingRes.data ?? null) as BriefRow | null

  const built = await action.buildContext(client, subjectKey)

  if (built.insufficient) {
    return respond('insufficient_data', null, built.insufficient)
  }

  // Prompt version and model in the hash: tuning either re-baselines every
  // cached brief for this action exactly once.
  const contextJson = JSON.stringify(canonical(built.context))
  const contextHash = await sha256Hex(
    JSON.stringify({
      action: actionKey,
      prompt_version: action.promptVersion,
      model: MODEL,
      context: contextJson,
    }),
  )

  // Nothing changed → the cached copy, instantly and for free. The Overview
  // auto-generates every morning on the strength of this line.
  if (existing && existing.context_hash === contextHash) {
    return respond('cached', existing)
  }

  if (existing && COOLDOWN_SECONDS > 0) {
    const ageMs = Date.now() - new Date(existing.generated_at).getTime()
    if (ageMs >= 0 && ageMs < COOLDOWN_SECONDS * 1000) {
      return respond('cooldown', existing, {
        retry_after_seconds: Math.ceil((COOLDOWN_SECONDS * 1000 - ageMs) / 1000),
      })
    }
  }

  // Per-user daily cap over ALL paid generations (every action), counted
  // from the ai_usage_events ledger.
  if (DAILY_LIMIT > 0) {
    const startOfDay = new Date()
    startOfDay.setUTCHours(0, 0, 0, 0)
    const usage = await client
      .from('ai_usage_events')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', caller.id)
      .gte('created_at', startOfDay.toISOString())

    if (!usage.error && (usage.count ?? 0) >= DAILY_LIMIT) {
      throw new HttpError(
        429,
        'daily_limit_reached',
        `You have generated ${DAILY_LIMIT} briefs today. Cached briefs are still available.`,
      )
    }
  }

  const content = await callOpenAI(
    action.systemPrompt,
    `${action.userIntro}\n\n<context>\n${contextJson}\n</context>`,
  )

  // Ledger first, tolerantly — a failed usage insert must not discard a paid
  // generation, but a silent skip would also unmeter the cap, so log loudly.
  const usageInsert = await client
    .from('ai_usage_events')
    .insert({ user_id: caller.id, action: actionKey })
  if (usageInsert.error) {
    console.error('ai_usage_events insert failed', usageInsert.error)
  }

  const row: BriefRow = {
    user_id: caller.id,
    action: actionKey,
    subject_key: subjectKey,
    content,
    model: MODEL,
    context_hash: contextHash,
    prompt_version: action.promptVersion,
    generated_at: new Date().toISOString(),
  }

  const saved = await client
    .from('ai_briefs')
    .upsert(row, { onConflict: 'user_id,action,subject_key' })
    .select('*')
    .single()

  if (saved.error) {
    // The brief is good even if caching it failed; hand it back rather than
    // throwing away a paid call.
    console.error('ai_briefs upsert failed', saved.error)
    return respond('generated', row, { cached: false })
  }

  console.log('brief generated', { action: actionKey, user: caller.id })
  return respond('generated', saved.data as BriefRow, { cached: true })
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
    console.error('ai-brief unhandled error', err)
    return fail(500, 'internal_error', 'Could not build the brief.')
  }
})
