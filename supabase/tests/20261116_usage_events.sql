/*============================================================================
  20261116_usage_events.sql — assertions for the usage log.

  Companion to 20261116130000_usage_events.sql. Proves that log_usage() is
  the only write path and stamps the caller, that junk and oversize input is
  dropped, that nothing is logged while an admin views as a rep, that the
  hourly cap holds, and that only an admin reads the table or the report.

  Runs entirely inside a transaction and ROLLS BACK.

      psql "$DATABASE_URL" -f supabase/tests/20261116_usage_events.sql

  Any error is a failure; a clean run printing "ALL USAGE-EVENT TESTS
  PASSED" is the pass condition.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('admin', 'a7a7a7a7-a7a7-4a7a-8a7a-a7a7a7a7a7a7'),
  ('rep',   'b8b8b8b8-b8b8-4b8b-8b8b-b8b8b8b8b8b8'),
  ('quiet', 'c9c9c9c9-c9c9-4c9c-8c9c-c9c9c9c9c9c9');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@usage.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set role = 'admin', full_name = 'Usage Admin'
  where user_id = (select id from t_user where label = 'admin');
update public.profiles set full_name = 'Usage Rep'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set full_name = 'Quiet Rep'
  where user_id = (select id from t_user where label = 'quiet');

-- Since 20261124090000 nothing is logged for someone who has not agreed to
-- the current Terms of Use and Privacy Policy (that rule has its own tests in
-- 20261124_legal_agreements.sql): everyone here has agreed.
insert into public.legal_acceptances (user_id, document_id, doc_key, version, content_sha256)
select u.id, c.id, c.doc_key, c.version, c.content_sha256
from t_user u cross join public.legal_current_documents() c;

create or replace function pg_temp.be(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
end;
$$;

/** log_usage() as the user, under RLS; returns rows written. */
create or replace function pg_temp.log_as(p_user uuid, p_events jsonb) returns integer
language plpgsql as $$
declare n integer;
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select public.log_usage(p_events) into n;
  execute 'reset role';
  return n;
end;
$$;

create or replace function pg_temp.report_as(p_user uuid, p_days int, p_only uuid, p_admins boolean)
returns jsonb
language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select public.admin_usage_report(p_days, p_only, p_admins) into j;
  execute 'reset role';
  return j;
end;
$$;

do $$
declare
  v_admin uuid := (select id from t_user where label = 'admin');
  v_rep   uuid := (select id from t_user where label = 'rep');
  v_quiet uuid := (select id from t_user where label = 'quiet');
  n       integer;
  j       jsonb;
  r       jsonb;
