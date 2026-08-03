/*============================================================================
  020_recommendation_engine_v2.sql
  Purpose: Rewire generate_recommendations() onto the 019 score.

           Same signature, same return shape, same ETL hook — views.yml does
           not change. What changes is where priority comes from, what the
           reason text says, and how long a resolved recommendation stays
           resolved.

  Four things happen here.

  1. THE SCORE DRIVES PRIORITY.
     008 stamped `case when trailing_12m_revenue >= 50000 then 'high'`, with
     the number written into the function body. Those cutoffs are
     unmaintainable — wrong the moment the book changes shape, and invisible
     to the admin. Priority now comes from the score bands in
     public.score_settings, and the score and its factor breakdown are
     persisted on the recommendation row.

     Persisted, not joined: the Today list stays ONE query, and the score a
     rep sees is the score the rule actually fired on rather than whatever
     tonight's refresh has since moved it to.

  2. THE REASON EXPLAINS ITSELF.
     A reordered list with no explanation is a list a rep stops trusting.
     Every row now leads with the two factors that contributed most —
     "Usually orders every 34 days — 96 since the last one. $48,000 trailing
     12 months, down 31% from last year." — built from the `why` strings 019
     stores per factor. This is not decoration; it is the thing that makes a
     score usable by someone who does not read dashboards.

  3. A NEW RULE: cadence_overdue.
     Fires when an account is late against its OWN rhythm. This catches what
     the other two structurally cannot: a weekly dealer silent for six weeks
     is in trouble long before "no order in 120 days", and an annual buyer at
     day 150 is not in trouble at all.

     Seeded DISABLED. See the wave note at the bottom.

  4. RESOLVED WORK STAYS RESOLVED — this one is a bug fix.

     uq_recs_open_rule is a partial unique index on `status = 'open'`. It
     stops a duplicate OPEN row and does nothing once a rep closes one. So an
     account that is still quiet re-fires the same rule on the NEXT nightly
     run: a rep who closes "No order in 140 days" this afternoon has it back
     tomorrow morning, forever, until the account orders.

     008's header describes the re-fire as intended ("if an account goes
     quiet again next quarter it gets flagged again") and it is — but there
     was no interval, and next quarter and next night are the same thing to
     that query. Every rule now respects a per-rule cooldown after a
     resolution: 30 days by default, 90 after a false positive, because a rep
     who took the trouble to report noise should not be asked again in a
     month.

  NOT CHANGED, deliberately: a rising score does not re-open a closed
  recommendation. That is the same judgement — the rep answered, and 019's
  suppression multiplier already keeps a just-resolved account out of the top
  of the ranking. If you are here to "fix" that, it is not broken.
============================================================================*/

--------------------------------------------------------------------------
-- Carry the score onto the recommendation.
--------------------------------------------------------------------------
alter table public.recommendations
  add column if not exists score numeric(5,2),
  add column if not exists score_factors jsonb;

create index if not exists idx_recs_open_score
  on public.recommendations (score desc nulls last)
  where status in ('open', 'acted');

comment on column public.recommendations.score is
  'The 0-100 account priority score at the moment this row was created '
  '(019_account_scoring.sql). Persisted rather than joined so the rep''s '
  'list is one query and the score shown is the score the rule fired on.';

--------------------------------------------------------------------------
-- New rule + cooldown settings.
--
-- cadence_overdue ships DISABLED. Turning it on is a decision made from the
-- admin screen after previewing what it would create, not a side effect of
-- applying a migration.
--------------------------------------------------------------------------
insert into public.rule_settings (rule_key, description, enabled, params) values
  ('cadence_overdue',
   'Overdue against the account''s OWN order rhythm (median gap over 24 months)',
   false,
   '{"trigger_ratio": 1.5, "min_score": 55, "min_trailing_12m_revenue": 2500,
     "require_confident_cadence": true, "resolve_cooldown_days": 30,
     "false_positive_cooldown_days": 90}'::jsonb)
on conflict (rule_key) do nothing;

-- The existing two rules gain a score gate and the cooldown. `||` merges, so
-- an admin who has already retuned `days` or `decline_pct` keeps their values.
update public.rule_settings
   set params = params || '{"min_score": 45, "resolve_cooldown_days": 30,
                            "false_positive_cooldown_days": 90}'::jsonb
 where rule_key in ('no_order_days', 'yoy_decline');

