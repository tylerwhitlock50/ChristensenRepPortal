/*============================================================================
  016_missions.sql — assertions for missions and the 016 hardening.

  Same harness as 010_access_rules.sql: runs entirely inside a transaction
  and ROLLS BACK, creating throwaway auth users. Dev only — never prod.

      psql "$DATABASE_URL" -f supabase/tests/016_missions.sql

  A clean run prints "ALL MISSION TESTS PASSED"; any error is a failure.

  Fixtures are throwaway ERP rows seeded (and rolled back) by the test
  itself, same as 010: an 8-account rep inside a 2-rep / 14-account agency.
  Expected counts are computed from the data at run time, so the file runs
  on the bare _local_harness.sql cluster and on dev alike.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------
create temporary table t_fix (name text primary key, val text) on commit drop;
insert into t_fix (name, val) values
  ('rep_key',     'MIS REPA'),
  ('vendor_id',   'MIS VENDOR'),
  ('placeholder', 'WEB');   -- a REAL placeholder key: T4/T8 assert rejection

insert into erp.dim_sales_rep (sales_rep_key, vendor_id) values
  ('MIS REPA', 'MIS VENDOR'),
  ('MIS REPB', 'MIS VENDOR');

-- 8 + 6 active accounts across the agency's reps (guard needs ≥5 each way).
insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id,
   customer_type, active_flag)
select format('MIS-CUST-%s%s', b.rep_tag, g),
       format('MIS-CUST-%s%s', b.rep_tag, g),
       format('MIS %s Dealer %s', b.rep_tag, g),
       b.rep_key, 'MIS-DEALER', 'Y'
from (values ('A', 'MIS REPA', 8),
             ('B', 'MIS REPB', 6)) as b(rep_tag, rep_key, n)
cross join lateral generate_series(1, b.n) g;

-- Expected scope sizes use the SAME predicate as create_mission with
-- p_active_only = true (its default).
create temporary table t_expect (name text primary key, n int) on commit drop;
insert into t_expect
select 'rep_scope', count(*) from erp.dim_customer
 where active_flag = 'Y'
   and assigned_sales_rep_id = (select val from t_fix where name='rep_key');
insert into t_expect
select 'vendor_scope', count(*) from erp.dim_customer c
 where c.active_flag = 'Y'
   and exists (
     select 1 from erp.dim_sales_rep sr
     where sr.sales_rep_key = c.assigned_sales_rep_id
       and sr.vendor_id = (select val from t_fix where name='vendor_id')
       and not (sr.sales_rep_key = any (public.placeholder_rep_keys())));

-- Throwaway users; handle_new_user creates each profile (now with email).
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-1111-4111-8111-111111111111'),
  ('admin', 'bbbbbbbb-2222-4222-8222-222222222222');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@missions.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = (select val from t_fix where name='rep_key')
  where p.user_id = (select id from t_user where label='rep');
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.as_user(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  execute 'set local role authenticated';
end;
$$;

create or replace function pg_temp.as_postgres() returns void
language plpgsql as $$
begin
  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- The assertions
--------------------------------------------------------------------------
do $$
declare
  u_rep      uuid := (select id from t_user where label='rep');
  u_admin    uuid := (select id from t_user where label='admin');
  f_rep_key  text := (select val from t_fix where name='rep_key');
  f_vendor   text := (select val from t_fix where name='vendor_id');
  n_rep      int  := (select n from t_expect where name='rep_scope');
  n_vendor   int  := (select n from t_expect where name='vendor_scope');
  v_count    int;
  v_batch    bigint;
  v_rec      bigint;
  v_key      text;
  v_action   bigint;
  v_status   text;
begin
  if n_rep < 5 or n_vendor < 5 then
    raise exception 'Fixtures no longer match the data (rep=%, vendor=%). Re-pin them.',
      n_rep, n_vendor;
  end if;

  ----------------------------------------------------------------
  -- T1: email backfill / handle_new_user mirrors auth email.
  ----------------------------------------------------------------
  if (select email from public.profiles where user_id = u_rep) <> 'rep@missions.test' then
    raise exception 'T1 FAILED: profiles.email not mirrored from auth.users';
  end if;
  raise notice 'T1 ok (profiles.email mirrored)';

  ----------------------------------------------------------------
  -- T2: dry run count matches the pinned scope, creates nothing.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_admin);
  select created_count into v_count
    from public.create_mission(
      p_title => 'Test blitz', p_scope_type => 'rep',
      p_scope_value => f_rep_key, p_dry_run => true);
  if v_count <> n_rep then
    perform pg_temp.as_postgres();
    raise exception 'T2 FAILED: dry run expected %, got %', n_rep, v_count;
  end if;
  perform pg_temp.as_postgres();
  if exists (select 1 from public.mission_batches where title = 'Test blitz') then
    raise exception 'T2 FAILED: dry run created a batch';
  end if;
  raise notice 'T2 ok (dry run counts % without creating)', n_rep;

  ----------------------------------------------------------------
  -- T3: real run creates batch + one recommendation per account,
  --     and mission_batch_progress agrees.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_admin);
  select m.batch_id, m.created_count into v_batch, v_count
    from public.create_mission(
      p_title => 'Test blitz', p_reason => 'Follow up every dealer',
      p_priority => 'high', p_due_date => current_date + 14,
      p_requires_visit => true,
      p_scope_type => 'rep', p_scope_value => f_rep_key) m;
  if v_count <> n_rep then
    perform pg_temp.as_postgres();
    raise exception 'T3 FAILED: created % rows, expected %', v_count, n_rep;
  end if;
  if (select count(*) from public.recommendations
       where batch_id = v_batch and source = 'admin' and requires_visit) <> n_rep then
    perform pg_temp.as_postgres();
    raise exception 'T3 FAILED: recommendations rows do not match the batch';
  end if;
  if (select total from public.mission_batch_progress where batch_id = v_batch) <> n_rep
     or (select open_count from public.mission_batch_progress where batch_id = v_batch) <> n_rep then
    perform pg_temp.as_postgres();
    raise exception 'T3 FAILED: mission_batch_progress disagrees';
  end if;
  perform pg_temp.as_postgres();
  raise notice 'T3 ok (batch % created % missions)', v_batch, n_rep;

  ----------------------------------------------------------------
  -- T4: vendor scope resolves the agency book; placeholder rep
  --     scope is rejected.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_admin);
  select created_count into v_count
    from public.create_mission(
      p_title => 'Vendor blitz', p_scope_type => 'vendor',
      p_scope_value => f_vendor, p_dry_run => true);
  if v_count <> n_vendor then
    perform pg_temp.as_postgres();
    raise exception 'T4 FAILED: vendor dry run expected %, got %', n_vendor, v_count;
  end if;
  begin
    perform public.create_mission(
      p_title => 'Bad', p_scope_type => 'rep',
      p_scope_value => 'WEB', p_dry_run => true);
    perform pg_temp.as_postgres();
    raise exception 'T4 FAILED: placeholder rep scope was accepted';
  exception when others then
    if sqlerrm not like '%placeholder_rep_key%' then
      perform pg_temp.as_postgres();
      raise exception 'T4 FAILED: wrong error for placeholder scope: %', sqlerrm;
    end if;
  end;
  perform pg_temp.as_postgres();
  raise notice 'T4 ok (vendor scope %, placeholder rejected)', n_vendor;

  ----------------------------------------------------------------
  -- T5: a rep can neither call create_mission nor insert
  --     recommendations directly.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);
  begin
    perform public.create_mission(
      p_title => 'Nope', p_scope_type => 'rep',
      p_scope_value => f_rep_key, p_dry_run => true);
    perform pg_temp.as_postgres();
    raise exception 'T5 FAILED: rep called create_mission';
  exception when others then
    if sqlerrm not like '%not_admin%' then
      perform pg_temp.as_postgres();
      raise exception 'T5 FAILED: wrong error for rep create_mission: %', sqlerrm;
    end if;
  end;
  begin
    insert into public.recommendations (customer_key, source, title)
    select customer_key, 'admin', 'Nope' from erp.dim_customer limit 1;
    perform pg_temp.as_postgres();
    raise exception 'T5 FAILED: rep inserted a recommendation';
  exception when sqlstate '42501' then
    null; -- RLS rejection is the pass condition
  end;
  perform pg_temp.as_postgres();
  raise notice 'T5 ok (rep cannot create missions)';

  ----------------------------------------------------------------
  -- T6: requires_visit — close is blocked until a survey exists,
  --     then succeeds; dismissal never needs one.
  ----------------------------------------------------------------
  select r.id, r.customer_key into v_rec, v_key
  from public.recommendations r
  where r.batch_id = v_batch
  order by r.customer_key limit 1;

  perform pg_temp.as_user(u_rep);
  begin
    update public.recommendations
       set status = 'closed', outcome = 'order_received'
     where id = v_rec;
    perform pg_temp.as_postgres();
    raise exception 'T6 FAILED: visit-required mission closed without a survey';
  exception when others then
    if sqlerrm not like '%mission_requires_visit%' then
      perform pg_temp.as_postgres();
      raise exception 'T6 FAILED: wrong error closing without survey: %', sqlerrm;
    end if;
  end;

  -- The rep does the survey: action (advances to acted) then visit.
  insert into public.actions (customer_key, action_type, recommendation_id)
  values (v_key, 'visit', v_rec)
  returning id into v_action;
  insert into public.visits (action_id, customer_key, visit_type)
  values (v_action, v_key, 'in_person');

  select status into v_status from public.recommendations where id = v_rec;
  if v_status <> 'acted' then
    perform pg_temp.as_postgres();
    raise exception 'T6 FAILED: action did not advance mission to acted (got %)', v_status;
  end if;

  update public.recommendations
     set status = 'closed', outcome = 'order_received'
   where id = v_rec;
  select status into v_status from public.recommendations where id = v_rec;
  if v_status <> 'closed' then
    perform pg_temp.as_postgres();
    raise exception 'T6 FAILED: close after survey did not stick';
  end if;

  -- Dismissal (the escape hatch) needs no survey.
  select r.id into v_rec from public.recommendations r
   where r.batch_id = v_batch and r.status = 'open'
   order by r.customer_key limit 1;
  update public.recommendations
     set status = 'dismissed', outcome = 'could_not_contact'
   where id = v_rec;
  perform pg_temp.as_postgres();

  if (select closed_count from public.mission_batch_progress where batch_id = v_batch) <> 1
     or (select dismissed_count from public.mission_batch_progress where batch_id = v_batch) <> 1 then
    raise exception 'T6 FAILED: progress view does not show 1 closed + 1 dismissed';
  end if;
  raise notice 'T6 ok (survey gate enforced; dismissal open; progress tracks)';

  ----------------------------------------------------------------
  -- T7: login_events is RPC-only again — direct insert fails,
  --     log_login() works.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);
  begin
    insert into public.login_events (user_id) values (u_rep);
    perform pg_temp.as_postgres();
    raise exception 'T7 FAILED: client inserted a login event directly';
  exception when sqlstate '42501' then
    null;
  end;
  perform public.log_login();
  perform pg_temp.as_postgres();
  if (select count(*) from public.login_events where user_id = u_rep) <> 1 then
    raise exception 'T7 FAILED: log_login() did not record the login';
  end if;
  raise notice 'T7 ok (login_events RPC-only)';

  ----------------------------------------------------------------
  -- T8: placeholder rep codes cannot be stamped on a profile,
  --     from any role.
  ----------------------------------------------------------------
  begin
    update public.profiles set sales_rep_key = 'WEB' where user_id = u_rep;
    raise exception 'T8 FAILED: placeholder rep key accepted on a profile';
  exception when others then
    if sqlerrm not like '%placeholder_rep_key%' then
      raise exception 'T8 FAILED: wrong error stamping placeholder: %', sqlerrm;
    end if;
  end;
  raise notice 'T8 ok (profile placeholder guard)';

  raise notice '--- ALL MISSION TESTS PASSED ---';
end;
$$;

rollback;
