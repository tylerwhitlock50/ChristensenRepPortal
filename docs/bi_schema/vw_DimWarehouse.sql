/*============================================================================
  Object : bi.vw_DimWarehouse
  Source : VECA.dbo.WAREHOUSE
  Grain  : One row per WAREHOUSE.ID (13 today), plus one '(Unknown)' sentinel.
  Key    : WarehouseKey = WAREHOUSE.ID (nvarchar). Natural business key; the
           bin-level inventory fact carries it.
  Notes  : - Inventory-model dimension. Visual runs multiple WAREHOUSES within
             the single SITE (verified 13 warehouses, all with a populated
             SITE_ID). Warehouse is its OWN dimension, distinct from DimSite.
           - Consignment: CUSTOMER_ID / VENDOR_ID identify the owning party for
             a consigned warehouse (CONSIGNED_TYPE); carried as attributes.
           - Keep ALL warehouses; never filter. Sentinel '(Unknown)' catches any
             bin row whose WAREHOUSE_ID is NULL/blank.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimWarehouse
AS
SELECT
    w.ID                                  AS WarehouseKey,
    w.ID                                  AS WarehouseID,
    w.NAME                                AS WarehouseName,
    w.DESCRIPTION                         AS [Description],
    w.SITE_ID                             AS SiteID,
    w.REGION_ID                           AS RegionID,
    w.ADDR_1                              AS Address1,
    w.ADDR_2                              AS Address2,
    w.ADDR_3                              AS Address3,
    w.CITY                                AS City,
    w.STATE                               AS [State],
    w.ZIPCODE                             AS ZipCode,
    w.COUNTRY                             AS Country,
    w.CONSIGNED_TYPE                      AS ConsignedType,
    w.CUSTOMER_ID                         AS ConsignCustomerID,
    w.VENDOR_ID                           AS ConsignVendorID,
    w.INDEPENDENT                         AS IndependentFlag,
    w.INV_NOT_SHARED                      AS InventoryNotSharedFlag,
    w.MRP_EXEMPT                          AS MRPExemptFlag,
    CAST(0 AS bit)                        AS IsUnknownWarehouse
FROM dbo.WAREHOUSE AS w

UNION ALL

SELECT
    N'(Unknown)'   AS WarehouseKey,
    N'(Unknown)'   AS WarehouseID,
    N'(Unknown)'   AS WarehouseName,
    NULL           AS [Description],
    NULL           AS SiteID,
    NULL           AS RegionID,
    NULL           AS Address1,
    NULL           AS Address2,
    NULL           AS Address3,
    NULL           AS City,
    NULL           AS [State],
    NULL           AS ZipCode,
    NULL           AS Country,
    NULL           AS ConsignedType,
    NULL           AS ConsignCustomerID,
    NULL           AS ConsignVendorID,
    NULL           AS IndependentFlag,
    NULL           AS InventoryNotSharedFlag,
    NULL           AS MRPExemptFlag,
    CAST(1 AS bit) AS IsUnknownWarehouse;
GO
