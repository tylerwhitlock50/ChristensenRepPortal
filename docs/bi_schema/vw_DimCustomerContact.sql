/*============================================================================
  Object : bi.vw_DimCustomerContact
  Source : VECA.dbo.CUST_CONTACT  (customer/contact assignment)
           INNER JOIN VECA.dbo.CONTACT  (contact master)
  Grain  : One row per customer/contact assignment.
  Key    : CustomerContactKey = CUSTOMER_ID + '|' + CONTACT_ID.

  Notes  : - This is the sales model's one deliberate SNOWFLAKE leaf:
               DimCustomer (1) -> (*) DimCustomerContact
             on CustomerKey, with single-direction filtering from customer to
             contact. It has NO direct relationship to a fact table; joining it
             to facts would multiply measures by the number of contacts.
           - CustomerContactKey is the association key. CONTACT.ID is globally
             unique in CONTACT but a contact can be assigned to more than one
             customer, so ContactID is NOT unique in this view.
           - Keep all assignments and contacts, including inactive rows. The CRM
             or report must filter ContactActiveFlag / consent flags explicitly.
           - PRIMARY_CONTACT is optional. Do not assume every customer has one;
             source data permits all contacts for a customer to be non-primary.
           - Use the normalized CUST_CONTACT -> CONTACT path. CUSTOMER_ORDER also
             references CONTACT.ID, and CUST_CONTACT supplies the customer
             assignment plus primary-contact flag. The older denormalized
             CUSTOMER_CONTACT table is deliberately not unioned because it lacks
             the normalized ContactID/preferences model and cannot be merged
             without ambiguous duplicate/stale-contact rules.
           - Data minimization: expose business contact and communication fields,
             but deliberately exclude WEB_USER_ID / WEB_PASSWORD, birth date,
             gender, marital status, and ungoverned USER_1..USER_10 fields.
           - No '(Unknown)' sentinel: this leaf does not key any fact, and both
             customer and contact parents are protected by source foreign keys.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimCustomerContact
AS
SELECT
    cc.CUSTOMER_ID + N'|' + cc.CONTACT_ID AS CustomerContactKey,
    cc.CUSTOMER_ID                        AS CustomerKey,
    cc.CONTACT_ID                         AS ContactID,
    cc.CONTACT_NO                         AS ContactNumber,
    cc.PRIMARY_CONTACT                    AS PrimaryContactFlag,

    -- Identity / role
    c.FIRST_NAME                          AS FirstName,
    c.LAST_NAME                           AS LastName,
    NULLIF(
        LTRIM(RTRIM(COALESCE(c.FIRST_NAME, N'') + N' '
            + COALESCE(c.LAST_NAME, N''))),
        N''
    )                                     AS ContactName,
    c.MIDDLE_NAME                         AS MiddleName,
    c.MIDDLE_INITIAL                      AS MiddleInitial,
    c.POSITION                            AS Position,
    c.SALUTATION                          AS Salutation,
    c.HONORIFIC                           AS Honorific,

    -- Communication
    c.COUNTRY_DIAL_CODE                   AS CountryDialCode,
    c.PHONE                               AS Phone,
    c.PHONE_EXT                           AS PhoneExtension,
    c.FAX                                 AS Fax,
    c.MOBILE                              AS Mobile,
    c.EMAIL                               AS Email,
    c.PREFERRED_CONTACT_METHOD            AS PreferredContactMethodCode,
    c.NO_CALL_PHONE                       AS DoNotCallPhoneFlag,
    c.NO_CALL_MOBILE                      AS DoNotCallMobileFlag,
    c.NO_EMAIL                            AS DoNotEmailFlag,

    -- Contact-specific mailing address
    c.ADDR_1                              AS Address1,
    c.ADDR_2                              AS Address2,
    c.ADDR_3                              AS Address3,
    c.CITY                                AS City,
    c.STATE                               AS State,
    c.ZIPCODE                             AS ZipCode,
    c.COUNTRY                             AS Country,
    c.CONTACT_COUNTRY_ID                  AS ContactCountryID,

    -- CRM-relevant profile links / status
    c.URL_LINKEDIN                        AS LinkedInURL,
    c.URL_TWITTER                         AS TwitterURL,
    c.URL_FACEBOOK                        AS FacebookURL,
    c.ACTIVE_FLAG                         AS ContactActiveFlag
FROM dbo.CUST_CONTACT AS cc
INNER JOIN dbo.CONTACT AS c
    ON c.ID = cc.CONTACT_ID;
GO
