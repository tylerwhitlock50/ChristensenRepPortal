/*============================================================================
  019_account_scoring.sql
  Purpose: A balanced priority score per account, replacing the binary
           high/normal that 008 stamped off two hardcoded dollar cutoffs.

           Five factors, each answering a different question a rep would ask:

             cadence   are they overdue AGAINST THEIR OWN RHYTHM?
             recency   how long since anyone here talked to them?
             trend     which way is the revenue going?
             value     how much is at stake?
             mix       are they buying a narrower range than they used to?

           Weights live in public.score_settings and are tuned from the admin
           screen, not a deploy.

  ── Why a TABLE and not a materialized view ────────────────────────────────
  Postgres does not support row level security on materialized views —
  `alter materialized view … enable row level security` is rejected outright,
  and there is no security_invoker escape hatch either. Supabase's default
  privileges grant `authenticated` SELECT on new objects in public, so a
  matview of per-account revenue, cadence and score would hand every dealer's
  numbers to every rep and to every non-employee rep group, while looking
  entirely correct in review. That is PRD acceptance criterion #1 failing
  silently and totally — the exact thing 011_account_views.sql was written to
  prevent.

  So: a plain table with RLS, written only by a security definer job. If you
  are here to "optimise" this into a matview, that is the reason not to.

  ── Signals and scores live in ONE table, on purpose ───────────────────────
  Splitting them would mean two upserts, two policies and a join on every
  read for no benefit — the grain is identical (one row per account) and they
  are written by the same job seconds apart.

  ── But the two FUNCTIONS are split, and that matters ──────────────────────
    refresh_account_signals()   expensive. Scans ~529k invoice lines and
                                ~501k order lines. Nightly, after the ETL.
    apply_account_scores()      cheap. Pure arithmetic over stored signals.
                                Also runs when an admin saves new weights.

  The split is forced by the `value` factor: percent_rank() is a window over
  the whole population, so it cannot live inside a per-row scorer. It is
  computed once during the refresh and STORED as a raw signal. That is what
  keeps score_account() a pure per-row function, which in turn is what makes
  the admin's dry-run preview cheap — a preview that re-derived signals would
  scan a million fact rows every time someone dragged a weight.

  ── NULL means "no basis to judge", never zero ─────────────────────────────
  A factor returns NULL when the account gives it nothing to work with: no
  prior-year revenue, no logged contact, no families bought last year. The
  composite divides by the sum of the weights that ACTUALLY CONTRIBUTED.
  Without that renormalization, an account with no history is dragged toward
  zero by blanks it did not earn, and the ranking quietly favours whoever has
  been a customer longest.

  It also makes weights relative rather than percentages: 30/20/20/20/10 and
  3/2/2/2/1 rank identically, so nothing has to add up to 100.
============================================================================*/

--------------------------------------------------------------------------
-- score_settings — the tuning surface. A singleton: `id boolean primary key
-- default true check (id)` admits exactly one row, so the admin screen never
-- has to pick which settings are live.
--
-- NOT a row in rule_settings, though that table is the obvious home for it.
-- public.recommendations.rule_key is a FOREIGN KEY to rule_settings.rule_key:
-- every row in that table is a legal rule stamp on a recommendation, and a
-- weight vector must not be stampable. Typed columns also let `low < high` be
-- a CHECK rather than an admin-screen convention.
--
-- cadence_overdue IS a rule and does live in rule_settings (see 020).
--------------------------------------------------------------------------
create table if not exists public.score_settings (
    id            boolean primary key default true check (id),
    weights       jsonb not null default
      '{"cadence": 30, "recency": 20, "trend": 20, "value": 20, "mix": 10}'::jsonb,
    params        jsonb not null default '{
        "cadence": {"full_ratio": 2.5, "min_days": 14, "default_days": 120},
        "recency": {"target_days": 90, "treat_never_as": "unknown"},
        "trend":   {"full_decline_pct": 50, "min_prior_revenue": 2500},
        "mix":     {"breadth_target": 4, "dropped_weight": 0.7},
        "suppress": {"order_received_days": 30, "order_received_factor": 0.4,
                     "false_positive_days": 60, "false_positive_factor": 0.6}
    }'::jsonb,
    priority_high numeric not null default 70,
    priority_low  numeric not null default 35,
    updated_at    timestamptz not null default now(),
    updated_by    uuid references public.profiles (user_id),
    constraint score_bands_ordered check (priority_low < priority_high)
);
alter table public.score_settings enable row level security;

