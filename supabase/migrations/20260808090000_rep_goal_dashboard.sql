/*============================================================================
  20260808090000_rep_goal_dashboard.sql — admin roster: every rep vs their
  aggregate goal, shipped-this-year AND sold-this-year.

  The ask: one admin screen with every rep, current-year shipments vs goal
  and current-year sales (orders written) vs goal. The pieces exist but not
  in one place — v_rep_goal_attainment (023_account_goals) only counts
  accounts that have a CRM goal row and only measures invoice revenue.

  Two changes:

  1. erp.agg_account_rollup + bookings_ytd — booked order value (bookings,
     the ORDER-side headline measure) for orders dated this calendar year,
     canceled orders excluded. Computed in refresh_territory_rollups() with
     the other windows, same nightly freshness, so the dashboard never
     touches the 500k-row fact tables at request time (the whole point of
     030).

  2. public.v_rep_goal_dashboard — one row per rep profile:
       goal_total    per-account coalesce(CRM goal for the current year,
                     ERP yearly_sales_goal) summed over the rep's book.
                     CRM wins per account when both exist; either alone
                     still counts. Split out as crm/erp components so the
                     screen can say where the number came from.
       shipped_ytd   invoiced revenue YTD (agg_account_rollup.revenue_ytd —
                     memo lines already excluded by the refresh).
       booked_ytd    bookings_ytd summed the same way.
     Book = v_user_accounts restricted to the territory definition every
     other rollup surface uses (029/030): active, external accounts only,
     so a dead account's stale ERP goal can't inflate a rep's target.

  security_invoker like every admin view: an admin resolves every rep's
  whole book; a rep who somehow queried it would resolve only rows their
  own RLS lets them see. The /admin route stays admin-only in the app.
============================================================================*/

--------------------------------------------------------------------------
-- 1. bookings_ytd on the account rollup.
--------------------------------------------------------------------------
alter table erp.agg_account_rollup
  add column if not exists bookings_ytd numeric not null default 0;

comment on column erp.agg_account_rollup.bookings_ytd is
  'Booked order value (fact_order_line.bookings) for orders dated in the '
  'current calendar year, canceled orders (order_status = X) excluded. '
  'Rebuilt nightly with the rest of the row.';

--------------------------------------------------------------------------
-- 2. refresh_territory_rollups() — same body as 030 plus bookings_ytd in
--    the order-side subquery. This function is the single home of the
--    window definitions (030's header); this file is now its latest word.
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
    bookings_ytd
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
    coalesce(ord.bookings_ytd, 0)
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
          sum(o.backlog_amount) filter (where o.is_backlog_line) as backlog_amount,
          sum(o.bookings) filter (
              where o.order_date >= date_trunc('year', current_date)::date
                and coalesce(o.order_status, '') <> 'X'
          )                                                      as bookings_ytd
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

comment on function public.refresh_territory_rollups() is
  'Rebuilds erp.agg_account_rollup and erp.agg_sku_year. Called by the ETL '
  'as its first post_load_sql step (etl/views.yml). Not callable by app '
  'roles — the ETL connects as postgres.';

-- 017 conventions, restated after CREATE OR REPLACE.
revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 3. The dashboard view.
--------------------------------------------------------------------------
create or replace view public.v_rep_goal_dashboard
with (security_invoker = true)
as
select
    p.user_id,
    p.full_name,
    p.active,
    extract(year from current_date)::integer as period_year,
    b.assigned_accounts,
    b.accounts_with_goal,
    b.goal_total,
    b.crm_goal_total,
    b.erp_goal_total,
    b.shipped_ytd,
    b.booked_ytd,
    case when b.goal_total > 0::numeric
         then round(100::numeric * b.shipped_ytd / b.goal_total, 1) end as shipped_pct,
    case when b.goal_total > 0::numeric
         then round(100::numeric * b.booked_ytd / b.goal_total, 1) end as booked_pct
from public.profiles p
left join lateral (
    select
        count(*)::integer                                as assigned_accounts,
        (count(*) filter (
            where g.target_amount is not null
               or c.yearly_sales_goal is not null))::integer as accounts_with_goal,
        coalesce(sum(coalesce(g.target_amount, c.yearly_sales_goal)), 0)::numeric
                                                         as goal_total,
        coalesce(sum(g.target_amount), 0)::numeric       as crm_goal_total,
        coalesce(sum(c.yearly_sales_goal)
                   filter (where g.target_amount is null), 0)::numeric
                                                         as erp_goal_total,
        coalesce(sum(a.revenue_ytd), 0)::numeric         as shipped_ytd,
        coalesce(sum(a.bookings_ytd), 0)::numeric        as booked_ytd
    from public.v_user_accounts ua
    join erp.dim_customer c on c.customer_key = ua.customer_key
    left join erp.agg_account_rollup a on a.customer_key = ua.customer_key
    left join public.account_goals g
           on g.customer_key = ua.customer_key
          and g.period_year = extract(year from current_date)::integer
    -- Territory definition shared with v_territory_account_yoy (029/030).
    where ua.user_id = p.user_id
      and c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
) b on true
where p.role = 'rep';

comment on view public.v_rep_goal_dashboard is
  'One row per rep: current-year aggregate goal (CRM account_goals beats '
  'erp.dim_customer.yearly_sales_goal per account), invoiced revenue YTD '
  'and booked order value YTD from erp.agg_account_rollup (nightly), over '
  'active external accounts in the rep''s book. security_invoker — the '
  'admin screen reads it; RLS keeps it harmless elsewhere.';

revoke all on public.v_rep_goal_dashboard from anon, public;
grant select on public.v_rep_goal_dashboard to authenticated;

--------------------------------------------------------------------------
-- 4. First fill, so bookings_ytd is populated between "migration applied"
--    and the next nightly ETL run.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
