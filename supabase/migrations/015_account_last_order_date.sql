/*============================================================================
  015_account_last_order_date.sql
  Purpose: One "Last order" date, everywhere it is shown.

  The accounts list and the account header read
  erp.dim_customer.last_order_date, which lands from Visual's base
  CUSTOMER.LAST_ORDER_DATE — a field this ERP install does not maintain. It is
  NULL for most customers, so the UI said "Last order never" one scroll above
  an order-history card full of orders. The Performance card derives the date
  from erp.fact_order_line instead (v_account_summary, 011) and is right.

  This migration makes the order-history-derived date the one the UI shows:

      last_order_date = greatest(dim_customer.last_order_date,
                                 max(fact_order_line.order_date))

  greatest() rather than the fact max alone because greatest() skips NULLs in
  Postgres: an account whose orders predate the fact extract keeps whatever
  date the ERP has instead of regressing to "never", while any account with
  real order lines shows exactly what the order history shows.

  Two changes:
    1. public.v_account_list — NEW. The list-shaped read the accounts page
       uses instead of selecting erp.dim_customer directly.
    2. public.v_account_summary — recreated with the same greatest(), so the
       Performance card can never disagree with the list.

  ── security_invoker, as always ────────────────────────────────────────────
  Same rule as 011: without `with (security_invoker = true)` these views
  would run as their owner and bypass the erp RLS entirely, handing every
  dealer to every rep. Write that line before the select.

  ── Why v_account_list computes the date in the TARGET LIST, not a join ────
  The date is a scalar subquery per row, not a LEFT JOIN LATERAL:

    - The list is paged with `count: 'exact'`, and PostgREST's count query
      references no columns. A simple view is pulled up into the outer query,
      so the unreferenced subplan is discarded — counting v_account_list
      costs the same as counting dim_customer. A lateral join would execute
      once per row of the caller's whole book (41k for an admin) just to
      count rows.
    - The page query orders by customer_name with a LIMIT; the planner
      postpones subplan-bearing target-list items until after the sort, so
      the subquery runs only for the rows actually returned, each one an
      index probe on idx_fol_customer_order_date (011).
============================================================================*/

--------------------------------------------------------------------------
-- v_account_list
--   Grain: one row per customer — exactly the columns the accounts list
--   selects, with the harmonized last_order_date. Anything else the UI
--   wants about an account comes from dim_customer (detail) or
--   v_account_summary (rollups).
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
        (select max(o.order_date)
           from erp.fact_order_line o
          where o.customer_key = c.customer_key)
    ) as last_order_date
from erp.dim_customer c;

comment on view public.v_account_list is
  'The accounts list: dim_customer identity columns plus a last_order_date '
  'derived from order history (greatest of the ERP field and '
  'max(fact_order_line.order_date)), matching v_account_summary. '
  'security_invoker: the caller''s RLS on erp.dim_customer and '
  'erp.fact_order_line applies.';

--------------------------------------------------------------------------
-- v_account_summary — identical to 011 except last_order_date now folds in
-- the dim_customer field via greatest(), so the one account whose orders
-- predate the fact extract shows the ERP's date here too instead of "—".
-- Column list, names, and types are unchanged; create or replace is safe.
--------------------------------------------------------------------------
create or replace view public.v_account_summary
with (security_invoker = true)
as
select
    c.customer_key,
    coalesce(inv.revenue_ytd, 0)::numeric            as revenue_ytd,
    coalesce(inv.revenue_prior_ytd, 0)::numeric      as revenue_prior_ytd,
    coalesce(inv.revenue_trailing_12m, 0)::numeric   as revenue_trailing_12m,
    greatest(c.last_order_date, ord.last_order_date) as last_order_date,
    inv.last_invoice_date,
    coalesce(ord.open_order_count, 0)::int           as open_order_count,
    coalesce(ord.open_order_value, 0)::numeric       as open_order_value,
    coalesce(ord.backlog_qty, 0)::numeric            as backlog_qty
from erp.dim_customer c
left join lateral (
    select
        sum(f.revenue) filter (
            where f.invoice_date >= date_trunc('year', current_date)::date
        )                                                        as revenue_ytd,
        sum(f.revenue) filter (
            where f.invoice_date >= (date_trunc('year', current_date) - interval '1 year')::date
              and f.invoice_date <= (current_date - interval '1 year')::date
        )                                                        as revenue_prior_ytd,
        sum(f.revenue) filter (
            where f.invoice_date > (current_date - interval '12 months')::date
        )                                                        as revenue_trailing_12m,
        max(f.invoice_date)                                      as last_invoice_date
    from erp.fact_invoice_line f
    where f.customer_key = c.customer_key
      and f.is_memo is not true        -- NULL-safe; see the 011 header
      and f.invoice_date is not null
) inv on true
left join lateral (
    select
        max(o.order_date)                                        as last_order_date,
        -- "Open" = the ERP's own backlog flag: a line with quantity still
        -- owed. Counting distinct order_id answers the rep's question
        -- ("how many orders are open?"), not "how many lines".
        count(distinct o.order_id) filter (where o.is_backlog_line) as open_order_count,
        sum(o.backlog_amount)      filter (where o.is_backlog_line) as open_order_value,
        sum(o.backlog_qty)         filter (where o.is_backlog_line) as backlog_qty
    from erp.fact_order_line o
    where o.customer_key = c.customer_key
) ord on true;

comment on view public.v_account_summary is
  'One row per account: YTD vs prior-YTD vs trailing-12m revenue, last '
  'order/invoice dates, and open-order count/value/qty. last_order_date is '
  'greatest(dim_customer.last_order_date, max(fact_order_line.order_date)) — '
  'harmonized with v_account_list (015). security_invoker: driven off '
  'erp.dim_customer so the caller sees only their book. Always query with '
  '.eq(customer_key) — unfiltered it aggregates every account the caller '
  'can see.';

--------------------------------------------------------------------------
-- Grants. Same shape as 011: take back the default anon SELECT, keep
-- authenticated. v_account_summary's ACL survives create-or-replace, so
-- only the new view needs them.
--------------------------------------------------------------------------
revoke all on public.v_account_list from anon, public;
grant select on public.v_account_list to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Add v_account_list to the RLS test suite (§3.5): rep A must get zero
     rows for rep B's customer_key from it, same as the 011 views.
  2. Regenerate frontend/src/types/database.types.ts — until then
     useAccounts.ts reads the view through the same untyped handle pattern
     as useAccountMetrics.ts.
  3. The recommendation engine's `no_order_days` rule (008) still reads the
     raw dim_customer.last_order_date and therefore skips the mostly-NULL
     accounts. Left as-is here on purpose — switching it to the derived date
     would fire a wave of new recommendations overnight and deserves its own
     tuning pass.
----------------------------------------------------------------------------*/
