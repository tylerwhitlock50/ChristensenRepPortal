/*============================================================================
  030_territory_rollups.sql — precomputed territory rollups.

  Why
  ---
  v_territory_account_yoy (025) aggregated BOTH whole fact tables at query
  time, per page load, per user. Measured on this database (2026-08-04):

      rep, 41-account book ....  4.75 s
      admin, whole company ..... 18.15 s   → statement_timeout (8s) → HTTP 500

  The RLS predicate `is_admin() OR customer_key IN (my_customer_keys())` is
  an OR, so neither branch can drive the customer_key index — every request
  seq-scanned 529k invoice lines and 501k order lines and re-grouped them.
  v_territory_sku_sales had the same shape (4.4s mean, 7.5s max), and the
  ai-brief Edge Function runs BOTH inside its context build, which is where
  the 8–15s briefs and the mid-brief statement timeouts came from.

  The fix
  -------
  ERP data changes once a night (TRUNCATE + COPY by the ETL), so aggregating
  it per request bought nothing. Two rollup tables, rebuilt by
  public.refresh_territory_rollups() as the ETL's first post_load_sql step:

    erp.agg_account_rollup   one row per customer (~41k): the exact windows
                             025 computed — day-aligned YTD / prior-YTD,
                             trailing 12m, last invoice date, backlog.
    erp.agg_sku_year         (customer_key, part_key, sales_year), current
                             + 3 prior years (~65k rows) — the base both
                             SKU views group over.

  The public views keep their exact names and column lists, so the frontend
  and the Edge Functions change NOTHING. They now join ~41k/~65k indexed
  rows instead of re-aggregating half a million, which puts the admin's
  worst case comfortably under a second.

  Window semantics live in the REFRESH, so they are as of the last refresh,
  not of the request — identical to the data itself, which is also as of
  the last ETL run. v_data_freshness already tells the user that.

  RLS: same policy shape as the fact tables (010) — these tables hold the
  same customer-scoped facts, just pre-added. security_invoker views on top,
  as everywhere else.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Rollup tables. Owned by postgres, written only by the refresh
--    function; authenticated can only SELECT, through RLS.
--------------------------------------------------------------------------

create table if not exists erp.agg_account_rollup (
    customer_key         text primary key,
    revenue_ytd          numeric not null default 0,
    revenue_prior_ytd    numeric not null default 0,
    revenue_trailing_12m numeric not null default 0,
    last_invoice_date    date,
    open_order_value     numeric not null default 0,
    backlog_qty          numeric not null default 0,
    backlog_amount       numeric not null default 0,
    refreshed_at         timestamptz not null default now()
);

comment on table erp.agg_account_rollup is
  'Per-customer revenue windows + backlog, rebuilt nightly by '
  'public.refresh_territory_rollups() (ETL post_load_sql). Windows are as '
  'of refresh time — same freshness as the ERP data itself.';

create table if not exists erp.agg_sku_year (
    customer_key      text not null,
    part_key          text not null,
    sales_year        int  not null,
    revenue           numeric not null default 0,
    qty               numeric not null default 0,
    invoice_count     int not null default 0,
    last_invoice_date date,
    primary key (customer_key, part_key, sales_year)
);

comment on table erp.agg_sku_year is
  'Per (customer, part, calendar year) invoice rollup, current + 3 prior '
  'years. Rebuilt nightly by public.refresh_territory_rollups(). Base for '
  'v_territory_sku_sales and v_sku_sales_by_account.';

-- The territory SKU view groups by part over the caller's whole book;
-- give the per-year slice a path that doesn't start at customer_key.
create index if not exists idx_agg_sku_year_year on erp.agg_sku_year (sales_year);

alter table erp.agg_account_rollup enable row level security;
alter table erp.agg_sku_year       enable row level security;

drop policy if exists "read own agg_account_rollup" on erp.agg_account_rollup;
create policy "read own agg_account_rollup" on erp.agg_account_rollup
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

drop policy if exists "read own agg_sku_year" on erp.agg_sku_year;
create policy "read own agg_sku_year" on erp.agg_sku_year
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

grant select on erp.agg_account_rollup to authenticated;
grant select on erp.agg_sku_year       to authenticated;
revoke all on erp.agg_account_rollup from anon, public;
revoke all on erp.agg_sku_year       from anon, public;

--------------------------------------------------------------------------
-- 2. The refresh. One transaction (the function body), truncate + insert,
--    so readers see either the old rollup or the new one, never a gap.
--
--    Window definitions are copied VERBATIM from 025's view subqueries —
--    if you change one, change the other… except there is no other any
--    more; this is now the single home of the windows.
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
    last_invoice_date, open_order_value, backlog_qty, backlog_amount
  )
  select
    c.customer_key,
    coalesce(inv.revenue_ytd, 0),
    coalesce(inv.revenue_prior_ytd, 0),
    coalesce(inv.revenue_trailing_12m, 0),
    inv.last_invoice_date,
    coalesce(ord.open_order_value, 0),
    coalesce(ord.backlog_qty, 0),
    coalesce(ord.backlog_amount, 0)
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

comment on function public.refresh_territory_rollups() is
  'Rebuilds erp.agg_account_rollup and erp.agg_sku_year. Called by the ETL '
  'as its first post_load_sql step (etl/views.yml). Not callable by app '
  'roles — the ETL connects as postgres.';

-- 017 conventions: a SECURITY DEFINER function nobody signed-in needs to
-- call must not be reachable from /rest/v1/rpc.
revoke execute on function public.refresh_territory_rollups()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 3. The views, re-pointed at the rollups. Names and column lists are
--    UNCHANGED — the frontend and the Edge Functions notice nothing except
--    the speed. Territory definition (active, external) restated from 029.
--------------------------------------------------------------------------

create or replace view public.v_territory_account_yoy
with (security_invoker = true)
as
select
    c.customer_key,
    c.customer_name,
    c.sold_to_city,
    c.sold_to_state,
    c.yearly_sales_goal,
    coalesce(a.revenue_ytd, 0)::numeric          as revenue_ytd,
    coalesce(a.revenue_prior_ytd, 0)::numeric    as revenue_prior_ytd,
    coalesce(a.revenue_trailing_12m, 0)::numeric as revenue_trailing_12m,
    a.last_invoice_date,
    coalesce(a.open_order_value, 0)::numeric     as open_order_value,
    coalesce(a.backlog_qty, 0)::numeric          as backlog_qty,
    coalesce(a.backlog_amount, 0)::numeric       as backlog_amount
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_account_yoy is
  'One row per account in the caller''s book, read from erp.agg_account_rollup '
  '(refreshed nightly by the ETL — see 030). security_invoker: RLS is the '
  'territory filter. Queried UNFILTERED by design — the Overview''s single '
  'round trip.';

create or replace view public.v_territory_sku_sales
with (security_invoker = true)
as
select
    s.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    p.upc,
    s.sales_year,
    coalesce(sum(s.revenue), 0)::numeric     as revenue,
    coalesce(sum(s.qty), 0)::numeric         as qty,
    -- invoice ids never span customers, so per-customer distinct counts add.
    sum(s.invoice_count)::int                as invoice_count,
    max(s.last_invoice_date)                 as last_invoice_date
from erp.agg_sku_year s
join erp.dim_customer c on c.customer_key = s.customer_key
left join erp.dim_part p on p.part_key = s.part_key
-- Same territory definition as v_territory_account_yoy (029).
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by
    s.part_key, p.part_id, p.part_description,
    p.product_family, p.chambering, p.upc, s.sales_year;

comment on view public.v_territory_sku_sales is
  'SKU sales by calendar year across the caller''s whole book (current + 3 '
  'prior years), active external accounts only, read from erp.agg_sku_year '
  '(refreshed nightly — see 030). security_invoker. Queried unfiltered by '
  'design — RLS is the territory filter.';

-- CREATE OR REPLACE preserves grants, but restate them so this file stands
-- alone if replayed against a fresh database mid-sequence.
revoke all on public.v_territory_account_yoy from anon, public;
revoke all on public.v_territory_sku_sales   from anon, public;
grant select on public.v_territory_account_yoy to authenticated;
grant select on public.v_territory_sku_sales   to authenticated;

--------------------------------------------------------------------------
-- 4. First fill, so the Overview works between "migration applied" and
--    "next nightly ETL run".
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
