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

  An action's context, prompt payload and reply parsing live in their own
  module (territory.ts for 'territory.brief') so they can be tested without
  starting this server. Since 2.0.0 the territory brief comes back as strict
  JSON — the same prose `content` as always, plus headlines tagged with the
  account they are about, validated against the context and stored in
  ai_briefs.items (20261013140001). On a database without that column the
  row is stored without it and the client keeps rendering prose.
============================================================================*/

import { fail, json, preflight } from '../_shared/cors.ts'
import {
  HttpError,
  readJson,
  requireCaller,
  requirePost,
  userClient,
} from '../_shared/supabase.ts'
import { MODEL, callOpenAI, canonical, envInt, sha256Hex } from '../_shared/ai.ts'
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { TERRITORY_BRIEF_PROMPT, TERRITORY_BRIEF_VERSION } from './prompts.ts'
import {
  type BriefItems,
  buildTerritoryContext,
  parseBriefOutput,
  TERRITORY_BRIEF_FORMAT,
  type TerritoryBuilt,
  territoryPromptPayload,
} from './territory.ts'

const COOLDOWN_SECONDS = envInt('AI_BRIEF_COOLDOWN_SECONDS', 300)
const DAILY_LIMIT = envInt('AI_BRIEF_DAILY_LIMIT', 25)

/*----------------------------------------------------------------------------
  Action registry
----------------------------------------------------------------------------*/

type BuiltContext = TerritoryBuilt

type ActionDef = {
  promptVersion: string
  systemPrompt: string
  /** The user-turn framing line ahead of the JSON context. */
  userIntro: string
  buildContext: (client: SupabaseClient, subjectKey: string, today: Date) => Promise<BuiltContext>
  /** The model's input: the hashed context plus whatever moves with the clock. */
  promptPayload: (built: BuiltContext, today: Date) => unknown
  /** OpenAI response_format; the reply is then parsed by parseOutput. */
  responseFormat?: Record<string, unknown>
  parseOutput?: (text: string, built: BuiltContext) => { content: string; items: BriefItems | null }
}

const ACTIONS: Record<string, ActionDef> = {
  'territory.brief': {
    promptVersion: TERRITORY_BRIEF_VERSION,
    systemPrompt: TERRITORY_BRIEF_PROMPT,
    userIntro: 'Write the morning territory briefing.',
    buildContext: buildTerritoryContext,
    promptPayload: territoryPromptPayload,
    responseFormat: TERRITORY_BRIEF_FORMAT,
    parseOutput: (text, built) => parseBriefOutput(text, built.subjects),
  },
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
  /** Structured headlines (20261013140001); absent on an older database. */
  items?: BriefItems | null
  model: string | null
  context_hash: string | null
  prompt_version: string | null
  generated_at: string
}

/** PostgREST's answer to a write naming a column the table lacks. */
// deno-lint-ignore no-explicit-any
function isMissingColumn(error: any): boolean {
  return (
    String(error?.code ?? '') === 'PGRST204' ||
    String(error?.code ?? '') === '42703' ||
    /could not find the '.*' column/i.test(String(error?.message ?? ''))
  )
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

  const today = new Date()
  const built = await action.buildContext(client, subjectKey, today)

  if (built.insufficient) {
    return respond('insufficient_data', null, built.insufficient)
  }

  // Prompt version and model in the hash: tuning either re-baselines every
  // cached brief for this action exactly once. The hash covers the data
  // only — never today's date or day counts (see territory.ts).
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

  const promptJson = JSON.stringify(canonical(action.promptPayload(built, today)))
  const reply = await callOpenAI(
    action.systemPrompt,
    `${action.userIntro}\n\n<context>\n${promptJson}\n</context>`,
    action.responseFormat,
  )
  const { content, items } = action.parseOutput
    ? action.parseOutput(reply, built)
    : { content: reply, items: null }

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
    items,
    model: MODEL,
    context_hash: contextHash,
    prompt_version: action.promptVersion,
    generated_at: new Date().toISOString(),
  }

  const upsert = (r: BriefRow) =>
    client
      .from('ai_briefs')
      .upsert(r, { onConflict: 'user_id,action,subject_key' })
      .select('*')
      .single()

  let saved = await upsert(row)
  if (saved.error && isMissingColumn(saved.error)) {
    // A database without 20261013140001: store the prose alone. The client
    // renders prose whenever items is absent.
    const { items: _dropped, ...withoutItems } = row
    saved = await upsert(withoutItems)
  }

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
