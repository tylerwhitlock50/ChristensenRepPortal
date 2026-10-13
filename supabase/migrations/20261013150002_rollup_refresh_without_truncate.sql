/*============================================================================
  20261013150002_rollup_refresh_without_truncate.sql — the nightly rollup
  refresh stops locking readers out.

  Why
  ---
  refresh_territory_rollups() began each of its four blocks with
  `truncate erp.agg_*`. TRUNCATE takes ACCESS EXCLUSIVE, and the ETL runs
  the whole function as one post-load statement (push_to_supabase.py wraps
  each step in a transaction), so all four rollups stayed locked until the
  last insert committed. Every read of them waits that long: the Overview
  (v_territory_account_yoy), the Accounts table, the account header, goals,
  the AI brief, report_global_product_sales. The refresh runs at 5 PM
  Mountain, 4 PM for the Pacific reps who are still working, and the
  authenticated role gives up after 8 s. The same aggregates took 18 s
  company-wide when 030 measured them.

  20260901190400 fixed exactly this for the erp.* fact swaps (DELETE +
  INSERT instead of TRUNCATE) and left the rollups behind.

  What
  ----
  The function restated VERBATIM from its latest definition
  (20260901190100_rollup_restore.sql) with one kind of change: each of the
  four `truncate erp.X;` is now `delete from erp.X;`. (Plus, first, a
  SHARE ROW EXCLUSIVE lock on the four rollups — the old exclusive lock
  serialized two concurrent refreshes for free; DELETE does not, and the
  second run's INSERT would hit the first one's rows on the primary key.
  Readers' ACCESS SHARE does not conflict with it.) DELETE takes ROW
  EXCLUSIVE, which conflicts with no reader: until the function's
  transaction commits, every query keeps seeing the previous rollup in
  full, then sees tonight's in full. Nothing else in the body moved — this
  function has lost a block in three earlier restatements, so the build
  diffed this body against 20260901190100's line by line (four lines
  differ, all of them the truncates).

  The cost is dead tuples: ~41k account rows plus the SKU/month rollups
  each night. Autovacuum reclaims them, and the post-load ANALYZE below
  keeps the planner's row counts honest straight after the refresh.

  supabase/tests/20260901_rollup_restore.sql T1 now requires
  `delete from erp.<t>` for every erp.agg_* table (the every-table-is-
  cleared guarantee stays) and that no TRUNCATE is left.

  Also: public.analyze_territory_rollups()
  ----------------------------------------
  ANALYZE of the four rollups, as its own post_load_sql step after the
  refresh (etl/views.yml). A function rather than a bare `analyze …;` step
  because the loader fetches a result set from every step (psycopg's
  fetchall() raises on a command with no rows), and ANALYZE, unlike
  VACUUM, is allowed inside the transaction each step runs in.

  This migration does not run the refresh: tonight's ETL does, and the
  rollups on disk are already current.

  Backward compatible: same name, no arguments, same OUT columns, same
  owner, grants and pinned timezone (restated below — CREATE OR REPLACE
  resets the SET clauses to the ones it names, so the timezone pin from
  20260901190000 has to be said again or it is lost).
============================================================================*/

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
  -- One refresh at a time. A second run started during this one (a
  -- hand-run push.ps1 or SQL-editor call during the scheduled load) waits
  -- here, then clears and rebuilds what this one committed. Without the
  -- lock its DELETE skipped rows this run had just inserted and its INSERT
  -- collided with them on the primary key. SHARE ROW EXCLUSIVE conflicts
  -- with itself and with writers, never with a reader's ACCESS SHARE.
  lock table erp.agg_account_rollup, erp.agg_sku_year, erp.agg_customer_month,
             erp.agg_sku_month
    in share row exclusive mode;

  ------------------------------------------------------------------------
  -- 1. Account rollup. When you add a column to erp.agg_account_rollup,
  --    add it HERE and run supabase/tests/20260901_rollup_restore.sql.
  ------------------------------------------------------------------------
  delete from erp.agg_account_rollup;

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
  delete from erp.agg_sku_year;

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
  delete from erp.agg_customer_month;

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
  delete from erp.agg_sku_month;

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
  'and erp.agg_sku_month with DELETE + INSERT (never TRUNCATE: readers keep '
  'the previous rollup until commit; one run at a time — 20261013150002). '
  'Called by the ETL as '
  'its first post_load_sql step (etl/views.yml). Not callable by app roles — '
  'the ETL connects as postgres. THE SINGLE HOME OF EVERY WINDOW: when '
  'restating, diff the insert column list against the LIVE table and run '
  'supabase/tests/20260901_rollup_restore.sql — three restatements have '
  'lost columns (bookings_ytd, first_invoice_date, agg_sku_month).';

revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

-- CREATE OR REPLACE replaced the function's SET list with the one above
-- (search_path only), so the Mountain-time pin from 20260901190000 must be
-- restated here or the refresh would compute "today" in UTC.
alter function public.refresh_territory_rollups() set timezone to 'America/Denver';

--------------------------------------------------------------------------
-- analyze_territory_rollups() — fresh planner statistics after the refresh.
--------------------------------------------------------------------------
create or replace function public.analyze_territory_rollups()
returns table (rollup_name text)
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- One table per statement, in the refresh's order. Run by the ETL as
  -- postgres, the tables' owner; ANALYZE is legal inside the step's
  -- transaction (VACUUM would not be).
  analyze erp.agg_account_rollup;
  rollup_name := 'agg_account_rollup';
  return next;

  analyze erp.agg_sku_year;
  rollup_name := 'agg_sku_year';
  return next;

  analyze erp.agg_customer_month;
  rollup_name := 'agg_customer_month';
  return next;

  analyze erp.agg_sku_month;
  rollup_name := 'agg_sku_month';
  return next;
end;
$$;

comment on function public.analyze_territory_rollups() is
  'ANALYZE the four erp.agg_* rollups. Run by the ETL as a post_load_sql step '
  'after refresh_territory_rollups() (etl/views.yml). Job-only: not '
  'executable by app roles (20261013150002).';

revoke execute on function public.analyze_territory_rollups()
  from public, anon, authenticated;
