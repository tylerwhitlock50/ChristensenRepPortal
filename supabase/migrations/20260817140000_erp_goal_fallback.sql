/*============================================================================
  20260817140000_erp_goal_fallback.sql — ERP yearly goals count as goals.

  Why
  ---
  v_account_goal_progress built rows ONLY from public.account_goals (the
  CRM-entered targets), carrying erp.dim_customer.yearly_sales_goal along as
  a comparison column. account_goals has 0 rows, so every goal surface — the
  portal's goal tiles, v_my_goal_rollup, the MCP get_goal_progress tool —
  reported "no goals" while 603 accounts carry a real goal in the ERP.

  That ERP figure is maintained: it is the customer master's USER_3 field,
  verified 2026-08-17 — dbo.CUSTOMER.USER_3 → bi.vw_DimCustomer.YearlySalesGoal
  → erp.dim_customer.yearly_sales_goal, value-for-value (SPORTS SOUTH
  $6,916,593, LIPSEY'S $6,889,877.54, …).

  What changes
  ------------
  The progress view's source becomes a union:

    - every public.account_goals row, as before        (goal_source = 'crm')
    - PLUS, for the CURRENT year only, every account with a positive ERP
      yearly_sales_goal and no CRM goal for that year   (goal_source = 'erp')

  A CRM row for the same account+year always wins — entering a target in the
  portal overrides the ERP number, which keeps account_goals the editable
  source and the ERP the default. ERP goals are yearless in the source, so
  they only ever materialise for the current calendar year.

  `goal_source` is APPENDED as the last column; everything else keeps its
  name, type and position, so existing consumers (rep goal dashboard, MCP
  tools, v_my_goal_rollup / v_rep_goal_attainment which aggregate this view)
  see the same shape — plus 603 accounts' worth of rows they were missing.
  ERP-derived rows have goal_id/created_by/updated_by/updated_at NULL, which
  is also how the portal can tell "editable CRM goal" from "ERP default".
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
        coalesce(rev.revenue_to_date, 0::numeric) as revenue_to_date,
        case
            when e.days_elapsed = 0 then 'not_started'
            when coalesce(rev.prior_full, 0::numeric) > 0::numeric then 'seasonal'
            else 'straight_line'
        end as pace_basis,
        case
            when e.days_elapsed = 0 then 0::numeric
            when coalesce(rev.prior_full, 0::numeric) > 0::numeric
                then least(greatest(coalesce(rev.prior_to_date, 0::numeric)
                                    / rev.prior_full, 0::numeric), 1::numeric)
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
    cross join lateral (
        select make_date(g.period_year, 1, 1)      as period_start,
               make_date(g.period_year, 12, 31)    as period_end,
               make_date(g.period_year - 1, 1, 1)  as prior_start,
               make_date(g.period_year - 1, 12, 31) as prior_end
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
    left join lateral (
        select
            sum(f.revenue) filter (where f.invoice_date >= d.period_start
                                     and f.invoice_date <= w.as_of)      as revenue_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= x.prior_as_of) as prior_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= d.prior_end)   as prior_full
        from erp.fact_invoice_line f
        where f.customer_key = g.customer_key
          and f.is_memo is not true
          and f.invoice_date is not null
          and f.invoice_date >= d.prior_start
          and f.invoice_date <= greatest(w.as_of, d.prior_end)
    ) rev on true
) r;

comment on view public.v_account_goal_progress is
  'One row per account goal with seasonal/straight-line pace math. Sources '
  '(goal_source): ''crm'' = public.account_goals (editable, any year; wins '
  'on conflict); ''erp'' = dim_customer.yearly_sales_goal (the customer '
  'master''s USER_3 field, current year, read-only default). ERP rows have '
  'null goal_id. security_invoker — RLS scopes to the caller''s book.';

-- CREATE OR REPLACE preserves grants; restate for standalone replay.
revoke all on public.v_account_goal_progress from anon, public;
grant select on public.v_account_goal_progress to authenticated;
