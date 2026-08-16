/*============================================================================
  010_access_rules.sql — RLS assertions for the derived access model.

  TECH_STACK §3.5: "PRD acceptance criterion #1 is a security test, and it's
  the single most important test in the project — non-employee rep groups are
  seeing each other's dealer revenue if it fails."

  Runs entirely inside a transaction and ROLLS BACK. It creates throwaway auth
  users, so run it against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/010_access_rules.sql

  Every check raises an exception on failure, so a clean run that prints
  "ALL ACCESS TESTS PASSED" is the pass condition and any error is a failure.

  Fixtures are throwaway ERP rows seeded (and rolled back) by the test
  itself, same as 035/036/20260817_orders: a 12-account rep inside a
  3-rep / 30-account agency, plus two accounts on the real 'WEB'
  placeholder key. Earlier revisions pinned real ERP values instead
  ('TANY MCDO', 'MOUN STAT SPOR'), which read nicely but meant the single
  most important test in the project could only run against a loaded dev
  database — on the bare _local_harness.sql cluster the fixture lookups
  returned nothing and the run died on a null insert before the first
  assertion. Every expected count is still computed from the data at run
  time, so the file works unchanged on dev, where the seeded rows simply
  sit alongside the real book until rollback.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------
create temporary table t_fix (name text primary key, val text) on commit drop;

insert into t_fix (name, val) values
  ('rep_key',    'RLS REPA'),     -- an ordinary rep: 12 seeded customers
  ('vendor_id',  'RLS VENDOR'),   -- an agency: 3 reps, 30 seeded customers
  ('placeholder','WEB');          -- a REAL placeholder key (016/placeholder_rep_keys)

-- The agency: rep A belongs to it, so the group book strictly contains
-- (and exceeds) rep A's own book — what T7 asserts.
insert into erp.dim_sales_rep (sales_rep_key, vendor_id) values
  ('RLS REPA', 'RLS VENDOR'),
  ('RLS REPB', 'RLS VENDOR'),
  ('RLS REPC', 'RLS VENDOR');

-- 12 + 10 + 8 accounts across the agency's reps, plus two accounts riding
-- the live 'WEB' placeholder key (T2 must prove a placeholder derives
-- nothing even when the placeholder genuinely owns customers).
insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id,
   customer_type, active_flag)
select format('RLS-CUST-%s%s', b.rep_tag, lpad(g::text, 2, '0')),
       format('RLS-CUST-%s%s', b.rep_tag, lpad(g::text, 2, '0')),
       format('RLS %s Dealer %s', b.rep_tag, g),
       b.rep_key, 'RLS-DEALER', 'Y'
from (values ('A', 'RLS REPA', 12),
             ('B', 'RLS REPB', 10),
             ('C', 'RLS REPC',  8),
             ('W', 'WEB',       2)) as b(rep_tag, rep_key, n)
cross join lateral generate_series(1, b.n) g;

create temporary table t_expect (name text primary key, n int) on commit drop;
insert into t_expect
select 'rep_book', count(*) from erp.dim_customer
  where assigned_sales_rep_id = (select val from t_fix where name='rep_key');
insert into t_expect
select 'group_book', count(distinct c.customer_key)
  from erp.dim_sales_rep sr
  join erp.dim_customer c on c.assigned_sales_rep_id = sr.sales_rep_key
  where sr.vendor_id = (select val from t_fix where name='vendor_id');
insert into t_expect
select 'placeholder_book', count(*) from erp.dim_customer
  where assigned_sales_rep_id = (select val from t_fix where name='placeholder');
insert into t_expect select 'all_customers', count(*) from erp.dim_customer;

-- Throwaway users. The handle_new_user trigger creates each profile.
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',         '11111111-1111-4111-8111-111111111111'),
  ('principal',   '22222222-2222-4222-8222-222222222222'),
  ('nullkey',     '33333333-3333-4333-8333-333333333333'),
  ('placeholder', '44444444-4444-4444-8444-444444444444'),
  ('inactive',    '55555555-5555-4555-8555-555555555555'),
  ('admin',       '66666666-6666-4666-8666-666666666666');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@rls.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = (select val from t_fix where name='rep_key')
  where p.user_id = (select id from t_user where label='rep');
update public.profiles p set rep_group_vendor_id = (select val from t_fix where name='vendor_id')
  where p.user_id = (select id from t_user where label='principal');
-- 'nullkey' keeps both keys null: the §3.4 fail-open case.

-- The 016 guard (trg_profiles_placeholder_guard) refuses to stamp WEB on a
-- profile, which is the point of it. But T2 still has to prove that a row
-- ALREADY carrying a placeholder key derives nothing — rows like that predate
-- the guard and are exactly the case §3.4 is about. So assert the guard fires,
-- then build the legacy fixture the only way it can still exist: with the
-- trigger off. Asserting first means switching it off here can never quietly
-- mean the guard has gone missing.
do $$
begin
  begin
    update public.profiles p set sales_rep_key = (select val from t_fix where name='placeholder')
      where p.user_id = (select id from t_user where label='placeholder');
    raise exception 'T0 FAILED: the 016 placeholder guard let a WEB key onto a profile';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'placeholder_rep_key' then
      raise;   -- our own T0 failure, or something else entirely
    end if;
    raise notice 'T0 ok (guard rejected a placeholder rep key)';
  end;
end;
$$;

alter table public.profiles disable trigger trg_profiles_placeholder_guard;
update public.profiles p set sales_rep_key = (select val from t_fix where name='placeholder')
  where p.user_id = (select id from t_user where label='placeholder');
alter table public.profiles enable trigger trg_profiles_placeholder_guard;
update public.profiles p
  set sales_rep_key = (select val from t_fix where name='rep_key'), active = false
  where p.user_id = (select id from t_user where label='inactive');
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

-- A revoke on one of the rep's derived accounts, and a grant on one outside it.
create temporary table t_keys (label text primary key, customer_key text) on commit drop;
insert into t_keys
select 'revoked', customer_key from erp.dim_customer
 where assigned_sales_rep_id = (select val from t_fix where name='rep_key')
 order by customer_key limit 1;
insert into t_keys
select 'granted', customer_key from erp.dim_customer
 where assigned_sales_rep_id is distinct from (select val from t_fix where name='rep_key')
 order by customer_key limit 1;

insert into public.account_assignments (customer_key, user_id, access)
select (select customer_key from t_keys where label='revoked'),
       (select id from t_user where label='rep'), 'revoke';
insert into public.account_assignments (customer_key, user_id, access)
select (select customer_key from t_keys where label='granted'),
       (select id from t_user where label='rep'), 'grant';

--------------------------------------------------------------------------
-- Harness: run one assertion as a given user.
--------------------------------------------------------------------------
create or replace function pg_temp.assert_book(
  p_user uuid, p_label text, p_expected int
) returns void
language plpgsql
as $$
declare
  actual int;
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  execute 'set local role authenticated';
  select count(*) into actual from public.my_customer_keys();
  execute 'reset role';

  if actual <> p_expected then
    raise exception '% FAILED: expected % accounts, got %', p_label, p_expected, actual;
  end if;
  raise notice '% ok (% accounts)', p_label, actual;
end;
$$;

create or replace function pg_temp.assert_sees(
  p_user uuid, p_label text, p_key text, p_expected boolean
) returns void
language plpgsql
as $$
declare
  actual boolean;
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  execute 'set local role authenticated';
  select exists (select 1 from erp.dim_customer where customer_key = p_key)
    into actual;
  execute 'reset role';

  if actual <> p_expected then
    raise exception '% FAILED: expected visible=%, got % for key %',
      p_label, p_expected, actual, p_key;
  end if;
  raise notice '% ok', p_label;
end;
$$;

--------------------------------------------------------------------------
-- The assertions
--------------------------------------------------------------------------
do $$
declare
  u_rep         uuid := (select id from t_user where label='rep');
  u_principal   uuid := (select id from t_user where label='principal');
  u_nullkey     uuid := (select id from t_user where label='nullkey');
  u_placeholder uuid := (select id from t_user where label='placeholder');
  u_inactive    uuid := (select id from t_user where label='inactive');
  u_admin       uuid := (select id from t_user where label='admin');
  k_revoked     text := (select customer_key from t_keys where label='revoked');
  k_granted     text := (select customer_key from t_keys where label='granted');
  n_rep         int  := (select n from t_expect where name='rep_book');
  n_group       int  := (select n from t_expect where name='group_book');
  n_all         int  := (select n from t_expect where name='all_customers');
  n_placeholder int  := (select n from t_expect where name='placeholder_book');
  sample        text;
begin
  if n_rep < 10 or n_group < 10 or n_placeholder < 1 then
    raise exception 'Fixtures no longer match the data (rep=%, group=%, placeholder=%). Re-pin them.',
      n_rep, n_group, n_placeholder;
  end if;

  ----------------------------------------------------------------
  -- The two ways derived ownership fails open (TECH_STACK §3.4).
  -- Both fail silently and totally, so both are named cases.
  ----------------------------------------------------------------
  perform pg_temp.assert_book(u_nullkey, 'T1 null sales_rep_key sees nothing', 0);
  perform pg_temp.assert_book(u_placeholder,
    format('T2 placeholder rep key (WEB, %s live customers) sees nothing', n_placeholder), 0);

  ----------------------------------------------------------------
  -- Ordinary resolution. -1 revoked, +1 granted.
  ----------------------------------------------------------------
  perform pg_temp.assert_book(u_rep, 'T3 rep sees own book, minus revoke, plus grant',
                              n_rep - 1 + 1);
  perform pg_temp.assert_sees(u_rep, 'T4 revoke beats derive', k_revoked, false);
  perform pg_temp.assert_sees(u_rep, 'T5 grant adds an account outside the derived book',
                              k_granted, true);

  ----------------------------------------------------------------
  -- Principal: the group book, and strictly bigger than one member's.
  ----------------------------------------------------------------
  perform pg_temp.assert_book(u_principal, 'T6 principal sees the whole agency book', n_group);
  if n_group <= n_rep then
    raise exception 'T7 FAILED: group book (%) should exceed a single rep book (%)', n_group, n_rep;
  end if;
  raise notice 'T7 ok (group % > rep %)', n_group, n_rep;

  ----------------------------------------------------------------
  -- Deactivation kills the derived branches.
  ----------------------------------------------------------------
  perform pg_temp.assert_book(u_inactive, 'T8 inactive profile derives nothing', 0);

  ----------------------------------------------------------------
  -- Admin sees everything; RLS is what proves it, not the function.
  ----------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (select count(*) from erp.dim_customer) <> n_all then
    execute 'reset role';
    raise exception 'T9 FAILED: admin should see all % customers', n_all;
  end if;
  execute 'reset role';
  raise notice 'T9 ok (admin sees all % customers)', n_all;

  ----------------------------------------------------------------
  -- Isolation: the rep's RLS-filtered view of erp.dim_customer must equal
  -- their book exactly, and must not contain another rep group's account.
  ----------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', u_rep, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (select count(*) from erp.dim_customer) <> n_rep then
    execute 'reset role';
    raise exception 'T10 FAILED: rep RLS row count disagrees with my_customer_keys()';
  end if;
  -- Anti-drift: has_account_access() and my_customer_keys() must never
  -- disagree. They share one implementation now; this proves it stays true.
  if exists (
    select 1 from erp.dim_customer c
    where public.has_account_access(c.customer_key)
      <> (c.customer_key in (select public.my_customer_keys()))
    limit 1
  ) then
    execute 'reset role';
    raise exception 'T11 FAILED: has_account_access() disagrees with my_customer_keys()';
  end if;
  execute 'reset role';
  raise notice 'T10/T11 ok (rep sees exactly % rows; access functions agree)', n_rep;

  ----------------------------------------------------------------
  -- Cross-tenant probe (PRD acceptance criterion #1): pick an account the
  -- rep does NOT own and confirm a direct lookup by ID returns nothing.
  ----------------------------------------------------------------
  select c.customer_key into sample
  from erp.dim_customer c
  where c.assigned_sales_rep_id is not null
    and c.assigned_sales_rep_id <> (select val from t_fix where name='rep_key')
    and c.customer_key <> k_granted
  order by c.customer_key
  limit 1;

  perform pg_temp.assert_sees(u_rep,
    'T12 querying another rep''s account by ID returns nothing', sample, false);

  raise notice '--- ALL ACCESS TESTS PASSED ---';
end;
$$;

rollback;