--------------------------------------------------------------------------
-- explain_score — the two biggest contributors, as a sentence.
--------------------------------------------------------------------------
create or replace function public.explain_score(p_factors jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select string_agg(why, '. ' order by contribution desc)
  from (
    select f.value ->> 'why'                    as why,
           (f.value ->> 'contribution')::numeric as contribution
    from jsonb_each(coalesce(p_factors, '{}'::jsonb)) f
    where f.value ->> 'why' is not null
    order by (f.value ->> 'contribution')::numeric desc
    limit 2
  ) top2;
$$;

comment on function public.explain_score(jsonb) is
  'The "why now" clause on a recommendation: the two highest-contributing '
  'factors from account_signals.factors, joined into a sentence.';

--------------------------------------------------------------------------
-- generate_recommendations — same signature and return shape as 008, so the
-- ETL post_load_sql and job_runs are untouched.
--
-- Step 0 now refreshes and scores. Doing it here rather than adding a second
-- statement to views.yml keeps ONE hook: there is no way for the two to run
-- out of order, and no way to generate against yesterday's facts. That is
-- TECH_STACK §4.2's whole argument for putting this in the database.
--------------------------------------------------------------------------
create or replace function public.generate_recommendations()
returns table (out_rule_key text, out_created int)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_params  jsonb;
  v_created int;
  v_started timestamptz := clock_timestamp();
  v_total   int := 0;
  v_cfg     public.score_settings;
  v_signals int;
begin
  ------------------------------------------------------------------
  -- Step 0: fresh signals, fresh scores. Everything below reads them.
  ------------------------------------------------------------------
  v_signals := public.refresh_account_signals();
  perform public.apply_account_scores();
  out_rule_key := 'refresh_signals'; out_created := v_signals;
  return next;

  v_cfg := (select s from public.score_settings s where s.id);

  ------------------------------------------------------------------
  -- Rule: no_order_days — accounts with real history whose last order is
  -- older than N days.
  --
  -- Reads account_signals.last_order_date, which is the harmonized
  -- greatest(dim, max(fact)) from 015. 008 filtered on the raw
  -- dim_customer.last_order_date, which this ERP does not maintain: it is
  -- NULL for most accounts, so `c.last_order_date is not null` silently
  -- skipped most of the book and this rule has been firing on a fraction of
  -- what it should.
  ------------------------------------------------------------------
  select params into v_params
  from public.rule_settings rs
  where rs.rule_key = 'no_order_days' and rs.enabled;

  if found then
    with ins as (
      insert into public.recommendations
        (customer_key, source, rule_key, title, reason, priority, score, score_factors)
      select
        s.customer_key,
        'system',
        'no_order_days',
        'No order in ' || s.days_since_order || ' days',
        coalesce(public.explain_score(s.factors) || '. ', '') ||
          'Contact the buyer and find out why.',
        coalesce(s.priority, 'normal'),
        s.score,
        s.factors
      from public.account_signals s
      where s.days_since_order is not null
        and s.days_since_order > (v_params ->> 'days')::int
        and s.revenue_12m >= (v_params ->> 'min_trailing_12m_revenue')::numeric
        and coalesce(s.score, 0) >= coalesce((v_params ->> 'min_score')::numeric, 0)
        and not public.rule_in_cooldown(s.customer_key, 'no_order_days', v_params)
      on conflict (customer_key, rule_key) where status = 'open' and source = 'system'
        do nothing
      returning 1
    )
    select count(*) into v_created from ins;
    v_total := v_total + coalesce(v_created, 0);
    out_rule_key := 'no_order_days'; out_created := coalesce(v_created, 0);
    return next;
  end if;

  ------------------------------------------------------------------
  -- Rule: yoy_decline — trailing 12 months down more than X% on the 12
  -- before. 019 already computed the comparison; this is now a threshold
  -- check rather than a second pass over the fact table.
  ------------------------------------------------------------------
  select params into v_params
  from public.rule_settings rs
  where rs.rule_key = 'yoy_decline' and rs.enabled;

  if found then
    with ins as (
      insert into public.recommendations
        (customer_key, source, rule_key, title, reason, priority, score, score_factors)
      select
        s.customer_key,
        'system',
        'yoy_decline',
        'Revenue down ' || round(abs(s.yoy_change) * 100) || '% YoY',
        coalesce(public.explain_score(s.factors) || '. ', '') ||
          'Verify inventory, ask about competitors, and review fall programs.',
        coalesce(s.priority, 'normal'),
        s.score,
        s.factors
      from public.account_signals s
      where s.yoy_change is not null
        and s.yoy_change < 0
        and abs(s.yoy_change) * 100 > (v_params ->> 'decline_pct')::numeric
        and s.revenue_prior_12m >= (v_params ->> 'min_prior_ytd_revenue')::numeric
        and coalesce(s.score, 0) >= coalesce((v_params ->> 'min_score')::numeric, 0)
        and not public.rule_in_cooldown(s.customer_key, 'yoy_decline', v_params)
      on conflict (customer_key, rule_key) where status = 'open' and source = 'system'
        do nothing
      returning 1
    )
    select count(*) into v_created from ins;
    v_total := v_total + coalesce(v_created, 0);
    out_rule_key := 'yoy_decline'; out_created := coalesce(v_created, 0);
    return next;
  end if;

  ------------------------------------------------------------------
  -- Rule: cadence_overdue — late against the account's OWN rhythm.
  --
  -- require_confident_cadence defaults true: with fewer than two observed
  -- gaps the "median interval" is a guess, and guessing is how you tell a
  -- dealer they are overdue on a rhythm they never had.
  ------------------------------------------------------------------
  select params into v_params
  from public.rule_settings rs
  where rs.rule_key = 'cadence_overdue' and rs.enabled;

  if found then
    with ins as (
      insert into public.recommendations
        (customer_key, source, rule_key, title, reason, priority, score, score_factors)
      select
        s.customer_key,
        'system',
        'cadence_overdue',
        'Overdue — usually orders every ' || round(s.cadence_days) || ' days',
        coalesce(public.explain_score(s.factors) || '. ', '') ||
          'They are past their normal reorder window. Ask what changed.',
        coalesce(s.priority, 'normal'),
        s.score,
        s.factors
      from public.account_signals s
      where s.cadence_days is not null
        and s.cadence_days > 0
        and s.days_since_order is not null
        and s.days_since_order::numeric / s.cadence_days
              >= (v_params ->> 'trigger_ratio')::numeric
        and s.revenue_12m >= (v_params ->> 'min_trailing_12m_revenue')::numeric
        and coalesce(s.score, 0) >= coalesce((v_params ->> 'min_score')::numeric, 0)
        and (not coalesce((v_params ->> 'require_confident_cadence')::boolean, true)
             or s.cadence_confident)
        and not public.rule_in_cooldown(s.customer_key, 'cadence_overdue', v_params)
      on conflict (customer_key, rule_key) where status = 'open' and source = 'system'
        do nothing
      returning 1
    )
    select count(*) into v_created from ins;
    v_total := v_total + coalesce(v_created, 0);
    out_rule_key := 'cadence_overdue'; out_created := coalesce(v_created, 0);
    return next;
  end if;

  perform public.log_job_run('generate_recommendations', 'success',
                             v_total::bigint, null, v_started);
  return;
end;
$$;

revoke execute on function public.generate_recommendations()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- rule_in_cooldown — has this rule recently been resolved on this account?
--
-- Declared after the generator only for readability; plpgsql resolves at
-- run time, so the order does not matter. Created BEFORE the generator is
-- first called, which is what does.
--------------------------------------------------------------------------
create or replace function public.rule_in_cooldown(
    p_customer_key text,
    p_rule_key     text,
    p_params       jsonb
) returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.recommendations prev
    where prev.customer_key = p_customer_key
      and prev.rule_key     = p_rule_key
      and prev.status in ('closed', 'dismissed')
      and prev.closed_at is not null
      and prev.closed_at > now() - make_interval(days =>
            case when prev.outcome = 'false_positive'
                 then coalesce((p_params ->> 'false_positive_cooldown_days')::int, 90)
                 else coalesce((p_params ->> 'resolve_cooldown_days')::int, 30)
            end)
  );
