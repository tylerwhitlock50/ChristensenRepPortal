/*============================================================================
  20260817120000_territory_ranking.sql — make the MCP territory tools rank
  in SQL instead of truncating in TypeScript.

  Why
  ---
  The mcp Edge Function's get_territory_summary / list_territory_accounts
  paged v_territory_account_yoy behind a 5,000-row cap WITH NO ORDER BY and
  then sorted/filtered in TypeScript. Against a 20,689-row admin book the
  cap kept an arbitrary physical-order prefix: the reported top account was
  actually #4, revenue_ytd totals were 82% understated, and a state filter
  ran after the cap (TX matched 601 of 2,287). Measured 2026-08-17.

  The cap was bought as a performance guard, but the source is the nightly
  erp.agg_account_rollup (030) — the full whole-book aggregate runs in ~41ms.
  So: rank and aggregate in Postgres, delete the cap.

  Two changes, both additive
  --------------------------
  1. v_territory_account_yoy gains yoy_change_amount / yoy_change_pct as SQL
     columns, APPENDED so every existing consumer sees the same column
     positions. They were previously computed in TypeScript, which is what
     forced the client-side sort in the first place.
     yoy_change_pct mirrors the function's pct(): one decimal place, null
     when there is no prior-year base.

  2. report_territory_summary(): whole-book totals in one round trip.
     SECURITY INVOKER on purpose — it reads the security_invoker view, so
     RLS scopes it to the caller's book exactly like every other read.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The view, with the YoY math moved into SQL. Columns appended.
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
    coalesce(a.backlog_amount, 0)::numeric       as backlog_amount,
    (coalesce(a.revenue_ytd, 0) - coalesce(a.revenue_prior_ytd, 0))::numeric
                                                 as yoy_change_amount,
    case
        when coalesce(a.revenue_prior_ytd, 0) > 0 then
            round(
                (coalesce(a.revenue_ytd, 0) - a.revenue_prior_ytd)
                    / a.revenue_prior_ytd * 1000
            ) / 10
        else null
    end                                          as yoy_change_pct
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_account_yoy is
  'One row per account in the caller''s book, read from erp.agg_account_rollup '
  '(refreshed nightly by the ETL — see 030). security_invoker: RLS is the '
  'territory filter. yoy_change_amount/_pct are SQL columns so callers can '
  'ORDER BY them server-side (see 20260817120000).';

-- CREATE OR REPLACE preserves grants; restate for standalone replay.
revoke all on public.v_territory_account_yoy from anon, public;
grant select on public.v_territory_account_yoy to authenticated;

--------------------------------------------------------------------------
-- 2. Whole-book totals. SECURITY INVOKER: it aggregates the view above,
--    so the caller's RLS decides what "the book" is — no second
--    implementation of the access rules (010 header's argument).
--------------------------------------------------------------------------

create or replace function public.report_territory_summary()
returns table (
    accounts                  bigint,
    accounts_with_ytd_revenue bigint,
    revenue_ytd               numeric,
    revenue_prior_ytd         numeric,
    revenue_trailing_12m      numeric,
    open_order_value          numeric,
    backlog_amount            numeric,
    backlog_qty               numeric
)
language sql
stable
security invoker
set search_path = public
as $$
    select
        count(*)                                          as accounts,
        count(*) filter (where t.revenue_ytd > 0)         as accounts_with_ytd_revenue,
        coalesce(sum(t.revenue_ytd), 0)                   as revenue_ytd,
        coalesce(sum(t.revenue_prior_ytd), 0)             as revenue_prior_ytd,
        coalesce(sum(t.revenue_trailing_12m), 0)          as revenue_trailing_12m,
        coalesce(sum(t.open_order_value), 0)              as open_order_value,
        coalesce(sum(t.backlog_amount), 0)                as backlog_amount,
        coalesce(sum(t.backlog_qty), 0)                   as backlog_qty
    from public.v_territory_account_yoy t
$$;

comment on function public.report_territory_summary() is
  'Whole-book territory totals over v_territory_account_yoy, scoped by the '
  'caller''s own RLS (security invoker). One row. Used by the mcp Edge '
  'Function''s get_territory_summary so totals cover the entire book rather '
  'than a row-capped prefix.';

revoke execute on function public.report_territory_summary() from public, anon;
grant execute on function public.report_territory_summary() to authenticated;