-- Reps read it (the admin screen and any "why is this ranked here" UI need
-- the bands); only the admin writes.
drop policy if exists "read score settings" on public.score_settings;
create policy "read score settings" on public.score_settings
  for select to authenticated using (true);

drop policy if exists "admin manages score settings" on public.score_settings;
create policy "admin manages score settings" on public.score_settings
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

insert into public.score_settings (id) values (true) on conflict (id) do nothing;

comment on table public.score_settings is
  'Singleton tuning row for the account priority score. Weights are RELATIVE '
  '— the composite renormalizes over whichever factors produced a value — so '
  'they need not sum to anything. Edited from /admin/settings.';

--------------------------------------------------------------------------
-- account_signals — one row per scorable account: the raw inputs, then the
-- five subscores and the composite computed from them.
--
-- "Scorable" = active, not internal, and some invoice or order activity in
-- the last 24 months. Everything else simply has no row and is unranked.
--------------------------------------------------------------------------
create table if not exists public.account_signals (
    customer_key           text primary key,
    computed_at            timestamptz not null default now(),
    scored_at              timestamptz,

    -- revenue
    revenue_12m            numeric,
    revenue_prior_12m      numeric,
    revenue_percentile     numeric,   -- 0..1, percent_rank across the scored book
    yoy_change             numeric,   -- ratio, e.g. -0.31; null when no prior year

    -- rhythm
    last_order_date        date,      -- harmonized greatest(), see 015
    days_since_order       int,
    order_days_24m         int,       -- distinct order DAYS, not order ids
    cadence_days           numeric,   -- median gap between consecutive order days
    cadence_confident      boolean not null default false,

    -- engagement
    last_touch_date        date,
    days_since_touch       int,

    -- mix
    families_12m           int,
    families_prior_12m     int,
    families_dropped       int,

    -- context the reason text uses
    open_backlog_amount    numeric,
    yearly_sales_goal      numeric,

    -- outcome feedback (drives the suppression multiplier)
    last_order_received_at date,
    last_false_positive_at date,

    -- computed
    score_cadence numeric, score_recency numeric, score_trend numeric,
    score_value   numeric, score_mix     numeric,
    score         numeric,             -- 0..100, null when every factor is null
    priority      text check (priority in ('high','normal','low')),
    factors       jsonb                -- per-factor value/weight/contribution/why
);
alter table public.account_signals enable row level security;

-- Same predicate SHAPE as 010_access_performance.sql, deliberately: is_admin()
-- as a scalar subquery so it is an InitPlan evaluated once, and
-- my_customer_keys() uncorrelated so it is evaluated once rather than per row.
-- Writing it any other way re-introduces the scan 010 exists to have fixed.
drop policy if exists "read account signals" on public.account_signals;
create policy "read account signals" on public.account_signals
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

-- No insert/update/delete policy exists, so app writes are impossible; the
-- refresh job is security definer and bypasses RLS the way the ETL does.
revoke all on public.account_signals from anon, public;
grant select on public.account_signals to authenticated;

create index if not exists idx_signals_score
  on public.account_signals (score desc nulls last);

comment on table public.account_signals is
  'One row per scorable account: raw priority signals plus the five subscores '
  'and the composite. Refreshed nightly by refresh_account_signals(); scored '
  'by apply_account_scores(). A TABLE and not a matview because matviews '
  'cannot carry RLS — see the migration header.';

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------
create or replace function public.clamp100(v numeric)
returns numeric language sql immutable set search_path = ''
as $$ select greatest(0, least(100, v)) $$;

