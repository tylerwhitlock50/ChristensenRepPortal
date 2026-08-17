/*============================================================================
  20260816_admin_reporting.sql — assertions for the admin Reports rollups
  (migration 20260816120000): v_channel_performance and
  v_rep_group_performance.

  Same harness rules as 010_access_rules.sql / 024_intel_views.sql: runs in a
  transaction and ROLLS BACK, creates throwaway auth users, run against dev —
  never prod.

      psql "$DATABASE_URL" -f supabase/tests/20260816_admin_reporting.sql

  A clean run prints "ALL ADMIN REPORTING TESTS PASSED"; any error is a
  failure.

  What is being protected here:
    - the two rollups reconcile with each other AND with the account-grain
      view every other surface reads, so no admin ever compares a channel
      total to an account list and finds a gap;
    - inactive and internal accounts stay out of both;
    - security_invoker really is the territory filter — a rep sums their own
      book, an empty-book user sums nothing, and neither errors.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures — same pinned book as 010 / 024.
--------------------------------------------------------------------------
create temporary table t_fix (name text primary key, val text) on commit drop;
insert into t_fix (name, val) values
  ('rep_key', 'TANY MCDO');

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-4444-4444-8444-444444444444'),
  ('other', 'bbbbbbbb-5555-4555-8555-555555555555'),
  ('admin', 'cccccccc-6666-4666-8666-666666666666');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@reports.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = (select val from t_fix where name='rep_key')
  where p.user_id = (select id from t_user where label='rep');
-- 'other' keeps null keys: an authenticated user with an EMPTY book.
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

--------------------------------------------------------------------------
-- Superuser recomputation of the whole company and of the rep's own book,
-- straight from the base tables on the documented territory definition.
--------------------------------------------------------------------------
create temporary table t_expect (name text primary key, v numeric) on commit drop;

insert into t_expect
select 'company_revenue_ytd', coalesce(sum(a.revenue_ytd), 0)
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

insert into t_expect
select 'company_accounts', count(*)
from erp.dim_customer c
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

insert into t_expect
select 'rep_revenue_ytd', coalesce(sum(a.revenue_ytd), 0)
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.assigned_sales_rep_id = (select val from t_fix where name='rep_key')
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

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

create or replace function pg_temp.as_super() returns void
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
  u_rep   uuid := (select id from t_user where label='rep');
  u_other uuid := (select id from t_user where label='other');
  u_admin uuid := (select id from t_user where label='admin');
  n int;
  v numeric;
  v2 numeric;
  v_company numeric := (select e.v from t_expect e where e.name='company_revenue_ytd');
  n_company numeric := (select e.v from t_expect e where e.name='company_accounts');
  v_rep     numeric := (select e.v from t_expect e where e.name='rep_revenue_ytd');
begin
  ----------------------------------------------------------------
  -- T1: an admin's channel rollup IS the company, to the dollar.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_admin);

  select coalesce(sum(revenue_ytd), 0) into v from public.v_channel_performance;
  if abs(v - v_company) > 1 then       -- rounding tolerance
    raise exception 'T1 FAILED: channel revenue % <> company %', v, v_company;
  end if;
  raise notice 'T1 ok (channel rollup = company revenue: %)', v;

  select coalesce(sum(accounts), 0) into v from public.v_channel_performance;
  if v <> n_company then
    raise exception 'T1b FAILED: channel accounts % <> company %', v, n_company;
  end if;
  raise notice 'T1b ok (channel rollup = % accounts)', v;

  ----------------------------------------------------------------
  -- T2: the two rollups cut the SAME book. If one ever drops accounts
  -- (an unmatched rep code, a null vendor) this is the test that catches
  -- it — the whole point of the "(No rep group)" bucket.
  ----------------------------------------------------------------
  select coalesce(sum(revenue_ytd), 0) into v  from public.v_channel_performance;
  select coalesce(sum(revenue_ytd), 0) into v2 from public.v_rep_group_performance;
  if abs(v - v2) > 1 then
    raise exception 'T2 FAILED: channel revenue % <> rep-group revenue %', v, v2;
  end if;

  select coalesce(sum(accounts), 0) into v  from public.v_channel_performance;
  select coalesce(sum(accounts), 0) into v2 from public.v_rep_group_performance;
  if v <> v2 then
    raise exception 'T2 FAILED: channel accounts % <> rep-group accounts %', v, v2;
  end if;
  raise notice 'T2 ok (both rollups cover the same book)';

  ----------------------------------------------------------------
  -- T3: and both agree with the account-grain view the Overview reads,
  -- so an admin can drill from a channel row into a list of accounts and
  -- have the numbers add up.
  ----------------------------------------------------------------
  select coalesce(sum(revenue_ytd), 0) into v2 from public.v_territory_account_yoy;
  select coalesce(sum(revenue_ytd), 0) into v  from public.v_channel_performance;
  if abs(v - v2) > 1 then
    raise exception 'T3 FAILED: channel revenue % <> v_territory_account_yoy %', v, v2;
  end if;
  raise notice 'T3 ok (rollups reconcile with v_territory_account_yoy)';

  ----------------------------------------------------------------
  -- T4: proves T1 has teeth. T1 only means something if there IS
  -- inactive/internal revenue for the scope filter to exclude —
  -- otherwise "equals the company" is a vacuous match that would still
  -- pass with the where-clause deleted.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  select coalesce(sum(a.revenue_ytd), 0) into v
  from erp.dim_customer c
  join erp.agg_account_rollup a on a.customer_key = c.customer_key
  where c.active_flag <> 'Y'
     or coalesce(c.internal_customer_flag, 'N') = 'Y';

  if v > 0 then
    raise notice 'T4 ok (T1 excluded % of inactive/internal revenue)', v;
  else
    raise warning 'T4 SKIPPED: no inactive/internal revenue here, so T1 proves '
                  'reconciliation but not the scope filter';
  end if;

  ----------------------------------------------------------------
  -- T5: security_invoker is the territory filter — a rep's channel
  -- rollup sums their OWN book and nothing else.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_rep);

  select coalesce(sum(revenue_ytd), 0) into v from public.v_channel_performance;
  if abs(v - v_rep) > 1 then
    raise exception 'T5 FAILED: rep channel revenue % <> own book %', v, v_rep;
  end if;
  if v_company > v_rep and abs(v - v_company) <= 1 then
    raise exception 'T5 FAILED: a rep summed the whole company';
  end if;
  raise notice 'T5 ok (rep sums their own book: %)', v;

  select coalesce(sum(revenue_ytd), 0) into v from public.v_rep_group_performance;
  if abs(v - v_rep) > 1 then
    raise exception 'T5b FAILED: rep group-rollup revenue % <> own book %', v, v_rep;
  end if;
  raise notice 'T5b ok (rep-group rollup honours RLS too)';

  ----------------------------------------------------------------
  -- T6: an empty-book user gets zero rows from both, not an error.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_other);

  select count(*) into n from public.v_channel_performance;
  if n <> 0 then
    raise exception 'T6 FAILED: empty-book user sees % channel rows', n;
  end if;
  select count(*) into n from public.v_rep_group_performance;
  if n <> 0 then
    raise exception 'T6 FAILED: empty-book user sees % rep-group rows', n;
  end if;
  raise notice 'T6 ok (empty book, empty reports)';

  ----------------------------------------------------------------
  -- T7: anon is locked out of both (the REVOKE in the migration).
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  if has_table_privilege('anon', 'public.v_channel_performance', 'select')
     or has_table_privilege('anon', 'public.v_rep_group_performance', 'select') then
    raise exception 'T7 FAILED: anon can select a reporting view';
  end if;
  raise notice 'T7 ok (anon has no grant on either view)';

  ----------------------------------------------------------------
  -- T8: no bucket is silently dropped — every active external account
  -- lands in exactly one channel row and one rep-group row.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_admin);
  if exists (select 1 from public.v_channel_performance where channel is null) then
    raise exception 'T8 FAILED: a null channel survived the Unclassified coalesce';
  end if;
  if exists (select 1 from public.v_rep_group_performance where rep_group_id is null) then
    raise exception 'T8 FAILED: a null rep_group_id survived the coalesce';
  end if;
  raise notice 'T8 ok (every account carries a bucket label)';

  perform pg_temp.as_super();
end $$;

select 'ALL ADMIN REPORTING TESTS PASSED' as result;

rollback;
