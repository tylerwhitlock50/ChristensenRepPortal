/*============================================================================
  021_ai_summary_batch.sql
  Purpose: Support pre-generating account summaries overnight, so the top of
           a rep's Today list carries a real briefing instead of a
           formula-built sentence.

  Two things: a headline column, and the query that decides whose summaries
  get generated.

  ── Why a headline and not the first sentence of the briefing ──────────────
  The briefing is 120-200 words, written to be read in a parking lot. A card
  on Today has room for about fifteen. Truncating prose mid-thought produces
  something worse than the deterministic reason string it replaced, so the
  model writes the short form itself, in the same call, and it is stored
  separately.

  ── Suppression: "if one is resolved it doesn't generate again" ────────────
  ai_batch_targets skips any account whose recommendation was closed or
  dismissed inside the rule cooldown window. That is the SAME setting the
  generator uses (rule_settings.*.resolve_cooldown_days, migration 020), so
  resolved work goes quiet in one place rather than two that can drift.
============================================================================*/

--------------------------------------------------------------------------
-- The short form. Nullable, no backfill: existing rows keep their briefing
-- and simply have no headline until they are next generated.
--
-- No policy or grant changes — there are no column-level grants on this
-- table, so the existing ai_summaries policies already cover it.
--------------------------------------------------------------------------
alter table public.ai_summaries
  add column if not exists headline text;

comment on column public.ai_summaries.headline is
  'One sentence, <=140 chars, produced by the same model call as `content`. '
  'Shown on the Today card in place of the rule-generated reason string.';

--------------------------------------------------------------------------
-- ai_batch_targets — whose summaries are worth paying for tonight.
--
-- For each active rep, their highest-scoring accounts that actually have
-- open work, minus anything recently resolved.
--
-- TWO THINGS THAT LOOK WRONG AND ARE NOT:
--
-- 1. v_user_accounts is `security_invoker = true`, but inside a SECURITY
--    DEFINER function current_user is the OWNER, so it resolves the whole
--    user x account map rather than one caller's book. That is exactly what
--    a job needs. If this function were ever changed to SECURITY INVOKER it
--    would silently return zero rows for the service role.
--
-- 2. `distinct on (customer_key)` is not cosmetic. An account can be top-N
--    for a rep AND for their group principal; without the dedupe the batch
--    would generate — and pay for — the same summary twice.
--------------------------------------------------------------------------
create or replace function public.ai_batch_targets(p_per_rep int default 5)
returns table (customer_key text, score numeric)
language sql
security definer set search_path = public, erp
as $$
  with cooldown as (
    -- One number for the whole batch: the longest resolve cooldown any rule
    -- is configured with. Simpler than per-rule bookkeeping here, and errs
    -- toward staying quiet, which is the intent.
    select coalesce(max((rs.params ->> 'resolve_cooldown_days')::int), 30) as days
    from public.rule_settings rs
  ),
  eligible as (
    select ua.user_id, ua.customer_key, s.score
    from public.v_user_accounts ua
    join public.profiles p
      on p.user_id = ua.user_id and p.active and p.role = 'rep'
    join public.account_signals s
      on s.customer_key = ua.customer_key
    where s.score is not null
      -- Only accounts the rep is actually being asked to work: a briefing
      -- for an account with nothing open is a briefing nobody opens.
      and exists (
        select 1 from public.recommendations r
        where r.customer_key = ua.customer_key
          and r.status in ('open', 'acted')
      )
      -- ...and not one they just finished with.
      and not exists (
        select 1 from public.recommendations r, cooldown c
        where r.customer_key = ua.customer_key
          and r.status in ('closed', 'dismissed')
          and r.closed_at is not null
          and r.closed_at > now() - make_interval(days => c.days)
      )
  ),
  ranked as (
    select e.*, row_number() over (
             partition by e.user_id
             order by e.score desc, e.customer_key) as rn
    from eligible e
  )
  select distinct on (r.customer_key) r.customer_key, r.score
  from ranked r
  where r.rn <= greatest(1, least(coalesce(p_per_rep, 5), 25))
  order by r.customer_key, r.score desc;
$$;

comment on function public.ai_batch_targets(int) is
  'The accounts tonight''s summary batch should generate: each active rep''s '
  'top N by score that have open work and were not recently resolved. Job '
  'only — the Edge Function calls it with service_role.';

-- Job-only. Nothing about this should be reachable from a browser.
revoke execute on function public.ai_batch_targets(int) from public, anon, authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Deploy the function and set its secret:
       supabase functions deploy ai-summary-batch --no-verify-jwt
       supabase secrets set AI_BATCH_SECRET=$(openssl rand -hex 32)
  2. PROMPT_VERSION goes to 2.0.0 with the headline, and the version is folded
     into the context hash — so every account re-baselines once. Only accounts
     someone opens, plus the ~5 x rep count the batch picks, not all 41k. Land
     it on a day someone is watching the OpenAI dashboard.
  3. Sanity-check the target list before wiring it into the ETL:
       select * from public.ai_batch_targets(5);
  4. Regenerate frontend/src/types/database.types.ts for the headline column.
----------------------------------------------------------------------------*/
