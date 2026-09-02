/*============================================================================
  20260901_view_as_trigger_sweep.sql — every RLS-enabled public table
  refuses writes while an admin is viewing as a rep.

  20260816140000 attached the trigger to the tables that existed that day;
  the order-writer tables landed the next day without it (fixed in
  20260901190200). This makes the next omission a failing test.

  Read-only; safe on prod.

      psql "$DATABASE_URL" -f supabase/tests/20260901_view_as_trigger_sweep.sql
============================================================================*/

\set ON_ERROR_STOP on

do $$
declare
  missing text;
begin
  select string_agg(p.tablename, ', ' order by p.tablename) into missing
  from pg_tables p
  where p.schemaname = 'public'
    and p.rowsecurity
    and p.tablename not in ('impersonation', 'impersonation_events',
                            'login_events', 'job_runs')
    and not exists (
      select 1
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = p.tablename
        and t.tgname = 'trg_' || p.tablename || '_no_write_while_viewing_as'
        and not t.tgisinternal
    );

  if missing is not null then
    raise exception 'T1 FAIL: no view-as read-only trigger on: % — re-run the sweep in 20260901190200', missing;
  end if;

  raise notice 'ALL VIEW-AS TRIGGER TESTS PASSED';
end;
$$;
