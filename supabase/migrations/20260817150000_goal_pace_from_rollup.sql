/*============================================================================
  20260817150000_goal_pace_from_rollup.sql — goal pace reads the nightly
  rollup for current-year rows.

  Why
  ---
  20260817140000 unioned the 637 ERP USER_3 goals into
  v_account_goal_progress, which made the whole-book consumers
  (v_my_goal_rollup, the "furthest behind" list) execute the per-account
  fact_invoice_line lateral 637 times. Warm that is ~260ms; cold it measured
  9.6s — over the authenticated role's 8s statement_timeout, the same
  failure mode 030 fixed for the territory views.

  Same cure as 030: erp.agg_account_rollup already carries revenue_ytd and
  the day-aligned revenue_prior_ytd, which are exactly revenue_to_date and
  prior_to_date for a current-calendar-year goal. It gains one column here —
  revenue_prior_full (the full prior calendar year) — so the seasonal pace
  fraction can be computed from the rollup too.

  The live fact lateral remains ONLY for goals in other years (CRM-entered
  history), gated inside the subquery so the planner skips it for
  current-year rows. ERP-derived goals are always current-year, so the
  common path is one indexed join against ~41k pre-aggregated rows.

  Freshness: pace figures are now as-of the last ETL refresh for
  current-year goals — identical to the territory views, and to the data
  itself. Day-alignment nuance: prior_to_date becomes "same date last year"
  instead of the day-fraction mapping; they differ by at most a day around
  leap years, and agreeing with the Overview's YoY numbers is worth more.
============================================================================*/

--------------------------------------------------------------------------
-- 1. One more window on the account rollup: the full prior calendar year.
--------------------------------------------------------------------------

alter table erp.agg_account_rollup
  add column if not exists revenue_prior_full numeric not null default 0;

comment on column erp.agg_account_rollup.revenue_prior_full is
  'Invoiced revenue over the ENTIRE prior calendar year (Jan 1 – Dec 31). '
  'Denominator of the seasonal goal-pace fraction (v_account_goal_progress).';

--------------------------------------------------------------------------
-- 2. The refresh, restated in full (single home of the window math)
--    with the new column added.
--------------------------------------------------------------------------

create or replace function public.refresh_territory_rollups()
returns table (rollup_name text, row_count bigint)
language plpgsql
security definer
set search_path = public, erp
as $$
begin
  truncate erp.agg_account_rollup;

  insert into erp.agg_account_rollup (
    customer_key, revenue_ytd, revenue_prior_ytd, revenue_trailing_12m,
    last_invoice_date, open_order_value, backlog_qty, backlog_amount,
    revenue_prior_full
  )
  select
    c.customer_key,
    coalesce(inv.revenue_ytd, 0),
    coalesce(inv.revenue_prior_ytd, 0),
    coalesce(inv.revenue_trailing_12m, 0),
    inv.last_invoice_date,
    coalesce(ord.open_order_value, 0),
    coalesce(ord.backlog_qty, 0),
    coalesce(ord.backlog_amount, 0),
    coalesce(inv.revenue_prior_full, 0)
  from erp.dim_customer c
  left join (
      select
          f.customer_key,
          sum(f.revenue) filter (
              where f.invoice_date >= date_trunc('year', current_date)::date
          )                                          as revenue_ytd,
          sum(f.revenue) filter (
              where f.invoice_date >= (date_trunc('year', current_date) - interval '1 year')::date
                and f.invoice_date <= (current_date - interval '1 year')::date
          )                                          as revenue_prior_ytd,
          sum(f.revenue) filter (
              where f.invoice_date > (current_date - interval '12 months')::date
          )                                          as revenue_trailing_12m,
          sum(f.revenue) filter (
              where f.invoice_date >= (date_trunc('year', current_date) - interval '1 year')::date
                and f.invoice_date <  date_trunc('year', current_date)::date
          )                                          as revenue_prior_full,
          max(f.invoice_date)                        as last_invoice_date
      from erp.fact_invoice_line f
      where f.is_memo is not true        -- NULL-safe; see 011 header
        and f.invoice_date is not null
      group by f.customer_key
  ) inv on inv.customer_key = c.customer_key
  left join (
      select
          o.customer_key,
          sum(o.backlog_amount) filter (where o.is_backlog_line) as open_order_value,
          sum(o.backlog_qty)    filter (where o.is_backlog_line) as backlog_qty,
          sum(o.backlog_amount) filter (where o.is_backlog_line) as backlog_amount
      from erp.fact_order_line o
      group by o.customer_key
  ) ord on ord.customer_key = c.customer_key
  where inv.customer_key is not null or ord.customer_key is not null;

  rollup_name := 'agg_account_rollup';
  get diagnostics row_count = row_count;
  return next;

  truncate erp.agg_sku_year;

  insert into erp.agg_sku_year (
    customer_key, part_key, sales_year, revenue, qty, invoice_count,
    last_invoice_date
  )
  select
      f.customer_key,
      f.part_key,
      extract(year from f.invoice_date)::int,
      coalesce(sum(f.revenue), 0),
      coalesce(sum(f.invoice_qty), 0),
      count(distinct f.invoice_id),
      max(f.invoice_date)
  from erp.fact_invoice_line f
  where f.is_memo is not true
    and f.invoice_date is not null
    and f.part_key is not null
    and f.invoice_date >= (date_trunc('year', current_date) - interval '3 years')::date
  group by f.customer_key, f.part_key, extract(year from f.invoice_date)::int;

  rollup_name := 'agg_sku_year';
  get diagnostics row_count = row_count;
  return next;
