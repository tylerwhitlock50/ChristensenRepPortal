/*============================================================================
  Object : bi.vw_FactInventoryLocation
  Source : VECA.dbo.PART_LOCATION  (part x warehouse x location — the grain)
           LEFT JOIN VECA.dbo.WAREHOUSE  (w: SITE_ID for the cost join + SiteKey)
           LEFT JOIN VECA.dbo.PART_SITE  (ps: standard unit cost for valuation)
  Grain  : ONE ROW PER (PART_ID, WAREHOUSE_ID, LOCATION_ID).
           The BIN-LEVEL inventory detail snapshot — "where is the stock and in
           what state." Complements vw_FactInventoryOnHand (part-site
           authoritative). Bin QTY can drift slightly from the authoritative
           PART_SITE.QTY_ON_HAND; for a number that ties to GL use
           FactInventoryOnHand, and use this view for by-warehouse /
           by-location / hold-status analysis.

  SNAPSHOT SEMANTICS: current-state (as-of-refresh). The only date role is
  LastCountDateKey (cycle-count recency), role-played to DimDate.

  COSTING: bins carry QTY but no cost. Value = bin QTY x the part-site standard
  unit cost (resolved via the warehouse's SITE_ID). Uniform cost across a part's
  bins, same basis as FactInventoryOnHand.

  Dimension keys: PartKey, SiteKey (from the warehouse), WarehouseKey. LocationID
  is a degenerate bin code (bins are low-attribute — no DimLocation).
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactInventoryLocation
AS
SELECT
    -- Degenerate / tags (identify the bin + its state)
    pl.LOCATION_ID                        AS LocationID,
    pl.[DESCRIPTION]                      AS LocationDescription,
    pl.[STATUS]                           AS LocationStatus,
    pl.HOLD_REASON_ID                     AS HoldReasonID,
    pl.LOCKED                             AS LockedFlag,
    pl.TRANSIT                            AS InTransitFlag,

    -- Dimension foreign keys
    COALESCE(NULLIF(pl.PART_ID, N''), N'(Unknown)')       AS PartKey,
    COALESCE(NULLIF(w.SITE_ID, N''), N'(Unknown)')        AS SiteKey,
    COALESCE(NULLIF(pl.WAREHOUSE_ID, N''), N'(Unknown)')  AS WarehouseKey,

    -- Role-played date key (integer yyyymmdd; sentinel 19000101 for NULLs)
    COALESCE(CAST(CONVERT(char(8), pl.LAST_COUNT_DATE, 112) AS int), 19000101) AS LastCountDateKey,

    -- Quantity balances (additive at this bin grain)
    pl.QTY                                AS OnHandQty,
    pl.COMMITTED_QTY                      AS CommittedQty,
    pl.PURGE_QTY                          AS PurgeQty,

    -- Value (additive) — bin qty x part-site standard cost, split by element.
    (pl.QTY * COALESCE(ps.UNIT_MATERIAL_COST,0)) AS OnHandValueMaterial,
    (pl.QTY * COALESCE(ps.UNIT_LABOR_COST,0))    AS OnHandValueLabor,
    (pl.QTY * COALESCE(ps.UNIT_BURDEN_COST,0))   AS OnHandValueBurden,
    (pl.QTY * COALESCE(ps.UNIT_SERVICE_COST,0))  AS OnHandValueService,
    (pl.QTY *
        ( COALESCE(ps.UNIT_MATERIAL_COST,0) + COALESCE(ps.UNIT_LABOR_COST,0)
        + COALESCE(ps.UNIT_BURDEN_COST,0)   + COALESCE(ps.UNIT_SERVICE_COST,0) )
    )                                     AS OnHandValue
FROM dbo.PART_LOCATION AS pl
LEFT JOIN dbo.WAREHOUSE AS w
    ON w.ID = pl.WAREHOUSE_ID
LEFT JOIN dbo.PART_SITE AS ps
    ON ps.PART_ID = pl.PART_ID
   AND ps.SITE_ID = w.SITE_ID;
GO