--------------------------------------------------------------------------
-- score_account — the whole formula, in one pure per-row function so the
-- nightly job, an admin's save and the dry-run preview cannot disagree.
--
-- STABLE, not IMMUTABLE: the suppression multiplier reads current_date.
--------------------------------------------------------------------------
create or replace function public.score_account(
    s   public.account_signals,
    cfg public.score_settings
) returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  p jsonb := cfg.params;
  w jsonb := cfg.weights;

  f_cadence numeric; f_recency numeric; f_trend numeric;
  f_value   numeric; f_mix     numeric;
  why_cadence text; why_recency text; why_trend text;
  why_value   text; why_mix     text;

  cad   numeric;
  ratio numeric;
  touch_days int;
  dropped_share numeric;
  breadth_gap   numeric;

  num numeric := 0;
  den numeric := 0;
  suppression numeric := 1.0;
  raw numeric;
  final numeric;
  factors jsonb := '{}'::jsonb;
begin
  ------------------------------------------------------------------
  -- cadence: overdue against THIS account's own rhythm.
  -- An annual buyer 200 days out is early; a weekly buyer 30 days out is a
  -- fire. That distinction is the entire reason this factor is weighted
  -- highest, and the reason 008's flat "no order in N days" missed so much.
  ------------------------------------------------------------------
  cad := greatest(
           coalesce(s.cadence_days, (p->'cadence'->>'default_days')::numeric),
           (p->'cadence'->>'min_days')::numeric);
  if s.days_since_order is not null and cad > 0 then
    ratio := s.days_since_order::numeric / cad;
    f_cadence := public.clamp100(
      (ratio - 1) / nullif((p->'cadence'->>'full_ratio')::numeric - 1, 0) * 100);
    -- The sentence quotes the OBSERVED median, not `cad`. `cad` carries the
    -- min_days floor, which is correct for scoring (a weekly dealer must not
    -- max out after missing one week) but would make this a false statement
    -- about the dealer: "usually orders every 14 days" for a shop that
    -- reliably orders every 7. A rep reads this line ninety seconds before
    -- walking in; it has to be true.
    why_cadence := case
      when s.cadence_confident and s.cadence_days is not null
        then format('Usually orders every %s days — %s since the last one',
                    round(s.cadence_days), s.days_since_order)
      else format('No order in %s days', s.days_since_order)
    end;
  end if;

  ------------------------------------------------------------------
  -- recency: time since any rep logged a call, visit or email.
  --
  -- treat_never_as = 'unknown' is the launch default and it is not timidity.
  -- If public.actions is still nearly empty, treating "never contacted" as
  -- maximally urgent pins every account at 100 and this factor spends its
  -- whole weight on noise. As NULL it renormalizes away and switches itself
  -- on as touch history accumulates. Flip to 'max' once coverage is real.
  ------------------------------------------------------------------
  touch_days := s.days_since_touch;
  if touch_days is null and (p->'recency'->>'treat_never_as') = 'max' then
    touch_days := (p->'recency'->>'target_days')::int * 4;
  end if;
  if touch_days is not null then
    f_recency := public.clamp100(
      touch_days::numeric / nullif((p->'recency'->>'target_days')::numeric, 0) * 100);
    why_recency := case
      when s.last_touch_date is null then 'No contact ever logged'
      else format('No contact logged in %s days', touch_days)
    end;
  end if;

  ------------------------------------------------------------------
  -- trend: trailing 12 months against the 12 before.
  -- Growth scores 0 — the composite means "needs attention", not "is
  -- interesting". No prior year gives NULL, not 0, so a brand-new dealer is
  -- not rewarded for having nothing to decline from.
  ------------------------------------------------------------------
  if coalesce(s.revenue_prior_12m, 0) >= (p->'trend'->>'min_prior_revenue')::numeric
     and s.yoy_change is not null then
    f_trend := public.clamp100(
      (-100 * s.yoy_change) / nullif((p->'trend'->>'full_decline_pct')::numeric, 0) * 100);
    why_trend := format('$%s trailing 12 months, %s %s%% from last year',
                        to_char(round(coalesce(s.revenue_12m, 0)), 'FM999,999,999'),
                        case when s.yoy_change < 0 then 'down' else 'up' end,
                        round(abs(s.yoy_change) * 100));
  end if;

  ------------------------------------------------------------------
  -- value: size of the prize, as a percentile of the whole book.
  --
  -- A percentile and not a dollar cutoff. This directly replaces 008's
  -- hardcoded 50000/100000, which are unmaintainable and wrong the moment
  -- the book changes shape. Ranking against the WHOLE book rather than each
  -- rep's own is deliberate: a small rep's biggest account should not score
  -- like a national chain.
  ------------------------------------------------------------------
  if s.revenue_percentile is not null then
    f_value := public.clamp100(s.revenue_percentile * 100);
    why_value := format('$%s trailing 12 months',
                        to_char(round(coalesce(s.revenue_12m, 0)), 'FM999,999,999'));
  end if;

  ------------------------------------------------------------------
  -- mix: "they used to buy three families, now they buy one" is the
  -- actionable signal. Raw breadth alone punishes a specialist dealer for
  -- being a specialist, hence the split.
  ------------------------------------------------------------------
  if coalesce(s.families_prior_12m, 0) > 0 then
    dropped_share := coalesce(s.families_dropped, 0)::numeric / s.families_prior_12m;
    breadth_gap := greatest(0, 1 - coalesce(s.families_12m, 0)::numeric
                                   / nullif((p->'mix'->>'breadth_target')::numeric, 0));
    f_mix := public.clamp100(
        (p->'mix'->>'dropped_weight')::numeric * dropped_share * 100
      + (1 - (p->'mix'->>'dropped_weight')::numeric) * breadth_gap * 100);
    -- Every factor that contributes must be able to say why it did, or the
    -- ranking has a component the rep cannot see.
    why_mix := case
      when coalesce(s.families_dropped, 0) > 0
        then format('Bought %s product %s last year that they have not this year',
                    s.families_dropped,
                    case when s.families_dropped = 1 then 'family' else 'families' end)
      else format('Buying %s product %s',
                  coalesce(s.families_12m, 0),
                  case when coalesce(s.families_12m, 0) = 1 then 'family' else 'families' end)
    end;
  end if;

  ------------------------------------------------------------------
  -- Composite, renormalized over the factors that produced a value.
  ------------------------------------------------------------------
  if f_cadence is not null then
    num := num + (w->>'cadence')::numeric * f_cadence;
    den := den + (w->>'cadence')::numeric;
  end if;
  if f_recency is not null then
    num := num + (w->>'recency')::numeric * f_recency;
    den := den + (w->>'recency')::numeric;
  end if;
  if f_trend is not null then
    num := num + (w->>'trend')::numeric * f_trend;
    den := den + (w->>'trend')::numeric;
  end if;
  if f_value is not null then
    num := num + (w->>'value')::numeric * f_value;
    den := den + (w->>'value')::numeric;
  end if;
  if f_mix is not null then
    num := num + (w->>'mix')::numeric * f_mix;
    den := den + (w->>'mix')::numeric;
  end if;

  if den = 0 then
    return jsonb_build_object('score', null, 'priority', null,
                              'subscores', '{}'::jsonb, 'factors', '{}'::jsonb);
  end if;
  raw := num / den;

  ------------------------------------------------------------------
  -- Suppression — the outcome feedback loop the PRD is built around,
  -- finally reading back into the engine. An account that just ordered, or
  -- that a rep already told us was a false positive, should not climb
  -- straight back to the top of the ranking.
  ------------------------------------------------------------------
  if s.last_order_received_at is not null
     and s.last_order_received_at > current_date - (p->'suppress'->>'order_received_days')::int then
    suppression := (p->'suppress'->>'order_received_factor')::numeric;
  elsif s.last_false_positive_at is not null
     and s.last_false_positive_at > current_date - (p->'suppress'->>'false_positive_days')::int then
    suppression := (p->'suppress'->>'false_positive_factor')::numeric;
  end if;

  final := round(raw * suppression, 1);

  factors := jsonb_strip_nulls(jsonb_build_object(
    'cadence', case when f_cadence is null then null else jsonb_build_object(
        'value', round(f_cadence, 1), 'weight', (w->>'cadence')::numeric,
        'contribution', round((w->>'cadence')::numeric * f_cadence / den, 1),
        'why', why_cadence) end,
    'recency', case when f_recency is null then null else jsonb_build_object(
        'value', round(f_recency, 1), 'weight', (w->>'recency')::numeric,
        'contribution', round((w->>'recency')::numeric * f_recency / den, 1),
        'why', why_recency) end,
    'trend', case when f_trend is null then null else jsonb_build_object(
        'value', round(f_trend, 1), 'weight', (w->>'trend')::numeric,
        'contribution', round((w->>'trend')::numeric * f_trend / den, 1),
        'why', why_trend) end,
    'value', case when f_value is null then null else jsonb_build_object(
        'value', round(f_value, 1), 'weight', (w->>'value')::numeric,
        'contribution', round((w->>'value')::numeric * f_value / den, 1),
        'why', why_value) end,
    'mix', case when f_mix is null then null else jsonb_build_object(
        'value', round(f_mix, 1), 'weight', (w->>'mix')::numeric,
        'contribution', round((w->>'mix')::numeric * f_mix / den, 1),
        'why', why_mix) end
  ));

  return jsonb_build_object(
    'score', final,
    'priority', case when final >= cfg.priority_high then 'high'
                     when final <  cfg.priority_low  then 'low'
                     else 'normal' end,
    'suppression', suppression,
    'subscores', jsonb_build_object(
        'cadence', round(f_cadence, 1), 'recency', round(f_recency, 1),
        'trend',   round(f_trend, 1),   'value',   round(f_value, 1),
        'mix',     round(f_mix, 1)),
    'factors', factors);
