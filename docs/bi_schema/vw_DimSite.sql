/*============================================================================
  Object : bi.vw_DimSite
  Source : VECA.dbo.SITE
  Grain  : One row per site (SITE.ID), plus one '(Unknown)' sentinel.
  Key    : SiteKey = SITE.ID (nvarchar). Natural business key; facts carry it.
  Notes  : - Conformed dimension, reused by BOTH the sales and purchasing
             models (SITE_ID is on nearly every transactional table).
           - Decision: keep ALL sites; reports slice by site. No single-site
             WHERE filter is baked into any fact view.
           - INTERNAL_CUST_ID = the customer record that represents this site
             for intercompany transactions; carried here for future
             intercompany identification (see DimCustomer open questions).
           - Sentinel '(Unknown)' catches facts whose SITE_ID is NULL/blank.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimSite
AS
SELECT
    s.ID                                  AS SiteKey,
    s.ID                                  AS SiteID,
    s.SITE_NAME                           AS SiteName,
    s.ENTITY_ID                           AS EntityID,
    s.SITE_ADDR_1                         AS Address1,
    s.SITE_ADDR_2                         AS Address2,
    s.SITE_ADDR_3                         AS Address3,
    s.SITE_CITY                           AS City,
    s.SITE_STATE                          AS [State],
    s.SITE_ZIPCODE                        AS ZipCode,
    s.SITE_COUNTRY                        AS Country,
    s.STATUS                              AS [Status],
    s.INTERNAL_CUST_ID                    AS InternalCustomerID,
    CAST(0 AS bit)                        AS IsUnknownSite
FROM dbo.SITE AS s

UNION ALL

SELECT
    N'(Unknown)' AS SiteKey,
    N'(Unknown)' AS SiteID,
    N'(Unknown)' AS SiteName,
    NULL         AS EntityID,
    NULL         AS Address1,
    NULL         AS Address2,
    NULL         AS Address3,
    NULL         AS City,
    NULL         AS [State],
    NULL         AS ZipCode,
    NULL         AS Country,
    NULL         AS [Status],
    NULL         AS InternalCustomerID,
    CAST(1 AS bit) AS IsUnknownSite;
GO
