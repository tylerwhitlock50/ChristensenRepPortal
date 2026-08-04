/*============================================================================
  029_intel_view_filters.sql
  Purpose: Make the territory-wide intel views agree with the Overview about
           what "the territory" is.

  v_territory_account_yoy (025) defines the territory as ACTIVE, EXTERNAL
  accounts (`active_flag = 'Y'` and not internal). The two other
  territory-only views shipped without that predicate, so a rep with an
  inactive or internal account still assigned in the ERP would see its
  revenue in Sales Intel's SKU rollup — and in the AI territory brief's
  top-SKU context — while the Overview excluded it. Same portal, two answers.
  (Flagged by review on PR #11.)

  Deliberately NOT changed:
  - v_sku_sales_by_account — account-scoped; the caller picked the account,
    and the account page must keep working for inactive accounts.
  - v_backlog_by_sku — dual-use (territory page and the account card), and a
    backorder owed to a deactivated account is still real money someone must
    deal with; hiding it because the account went inactive would be worse
    than the mismatch. The backlog page can therefore exceed the Overview's
    backorder tile when an inactive account is still owed stock — that is a
    fact, not a bug.
============================================================================*/

create or replace view public.v_territory_sku_sales
with (security_invoker = true)
as
select
    f.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    p.upc,
    extract(year from f.invoice_date)::int         as sales_year,
    coalesce(sum(f.revenue), 0)::numeric           as revenue,
    coalesce(sum(f.invoice_qty), 0)::numeric       as qty,
    count(distinct f.invoice_id)::int              as invoice_count,
    max(f.invoice_date)                            as last_invoice_date
from erp.fact_invoice_line f
join erp.dim_customer c on c.customer_key = f.customer_key
left join erp.dim_part p on p.part_key = f.part_key
where f.is_memo is not true            -- NULL-safe; see 011 header
  and f.invoice_date is not null
  and f.invoice_date >= (date_trunc('year', current_date) - interval '3 years')::date
  -- Same territory definition as v_territory_account_yoy (025).
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by
    f.part_key, p.part_id, p.part_description,
    p.product_family, p.chambering, p.upc,
    extract(year from f.invoice_date)::int;

comment on view public.v_territory_sku_sales is
  'SKU sales by calendar year across the caller''s whole book (current + 3 '
  'prior years), active external accounts only — the same territory '
  'definition as v_territory_account_yoy. security_invoker. Queried '
  'unfiltered by design — RLS is the territory filter.';

create or replace view public.v_territory_recent_orders
with (security_invoker = true)
as
select
    o.customer_key,
    c.customer_name,
    o.order_id,
    max(o.order_date)                              as order_date,
    coalesce(sum(o.bookings), 0)::numeric          as order_amount,
    count(*)::int                                  as line_count,
    bool_or(o.is_backlog_line)                     as has_backlog
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
where o.order_date >= current_date - 14
  -- Same territory definition as v_territory_account_yoy (025).
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by o.customer_key, c.customer_name, o.order_id;

comment on view public.v_territory_recent_orders is
  'Order headers from the last 14 days across the caller''s book, active '
  'external accounts only. security_invoker. Feeds the Overview Recent '
  'Activity list.';

-- CREATE OR REPLACE preserves grants, but restate them so this file stands
-- alone if replayed against a fresh database mid-sequence.
revoke all on public.v_territory_sku_sales     from anon, public;
revoke all on public.v_territory_recent_orders from anon, public;
grant select on public.v_territory_sku_sales     to authenticated;
grant select on public.v_territory_recent_orders to authenticated;