begin
  -- T1: no direct insert, for anyone.
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  begin
    insert into public.usage_events (user_id, event) values (v_rep, 'page_view');
    execute 'reset role';
    raise exception 'T1 FAIL: a rep inserted into usage_events directly';
  exception when insufficient_privilege then
    execute 'reset role';
  end;

  -- T2: log_usage writes the caller's rows; a spoofed user_id and time are ignored.
  n := pg_temp.log_as(v_rep, jsonb_build_array(
    jsonb_build_object('event', 'page_view', 'page', 'intel-ats', 'device', 'phone',
                       'user_id', v_admin, 'occurred_at', '2001-01-01'),
    jsonb_build_object('event', 'page_view', 'page', 'intel-ats', 'device', 'phone'),
    jsonb_build_object('event', 'page_view', 'page', 'account', 'customer_key', 'CUST-1',
                       'device', 'desktop'),
    jsonb_build_object('event', 'export', 'page', 'intel-ats',
                       'detail', jsonb_build_object('report', 'In stock', 'format', 'xlsx'))));
  if n <> 4 then raise exception 'T2 FAIL: wrote % rows, expected 4', n; end if;
  if exists (select 1 from public.usage_events
             where user_id <> v_rep or occurred_at < now() - interval '1 minute') then
    raise exception 'T2 FAIL: a row carries a spoofed user or time';
  end if;

  -- T3: junk is dropped, not raised: bad event names, a bad device, oversize
  -- detail, a non-array, and everything past the 20th event.
  n := pg_temp.log_as(v_rep, jsonb_build_array(
    jsonb_build_object('event', 'Page View'),
    jsonb_build_object('page', 'no-event'),
    '"a string"'::jsonb,
    jsonb_build_object('event', 'page_view', 'page', 'overview', 'device', 'toaster',
                       'detail', jsonb_build_object('blob', repeat('x', 2000)))));
  if n <> 1 then raise exception 'T3 FAIL: wrote % rows, expected 1', n; end if;
  if not exists (select 1 from public.usage_events
                 where page = 'overview' and device is null and detail is null) then
    raise exception 'T3 FAIL: bad device / oversize detail were not nulled';
  end if;
  if pg_temp.log_as(v_rep, '{"event":"page_view"}'::jsonb) <> 0 then
    raise exception 'T3 FAIL: a non-array was logged';
  end if;
  n := pg_temp.log_as(v_quiet, (select jsonb_agg(jsonb_build_object('event', 'page_view', 'page', 'help'))
                                from generate_series(1, 30)));
  if n <> 20 then raise exception 'T3 FAIL: batch cap wrote % rows, expected 20', n; end if;
  delete from public.usage_events where user_id = v_quiet;

  -- T4: nothing is logged while the admin views as the rep.
  n := pg_temp.log_as(v_admin, '[{"event":"page_view","page":"admin-users"}]'::jsonb);
  if n <> 1 then raise exception 'T4 FAIL: admin''s own view not logged'; end if;
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(v_rep);
  select public.log_usage('[{"event":"page_view","page":"overview"}]'::jsonb) into n;
  perform public.stop_impersonation();
  execute 'reset role';
  if n <> 0 then raise exception 'T4 FAIL: logged % rows while viewing as a rep', n; end if;

  -- T5: only the admin reads the table.
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  if exists (select 1 from public.usage_events) then
    execute 'reset role';
    raise exception 'T5 FAIL: a rep can read usage_events';
  end if;
  execute 'reset role';
  if pg_temp.report_as(v_rep, 30, null, true) is not null then
    raise exception 'T5 FAIL: a rep got the usage report';
  end if;

  -- T6: the report. Admins left out by default; everyone active listed, zeros included.
  j := pg_temp.report_as(v_admin, 7, null, false);
  if (j -> 'totals' ->> 'views')::int <> 4 or (j -> 'totals' ->> 'users')::int <> 1
     or (j -> 'totals' ->> 'actions')::int <> 1 or (j -> 'totals' ->> 'phone_views')::int <> 2 then
    raise exception 'T6 FAIL: totals = %', j -> 'totals';
  end if;
  if jsonb_array_length(j -> 'by_day') <> 7 then
    raise exception 'T6 FAIL: by_day has % days, expected 7', jsonb_array_length(j -> 'by_day');
  end if;
  if (j -> 'by_page' -> 0 ->> 'page') <> 'intel-ats' or (j -> 'by_page' -> 0 ->> 'views')::int <> 2 then
    raise exception 'T6 FAIL: by_page[0] = %', j -> 'by_page' -> 0;
  end if;
  select x into r from jsonb_array_elements(j -> 'by_user') x where x ->> 'user_id' = v_rep::text;
  if r is null or (r ->> 'views')::int <> 4 or (r ->> 'active_days')::int <> 1
     or (r ->> 'accounts')::int <> 1 or (r ->> 'exports')::int <> 1
     or r ->> 'top_page' <> 'intel-ats' then
    raise exception 'T6 FAIL: rep row = %', r;
  end if;
  select x into r from jsonb_array_elements(j -> 'by_user') x where x ->> 'user_id' = v_quiet::text;
  if r is null or (r ->> 'views')::int <> 0 then
    raise exception 'T6 FAIL: a rep with no use is missing or non-zero: %', r;
  end if;
  if exists (select 1 from jsonb_array_elements(j -> 'by_user') x where x ->> 'user_id' = v_admin::text) then
    raise exception 'T6 FAIL: the admin is listed without include_admins';
  end if;
  if (j -> 'by_account' -> 0 ->> 'customer_key') <> 'CUST-1' then
    raise exception 'T6 FAIL: by_account = %', j -> 'by_account';
  end if;
  if (j -> 'by_action' -> 0 ->> 'what') <> 'In stock' then
    raise exception 'T6 FAIL: by_action = %', j -> 'by_action';
  end if;
  if jsonb_array_length(j -> 'recent') <> 5 then
    raise exception 'T6 FAIL: recent has % rows', jsonb_array_length(j -> 'recent');
  end if;

  -- T7: include_admins, and the one-person filter.
  j := pg_temp.report_as(v_admin, 7, null, true);
  if (j -> 'totals' ->> 'users')::int <> 2 then
    raise exception 'T7 FAIL: users with admins = %', j -> 'totals' ->> 'users';
  end if;
  j := pg_temp.report_as(v_admin, 7, v_quiet, false);
  if (j -> 'totals' ->> 'views')::int <> 0 or jsonb_array_length(j -> 'by_user') <> 1 then
    raise exception 'T7 FAIL: one-person report = %', j -> 'totals';
  end if;

  -- T8: the hourly cap.
  insert into public.usage_events (user_id, event, page)
  select v_quiet, 'page_view', 'help' from generate_series(1, 600);
  if pg_temp.log_as(v_quiet, '[{"event":"page_view","page":"help"}]'::jsonb) <> 0 then
    raise exception 'T8 FAIL: logged past 600 events in an hour';
  end if;

  -- T9: anon cannot call either function.
  if has_function_privilege('anon', 'public.log_usage(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.admin_usage_report(integer, uuid, boolean)', 'execute') then
    raise exception 'T9 FAIL: anon can execute a usage function';
  end if;

  raise notice 'ALL USAGE-EVENT TESTS PASSED';
end;
$$;

rollback;
