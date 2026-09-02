/*============================================================================
  20260901190100_rollup_restore.sql — refresh_territory_rollups() restated
  from the LIVE tables, with every window it has ever carried.

  Why
  ---
  20260901000100 restated this function from an older body and silently
  dropped three things later migrations had added (the CLI hotfix
  20260901182504 carried the same holes):

    1. first_invoice_date (20260817170000) — every rollup row was null, so
       v_territory_account_yoy.first_invoice_date and the MCP's "new
       accounts" sort treated every account as never-invoiced.
    2. coalesce(order_status, '') <> 'X' on bookings (20260808090000) —
       bookings_ytd counted ~$735k of cancelled orders.
    3. the erp.agg_sku_month block (20260818212142) — frozen at August, so
       report_global_product_sales and report_account_sku_gaps drifted
       further every night.

  This is the third time a restatement has lost a column (20260818212142's
  header tells the same story about bookings_ytd). The guard is now
  mechanical: supabase/tests/20260901_rollup_restore.sql asserts that the
  insert column list equals the live table and that every erp.agg_* table
  is truncated in the body. Run it after any future restatement.

  Also in this file
  -----------------
  open_order_value and backlog_amount were the same expression since 025
  (both: sum(backlog_amount) where is_backlog_line), so the Overview showed
  one figure in two tiles. They now mean two things:

    open_order_value  everything still owed on open orders   ("on order")
    backlog_amount    the subset whose promise date has passed ("late")

  backlog_qty stays paired with open_order_value (all still-owed units) —
  the account header prints it next to that figure.

  Dates use current_date, which is Mountain time as of 20260901190000.
============================================================================*/

comment on column erp.agg_account_rollup.open_order_value is
  'Sum of fact_order_line.backlog_amount over is_backlog_line — everything '
  'still owed on open orders, hold included ("on order"). See 20260901190100.';

comment on column erp.agg_account_rollup.backlog_amount is
  'The subset of open_order_value whose promise_date is before today — '
  'open order value that is LATE. Lines with no promise date are never '
  'late. Was identical to open_order_value until 20260901190100.';

comment on column erp.agg_account_rollup.backlog_qty is
  'Units still owed on open orders (pairs with open_order_value, not with '
  'backlog_amount).';

comment on column erp.agg_account_rollup.first_invoice_date is
  'min(non-memo invoice_date) — when this account first bought. Null only '
  'for accounts with no invoices at all.';

create or replace function public.refresh_territory_rollups()
returns table (rollup_name text, row_count bigint)
language plpgsql
security definer
set search_path = public, erp
as $$
declare
  -- One "today" for the whole run: Mountain time (20260901190000), pinned
  -- once so a refresh straddling midnight uses the same date everywhere.
  today constant date := current_date;
