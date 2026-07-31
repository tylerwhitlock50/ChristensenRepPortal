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