$$;

comment on function public.rule_in_cooldown(text, text, jsonb) is
  'True while a resolved recommendation for this (account, rule) is still '
  'inside its cooldown. Without it, uq_recs_open_rule only prevents '
  'duplicate OPEN rows and a closed recommendation re-fires the next night.';

--------------------------------------------------------------------------
-- preview_recommendation_counts — "what would tonight create?"
--
-- The create_mission(p_dry_run) analogue: same scope resolution as the real
-- thing, no writes. Scores from CANDIDATE settings without touching
-- account_signals, so an admin can see the size of a change before saving it.
--------------------------------------------------------------------------
create or replace function public.preview_recommendation_counts(
    p_weights jsonb   default null,
    p_params  jsonb   default null,
    p_high    numeric default null,
    p_low     numeric default null,
    p_rules   jsonb   default null   -- {"rule_key": {enabled, params…}} overrides
) returns table (rule_key text, would_create int)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  cfg public.score_settings;
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;

  cfg := (
    select (true,
            coalesce(p_weights, d.weights),
            coalesce(p_params,  d.params),
            coalesce(p_high,    d.priority_high),
            coalesce(p_low,     d.priority_low),
            now(), null)::public.score_settings
    from public.score_settings d where d.id
  );

  return query
  with scored as (
    select s.*, public.score_account(s, cfg) as j
    from public.account_signals s
  ),
  flat as (
    select sc.customer_key, sc.days_since_order, sc.revenue_12m,
           sc.revenue_prior_12m, sc.yoy_change, sc.cadence_days,
           sc.cadence_confident,
           (sc.j ->> 'score')::numeric as score
    from scored sc
  ),
  rules as (
    select rs.rule_key,
           coalesce((p_rules -> rs.rule_key ->> 'enabled')::boolean, rs.enabled) as enabled,
           coalesce(p_rules -> rs.rule_key -> 'params', rs.params)               as params
    from public.rule_settings rs
    where rs.rule_key in ('no_order_days', 'yoy_decline', 'cadence_overdue')
  )
  select r.rule_key,
         count(*) filter (where
           r.enabled
           and coalesce(f.score, 0) >= coalesce((r.params ->> 'min_score')::numeric, 0)
           and not public.rule_in_cooldown(f.customer_key, r.rule_key, r.params)
           and case r.rule_key
                 when 'no_order_days' then
                   f.days_since_order is not null
                   and f.days_since_order > (r.params ->> 'days')::int
                   and f.revenue_12m >= (r.params ->> 'min_trailing_12m_revenue')::numeric
                 when 'yoy_decline' then
                   f.yoy_change is not null and f.yoy_change < 0
                   and abs(f.yoy_change) * 100 > (r.params ->> 'decline_pct')::numeric
                   and f.revenue_prior_12m >= (r.params ->> 'min_prior_ytd_revenue')::numeric
                 when 'cadence_overdue' then
                   f.cadence_days is not null and f.cadence_days > 0
                   and f.days_since_order is not null
                   and f.days_since_order::numeric / f.cadence_days
                         >= (r.params ->> 'trigger_ratio')::numeric
                   and f.revenue_12m >= (r.params ->> 'min_trailing_12m_revenue')::numeric
                   and (not coalesce((r.params ->> 'require_confident_cadence')::boolean, true)
                        or f.cadence_confident)
                 else false
               end
           -- An already-open row would be swallowed by ON CONFLICT, so it is
           -- not something tonight would "create".
           and not exists (
             select 1 from public.recommendations o
             where o.customer_key = f.customer_key and o.rule_key = r.rule_key
               and o.status = 'open' and o.source = 'system')
         )::int as would_create
  from rules r cross join flat f
  group by r.rule_key
  order by r.rule_key;
