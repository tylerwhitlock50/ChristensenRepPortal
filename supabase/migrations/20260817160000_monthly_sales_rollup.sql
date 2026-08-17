/*============================================================================
  20260817160000_monthly_sales_rollup.sql — invoiced revenue by calendar
  month, so "what are my sales this month" stops being unanswerable.

  Why
  ---
  Every revenue figure the portal and the MCP endpoint expose is
  calendar-YTD, prior-YTD or trailing-12m (030's windows). The most-asked
  rep question — this month, last month, the quarter, "how am I trending" —
  had no source at any grain. Same fix as 030: the data changes once a
  night, so pre-aggregate it.

  erp.agg_customer_month: one row per (customer, calendar month) with any
  invoiced activity, current + 3 prior calendar years — the same horizon as
  agg_sku_year, wide enough for month-over-month and year-over-year at once.
  Rebuilt by refresh_territory_rollups() (restated below), so it refreshes
  in the same ETL transaction slot as every other rollup. The current month
  is PARTIAL up to the ETL's data_through date; v_data_freshness already
  tells the user what "today" means.

  report_sales_by_month(): the caller's book summed per month, optionally
  one account. SECURITY INVOKER over RLS-scoped tables — the territory
  definition (active, external) is restated from 029/030 so it agrees with
  v_territory_account_yoy; a single-account call skips that filter, because
  "what did THIS account do monthly" should work even for an account that
  has since gone inactive.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The rollup table. Same ownership/RLS shape as 030's tables.
--------------------------------------------------------------------------

create table if not exists erp.agg_customer_month (
    customer_key  text not null,
    sales_month   date not null,   -- first day of the month
    revenue       numeric not null default 0,
    qty           numeric not null default 0,
    invoice_count int not null default 0,
    primary key (customer_key, sales_month)
);

comment on table erp.agg_customer_month is
  'Invoiced revenue per (customer, calendar month), current + 3 prior '
  'years, rebuilt nightly by public.refresh_territory_rollups(). The '
  'current month is partial up to the last ETL load.';

-- Book-wide month sums walk every customer for a few months; give the
-- month slice a path that does not start at customer_key.
create index if not exists idx_agg_customer_month_month
  on erp.agg_customer_month (sales_month);

alter table erp.agg_customer_month enable row level security;

drop policy if exists "read own agg_customer_month" on erp.agg_customer_month;
create policy "read own agg_customer_month" on erp.agg_customer_month
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

grant select on erp.agg_customer_month to authenticated;
revoke all on erp.agg_customer_month from anon, public;

--------------------------------------------------------------------------
-- 2. The refresh, restated in full with the third rollup added.
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
-- 3. The book (or one account) summed per month, RLS-scoped.
--------------------------------------------------------------------------

create or replace function public.report_sales_by_month(
    p_customer_key text default null,
    p_months       int  default 13
)
returns table (
    sales_month   date,
    revenue       numeric,
    qty           numeric,
    invoice_count bigint,
    account_count bigint
)
language sql
stable
security invoker
set search_path = public, erp
as $$
    select
        m.sales_month,
        coalesce(sum(m.revenue), 0)       as revenue,
        coalesce(sum(m.qty), 0)           as qty,
        coalesce(sum(m.invoice_count), 0) as invoice_count,
        count(distinct m.customer_key)    as account_count
    from erp.agg_customer_month m
    join erp.dim_customer c on c.customer_key = m.customer_key
    where m.sales_month >= (date_trunc('month', current_date)
                            - make_interval(months => greatest(least(p_months, 48), 1) - 1))::date
      and (
            p_customer_key is not null and m.customer_key = p_customer_key
            -- Book-wide: the same territory definition as
            -- v_territory_account_yoy (029/030) — active, external.
            or (p_customer_key is null
                and c.active_flag = 'Y'
                and coalesce(c.internal_customer_flag, 'N') <> 'Y')
          )
    group by m.sales_month
    order by m.sales_month
$$;

comment on function public.report_sales_by_month(text, int) is
  'Invoiced revenue per calendar month over the caller''s book (RLS via '
  'security invoker; active external accounts, matching the territory '
  'views), or one account when p_customer_key is given (no activity '
  'filter — history should work for accounts that went inactive). Months '
  'clamped to [1, 48]; the newest month is partial up to the last ETL '
  'load. Used by the mcp Edge Function''s get_sales_summary.';

revoke execute on function public.report_sales_by_month(text, int) from public, anon;
grant execute on function public.report_sales_by_month(text, int) to authenticated;

--------------------------------------------------------------------------
-- 4. First fill.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
