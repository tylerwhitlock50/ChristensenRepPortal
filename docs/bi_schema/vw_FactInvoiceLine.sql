/*============================================================================
  Object : bi.vw_FactInvoiceLine
  Source : VFIN.dbo.RECEIVABLES_RECEIVABLE_LINE  (rl — the grain)
           JOIN  VFIN.dbo.RECEIVABLES_RECEIVABLE (rh — invoice header attrs/dates)
           LEFT JOIN VECA.dbo.CUST_ORDER_LINE    (oln — PART_ID + SITE_ID)
           LEFT JOIN VECA.dbo.CUSTOMER_ORDER     (ord — ship-to resolution)
           LEFT JOIN VECA.dbo.SALES_REP          (rep — key existence check)
           LEFT JOIN VECA.dbo.RECEIVABLE[_LINE]  (signed TDJ memo amount)
           LEFT JOIN VFIN.dbo.LEDGER_ACCOUNT    (entity/account class)
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

  MEMO SIGN CONTRACT (2026-09-10): VFIN MEMO/ARM AMOUNT uses the opposite
  polarity to signed billing revenue. Positive stored amounts are credits;
  negative stored amounts are debit/offset lines. Verified against VFIN REV
  distributions (CREDIT_AMOUNT - DEBIT_AMOUNT), including ARM02853.
  For matching TDJ VECA memo lines, pass signed RECEIVABLE_LINE.AMOUNT through.
  Match customer, site, and account as well as invoice/line: ordinary invoice
  tax lines can reuse the line number of a DIFFERENT VFIN adjustment.
  Otherwise negate VFIN MEMO/ARM AMOUNT once; ordinary invoices pass through.
  Do not use ABS or quantity/price to infer direction. RawVfinAmount and
  RevenueSignBasis preserve the audit trail. This is billing, not GL actuals:
  void/reversal distributions may net to zero while the original line remains.
  Retain non-revenue accounts; IsRevenueAccount uses the entity's ledger class
  (not a 4xxx/6xxx prefix). Sales measures filter this flag and exclude VOID.

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
    CASE WHEN rh.INVOICE_TYPE = 'MEMO' AND rh.DOCUMENT_TYPE_ID = 'ARM'
         THEN CASE WHEN vrl.INVOICE_ID IS NOT NULL THEN vrl.AMOUNT
                   ELSE -rl.AMOUNT END
         ELSE rl.AMOUNT END               AS Revenue,
    rl.COMMISSION_AMOUNT                  AS CommissionAmount,
    rl.UNIT_PRICE                         AS UnitPrice,            -- NON-additive (rate)
    rl.COMMISSION_PCT                     AS CommissionPct,        -- NON-additive (rate)
    -- Append audit/scope fields to preserve existing column ordinals.
    rl.AMOUNT                             AS RawVfinAmount,
    CASE WHEN rh.INVOICE_TYPE = 'MEMO' AND rh.DOCUMENT_TYPE_ID = 'ARM'
         THEN CASE WHEN vrl.INVOICE_ID IS NOT NULL THEN N'VECA signed memo'
                   ELSE N'VFIN memo polarity' END
         ELSE N'VFIN invoice amount' END   AS RevenueSignBasis,
    gla.AccountClass                     AS RevenueAccountClass,
    CAST(CASE WHEN gla.AccountClass = 'REV' THEN 1
              WHEN gla.AccountClass IS NOT NULL THEN 0
              ELSE NULL END AS bit)      AS IsRevenueAccount
FROM VFIN.dbo.RECEIVABLES_RECEIVABLE_LINE AS rl
INNER JOIN VFIN.dbo.RECEIVABLES_RECEIVABLE AS rh
    ON rh.ENTITY_ID  = rl.INVOICE_ENTITY_ID
   AND rh.INVOICE_ID = rl.INVOICE_ID
-- VECA's invoice key is global, but only TDJ is the verified entity/site
-- mapping. Never reuse its amounts for another VFIN entity with the same ID.
LEFT JOIN dbo.RECEIVABLE AS vr
    ON rh.ENTITY_ID = N'TDJ'
   AND vr.SITE_ID = N'TDJ'
   AND vr.INVOICE_ID = rl.INVOICE_ID
   AND vr.CUSTOMER_ID = rh.CUSTOMER_ID
   AND vr.TYPE = 'M'
   AND rh.INVOICE_TYPE = 'MEMO'
   AND rh.DOCUMENT_TYPE_ID = 'ARM'
LEFT JOIN dbo.RECEIVABLE_LINE AS vrl
    ON vrl.INVOICE_ID = vr.INVOICE_ID
   AND vrl.LINE_NO = rl.LINE_NO
   AND vrl.GL_ACCOUNT_ID = rl.ACCOUNT_ID
-- VFIN has surrogate PKs; collapse to the business key to prevent fan-out.
-- Conflicting classes are unknown, never arbitrarily classified as revenue.
LEFT JOIN (
    SELECT ENTITY_ID, ACCOUNT_ID,
           CASE WHEN COUNT(*) = COUNT(NULLIF(ACCOUNT_CLASS, N''))
                     AND MIN(ACCOUNT_CLASS) = MAX(ACCOUNT_CLASS)
                THEN MIN(ACCOUNT_CLASS) END AS AccountClass
    FROM VFIN.dbo.LEDGER_ACCOUNT
    GROUP BY ENTITY_ID, ACCOUNT_ID
) AS gla
    ON gla.ENTITY_ID = rl.INVOICE_ENTITY_ID
   AND gla.ACCOUNT_ID = rl.ACCOUNT_ID
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
