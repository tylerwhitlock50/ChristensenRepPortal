/*============================================================================
  Object : bi.vw_FactShipmentLine
  Source : VECA.dbo.SHIPPER_LINE   (line — the grain)
           JOIN  VECA.dbo.SHIPPER        (hdr: dates, site, rep, ship-to, status)
           JOIN  VECA.dbo.CUSTOMER_ORDER (ord: customer, ship-to fallback, promise)
           LEFT JOIN VECA.dbo.CUST_ORDER_LINE (oln: PART_ID + line promise date)
           LEFT JOIN VECA.dbo.USER_DEF_FIELDS (trk: line-level tracking number)
           LEFT JOIN VECA.dbo.SALES_REP       (rep existence check for key)
           LEFT JOIN VECA.dbo.INVENTORY_TRANS (itx: ACTUAL COGS at ship time)
  Grain  : ONE ROW PER PACKLIST LINE = (PACKLIST_ID, LINE_NO).
           This is the SHIPMENT / fulfilment fact (what physically shipped and
           what was booked to AR). It is a SEPARATE fact from FactOrderLine;
           the two are compared via shared dimensions, NEVER joined fact-to-fact.

  KEY SOURCING GOTCHAS (verified against DDL, not the curated doc):
    - SHIPPER_LINE has NO PART_ID. Part is resolved by joining back to
      CUST_ORDER_LINE on (CUST_ORDER_ID, CUST_ORDER_LINE_NO). That line ref is
      NULLABLE (misc / freight / service shipment lines) -> LEFT JOIN -> those
      rows land on the '(Unknown)' part sentinel. This is expected, not a bug.
    - SHIPPER_LINE has NO SITE_ID. Site comes from the SHIPPER header.
    - Tracking number is the VMSHPENT shipper-line UDF UDF-0000028. Its UDF
      definition targets TABLE_ID = 'tblShpLineItem', so the value joins on
      (DOCUMENT_ID, LINE_NO) = (SHIPPER_LINE.PACKLIST_ID, SHIPPER_LINE.LINE_NO).
      Blank and placeholder '0' values are exposed as NULL. This is distinct
      from the packlist-header SHIPPER.WAYBILL_NUMBER.
    - Transacting rep = SHIPPER.SALESREP_ID (snapshotted at SHIP time). This is
      deliberately the ship-time rep, which can differ from the order's rep.
    - Ship-to = SHIPPER.SHIP_TO_ADDR_NO (header override) falling back to the
      order's SHIP_TO_ADDR_NO; customer always comes from the order header.
    - COGS is ACTUAL cost from INVENTORY_TRANS via SHIPPER_LINE.TRANSACTION_ID
      (integer PK -> 1:1, no fan-out). Signed by TYPE ('O' sale = +, 'I' return
      = -) so it nets the same way returns net ShippedRevenue. NULL on
      freight/service lines with no TRANSACTION_ID (~2.6%). This is actual cost
      flow, NOT standard cost (DimPart carries the static standard). ~97% of
      lines link; GrossMarginAmount = ShippedRevenue - COGSAmount at this grain.

  Dimension keys (all coalesced to a sentinel so rows never silently drop):
    CustomerKey  -> DimCustomer  (order header CUSTOMER_ID)
    ShipToKey    -> DimShipTo    (CUSTOMER_ID + '|' + COALESCE(shipper, order addr);
                                  CUSTOMER_ID + '|CUST' fallback when no ship-to)
    SalesRepKey  -> DimSalesRep  (SHIPPER.SALESREP_ID; '(Unknown)' if no match)
    PartKey      -> DimPart      (order line PART_ID; '(Unknown)' if none)
    SiteKey      -> DimSite      (SHIPPER.SITE_ID)
    ShipDateKey, InvoicedDateKey, ActualDeliveryDateKey, PromiseDateKey
                 -> DimDate (role-played). PromiseDateKey carries the ORDER
                    LINE's commitment onto the shipment so OTD (ship vs promise)
                    is computable within this one fact — no fact-to-fact join.

  NO STATUS FILTER. ShipperStatus / RevenueStatus / NoInvoiceFlag are exposed as
  columns so report authors filter VISIBLY. Do not add a WHERE on STATUS here.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactShipmentLine
AS
SELECT
    -- Degenerate dimensions (identify the shipment line; live on the fact)
    sl.PACKLIST_ID                        AS PacklistID,
    sl.LINE_NO                            AS LineNum,
    sl.CUST_ORDER_ID                      AS OrderID,
    sl.CUST_ORDER_LINE_NO                 AS OrderLineNo,
    hdr.STATUS                            AS ShipperStatus,
    -- SHIPPER.STATUS is its OWN enum (separate from order status): A = Approved,
    -- S = Shipped, and review states '1'/'2'/'3' = Review 1/2/3 (pre-approval
    -- workflow steps; confirmed via PL-283003 = '1').
    CASE hdr.STATUS
        WHEN 'A' THEN 'Approved' WHEN 'S' THEN 'Shipped'
        WHEN '1' THEN 'Review 1' WHEN '2' THEN 'Review 2' WHEN '3' THEN 'Review 3'
        ELSE hdr.STATUS
    END                                   AS ShipperStatusDesc,
    CASE WHEN hdr.STATUS IN ('A', 'S') THEN 'Shipped' ELSE 'In Review' END AS ShipmentState,
    sl.REVENUE_STATUS                     AS RevenueStatus,
    sl.NO_INVOICE                         AS NoInvoiceFlag,
    hdr.INVOICE_ID                        AS InvoiceID,
    hdr.BOL_ID                            AS BillOfLadingID,
    hdr.WAYBILL_NUMBER                    AS WaybillNumber,
    NULLIF(NULLIF(LTRIM(RTRIM(trk.STRING_VAL)), N''), N'0') AS TrackingNumber,
    hdr.SHIP_VIA                          AS ShipVia,
    hdr.FREE_ON_BOARD                     AS FreeOnBoard,
    sl.MISC_REFERENCE                     AS MiscReference,
    sl.RMA_ID                             AS RMAID,

    -- Dimension foreign keys
    COALESCE(NULLIF(ord.CUSTOMER_ID, N''), N'(Unknown)')                       AS CustomerKey,
    -- Real ship-to only when the CUST_ADDRESS row exists; else customer-master
    -- fallback ('|CUST'). Covers no-ship-to AND stale addr refs -> never orphans.
    CASE
        WHEN ord.CUSTOMER_ID IS NULL THEN N'(Unknown)'
        WHEN sa.ADDR_NO IS NULL      THEN ord.CUSTOMER_ID + N'|CUST'
        ELSE ord.CUSTOMER_ID + N'|' + CAST(sa.ADDR_NO AS nvarchar(20))
    END                                                                       AS ShipToKey,
    COALESCE(rep.ID, N'(Unknown)')                                            AS SalesRepKey,
    COALESCE(NULLIF(oln.PART_ID, N''), N'(Unknown)')                          AS PartKey,
    COALESCE(NULLIF(hdr.SITE_ID, N''), N'(Unknown)')                          AS SiteKey,

    -- Role-played date keys (integer yyyymmdd; sentinel 19000101 for NULLs)
    COALESCE(CAST(CONVERT(char(8), hdr.SHIPPED_DATE, 112) AS int), 19000101)     AS ShipDateKey,
    COALESCE(CAST(CONVERT(char(8), hdr.INVOICED_DATE, 112) AS int), 19000101)    AS InvoicedDateKey,
    COALESCE(CAST(CONVERT(char(8), hdr.ACTUAL_DEL_DATE, 112) AS int), 19000101)  AS ActualDeliveryDateKey,
    COALESCE(CAST(CONVERT(char(8),
        COALESCE(oln.PROMISE_DATE, ord.PROMISE_DATE), 112) AS int), 19000101)    AS PromiseDateKey,

    -- Measures (additive at this packlist-line grain unless noted)
    sl.SHIPPED_QTY                        AS ShippedQty,           -- stocking UM
    sl.USER_SHIPPED_QTY                   AS ShippedQtySellingUM,  -- selling UM
    sl.RECEIVABLE_AMOUNT                  AS ShippedRevenue,       -- net shipped revenue booked to AR — the SHIPPED headline measure
    sl.ACT_FREIGHT                        AS ActualFreight,
    sl.SHIPPING_WEIGHT                    AS ShippingWeight,
    -- COGS: ACTUAL cost at ship time from the linked inventory movement
    -- (SHIPPER_LINE.TRANSACTION_ID -> INVENTORY_TRANS, integer PK so 1:1).
    -- Signed by movement direction to match how returns already sign
    -- ShippedRevenue: TYPE='O' (outbound sale) = +cost, TYPE='I' (return to
    -- stock) = -cost. NULL on non-inventory lines (freight/service, ~2.6% with
    -- no TRANSACTION_ID) so they don't dilute cost. Actual cost FLOW, not
    -- standard cost x qty (the static standard lives on DimPart as reference).
    CASE WHEN itx.TRANSACTION_ID IS NULL THEN NULL
         ELSE (CASE WHEN itx.TYPE = 'O' THEN 1 ELSE -1 END)
            * ( COALESCE(itx.ACT_MATERIAL_COST,0) + COALESCE(itx.ACT_LABOR_COST,0)
              + COALESCE(itx.ACT_BURDEN_COST,0)   + COALESCE(itx.ACT_SERVICE_COST,0) )
    END                                   AS COGSAmount,
    -- Gross margin at packlist-line grain = ShippedRevenue - COGS (SQL, not DAX).
    -- NULL when COGS is NULL (freight/service) so margin isn't overstated as
    -- pure revenue; for a margin %, aggregate ShippedRevenue and COGSAmount
    -- separately and divide.
    CASE WHEN itx.TRANSACTION_ID IS NULL THEN NULL
         ELSE sl.RECEIVABLE_AMOUNT
            - (CASE WHEN itx.TYPE = 'O' THEN 1 ELSE -1 END)
            * ( COALESCE(itx.ACT_MATERIAL_COST,0) + COALESCE(itx.ACT_LABOR_COST,0)
              + COALESCE(itx.ACT_BURDEN_COST,0)   + COALESCE(itx.ACT_SERVICE_COST,0) )
    END                                   AS GrossMarginAmount,
    -- Raw actual cost components (as stored) for drill-down / cost-element mix
    itx.ACT_MATERIAL_COST                 AS COGSMaterial,
    itx.ACT_LABOR_COST                    AS COGSLabor,
    itx.ACT_BURDEN_COST                   AS COGSBurden,
    itx.ACT_SERVICE_COST                  AS COGSService,
    itx.TRANSACTION_ID                    AS InventoryTransID,     -- degenerate: link to the costing movement
    sl.UNIT_PRICE                         AS UnitPrice,            -- NON-additive (rate)
    sl.TRADE_DISC_PERCENT                 AS TradeDiscountPct,     -- NON-additive (rate)
    sl.COMMISSION_PCT                     AS CommissionPct         -- NON-additive (rate)
FROM dbo.SHIPPER_LINE AS sl
INNER JOIN dbo.SHIPPER AS hdr
    ON hdr.PACKLIST_ID = sl.PACKLIST_ID
INNER JOIN dbo.CUSTOMER_ORDER AS ord
    ON ord.ID = hdr.CUST_ORDER_ID
LEFT JOIN dbo.CUST_ORDER_LINE AS oln
    ON oln.CUST_ORDER_ID = sl.CUST_ORDER_ID
   AND oln.LINE_NO       = sl.CUST_ORDER_LINE_NO
-- VMSHPENT UDF-0000028 is defined on tblShpLineItem, so both the packlist and
-- shipper-line number are required. Current source data is unique at this key;
-- validation check B2a guards that assumption so this join cannot fan out.
LEFT JOIN dbo.USER_DEF_FIELDS AS trk
    ON trk.PROGRAM_ID  = N'VMSHPENT'
   AND trk.ID          = N'UDF-0000028'
   AND trk.DOCUMENT_ID = sl.PACKLIST_ID
   AND trk.LINE_NO     = sl.LINE_NO
LEFT JOIN dbo.SALES_REP AS rep
    ON rep.ID = hdr.SALESREP_ID
-- Existence probe for the effective ship-to (packlist override, else order),
-- PK (CUSTOMER_ID, ADDR_NO) so 1:1 — drives the ShipToKey fallback above.
LEFT JOIN dbo.CUST_ADDRESS AS sa
    ON sa.CUSTOMER_ID = ord.CUSTOMER_ID
   AND sa.ADDR_NO     = COALESCE(hdr.SHIP_TO_ADDR_NO, ord.SHIP_TO_ADDR_NO)
-- Actual COGS at ship time. SHIPPER_LINE.TRANSACTION_ID -> INVENTORY_TRANS
-- (integer PK) is 1:1, so this LEFT JOIN cannot fan out the packlist-line grain.
-- NULL for non-inventory lines (freight/service) that carry no TRANSACTION_ID.
LEFT JOIN dbo.INVENTORY_TRANS AS itx
    ON itx.TRANSACTION_ID = sl.TRANSACTION_ID;
GO
