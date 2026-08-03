/*============================================================================
  018_account_header_views.sql
  Purpose: The account page's order/shipment lists move from line grain to
           HEADER grain (one row per order, one row per packlist), with two
           uncapped line-detail views behind them for the drill-in modal.

           A rep scanning "where is order 51234?" wants 20 orders, not 20
           arbitrary lines that may all belong to three orders. The header
           row is the scannable unit; the lines are the detail behind a tap.

  Same contract as 011_account_views.sql — read its header before editing:
    - every view is `with (security_invoker = true)`; RLS on the erp fact
      tables is the security boundary, and these views are created by the
      table owner, so forgetting that line leaks every dealer's book.
    - the caller MUST filter customer_key. In the header views it is both
      the GROUP BY and the window PARTITION BY column, so the predicate is
      pushdown-safe and reaches idx_fol_customer_order_date /
      idx_fsl_customer_ship_date. In the line-detail views the caller also
      sends order_id / packlist_id, which hits each fact table's primary
      key index.
    - only certified measures: bookings, backlog_amount, backlog_qty,
      shipped_revenue. Dates via the generated *_date columns.

  tracking_number is erp.fact_shipment_line.waybill_number, surfaced at the
  header (max() — a packlist carries one waybill; max collapses the per-line
  duplicates). NOTE, verified 2026-08-03 against production: only 535 lines
  have a waybill and the newest is 2022 — bi.vw_FactShipmentLine is not
  landing tracking numbers for current shipments. The UI renders it when
  present; making it appear on new shipments is an upstream fix to the BI
  view, not a change here.

  The 011 line views (v_account_recent_orders / _recent_shipments) are left
  in place until the UI cutover is deployed, then can be dropped.
============================================================================*/

--------------------------------------------------------------------------
-- v_account_recent_order_headers
--   Grain: order. The 20 most recent orders per account.
--
--   Header status fields (order_state, order_status_desc, order_date) are
--   order-level attributes repeated on every line in the fact, so max() is
--   "pick the value", not an aggregation choice.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_order_headers
with (security_invoker = true)
as
select *
from (
    select
        h.*,
        row_number() over (
            partition by h.customer_key
            order by h.order_date desc nulls last, h.order_id desc
        ) as rn
    from (
        select
            o.customer_key,
            o.order_id,
            max(o.order_date)                                   as order_date,
            max(o.order_state)                                  as order_state,
            max(o.order_status_desc)                            as order_status_desc,
            count(*)::int                                       as line_count,
            coalesce(sum(o.order_qty), 0)::numeric              as order_qty,
            coalesce(sum(o.bookings), 0)::numeric               as bookings,
            count(*) filter (where o.is_backlog_line)::int      as open_line_count,
            coalesce(sum(o.backlog_qty)    filter (where o.is_backlog_line), 0)::numeric as backlog_qty,
            coalesce(sum(o.backlog_amount) filter (where o.is_backlog_line), 0)::numeric as backlog_amount,
            -- Next date the account is owed something — the rep's "when".
            min(o.promise_date) filter (where o.is_backlog_line) as next_promise_date
        from erp.fact_order_line o
        group by o.customer_key, o.order_id
    ) h
) r
where r.rn <= 20;

comment on view public.v_account_recent_order_headers is
  'Most recent 20 orders per account at header grain (lines rolled up). '
  'security_invoker. Always query with .eq(customer_key) — it is the GROUP '
  'BY and PARTITION BY column, so the predicate reaches the index. Lines '
  'for one order come from v_account_order_lines.';