end;
$$;

revoke execute on function public.rule_in_cooldown(text, text, jsonb) from public, anon;
revoke execute on function public.preview_recommendation_counts(jsonb, jsonb, numeric, numeric, jsonb)
  from public, anon;
revoke execute on function public.explain_score(jsonb) from public, anon;

grant execute on function public.rule_in_cooldown(text, text, jsonb) to authenticated;
grant execute on function public.preview_recommendation_counts(jsonb, jsonb, numeric, numeric, jsonb)
  to authenticated;
grant execute on function public.explain_score(jsonb) to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist

  1. EXPECT A WAVE, and look at it before you let it out.
     015_account_last_order_date.sql warned in its own footnote that pointing
     no_order_days at the derived date "would fire a wave of new
     recommendations overnight and deserves its own tuning pass". This is
     that pass. The candidate pool gets much larger because the rule can
     finally see accounts whose ERP last_order_date is NULL.

     Three things hold it back, and all three are visible rather than hidden:
       - every rule now has a min_score gate (45 by default);
       - cadence_overdue ships disabled;
       - preview_recommendation_counts() tells you the number before you
         commit to it.

     Do NOT quietly raise min_trailing_12m_revenue to make the number look
     smaller. Run the preview, decide, and write down what you chose.

  2. Verify the cooldown fix by hand, because it is the one behaviour change
     a rep will notice immediately:
         select public.generate_recommendations();
         update public.recommendations set status='closed', outcome='seasonal'
          where id = <one of them>;
         select public.generate_recommendations();
     The closed row must NOT come back. On main it does, the same night.

  3. Idempotency is unchanged: running the generator twice creates zero rows
     the second time (uq_recs_open_rule).

  4. Regenerate frontend/src/types/database.types.ts for the two new columns.
----------------------------------------------------------------------------*/
