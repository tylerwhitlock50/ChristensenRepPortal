/*============================================================================
  20261013110000_account_page.sql — two account reads moved onto the
  nightly rollups.

  Why
  ---
  Two views still aggregate a fact table on every request, although the
  nightly refresh (refresh_territory_rollups(), latest body in
  20260901190100) already holds the same figures at the same grain:

    1. public.v_account_revenue_monthly (011) — the account page's revenue
       chart, the AI summary's context (functions/_shared/accountContext.ts)
       and the MCP get_account_revenue_trend tool. A live GROUP BY over
       erp.fact_invoice_line, while erp.agg_customer_month
       (20260817160000) is the same (customer, month) grain with the same
       filter and a wider window.
    2. public.v_account_list (023) — the accounts list and search, and the
       MCP whoami / search_accounts / list_territory_accounts tools. A
       correlated max(fact_order_line.order_date) per row, while
       erp.agg_account_rollup.last_order_date (20260901000100) is that max,
       precomputed. list_territory_accounts sorts the whole book by this
       column, which ran the max over the order facts once per account.

  Compatibility
  -------------
  create or replace with the same columns, in the same order, with the
  same names and types — supabase/tests/20261013_account_page.sql pins
  both shapes — and still security_invoker. Nothing that reads either view
  (the frontend, the edge functions, the MCP server) changes.

  Parity with the live versions, checked against 20260901190100:
    - is_memo: the refresh fills agg_customer_month with
      `is_memo is not true and invoice_date is not null`, exactly 011's
      filter.
    - invoice_count: count(distinct invoice_id) per (customer, month) on
      both sides.
    - window: the rollup keeps the current year plus three prior calendar
      years (36+ months), so the trailing 24 months below are always
      covered. The window is still computed at request time from
      current_date, and current_date is Mountain time for every PostgREST
      role (20260901190000) — the zone the refresh pins — so "this month"
      means the same month on both sides.
    - last_order_date: max(order_date) over every order line, as before
      (the refresh does not drop cancelled lines from this max either), and
      still greatest()'d with the ERP's own field (015).
    - freshness: the rollups are rebuilt as the ETL's first post_load_sql
      step, right after the facts land. For the few minutes between those
      two steps, once a night, these views show the previous load.

  RLS: the scope now comes from the rollups' "read own agg_*" policies
  instead of the fact tables' — the same predicate, is_admin() or
  my_customer_keys(), view-as aware (20260816140000). Same book.
============================================================================*/

--------------------------------------------------------------------------
-- 1. v_account_revenue_monthly
--    Grain unchanged: one row per (customer_key, month), trailing 24
--    calendar months including the current partial one, silent months
--    absent. sales_month is already the first of the month.
--------------------------------------------------------------------------
create or replace view public.v_account_revenue_monthly
with (security_invoker = true)
as
select
    m.customer_key,
    m.sales_month                                    as month,
    m.revenue::numeric                               as revenue,
    m.invoice_count::int                             as invoice_count
from erp.agg_customer_month m
where m.sales_month >= (date_trunc('month', current_date) - interval '23 months')::date;

comment on view public.v_account_revenue_monthly is
  'Trailing 24 months of invoiced revenue per account, one row per month, '
  'read from erp.agg_customer_month (rebuilt nightly; see '
  '20261013110000). security_invoker: the caller''s RLS on the rollup '
  'applies. Always query with a customer_key filter — it leads the '
  'rollup''s primary key.';

revoke all on public.v_account_revenue_monthly from anon, public;
grant select on public.v_account_revenue_monthly to authenticated;

--------------------------------------------------------------------------
-- 2. v_account_list
--    Same columns as 023. Still a scalar subquery in the target list, for
--    015's reasons — PostgREST's count query discards it, and a page
--    sorted by name runs it only for the rows returned — but now a
--    primary-key probe on the rollup instead of a max() over the order
--    facts. Measured on 41k accounts / 400k order lines (admin scope):
--
--        count               9 ms   (was 9)
--        page by name       15 ms   (was 16)
--        sort by last order 70 ms   (was 106-146; list_territory_accounts)
--
--    A LEFT JOIN to the rollup was tried first: it is no faster for the
--    sort and makes the name-ordered page 70 ms, because the join has to
--    run for the whole book before the sort can limit it.
--
--    No rollup row (no order or invoice history) → NULL → the ERP field
--    alone, which is what max() over zero lines gave before.
--------------------------------------------------------------------------
create or replace view public.v_account_list
with (security_invoker = true)
as
select
    c.customer_key,
    c.customer_name,
    c.sold_to_city,
    c.sold_to_state,
    c.assigned_sales_rep_id,
    c.assigned_sales_rep_name,
    c.territory,
    c.active_flag,
    greatest(
        c.last_order_date,
        (select r.last_order_date
           from erp.agg_account_rollup r
          where r.customer_key = c.customer_key)
    ) as last_order_date,
    d.deactivated_at,
    d.reason as deactivation_reason
from erp.dim_customer c
left join public.account_deactivations d
  on d.customer_key = c.customer_key
 and d.reactivated_at is null;

comment on view public.v_account_list is
  'The accounts list: dim_customer identity columns plus last_order_date '
  '(the ERP field greatest()''d with the nightly rollup''s max order date, '
  '015/20261013110000) and the open portal deactivation period, if any '
  '(023). deactivated_at is null = the account is in play. '
  'security_invoker: the caller''s RLS applies throughout.';

revoke all on public.v_account_list from anon, public;
grant select on public.v_account_list to authenticated;