end;
$$;

comment on function public.score_account(public.account_signals, public.score_settings) is
  'The priority formula. Pure per-row so the nightly job, an admin save and '
  'the dry-run preview cannot drift. Returns {score, priority, subscores, '
  'factors}; score is NULL when no factor had anything to judge.';

--------------------------------------------------------------------------
-- refresh_account_signals — the expensive half. Whole-book scan; run it as
-- a job, never on a page load.
--
-- UPSERT rather than truncate-and-load, unlike the ETL: TRUNCATE takes
-- ACCESS EXCLUSIVE on a table reps are actively reading. At ~41k rows the
-- upsert is cheap and never blocks a reader.
--------------------------------------------------------------------------
create or replace function public.refresh_account_signals()
returns integer
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_rows int;
begin
  with base as (
    select c.customer_key, c.yearly_sales_goal, c.last_order_date as dim_last_order
    from erp.dim_customer c
    where c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
  ),
  inv as (
    select f.customer_key,
      sum(f.revenue) filter (
        where f.invoice_date > current_date - interval '12 months')     as revenue_12m,
      sum(f.revenue) filter (
        where f.invoice_date <= current_date - interval '12 months'
          and f.invoice_date >  current_date - interval '24 months')    as revenue_prior_12m
    from erp.fact_invoice_line f
    where f.is_memo is not true            -- NULL-safe; see the 011 header
      and f.invoice_date is not null
      and f.invoice_date > current_date - interval '24 months'
    group by 1
  ),
  ord as (
    select o.customer_key,
      max(o.order_date)                                          as last_order_date,
      sum(o.backlog_amount) filter (where o.is_backlog_line)      as open_backlog_amount
    from erp.fact_order_line o
    group by 1
  ),
  -- Distinct order DAYS, not order ids: three POs the same morning are one
  -- buying event, and counting them separately halves the apparent cadence
  -- of every dealer that batches its paperwork.
  order_days as (
    select o.customer_key, o.order_date
    from erp.fact_order_line o
    where o.order_date is not null
      and o.order_date > current_date - interval '24 months'
    group by 1, 2
  ),
  gaps as (
    select customer_key,
           order_date - lag(order_date) over (
             partition by customer_key order by order_date) as gap
    from order_days
  ),
  cadence as (
    select customer_key,
      count(*)::int                                             as order_days_24m,
      percentile_cont(0.5) within group (order by gap)::numeric as cadence_days,
      count(*) filter (where gap is not null)                   as gap_count
    from gaps
    group by 1
  ),
  touch as (
    select a.customer_key, max(a.action_date) as last_touch_date
    from public.actions a
    group by 1
  ),
  -- One pass, both windows: a family present in the prior year and absent in
  -- this one is the signal, so both flags come off the same grouped row.
  fam as (
    select f.customer_key, p.product_family,
      bool_or(f.invoice_date >  current_date - interval '12 months') as in_now,
      bool_or(f.invoice_date <= current_date - interval '12 months') as in_prior
    from erp.fact_invoice_line f
    join erp.dim_part p on p.part_key = f.part_key
    where f.is_memo is not true
      and f.invoice_date is not null
      and f.invoice_date > current_date - interval '24 months'
      and p.product_family is not null
    group by 1, 2
  ),
  fam_agg as (
    select customer_key,
      count(*) filter (where in_now)::int                   as families_12m,
      count(*) filter (where in_prior)::int                 as families_prior_12m,
      count(*) filter (where in_prior and not in_now)::int  as families_dropped
    from fam
    group by 1
  ),
  outcomes as (
    select r.customer_key,
      max(r.closed_at::date) filter (where r.outcome = 'order_received') as last_order_received_at,
      max(r.closed_at::date) filter (where r.outcome = 'false_positive') as last_false_positive_at
    from public.recommendations r
    where r.status in ('closed','dismissed') and r.closed_at is not null
    group by 1
  ),
  merged as (
    select
      b.customer_key,
      coalesce(i.revenue_12m, 0)::numeric        as revenue_12m,
      coalesce(i.revenue_prior_12m, 0)::numeric  as revenue_prior_12m,
      case when coalesce(i.revenue_prior_12m, 0) > 0
           then (coalesce(i.revenue_12m, 0) - i.revenue_prior_12m) / i.revenue_prior_12m
      end                                        as yoy_change,
      -- The 015 fix. dim_customer.last_order_date is unmaintained in this ERP
      -- and NULL for most accounts; greatest() ignores NULLs, so this is the
      -- real date wherever either source has one.
      greatest(b.dim_last_order, o.last_order_date) as last_order_date,
      cd.order_days_24m,
      cd.cadence_days,
      coalesce(cd.gap_count, 0) >= 2             as cadence_confident,
      t.last_touch_date,
      coalesce(fa.families_12m, 0)               as families_12m,
      coalesce(fa.families_prior_12m, 0)         as families_prior_12m,
      coalesce(fa.families_dropped, 0)           as families_dropped,
      coalesce(o.open_backlog_amount, 0)::numeric as open_backlog_amount,
      b.yearly_sales_goal,
      oc.last_order_received_at,
      oc.last_false_positive_at
    from base b
    left join inv     i  on i.customer_key  = b.customer_key
    left join ord     o  on o.customer_key  = b.customer_key
    left join cadence cd on cd.customer_key = b.customer_key
    left join touch   t  on t.customer_key  = b.customer_key
    left join fam_agg fa on fa.customer_key = b.customer_key
    left join outcomes oc on oc.customer_key = b.customer_key
    -- Scorable = some activity in 24 months. Everything else gets no row and
    -- is simply unranked, rather than sitting at the bottom of every list.
    where coalesce(i.revenue_12m, 0) <> 0
       or coalesce(i.revenue_prior_12m, 0) <> 0
       or coalesce(cd.order_days_24m, 0) > 0
  ),
  ranked as (
    select m.*, percent_rank() over (order by m.revenue_12m) as revenue_percentile
    from merged m
  ),
  upserted as (
    insert into public.account_signals as t (
      customer_key, computed_at,
      revenue_12m, revenue_prior_12m, revenue_percentile, yoy_change,
      last_order_date, days_since_order, order_days_24m, cadence_days,
      cadence_confident, last_touch_date, days_since_touch,
      families_12m, families_prior_12m, families_dropped,
      open_backlog_amount, yearly_sales_goal,
      last_order_received_at, last_false_positive_at
    )
    select
      -- v_started, NOT now(): now() is the TRANSACTION timestamp and is
      -- therefore always earlier than the clock_timestamp() captured above,
      -- so the stale-row delete below would sweep away every row this
      -- statement just wrote. One stamp, used for the write and the compare.
      r.customer_key, v_started,
      r.revenue_12m, r.revenue_prior_12m, r.revenue_percentile, r.yoy_change,
      r.last_order_date,
      case when r.last_order_date is not null
           then (current_date - r.last_order_date) end,
      r.order_days_24m, r.cadence_days,
      r.cadence_confident, r.last_touch_date,
      case when r.last_touch_date is not null
           then (current_date - r.last_touch_date) end,
      r.families_12m, r.families_prior_12m, r.families_dropped,
      r.open_backlog_amount, r.yearly_sales_goal,
      r.last_order_received_at, r.last_false_positive_at
    from ranked r
    on conflict (customer_key) do update set
      computed_at            = excluded.computed_at,
      revenue_12m            = excluded.revenue_12m,
      revenue_prior_12m      = excluded.revenue_prior_12m,
      revenue_percentile     = excluded.revenue_percentile,
      yoy_change             = excluded.yoy_change,
      last_order_date        = excluded.last_order_date,
      days_since_order       = excluded.days_since_order,
      order_days_24m         = excluded.order_days_24m,
      cadence_days           = excluded.cadence_days,
      cadence_confident      = excluded.cadence_confident,
      last_touch_date        = excluded.last_touch_date,
      days_since_touch       = excluded.days_since_touch,
      families_12m           = excluded.families_12m,
      families_prior_12m     = excluded.families_prior_12m,
      families_dropped       = excluded.families_dropped,
      open_backlog_amount    = excluded.open_backlog_amount,
      yearly_sales_goal      = excluded.yearly_sales_goal,
      last_order_received_at = excluded.last_order_received_at,
      last_false_positive_at = excluded.last_false_positive_at
    returning 1
  )
  select count(*)::int into v_rows from upserted;

  -- Accounts that left the ERP, went inactive, or fell out of the 24-month
  -- window. Without this they keep their last score forever. Rows written
  -- above carry computed_at = v_started exactly, so `<` spares them.
  delete from public.account_signals s
  where s.computed_at < v_started;

  perform public.log_job_run('refresh_account_signals', 'success',
                             v_rows::bigint, null, v_started);
  return v_rows;
