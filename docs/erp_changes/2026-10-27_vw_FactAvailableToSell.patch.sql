/*============================================================================
  PATCH  : bi.vw_FactAvailableToSell — sellable stock = SHIPPING R01–R09 only
  For    : the owner of the bi.* views (Power BI project)
  From   : Tyler / Rep Portal, 2026-10-27. Read 2026-10-27_bi_view_changes.md
           (same folder) first; it has the reasons and the expected numbers.

  THIS IS NOT A COMPLETE VIEW. It is three find-and-replace edits, written
  against the Rep Portal's copy of the view (docs/bi_schema/
  vw_FactAvailableToSell.sql). That copy may be out of date: every bi view was
  redeployed on 2026-09-17 and the portal's SQL login has no VIEW DEFINITION,
  so we cannot see the live text. Apply the edits to the LIVE definition from
  your project. Do not paste a whole view from our repo over yours.

  The output column list (names, order, types) must stay EXACTLY the same.
  The portal loads this view every 15 minutes on weekdays; a new, renamed or
  retyped column makes that load fail.
============================================================================*/


/*----------------------------------------------------------------------------
  EDIT 1 of 3 — the ShippingOnHand CTE. Replace the whole CTE.

  FIND (three places in this CTE test N'R10%': the two SUM(CASE…) columns
  and the second HAVING term):

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

  REPLACE WITH:
----------------------------------------------------------------------------*/
WITH ShippingOnHand AS (
    -- Sellable stock = SHIPPING rack locations R01–R09 ONLY (business rule,
    -- 2026-10-26). Everything else in SHIPPING is reserved and never counts
    -- toward ATS: R10% (staging), R11% (components), INTERNATIONAL,
    -- STAGE / STAGE1 / STAGE2 / STAGE3, SHELF PREP, TOP SHELF, … The test is a
    -- positive LIKE rather than a list of exclusions, so a location added
    -- later is reserved until someone decides it is sellable.
    -- ExcludedStagingQty keeps its name (column-list compatibility) but now
    -- holds ALL SHIPPING qty outside R01–R09. The two CASEs are exact
    -- complements (a NULL LOCATION_ID falls to the excluded side), so
    -- ShippingOnHandBeforeExclusionsQty = ShippingOnHandQty + ExcludedStagingQty
    -- on every row.
    SELECT
        w.SITE_ID,
        pl.PART_ID,
        SUM(ISNULL(pl.QTY, 0)) AS ShippingOnHandBeforeExclusionsQty,
        SUM(CASE
                WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN ISNULL(pl.QTY, 0)
                ELSE 0
            END) AS ShippingOnHandQty,
        SUM(CASE
                WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN 0
                ELSE ISNULL(pl.QTY, 0)
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
                   WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN 0
                   ELSE ISNULL(pl.QTY, 0)
               END) <> 0
),


/*----------------------------------------------------------------------------
  EDIT 2 of 3 — the ExcludedLocationPattern constant in the final SELECT.
  nvarchar(15) is the live column type; the new value is 12 characters.

  FIND:
    CAST(N'R10%' AS nvarchar(15)) AS ExcludedLocationPattern,

  REPLACE WITH:
----------------------------------------------------------------------------*/
    -- Describes the rule: every SHIPPING location NOT LIKE 'R0[1-9]%' is
    -- excluded from sellable stock (its qty is in ExcludedStagingQty).
    CAST(N'NOT R0[1-9]%' AS nvarchar(15)) AS ExcludedLocationPattern,


/*----------------------------------------------------------------------------
  EDIT 3 of 3 — the header comment (no effect on the output; keeps the
  documentation true).

  FIND:
      AvailableToSellQty = SHIPPING QOH outside R10 staging
                         - open Released/Firmed customer-order qty
  REPLACE WITH:
      AvailableToSellQty = SHIPPING QOH in rack locations R01–R09
                         - open Released/Firmed customer-order qty

  FIND:
  - R10% locations are staging and excluded from sellable QOH; their qty is exposed.
  REPLACE WITH:
  - Only rack locations R01–R09 (LOCATION_ID LIKE 'R0[1-9]%') are sellable.
    R10 (staging), R11 (components), INTERNATIONAL, STAGE* and every other
    SHIPPING location are reserved; their qty is exposed as ExcludedStagingQty
    (the name predates the rule) and ExcludedLocationPattern = 'NOT R0[1-9]%'.
----------------------------------------------------------------------------*/
