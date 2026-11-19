/*============================================================================
  20261119110000_shipment_service_line_columns.sql — land the two columns
  bi.vw_FactShipmentLine grew on 2026-11-16.

  Why
  ---
  All ten bi.vw_* views were redeployed at 14:26 on 2026-11-16. Nine came
  back with the columns they had; vw_FactShipmentLine now also emits
  ServiceChargeID and IsServiceLine. Every load from the 15:05 hourly run on
  failed that table with

      column "service_charge_id" of relation "fact_shipment_line" does not exist

  (is_service_line would have been the next one named). fact_shipment_line
  is in post_load_requires, so post-load was skipped on every run since: the
  rollups, order change capture and order QC stopped at 14:05 on 2026-11-16
  while orders and invoices kept loading. The live table was untouched (the
  failure is in the staging COPY).

  What the columns are
  --------------------
  The same pair erp.fact_order_line has carried since 002, same types.
  The grain did not change: service lines were always in this table, they
  are now labelled. 12,126 of ~497k lines, 20 service charge ids (customer
  returns, stock finishing, the generic "SERVICE CHARGE"), $634.6k of
  shipped_revenue, none shipped after 2024-05-21 — so no current-year figure
  includes one. Totals in the view match the live table apart from the three
  days of shipments not yet loaded.

  First load after this
  ---------------------
  The table is on swap: merge, which compares every loaded column. Each live
  row holds NULL in is_service_line where the view supplies true/false, so
  the first merge deletes and re-inserts every row — one replace-sized
  rewrite, then back to a few hundred rows a run.

  Grants
  ------
  fact_shipment_line is column-granted (20260901190300), so the new columns
  are NOT readable by authenticated until granted. Left that way, as with
  stored_receivable_amount (20261026181500): nothing in the app reads them.
  Neither is sensitive (both are readable on fact_order_line) — grant by
  name when a view needs to filter service lines.
============================================================================*/

alter table erp.fact_shipment_line
  add column if not exists service_charge_id text,
  add column if not exists is_service_line   boolean;

comment on column erp.fact_shipment_line.service_charge_id is
  'ERP service charge on a service line (CUSTOMER-RETURN, SERVICE CHARGE, '
  'finishing work); null on part lines. Published by the view since 2026-11-16.';

comment on column erp.fact_shipment_line.is_service_line is
  'True when the packlist line ships a service charge rather than a part. '
  'Published by the view since 2026-11-16; no service line after 2024-05-21.';
