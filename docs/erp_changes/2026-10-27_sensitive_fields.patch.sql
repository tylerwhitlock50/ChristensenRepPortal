/*============================================================================
  PATCH  : stop publishing two sensitive fields
           bi.vw_DimCustomer.TaxIDNumber, bi.vw_DimCustomerContact.Salutation
  For    : the owner of the bi.* views (Power BI project)
  From   : Tyler / Rep Portal, 2026-10-27. Read 2026-10-27_bi_view_changes.md
           (same folder) first.

  One select-list line per view. Both columns stay in the view, with the same
  name, position and type, so nothing that selects them breaks; they are just
  always NULL. Written against the Rep Portal's copies in docs/bi_schema/,
  which may be stale: apply to the LIVE definitions from your project.

  Types are the live view column types, read from sys.columns on 2026-10-26
  (they equal the source columns CUSTOMER.TAX_ID_NUMBER nvarchar(25) and
  CONTACT.SALUTATION nvarchar(60)).
============================================================================*/


/*----------------------------------------------------------------------------
  bi.vw_DimCustomer (column 43 of 65)

  FIND:
    c.TAX_ID_NUMBER                       AS TaxIDNumber,

  REPLACE WITH:
----------------------------------------------------------------------------*/
    -- Deliberately NULL (2026-10-27): free-text field that holds personal
    -- identifiers on some records; not published to BI. Kept as a typed NULL
    -- so the column list does not change. A report that genuinely needs a
    -- tax ID should read it from a separately granted, restricted object.
    CAST(NULL AS nvarchar(25))            AS TaxIDNumber,


/*----------------------------------------------------------------------------
  bi.vw_DimCustomerContact (column 12 of 35)

  FIND:
    c.SALUTATION                          AS Salutation,

  REPLACE WITH:
----------------------------------------------------------------------------*/
    -- Deliberately NULL (2026-10-27): free-text field that held personal data
    -- on at least one record; not published to BI. Kept as a typed NULL so
    -- the column list does not change. Honorific is unaffected.
    CAST(NULL AS nvarchar(60))            AS Salutation,


/*----------------------------------------------------------------------------
  Also update the header "Data minimization" note in vw_DimCustomerContact to
  list SALUTATION among the deliberately excluded fields, and add TAX_ID_NUMBER
  to a similar note in vw_DimCustomer.
----------------------------------------------------------------------------*/
