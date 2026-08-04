/*============================================================================
  025_intel_views.sql
  Purpose: The read path behind the data-first restructure — the territory
           Overview (morning briefing) and the Sales Intel section.

           Every view here is `with (security_invoker = true)`; the caller's
           RLS on erp.* (customer_key in my_customer_keys(), admins via
           is_admin()) IS the territory filter. No view takes a rep
           parameter, and none needs one. Read the header of
           011_account_views.sql before touching this file — the ownership,
           measure, and NULL-safe-memo rules there all apply.

  ── Unfiltered scans are the POINT here ────────────────────────────────────
  Unlike the 011/018 account views (always .eq(customer_key)), the territory
  views are intentionally queried UNFILTERED: "the caller's whole book" is
  the unit of analysis. That pays the RLS predicate over the full fact scan
  (~756ms noted in 011; more for admins, whose book is every account). This
  runs at page-load frequency, not per keystroke, and results sit in the
  client cache for 10 minutes. If it shows up in slow-query logs, promote
  the offender to a materialized view refreshed in the ETL post_load_sql —
  the client contract does not change.

  ── Measures ───────────────────────────────────────────────────────────────
  Certified measures only (002): revenue, bookings, backlog_qty,
  backlog_amount. `is_memo is not true` everywhere revenue is summed —
  is_memo is nullable and `not is_memo` silently drops NULL rows.
============================================================================*/

--------------------------------------------------------------------------
-- Supporting indexes. The territory SKU rollups group by part_key across
-- years of invoice lines; give them a part-first path. The customer-first
-- composites from 011 keep serving the .eq(customer_key) callers.
--------------------------------------------------------------------------
create index if not exists idx_fil_part_invoice_date
  on erp.fact_invoice_line (part_key, invoice_date);

--------------------------------------------------------------------------
-- v_territory_account_yoy
--   Grain: one row per account in the caller's book. THE Overview query:
--   tiles (sum client-side), largest movers, worth-investigating, and the
--   AI territory brief context all come from this one result set.
--
--   Pre-grouped subqueries, not v_account_summary's correlated LATERALs —
--   that shape is deliberately single-account (011 header); here the whole
--   book IS the access pattern, so grouped scans joined on customer_key
--   are the right plan.
--
--   Windows match v_account_summary exactly (day-aligned prior YTD) so the
--   Overview and the account page never disagree about a number.
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
    coalesce(inv.revenue_ytd, 0)::numeric          as revenue_ytd,
    coalesce(inv.revenue_prior_ytd, 0)::numeric    as revenue_prior_ytd,
    coalesce(inv.revenue_trailing_12m, 0)::numeric as revenue_trailing_12m,
    inv.last_invoice_date,
    coalesce(ord.open_order_value, 0)::numeric     as open_order_value,
    coalesce(ord.backlog_qty, 0)::numeric          as backlog_qty,
    coalesce(ord.backlog_amount, 0)::numeric       as backlog_amount
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
    where f.is_memo is not true        -- NULL-safe; see header
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
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_account_yoy is
  'One row per account in the caller''s book: day-aligned YTD vs prior-YTD '
  'revenue, trailing 12m, goal, open orders, backlog. security_invoker: RLS '
  'is the territory filter. Queried UNFILTERED by design — the Overview''s '
  'single round trip.';

--------------------------------------------------------------------------
-- v_territory_recent_orders
--   Grain: order header, last 14 days, across the caller's book. The
--   Overview "Recent Activity" feed. Lines rolled up to headers here so
--   the phone never does.
--------------------------------------------------------------------------
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
group by o.customer_key, c.customer_name, o.order_id;

comment on view public.v_territory_recent_orders is
  'Order headers from the last 14 days across the caller''s book. '
  'security_invoker. Feeds the Overview Recent Activity list.';

