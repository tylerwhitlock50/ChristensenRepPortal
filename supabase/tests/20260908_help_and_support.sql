/*============================================================================
  20260908_help_and_support.sql — the support inbox is private per rep and
  the guides are admin-written.

  Shape checks only (policies, grants, triggers) — the tables are new and
  empty on a fresh environment, and the per-row behaviour is a one-line
  policy each. Read-only; safe on prod.

      psql "$DATABASE_URL" -f supabase/tests/20260908_help_and_support.sql
============================================================================*/

\set ON_ERROR_STOP on

do $$
declare
  n int;
begin
  -- T1: RLS on, and the view-as read-only trigger attached, on all three.
  select count(*) into n
  from pg_tables
  where schemaname = 'public'
    and tablename in ('help_articles', 'support_requests', 'support_messages')
    and rowsecurity;
  if n <> 3 then
    raise exception 'T1 FAIL: RLS is not enabled on all three support tables (% of 3)', n;
  end if;

  select count(*) into n
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public'
    and c.relname in ('help_articles', 'support_requests', 'support_messages')
    and t.tgname = 'trg_' || c.relname || '_no_write_while_viewing_as';
  if n <> 3 then
    raise exception 'T1 FAIL: view-as read-only trigger missing on a support table (% of 3)', n;
  end if;

  -- T2: reps can only insert a request as themselves, and only read own /
  --     admin. Every support_requests policy must mention auth.uid().
  select count(*) into n
  from pg_policies
  where schemaname = 'public' and tablename = 'support_requests'
    and cmd in ('SELECT', 'INSERT', 'UPDATE')
    and coalesce(qual, '') || coalesce(with_check, '') not like '%auth.uid()%';
  if n > 0 then
    raise exception 'T2 FAIL: % support_requests policy(ies) do not scope by auth.uid()', n;
  end if;

  -- T3: help_articles writes are admin-only; reads are published-or-admin.
  select count(*) into n
  from pg_policies
  where schemaname = 'public' and tablename = 'help_articles'
    and cmd in ('INSERT', 'UPDATE', 'DELETE')
    and coalesce(qual, '') || coalesce(with_check, '') not like '%is_admin()%';
  if n > 0 then
    raise exception 'T3 FAIL: % help_articles write policy(ies) are not admin-gated', n;
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'help_articles'
      and cmd = 'SELECT' and qual like '%published%'
  ) then
    raise exception 'T3 FAIL: help_articles read policy does not check published';
  end if;

  -- T4: reps cannot rewrite or delete thread messages — only insert/select.
  if exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'support_messages'
      and grantee = 'authenticated'
      and privilege_type in ('UPDATE', 'DELETE')
  ) then
    raise exception 'T4 FAIL: authenticated holds UPDATE/DELETE on support_messages';
  end if;

  -- T5: anon holds nothing.
  select count(*) into n
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in ('help_articles', 'support_requests', 'support_messages')
    and grantee = 'anon';
  if n > 0 then
    raise exception 'T5 FAIL: anon holds % grant(s) on the support tables', n;
  end if;

  -- T6: the status trigger is attached.
  if not exists (
    select 1 from pg_trigger where tgname = 'trg_support_messages_insert'
  ) then
    raise exception 'T6 FAIL: trg_support_messages_insert is missing';
  end if;

  raise notice 'ALL HELP & SUPPORT TESTS PASSED';
end;
$$;
