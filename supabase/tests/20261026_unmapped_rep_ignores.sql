/*============================================================================
  20261026_unmapped_rep_ignores.sql — assertions for the admin's ignore
  list on "Reps without an account".

  Companion to 20261026120000_unmapped_rep_ignores.sql, on top of
  20261013_unmapped_reps.sql (which still passes unchanged: it names its
  columns). Proves that an ignored rep stays in admin_unmapped_reps() with
  the flag set, that only a real admin can ignore or restore, and that the
  view-as trigger is on the new table.

  Runs entirely inside a transaction and ROLLS BACK.

      psql "$DATABASE_URL" -f supabase/tests/20261026_unmapped_rep_ignores.sql

  Any error is a failure; a clean run printing "ALL REP-IGNORE TESTS
  PASSED" is the pass condition.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures: one admin, one rep, two unmapped ERP reps.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('admin', 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3'),
  ('rep',   'd4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@ignores.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set role = 'admin', full_name = 'Ignore Admin'
  where user_id = (select id from t_user where label = 'admin');

insert into erp.dim_sales_rep
  (sales_rep_key, sales_rep_name, sales_rep_email, sales_rep_type, is_placeholder_rep)
values
  ('IG-KEEP', 'KEEP REP', 'keep@ignores.test', 'CONTRACT', false),
  ('IG-PARK', 'PARK REP', 'park@ignores.test', 'CONTRACT', false);

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.be(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
end;
$$;

/** "key:ignored:note" for the IG-* rows the caller gets back. */
create or replace function pg_temp.listing(p_user uuid) returns text[]
language plpgsql as $$
declare out text[];
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select array(
    select r.sales_rep_key || ':' || r.ignored || ':' || coalesce(r.ignore_note, '-')
    from public.admin_unmapped_reps() r
    where r.sales_rep_key like 'IG-%'
    order by r.sales_rep_key
  ) into out;
  execute 'reset role';
  return out;
end;
$$;

/** Runs one statement as the user under RLS; returns the SQLSTATE or 'ok'. */
create or replace function pg_temp.try_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  begin
    execute p_sql;
  exception when others then
    execute 'reset role';
    return sqlstate;
  end;
  execute 'reset role';
  return 'ok';
end;
$$;

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------
do $$
declare
  v_admin uuid := (select id from t_user where label = 'admin');
  v_rep   uuid := (select id from t_user where label = 'rep');
  got     text[];
  rc      text;
begin
  -- T1: a rep can neither ignore nor read ignores.
  rc := pg_temp.try_as(v_rep,
    $q$insert into public.unmapped_rep_ignores (sales_rep_key) values ('IG-PARK')$q$);
  if rc = 'ok' then
    raise exception 'T1 FAIL: a rep could insert into unmapped_rep_ignores';
  end if;
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  if exists (select 1 from public.unmapped_rep_ignores) then
    execute 'reset role';
    raise exception 'T1 FAIL: a rep can read unmapped_rep_ignores';
  end if;
  execute 'reset role';

  -- T2: the admin ignores one; it stays listed, flagged, with the note.
  rc := pg_temp.try_as(v_admin,
    $q$insert into public.unmapped_rep_ignores (sales_rep_key, note)
       values ('IG-PARK', 'retired 2025')$q$);
  if rc <> 'ok' then
    raise exception 'T2 FAIL: admin insert refused with %', rc;
  end if;
  got := pg_temp.listing(v_admin);
  if got <> array['IG-KEEP:false:-', 'IG-PARK:true:retired 2025'] then
    raise exception 'T2 FAIL: listing after ignore = %', got;
  end if;

  -- T3: ignored_by is pinned to the caller — an admin cannot write a row
  -- as somebody else.
  rc := pg_temp.try_as(v_admin,
    format($q$insert into public.unmapped_rep_ignores (sales_rep_key, ignored_by)
              values ('IG-KEEP', %L)$q$, v_rep));
  if rc = 'ok' then
    raise exception 'T3 FAIL: admin inserted an ignore attributed to another user';
  end if;

  -- T4: restore is a delete; the flag drops.
  rc := pg_temp.try_as(v_admin,
    $q$delete from public.unmapped_rep_ignores where sales_rep_key = 'IG-PARK'$q$);
  if rc <> 'ok' then
    raise exception 'T4 FAIL: admin delete refused with %', rc;
  end if;
  got := pg_temp.listing(v_admin);
  if got <> array['IG-KEEP:false:-', 'IG-PARK:false:-'] then
    raise exception 'T4 FAIL: listing after restore = %', got;
  end if;

  -- T5: the view-as read-only trigger is attached, and anon holds nothing.
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'unmapped_rep_ignores'
      and t.tgname = 'trg_unmapped_rep_ignores_no_write_while_viewing_as'
  ) then
    raise exception 'T5 FAIL: no view-as trigger on unmapped_rep_ignores';
  end if;
  if has_table_privilege('anon', 'public.unmapped_rep_ignores', 'select') then
    raise exception 'T5 FAIL: anon can read unmapped_rep_ignores';
  end if;

  raise notice 'ALL REP-IGNORE TESTS PASSED';
end;
$$;

rollback;
