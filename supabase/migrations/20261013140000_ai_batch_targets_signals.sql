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
     a call generates nothing (etl/views.yml repeat_until_idle); with the
     fresh rows filtered first, each call moves down the list instead of
     re-reading the same top N. 20 hours matches the function's
     AI_BATCH_MIN_AGE_HOURS default: last night's rows are eligible again,
     a brief a rep generated this afternoon is not.
  3. Rows come back in round-robin order: every rep's #1 (by its place in
     the rep's WHOLE book, fresh accounts included), then every rep's #2,
     and so on, score breaking ties within a round. The batch works them in
     that order and stops at its per-call allowance, so across the night's
     repeated calls each rep's top accounts are done before any rep's
     deeper ones. Sorted by score alone, the books with the highest scores
     took every call's allowance while a rep with smaller dealers got
     nothing. (The order is the function's; its OUT columns cannot carry
     the rank — create-or-replace rules.)
  4. Unchanged: the recently-resolved suppression (021 header), the
     distinct-on dedupe, the per-rep clamp 1..25, SECURITY DEFINER (the
     batch runs as service_role and needs the whole user x account map —
     see 021), and job-only grants.

  Backward compatible: same name, argument and OUT columns, so the deployed
  ai-summary-batch keeps calling it unchanged. search_path is now pinned to
  '' with every name qualified (017's rule for definer functions).
============================================================================*/

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
    -- the round an account belongs to (see header, 3).
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
  'top N by account_signals.score, skipping accounts summarised in the last '
  '20 hours (before the cap, so chunked calls make progress) and ones '
  'recently resolved, in round-robin order (every rep''s #1, then every '
  'rep''s #2, ...). No recommendation required (20261013140000). Job only '
  '— the Edge Function calls it with service_role and works the rows in '
  'the order returned.';

-- Job-only. Nothing about this should be reachable from a browser.
revoke execute on function public.ai_batch_targets(int) from public, anon, authenticated;
