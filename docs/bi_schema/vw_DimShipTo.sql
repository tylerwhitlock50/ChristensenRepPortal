/*============================================================================
  Object : bi.vw_DimShipTo
  Source : VECA.dbo.CUST_ADDRESS
  Grain  : One row per (CUSTOMER_ID, ADDR_NO) real ship-to,
           PLUS one customer-master fallback row per CUSTOMER (key suffix
           '|CUST'), PLUS one '(Unknown)' sentinel.
  Key    : ShipToKey = CUSTOMER_ID + '|' + ADDR_NO  (single-column surrogate
           so Power BI can build a one-column relationship). The fact computes
           the IDENTICAL expression from (CUSTOMER_ID, SHIP_TO_ADDR_NO).
           When the fact has NO ship-to address, it instead emits
           CUSTOMER_ID + '|CUST' and lands on the customer-master fallback row.
  AddressSource : 'ShipTo' (real CUST_ADDRESS row) | 'CustomerMaster' (the
           customer's own address used as a fallback ship-to) | 'Unknown'.
  Notes  : - Ship-to is 1:many off the customer, so it is its OWN dimension
             (unlike bill-to, which is 1:1 and flattened onto DimCustomer).
           - Join key is ADDR_NO (int), NOT SHIPTO_ID. SHIPTO_ID is a
             human-friendly code that drifts; carried as a descriptive
             attribute only.
           - Do NOT use the legacy SHIPTO_ADDRESS table — it doesn't link to
             the customer.
           - Authoritative location for ship-to FFL: USER_4 = license,
             USER_5 = expiration (free-form string).
           - Relates DIRECTLY to facts; never routed through DimCustomer.
           - Keep ALL ship-tos including inactive — no ACTIVE_FLAG filter.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimShipTo
AS
SELECT
    ca.CUSTOMER_ID + N'|' + CAST(ca.ADDR_NO AS nvarchar(20)) AS ShipToKey,
    ca.CUSTOMER_ID                        AS CustomerID,
    ca.ADDR_NO                            AS AddrNo,
    ca.SHIPTO_ID                          AS ShipToID,
    ca.NAME                               AS ShipToName,
    ca.ADDR_1                             AS Address1,
    ca.ADDR_2                             AS Address2,
    ca.ADDR_3                             AS Address3,
    ca.CITY                               AS City,
    ca.STATE                              AS [State],
    ca.ZIPCODE                            AS ZipCode,
    ca.COUNTRY                            AS Country,
    ca.SHIP_VIA                           AS ShipVia,
    ca.FREE_ON_BOARD                      AS FreeOnBoard,
    ca.CARRIER_ID                         AS CarrierID,
    ca.WAREHOUSE_ID                       AS WarehouseID,
    ca.DISCOUNT_CODE                      AS DiscountCode,
    ca.DEF_SLS_TAX_GRP_ID                 AS DefaultSalesTaxGroupID,
    ca.SALESREP_ID                        AS ShipToSalesRepID,
    ca.TERRITORY                          AS Territory,
    ca.ACTIVE_FLAG                        AS ActiveFlag,
    ca.USER_4                             AS FFLLicenseNumber,
    ca.USER_5                             AS FFLExpirationRaw,
    N'ShipTo'                             AS AddressSource,
    CAST(0 AS bit)                        AS IsUnknownShipTo
FROM dbo.CUST_ADDRESS AS ca

UNION ALL

-- Customer-master fallback rows: one synthetic ship-to per CUSTOMER, built from
-- the customer's own (sold-to) address. Key = CUSTOMER_ID + '|CUST' (the 'CUST'
-- marker never collides with a real integer ADDR_NO). When an order/shipment/
-- invoice has NO ship-to address, the fact resolves its ShipToKey to this row
-- instead of '(Unknown)', so every line lands on a real address with no
-- null-checking on the Power BI side. Deliberate double-entry of the customer
-- address (also on DimCustomer as SoldTo*) — the trade is fewer report-side
-- COALESCEs. AddrNo is NULL because there is no CUST_ADDRESS row behind it.
SELECT
    c.ID + N'|CUST'                       AS ShipToKey,
    c.ID                                  AS CustomerID,
    NULL                                  AS AddrNo,
    NULL                                  AS ShipToID,
    c.NAME                                AS ShipToName,
    c.ADDR_1                              AS Address1,
    c.ADDR_2                              AS Address2,
    c.ADDR_3                              AS Address3,
    c.CITY                                AS City,
    c.STATE                               AS [State],
    c.ZIPCODE                             AS ZipCode,
    c.COUNTRY                             AS Country,
    c.SHIP_VIA                            AS ShipVia,
    c.FREE_ON_BOARD                       AS FreeOnBoard,
    c.CARRIER_ID                          AS CarrierID,
    NULL                                  AS WarehouseID,
    c.DISCOUNT_CODE                       AS DiscountCode,
    c.DEF_SLS_TAX_GRP_ID                  AS DefaultSalesTaxGroupID,
    c.SALESREP_ID                         AS ShipToSalesRepID,
    c.TERRITORY                           AS Territory,
    c.ACTIVE_FLAG                         AS ActiveFlag,
    c.USER_4                              AS FFLLicenseNumber,
    c.USER_5                              AS FFLExpirationRaw,
    N'CustomerMaster'                     AS AddressSource,
    CAST(0 AS bit)                        AS IsUnknownShipTo
FROM dbo.CUSTOMER AS c

UNION ALL

SELECT
    N'(Unknown)'   AS ShipToKey,
    N'(Unknown)'   AS CustomerID,
    NULL           AS AddrNo,
    NULL           AS ShipToID,
    N'(Unknown)'   AS ShipToName,
    NULL           AS Address1,
    NULL           AS Address2,
    NULL           AS Address3,
    NULL           AS City,
    NULL           AS [State],
    NULL           AS ZipCode,
    NULL           AS Country,
    NULL           AS ShipVia,
    NULL           AS FreeOnBoard,
    NULL           AS CarrierID,
    NULL           AS WarehouseID,
    NULL           AS DiscountCode,
    NULL           AS DefaultSalesTaxGroupID,
    NULL           AS ShipToSalesRepID,
    NULL           AS Territory,
    NULL           AS ActiveFlag,
    NULL           AS FFLLicenseNumber,
    NULL           AS FFLExpirationRaw,
    N'Unknown'     AS AddressSource,
    CAST(1 AS bit) AS IsUnknownShipTo;
GO