begin
  ------------------------------------------------------------------------
  -- 1. Account rollup. When you add a column to erp.agg_account_rollup,
  --    add it HERE and run supabase/tests/20260901_rollup_restore.sql.
  ------------------------------------------------------------------------
  truncate erp.agg_account_rollup;

  insert into erp.agg_account_rollup (
    customer_key,
    revenue_ytd, revenue_prior_ytd, revenue_trailing_12m, revenue_prior_full,
    first_invoice_date, last_invoice_date,
    open_order_value, backlog_qty, backlog_amount, open_order_count, last_order_date,
    bookings_ytd, bookings_prior_ytd
  )
  select
    c.customer_key,
    coalesce(inv.revenue_ytd, 0),
    coalesce(inv.revenue_prior_ytd, 0),
    coalesce(inv.revenue_trailing_12m, 0),
    coalesce(inv.revenue_prior_full, 0),
    inv.first_invoice_date,
    inv.last_invoice_date,
    coalesce(ord.open_order_value, 0),
    coalesce(ord.backlog_qty, 0),
    coalesce(ord.backlog_amount, 0),
    coalesce(ord.open_order_count, 0),
    ord.last_order_date,
    coalesce(ord.bookings_ytd, 0),
    coalesce(ord.bookings_prior_ytd, 0)
  from erp.dim_customer c
  left join (
      select
          f.customer_key,
          sum(f.revenue) filter (
              where f.invoice_date >= date_trunc('year', today)::date
          )                                          as revenue_ytd,
          sum(f.revenue) filter (
              where f.invoice_date >= (date_trunc('year', today) - interval '1 year')::date
                and f.invoice_date <= (today - interval '1 year')::date
          )                                          as revenue_prior_ytd,
          sum(f.revenue) filter (
              where f.invoice_date > (today - interval '12 months')::date
          )                                          as revenue_trailing_12m,
          sum(f.revenue) filter (
              where f.invoice_date >= (date_trunc('year', today) - interval '1 year')::date
                and f.invoice_date <  date_trunc('year', today)::date
          )                                          as revenue_prior_full,
          min(f.invoice_date)                        as first_invoice_date,
          max(f.invoice_date)                        as last_invoice_date
      from erp.fact_invoice_line f
      where f.is_memo is not true        -- NULL-safe; see 011 header
        and f.invoice_date is not null
      group by f.customer_key
  ) inv on inv.customer_key = c.customer_key
  left join (
      select
          o.customer_key,
          sum(o.backlog_amount) filter (where o.is_backlog_line)   as open_order_value,
          sum(o.backlog_qty)    filter (where o.is_backlog_line)   as backlog_qty,
          sum(o.backlog_amount) filter (
              where o.is_backlog_line and o.promise_date < today
          )                                                        as backlog_amount,
          count(distinct o.order_id) filter (where o.is_backlog_line)
                                                                   as open_order_count,
          max(o.order_date)                                        as last_order_date,
          -- Bookings exclude cancelled orders (status X): a cancelled order
          -- was placed, but it is not demand.
          sum(o.bookings) filter (
              where o.order_date >= date_trunc('year', today)::date
                and coalesce(o.order_status, '') <> 'X'
          )                                                        as bookings_ytd,
          sum(o.bookings) filter (
              where o.order_date >= (date_trunc('year', today) - interval '1 year')::date
                and o.order_date <= (today - interval '1 year')::date
                and coalesce(o.order_status, '') <> 'X'
          )                                                        as bookings_prior_ytd
      from erp.fact_order_line o
      group by o.customer_key
  ) ord on ord.customer_key = c.customer_key
  where inv.customer_key is not null or ord.customer_key is not null;

  rollup_name := 'agg_account_rollup';
  get diagnostics row_count = row_count;
  return next;

  ------------------------------------------------------------------------
  -- 2. SKU × year (current + 3 prior years).
  ------------------------------------------------------------------------
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
    and f.invoice_date >= (date_trunc('year', today) - interval '3 years')::date
  group by f.customer_key, f.part_key, extract(year from f.invoice_date)::int;

  rollup_name := 'agg_sku_year';
  get diagnostics row_count = row_count;
  return next;

  ------------------------------------------------------------------------
  -- 3. Customer × month (current + 3 prior years) — report_sales_by_month.
  ------------------------------------------------------------------------
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
    and f.invoice_date >= (date_trunc('year', today) - interval '3 years')::date
  group by f.customer_key, date_trunc('month', f.invoice_date)::date;

  rollup_name := 'agg_customer_month';
  get diagnostics row_count = row_count;
  return next;

  ------------------------------------------------------------------------
  -- 4. Customer × SKU × month, 36 whole months + the current partial one —
  --    report_global_product_sales and report_account_sku_gaps.
  ------------------------------------------------------------------------
  truncate erp.agg_sku_month;

  insert into erp.agg_sku_month (
    customer_key, part_key, sales_month, revenue, qty, invoice_count
  )
  select
      f.customer_key,
      f.part_key,
      date_trunc('month', f.invoice_date)::date,
      coalesce(sum(f.revenue), 0),
      coalesce(sum(f.invoice_qty), 0),
      count(distinct f.invoice_id)
  from erp.fact_invoice_line f
  where f.is_memo is not true
    and f.invoice_date is not null
    and f.part_key is not null
    -- 36 = report_global_product_sales' p_months ceiling; month-aligned
    -- exactly as that function's own filter is.
    and f.invoice_date >= (date_trunc('month', today) - interval '36 months')::date
  group by f.customer_key, f.part_key, date_trunc('month', f.invoice_date)::date;

  rollup_name := 'agg_sku_month';
  get diagnostics row_count = row_count;
  return next;
end;
$$;

comment on function public.refresh_territory_rollups() is
  'Rebuilds erp.agg_account_rollup, erp.agg_sku_year, erp.agg_customer_month '
  'and erp.agg_sku_month. Called by the ETL as its first post_load_sql step '
  '(etl/views.yml). Not callable by app roles — the ETL connects as postgres. '
  'THE SINGLE HOME OF EVERY WINDOW: when restating, diff the insert column '
  'list against the LIVE table and run '
  'supabase/tests/20260901_rollup_restore.sql — three restatements have '
  'lost columns (bookings_ytd, first_invoice_date, agg_sku_month).';

revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

-- 20260901190000 pinned the timezone on the previous definition; create or
-- replace keeps proconfig, but say it again so this file stands alone.
alter function public.refresh_territory_rollups() set timezone to 'America/Denver';

--------------------------------------------------------------------------
-- First fill, then prove it — the exact symptoms this file repairs.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();

do $$
declare
  n_null_first bigint;
  sku_month_max date;
begin
  select count(*) into n_null_first
  from erp.agg_account_rollup
  where first_invoice_date is null and revenue_trailing_12m <> 0;
  if n_null_first > 0 then
    raise exception 'rollup_restore: % invoiced accounts still have no first_invoice_date', n_null_first;
  end if;

  select max(sales_month) into sku_month_max from erp.agg_sku_month;
  if sku_month_max is null
     or sku_month_max < (date_trunc('month', current_date) - interval '1 month')::date then
    raise exception 'rollup_restore: agg_sku_month is stale (max month %)', sku_month_max;
  end if;
end;
$$;
