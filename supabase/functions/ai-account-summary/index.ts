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

  ── Steps 4, 6 and 8 now live in _shared/ ──────────────────────────────────
  ai-summary-batch pre-generates summaries overnight and has to build a
  byte-identical context, or the context hash stops meaning anything: the
  same unchanged account would look "changed" to one path and cached to the
  other, and they would take turns paying to overwrite each other. Shared
  modules make that impossible rather than merely unlikely.

  PII (TECH_STACK §5.1) is enforced in _shared/accountContext.ts: no
  public.contacts at all, and no author identity on notes, visits or actions.
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
  callOpenAI,
  envInt,
  INSUFFICIENT_DATA_MESSAGE,
  MODEL,
  prepareContext,
  PROMPT_VERSION,
  type SummaryRow,
} from '../_shared/aiSummary.ts'

/**
 * Re-exported so the prompt version stays importable from this entrypoint.
 * It is defined next to the prompt text in prompt.ts, which is what makes the
 * two impossible to desync.
 */
export { PROMPT_VERSION }

/** "An internal tool with an unmetered LLM button is a bill waiting to happen." */
const DAILY_LIMIT = envInt('AI_SUMMARY_DAILY_LIMIT', 25)

/**
 * Second half of the cost ceiling. The context hash makes an unchanged
 * regenerate free, but a rep who adds a note and regenerates in a loop would
 * change the hash every time. One paid generation per account per cooldown
 * window bounds that without needing a new table.
 */
const COOLDOWN_SECONDS = envInt('AI_SUMMARY_COOLDOWN_SECONDS', 60)

type RequestBody = { customer_key?: string }
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
  const access = await client.rpc('has_account_access', { p_customer_key: customerKey })
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

  const prepared = await prepareContext(client, customerKey)

  /*
    Graceful degradation, before a single token is spent (PRD acceptance
    criterion #7). A brand-new dealer with two invoice lines and no notes has
    nothing to summarise, and paying OpenAI to say so would be silly.
  */
  if (prepared.insufficient) {
    return respond('insufficient_data', null, {
      message: INSUFFICIENT_DATA_MESSAGE,
      reason: 'not_enough_activity',
    })
  }

  // Nothing changed → return the cached copy instantly and for free.
  if (existing && existing.context_hash === prepared.contextHash) {
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
    Per-user daily cap. Counted off ai_summaries rather than a dedicated
    counter table so this function needs no schema of its own; the honest
    limitation is that it counts DISTINCT ACCOUNTS summarised today, not total
    generations (the table is one row per account). The cooldown above bounds
    repeat generations on a single account, so the two together bound spend.

    Batch rows carry generated_by = null, so an overnight run never eats into
    anyone's allowance.
  */
  if (DAILY_LIMIT > 0) {
    const startOfDay = new Date()
    startOfDay.setUTCHours(0, 0, 0, 0)
    const usage = await client
      .from('ai_summaries')
      .select('customer_key', { count: 'exact', head: true })
      .eq('generated_by', caller.id)
      .gte('generated_at', startOfDay.toISOString())

    if (!usage.error && (usage.count ?? 0) >= DAILY_LIMIT) {
      throw new HttpError(
        429,
        'daily_limit_reached',
        `You have generated ${DAILY_LIMIT} summaries today. ` +
          'Cached summaries are still available.',
      )
    }
  }

  const briefing = await callOpenAI(prepared.contextJson)

  const row: SummaryRow = {
    customer_key: customerKey,
    content: briefing.briefing,
    headline: briefing.headline || null,
    model: MODEL,
    context_hash: prepared.contextHash,
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
    return respond('generated', row, { cached: false })
  }

  console.log('summary generated', {
    customer_key: customerKey,
    revenue_source: prepared.built.revenueSource,
    invoice_lines: prepared.built.invoiceLineCount,
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
