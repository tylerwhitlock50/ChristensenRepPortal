/*============================================================================
  20261027090400_goal_active_customers.sql — ERP goals count only for
  accounts that are in the territory (G09).

  Why
  ---
  v_account_goal_progress's ERP branch (20260817140000, restated by
  20260817150000) takes every dim_customer row with a USER_3 goal, active
  or not. v_rep_goal_dashboard — the admin screen's per-rep total — and
  every v_territory_* view count only active, external accounts (025/029).
  So the same rep's goal was two numbers: on 2026-10-26 the PMI principal's
  book summed to $6,318,507.95 here against $5,987,088.75 on the dashboard.
  The $331,419.20 difference is nine accounts nobody sells to: eight closed
  (inactive) ones — including a $250,000 goal still sitting on a closed
  account of rep DUST GIBB — and one active internal account.

  A closed account's goal is not a target anyone is chasing; it only drags
  the book's attainment down and puts dead accounts in the "furthest
  behind" list.

  What
  ----
  The ERP branch gains the territory definition:
      active_flag = 'Y' and coalesce(internal_customer_flag, 'N') <> 'Y'
  — the exact predicate of v_rep_goal_dashboard (20260808090000). CRM goals
  (public.account_goals) are untouched: a goal a person typed in is shown
  until they remove it.

  Restated from LIVE (pg_get_viewdef on 2026-10-26), which is identical to
  20260817150000_goal_pace_from_rollup.sql (20260901000100 reads the view
  but does not restate it). Column list, names, types and order unchanged,
  so v_my_goal_rollup and the account list's goal join keep working.
============================================================================*/

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
        -- CRM goal exists for that account+year, and only for accounts in
        -- the territory — active and external, the v_rep_goal_dashboard /
        -- v_territory_* definition (20261027090400).
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
          and c2.active_flag = 'Y'
          and coalesce(c2.internal_customer_flag, 'N') <> 'Y'
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
  'master''s USER_3 field, current year, read-only default; null goal_id), '
  'for active external accounts only — the v_rep_goal_dashboard definition '
  '(20261027090400). Current-year windows come from erp.agg_account_rollup '
  '(see 030 and 20260817150000) so the whole-book rollup stays inside the '
  '8s statement_timeout; other years read fact_invoice_line live. '
  'security_invoker — RLS scopes to the caller''s book.';

revoke all on public.v_account_goal_progress from anon, public;
grant select on public.v_account_goal_progress to authenticated;
