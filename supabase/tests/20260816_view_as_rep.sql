/*============================================================================
  20260816_view_as_rep.sql — assertions for admin "view as rep".

  Companion to 010_access_rules.sql. That file proves the access model is
  right for ordinary users; this one proves that pointing an admin at a rep
  reproduces that rep's answers exactly, that it is read-only, and that the
  admin can always get back out.

  Runs entirely inside a transaction and ROLLS BACK.

      psql "$DATABASE_URL" -f supabase/tests/20260816_view_as_rep.sql

  Unlike 010 this file builds its OWN erp.dim_customer / dim_sales_rep rows
  rather than pinning to production values. The rules under test are about
  identity resolution, not about the shape of the book, and self-contained
  fixtures mean it runs on an empty local harness (supabase/tests/_local_harness.sql)
  as well as against dev.

  Any error is a failure; a clean run printing "ALL VIEW-AS TESTS PASSED"
  is the pass condition.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures: two agencies, one house account, six users.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('admin',      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('admin2',     'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('rep',        'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  ('principal',  'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  ('otherrep',   'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  ('inactive',   'ffffffff-ffff-4fff-8fff-ffffffffffff');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@viewas.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

-- Two reps in agency ACME, one rep in agency OTHER.
insert into erp.dim_sales_rep (sales_rep_key, sales_rep_name, vendor_id) values
  ('VA-REP1', 'View As Rep One',   'ACME-AGENCY'),
  ('VA-REP2', 'View As Rep Two',   'ACME-AGENCY'),
  ('VA-REP3', 'View As Rep Three', 'OTHER-AGENCY');

-- 3 accounts on REP1, 2 on REP2, 2 on REP3, 1 unassigned house account.
insert into erp.dim_customer (customer_key, customer_id, customer_name, assigned_sales_rep_id) values
  ('VA-C1', 'VA-C1', 'Rep One Dealer A',   'VA-REP1'),
  ('VA-C2', 'VA-C2', 'Rep One Dealer B',   'VA-REP1'),
  ('VA-C3', 'VA-C3', 'Rep One Dealer C',   'VA-REP1'),
  ('VA-C4', 'VA-C4', 'Rep Two Dealer A',   'VA-REP2'),
  ('VA-C5', 'VA-C5', 'Rep Two Dealer B',   'VA-REP2'),
  ('VA-C6', 'VA-C6', 'Other Agency Dealer','VA-REP3'),
  ('VA-C7', 'VA-C7', 'Other Agency Two',   'VA-REP3'),
  ('VA-C8', 'VA-C8', 'House Account',      null);

update public.profiles set role = 'admin' where user_id = (select id from t_user where label='admin');
update public.profiles set role = 'admin' where user_id = (select id from t_user where label='admin2');
update public.profiles set sales_rep_key = 'VA-REP1'
  where user_id = (select id from t_user where label='rep');
update public.profiles set rep_group_vendor_id = 'ACME-AGENCY'
  where user_id = (select id from t_user where label='principal');
update public.profiles set sales_rep_key = 'VA-REP3'
  where user_id = (select id from t_user where label='otherrep');
update public.profiles set sales_rep_key = 'VA-REP2', active = false
  where user_id = (select id from t_user where label='inactive');

-- The target rep carries BOTH kinds of override, so "the admin sees what the
-- rep sees" has to mean the overridden book and not the derived one.
insert into public.account_assignments (customer_key, user_id, access) values
  ('VA-C3', (select id from t_user where label='rep'), 'revoke'),
  ('VA-C8', (select id from t_user where label='rep'), 'grant');

-- An override on the ADMIN, which must never leak into the rep's view.
insert into public.account_assignments (customer_key, user_id, access) values
  ('VA-C6', (select id from t_user where label='admin'), 'grant');

-- Personal-scope rows, one per identity, so "whose follow-up list am I
-- looking at" has three distinguishable answers.
insert into public.tasks (customer_key, user_id, title) values
  ('VA-C1', (select id from t_user where label='rep'),      'REP TASK'),
  ('VA-C6', (select id from t_user where label='otherrep'), 'OTHER TASK'),
  (null,    (select id from t_user where label='admin'),    'ADMIN TASK');

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

/* Back to nobody: fixture edits below must not be seen as an impersonating
   admin, or the read-only trigger blocks them. */
