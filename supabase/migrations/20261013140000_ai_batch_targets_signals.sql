/*============================================================================
  20261013140000_ai_batch_targets_signals.sql
  Purpose: Point the nightly AI summary batch at each rep's top accounts by
           score, not at whatever has an open recommendation.

  Why
  ---
  021's ai_batch_targets() only picked accounts with an OPEN or ACTED
  recommendation. Recommendations are generated only while
  feature.recommendations is on (024, etl/views.yml), and nothing expires the
  open ones — so with the flag off the batch kept re-targeting the same
  frozen set from the last generator run, and the accounts a rep actually
  opens (the top of the account_signals ranking) never got a pre-built
  brief.

  What changes
  ------------
  1. No recommendation requirement. Each active rep's book is ranked by
     account_signals.score, exactly as before.
  2. Accounts whose ai_summaries row is younger than 20 hours are left out
     BEFORE the per-rep cap. The ETL now calls the batch in small chunks until
     a call neither generates nor checks anything (etl/views.yml
     repeat_until_idle); with the
     fresh rows filtered first, each call moves down the list instead of
     re-reading the same top N. 20 hours matches the function's
     AI_BATCH_MIN_AGE_HOURS default: last night's rows are eligible again,
     a brief a rep generated this afternoon is not.
  3. Accounts the batch already LOOKED AT in the last 20 hours are left out
     the same way, whatever came of it (public.ai_batch_checks, below). An
     unchanged account comes back 'cached', a thin one 'insufficient', a
     broken one 'failed' — none of them writes ai_summaries, so without
     this they kept the lowest places in their rep's list on every repeat
     call: the same top N rebuilt (and a failing one paid for) up to eight
     times, while that rep's deeper accounts were never reached.
  4. Rows come back in round-robin order: every rep's #1 (by its place in
     the rep's WHOLE book, fresh accounts included), then every rep's #2,
     and so on, score breaking ties within a round. The batch works them in
     that order and stops at its per-call allowance, so across the night's
     repeated calls each rep's top accounts are done before any rep's
     deeper ones. Sorted by score alone, the books with the highest scores
     took every call's allowance while a rep with smaller dealers got
     nothing. (The order is the function's; its OUT columns cannot carry
     the rank — create-or-replace rules.)
  5. Unchanged: the recently-resolved suppression (021 header), the
     distinct-on dedupe, the per-rep clamp 1..25, SECURITY DEFINER (the
     batch runs as service_role and needs the whole user x account map —
     see 021), and job-only grants.

  Backward compatible: same name, argument and OUT columns, so the deployed
  ai-summary-batch keeps calling it unchanged (it simply never writes
  ai_batch_checks, so 3 has nothing to filter). search_path is now pinned
  to '' with every name qualified (017's rule for definer functions).
============================================================================*/

--------------------------------------------------------------------------
-- public.ai_batch_checks — "tonight's batch looked at this account".
-- One row per account, stamped by ai-summary-batch for every account it
-- finishes (generated, cached, insufficient or failed); read only by
-- ai_batch_targets(). Internal: RLS on with no policy and no app grant, so
-- only service_role (the batch, which bypasses RLS) and the owner touch it.
--------------------------------------------------------------------------
create table if not exists public.ai_batch_checks (
    customer_key text        primary key,
    checked_at   timestamptz not null default now(),
    outcome      text        not null
                 check (outcome in ('generated', 'cached', 'insufficient', 'failed'))
);
alter table public.ai_batch_checks enable row level security;

comment on table public.ai_batch_checks is
  'When the nightly AI summary batch last looked at each account and what '
  'came of it. ai_batch_targets() skips accounts checked in the last 20 '
  'hours, so repeat calls in one night move down each rep''s list instead '
  'of re-reading (or re-paying for) the same top N. Written by '
  'ai-summary-batch as service_role only (20261013140000).';

revoke all on public.ai_batch_checks from anon, authenticated, public;
grant select, insert, update, delete on public.ai_batch_checks to service_role;

-- View-as is read-only on every RLS-enabled public table (20260901190200's
-- sweep, restated in 20261013150003). The batch has no auth.uid(), so the
-- trigger lets it through.
drop trigger if exists trg_ai_batch_checks_no_write_while_viewing_as
  on public.ai_batch_checks;
create trigger trg_ai_batch_checks_no_write_while_viewing_as
  before insert or update or delete on public.ai_batch_checks
  for each row execute function public.block_writes_while_impersonating();

create or replace function public.ai_batch_targets(p_per_rep int default 5)
returns table (customer_key text, score numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with cooldown as (
    -- The longest resolve cooldown any rule carries (021, unchanged).
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
      -- ...not one the rep just finished with (021).
      and not exists (
        select 1 from public.recommendations r, cooldown c
        where r.customer_key = ua.customer_key
          and r.status in ('closed', 'dismissed')
          and r.closed_at is not null
          and r.closed_at > now() - make_interval(days => c.days)
      )
  ),
  book as (
    -- Each account's place in its rep's whole book, fresh ones included:
    -- the round an account belongs to (see header, 4).
    select e.*, row_number() over (
             partition by e.user_id
             order by e.score desc, e.customer_key) as book_rank
    from eligible e
  ),
  todo as (
    -- Written in the last 20 hours (by last night's batch or by a rep
    -- pressing Summarize): nothing to do tonight. Filtered here, before
    -- the cap, so the next call in the chunked run gets the next accounts.
    select b.*, row_number() over (
             partition by b.user_id
             order by b.book_rank) as rn
    from book b
    where not exists (
        select 1 from public.ai_summaries a
        where a.customer_key = b.customer_key
          and a.generated_at > now() - interval '20 hours'
      )
      -- Looked at in the last 20 hours and left alone (cached, too thin,
      -- or failed): also done for tonight (see header, 3).
      and not exists (
        select 1 from public.ai_batch_checks c
        where c.customer_key = b.customer_key
          and c.checked_at > now() - interval '20 hours'
      )
  ),
  picked as (
    -- An account in two books (a rep's and their group principal's) is
    -- generated once, in the earlier of its two rounds.
    select distinct on (t.customer_key) t.customer_key, t.score, t.book_rank
    from todo t
    where t.rn <= greatest(1, least(coalesce(p_per_rep, 5), 25))
    order by t.customer_key, t.book_rank
  )
  select p.customer_key, p.score
  from picked p
  order by p.book_rank, p.score desc, p.customer_key;
$$;

comment on function public.ai_batch_targets(int) is
  'The accounts tonight''s summary batch should generate: each active rep''s '
  'top N by account_signals.score, skipping accounts summarised or checked '
  '(ai_batch_checks) in the last 20 hours (before the cap, so chunked calls '
  'make progress) and ones '
  'recently resolved, in round-robin order (every rep''s #1, then every '
  'rep''s #2, ...). No recommendation required (20261013140000). Job only '
  '— the Edge Function calls it with service_role and works the rows in '
  'the order returned.';

-- Job-only. Nothing about this should be reachable from a browser.
revoke execute on function public.ai_batch_targets(int) from public, anon, authenticated;
