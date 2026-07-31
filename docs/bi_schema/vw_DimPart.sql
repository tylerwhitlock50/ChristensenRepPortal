/*============================================================================
  Object : bi.vw_DimPart
  Source : VECA.dbo.PART                         (spine — global part attributes)
           LEFT JOIN VECA.dbo.PRODUCT            (product-code description)
           LEFT JOIN VECA.dbo.PART_SITE_VIEW     (site-level cost + planning)
           LEFT JOIN VECA.dbo.Z_PRODUCT_DETAIL   (FG spec attributes / UPC)
  Grain  : One row per PART.ID, plus one '(Unknown)' sentinel.
  Key    : PartKey = PART.ID (nvarchar(30)). Natural business key.
  Notes  : - Conformed dimension, reused by BOTH sales and purchasing models.
           - PART is the SPINE; every other source is LEFT-joined so no part is
             dropped. All three joins are 1:1 (verified: 21,002 PART rows =
             21,002 PART_SITE rows = 21,002 Z_PRODUCT_DETAIL rows, no dupes).

           - SINGLE-SITE FLATTEN (cost + planning from PART_SITE_VIEW):
             cost/price and the planning policy are PART_SITE (site-level) data.
             This shop runs ONE site and is not adding a second, so part x site
             is reliably 1:1 and these flatten safely as current-state part
             attributes. This is the SAME single-site shortcut already used for
             DimCustomer's customer-site + VFIN-credit flatten -- NOT a
             snowflake. PART_SITE_VIEW (not raw PART_SITE) is read so planning
             fields fall back to the PART-level default via its ISNULL pattern.
             If a 2nd site is ever added these fan out and must move to a
             part-site context or onto the fact; the A3 PartKey dedup check in
             99_validation/grain_checks.sql will flag the fan-out.

           - DELIBERATELY EXCLUDED: the volatile quantity balances
             (QTY_ON_HAND, QTY_AVAILABLE_ISS/MRP, QTY_ON_ORDER, QTY_IN_DEMAND,
             QTY_COMMITTED, ANNUAL_USAGE_QTY). Running balances are MEASURES,
             not descriptive attributes -- same call as keeping OPEN_RECV_AMOUNT
             off DimCustomer. If inventory position is needed, build a fact or a
             live part-site query; do not snapshot it onto the conformed dim.
             Standard costs ARE kept: they are relatively static reference
             values (cf. CREDIT_LIMIT_AMT on DimCustomer), not running balances.

           - Z_PRODUCT_DETAIL supplies finished-goods spec attributes (family,
             chambering, barrel length, twist, finish, handedness, action type,
             handguard, stock color/style, UPC). Values are free-form and use an
             'N/A' string on non-applicable parts -- left raw, not coerced.

           - Keep ALL parts regardless of STATUS -- never filter, or historical
             facts referencing inactive parts orphan.
           - Sentinel '(Unknown)' catches order/shipment lines with NULL
             PART_ID (note / service / non-stock lines).
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimPart
AS
SELECT
    p.ID                                  AS PartKey,
    p.ID                                  AS PartID,
    p.DESCRIPTION                         AS PartDescription,
    p.PRODUCT_CODE                        AS ProductCode,
    pr.DESCRIPTION                        AS ProductCodeDescription,
    p.COMMODITY_CODE                      AS CommodityCode,
    cm.DESCRIPTION                        AS CommodityCodeDescription,
    p.STOCK_UM                            AS StockUM,
    p.STATUS                              AS [Status],
    p.ABC_CODE                            AS ABCCode,
    p.FABRICATED                          AS FabricatedFlag,
    p.PURCHASED                           AS PurchasedFlag,
    p.STOCKED                             AS StockedFlag,
    p.DETAIL_ONLY                         AS DetailOnlyFlag,
    p.IS_KIT                              AS IsKitFlag,
    p.INSPECTION_REQD                     AS InspectionRequiredFlag,
    p.PLANNING_LEADTIME                   AS PlanningLeadTimeDays,
    p.PREF_VENDOR_ID                      AS PreferredVendorID,
    p.BUYER_USER_ID                       AS BuyerUserID,
    p.PLANNER_USER_ID                     AS PlannerUserID,
    p.WEIGHT                              AS [Weight],
    p.WEIGHT_UM                           AS WeightUM,
    p.DRAWING_ID                          AS DrawingID,
    p.REVISION_ID                         AS RevisionID,
    p.MFG_NAME                            AS ManufacturerName,
    p.MFG_PART_ID                         AS ManufacturerPartID,

    -- Product spec attributes (Z_PRODUCT_DETAIL, 1:1 on PART.ID)
    zpd.Family                            AS ProductFamily,
    zpd.chambering                        AS Chambering,
    zpd.Bar_Length                        AS BarrelLength,
    zpd.Twist                             AS Twist,
    zpd.finish                            AS Finish,
    zpd.handedness                        AS Handedness,
    zpd.action_type                       AS ActionType,
    zpd.handguard                         AS Handguard,
    zpd.stock_color                       AS StockColor,
    zpd.stock_style                       AS StockStyle,
    zpd.UPC                               AS UPC,

    -- Planning policy (PART_SITE_VIEW, site-effective via ISNULL fallback)
    psv.ORDER_POLICY                      AS OrderPolicy,
    psv.ORDER_POINT                       AS OrderPoint,
    psv.ORDER_UP_TO_QTY                   AS OrderUpToQty,
    psv.SAFETY_STOCK_QTY                  AS SafetyStockQty,
    psv.FIXED_ORDER_QTY                   AS FixedOrderQty,
    psv.MINIMUM_ORDER_QTY                 AS MinimumOrderQty,
    psv.MAXIMUM_ORDER_QTY                 AS MaximumOrderQty,
    psv.MULTIPLE_ORDER_QTY                AS MultipleOrderQty,
    psv.DAYS_OF_SUPPLY                    AS DaysOfSupply,
    psv.MINIMUM_LEADTIME                  AS MinimumLeadTimeDays,
    psv.MRP_REQUIRED                      AS MRPRequiredFlag,
    psv.PRIMARY_WHS_ID                    AS PrimaryWarehouseID,
    psv.PRIMARY_LOC_ID                    AS PrimaryLocationID,

    -- Standard costs / price (PART_SITE, site-level reference values)
    psv.UNIT_PRICE                        AS StandardUnitPrice,
    psv.WHSALE_UNIT_COST                  AS WholesaleUnitCost,
    psv.UNIT_MATERIAL_COST                AS UnitMaterialCost,
    psv.UNIT_LABOR_COST                   AS UnitLaborCost,
    psv.UNIT_BURDEN_COST                  AS UnitBurdenCost,
    psv.UNIT_SERVICE_COST                 AS UnitServiceCost,
    psv.FIXED_COST                        AS FixedCost,
    psv.BURDEN_PERCENT                    AS BurdenPercent,
    ( psv.UNIT_MATERIAL_COST
    + psv.UNIT_LABOR_COST
    + psv.UNIT_BURDEN_COST
    + psv.UNIT_SERVICE_COST )             AS StandardUnitCost,

    CAST(0 AS bit)                        AS IsUnknownPart
FROM dbo.PART AS p
LEFT JOIN dbo.PRODUCT AS pr
    ON pr.CODE = p.PRODUCT_CODE
LEFT JOIN dbo.COMMODITY AS cm
    ON cm.CODE = p.COMMODITY_CODE
LEFT JOIN dbo.PART_SITE_VIEW AS psv
    ON psv.PART_ID = p.ID
LEFT JOIN dbo.Z_PRODUCT_DETAIL AS zpd
    ON zpd.ID = p.ID

UNION ALL

SELECT
    N'(Unknown)'                 AS PartKey,
    N'(Unknown)'                 AS PartID,
    N'(No part / non-stock line)' AS PartDescription,
    NULL                         AS ProductCode,
    NULL                         AS ProductCodeDescription,
    NULL                         AS CommodityCode,
    NULL                         AS CommodityCodeDescription,
    NULL                         AS StockUM,
    NULL                         AS [Status],
    NULL                         AS ABCCode,
    NULL                         AS FabricatedFlag,
    NULL                         AS PurchasedFlag,
    NULL                         AS StockedFlag,
    NULL                         AS DetailOnlyFlag,
    NULL                         AS IsKitFlag,
    NULL                         AS InspectionRequiredFlag,
    NULL                         AS PlanningLeadTimeDays,
    NULL                         AS PreferredVendorID,
    NULL                         AS BuyerUserID,
    NULL                         AS PlannerUserID,
    NULL                         AS [Weight],
    NULL                         AS WeightUM,
    NULL                         AS DrawingID,
    NULL                         AS RevisionID,
    NULL                         AS ManufacturerName,
    NULL                         AS ManufacturerPartID,

    NULL                         AS ProductFamily,
    NULL                         AS Chambering,
    NULL                         AS BarrelLength,
    NULL                         AS Twist,
    NULL                         AS Finish,
    NULL                         AS Handedness,
    NULL                         AS ActionType,
    NULL                         AS Handguard,
    NULL                         AS StockColor,
    NULL                         AS StockStyle,
    NULL                         AS UPC,

    NULL                         AS OrderPolicy,
    NULL                         AS OrderPoint,
    NULL                         AS OrderUpToQty,
    NULL                         AS SafetyStockQty,
    NULL                         AS FixedOrderQty,
    NULL                         AS MinimumOrderQty,
    NULL                         AS MaximumOrderQty,
    NULL                         AS MultipleOrderQty,
    NULL                         AS DaysOfSupply,
    NULL                         AS MinimumLeadTimeDays,
    NULL                         AS MRPRequiredFlag,
    NULL                         AS PrimaryWarehouseID,
    NULL                         AS PrimaryLocationID,

    NULL                         AS StandardUnitPrice,
    NULL                         AS WholesaleUnitCost,
    NULL                         AS UnitMaterialCost,
    NULL                         AS UnitLaborCost,
    NULL                         AS UnitBurdenCost,
    NULL                         AS UnitServiceCost,
    NULL                         AS FixedCost,
    NULL                         AS BurdenPercent,
    NULL                         AS StandardUnitCost,

    CAST(1 AS bit)               AS IsUnknownPart;
GO
