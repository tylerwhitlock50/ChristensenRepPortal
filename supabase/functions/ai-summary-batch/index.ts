/*============================================================================
  ai-summary-batch

  Pre-generates account briefings overnight so the top of a rep's Today list
  carries a real summary instead of a formula-built sentence.

  Justification for existing at all (TECH_STACK §3.2, and the bar set in
  functions/README.md): it holds OPENAI_API_KEY. A Postgres function cannot.

  ── THIS FUNCTION USES service_role. Here is why that is not the thing the
     architecture forbids. ────────────────────────────────────────────────

  ai-account-summary's header is emphatic that it must never import
  serviceClient(), and it must not. But read the invariant precisely: the ban
  is on a server reading account data ON BEHALF OF A REP and handing back the
  result, because that moves the access decision out of Postgres and into
  TypeScript, where it eventually leaks.

  A nightly batch has no caller. It answers no browser, returns no account
  data — only counts — and writes rows to public.ai_summaries, whose read
  path is still `customer_key in (select public.my_customer_keys())`. A
  summary written for an account outside a rep's book is invisible to that
  rep, enforced by the same policy that protects everything else.

  ── The subtlety that makes it safe, and would have been the leak if it were
     false ────────────────────────────────────────────────────────────────

  buildContext() reads notes, visits, actions and recommendations filtered
  only by customer_key. Under service_role those reads are unscoped. That is
  acceptable ONLY because every one of those policies is ACCOUNT-scoped, not
  AUTHOR-scoped: any rep who can see the account can already see all of its
  notes. So the batch context is byte-identical to what the assigned rep
  would have built themselves — which is also what keeps the shared context
  hash meaningful across both paths.

  If a per-author policy is ever added to public.notes, that equivalence
  breaks and this function must be revisited.

  ── The guards, all five ───────────────────────────────────────────────────

  1. No JWT path at all. A constant-time match on x-batch-secret against
     AI_BATCH_SECRET, and nothing else gets in. requireCaller() is never
     called; there is no user here.
  2. It cannot be pointed at an account. The request body carries no
     customer_key — targets come only from public.ai_batch_targets(). Even
     with a leaked secret this is not an exfiltration oracle: it returns
     counts, never account data.
  3. Hard caps: AI_BATCH_MAX_ACCOUNTS, bounded concurrency, per-account
     try/catch so one failure cannot take down the run, and a job_runs row.
  4. generated_by = null, so batch rows are distinguishable from
     rep-triggered ones and never consume anyone's daily allowance.
  5. service_role is used for exactly two things: calling ai_batch_targets()
     and upserting ai_summaries. Context building goes through the same
     shared module the interactive path uses.

  Rejected alternative: minting JWTs to impersonate each rep. It needs the
  JWT secret, attributes audit rows to people who did nothing, and STILL puts
  the access decision in TypeScript — strictly worse than an honest,
  documented, narrow exception.

  ── Small calls, repeated (20261013140000) ─────────────────────────────────
  One request used to try every target (up to 100 model calls) and reply at
  the end — far past an Edge Function's wall-clock limit, so a long run was
  cut off before it logged anything. Now each call does a bounded slice and
  the ETL repeats it (etl/views.yml `repeat_until_idle`) while the reply says
  `generated > 0`. Three things make that converge:

    - ai_batch_targets() leaves out accounts summarised in the last 20 hours
      BEFORE the per-rep cap, and this function filters them again before
      slicing (the same rule, for a database that still has 021's version),
      so a repeat call sees the next accounts, not the same top N;
    - every account this function finishes — generated, cached (unchanged),
      insufficient or failed — is stamped in public.ai_batch_checks, which
      ai_batch_targets() also leaves out for 20 hours. Without it an
      unchanged or failing account wrote nothing, kept its rep's top slots
      on every repeat call, and a failing one was paid for again each time.
      The reply's `checked` counts those stamps, and the ETL keeps calling
      while `generated + checked > 0`: a call that only confirmed unchanged
      accounts still moved down the list;
    - `max_accounts` caps PAID generations per call, not accounts looked at:
      an unchanged account comes back 'cached' for the price of its reads
      and does not use up the call, so a run of unchanged accounts at the
      top cannot end the night early;
    - a time budget (AI_BATCH_TIME_BUDGET_SECONDS, default 75) after which
      no new account is started, leaving room for the ones in flight under
      the 150 s request limit.

  Targets are worked in the function's order — round-robin across reps,
  each rep's highest score first — so a call cut short by its allowance has
  spent it on every rep's top accounts, not on whichever books score
  highest.

  ── Invoking it ────────────────────────────────────────────────────────────
      curl -X POST "$SUPABASE_URL/functions/v1/ai-summary-batch" \
        -H "x-batch-secret: $AI_BATCH_SECRET" \
        -H 'content-type: application/json' -d '{"per_rep":5,"max_accounts":15}'
============================================================================*/

import { fail, json, preflight } from '../_shared/cors.ts'
import { HttpError, readJson, requirePost, serviceClient } from '../_shared/supabase.ts'
import {
  callOpenAI,
  envInt,
  MODEL,
  prepareContext,
  PROMPT_VERSION,
} from '../_shared/aiSummary.ts'

