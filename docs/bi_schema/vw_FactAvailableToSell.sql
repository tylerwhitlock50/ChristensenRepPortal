/*============================================================================
  Object : bi.vw_FactAvailableToSell
  Source : VECA.dbo.PART_LOCATION       (physical SHIPPING stock)
           JOIN VECA.dbo.WAREHOUSE      (site for the warehouse stock)
           VECA.dbo.CUST_ORDER_LINE     (open customer demand)
           JOIN VECA.dbo.CUSTOMER_ORDER (open-order status + customer/site)
           LEFT JOIN VECA.dbo.SITE / CUSTOMER_ENTITY (credit diagnostics)
           LEFT JOIN agg(VECA.dbo.DEMAND_SUPPLY_LINK) (explicit CO -> WO peg)
  Grain  : ONE ROW PER (PART_ID, SITE_ID) that has non-zero SHIPPING stock or
           open Released/Firmed customer-order demand. This is narrower than the
           Tableau/SQL Toolbox spine (all PART_SITE_VIEW A/O parts); zero/zero
           part-sites are omitted because they add no inventory signal.

  PURPOSE
  -------
  Current-state Available To Sell (ATS) list for the Inventory semantic model.
  Headline math matches the canonical Toolbox query
  domains/sales/ats_finished_goods.sql. ATS is deliberately conservative:

      AvailableToSellQty = SHIPPING QOH outside R10 staging
                         - open Released/Firmed customer-order qty

  OPEN DEMAND / DOUBLE-PROMISE RULE
  ---------------------------------
  Every open order line is subtracted exactly once. CUST_ORDER_LINE.ALLOCATED_QTY
  and DEMAND_SUPPLY_LINK.ALLOCATED_QTY describe allocation/coverage of that same
  demand; they are exposed for audit only and are NOT additional demand. Subtracting
  either one again would double-count promised product. Explicitly WO-linked demand
  remains part of OpenOrderQty: once its WO output reaches SHIPPING QOH, the still-open
  order must continue to reserve it until shipment closes the demand.

  CUSTOMER CREDIT RULE
  --------------------
  Credit status does not remove demand from ATS. Released/Firmed lines for customers
  on credit restriction are still promises and remain in OpenOrderQty. The approved
  vs restricted split is exposed so consumers can audit the effect. Credit comes
  from VECA.dbo.CUSTOMER_ENTITY (single-letter codes: A/H/O/S), joined through
  SITE.ENTITY_ID because its key is (ENTITY_ID, CUSTOMER_ID). Do not swap in
  VFIN.dbo.RECEIVABLES_CUSTOMER_ENTITY here — that table uses full words
  (APPROVED/HOLD/...) and would silently break the A-vs-not-A split. DimCustomer
  credit attributes remain the VFIN enrichment for the sales model.

  OTHER CAVEATS
  -------------
  - SHIPPING is the governed shippable warehouse for this list. WarehouseID is a
    degenerate constant (ShippableWarehouseID), not a DimWarehouse relationship —
    grain is part × site, same as FactInventoryOnHand.
  - R10% locations are staging and excluded from sellable QOH; their qty is exposed.
  - Held order headers (STATUS='H') are not included, matching the canonical SQL
    Toolbox ATS definition. Sales FactOrderLine.Backlog* still includes Hold —
    that is sales backlog, not ATS reservation. Revisit held demand only as an
    explicit policy choice.
  - Open POs and unreceived WOs are future supply and are not added to ATS.
  - Finished-goods / current-pricelist filters stay in reports or the sales
    pricing facts — not in this inventory snapshot.
  - Signed AvailableToSellQty is intentional; negative values identify oversold SKUs.
  - Snapshot semantics: current state as of the Power BI refresh; no DimDate role.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactAvailableToSell
AS
WITH ShippingOnHand AS (
    SELECT
        w.SITE_ID,
        pl.PART_ID,
        SUM(ISNULL(pl.QTY, 0)) AS ShippingOnHandBeforeExclusionsQty,
        SUM(CASE
                WHEN pl.LOCATION_ID LIKE N'R10%' THEN 0
                ELSE ISNULL(pl.QTY, 0)
            END) AS ShippingOnHandQty,
        SUM(CASE
                WHEN pl.LOCATION_ID LIKE N'R10%' THEN ISNULL(pl.QTY, 0)
                ELSE 0
            END) AS ExcludedStagingQty
    FROM dbo.PART_LOCATION AS pl
    INNER JOIN dbo.WAREHOUSE AS w
        ON w.ID = pl.WAREHOUSE_ID
    WHERE pl.WAREHOUSE_ID = N'SHIPPING'
    GROUP BY
        w.SITE_ID,
        pl.PART_ID
    HAVING SUM(ISNULL(pl.QTY, 0)) <> 0
        OR SUM(CASE
                   WHEN pl.LOCATION_ID LIKE N'R10%' THEN ISNULL(pl.QTY, 0)
                   ELSE 0
               END) <> 0
),
DemandSupplyLinkByLine AS (
    -- Pre-aggregate to the order-line grain before joining. A handful of lines
    -- have multiple linked WOs; joining raw link rows would multiply demand.
    SELECT
        dsl.DEMAND_SITE_ID,
        dsl.DEMAND_BASE_ID,
        dsl.DEMAND_SEQ_NO,
        COUNT_BIG(*) AS LinkedSupplyCount,
        SUM(ISNULL(dsl.ALLOCATED_QTY, 0)) AS LinkedSupplyAllocatedQty,
        SUM(ISNULL(dsl.ISSUED_QTY, 0)) AS LinkedSupplyIssuedQty
    FROM dbo.DEMAND_SUPPLY_LINK AS dsl
    WHERE dsl.DEMAND_TYPE = N'CO'
      AND dsl.SUPPLY_TYPE = N'WO'
    GROUP BY
        dsl.DEMAND_SITE_ID,
        dsl.DEMAND_BASE_ID,
        dsl.DEMAND_SEQ_NO
),
OpenOrderLineBase AS (
    SELECT
        col.SITE_ID,
        col.CUST_ORDER_ID,
        col.LINE_NO,
        col.PART_ID,
        col.ORDER_QTY - ISNULL(col.TOTAL_SHIPPED_QTY, 0) AS OpenOrderQty,
        ISNULL(col.ALLOCATED_QTY, 0) AS RawLineAllocatedQty,
        ce.CREDIT_STATUS AS CustomerCreditStatus,
        ISNULL(dsl.LinkedSupplyCount, 0) AS LinkedSupplyCount,
        ISNULL(dsl.LinkedSupplyAllocatedQty, 0) AS RawLinkedSupplyAllocatedQty,
        ISNULL(dsl.LinkedSupplyIssuedQty, 0) AS RawLinkedSupplyIssuedQty
    FROM dbo.CUST_ORDER_LINE AS col
    INNER JOIN dbo.CUSTOMER_ORDER AS co
        ON co.ID = col.CUST_ORDER_ID
    LEFT JOIN dbo.SITE AS s
        ON s.ID = co.SITE_ID
    LEFT JOIN dbo.CUSTOMER_ENTITY AS ce
        ON ce.ENTITY_ID = s.ENTITY_ID
       AND ce.CUSTOMER_ID = co.CUSTOMER_ID
    LEFT JOIN DemandSupplyLinkByLine AS dsl
        ON dsl.DEMAND_SITE_ID = col.SITE_ID
       AND dsl.DEMAND_BASE_ID = col.CUST_ORDER_ID
       AND dsl.DEMAND_SEQ_NO = col.LINE_NO
    WHERE co.STATUS IN (N'R', N'F')
      AND col.LINE_STATUS = N'A'
      AND NULLIF(LTRIM(RTRIM(col.PART_ID)), N'') IS NOT NULL
      AND col.ORDER_QTY - ISNULL(col.TOTAL_SHIPPED_QTY, 0) > 0
),
OpenOrderLine AS (
    SELECT
        SITE_ID,
        CUST_ORDER_ID,
        LINE_NO,
        PART_ID,
        OpenOrderQty,
        -- Cap allocation diagnostics at the still-open demand on the line. This
        -- prevents stale/over-allocation from inflating the audit splits.
        CASE
            WHEN RawLineAllocatedQty <= 0 THEN 0
            WHEN RawLineAllocatedQty >= OpenOrderQty THEN OpenOrderQty
            ELSE RawLineAllocatedQty
        END AS AllocatedOpenOrderQty,
        CustomerCreditStatus,
        LinkedSupplyCount,
        CASE
            WHEN RawLinkedSupplyAllocatedQty <= 0 THEN 0
            WHEN RawLinkedSupplyAllocatedQty >= OpenOrderQty THEN OpenOrderQty
            ELSE RawLinkedSupplyAllocatedQty
        END AS LinkedSupplyAllocatedQty,
        CASE
            WHEN RawLinkedSupplyAllocatedQty - RawLinkedSupplyIssuedQty <= 0 THEN 0
            WHEN RawLinkedSupplyAllocatedQty - RawLinkedSupplyIssuedQty >= OpenOrderQty
                THEN OpenOrderQty
            ELSE RawLinkedSupplyAllocatedQty - RawLinkedSupplyIssuedQty
        END AS LinkedSupplyRemainingQty
    FROM OpenOrderLineBase
),
OpenDemand AS (
    SELECT
        SITE_ID,
        PART_ID,
        SUM(OpenOrderQty) AS OpenOrderQty,
        SUM(AllocatedOpenOrderQty) AS AllocatedOpenOrderQty,
        SUM(CASE WHEN CustomerCreditStatus = N'A' THEN OpenOrderQty ELSE 0 END)
            AS CreditApprovedOpenOrderQty,
        SUM(CASE WHEN CustomerCreditStatus = N'A' THEN 0 ELSE OpenOrderQty END)
            AS CreditRestrictedOpenOrderQty,
        SUM(CASE WHEN LinkedSupplyCount > 0 THEN OpenOrderQty ELSE 0 END)
            AS DemandWithLinkedSupplyQty,
        SUM(CASE WHEN LinkedSupplyCount > 0 THEN 0 ELSE OpenOrderQty END)
            AS DemandWithoutLinkedSupplyQty,
        SUM(LinkedSupplyAllocatedQty) AS LinkedSupplyAllocatedQty,
        SUM(LinkedSupplyRemainingQty) AS LinkedSupplyRemainingQty,
        COUNT_BIG(*) AS OpenOrderLineCount,
        SUM(CASE
                WHEN LinkedSupplyCount > 0 THEN CAST(1 AS bigint)
                ELSE CAST(0 AS bigint)
            END) AS LinkedSupplyLineCount,
        MAX(LinkedSupplyCount) AS MaxLinkedSupplyCount
    FROM OpenOrderLine
    GROUP BY
        SITE_ID,
        PART_ID
),
PartSite AS (
    -- UNION supplies the useful ATS population without a FULL OUTER JOIN and
    -- guarantees a single key row before the two aggregates are joined.
    SELECT SITE_ID, PART_ID FROM ShippingOnHand
    UNION
    SELECT SITE_ID, PART_ID FROM OpenDemand
)
SELECT
    -- Dimension foreign keys
    COALESCE(NULLIF(ps.PART_ID, N''), N'(Unknown)') AS PartKey,
    COALESCE(NULLIF(ps.SITE_ID, N''), N'(Unknown)') AS SiteKey,

    -- Governed ATS scope (degenerate context; constant across the snapshot)
    CAST(N'SHIPPING' AS nvarchar(15)) AS ShippableWarehouseID,
    CAST(N'R10%' AS nvarchar(15)) AS ExcludedLocationPattern,

    -- Physical stock in SHIPPING
    CAST(ISNULL(q.ShippingOnHandBeforeExclusionsQty, 0) AS decimal(38,8))
        AS ShippingOnHandBeforeExclusionsQty,
    CAST(ISNULL(q.ExcludedStagingQty, 0) AS decimal(38,8)) AS ExcludedStagingQty,
    CAST(ISNULL(q.ShippingOnHandQty, 0) AS decimal(38,8)) AS ShippingOnHandQty,

    -- Open-order demand. The paired columns partition OpenOrderQty.
    CAST(ISNULL(d.OpenOrderQty, 0) AS decimal(38,8)) AS OpenOrderQty,
    CAST(ISNULL(d.AllocatedOpenOrderQty, 0) AS decimal(38,8)) AS AllocatedOpenOrderQty,
    CAST(ISNULL(d.OpenOrderQty, 0) - ISNULL(d.AllocatedOpenOrderQty, 0) AS decimal(38,8))
        AS UnallocatedOpenOrderQty,
    CAST(ISNULL(d.CreditApprovedOpenOrderQty, 0) AS decimal(38,8))
        AS CreditApprovedOpenOrderQty,
    CAST(ISNULL(d.CreditRestrictedOpenOrderQty, 0) AS decimal(38,8))
        AS CreditRestrictedOpenOrderQty,

    -- Explicit CO -> WO supply-link diagnostics. DemandWith/Without partitions
    -- OpenOrderQty; the two LinkedSupply* measures are subsets, never extra demand.
    CAST(ISNULL(d.DemandWithLinkedSupplyQty, 0) AS decimal(38,8))
        AS DemandWithLinkedSupplyQty,
    CAST(ISNULL(d.DemandWithoutLinkedSupplyQty, 0) AS decimal(38,8))
        AS DemandWithoutLinkedSupplyQty,
    CAST(ISNULL(d.LinkedSupplyAllocatedQty, 0) AS decimal(38,8))
        AS LinkedSupplyAllocatedQty,
    CAST(ISNULL(d.LinkedSupplyRemainingQty, 0) AS decimal(38,8))
        AS LinkedSupplyRemainingQty,
    ISNULL(d.OpenOrderLineCount, 0) AS OpenOrderLineCount,
    ISNULL(d.LinkedSupplyLineCount, 0) AS LinkedSupplyLineCount,
    ISNULL(d.MaxLinkedSupplyCount, 0) AS MaxLinkedSupplyCount,

    -- Headline measures / tags. Keep the signed number for oversold visibility.
    CAST(ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) AS decimal(38,8))
        AS AvailableToSellQty,
    CAST(CASE
        WHEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) > 0
            THEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0)
        ELSE 0
    END AS decimal(38,8)) AS AvailableToSellPositiveQty,
    CAST(CASE
        WHEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) >= 1 THEN 1
        ELSE 0
    END AS bit) AS IsAvailableToSell,
    CAST(CASE
        WHEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) < 0 THEN 1
        ELSE 0
    END AS bit) AS IsOversold,
    CASE
        WHEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) >= 1
            THEN N'Available'
        WHEN ISNULL(q.ShippingOnHandQty, 0) - ISNULL(d.OpenOrderQty, 0) < 0
            THEN N'Oversold'
        ELSE N'No surplus'
    END AS AvailabilityStatus
FROM PartSite AS ps
LEFT JOIN ShippingOnHand AS q
    ON q.SITE_ID = ps.SITE_ID
   AND q.PART_ID = ps.PART_ID
LEFT JOIN OpenDemand AS d
    ON d.SITE_ID = ps.SITE_ID
   AND d.PART_ID = ps.PART_ID;
GO
