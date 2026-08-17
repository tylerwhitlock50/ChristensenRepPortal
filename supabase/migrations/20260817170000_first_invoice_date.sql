/*============================================================================
  20260817170000_first_invoice_date.sql — the new-account signal.

  Why
  ---
  "Which of my accounts are new this year?", "who has never ordered?",
  "which ones did I open and then lose?" — prospecting questions — had no
  source: nothing exposed when an account FIRST invoiced. One more window
  on the nightly account rollup answers all three:

    - first_invoice_date recent            → a new account
    - first_invoice_date null              → never invoiced (pure prospect)
    - first this year + last months ago    → opened and lost

  Appended to erp.agg_account_rollup and v_territory_account_yoy (last
  column, so no existing consumer moves), and the refresh function is
  restated in full — its single-home-of-the-windows rule (030).
============================================================================*/

--------------------------------------------------------------------------
-- 1. The column.
--------------------------------------------------------------------------

alter table erp.agg_account_rollup
  add column if not exists first_invoice_date date;

comment on column erp.agg_account_rollup.first_invoice_date is
  'The account''s FIRST invoice ever (memos excluded). Null = never '
  'invoiced. The new-account / prospecting signal.';

--------------------------------------------------------------------------
-- 2. The refresh, restated in full with the new window.
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
    revenue_prior_full, first_invoice_date
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
    coalesce(inv.revenue_prior_full, 0),
    inv.first_invoice_date
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
-- 3. The territory view, first_invoice_date appended.
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
    end                                          as yoy_change_pct,
    a.first_invoice_date
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_account_yoy is
  'One row per account in the caller''s book, read from erp.agg_account_rollup '
  '(refreshed nightly by the ETL — see 030). security_invoker: RLS is the '
  'territory filter. yoy_change_amount/_pct are SQL columns for server-side '
  'ORDER BY (20260817120000); first_invoice_date is the new-account signal '
  '(20260817170000, null = never invoiced).';

revoke all on public.v_territory_account_yoy from anon, public;
grant select on public.v_territory_account_yoy to authenticated;

--------------------------------------------------------------------------
-- 4. First fill.
--------------------------------------------------------------------------
select public.refresh_territory_rollups();
