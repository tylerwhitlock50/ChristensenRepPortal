/*============================================================================
  Object : bi.vw_FactInventoryOnHand
  Source : VECA.dbo.PART_SITE   (part x site — the grain and the authoritative
                                  on-hand + current standard cost)
  Grain  : ONE ROW PER (SITE_ID, PART_ID) = 21,051 rows (single site today).
           This is the AUTHORITATIVE current-inventory snapshot — PART_SITE.
           QTY_ON_HAND is the official on-hand that reconciles to the GL
           inventory control account. Bin-level detail lives in the separate
           vw_FactInventoryLocation (which can drift slightly from this).

  SNAPSHOT SEMANTICS: this is a CURRENT-STATE (as-of-refresh) fact — it has no
  transaction date and does NOT relate to DimDate. It answers "what do we hold
  right now, and what is it worth." For inventory OVER TIME (turns trend, as-of
  reconstruction) use the movement fact (INVENTORY_TRANS) — deferred by design.

  VALUATION: OnHandValue = QTY_ON_HAND x standard unit cost, where standard unit
  cost = UNIT_MATERIAL + UNIT_LABOR + UNIT_BURDEN + UNIT_SERVICE (the same basis
  as DimPart.StandardUnitCost). The four *Value columns split the on-hand value
  by cost element. Verified total ~ $21.6M. If this fails to reconcile to the GL
  inventory control account (possible under actual costing), switch OnHandValue
  to an actual weighted-average from INVENTORY_TRANS — see the validation check.

  The volatile quantity balances here (QTY_ON_HAND etc.) are DELIBERATELY the
  measures of this fact — the same balances that are deliberately kept OFF the
  conformed DimPart (where they would be wrong as attributes). This fact is the
  governed home for inventory position.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_FactInventoryOnHand
AS
SELECT
    -- Degenerate / tags
    ps.[STATUS]                           AS PartSiteStatus,
    ps.ABC_CODE                           AS ABCCode,

    -- Dimension foreign keys
    COALESCE(NULLIF(ps.PART_ID, N''), N'(Unknown)')   AS PartKey,
    COALESCE(NULLIF(ps.SITE_ID, N''), N'(Unknown)')   AS SiteKey,

    -- Quantity balances (additive at this part-site grain)
    ps.QTY_ON_HAND                        AS OnHandQty,
    ps.QTY_AVAILABLE_ISS                  AS QtyAvailableIssue,
    ps.QTY_AVAILABLE_MRP                  AS QtyAvailableMRP,
    ps.QTY_ON_ORDER                       AS QtyOnOrder,
    ps.QTY_IN_DEMAND                      AS QtyInDemand,
    ps.QTY_COMMITTED                      AS QtyCommitted,
    ps.ANNUAL_USAGE_QTY                   AS AnnualUsageQty,

    -- Standard unit costs (NON-additive rates; reference cost basis)
    ps.UNIT_MATERIAL_COST                 AS UnitMaterialCost,
    ps.UNIT_LABOR_COST                    AS UnitLaborCost,
    ps.UNIT_BURDEN_COST                   AS UnitBurdenCost,
    ps.UNIT_SERVICE_COST                  AS UnitServiceCost,
    ( COALESCE(ps.UNIT_MATERIAL_COST,0) + COALESCE(ps.UNIT_LABOR_COST,0)
    + COALESCE(ps.UNIT_BURDEN_COST,0)   + COALESCE(ps.UNIT_SERVICE_COST,0) ) AS StandardUnitCost,

    -- On-hand VALUE (additive) — on-hand qty x standard cost, split by element.
    (ps.QTY_ON_HAND * COALESCE(ps.UNIT_MATERIAL_COST,0)) AS OnHandValueMaterial,
    (ps.QTY_ON_HAND * COALESCE(ps.UNIT_LABOR_COST,0))    AS OnHandValueLabor,
    (ps.QTY_ON_HAND * COALESCE(ps.UNIT_BURDEN_COST,0))   AS OnHandValueBurden,
    (ps.QTY_ON_HAND * COALESCE(ps.UNIT_SERVICE_COST,0))  AS OnHandValueService,
    (ps.QTY_ON_HAND *
        ( COALESCE(ps.UNIT_MATERIAL_COST,0) + COALESCE(ps.UNIT_LABOR_COST,0)
        + COALESCE(ps.UNIT_BURDEN_COST,0)   + COALESCE(ps.UNIT_SERVICE_COST,0) )
    )                                     AS OnHandValue
FROM dbo.PART_SITE AS ps;
GO
