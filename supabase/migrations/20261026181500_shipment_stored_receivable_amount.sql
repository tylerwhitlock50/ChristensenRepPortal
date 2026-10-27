/*============================================================================
  20261026181500_shipment_stored_receivable_amount.sql — land the column
  bi.vw_FactShipmentLine grew on 2026-10-26.

  Why
  ---
  The source view was restated alongside the vw_DimCustomer tax-ID change
  (20261026180000). It now emits StoredReceivableAmount, so the 17:03 load
  failed with

      column "stored_receivable_amount" of relation "fact_shipment_line" does not exist

  and, with dim_customer also failing, post-load (rollups, scoring) was
  skipped. The live table was untouched (the failure is in the staging COPY).

  What the view change means for `shipped_revenue`
  ------------------------------------------------
  stored_receivable_amount is what `shipped_revenue` used to be: the amount
  stored on the ERP shipper line (its total over the view matches
  shipped_revenue as loaded at 13:30 on 2026-10-26, to the cent).
  `shipped_revenue` is now computed: shipped_qty_selling_um x unit_price x
  (1 - trade_discount_pct / 100). The two agree on ~97% of lines; the rest
  are almost all invoiced lines shipped before 2026-05-07, plus the
  not-yet-invoiced recent lines whose stored amount was null and now get a
  value. So historical shipment dollars move, and recent un-invoiced
  shipments show an amount where they showed none.

  shipped_revenue feeds the shipment views (v_account_recent_shipments,
  v_account_shipment_lines, v_account_recent_shipment_headers,
  v_territory_recent_events) — not the revenue rollups, which read
  fact_invoice_line.

  Grants
  ------
  fact_shipment_line is column-granted (20260901190300), so the new column is
  NOT readable by authenticated until granted. Deliberately left that way:
  nothing in the app reads it. Grant by name when a caller needs it.
============================================================================*/

alter table erp.fact_shipment_line
  add column if not exists stored_receivable_amount numeric;

comment on column erp.fact_shipment_line.stored_receivable_amount is
  'Amount stored on the ERP shipper line — what `shipped_revenue` was before '
  'the 2026-10-26 view restatement. `shipped_revenue` is now qty x unit price '
  'net of trade discount.';