end;
$$;

revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 3. The goal progress view: current-year rows read the rollup; the live
--    fact lateral only runs for other years (gated inside the subquery).
--------------------------------------------------------------------------

create or replace view public.v_account_goal_progress
with (security_invoker = true)
as
select
    goal_id, customer_key, customer_name, sold_to_city, sold_to_state,
    active_flag, period_year, target_amount, note, created_by, updated_by,
    updated_at, erp_yearly_sales_goal, period_start, period_end, as_of,
    days_elapsed, days_total,
    greatest(days_total - days_elapsed, 0)                     as days_remaining,
    revenue_to_date, pace_basis,
    round(100::numeric * revenue_to_date / target_amount, 1)   as attainment_pct,
    round(100::numeric * expected_frac, 1)                     as expected_pct,
    round(target_amount * expected_frac, 2)                    as expected_amount,
    round(revenue_to_date - target_amount * expected_frac, 2)  as gap_to_pace,
    round(greatest(target_amount - revenue_to_date, 0::numeric), 2) as gap_to_goal,
    case when expected_frac > 0::numeric
         then round(revenue_to_date / expected_frac, 2) end    as projected_amount,
    case when days_elapsed = 0 then null::boolean
         else revenue_to_date >= target_amount * expected_frac end as on_track,
    goal_source