const DEFAULT_PER_REP = envInt('AI_BATCH_PER_REP', 5)
/** Paid generations per call (see header). The ETL sends 15. */
const MAX_ACCOUNTS = envInt('AI_BATCH_MAX_ACCOUNTS', 100)
const CONCURRENCY = Math.max(1, envInt('AI_BATCH_CONCURRENCY', 3))
/** No new account starts after this; in-flight ones finish (≤ 60 s each). */
const TIME_BUDGET_MS = envInt('AI_BATCH_TIME_BUDGET_SECONDS', 75) * 1000

/**
 * Skip an account whose summary is already younger than this. The context
 * hash makes an unchanged account free anyway, but this avoids even building
 * the context for the ones a rep regenerated by hand this morning.
 */
const MIN_AGE_HOURS = envInt('AI_BATCH_MIN_AGE_HOURS', 20)

/**
 * Timing-safe compare. `===` on secrets leaks length and prefix through
 * response timing; it is one function to avoid that, so avoid it.
 */
function secretMatches(provided: string, expected: string): boolean {
  if (provided.length !== expected.length) return false
  let diff = 0
  for (let i = 0; i < provided.length; i++) {
    diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i)
  }
  return diff === 0
}

type RequestBody = { per_rep?: number; max_accounts?: number }

type Outcome = 'generated' | 'cached' | 'skipped' | 'insufficient' | 'failed' | 'deferred'

/**
 * The per-call budget of paid generations, shared by the pool's workers.
 * Claimed only once an account is known to need a model call, so cached
 * and insufficient accounts never spend it.
 */
type Budget = { paid: number; cap: number; deadline: number }

function isFresh(generatedAt: string | null | undefined): boolean {
  if (!generatedAt || MIN_AGE_HOURS <= 0) return false
  const ageHours = (Date.now() - new Date(generatedAt).getTime()) / 3_600_000
  return ageHours >= 0 && ageHours < MIN_AGE_HOURS
}

async function generateFor(
  client: ReturnType<typeof serviceClient>,
  customerKey: string,
  budget: Budget,
): Promise<Outcome> {
  const existing = await client
    .from('ai_summaries')
    .select('context_hash, generated_at')
    .eq('customer_key', customerKey)
    .maybeSingle()

  const row = existing.data as { context_hash: string | null; generated_at: string } | null

  // A rep may have generated it since the target list was read.
  if (row && isFresh(row.generated_at)) return 'skipped'

  const prepared = await prepareContext(client, customerKey)
  if (prepared.insufficient) return 'insufficient'

  // Unchanged since last time → nothing to pay for.
  if (row && row.context_hash === prepared.contextHash) return 'cached'

  // Needs a model call. Leave it for the next call if this one has spent
  // its allowance or its time.
  if (budget.paid >= budget.cap || Date.now() > budget.deadline) return 'deferred'
  budget.paid += 1

  const briefing = await callOpenAI(prepared.promptJson)

  const { error } = await client.from('ai_summaries').upsert(
    {
      customer_key: customerKey,
      content: briefing.briefing,
      headline: briefing.headline || null,
      model: MODEL,
      context_hash: prepared.contextHash,
      prompt_version: PROMPT_VERSION,
      generated_at: new Date().toISOString(),
      // Not attributed to a person: nobody asked for it, and it must not
      // count against anyone's daily cap.
      generated_by: null,
    },
    { onConflict: 'customer_key' },
  )
  if (error) throw error

  return 'generated'
}

/** Fixed-size worker pool. Deliberately not Promise.all over the whole list:
    100 concurrent OpenAI calls is how a nightly job earns a rate limit.
    Workers stop taking accounts once the budget's allowance or time is
    gone; whatever is left is reported as `remaining`. */
async function runPool(
  keys: string[],
  worker: (key: string) => Promise<Outcome>,
  size: number,
  budget: Budget,
): Promise<Record<Outcome, number> & { taken: number; remaining: number }> {
  const tally: Record<Outcome, number> = {
    generated: 0, cached: 0, skipped: 0, insufficient: 0, failed: 0, deferred: 0,
  }
  let next = 0
  const spent = () => budget.paid >= budget.cap || Date.now() > budget.deadline

  async function pump(): Promise<void> {
    while (next < keys.length && !spent()) {
      const key = keys[next++]
      try {
        tally[await worker(key)] += 1
      } catch (err) {
        // One bad account must not end the run — the other ninety-nine reps
        // still want their briefings in the morning.
        tally.failed += 1
        console.error('batch: account failed', key, err)
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(size, keys.length) }, () => pump()))
  // Deferred accounts were looked at but not paid for: still to do.
  return { ...tally, taken: next, remaining: keys.length - next + tally.deferred }
}

/**
 * Remember that tonight's run looked at this account, whatever came of it
 * (ai_batch_checks, 20261013140000) — see the header. False when the stamp
 * could not be written (a database without the table): the reply's
 * `checked` then stays 0 and the ETL repeats on `generated` alone, as
 * before, instead of re-reading the same accounts eight times.
 */