create or replace function pg_temp.be_nobody() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

/** The caller's resolved book, as a sorted array — the whole assertion in one value. */
create or replace function pg_temp.book(p_user uuid) returns text[]
language plpgsql as $$
declare out text[];
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select array(select k from public.my_customer_keys() k order by k) into out;
  execute 'reset role';
  return out;
end;
$$;

/** What RLS actually lets them read — the number that matters, not the function. */
create or replace function pg_temp.visible(p_user uuid) returns text[]
language plpgsql as $$
declare out text[];
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select array(select customer_key from erp.dim_customer
               where customer_key like 'VA-%' order by customer_key) into out;
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
-- The assertions
--------------------------------------------------------------------------
do $$
declare
  u_admin     uuid := (select id from t_user where label='admin');
  u_admin2    uuid := (select id from t_user where label='admin2');
  u_rep       uuid := (select id from t_user where label='rep');
  u_principal uuid := (select id from t_user where label='principal');
  u_other     uuid := (select id from t_user where label='otherrep');
  u_inactive  uuid := (select id from t_user where label='inactive');
  rep_book    text[];
  all_keys    text[] := array['VA-C1','VA-C2','VA-C3','VA-C4','VA-C5','VA-C6','VA-C7','VA-C8'];
  ok          boolean;
