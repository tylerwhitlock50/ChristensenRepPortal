/*============================================================================
  20260818120000_intel_rollups.sql — the request-time fact scans that 030
  missed, plus a bookings_ytd repair.

  Why
  ---
  Measured on this database (2026-08-18):

      report_global_product_sales(12, 500) .... 10.75 s   (/intel/global —
                                                over the 8s statement_timeout,
                                                so the page can 500 outright)
      v_account_summary for LIPSEYS ..........   2.31 s   (30,876 invoice
                                                lines + 27,908 order lines
                                                re-aggregated per page view)
      v_sku_sales_by_account for LIPSEYS .....   2.33 s cold / 0.32 s warm
      report_account_sku_gaps(LIPSEYS) .......   1.45 s

  All four still aggregate raw erp.fact_invoice_line / fact_order_line at
  request time. 030's header said v_sku_sales_by_account would read
  erp.agg_sku_year, but only the territory view was ever re-pointed. Same
  fix as 030/20260817160000: the ERP data changes once a night, so nothing
  request-time should touch a fact table.

  Changes
  -------
  1. erp.agg_sku_month — (customer, part, calendar month), 36 whole months
     + the current partial month: the exact window family
     report_global_product_sales and report_account_sku_gaps clamp to.
     Month cells partition invoices per part (one invoice = one customer,
     one date), so per-cell count(distinct invoice_id) SUMS exactly to the
     per-part invoice count, and count(distinct customer_key) over cells is
     the exact account/dealer breadth. Both definer functions become
     rollup group-bys (~72k narrow rows) instead of fact scans.

  2. erp.agg_account_rollup + last_order_date, open_order_count — the two
     order-side figures v_account_summary still computed live. The view now
     reads the rollup alone; column list unchanged.

  3. v_sku_sales_by_account re-pointed at erp.agg_sku_year — finishing
     030's stated intent. Column list unchanged. (Lines with a null
     part_key drop out, as they already did in v_territory_sku_sales.)

  4. bookings_ytd REPAIRED: the 20260817170000 restatement of
     refresh_territory_rollups() omitted the bookings_ytd column that
     20260808090000 added, so every rollup row has $0 bookings today and
     v_rep_goal_dashboard / v_channel_performance under-report. This file's
     restatement carries it again. THE LESSON, RESTATED: this function is
     the single home of every window; when you restate it, diff the insert
     column list against the live table, not against the last migration
     you happen to remember.

  Freshness semantics are 030's: windows are as of the nightly refresh,
  same as the data itself; v_data_freshness already says so.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The month-grain SKU rollup. Same ownership/RLS shape as 030's tables.
--------------------------------------------------------------------------

create table if not exists erp.agg_sku_month (
    customer_key  text not null,
    part_key      text not null,
    sales_month   date not null,   -- first day of the month
    revenue       numeric not null default 0,
    qty           numeric not null default 0,
    invoice_count int not null default 0,
    primary key (customer_key, part_key, sales_month)
);

comment on table erp.agg_sku_month is
  'Invoiced units/revenue per (customer, part, calendar month), trailing 36 '
  'whole months + the current partial month — the window family the global '
  'intel and SKU-gap functions clamp to. Rebuilt nightly by '
  'public.refresh_territory_rollups(). Month cells partition invoices per '
  'part, so invoice_count sums exactly and count(distinct customer_key) is '
  'exact breadth.';

-- Both definer functions filter by month range and group by part; give the
-- window slice a path that does not start at customer_key.
create index if not exists idx_agg_sku_month_month
  on erp.agg_sku_month (sales_month);

alter table erp.agg_sku_month enable row level security;

drop policy if exists "read own agg_sku_month" on erp.agg_sku_month;
create policy "read own agg_sku_month" on erp.agg_sku_month
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

grant select on erp.agg_sku_month to authenticated;
revoke all on erp.agg_sku_month from anon, public;

--------------------------------------------------------------------------
-- 2. The two order-side columns v_account_summary still computed live.
--------------------------------------------------------------------------

alter table erp.agg_account_rollup
  add column if not exists last_order_date date,
  add column if not exists open_order_count int not null default 0;

comment on column erp.agg_account_rollup.last_order_date is
  'max(fact_order_line.order_date) — all orders, not just backlog. '
  'v_account_summary folds in dim_customer.last_order_date via greatest().';

comment on column erp.agg_account_rollup.open_order_count is
  'count(distinct order_id) over backlog lines — "how many orders are '
  'open?", matching v_account_summary''s original definition (015).';

--------------------------------------------------------------------------
-- 3. The refresh, restated in full: bookings_ytd restored (see header),
--    last_order_date + open_order_count added, agg_sku_month appended.
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
    bookings_ytd, revenue_prior_full, first_invoice_date,
    last_order_date, open_order_count
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
    coalesce(ord.bookings_ytd, 0),
    coalesce(inv.revenue_prior_full, 0),
    inv.first_invoice_date,
    ord.last_order_date,
    coalesce(ord.open_order_count, 0)
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
          max(f.invoice_date)                        as last_invoice_date,
          min(f.invoice_date)                        as first_invoice_date
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
          )                                                      as bookings_ytd,
          max(o.order_date)                                      as last_order_date,
          count(distinct o.order_id) filter (where o.is_backlog_line)
                                                                 as open_order_count
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
    -- 36 = report_global_product_sales' p_months ceiling; the boundary is
    -- month-aligned exactly as the function's own filter is.
    and f.invoice_date >= (date_trunc('month', current_date) - interval '36 months')::date
  group by f.customer_key, f.part_key, date_trunc('month', f.invoice_date)::date;

  rollup_name := 'agg_sku_month';
  get diagnostics row_count = row_count;
  return next;
end;
$$;

comment on function public.refresh_territory_rollups() is
  'Rebuilds erp.agg_account_rollup, erp.agg_sku_year, erp.agg_customer_month '
  'and erp.agg_sku_month. Called by the ETL as its first post_load_sql step '
  '(etl/views.yml). Not callable by app roles — the ETL connects as '
  'postgres. When restating this body, diff the insert column lists against '
  'the LIVE tables (this file exists because a restatement silently zeroed '
  'bookings_ytd).';

revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 4. v_sku_sales_by_account re-pointed at the year rollup — 030's stated
--    intent, finally true. Column list, names, and types unchanged.
--------------------------------------------------------------------------

create or replace view public.v_sku_sales_by_account
with (security_invoker = true)
as
select
    s.customer_key,
    s.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    p.upc,
    s.sales_year,
    s.revenue,
    s.qty,
    s.invoice_count,
    s.last_invoice_date
from erp.agg_sku_year s
left join erp.dim_part p on p.part_key = s.part_key;

comment on view public.v_sku_sales_by_account is
  'SKU × calendar year for one account (current + 3 prior years), read from '
  'erp.agg_sku_year (refreshed nightly — see 030). security_invoker: RLS on '
  'the rollup scopes it to the caller''s book. Always query with '
  '.eq(customer_key); page with .order(part_key).order(sales_year).range() — '
  'a big dealer exceeds PostgREST''s 1,000-row cap.';

--------------------------------------------------------------------------
-- 5. v_account_summary re-pointed at the account rollup. Column list,
--    names, and types unchanged; the two order-side figures it still
--    computed live now come from the columns added in §2.
--------------------------------------------------------------------------

create or replace view public.v_account_summary
with (security_invoker = true)
as
select
    c.customer_key,
    coalesce(a.revenue_ytd, 0)::numeric              as revenue_ytd,
    coalesce(a.revenue_prior_ytd, 0)::numeric        as revenue_prior_ytd,
    coalesce(a.revenue_trailing_12m, 0)::numeric     as revenue_trailing_12m,
    greatest(c.last_order_date, a.last_order_date)   as last_order_date,
    a.last_invoice_date,
    coalesce(a.open_order_count, 0)::int             as open_order_count,
    coalesce(a.open_order_value, 0)::numeric         as open_order_value,
    coalesce(a.backlog_qty, 0)::numeric              as backlog_qty
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key;

comment on view public.v_account_summary is
  'One row per account: YTD vs prior-YTD vs trailing-12m revenue, last '
  'order/invoice dates, and open-order count/value/qty — all read from '
  'erp.agg_account_rollup (nightly; see 030/20260818120000). '
  'last_order_date is greatest(dim_customer.last_order_date, rollup''s '
  'max order_date), harmonized with v_account_list (015). security_invoker: '
  'driven off erp.dim_customer so the caller sees only their book.';

--------------------------------------------------------------------------
-- 6. report_global_product_sales over the month rollup. Same signature,
--    same OUT columns, same clamps, same window semantics; 026/033's
--    standing rules unchanged (definer, aggregates only, never a customer
--    or dollar column — supabase/tests/024_intel_views.sql enforces it).
--    Aggregate first, join dim_part after: the group-by runs over three
--    narrow columns instead of seven.
--------------------------------------------------------------------------

create or replace function public.report_global_product_sales(
    p_months int default 12,
    p_limit  int default 500
)
returns table (
    part_key         text,
    part_id          text,
    part_description text,
    product_code     text,
    product_family   text,
    chambering       text,
    barrel_length    text,
    qty              numeric,
    invoice_count    int,
    account_count    int
)
language sql
stable
security definer
set search_path = ''
as $$
  select
      s.part_key,
      p.part_id,
      p.part_description,
      p.product_code,
      p.product_family,
      p.chambering,
      p.barrel_length,
      s.qty,
      s.invoice_count,
      s.account_count
  from (
      select
          m.part_key,
          coalesce(sum(m.qty), 0)::numeric      as qty,
          -- Month cells partition invoices per part (one invoice = one
          -- customer, one date), so these per-cell distinct counts SUM
          -- exactly — see erp.agg_sku_month's comment.
          coalesce(sum(m.invoice_count), 0)::int as invoice_count,
          count(distinct m.customer_key)::int    as account_count
      from erp.agg_sku_month m
      where m.sales_month >= (date_trunc('month', current_date)
                              - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
      group by m.part_key
  ) s
  left join erp.dim_part p on p.part_key = s.part_key
  order by s.qty desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
$$;

comment on function public.report_global_product_sales(int, int) is
  'Company-wide sales by SKU for the last p_months whole months (clamped '
  '1-36) plus the current partial month, top p_limit by units (clamped '
  '1-2000), read from erp.agg_sku_month (nightly rollup — 20260818120000). '
  'SECURITY DEFINER on purpose: reps see global aggregates. Output is '
  'part-grain, units-and-counts only - never add customer or dollar '
  'columns (see 033).';

revoke execute on function public.report_global_product_sales(int, int) from public, anon;
grant execute on function public.report_global_product_sales(int, int) to authenticated;

--------------------------------------------------------------------------
-- 7. report_account_sku_gaps over the rollups: company-wide breadth from
--    agg_sku_month, the account's own history from agg_sku_year. Same
--    signature, OUT columns, guard, filters, and ordering as 036.
--------------------------------------------------------------------------

create or replace function public.report_account_sku_gaps(
    p_customer_key  text,
    p_months        int default 12,
    p_min_dealers   int default 4,
    p_limit         int default 25
)
returns table (
    part_key           text,
    part_id            text,
    part_description   text,
    product_code       text,
    product_family     text,
    chambering         text,
    barrel_length      text,
    upc                text,
    ats_qty            numeric,
    dealer_count       int,
    units_sold         numeric,
    bought_before      boolean,
    last_bought_date   date
)
language sql
stable
security definer
set search_path = ''
as $$
    with guard as (
        -- Evaluated as the CALLER despite SECURITY DEFINER — see 036.
        select public.has_account_access(p_customer_key) as ok
    ),
    -- Company-wide breadth, now a rollup group-by. Memo lines and null
    -- part keys are already excluded by the refresh.
    global as (
        select
            m.part_key,
            count(distinct m.customer_key)::int      as dealer_count,
            coalesce(sum(m.qty), 0)::numeric         as units_sold
        from erp.agg_sku_month m, guard
        where guard.ok
          and m.sales_month >= (date_trunc('month', current_date)
                                - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
        group by m.part_key
    ),
    -- What this ACCOUNT has bought, over the SKU rollup's 4-year window.
    mine as (
        select
            s.part_key,
            max(s.last_invoice_date) as last_bought_date
        from erp.agg_sku_year s, guard
        where guard.ok
          and s.customer_key = p_customer_key
        group by s.part_key
    )
    select
        a.part_key,
        p.part_id,
        p.part_description,
        p.product_code,
        p.product_family,
        p.chambering,
        p.barrel_length,
        p.upc,
        a.available_to_sell_qty::numeric                    as ats_qty,
        g.dealer_count,
        g.units_sold,
        (m.part_key is not null)                            as bought_before,
        m.last_bought_date
    from erp.fact_available_to_sell a
    join global g            on g.part_key = a.part_key
    left join mine m         on m.part_key = a.part_key
    left join erp.dim_part p on p.part_key = a.part_key
    where a.available_to_sell_qty >= 1          -- sellable today; see 027
      and g.dealer_count >= greatest(1, coalesce(p_min_dealers, 4))
      -- Finished firearms only. Mirrors isGunRow() in useIntel.ts (036).
      and coalesce(p.product_code, '') !~* 'component'
      and (
            coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
         or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A'
      )
    order by (m.part_key is not null), g.dealer_count desc, g.units_sold desc
    limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

comment on function public.report_account_sku_gaps(text, int, int, int) is
  'SKUs available to ship today that this account does not buy, ranked by '
  'how many dealers company-wide do — read from erp.agg_sku_month / '
  'agg_sku_year (nightly rollups, 20260818120000). SECURITY DEFINER, gated '
  'on has_account_access(p_customer_key) as the FIRST thing it evaluates. '
  'Part-grain, units and counts only - never add customer keys or '
  'company-wide dollars (see 033/036).';

revoke execute on function public.report_account_sku_gaps(text, int, int, int)
  from public, anon;
grant execute on function public.report_account_sku_gaps(text, int, int, int)
  to authenticated;

--------------------------------------------------------------------------
-- 8. First fill, so everything works between "migration applied" and the
--    next nightly ETL run — and bookings_ytd stops reading $0 today.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