from (
    select
        g.goal_id,
        g.customer_key,
        c.customer_name,
        c.sold_to_city,
        c.sold_to_state,
        c.active_flag,
        c.yearly_sales_goal as erp_yearly_sales_goal,
        g.period_year,
        g.target_amount,
        g.note,
        g.created_by,
        g.updated_by,
        g.updated_at,
        g.goal_source,
        d.period_start,
        d.period_end,
        w.as_of,
        w.days_total,
        e.days_elapsed,
        coalesce(win.revenue_to_date, 0::numeric) as revenue_to_date,
        case
            when e.days_elapsed = 0 then 'not_started'
            when coalesce(win.prior_full, 0::numeric) > 0::numeric then 'seasonal'
            else 'straight_line'
        end as pace_basis,
        case
            when e.days_elapsed = 0 then 0::numeric
            when coalesce(win.prior_full, 0::numeric) > 0::numeric
                then least(greatest(coalesce(win.prior_to_date, 0::numeric)
                                    / win.prior_full, 0::numeric), 1::numeric)
            else e.days_elapsed::numeric / w.days_total::numeric
        end as expected_frac
    from (
        -- CRM-entered goals: the editable source, any year.
        select
            ag.id as goal_id,
            ag.customer_key,
            ag.period_year,
            ag.target_amount,
            ag.note,
            ag.created_by,
            ag.updated_by,
            ag.updated_at,
            'crm'::text as goal_source
        from public.account_goals ag
        union all
        -- ERP default (dbo.CUSTOMER.USER_3): current year, only where no
        -- CRM goal exists for that account+year.
        select
            null::bigint,
            c2.customer_key,
            extract(year from current_date)::int,
            c2.yearly_sales_goal,
            null::text,
            null::uuid,
            null::uuid,
            null::timestamptz,
            'erp'::text
        from erp.dim_customer c2
        where c2.yearly_sales_goal > 0::numeric
          and not exists (
              select 1
              from public.account_goals ag2
              where ag2.customer_key = c2.customer_key
                and ag2.period_year = extract(year from current_date)::int
          )
    ) g
    left join erp.dim_customer c on c.customer_key = g.customer_key
    left join erp.agg_account_rollup ar on ar.customer_key = g.customer_key
    cross join lateral (
        select make_date(g.period_year, 1, 1)      as period_start,
               make_date(g.period_year, 12, 31)    as period_end,
               make_date(g.period_year - 1, 1, 1)  as prior_start,
               make_date(g.period_year - 1, 12, 31) as prior_end,
               g.period_year = extract(year from current_date)::int as is_current_year
    ) d
    cross join lateral (
        select least(current_date, d.period_end)      as as_of,
               (d.period_end - d.period_start) + 1    as days_total,
               (d.prior_end - d.prior_start) + 1      as prior_days
    ) w
    cross join lateral (
        select greatest((w.as_of - d.period_start) + 1, 0) as days_elapsed
    ) e
    cross join lateral (
        select (d.prior_start
                + round(e.days_elapsed::numeric / w.days_total::numeric
                        * w.prior_days::numeric)::integer) - 1 as prior_as_of
    ) x
    -- Live windows for NON-current years only. The gate is the first WHERE
    -- term, constant per outer row, so the planner short-circuits the whole
    -- scan for current-year rows (one-time filter).
    left join lateral (
        select
            sum(f.revenue) filter (where f.invoice_date >= d.period_start
                                     and f.invoice_date <= w.as_of)      as revenue_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= x.prior_as_of) as prior_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= d.prior_end)   as prior_full
        from erp.fact_invoice_line f
        where not d.is_current_year
          and f.customer_key = g.customer_key
          and f.is_memo is not true
          and f.invoice_date is not null
          and f.invoice_date >= d.prior_start
          and f.invoice_date <= greatest(w.as_of, d.prior_end)
    ) rev on true
    cross join lateral (
        select
            case when d.is_current_year
                 then coalesce(ar.revenue_ytd, 0::numeric)
                 else rev.revenue_to_date end        as revenue_to_date,
            case when d.is_current_year
                 then ar.revenue_prior_ytd
                 else rev.prior_to_date end          as prior_to_date,
            case when d.is_current_year
                 then ar.revenue_prior_full
                 else rev.prior_full end             as prior_full
    ) win
) r;

comment on view public.v_account_goal_progress is
  'One row per account goal with seasonal/straight-line pace math. Sources '
  '(goal_source): ''crm'' = public.account_goals (editable, any year; wins '
  'on conflict); ''erp'' = dim_customer.yearly_sales_goal (the customer '
  'master''s USER_3 field, current year, read-only default; null goal_id). '
  'Current-year windows come from erp.agg_account_rollup (nightly, see 030 '
  'and 20260817150000) so the whole-book rollup stays inside the 8s '
  'statement_timeout; other years read fact_invoice_line live. '
  'security_invoker — RLS scopes to the caller''s book.';

revoke all on public.v_account_goal_progress from anon, public;
grant select on public.v_account_goal_progress to authenticated;

--------------------------------------------------------------------------
-- 4. First fill of the new column, so pace works between "migration
--    applied" and the next nightly ETL run.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
