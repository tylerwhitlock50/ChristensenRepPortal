/*============================================================================
  Object : bi.vw_DimCustomer
  Source : VECA.dbo.CUSTOMER                         (master, 1 row per cust)
           LEFT JOIN VECA.dbo.SALES_REP              (assigned-rep name)
           LEFT JOIN VECA.dbo.CUSTOMER_SITE          (site-level cust config)
           LEFT JOIN VFIN.dbo.RECEIVABLES_CUSTOMER_ENTITY  (credit / AR attrs)
  Grain  : One row per CUSTOMER.ID. NO '(Unknown)' sentinel row (deliberate).
  Key    : CustomerKey = CUSTOMER.ID (nvarchar(15)). Clean PK in Visual.
  Notes  : - NO SENTINEL (unlike the other dims): every fact sources its
             customer from a NOT NULL FK (CUSTOMER_ORDER.CUSTOMER_ID; the AR
             invoice header CUSTOMER_ID), so the fact-side COALESCE to
             '(Unknown)' never actually fires for customer — a sentinel row
             would only ever sit empty. The facts still COALESCE to '(Unknown)'
             defensively; if an unexpected null/blank or an unsynced VFIN
             customer ever appears, it surfaces as a VISIBLE orphan in the CI1 /
             C1 validation checks rather than silently dropping. That is the
             intended safety net here, not a sentinel.
           - Sold-to and bill-to are inline on the SAME Visual record (1:1),
             so bill-to is flattened in as columns — NOT a separate dimension.
             (Ship-to IS separate: 1:many — see vw_DimShipTo.)
           - AssignedSalesRep* = customer-header SALESREP_ID ("who owns the
             account"), DIFFERENT from the transacting rep on an order.
           - Keep ALL customers including inactive — NEVER WHERE ACTIVE_FLAG.
           - FFL: USER_4 = license, USER_5 = expiration (free-form string).

           CROSS-DB CREDIT / AR ENRICHMENT (VFIN, same instance):
           - Credit, finance-charge, AR-account, and invoice/statement-delivery
             settings live in VFIN, not VECA. Pulled from
             RECEIVABLES_CUSTOMER_ENTITY: CreditStatus, CreditLimitAmount,
             FinanceChargeExemptFlag, FinanceChargePct, ARTermsRuleID,
             ARPaymentMethodID, ARActiveFlag (int 0/1 — NOT the same as the
             VECA Y/N ActiveFlag), ReceivablesAccountID, BillToParentFlag,
             EmailInvoicesFlag, InvoiceEmail, EmailStatementsFlag, StatementEmail.
           - RECEIVABLES_CUSTOMER_ENTITY is customer x entity grain; this
             install runs a SINGLE accounting entity, so the LEFT JOIN is 1:1
             and does not fan out. (If a second entity is ever added, this join
             must be filtered to a primary ENTITY_ID or moved to a bridge — the
             A4 dedup check in 99_validation will flag the regression.)
           - DELIBERATELY EXCLUDED: OPEN_RECV_AMOUNT / OPEN_ORDER_AMOUNT. Those
             are volatile running balances (measures), not descriptive customer
             attributes — they belong in a fact/measure, not a conformed dim.
           - Requires the BI service account to have SELECT on VFIN.dbo.

           COLUMN-EXISTENCE NOTE: MARKET_ID, OPEN_DATE, LAST_ORDER_DATE,
           INTERNAL_CUSTOMER, SIC_CODE, IND_CODE, FINANCE_CHARGE,
           DUNNING_LETTERS are on base CUSTOMER (confirmed via the
           CUSTOMER_SITE_VIEW T1 column list) even though veca.md omits them.

           CUSTOMER_SITE FLATTEN: CustomerType / SitePriorityCode /
           OrderFillRateTarget come from CUSTOMER_SITE, which is customer x site
           grain. This shop runs a SINGLE site (not expanding), so the join is
           1:1 and these flatten safely as descriptive attributes — NOT a
           snowflake. Spine stays base CUSTOMER via LEFT JOIN so a customer with
           no site row still survives. If a second site is ever added this join
           fans out and must move to a customer-site bridge (A4 check flags it).

           CARMS BUYGROUP: CarmsCustomerGroup / CarmsCustomerSubGroup come from
           CUSTOMER_CARMS (1:1 on CUSTOMER.ID, verified). The business-maintained
           distribution-channel classification (BIG BOX, EVERYTHING ELSE, ...)
           the sales scorecards slice on — distinct from the native Visual
           CustomerGroupID.

           SALES REGION: SalesRegion is looked up from z_REGIONS on the
           CUSTOMER's own STATE (HQ / sold-to), NOT a ship-to — region follows
           where the account is headquartered, not where any one shipment goes.
           z_REGIONS is deduped to one region per state in the join so it cannot
           fan out the customer grain.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimCustomer
AS
SELECT
    c.ID                                  AS CustomerKey,
    c.ID                                  AS CustomerID,
    c.NAME                                AS CustomerName,
    -- Sold-to address
    c.ADDR_1                              AS SoldToAddress1,
    c.ADDR_2                              AS SoldToAddress2,
    c.ADDR_3                              AS SoldToAddress3,
    c.CITY                                AS SoldToCity,
    c.STATE                               AS SoldToState,
    c.ZIPCODE                             AS SoldToZipCode,
    c.COUNTRY                             AS SoldToCountry,
    -- Bill-to address (inline / 1:1 — flattened, not snowflaked)
    c.BILL_TO_NAME                        AS BillToName,
    c.BILL_TO_ADDR_1                      AS BillToAddress1,
    c.BILL_TO_ADDR_2                      AS BillToAddress2,
    c.BILL_TO_ADDR_3                      AS BillToAddress3,
    c.BILL_TO_CITY                        AS BillToCity,
    c.BILL_TO_STATE                       AS BillToState,
    c.BILL_TO_ZIPCODE                     AS BillToZipCode,
    c.BILL_TO_COUNTRY                     AS BillToCountry,
    -- Account ownership / classification
    c.SALESREP_ID                         AS AssignedSalesRepID,
    sr.NAME                               AS AssignedSalesRepName,
    c.TERRITORY                           AS Territory,
    -- Sales region: driven by the CUSTOMER's own (HQ / sold-to) state, NOT a
    -- ship-to. A customer HQ'd in UT is a UT/West customer even if it has a
    -- store in CO. z_REGIONS is deduped to one region per state (it carries
    -- junk NULL-state rows + a REP column we don't use) so the join can never
    -- fan out the customer grain.
    rgn.REGION                            AS SalesRegion,
    c.CUSTOMER_GROUP_ID                   AS CustomerGroupID,
    -- CARMS buygroup / distribution-channel classification (e.g. BIG BOX vs
    -- EVERYTHING ELSE). 1:1 with CUSTOMER (verified). Distinct from the native
    -- CustomerGroupID above — this is the business-maintained channel grouping
    -- the sales scorecards slice on.
    cc.CUSTOMER_GROUP                     AS CarmsCustomerGroup,
    cc.CUSTOMER_SUB_GROUP                 AS CarmsCustomerSubGroup,
    c.PRICE_GROUP                         AS PriceGroup,
    c.PRIORITY                            AS Priority,
    c.MARKET_ID                           AS MarketID,
    c.SIC_CODE                            AS SICCode,
    c.IND_CODE                            AS IndustryCode,
    c.INTERNAL_CUSTOMER                   AS InternalCustomerFlag,
    -- Customer-site config (single-site 1:1 — see header)
    cs.CUSTOMER_TYPE                      AS CustomerType,
    cs.PRIORITY_CODE                      AS SitePriorityCode,
    cs.ORDER_FILL_RATE                    AS OrderFillRateTarget,
    -- Terms / tax / status
    c.DISCOUNT_CODE                       AS DiscountCode,
    c.CURRENCY_ID                         AS CurrencyID,
    c.DEF_SLS_TAX_GRP_ID                  AS DefaultSalesTaxGroupID,
    c.TAX_EXEMPT                          AS TaxExemptFlag,
    c.TAX_ID_NUMBER                       AS TaxIDNumber,
    c.FINANCE_CHARGE                      AS FinanceChargeFlag,
    c.DUNNING_LETTERS                     AS DunningLettersFlag,
    c.ACTIVE_FLAG                         AS ActiveFlag,
    CAST(c.OPEN_DATE AS date)             AS AccountOpenDate,
    CAST(c.LAST_ORDER_DATE AS date)       AS LastOrderDate,
    -- Yearly sales goal: CUSTOMER.USER_3 is the UDF set up to hold the yearly
    -- goal. Free-form nvarchar; keep the raw value AND a defensively-parsed
    -- numeric (NULL on non-numeric entries, never errors the view) so the goal
    -- is usable in measures (goal vs. actual) without losing the original text.
    -- CASE/ISNUMERIC used instead of TRY_CONVERT: this instance's compatibility
    -- level does not recognize TRY_CONVERT, which caused 'decimal' parse errors.
    c.USER_3                              AS YearlySalesGoalRaw,
    CASE
        WHEN c.USER_3 IS NOT NULL
         AND LTRIM(RTRIM(c.USER_3)) <> ''
         AND ISNUMERIC(c.USER_3) = 1
        THEN CAST(c.USER_3 AS decimal(18, 2))
        ELSE NULL
    END                                   AS YearlySalesGoal,
    -- Credit / AR (VFIN, single-entity 1:1)
    rce.CREDIT_STATUS                     AS CreditStatus,
    rce.CREDIT_LIMIT_AMT                  AS CreditLimitAmount,
    rce.FIN_CHG_EXEMPT                    AS FinanceChargeExemptFlag,
    rce.FIN_CHG_PERCENT                   AS FinanceChargePct,
    rce.TERMS_RULE_ID                     AS ARTermsRuleID,
    rce.PAYMENT_METHOD_ID                 AS ARPaymentMethodID,
    -- AR-entity flag (int 0/1) — distinct from the VECA-side ActiveFlag (Y/N)
    rce.ACTIVE_FLAG                       AS ARActiveFlag,
    rce.RECV_ACCOUNT_ID                   AS ReceivablesAccountID,
    rce.BILL_TO_PARENT                    AS BillToParentFlag,
    -- Invoice / statement delivery config
    rce.EMAIL_INVOICES                    AS EmailInvoicesFlag,
    rce.INVOICE_EMAIL                     AS InvoiceEmail,
    rce.EMAIL_STATEMENTS                  AS EmailStatementsFlag,
    rce.STATEMENT_EMAIL                   AS StatementEmail,
    -- FFL compliance (customer-master default; ship-to value is authoritative)
    c.USER_4                              AS FFLLicenseNumber,
    c.USER_5                              AS FFLExpirationRaw
FROM dbo.CUSTOMER AS c
LEFT JOIN dbo.SALES_REP AS sr
    ON sr.ID = c.SALESREP_ID
LEFT JOIN dbo.CUSTOMER_SITE AS cs
    ON cs.CUSTOMER_ID = c.ID
LEFT JOIN VFIN.dbo.RECEIVABLES_CUSTOMER_ENTITY AS rce
    ON rce.CUSTOMER_ID = c.ID
LEFT JOIN dbo.CUSTOMER_CARMS AS cc
    ON cc.ID = c.ID
LEFT JOIN (
    -- One region per state. WHERE STATE IS NOT NULL drops the two junk
    -- NULL-state rows; GROUP BY guarantees 1 row/state so DimCustomer can't
    -- fan out even if a future duplicate state/region pair is added.
    SELECT STATE, MIN(REGION) AS REGION
    FROM dbo.z_REGIONS
    WHERE STATE IS NOT NULL
    GROUP BY STATE
) AS rgn
    ON rgn.STATE = c.STATE;
GO
