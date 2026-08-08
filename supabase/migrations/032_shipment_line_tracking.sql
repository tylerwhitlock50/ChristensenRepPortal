/*============================================================================
  032_shipment_line_tracking.sql
  Purpose: Land the LINE-level tracking number from the ERP and prefer it
           over the header waybill in the account shipment views.

  Why
  ---
  018 surfaced tracking as max(waybill_number) — a SHIPPER-header field the
  feed stopped populating after 2022 (verified 2026-08-03: 535 rows, newest
  2022). The real tracking number for current shipments is carried on the
  shipment LINE, and bi.vw_FactShipmentLine is gaining a TrackingNumber
  column sourced from it.

  ETL coupling — apply BEFORE the upstream column ships
  -----------------------------------------------------
  etl/push_to_supabase.py builds its COPY column list from the SOURCE view's
  columns (SELECT * → to_snake). The moment bi.vw_FactShipmentLine emits
  TrackingNumber, the nightly load COPYs into erp.fact_shipment_line
  (tracking_number, …) — which fails with "column does not exist" until this
  migration runs. Until upstream ships, the column simply stays NULL and the
  COPY never references it, so applying this first is safe in both orders
  that end well.

  The column must arrive upstream named exactly TrackingNumber (→
  tracking_number). A different spelling (TrackingNo, TRACKING_NUMBER after
  the naive splitter, …) lands a different snake_case name and the COPY
  fails the same way; add a column_map override in etl/views.yml if the
  upstream name ends up not being TrackingNumber.

  View changes (create or replace keeps positions; new columns go LAST)
  ---------------------------------------------------------------------
    v_account_recent_shipment_headers.tracking_number
        was  max(waybill_number)
        now  coalesce(max(tracking_number), max(waybill_number))
        — line tracking wins; old shipments keep showing their waybill.
    v_account_shipment_lines
        + tracking_number (line value, waybill fallback) appended, so the
        drill-in modal can show per-line tracking on multi-package
        shipments.

  Same contract as 011/018 — security_invoker everywhere, caller always
  filters customer_key (and packlist_id on the line view).
============================================================================*/

alter table erp.fact_shipment_line
  add column if not exists tracking_number text;

--------------------------------------------------------------------------
-- v_account_recent_shipment_headers — body identical to 018 except the
-- tracking_number expression.
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
            -- Line-level tracking first; header waybill keeps pre-2022
            -- shipments linkable. max() collapses per-line duplicates —
            -- a multi-package packlist shows one number here, all of them
            -- in v_account_shipment_lines.
            coalesce(max(s.tracking_number), max(s.waybill_number))
                                                                as tracking_number,
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
  'tracking number (line tracking_number, waybill_number fallback). '
  'security_invoker. Always query with .eq(customer_key). Lines for one '
  'packlist come from v_account_shipment_lines.';

--------------------------------------------------------------------------
-- v_account_shipment_lines — 018's body with tracking_number appended
-- (create or replace view only allows adding columns at the end).
--------------------------------------------------------------------------
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
    s.shipped_revenue,
    coalesce(s.tracking_number, s.waybill_number) as tracking_number
from erp.fact_shipment_line s
left join erp.dim_part p on p.part_key = s.part_key;

comment on view public.v_account_shipment_lines is
  'All lines of one packlist for the account drill-in modal, each with its '
  'own tracking number (waybill fallback). security_invoker. Always query '
  'with .eq(customer_key) AND .eq(packlist_id) — packlist_id leads the fact '
  'table''s primary key.';

--------------------------------------------------------------------------
-- Grants — create or replace preserves them; restated so this file stands
-- alone against a fresh database mid-sequence (same posture as 030).
--------------------------------------------------------------------------
revoke all on public.v_account_recent_shipment_headers from anon, public;
revoke all on public.v_account_shipment_lines          from anon, public;

grant select on public.v_account_recent_shipment_headers to authenticated;
grant select on public.v_account_shipment_lines          to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Confirm bi.vw_FactShipmentLine's new column is named TrackingNumber and
     update docs/bi_schema/vw_FactShipmentLine.sql to match the deployed DDL
     (the mirror in this repo predates the column).
  2. After the first nightly load with the new column:
       select count(*) from erp.fact_shipment_line
        where tracking_number is not null and ship_date >= current_date - 30;
     should be > 0 — that is the whole point of the change.
----------------------------------------------------------------------------*/
