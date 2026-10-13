/*============================================================================
  20261013_call_list.sql — assertions for migration 20261013130000_call_list.sql:
  public.call_list_feedback and the feature.quick_log flag.

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_call_list.sql

  A clean run prints "ALL CALL LIST TESTS PASSED".

  What it proves: a rep reacts only to accounts in their own book and only
  as themselves; two reps never see each other's reactions; an admin reads
  all of them; an admin viewing as a rep reads that rep's and cannot write;
  anon holds nothing; the CHECKs keep the vocabulary closed.
============================================================================*/

begin;

\set ON_ERROR_STOP on

-- The local grants harness hands `authenticated` every DML privilege on every
-- table, which would let T9 pass for the wrong reason. Restate the
-- migration's exact grant for the life of this transaction.
revoke all on public.call_list_feedback from authenticated;
grant select, insert, delete on public.call_list_feedback to authenticated;

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-7171-4171-8171-717171717171'),
  ('rep_b', 'bbbbbbbb-7272-4272-8272-727272727272'),
  ('admin', 'cccccccc-7373-4373-8373-737373737373');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@calllist.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'CL REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'CL REPB'
  where user_id = (select id from t_user where label='rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label='admin');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('CL-A1', 'CL-A1', 'Call List Dealer A1', 'CL REPA', 'Y'),
       ('CL-A2', 'CL-A2', 'Call List Dealer A2', 'CL REPA', 'Y'),
       ('CL-B1', 'CL-B1', 'Call List Dealer B1', 'CL REPB', 'Y');

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

create or replace function pg_temp.be_nobody() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

/** What RLS lets this user read, as sorted "key:reaction" strings. */
create or replace function pg_temp.seen(p_user uuid) returns text[]
language plpgsql as $$
declare out text[];
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select array(select customer_key || ':' || reaction
               from public.call_list_feedback
               where customer_key like 'CL-%'
               order by customer_key, reaction) into out;
  execute 'reset role';
  return out;
end;
$$;

create or replace function pg_temp.assert_eq(
  p_label text, p_actual anyelement, p_expected anyelement
) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception '% FAILED: expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice '% ok (%)', p_label, p_actual;
end;
$$;

--------------------------------------------------------------------------
-- Shape: RLS on, the view-as trigger attached, the index, the flag.
--------------------------------------------------------------------------
do $$
begin
  perform pg_temp.assert_eq('T0a RLS enabled',
    (select rowsecurity from pg_tables
      where schemaname = 'public' and tablename = 'call_list_feedback'),
    true);
  perform pg_temp.assert_eq('T0b view-as read-only trigger attached',
    exists (select 1 from pg_trigger
             where tgname = 'trg_call_list_feedback_no_write_while_viewing_as'
               and not tgisinternal),
    true);
  perform pg_temp.assert_eq('T0c (user_id, created_at desc) index',
    exists (select 1 from pg_indexes
             where schemaname = 'public' and tablename = 'call_list_feedback'
               and indexname = 'idx_call_list_feedback_user'),
    true);
  perform pg_temp.assert_eq('T0d feature.quick_log seeded OFF',
    (select enabled from public.app_settings where setting_key = 'feature.quick_log'),
    false);
end;
$$;

--------------------------------------------------------------------------
-- Writes and reads
--------------------------------------------------------------------------
do $$
declare
  u_a     uuid := (select id from t_user where label='rep_a');
  u_b     uuid := (select id from t_user where label='rep_b');
  u_admin uuid := (select id from t_user where label='admin');
  n       int;
begin
  -- T1: a rep reacts to an account in their book. user_id comes from the
  -- column default, the way the client sends it.
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';
  insert into public.call_list_feedback (customer_key, reaction)
  values ('CL-A1', 'on_it');
  insert into public.call_list_feedback (customer_key, reaction, reason)
  values ('CL-A2', 'not_relevant', 'seasonal');
  execute 'reset role';
  perform pg_temp.assert_eq('T1 rep A''s reactions land under rep A',
    (select array_agg(distinct user_id) from public.call_list_feedback
      where customer_key like 'CL-A%'),
    array[u_a]);

  -- T2: not someone else's account.
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';
  begin
    insert into public.call_list_feedback (customer_key, reaction)
    values ('CL-B1', 'handled');
    execute 'reset role';
    raise exception 'T2 FAILED: rep A reacted to rep B''s account';
  exception when sqlstate '42501' then
    raise notice 'T2 ok (another rep''s account refused: %)', sqlerrm;
  end;
  execute 'reset role';

  -- T3: not as someone else.
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';
  begin
    insert into public.call_list_feedback (user_id, customer_key, reaction)
    values (u_b, 'CL-A1', 'handled');
    execute 'reset role';
    raise exception 'T3 FAILED: rep A wrote a reaction as rep B';
  exception when sqlstate '42501' then
    raise notice 'T3 ok (writing as another user refused: %)', sqlerrm;
  end;
  execute 'reset role';

  perform pg_temp.be(u_b);
  execute 'set local role authenticated';
  insert into public.call_list_feedback (customer_key, reaction)
  values ('CL-B1', 'handled');
  execute 'reset role';

  -- T4/T5: isolation between the two reps.
  perform pg_temp.assert_eq('T4 rep A reads only their own',
    pg_temp.seen(u_a), array['CL-A1:on_it', 'CL-A2:not_relevant']);
  perform pg_temp.assert_eq('T5 rep B reads only their own',
    pg_temp.seen(u_b), array['CL-B1:handled']);

  -- T6: the admin reads everyone's.
  perform pg_temp.assert_eq('T6 admin reads all',
    pg_temp.seen(u_admin), array['CL-A1:on_it', 'CL-A2:not_relevant', 'CL-B1:handled']);

  -- T7: rep B cannot undo rep A's reaction (the row is simply not theirs).
  perform pg_temp.be(u_b);
  execute 'set local role authenticated';
  delete from public.call_list_feedback where customer_key = 'CL-A1';
  get diagnostics n = row_count;
  execute 'reset role';
  perform pg_temp.assert_eq('T7 another rep''s delete touches nothing', n, 0);

  -- T8: rep A can undo their own.
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';
  delete from public.call_list_feedback where customer_key = 'CL-A1';
  get diagnostics n = row_count;
  execute 'reset role';
  perform pg_temp.assert_eq('T8 own undo deletes the row', n, 1);

  -- T9: no update path at all — a changed mind is a new row.
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';
  begin
    update public.call_list_feedback set reaction = 'handled'
     where customer_key = 'CL-A2';
    execute 'reset role';
    raise exception 'T9 FAILED: an update went through';
  exception when insufficient_privilege then
    raise notice 'T9 ok (no update privilege: %)', sqlerrm;
  end;
  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- CHECK constraints
--------------------------------------------------------------------------
do $$
declare
  u_a uuid := (select id from t_user where label='rep_a');
begin
  perform pg_temp.be(u_a);
  execute 'set local role authenticated';

  begin
    insert into public.call_list_feedback (customer_key, reaction)
    values ('CL-A1', 'ignored');
    raise exception 'T10 FAILED: an unknown reaction was stored';
  exception when check_violation then
    raise notice 'T10 ok (unknown reaction refused)';
  end;

  begin
    insert into public.call_list_feedback (customer_key, reaction, reason)
    values ('CL-A1', 'not_relevant', 'too_busy');
    raise exception 'T11 FAILED: an unknown reason was stored';
  exception when check_violation then
    raise notice 'T11 ok (unknown reason refused)';
  end;

  begin
    insert into public.call_list_feedback (customer_key, reaction, reason)
    values ('CL-A1', 'on_it', 'seasonal');
    raise exception 'T12 FAILED: a reason was stored on a reaction that takes none';
  exception when check_violation then
    raise notice 'T12 ok (reason only with not_relevant)';
  end;

  begin
    insert into public.call_list_feedback (customer_key, reaction, note)
    values ('CL-A1', 'handled', repeat('x', 501));
    raise exception 'T13 FAILED: a 501-character note was stored';
  exception when check_violation then
    raise notice 'T13 ok (note capped at 500)';
  end;

  -- Every legal reason still goes in.
  insert into public.call_list_feedback (customer_key, reaction, reason)
  select 'CL-A1', 'not_relevant', r
  from unnest(array['seasonal','store_closed','buys_elsewhere','wrong_data','other']) r;
  raise notice 'T14 ok (all five reasons accepted)';

  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- Admin viewing as rep A: reads rep A's reactions, writes nothing.
--------------------------------------------------------------------------
do $$
declare
  u_a     uuid := (select id from t_user where label='rep_a');
  u_admin uuid := (select id from t_user where label='admin');
begin
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(u_a);
  execute 'reset role';

  perform pg_temp.assert_eq('T15 viewing as rep A reads rep A''s reactions only',
    (select array_agg(distinct x) from unnest(pg_temp.seen(u_admin)) x),
    array['CL-A1:not_relevant', 'CL-A2:not_relevant']);

  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  begin
    insert into public.call_list_feedback (customer_key, reaction)
    values ('CL-A1', 'on_it');
    execute 'reset role';
    raise exception 'T16 FAILED: a reaction landed while viewing as a rep';
  exception when sqlstate '42501' then
    raise notice 'T16 ok (write blocked while viewing as: %)', sqlerrm;
  end;
  execute 'reset role';

  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.stop_impersonation();
  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- anon: no grant, no rows.
--------------------------------------------------------------------------
do $$
begin
  perform pg_temp.assert_eq('T17 anon holds no grant',
    (select count(*)::int from information_schema.role_table_grants
      where table_schema = 'public' and table_name = 'call_list_feedback'
        and grantee = 'anon'),
    0);

  perform pg_temp.be_nobody();
  execute 'set local role anon';
  begin
    perform 1 from public.call_list_feedback limit 1;
    execute 'reset role';
    raise exception 'T18 FAILED: anon read call_list_feedback';
  exception when insufficient_privilege then
    raise notice 'T18 ok (anon refused: %)', sqlerrm;
  end;
  execute 'reset role';

  raise notice '--- ALL CALL LIST TESTS PASSED ---';
end;
$$;

rollback;
