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

  Everything is top-N sliced and rounded: an admin's "territory" is the whole
  company, and the context must stay bounded (and cheap) even then.
----------------------------------------------------------------------------*/

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>

async function buildTerritoryContext(
  client: SupabaseClient,
  _subjectKey: string,
): Promise<BuiltContext> {
  const yearNow = new Date().getUTCFullYear()

  const [accountsRes, recentRes, skuNowRes, skuPriorRes, freshRes] =
    await Promise.all([
      // Unfiltered on purpose — RLS is the territory filter (025).
      client.from('v_territory_account_yoy').select('*'),
      client
        .from('v_territory_recent_orders')
        .select('*')
        .order('order_date', { ascending: false })
        .limit(15),
      client
        .from('v_territory_sku_sales')
        .select('part_id, part_description, product_family, chambering, revenue, qty')
        .eq('sales_year', yearNow)
        .order('revenue', { ascending: false })
        .limit(15),
      client
        .from('v_territory_sku_sales')
        .select('part_id, part_description, product_family, chambering, revenue, qty')
        .eq('sales_year', yearNow - 1)
        .order('revenue', { ascending: false })
        .limit(15),
      client.from('v_data_freshness').select('*').maybeSingle(),
    ])

  const accounts = rows(accountsRes, 'v_territory_account_yoy') as Row[]

  if (accounts.length === 0) {
    return {
      context: {},
      insufficient: {
        message: 'No accounts in this territory yet.',
        reason: 'empty_book',
      },
    }
  }

  const num = (v: unknown) => {
    const n = Number(v ?? 0)
    return Number.isFinite(n) ? n : 0
  }

  const totals = {
    revenue_ytd: 0,
    revenue_prior_ytd: 0,
    goal: 0,
    open_order_value: 0,
    backlog_amount: 0,
  }
  for (const a of accounts) {
    totals.revenue_ytd += num(a.revenue_ytd)
    totals.revenue_prior_ytd += num(a.revenue_prior_ytd)
    totals.goal += num(a.yearly_sales_goal)
    totals.open_order_value += num(a.open_order_value)
    totals.backlog_amount += num(a.backlog_amount)
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

  const byDelta = [...accounts].sort(
    (a, b) =>
      num(b.revenue_ytd) - num(b.revenue_prior_ytd) -
      (num(a.revenue_ytd) - num(a.revenue_prior_ytd)),
  )
  const moversUp = byDelta
    .filter((a) => num(a.revenue_ytd) > num(a.revenue_prior_ytd))
    .slice(0, 5)
    .map(slim)
  const moversDown = byDelta
    .filter((a) => num(a.revenue_ytd) < num(a.revenue_prior_ytd))
    .reverse()
    .slice(0, 5)
    .map(slim)

  const cutoff90 = isoDaysAgo(90)
  const today = new Date()
  const dormant = accounts
    .filter(
      (a) =>
        a.last_invoice_date &&
        String(a.last_invoice_date) < cutoff90 &&
        num(a.revenue_trailing_12m) >= 5_000,
    )
    .sort((a, b) => num(b.revenue_trailing_12m) - num(a.revenue_trailing_12m))
    .slice(0, 5)
    .map((a) => ({
      ...slim(a),
      days_since_invoice: Math.floor(
        (today.getTime() - new Date(String(a.last_invoice_date)).getTime()) /
          86_400_000,
      ),
    }))

  const topAccounts = [...accounts]
    .sort((a, b) => num(b.revenue_ytd) - num(a.revenue_ytd))
    .slice(0, 10)
    .map(slim)

  const slimSku = (s: Row) => ({
    part_id: s.part_id ?? null,
    description: s.part_description ?? null,
    family: s.product_family ?? null,
    chambering: s.chambering ?? null,
    revenue: round(s.revenue),
    qty: round(s.qty),
  })

  const fresh = (freshRes.data ?? null) as Row | null

  const context = {
    account_count: accounts.length,
    totals: {
      revenue_ytd: round(totals.revenue_ytd),
      revenue_prior_ytd: round(totals.revenue_prior_ytd),
      goal: round(totals.goal),
      open_order_value: round(totals.open_order_value),
      backlog_amount: round(totals.backlog_amount),
    },
    top_accounts: topAccounts,
    movers_up: moversUp,
    movers_down: moversDown,
    dormant,
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
