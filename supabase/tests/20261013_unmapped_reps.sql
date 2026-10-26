/*============================================================================
  20261013_unmapped_reps.sql — assertions for public.admin_unmapped_reps().

  Companion to 20261013170000_unmapped_reps.sql. Proves that the list is
  admin-only, that a rep drops off it the moment a profile carries their
  code, and that the two "you can't create this one" signals (placeholder,
  email already on a profile) are set.

  Runs entirely inside a transaction and ROLLS BACK. Self-contained
  fixtures, so it runs on the local harness as well as against dev.

      psql "$DATABASE_URL" -f supabase/tests/20261013_unmapped_reps.sql

  Any error is a failure; a clean run printing "ALL UNMAPPED-REP TESTS
  PASSED" is the pass condition.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures: one admin, one rep, three ERP reps.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('admin', 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1'),
  ('rep',   'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@unmapped.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set role = 'admin', full_name = 'Test Admin'
  where user_id = (select id from t_user where label = 'admin');
update public.profiles set sales_rep_key = 'UM-MAPPED', full_name = 'Mapped Rep'
  where user_id = (select id from t_user where label = 'rep');

-- MAPPED is on the rep's profile. FREE has nobody. TAKEN's email is already
-- the admin's. The ETL flags HOLD as a placeholder. Emails arrive from the
-- ERP with whatever case and padding the ERP felt like.
insert into erp.dim_sales_rep
  (sales_rep_key, sales_rep_name, sales_rep_email, vendor_id, sales_rep_type, is_placeholder_rep)
values
  ('UM-MAPPED', 'MAPPED REP',  'mapped@unmapped.test',   'UM-AGENCY', 'CONTRACT', false),
  ('UM-FREE',   'FREE REP',    '  Free@Unmapped.TEST ',  'UM-AGENCY', 'CONTRACT', false),
  ('UM-TAKEN',  'TAKEN REP',   'admin@unmapped.test',    null,        'HOUSE',    false),
  ('UM-NOMAIL', 'NO MAIL REP', '',                       null,        'EMPL',     false),
  ('UM-HOLD',   'HOLDING PEN', null,                     null,        'HOUSE',    true);

insert into erp.dim_customer (customer_key, customer_id, customer_name, assigned_sales_rep_id) values
  ('UM-C1', 'UM-C1', 'Free Dealer A',   'UM-FREE'),
  ('UM-C2', 'UM-C2', 'Free Dealer B',   'UM-FREE'),
  ('UM-C3', 'UM-C3', 'Mapped Dealer',   'UM-MAPPED');

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

/** The test rows the caller gets back, as "key:email:customers:placeholder:taken". */
create or replace function pg_temp.listing(p_user uuid) returns text[]
language plpgsql as $$
declare out text[];
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select array(
    select r.sales_rep_key || ':' || coalesce(r.sales_rep_email, '-') || ':'
        || r.customer_count || ':' || r.is_placeholder || ':'
        || coalesce(r.email_profile_name, '-')
    from public.admin_unmapped_reps() r
    where r.sales_rep_key like 'UM-%'
    order by r.sales_rep_key
  ) into out;
  execute 'reset role';
  return out;
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
  want    text[];
begin
  -- T1: a rep gets nothing — not an error, not a partial list, nothing.
  got := pg_temp.listing(v_rep);
  if coalesce(array_length(got, 1), 0) <> 0 then
    raise exception 'T1 FAIL: a rep can read the unmapped list: %', got;
  end if;

  -- T2: the admin sees every unmapped test rep, with the derived columns.
  got  := pg_temp.listing(v_admin);
  want := array[
    'UM-FREE:free@unmapped.test:2:false:-',
    'UM-HOLD:-:0:true:-',
    'UM-NOMAIL:-:0:false:-',
    'UM-TAKEN:admin@unmapped.test:0:false:Test Admin'
  ];
  if got <> want then
    raise exception 'T2 FAIL: admin listing % (wanted %)', got, want;
  end if;

  -- T3: mapping the code on a profile removes the rep from the list.
  update public.profiles set sales_rep_key = 'UM-FREE' where user_id = v_rep;
  got := pg_temp.listing(v_admin);
  if 'UM-FREE:free@unmapped.test:2:false:-' = any (got) then
    raise exception 'T3 FAIL: UM-FREE is still listed after being mapped: %', got;
  end if;
  if not ('UM-MAPPED:mapped@unmapped.test:1:false:-' = any (got)) then
    raise exception 'T3 FAIL: UM-MAPPED should be listed once its profile moved: %', got;
  end if;

  -- T4: a deactivated admin is not an admin.
  update public.profiles set active = false where user_id = v_admin;
  got := pg_temp.listing(v_admin);
  if coalesce(array_length(got, 1), 0) <> 0 then
    raise exception 'T4 FAIL: an inactive admin can read the unmapped list: %', got;
  end if;

  -- T5: anon holds no execute on the function.
  if has_function_privilege('anon', 'public.admin_unmapped_reps()', 'execute') then
    raise exception 'T5 FAIL: anon can execute admin_unmapped_reps()';
  end if;

  raise notice 'ALL UNMAPPED-REP TESTS PASSED';
end;
$$;

rollback;
