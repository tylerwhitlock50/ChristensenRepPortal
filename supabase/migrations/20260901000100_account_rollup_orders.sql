/*============================================================================
  20260901000100_account_rollup_orders.sql — order-side windows on the
  account rollup + a table-shaped accounts read.

  Why
  ---
  Rep feedback asked for the Accounts page as a metric table: YTD/PYTD
  ships, PY total ships, YTD/PYTD orders (bookings), open orders, rep,
  goal and pace. The invoice-side windows already live on
  erp.agg_account_rollup (030, 20260817150000); the order-side ones do not,
  and no single view serves identity + rollup + goal in one round trip.

  What
  ----
    1. erp.agg_account_rollup gains bookings_ytd, bookings_prior_ytd
       (day-aligned, mirroring revenue_prior_ytd), open_order_count and
       last_order_date.
    2. refresh_territory_rollups() restated in full (single home of the
       window math) with the new columns.
    3. public.v_account_table — one row per customer joining dim_customer,
       the rollup, the open deactivation period (023's predicate) and the
       current-year goal row of v_account_goal_progress. Reads only
       pre-aggregated rows, so it stays far inside the authenticated
       role's 8s statement_timeout.
    4. First fill, so the table works before the next nightly ETL run.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Order-side windows on the account rollup.
--------------------------------------------------------------------------

alter table erp.agg_account_rollup
  add column if not exists bookings_ytd       numeric not null default 0,
  add column if not exists bookings_prior_ytd numeric not null default 0,
  add column if not exists open_order_count   int     not null default 0,
  add column if not exists last_order_date    date;

comment on column erp.agg_account_rollup.bookings_ytd is
  'Order value PLACED this calendar year (fact_order_line.bookings) — '
  'bookings, not revenue.';
comment on column erp.agg_account_rollup.bookings_prior_ytd is
  'Order value placed in the prior calendar year through the same date '
  '(day-aligned, mirroring revenue_prior_ytd).';
comment on column erp.agg_account_rollup.open_order_count is
  'Distinct orders with at least one backlog line.';
comment on column erp.agg_account_rollup.last_order_date is
  'max(fact_order_line.order_date) — order grain, unlike last_invoice_date.';

--------------------------------------------------------------------------
-- 2. The refresh, restated in full with the new columns.
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
    revenue_prior_full,
    bookings_ytd, bookings_prior_ytd, open_order_count, last_order_date
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
    coalesce(inv.revenue_prior_full, 0),
    coalesce(ord.bookings_ytd, 0),
    coalesce(ord.bookings_prior_ytd, 0),
    coalesce(ord.open_order_count, 0),
    ord.last_order_date
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
          sum(o.backlog_amount) filter (where o.is_backlog_line) as backlog_amount,
          sum(o.bookings) filter (
              where o.order_date >= date_trunc('year', current_date)::date
          )                                                      as bookings_ytd,
          sum(o.bookings) filter (
              where o.order_date >= (date_trunc('year', current_date) - interval '1 year')::date
                and o.order_date <= (current_date - interval '1 year')::date
          )                                                      as bookings_prior_ytd,
          count(distinct o.order_id) filter (where o.is_backlog_line) as open_order_count,
          max(o.order_date)                                      as last_order_date
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

  truncate erp.agg_customer_month;

  insert into erp.agg_customer_month (
    customer_key, sales_month, revenue, qty, invoice_count
  )
  select
      f.customer_key,
      date_trunc('month', f.invoice_date)::date,
      coalesce(sum(f.revenue), 0),
      coalesce(sum(f.invoice_qty), 0),
      count(distinct f.invoice_id)
  from erp.fact_invoice_line f
  where f.is_memo is not true
    and f.invoice_date is not null
    and f.invoice_date >= (date_trunc('year', current_date) - interval '3 years')::date
  group by f.customer_key, date_trunc('month', f.invoice_date)::date;

  rollup_name := 'agg_customer_month';
  get diagnostics row_count = row_count;
  return next;
end;
$$;

comment on function public.refresh_territory_rollups() is
  'Rebuilds erp.agg_account_rollup, erp.agg_sku_year and '
  'erp.agg_customer_month. Called by the ETL as its first post_load_sql '
  'step (etl/views.yml). Not callable by app roles — the ETL connects as '
  'postgres.';

revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 3. v_account_table — the accounts page's table mode, one round trip.
--    Goal join takes the current-year row of v_account_goal_progress;
--    that view yields at most one row per (customer, year) — a CRM goal
--    suppresses the ERP default (20260817140000).
--------------------------------------------------------------------------

create or replace view public.v_account_table
with (security_invoker = true)
as
select
    c.customer_key,
    c.customer_name,
    c.sold_to_city,
    c.sold_to_state,
    c.active_flag,
    c.assigned_sales_rep_name,
    -- Same greatest() as v_account_list (015): the ERP field is unmaintained
    -- but occasionally populated where facts are missing — without it, Cards
    -- and Table would show two different "Last order" dates.
    greatest(c.last_order_date, a.last_order_date) as last_order_date,
    a.last_invoice_date,
    coalesce(a.revenue_ytd, 0)::numeric        as revenue_ytd,
    coalesce(a.revenue_prior_ytd, 0)::numeric  as revenue_prior_ytd,
    coalesce(a.revenue_prior_full, 0)::numeric as revenue_prior_full,
    coalesce(a.bookings_ytd, 0)::numeric       as bookings_ytd,
    coalesce(a.bookings_prior_ytd, 0)::numeric as bookings_prior_ytd,
    coalesce(a.open_order_value, 0)::numeric   as open_order_value,
    coalesce(a.open_order_count, 0)::int       as open_order_count,
    gp.target_amount                           as goal_amount,
    gp.goal_source,
    gp.attainment_pct,
    gp.expected_pct,
    gp.on_track,
    d.deactivated_at
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
left join public.account_deactivations d
  on d.customer_key = c.customer_key
 and d.reactivated_at is null
left join public.v_account_goal_progress gp
  on gp.customer_key = c.customer_key
 and gp.period_year = extract(year from current_date)::int
where coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_account_table is
  'The accounts page''s table mode: identity + nightly rollup windows '
  '(ships and bookings, YTD/prior) + the current-year goal row. All '
  'pre-aggregated reads (erp.agg_account_rollup, see 030) — no fact-table '
  'scans. security_invoker: the caller''s RLS is the territory filter.';

revoke all on public.v_account_table from anon, public;
grant select on public.v_account_table to authenticated;

--------------------------------------------------------------------------
-- 4. First fill, so the table works before the next nightly ETL run.
--------------------------------------------------------------------------

select public.refresh_territory_rollups();