end;
$$;

--------------------------------------------------------------------------
-- apply_account_scores — the cheap half. Pure arithmetic over stored
-- signals, so this is also what an admin's "save weights" runs.
--------------------------------------------------------------------------
create or replace function public.apply_account_scores(
    p_settings public.score_settings default null
) returns integer
language plpgsql
security definer set search_path = public
as $$
declare
  cfg    public.score_settings;
  v_rows int;
begin
  cfg := coalesce(p_settings, (select s from public.score_settings s where s.id));
  if cfg is null then
    raise exception 'score_settings_missing';
  end if;

  update public.account_signals t set
    score         = (x.j->>'score')::numeric,
    priority      = x.j->>'priority',
    score_cadence = (x.j->'subscores'->>'cadence')::numeric,
    score_recency = (x.j->'subscores'->>'recency')::numeric,
    score_trend   = (x.j->'subscores'->>'trend')::numeric,
    score_value   = (x.j->'subscores'->>'value')::numeric,
    score_mix     = (x.j->'subscores'->>'mix')::numeric,
    factors       = x.j->'factors',
    scored_at     = now()
  from (
    select s.customer_key, public.score_account(s, cfg) as j
    from public.account_signals s
  ) x
  where t.customer_key = x.customer_key;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

--------------------------------------------------------------------------
-- preview_account_scores — "what would the ranking look like under THESE
-- settings?" Writes nothing.
--
-- Cheap because it re-scores stored signals and never touches a fact table.
-- Same posture as create_mission(p_dry_run) in 016: admin-gated, bare error
-- codes for the client to translate.
--------------------------------------------------------------------------
create or replace function public.preview_account_scores(
    p_weights jsonb   default null,
    p_params  jsonb   default null,
    p_high    numeric default null,
    p_low     numeric default null,
    p_limit   int     default 25
) returns table (
    customer_key text, customer_name text, score numeric, priority text,
    score_cadence numeric, score_recency numeric, score_trend numeric,
    score_value numeric, score_mix numeric, factors jsonb
)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  cfg public.score_settings;
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  if coalesce(p_low, 0) >= coalesce(p_high, 1) then
    raise exception 'bands_out_of_order';
  end if;

  -- Plain assignment, NOT `select … into cfg`: with a composite target,
  -- SELECT INTO assigns column-by-column, so a single composite-typed column
  -- gets fed into the first field (`id boolean`) and fails with "invalid
  -- input syntax for type boolean". Assigning a scalar subquery keeps the
  -- row whole.
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
    select s.customer_key, public.score_account(s, cfg) as j
    from public.account_signals s
  )
  select
    sc.customer_key,
    c.customer_name,
    (sc.j->>'score')::numeric,
    sc.j->>'priority',
    (sc.j->'subscores'->>'cadence')::numeric,
    (sc.j->'subscores'->>'recency')::numeric,
    (sc.j->'subscores'->>'trend')::numeric,
    (sc.j->'subscores'->>'value')::numeric,
    (sc.j->'subscores'->>'mix')::numeric,
    sc.j->'factors'
  from scored sc
  left join erp.dim_customer c on c.customer_key = sc.customer_key
  where (sc.j->>'score') is not null
  order by (sc.j->>'score')::numeric desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$$;

