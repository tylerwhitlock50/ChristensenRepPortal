/*============================================================================
  20260901_rollup_restore.sql — refresh_territory_rollups() carries every
  column of every rollup table.

  Three restatements of this function have each silently dropped a column
  or a whole block (bookings_ytd in 20260817170000, first_invoice_date +
  agg_sku_month in 20260901000100/182504). The function body is the single
  home of every window, so this checks the body against the catalog rather
  than trusting whoever last edited it.

  Read-only; safe on prod.

      psql "$DATABASE_URL" -f supabase/tests/20260901_rollup_restore.sql
============================================================================*/

\set ON_ERROR_STOP on

do $$
declare
  body      text := pg_get_functiondef('public.refresh_territory_rollups()'::regprocedure);
  t         record;
  c         record;
  insert_at int;
  seg       text;
begin
  -- T1: every erp.agg_* table is truncated by the body.
  for t in
    select tablename from pg_tables
    where schemaname = 'erp' and tablename like 'agg\_%' order by 1
  loop
    if body !~* ('truncate\s+erp\.' || t.tablename || '\s*;') then
      raise exception 'T1 FAIL: refresh_territory_rollups() never truncates erp.%', t.tablename;
    end if;

    -- T2: every non-defaulted column of that table appears in the insert
    -- column list that follows its truncate. refreshed_at-style columns
    -- with a default are allowed to be omitted.
    insert_at := position(('insert into erp.' || t.tablename) in body);
    if insert_at = 0 then
      raise exception 'T2 FAIL: no insert into erp.% in the body', t.tablename;
    end if;
    seg := substr(body, insert_at, position(') ' in substr(body, insert_at)) + 1);
    for c in
      select column_name from information_schema.columns
      where table_schema = 'erp' and table_name = t.tablename
        and column_default is null
      order by ordinal_position
    loop
      if seg !~ ('\m' || c.column_name || '\M') then
        raise exception 'T2 FAIL: erp.%.% is not in the insert column list', t.tablename, c.column_name;
      end if;
    end loop;
  end loop;

  -- T3: the two order-side dollar columns are no longer the same expression
  -- (20260901190100): backlog_amount is the past-promise subset.
  if body !~ 'is_backlog_line and o\.promise_date < today' then
    raise exception 'T3 FAIL: backlog_amount is not the past-promise subset';
  end if;

  -- T4: cancelled orders are excluded from both bookings windows.
  if (select count(*) from regexp_matches(body, 'coalesce\(o\.order_status, ''''\) <> ''X''', 'g')) < 2 then
    raise exception 'T4 FAIL: bookings windows do not both exclude order_status X';
  end if;

  -- T5: the function is pinned to Mountain time (20260901190000).
  if not exists (
    select 1 from pg_proc
    where oid = 'public.refresh_territory_rollups()'::regprocedure
      and 'TimeZone=America/Denver' = any (proconfig)
  ) then
    raise exception 'T5 FAIL: refresh_territory_rollups() is not pinned to America/Denver';
  end if;

  raise notice 'ALL ROLLUP RESTORE TESTS PASSED';
end;
$$;
