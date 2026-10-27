/*============================================================================
  20261027090500_product_line_columns.sql — the product line on the three
  SKU lists (G13).

  Why
  ---
  Tableau's "Family" filter is the ERP part's PRODUCT_CODE (RIDGELINE,
  RIDGELINE FFT, MESA FFT, EVOKE, FG-COMP …). The portal's product_family is
  a different, coarser catalog attribute, so a rep who filters Tableau by
  "RIDGELINE FFT" had nothing to match it with on Backlog or SKU Sales. The
  UI calls it "Product line".

  What
  ----
  dim_part.product_code appended (last) to:
    v_backlog_by_sku         restated from 20261026180000_agency_overview.sql
                             (live since 2026-10-27 10:21), after its
                             assigned_sales_rep_id / _name
    v_territory_sku_sales    restated from LIVE = 030_territory_rollups.sql
    v_sku_sales_by_account   restated from LIVE = 20260818212142_intel_rollups.sql
  The two aggregating views add p.product_code to their GROUP BY. It is a
  column of dim_part, whose key is part_key, and both already group by the
  part key, so no group splits and no row count changes (the guard checks).
  product_code is outside dim_part's revoked cost columns (20260901190300).

  v_ats_list gets the same column in 20261027090200; v_open_order_lines and
  report_book_shipments() carry it from birth (20261027090600).
============================================================================*/

--------------------------------------------------------------------------
-- 1. Backlog by account × SKU.
--------------------------------------------------------------------------
create or replace view public.v_backlog_by_sku
with (security_invoker = true)
as
select
    o.customer_key,
    c.customer_id,
    c.customer_name,
    o.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    coalesce(sum(o.backlog_qty), 0)::numeric       as backlog_qty,
    coalesce(sum(o.backlog_amount), 0)::numeric    as backlog_amount,
    count(*)::int                                  as open_line_count,
    min(o.promise_date)                            as earliest_promise_date,
    min(o.desired_ship_date)                       as earliest_desired_ship_date,
    max(o.order_date)                              as latest_order_date,
    c.assigned_sales_rep_id,
    c.assigned_sales_rep_name,
    p.product_code
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
left join erp.dim_part p on p.part_key = o.part_key
where o.is_backlog_line
group by
    o.customer_key, c.customer_id, c.customer_name, o.part_key,
    p.part_id, p.part_description, p.product_family, p.chambering,
    c.assigned_sales_rep_id, c.assigned_sales_rep_name,
    p.product_code;

comment on view public.v_backlog_by_sku is
  'Open backlog rolled up to (account, SKU): qty, value, line count, '
  'earliest promise date, earliest desired ship date (surfaced as '
  '"estimated production date"), the account''s assigned rep '
  '(20261026180000) and the ERP product line (product_code, '
  '20261027090500). security_invoker. Unfiltered = the caller''s territory '
  'backlog; .eq(customer_key) = one account''s card.';

--------------------------------------------------------------------------
-- 2. SKU × year across the book.
--------------------------------------------------------------------------
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
    max(s.last_invoice_date)                 as last_invoice_date,
    p.product_code
from erp.agg_sku_year s
join erp.dim_customer c on c.customer_key = s.customer_key
left join erp.dim_part p on p.part_key = s.part_key
-- Same territory definition as v_territory_account_yoy (029).
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by
    s.part_key, p.part_id, p.part_description,
    p.product_family, p.chambering, p.upc, s.sales_year,
    p.product_code;

comment on view public.v_territory_sku_sales is
  'SKU sales by calendar year across the caller''s whole book (current + 3 '
  'prior years), active external accounts only, read from erp.agg_sku_year '
  '(refreshed by the ETL — see 030). product_code is the ERP product line '
  '(20261027090500). security_invoker. Queried unfiltered by design — RLS '
  'is the territory filter.';

--------------------------------------------------------------------------
-- 3. SKU × year for one account.
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
    s.last_invoice_date,
    p.product_code
from erp.agg_sku_year s
left join erp.dim_part p on p.part_key = s.part_key;

comment on view public.v_sku_sales_by_account is
  'SKU × calendar year for one account (current + 3 prior years), read from '
  'erp.agg_sku_year (refreshed by the ETL — see 030). product_code is the '
  'ERP product line (20261027090500). security_invoker: RLS on the rollup '
  'scopes it to the caller''s book. Always query with .eq(customer_key); '
  'page with .order(part_key).order(sales_year).range() — a big dealer '
  'exceeds PostgREST''s 1,000-row cap.';

revoke all on public.v_backlog_by_sku       from anon, public;
revoke all on public.v_territory_sku_sales  from anon, public;
revoke all on public.v_sku_sales_by_account from anon, public;
grant select on public.v_backlog_by_sku       to authenticated;
grant select on public.v_territory_sku_sales  to authenticated;
grant select on public.v_sku_sales_by_account to authenticated;