--------------------------------------------------------------------------
-- Grants. The two job functions are not callable by app users at all; the
-- two admin-facing ones gate on is_admin() themselves (016's posture).
--------------------------------------------------------------------------
revoke execute on function public.refresh_account_signals()
  from public, anon, authenticated;
revoke execute on function public.apply_account_scores(public.score_settings)
  from public, anon;
revoke execute on function public.preview_account_scores(jsonb, jsonb, numeric, numeric, int)
  from public, anon;
revoke execute on function public.score_account(public.account_signals, public.score_settings)
  from public, anon;

grant execute on function public.apply_account_scores(public.score_settings) to authenticated;
grant execute on function public.preview_account_scores(jsonb, jsonb, numeric, numeric, int) to authenticated;
grant execute on function public.score_account(public.account_signals, public.score_settings) to authenticated;
grant execute on function public.clamp100(numeric) to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Add account_signals to the RLS test suite (§3.5): rep A must get zero
     rows for rep B's customer_key. New tables are the likeliest place for a
     leak — supabase/tests/019_scoring.sql does this.
  2. Run `select public.refresh_account_signals();` once by hand and TIME IT.
     It is two whole-book fact scans and it runs inside the ETL window.
  3. Two weights need real data before they can be trusted, and both degrade
     safely until then:
       - `select count(*), max(action_date) from public.actions;`
         If that is near zero, leave recency.treat_never_as = 'unknown'.
       - `select count(*) filter (where product_family is not null)::numeric
                 / count(*) from erp.dim_part;`
         If product_family is sparse, drop the mix weight to 0 and say so on
         the admin screen rather than ranking on a mostly-NULL column.
  4. Regenerate frontend/src/types/database.types.ts.
----------------------------------------------------------------------------*/
