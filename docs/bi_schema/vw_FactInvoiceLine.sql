/*============================================================================
  Object : bi.vw_FactInvoiceLine
  Source : VFIN.dbo.RECEIVABLES_RECEIVABLE_LINE  (rl — the grain)
           JOIN  VFIN.dbo.RECEIVABLES_RECEIVABLE (rh — invoice header attrs/dates)
           LEFT JOIN VECA.dbo.CUST_ORDER_LINE    (oln — PART_ID + SITE_ID)
           LEFT JOIN VECA.dbo.CUSTOMER_ORDER     (ord — ship-to resolution)
           LEFT JOIN VECA.dbo.SALES_REP          (rep — key existence check)
  Grain  : ONE ROW PER AR INVOICE LINE = (INVOICE_ENTITY_ID, INVOICE_ID, LINE_NO).
           The revenue / billing fact, sourced from VFIN AR (authoritative for
           tax, credit memos, payment status, GL posting). Separate fact from
           order and shipment; lifecycle is joined via shared dims, never
           fact-to-fact.

  WHY VFIN (not VECA shipper-invoice): VECA only holds a partial AR slice
  (SHIPPER.INVOICE_ID + SHIPPER_LINE.RECEIVABLE_AMOUNT). The true invoice — tax,
  credit/debit memos, payment status, GL revenue accounts — lives in VFIN. VFIN
  is on the SAME SQL instance, so this reads it by three-part name. Requires the
  BI service account to have SELECT on VFIN.dbo (same grant the credit join in
  vw_DimCustomer needs).

  SINGLE ENTITY: this install runs one accounting entity, so the composite key
  is effectively (INVOICE_ID, LINE_NO) and no ENTITY filter is applied.

  KEY SOURCING GOTCHAS:
    - RECEIVABLES_RECEIVABLE_LINE has NO PART_ID and NO SITE_ID. Both are
      resolved by back-joining VECA CUST_ORDER_LINE on (CUST_ORDER_ID,
      CUST_ORDER_LINE_NO). Those refs are NULL on non-order lines (freight,
      finance charge, manual memo) -> LEFT JOIN -> '(Unknown)' part/site. The
      FREIGHT_LINE flag is exposed so those are identifiable.
    - Ship-to is not on the AR line; resolved from the source order header
      (CUSTOMER_ORDER.SHIP_TO_ADDR_NO) when an order link exists. With no order
      link or no ship-to addr, it falls back to the customer-master ship-to
      (invoice-header CUSTOMER_ID + '|CUST'); '(Unknown)' only if no customer.
    - CUSTOMER_ID / SALESREP_ID in VFIN are the SAME logical Visual IDs as VECA
      (kept in sync by the LSA exchange layer), so they join straight to the
      VECA-sourced DimCustomer / DimSalesRep. The C-INV orphan checks in
      99_validation will flag any drift.

  HEADER TOTALS DELIBERATELY EXCLUDED: TOTAL_AMOUNT / TOTAL_TAX_AMOUNT /
  TOTAL_PAID_AMOUNT etc. are invoice-HEADER grain; summing them on a line fact
  double-counts. If AR/aging/payment analysis is needed, build a separate
  header-grain FactInvoice — do NOT smear header totals across lines here.

  MEMOS (verified against live data — do NOT assume the textbook convention):
  INVOICE_TYPE has only two values here, 'INVOICE' and 'MEMO'; the doc-class
  field DOCUMENT_TYPE_ID mirrors them as 'AR' / 'ARM'. In THIS install memos are
  NOT stored as negative credit memos — memo headers are never negative (~$26M
  positive across 9,327 memos), most memo lines are positive, and some memos
  carry offsetting +/- lines that net to zero. So a report CANNOT net memos by
  summing a negative AMOUNT. ~78% of memo lines are order/shipper-linked; the
  rest are purely financial. Whether ARM memos belong in certified sales Revenue
  is a FINANCE decision — the base Revenue measure exposes them via IsMemo /
  DocumentTypeID / InvoiceType so reports include or exclude them explicitly.
  Revenue = invoice line AMOUNT; this is the single certified revenue grain
  (Bookings lives on FactOrderLine, ShippedRevenue on FactShipmentLine).

  NO STATUS FILTER. InvoiceStatus / PostedFlag exposed as columns.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactInvoiceLine
AS
SELECT
    -- Degenerate dimensions (identify the invoice line; live on the fact)
    rl.INVOICE_ID                         AS InvoiceID,
    rl.LINE_NO                            AS InvoiceLineNo,
    rl.INVOICE_ENTITY_ID                  AS InvoiceEntityID,
    rh.INVOICE_STATUS                     AS InvoiceStatus,
    rh.INVOICE_TYPE                       AS InvoiceType,
    -- DOCUMENT_TYPE_ID is the authoritative doc-class field: 'AR' = invoice,
    -- 'ARM' = AR memo (verified live — these are the only two values). IsMemo
    -- lets the certified Revenue measure include/exclude memos explicitly
    -- rather than relying on amount sign (see memo note in the header).
    rh.DOCUMENT_TYPE_ID                   AS DocumentTypeID,
    CASE WHEN rh.INVOICE_TYPE = 'MEMO' THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS IsMemo,
    -- Decoded labels + a lifecycle bucket so reports tag invoices without DAX.
    CASE rh.INVOICE_STATUS
        WHEN 'OPEN' THEN 'Open' WHEN 'CLOSED' THEN 'Closed' WHEN 'VOID' THEN 'Void'
        ELSE rh.INVOICE_STATUS
    END                                   AS InvoiceStatusDesc,
    CASE rh.INVOICE_TYPE
        WHEN 'INVOICE' THEN 'Invoice' WHEN 'MEMO' THEN 'Memo'
        ELSE rh.INVOICE_TYPE
    END                                   AS InvoiceTypeDesc,
    CASE
        WHEN rh.INVOICE_STATUS = 'VOID' THEN 'Void'
        WHEN rh.INVOICE_STATUS = 'OPEN' THEN 'Open'
        ELSE 'Closed'
    END                                   AS InvoiceState,
    rh.POSTED                             AS PostedFlag,
    rh.SHIPPER_GENERATED                  AS ShipperGeneratedFlag,
    rl.FREIGHT_LINE                       AS FreightLineFlag,
    rl.CUST_ORDER_ID                      AS OrderID,
    rl.CUST_ORDER_LINE_NO                 AS OrderLineNo,
    rl.SHIPPER_ID                         AS PacklistID,
    rl.CUSTOMER_PO_REF                    AS CustomerPONumber,
    rl.ACCOUNT_ID                         AS RevenueAccountID,
    rl.CURRENCY_ID                        AS CurrencyID,
    rh.BILL_TO_CUST_ID                    AS BillToCustomerID,

    -- Dimension foreign keys
    COALESCE(NULLIF(rh.CUSTOMER_ID, N''), N'(Unknown)')                        AS CustomerKey,
    -- Ship-to from the source order, resolved only when the CUST_ADDRESS row
    -- exists. With no order link (freight / finance / manual memo lines), no
    -- ship-to addr, or a stale addr ref, fall back to the customer-master
    -- ship-to ('|CUST') using the invoice-header customer, so these lines land
    -- on the customer's own address instead of orphaning. The fallback uses
    -- cust.ID (invoice-header customer gated on existence in VECA CUSTOMER), so
    -- an AR-only customer absent from VECA never produces a dangling '|CUST'
    -- key — it lands on '(Unknown)' and is caught by the CI1 customer check.
    CASE
        WHEN COALESCE(ord.CUSTOMER_ID, cust.ID) IS NULL THEN N'(Unknown)'
        WHEN sa.ADDR_NO IS NULL THEN COALESCE(ord.CUSTOMER_ID, cust.ID) + N'|CUST'
        ELSE ord.CUSTOMER_ID + N'|' + CAST(sa.ADDR_NO AS nvarchar(20))
    END                                                                        AS ShipToKey,
    COALESCE(rep.ID, N'(Unknown)')                                             AS SalesRepKey,
    COALESCE(NULLIF(oln.PART_ID, N''), N'(Unknown)')                           AS PartKey,
    COALESCE(NULLIF(oln.SITE_ID, N''), N'(Unknown)')                           AS SiteKey,

    -- Role-played date keys (integer yyyymmdd; sentinel 19000101 for NULLs)
    COALESCE(CAST(CONVERT(char(8), rh.INVOICE_DATE, 112) AS int), 19000101)    AS InvoiceDateKey,
    COALESCE(CAST(CONVERT(char(8), rh.LAST_PAID_DATE, 112) AS int), 19000101)  AS LastPaidDateKey,

    -- Measures (additive at this invoice-line grain unless noted).
    -- Header totals are intentionally absent — see header comment.
    rl.QTY                                AS InvoiceQty,
    rl.AMOUNT                             AS Revenue,              -- net AR line revenue — the REVENUE headline measure (see memo note in header)
    rl.COMMISSION_AMOUNT                  AS CommissionAmount,
    rl.UNIT_PRICE                         AS UnitPrice,            -- NON-additive (rate)
    rl.COMMISSION_PCT                     AS CommissionPct         -- NON-additive (rate)
FROM VFIN.dbo.RECEIVABLES_RECEIVABLE_LINE AS rl
INNER JOIN VFIN.dbo.RECEIVABLES_RECEIVABLE AS rh
    ON rh.ENTITY_ID  = rl.INVOICE_ENTITY_ID
   AND rh.INVOICE_ID = rl.INVOICE_ID
LEFT JOIN dbo.CUST_ORDER_LINE AS oln
    ON oln.CUST_ORDER_ID = rl.CUST_ORDER_ID
   AND oln.LINE_NO       = rl.CUST_ORDER_LINE_NO
LEFT JOIN dbo.CUSTOMER_ORDER AS ord
    ON ord.ID = rl.CUST_ORDER_ID
LEFT JOIN dbo.SALES_REP AS rep
    ON rep.ID = rl.SALESREP_ID
-- Existence probe for the source order's ship-to address, PK
-- (CUSTOMER_ID, ADDR_NO) so 1:1 — drives the ShipToKey fallback above.
LEFT JOIN dbo.CUST_ADDRESS AS sa
    ON sa.CUSTOMER_ID = ord.CUSTOMER_ID
   AND sa.ADDR_NO     = ord.SHIP_TO_ADDR_NO
-- Existence gate: the invoice-header customer in VECA. cust.ID is NULL for
-- AR-only customers not synced to VECA, so the '|CUST' fallback never dangles.
LEFT JOIN dbo.CUSTOMER AS cust
    ON cust.ID = rh.CUSTOMER_ID;
GO
