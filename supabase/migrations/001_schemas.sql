/*============================================================================
  001_schemas.sql
  Purpose: Namespaces for the portal database.
    erp    — read-only landed data pushed from SQL Server bi.vw_* views.
             Written ONLY by the ETL (service_role). App roles get SELECT.
    public — app-owned writable tables (assignments, recommendations, visits…)
  Note   : PostgREST must expose the erp schema: Supabase Dashboard →
           Settings → API → "Exposed schemas" → add `erp`.
============================================================================*/
create schema if not exists erp;

grant usage on schema erp to authenticated;
-- Future tables in erp default to SELECT for authenticated (RLS still applies)
alter default privileges in schema erp grant select on tables to authenticated;