--------------------------------------------------------------------------
-- v_account_recent_shipment_headers
--   Grain: packlist. The 20 most recent shipments per account.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_shipment_headers
with (security_invoker = true)
as
select *
from (
    select
        h.*,
        row_number() over (
            partition by h.customer_key
            order by h.ship_date desc nulls last, h.packlist_id desc
        ) as rn
    from (
        select
            s.customer_key,
            s.packlist_id,
            max(s.ship_date)                                    as ship_date,
            max(s.actual_delivery_date)                         as actual_delivery_date,
            max(s.shipment_state)                               as shipment_state,
            max(s.shipper_status_desc)                          as shipper_status_desc,
            max(s.waybill_number)                               as tracking_number,
            max(s.ship_via)                                     as ship_via,
            -- A packlist almost always ships one order; distinct keeps the
            -- rare multi-order packlist readable instead of "51234, 51234…".
            string_agg(distinct s.order_id, ', ')               as order_ids,
            count(*)::int                                       as line_count,
            coalesce(sum(s.shipped_qty), 0)::numeric            as shipped_qty,
            coalesce(sum(s.shipped_revenue), 0)::numeric        as shipped_revenue
        from erp.fact_shipment_line s
        group by s.customer_key, s.packlist_id
    ) h
) r
where r.rn <= 20;

comment on view public.v_account_recent_shipment_headers is
  'Most recent 20 packlists per account at header grain, with the UPS '
  'tracking number (waybill_number) when the ERP has one. security_invoker. '
  'Always query with .eq(customer_key). Lines for one packlist come from '
  'v_account_shipment_lines.';

--------------------------------------------------------------------------
-- v_account_order_lines / v_account_shipment_lines
--   Grain: line. NO top-N cap — these back the drill-in modal, which asks
--   for ONE order/packlist at a time. The client always sends
--   .eq(customer_key) AND .eq(order_id | packlist_id); the id predicate
--   resolves on the fact table's primary key index, so "uncapped" is a few
--   dozen rows, not a book scan.
--------------------------------------------------------------------------
create or replace view public.v_account_order_lines
with (security_invoker = true)
as
select
    o.customer_key,
    o.order_id,
    o.line_num,
    o.order_date,
    o.promise_date,
    o.line_status_desc,
    o.part_key,
    p.part_id,
    p.part_description,
    o.order_qty,
    o.bookings,
    o.backlog_qty,
    o.is_backlog_line
from erp.fact_order_line o
left join erp.dim_part p on p.part_key = o.part_key;

comment on view public.v_account_order_lines is
  'All lines of one order for the account drill-in modal. security_invoker. '
  'Always query with .eq(customer_key) AND .eq(order_id) — order_id leads '
  'the fact table''s primary key.';

create or replace view public.v_account_shipment_lines
with (security_invoker = true)
as
select
    s.customer_key,
    s.packlist_id,
    s.line_num,
    s.order_id,
    s.invoice_id,
    s.ship_date,
    s.actual_delivery_date,
    s.part_key,
    p.part_id,
    p.part_description,
    s.shipped_qty,
    s.shipped_revenue
from erp.fact_shipment_line s
left join erp.dim_part p on p.part_key = s.part_key;

comment on view public.v_account_shipment_lines is
  'All lines of one packlist for the account drill-in modal. '
  'security_invoker. Always query with .eq(customer_key) AND '
  '.eq(packlist_id) — packlist_id leads the fact table''s primary key.';

--------------------------------------------------------------------------
-- Grants — same posture as 011: anon has no business here.
--------------------------------------------------------------------------
revoke all on public.v_account_recent_order_headers    from anon, public;
revoke all on public.v_account_recent_shipment_headers from anon, public;
revoke all on public.v_account_order_lines             from anon, public;
revoke all on public.v_account_shipment_lines          from anon, public;

grant select on public.v_account_recent_order_headers    to authenticated;
grant select on public.v_account_recent_shipment_headers to authenticated;
grant select on public.v_account_order_lines             to authenticated;
grant select on public.v_account_shipment_lines          to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. RLS test suite: rep A gets zero rows for rep B's customer_key from all
     four relations (same drill as 011).
  2. Once the header-grain UI is deployed, drop v_account_recent_orders and
     v_account_recent_shipments from 011 in a later migration.
  3. Upstream: add the live tracking number to bi.vw_FactShipmentLine —
     waybill_number is empty for every shipment since 2022.
----------------------------------------------------------------------------*/
