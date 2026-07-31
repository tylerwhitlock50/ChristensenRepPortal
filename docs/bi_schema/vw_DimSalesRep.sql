/*============================================================================
  Object : bi.vw_DimSalesRep
  Source : VECA.dbo.SALES_REP                       (spine — transacting rep)
           LEFT JOIN VFIN.dbo.SHARED_SALES_REP        (email, territory, contact)
           LEFT JOIN VFIN.dbo.SHARED_SALES_REP_ENTITY (commission structure / GL)
  Grain  : One row per SALES_REP.ID, plus one '(Unknown)' sentinel.
  Key    : SalesRepKey = SALES_REP.ID (nvarchar(15)).
  Notes  : - This is the TRANSACTING rep (CUSTOMER_ORDER.SALESREP_ID /
             SHIPPER.SALESREP_ID), which drives commissions. Distinct from the
             customer's ASSIGNED rep (flattened onto DimCustomer).
           - VECA SALES_REP is a thin table (ID, NAME, VENDOR_ID, EMPLOYEE_ID,
             PAY_METHOD, DEF_COMMISSION_PCT, EARNING_CODE_ID). The richer rep
             attributes live in VFIN's SHARED_SALES_REP[_ENTITY] (same instance,
             same logical Visual ID). SALES_REP stays the SPINE so every rep that
             can appear on a VECA fact is present; the VFIN tables LEFT-join to
             enrich. Requires SELECT on VFIN.dbo for the BI service account.
           - TERRITORY: not on VECA SALES_REP; it comes from SHARED_SALES_REP
             (TERRITORY_ID). (Supersedes the old "no territory" note.)
           - SHARED_SALES_REP_ENTITY join key is SALESREP_ID (NOT ID), and the
             table is rep x entity grain. SINGLE accounting entity here, so the
             LEFT JOIN is 1:1 and does not fan out (same shortcut as the VFIN
             credit join on DimCustomer). A second entity would fan out and must
             move to a filtered/primary-entity join or a bridge — the A6 dedup
             check in 99_validation flags the regression.
           - Duplicated-concept columns are named distinctly to avoid collision:
             VECA EmployeeID / VendorID / DefaultCommissionPct vs the VFIN-entity
             EntityEmployeeID / EntitySupplierID / EntityCommissionPct.
           - PctPaidAt* (order / shipment / collect) are the commission-timing
             splits: what share of commission is earned at each lifecycle stage.
           - Orders may carry placeholder codes ('WEB', 'HOUSE') with no matching
             SALES_REP row; the fact COALESCEs those to the '(Unknown)' sentinel.
             IsPlaceholderRep flags the known placeholders for easy exclusion.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimSalesRep
AS
SELECT
    sr.ID                                 AS SalesRepKey,
    sr.ID                                 AS SalesRepID,
    sr.NAME                               AS SalesRepName,
    -- VECA SALES_REP (spine)
    sr.EMPLOYEE_ID                        AS EmployeeID,
    sr.VENDOR_ID                          AS VendorID,
    sr.PAY_METHOD                         AS PayMethod,
    sr.DEF_COMMISSION_PCT                 AS DefaultCommissionPct,
    sr.EARNING_CODE_ID                    AS EarningCodeID,
    -- SHARED_SALES_REP (VFIN): contact + territory
    ssr.EMAIL                             AS SalesRepEmail,
    ssr.PHONE                             AS SalesRepPhone,
    ssr.TERRITORY_ID                      AS TerritoryID,
    -- SHARED_SALES_REP_ENTITY (VFIN): commission structure + GL (single-entity 1:1)
    ssre.SALESREP_TYPE                    AS SalesRepType,
    ssre.COMMISSION_PCT                   AS EntityCommissionPct,
    ssre.PCT_PMT_AT_ORDER                 AS PctPaidAtOrder,
    ssre.PCT_PMT_AT_SHIPMT                AS PctPaidAtShipment,
    ssre.PCT_PMT_AT_COLLECT               AS PctPaidAtCollect,
    ssre.EMPLOYEE_ID                      AS EntityEmployeeID,
    ssre.SUPPLIER_ID                      AS EntitySupplierID,
    ssre.COMM_ACC_ACCT_ID                 AS CommissionAccrualAccountID,
    ssre.COMM_EXP_ACCT_ID                 AS CommissionExpenseAccountID,
    -- Flags
    CAST(CASE WHEN sr.ID IN (N'WEB', N'HOUSE') THEN 1 ELSE 0 END AS bit) AS IsPlaceholderRep,
    CAST(0 AS bit)                        AS IsUnknownSalesRep
FROM dbo.SALES_REP AS sr
LEFT JOIN VFIN.dbo.SHARED_SALES_REP AS ssr
    ON ssr.ID = sr.ID
LEFT JOIN VFIN.dbo.SHARED_SALES_REP_ENTITY AS ssre
    ON ssre.SALESREP_ID = sr.ID

UNION ALL

SELECT
    N'(Unknown)'   AS SalesRepKey,
    N'(Unknown)'   AS SalesRepID,
    N'(Unknown)'   AS SalesRepName,
    NULL           AS EmployeeID,
    NULL           AS VendorID,
    NULL           AS PayMethod,
    NULL           AS DefaultCommissionPct,
    NULL           AS EarningCodeID,
    NULL           AS SalesRepEmail,
    NULL           AS SalesRepPhone,
    NULL           AS TerritoryID,
    NULL           AS SalesRepType,
    NULL           AS EntityCommissionPct,
    NULL           AS PctPaidAtOrder,
    NULL           AS PctPaidAtShipment,
    NULL           AS PctPaidAtCollect,
    NULL           AS EntityEmployeeID,
    NULL           AS EntitySupplierID,
    NULL           AS CommissionAccrualAccountID,
    NULL           AS CommissionExpenseAccountID,
    CAST(0 AS bit) AS IsPlaceholderRep,
    CAST(1 AS bit) AS IsUnknownSalesRep;
GO
