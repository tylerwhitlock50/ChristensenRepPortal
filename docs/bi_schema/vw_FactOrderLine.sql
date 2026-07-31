/*============================================================================
  Object : bi.vw_FactOrderLine
  Source : VECA.dbo.CUST_ORDER_LINE  (line)
           JOIN  VECA.dbo.CUSTOMER_ORDER (hdr) for header attributes/dates
           LEFT JOIN VECA.dbo.SALES_REP (rep existence check for SalesRepKey)
           LEFT JOIN VECA.dbo.CUST_ADDRESS (ship-to existence probe)
           LEFT JOIN agg(VECA.dbo.DEMAND_SUPPLY_LINK) (primary linked work order)
  Grain  : ONE ROW PER SALES ORDER LINE  = (CUST_ORDER_ID, LINE_NO).
           This is the booking/demand fact (what was ordered), NOT what
           shipped — shipments live in vw_FactShipmentLine at packlist-line
           grain. The two facts are analyzed together via shared dimensions,
           never joined fact-to-fact.

  Dimension keys (all coalesced to a sentinel so rows never silently drop):
    CustomerKey   -> DimCustomer  (header CUSTOMER_ID)
    ShipToKey     -> DimShipTo    (CUSTOMER_ID + '|' + header SHIP_TO_ADDR_NO;
                                   CUSTOMER_ID + '|CUST' fallback when no ship-to)
    SalesRepKey   -> DimSalesRep  (header SALESREP_ID; '(Unknown)' if no match)
    PartKey       -> DimPart      (line PART_ID; '(Unknown)' if NULL/non-stock)
    SiteKey       -> DimSite      (line SITE_ID)
    OrderDateKey, DesiredShipDateKey, PromiseDateKey, LastShippedDateKey
                  -> DimDate (role-played; mark LastShippedDateKey as a date role too)

  Pipeline tagging on the line: ServiceChargeID/IsServiceLine (service vs part),
  HasLinkedWorkOrder/LinkedWorkOrderID/LinkedWorkOrderCount (primary pegged WO),
  BacklogQty/BacklogAmount/IsBacklogLine (still-owed demand — see rule below).

  NO STATUS FILTER. Every row is returned; LineStatus and OrderStatus are
  exposed as columns so report authors filter VISIBLY. This is the deliberate
  fix for the old "filter hidden in the SQL" problem — do not add a WHERE on
  STATUS / LINE_STATUS / ACTIVE here.

  Date precedence: line-level DESIRED_SHIP_DATE / PROMISE_DATE override the
  header; NULL dates collapse to the 19000101 DimDate sentinel.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactOrderLine
AS
SELECT
    -- Degenerate dimensions (identify the line; live on the fact)
    line.CUST_ORDER_ID                    AS OrderID,
    line.LINE_NO                          AS LineNum,
    hdr.CUSTOMER_PO_REF                   AS CustomerPONumber,
    line.LINE_STATUS                      AS LineStatus,
    hdr.STATUS                            AS OrderStatus,
    hdr.ORDER_TYPE                        AS OrderType,
    -- Decoded status labels (universal Infor codes) + a single lifecycle bucket
    -- so reports tag the pipeline without DAX. Raw codes kept above.
    CASE hdr.STATUS
        WHEN 'R' THEN 'Released' WHEN 'F' THEN 'Firmed' WHEN 'H' THEN 'Hold'
        WHEN 'C' THEN 'Closed'   WHEN 'X' THEN 'Canceled' ELSE hdr.STATUS
    END                                   AS OrderStatusDesc,
    CASE line.LINE_STATUS
        WHEN 'A' THEN 'Active' WHEN 'C' THEN 'Closed' WHEN 'X' THEN 'Canceled'
        ELSE line.LINE_STATUS
    END                                   AS LineStatusDesc,
    CASE
        WHEN hdr.STATUS = 'X' OR line.LINE_STATUS = 'X' THEN 'Canceled'
        WHEN hdr.STATUS = 'H'                           THEN 'Held'
        WHEN hdr.STATUS = 'C' OR line.LINE_STATUS = 'C' THEN 'Closed'
        ELSE 'Open'
    END                                   AS OrderState,
    line.BACKORDER_FLAG                   AS BackorderFlag,
    line.CUSTOMER_PART_ID                 AS CustomerPartID,
    line.PRODUCT_CODE                     AS ProductCode,
    line.SELLING_UM                       AS SellingUM,
    line.WAREHOUSE_ID                     AS WarehouseID,
    hdr.CURRENCY_ID                       AS CurrencyID,
    -- Service: a non-null SERVICE_CHARGE_ID marks the line as a sold service
    -- (e.g. gunsmithing / Cerakote) rather than a stocked part.
    line.SERVICE_CHARGE_ID                AS ServiceChargeID,
    CASE WHEN line.SERVICE_CHARGE_ID IS NOT NULL THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS IsServiceLine,
    -- Linked work order (DEMAND_SUPPLY_LINK peg, CO demand -> WO supply). The
    -- peg is effectively 1:1 (only a handful of lines peg to >1 WO), so the
    -- PRIMARY work order is flattened here as a degenerate lookup — NOT a
    -- fact-to-fact relationship or a bridge. LinkedWorkOrderCount surfaces the
    -- rare multi-WO lines. If WO ATTRIBUTES (status/dates) are ever needed for
    -- slicing, promote to a real DimWorkOrder instead of extending this.
    CASE WHEN dsl.primary_wo IS NOT NULL THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS HasLinkedWorkOrder,
    dsl.primary_wo                        AS LinkedWorkOrderID,
    COALESCE(dsl.wo_count, 0)             AS LinkedWorkOrderCount,

    -- Dimension foreign keys
    COALESCE(NULLIF(hdr.CUSTOMER_ID, N''), N'(Unknown)')                       AS CustomerKey,
    -- Resolve to the real ship-to ONLY when that CUST_ADDRESS row exists
    -- (sa.ADDR_NO not null); otherwise fall back to the customer-master ship-to
    -- ('|CUST'). This covers BOTH no ship-to addr AND a stale addr ref pointing
    -- at a missing CUST_ADDRESS row, so the key never orphans. '(Unknown)' only
    -- when there is no customer at all.
    CASE
        WHEN hdr.CUSTOMER_ID IS NULL THEN N'(Unknown)'
        WHEN sa.ADDR_NO IS NULL      THEN hdr.CUSTOMER_ID + N'|CUST'
        ELSE hdr.CUSTOMER_ID + N'|' + CAST(sa.ADDR_NO AS nvarchar(20))
    END                                                                       AS ShipToKey,
    COALESCE(rep.ID, N'(Unknown)')                                            AS SalesRepKey,
    COALESCE(NULLIF(line.PART_ID, N''), N'(Unknown)')                         AS PartKey,
    COALESCE(NULLIF(line.SITE_ID, N''), N'(Unknown)')                         AS SiteKey,

    -- Role-played date keys (integer yyyymmdd; sentinel 19000101 for NULLs)
    COALESCE(CAST(CONVERT(char(8), hdr.ORDER_DATE, 112) AS int), 19000101)    AS OrderDateKey,
    COALESCE(CAST(CONVERT(char(8),
        COALESCE(line.DESIRED_SHIP_DATE, hdr.DESIRED_SHIP_DATE), 112) AS int), 19000101) AS DesiredShipDateKey,
    COALESCE(CAST(CONVERT(char(8),
        COALESCE(line.PROMISE_DATE, hdr.PROMISE_DATE), 112) AS int), 19000101)           AS PromiseDateKey,
    COALESCE(CAST(CONVERT(char(8), line.LAST_SHIPPED_DATE, 112) AS int), 19000101)       AS LastShippedDateKey,

    -- Measures (additive at this grain unless noted)
    line.ORDER_QTY                        AS OrderQty,            -- stocking UM
    line.USER_ORDER_QTY                   AS OrderQtySellingUM,   -- selling UM
    line.TOTAL_AMT_ORDERED                AS Bookings,             -- booked order value ($) — the ORDER-side headline measure
    line.TOTAL_SHIPPED_QTY                AS TotalShippedQtyToDate,   -- cumulative on the line (semi-additive)
    line.TOTAL_AMT_SHIPPED                AS TotalAmountShippedToDate,-- cumulative on the line (semi-additive)
    line.ALLOCATED_QTY                    AS AllocatedQty,
    line.FULFILLED_QTY                    AS FulfilledQty,
    -- Backlog = still-owed demand. Rule: line is Active, the order is NOT
    -- closed/canceled (so Released/Firmed/Hold all count), and there is unshipped
    -- qty. To tighten to Released/Firmed only, swap NOT IN ('C','X') for
    -- IN ('R','F'). Both qty and $ are 0 (not negative) when not in backlog.
    CASE WHEN line.LINE_STATUS = 'A' AND hdr.STATUS NOT IN ('C','X')
              AND (line.ORDER_QTY - line.TOTAL_SHIPPED_QTY) > 0
         THEN line.ORDER_QTY - line.TOTAL_SHIPPED_QTY ELSE 0 END        AS BacklogQty,
    CASE WHEN line.LINE_STATUS = 'A' AND hdr.STATUS NOT IN ('C','X')
              AND (line.ORDER_QTY - line.TOTAL_SHIPPED_QTY) > 0
         THEN line.TOTAL_AMT_ORDERED - line.TOTAL_AMT_SHIPPED ELSE 0 END AS BacklogAmount,
    CASE WHEN line.LINE_STATUS = 'A' AND hdr.STATUS NOT IN ('C','X')
              AND (line.ORDER_QTY - line.TOTAL_SHIPPED_QTY) > 0
         THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END                    AS IsBacklogLine,
    line.UNIT_PRICE                       AS UnitPrice,           -- NON-additive (rate)
    line.TRADE_DISC_PERCENT               AS TradeDiscountPct     -- NON-additive (rate)
FROM dbo.CUST_ORDER_LINE AS line
INNER JOIN dbo.CUSTOMER_ORDER AS hdr
    ON hdr.ID = line.CUST_ORDER_ID
LEFT JOIN dbo.SALES_REP AS rep
    ON rep.ID = hdr.SALESREP_ID
-- Existence probe for the order's ship-to address (PK (CUSTOMER_ID, ADDR_NO),
-- so 1:1 — no fan-out). Drives the ShipToKey fallback above.
LEFT JOIN dbo.CUST_ADDRESS AS sa
    ON sa.CUSTOMER_ID = hdr.CUSTOMER_ID
   AND sa.ADDR_NO     = hdr.SHIP_TO_ADDR_NO
-- Linked work orders pre-aggregated to ONE row per order line (CO demand peg),
-- so the fact grain can't fan out. primary_wo = deterministic single WO id;
-- wo_count exposes the rare lines pegged to more than one.
LEFT JOIN (
    SELECT DEMAND_BASE_ID, DEMAND_SEQ_NO,
           MIN(SUPPLY_BASE_ID) AS primary_wo,
           COUNT(*)            AS wo_count
    FROM dbo.DEMAND_SUPPLY_LINK
    WHERE DEMAND_TYPE = 'CO' AND SUPPLY_TYPE = 'WO'
    GROUP BY DEMAND_BASE_ID, DEMAND_SEQ_NO
) AS dsl
    ON dsl.DEMAND_BASE_ID = line.CUST_ORDER_ID
   AND dsl.DEMAND_SEQ_NO  = line.LINE_NO;
GO