begin
  ----------------------------------------------------------------
  -- Baseline: nothing about the ordinary paths may have moved.
  -- VA-C3 revoked, VA-C8 granted, so the rep's book is C1, C2, C8.
  ----------------------------------------------------------------
  rep_book := pg_temp.book(u_rep);
  perform pg_temp.assert_eq('T1 rep resolves own book minus revoke plus grant',
                            rep_book, array['VA-C1','VA-C2','VA-C8']);

  -- The control for T12. The read-only guard is a trigger on every RLS table
  -- in `public`, so "writes are blocked while impersonating" only means
  -- something alongside proof that writes are NOT blocked otherwise —
  -- without this, a guard that refused everybody would pass the suite.
  perform pg_temp.be(u_rep);
  execute 'set local role authenticated';
  insert into public.notes (customer_key, body, created_by)
  values ('VA-C1', 'ordinary rep write', u_rep);
  execute 'reset role';
  raise notice 'T1b ok (an ordinary rep write still lands)';
  perform pg_temp.assert_eq('T2 admin sees every account',
                            pg_temp.visible(u_admin), all_keys);
  perform pg_temp.assert_eq('T3 rep sees exactly their book',
                            pg_temp.visible(u_rep), rep_book);

  ----------------------------------------------------------------
  -- The feature. An impersonating admin must be indistinguishable
  -- from the rep — including the rep's grant/revoke overrides, and
  -- excluding the admin's own.
  ----------------------------------------------------------------
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(u_rep);
  execute 'reset role';

  perform pg_temp.assert_eq('T4 impersonating admin resolves the rep''s exact book',
                            pg_temp.book(u_admin), rep_book);
  perform pg_temp.assert_eq('T5 impersonating admin READS the rep''s exact rows',
                            pg_temp.visible(u_admin), rep_book);

  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform pg_temp.assert_eq('T6 is_admin() is false while viewing as a rep',
                            public.is_admin(), false);
  perform pg_temp.assert_eq('T7 is_real_admin() stays true (the way out)',
                            public.is_real_admin(), true);
  perform pg_temp.assert_eq('T8 acting_as_user_id() resolves the target',
                            public.acting_as_user_id(), u_rep);
  -- The single most important line in this file: the cross-tenant probe from
  -- 010's T12, but for an admin who is supposed to be scoped down.
  perform pg_temp.assert_eq('T9 another agency''s account is invisible',
                            exists (select 1 from erp.dim_customer where customer_key = 'VA-C6'),
                            false);
  perform pg_temp.assert_eq('T10 the rep''s revoke applies to the admin too',
                            exists (select 1 from erp.dim_customer where customer_key = 'VA-C3'),
                            false);
  perform pg_temp.assert_eq('T11 has_account_access() agrees with the book',
                            public.has_account_access('VA-C1') and not public.has_account_access('VA-C4'),
                            true);
  -- Personal scope, not just account scope: an admin working out why a rep's
  -- Today screen looks the way it does has to see the REP's follow-ups. Their
  -- own must not bleed in, and neither must anyone else's.
  perform pg_temp.assert_eq('T11b the rep''s task list, not the admin''s',
                            array(select title from public.tasks order by title),
                            array['REP TASK']);
  execute 'reset role';

  ----------------------------------------------------------------
  -- Read-only, enforced by the database and not by the UI.
  ----------------------------------------------------------------
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  begin
    insert into public.notes (customer_key, body, created_by)
    values ('VA-C1', 'should never land', u_admin);
    execute 'reset role';
    raise exception 'T12 FAILED: a write landed while viewing as a rep';
  exception when sqlstate '42501' then
    raise notice 'T12 ok (write blocked: %)', sqlerrm;
  end;
  execute 'reset role';

  ----------------------------------------------------------------
  -- Switching targets, and the way out.
  ----------------------------------------------------------------
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(u_principal);
  execute 'reset role';
  -- The principal rolls up both ACME reps: C1..C5, minus nothing.
  perform pg_temp.assert_eq('T13 switching targets re-resolves to the group book',
                            pg_temp.book(u_admin),
                            array['VA-C1','VA-C2','VA-C3','VA-C4','VA-C5']);

  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.stop_impersonation();       -- gated on is_real_admin(), not is_admin()
  perform pg_temp.assert_eq('T14 stop restores admin', public.is_admin(), true);
  perform pg_temp.assert_eq('T14b …including their own follow-up list',
                            array(select title from public.tasks order by title),
                            array['ADMIN TASK','OTHER TASK','REP TASK']);  -- admin sees all
  -- …and the write guard lifts with it, on the same connection that was
  -- refused at T12.
  insert into public.notes (customer_key, body, created_by)
  values ('VA-C4', 'admin write after exit', u_admin);
  raise notice 'T14c ok (writes work again after exit)';
  execute 'reset role';
  perform pg_temp.assert_eq('T15 admin sees everything again',
                            pg_temp.visible(u_admin), all_keys);

  ----------------------------------------------------------------
  -- Who may do this at all.
  ----------------------------------------------------------------
  perform pg_temp.be(u_rep);
  execute 'set local role authenticated';
  begin
    perform public.start_impersonation(u_other);
    execute 'reset role';
    raise exception 'T16 FAILED: a rep impersonated another rep';
  exception when sqlstate '42501' then
    raise notice 'T16 ok (rep refused: %)', sqlerrm;
  end;
  execute 'reset role';
  perform pg_temp.assert_eq('T17 the refused attempt left no state',
                            pg_temp.book(u_rep), rep_book);

  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  begin
    perform public.start_impersonation(u_inactive);
    execute 'reset role';
    raise exception 'T18 FAILED: impersonated a deactivated profile';
  exception when sqlstate '22023' then
    raise notice 'T18 ok (deactivated target refused: %)', sqlerrm;
  end;
  execute 'reset role';

  ----------------------------------------------------------------
  -- Impersonating another ADMIN is honest about it: you asked to see
  -- what they see, and what they see is everything.
  ----------------------------------------------------------------
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(u_admin2);
  perform pg_temp.assert_eq('T19 viewing as another admin keeps admin scope',
                            public.is_admin(), true);
  execute 'reset role';
  perform pg_temp.assert_eq('T20 …and still sees every account',
                            pg_temp.visible(u_admin), all_keys);

  raise notice '--- ALL VIEW-AS TESTS PASSED (part 1) ---';
