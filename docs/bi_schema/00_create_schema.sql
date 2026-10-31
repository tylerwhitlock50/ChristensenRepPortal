/*============================================================================
  Object : SCHEMA [bi]
  Purpose: Namespace for the governed BI semantic layer. All views live in
           [bi]; nothing governed lives in [dbo]. One schema-level grant
           (GRANT SELECT ON SCHEMA::bi TO <bi_service_account>) covers the
           whole layer.
  Note   : CREATE OR ALTER does not exist for schemas, so this is the one
           object that needs a guarded create. Idempotent / rerunnable.
============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bi')
    EXEC('CREATE SCHEMA bi');
GO

/*============================================================================
  Object : SCHEMA [fin]
  Purpose: Separate namespace for the FINANCIAL surface (GL actuals, cost
           center reporting, budget, posting detail, RLS owner roster).
           Deliberately NOT [bi]: bi_reader / Powerbi_user / the sql-toolbox-bi
           connector must never see financial data by accident. Access is a
           separate role (fin_reader, 98_security/fin_access_roles.sql) that
           only elevated accounts are added to.
============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'fin')
    EXEC('CREATE SCHEMA fin');
GO