async function markChecked(
  client: ReturnType<typeof serviceClient>,
  customerKey: string,
  outcome: Outcome,
): Promise<boolean> {
  const { error } = await client.from('ai_batch_checks').upsert(
    { customer_key: customerKey, outcome, checked_at: new Date().toISOString() },
    { onConflict: 'customer_key' },
  )
  if (error) {
    console.warn('batch: could not stamp ai_batch_checks', customerKey, error)
    return false
  }
  return true
}

/**
 * Drop targets whose summary is younger than MIN_AGE_HOURS, BEFORE the
 * cap: 20261013140000's ai_batch_targets() already does, 021's did not,
 * and without this a repeat call against the old function would spend its
 * whole slice re-reading the accounts the previous call just wrote.
 */
async function withoutFresh(
  client: ReturnType<typeof serviceClient>,
  keys: string[],
): Promise<string[]> {
  if (keys.length === 0 || MIN_AGE_HOURS <= 0) return keys
  const fresh = new Set<string>()
  for (let i = 0; i < keys.length; i += 200) {
    const chunk = keys.slice(i, i + 200)
    const { data, error } = await client
      .from('ai_summaries')
      .select('customer_key, generated_at')
      .in('customer_key', chunk)
    if (error) {
      // Not fatal: generateFor() checks each account's age again.
      console.warn('batch: freshness pre-filter failed', error)
      return keys
    }
    for (const r of (data ?? []) as { customer_key: string; generated_at: string }[]) {
      if (isFresh(r.generated_at)) fresh.add(r.customer_key)
    }
  }
  return keys.filter((k) => !fresh.has(k))
}

async function handle(req: Request): Promise<Response> {
  requirePost(req)

  const expected = Deno.env.get('AI_BATCH_SECRET') ?? ''
  if (!expected) {
    throw new HttpError(500, 'missing_env',
      'AI_BATCH_SECRET is not set on this function. Refusing to run unauthenticated.')
  }
  const provided = req.headers.get('x-batch-secret') ?? ''
  if (!secretMatches(provided, expected)) {
    throw new HttpError(401, 'bad_secret', 'Invalid batch secret.')
  }

  const body = await readJson<RequestBody>(req).catch(() => ({}) as RequestBody)
  const perRep = Math.max(1, Math.min(Number(body.per_rep) || DEFAULT_PER_REP, 25))
  const cap = Math.max(1, Math.min(Number(body.max_accounts) || MAX_ACCOUNTS, 500))

  const client = serviceClient()
  const started = new Date().toISOString()

  const targets = await client.rpc('ai_batch_targets', { p_per_rep: perRep })
  if (targets.error) {
    console.error('ai_batch_targets failed', targets.error)
    throw new HttpError(500, 'targets_failed', 'Could not resolve the target accounts.')
  }

  // In the order the function returns them: round-robin across reps
  // (every rep's #1, then every rep's #2, ...), so a call that runs out of
  // allowance has spent it fairly. Re-sorting by score here would hand
  // every call to the books with the highest scores. (021's version
  // returns key order; it only runs until 20261013140000 is applied.)
  const ranked = ((targets.data ?? []) as { customer_key: string }[]).map((r) => r.customer_key)
  const keys = await withoutFresh(client, ranked)

  const budget: Budget = { paid: 0, cap, deadline: Date.parse(started) + TIME_BUDGET_MS }
  let checked = 0
  const { taken, ...tally } = await runPool(
    keys,
    async (k) => {
      // 'failed' unless generateFor returns: a throw is stamped too, so a
      // broken account is not paid for again by tonight's next call.
      let outcome: Outcome = 'failed'
      try {
        outcome = await generateFor(client, k, budget)
        return outcome
      } finally {
        // Deferred (no allowance left) and skipped (fresh) are not done.
        if (outcome !== 'deferred' && outcome !== 'skipped') {
          if (await markChecked(client, k, outcome)) checked += 1
        }
      }
    },
    CONCURRENCY,
    budget,
  )

  // `generated + checked` is what the ETL's repeat_until_idle reads: 0 means
  // this call found nothing left to look at.
  const summary = {
    targets: ranked.length,
    fresh: ranked.length - keys.length,
    attempted: taken,
    checked,
    ...tally,
  }
  // Never let a cap silently look like full coverage.
  if (tally.remaining > 0) {
    console.warn(`batch: ${tally.remaining} target accounts left for the next call`)
  }
  console.log('batch complete', summary)

  await client.rpc('log_job_run', {
    p_job_name: 'ai_summary_batch',
    p_status: tally.failed > 0 && tally.generated === 0 ? 'error' : 'success',
    p_rows: tally.generated,
    p_error: tally.failed > 0 ? `${tally.failed} accounts failed` : null,
    p_started_at: started,
  })

  return json(summary)
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
    console.error('ai-summary-batch unhandled error', err)
    return fail(500, 'internal_error', 'The batch run failed.')
  }
})