end;
$$;

--------------------------------------------------------------------------
-- The ETL and the nightly recommendation job run as service_role with no
-- JWT at all. auth.uid() is null there, so no impersonation row can match
-- and the step-11 trigger must be inert — a guard that stalled the nightly
-- load would be a far more expensive bug than the one it prevents.
--------------------------------------------------------------------------
do $$
declare
  -- Resolved BEFORE the role switch: pg_temp is not readable as service_role.
  u_admin uuid := (select id from t_user where label='admin');
begin
  perform pg_temp.be_nobody();
  execute 'set local role service_role';
  insert into public.notes (customer_key, body, created_by)
  values ('VA-C6', 'service_role write', u_admin);
  execute 'reset role';
  raise notice 'T27 ok (service_role writes are untouched by the guard)';
exception when others then
  execute 'reset role';
  raise exception 'T27 FAILED: the read-only guard caught service_role: %', sqlerrm;
end;
$$;

--------------------------------------------------------------------------
-- Expiry and mid-session deactivation, which need fixture writes between
-- assertions and so cannot sit inside the block above (the read-only
-- trigger would refuse them while an impersonation row is live).
--------------------------------------------------------------------------
select pg_temp.be_nobody();

update public.impersonation
   set target_user_id = (select id from t_user where label='rep'),
       expires_at     = now() - interval '1 minute'
 where admin_user_id = (select id from t_user where label='admin');

do $$
declare
  u_admin  uuid := (select id from t_user where label='admin');
  all_keys text[] := array['VA-C1','VA-C2','VA-C3','VA-C4','VA-C5','VA-C6','VA-C7','VA-C8'];
begin
  -- An admin who closed the tab yesterday comes back to their own portal,
  -- not to a mysteriously empty one.
  perform pg_temp.assert_eq('T21 an expired row is ignored',
                            pg_temp.visible(u_admin), all_keys);
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform pg_temp.assert_eq('T22 …and the admin is an admin again',
                            public.is_admin(), true);
  execute 'reset role';
end;
$$;

select pg_temp.be_nobody();

update public.impersonation
   set expires_at = now() + interval '1 hour'
 where admin_user_id = (select id from t_user where label='admin');
update public.profiles set active = false
 where user_id = (select id from t_user where label='rep');

do $$
declare
  u_admin uuid := (select id from t_user where label='admin');
  u_rep   uuid := (select id from t_user where label='rep');
begin
  -- The direction this must fail. Deactivating the target mid-session must
  -- scope the admin DOWN to whatever that rep can now see, never pop them
  -- back up to everything.
  --
  -- Asserted against the rep's own answer rather than a literal, because
  -- what a deactivated rep sees is not nothing: deactivation kills the
  -- derived branches of my_customer_keys() but not an explicit grant row
  -- (see the note on §6 of the migration — that is 010's behaviour, left
  -- deliberately unchanged). Comparing the two answers keeps this test
  -- honest about fidelity instead of pinning a constant that would have to
  -- be re-guessed if the grant rules ever move.
  perform pg_temp.assert_eq('T23 a deactivated target scopes DOWN to what that rep sees',
                            pg_temp.visible(u_admin), pg_temp.visible(u_rep));
  perform pg_temp.assert_eq('T23b …which is the grant only, not the whole company',
                            pg_temp.visible(u_admin), array['VA-C8']);
  perform pg_temp.be(u_admin);
  execute 'set local role authenticated';
  perform pg_temp.assert_eq('T24 …and does not restore admin rights',
                            public.is_admin(), false);
  perform pg_temp.assert_eq('T25 …but the way out still works',
                            public.is_real_admin(), true);
  perform public.stop_impersonation();
  perform pg_temp.assert_eq('T26 …and did', public.is_admin(), true);
  execute 'reset role';

  raise notice '--- ALL VIEW-AS TESTS PASSED ---';
end;
$$;

rollback;