--------------------------------------------------------------------------
-- v_sku_sales_by_account
--   Grain: (customer_key, part_key, sales_year), current year + 3 prior.
--   "What did this account buy, by SKU, this year and historically."
--
--   customer_key is a GROUP BY column, so the caller's .eq(customer_key)
--   predicate reaches idx_fil_customer_invoice_date. The caller MUST
--   filter — unfiltered this is (book × SKUs × 4 years) rows; the
--   territory-wide rollup is v_territory_sku_sales, use that instead.
--------------------------------------------------------------------------
create or replace view public.v_sku_sales_by_account
with (security_invoker = true)
as
select
    f.customer_key,
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
left join erp.dim_part p on p.part_key = f.part_key
where f.is_memo is not true            -- NULL-safe; see header
  and f.invoice_date is not null
  and f.invoice_date >= (date_trunc('year', current_date) - interval '3 years')::date
group by
    f.customer_key, f.part_key, p.part_id, p.part_description,
    p.product_family, p.chambering, p.upc,
    extract(year from f.invoice_date)::int;

comment on view public.v_sku_sales_by_account is
  'Per-account SKU sales by calendar year (current + 3 prior). '
  'security_invoker. ALWAYS query with .eq(customer_key) — it is a GROUP BY '
  'column, so the predicate reaches the index. Territory-wide rollup is '
  'v_territory_sku_sales.';

--------------------------------------------------------------------------
-- v_territory_sku_sales
--   Grain: (part_key, sales_year) across the caller's WHOLE book. No
--   customer column on purpose: the rollup happens in Postgres, so the
--   result stays small (SKUs × 4 years) and never ships per-account
--   detail the page didn't ask for. Queried unfiltered; RLS scopes it.
--------------------------------------------------------------------------
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
left join erp.dim_part p on p.part_key = f.part_key
where f.is_memo is not true            -- NULL-safe; see header
  and f.invoice_date is not null
  and f.invoice_date >= (date_trunc('year', current_date) - interval '3 years')::date
group by
    f.part_key, p.part_id, p.part_description,
    p.product_family, p.chambering, p.upc,
    extract(year from f.invoice_date)::int;

comment on view public.v_territory_sku_sales is
  'SKU sales by calendar year across the caller''s whole book (current + 3 '
  'prior years). security_invoker. Queried unfiltered by design — RLS is '
  'the territory filter.';

--------------------------------------------------------------------------
-- v_backlog_by_sku
--   Grain: (customer_key, part_key) over open backlog lines only (the
--   ERP's own is_backlog_line flag; partial index idx_fol_backlog from
--   002 serves the scan). Serves BOTH the territory Backlog intel page
--   (unfiltered) and the account backlog card (.eq customer_key).
--------------------------------------------------------------------------
create or replace view public.v_backlog_by_sku
with (security_invoker = true)
as
select
    o.customer_key,
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
    max(o.order_date)                              as latest_order_date
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
left join erp.dim_part p on p.part_key = o.part_key
where o.is_backlog_line
group by
    o.customer_key, c.customer_name, o.part_key,
    p.part_id, p.part_description, p.product_family, p.chambering;

comment on view public.v_backlog_by_sku is
  'Open backlog rolled up to (account, SKU): qty, value, line count, '
  'earliest promise date. security_invoker. Unfiltered = the caller''s '
  'territory backlog; .eq(customer_key) = one account''s card.';

--------------------------------------------------------------------------
-- Grants — same reasoning as 011: anon has no business reaching these.
--------------------------------------------------------------------------
revoke all on public.v_territory_account_yoy   from anon, public;
revoke all on public.v_territory_recent_orders from anon, public;
revoke all on public.v_sku_sales_by_account    from anon, public;
revoke all on public.v_territory_sku_sales     from anon, public;
revoke all on public.v_backlog_by_sku          from anon, public;

grant select on public.v_territory_account_yoy   to authenticated;
grant select on public.v_territory_recent_orders to authenticated;
grant select on public.v_sku_sales_by_account    to authenticated;
grant select on public.v_territory_sku_sales     to authenticated;
grant select on public.v_backlog_by_sku          to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. RLS tests (supabase/tests/024_intel_views.sql): rep A must see zero of
     rep B's rows in every view here, and rep A's v_territory_sku_sales
     totals must equal a superuser recomputation over rep A's book only.
  2. Regenerate frontend/src/types/database.types.ts — until then the intel
     composables read these through the untyped client handle and say so.
  3. If any territory view shows up in slow-query logs, materialize it and
     refresh in the ETL post_load_sql; the client contract does not change.
----------------------------------------------------------------------------*/
