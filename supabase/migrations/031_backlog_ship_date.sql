/*============================================================================
  031_backlog_ship_date.sql
  Purpose: The Backlog intel page needs the desired ship date (shown to reps
           as "estimated production date") and the human-facing account ID
           (dim_customer.customer_id, e.g. "SMOK MOUN") so the grid can lead
           with the ID and demote the long legal name.

  v_backlog_by_sku is an account × SKU rollup, so the date arrives as
  min(desired_ship_date) across the open lines — the earliest thing
  production has committed to, same convention as earliest_promise_date.
============================================================================*/

-- Dropped rather than replaced: the new columns land mid-select, and
-- create-or-replace can only append. Nothing in-database depends on it.
drop view if exists public.v_backlog_by_sku;

create view public.v_backlog_by_sku
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
    max(o.order_date)                              as latest_order_date
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
left join erp.dim_part p on p.part_key = o.part_key
where o.is_backlog_line
group by
    o.customer_key, c.customer_id, c.customer_name, o.part_key,
    p.part_id, p.part_description, p.product_family, p.chambering;

comment on view public.v_backlog_by_sku is
  'Open backlog rolled up to (account, SKU): qty, value, line count, '
  'earliest promise date, earliest desired ship date (surfaced as '
  '"estimated production date"). security_invoker. Unfiltered = the '
  'caller''s territory backlog; .eq(customer_key) = one account''s card.';

revoke all on public.v_backlog_by_sku from anon, public;
grant select on public.v_backlog_by_sku to authenticated;
