/*============================================================================
  20261027_goal_active_customers.sql — assertions for
    20261027090400_goal_active_customers.sql
      v_account_goal_progress   ERP-sourced goals only for active, external
                                accounts (the v_rep_goal_dashboard rule)

  Runs in a transaction and ROLLS BACK; writes throwaway users and ERP rows.
  Section 2 reads the production book of the PMI agency (vendor
  'PROF MARK INC') through a throwaway principal. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_goal_active_customers.sql

  A clean run prints "ALL GOAL ACTIVE CUSTOMER TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep', 'aaaaaaaa-9494-4494-8494-949494949494'),
  ('pmi', 'bbbbbbbb-9595-4595-8595-959595959595');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@goalactive.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'GA REPA'
  where user_id = (select id from t_user where label = 'rep');
-- A principal over the PMI agency, like the real one (a rep-role profile
-- with rep_group_vendor_id set; the dashboard lists role = 'rep').
update public.profiles set rep_group_vendor_id = 'PROF MARK INC'
  where user_id = (select id from t_user where label = 'pmi');

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Shape unchanged (v_my_goal_rollup and the account list depend on it).
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_account_goal_progress')
  = array['goal_id', 'customer_key', 'customer_name', 'sold_to_city', 'sold_to_state',
          'active_flag', 'period_year', 'target_amount', 'note', 'created_by', 'updated_by',
          'updated_at', 'erp_yearly_sales_goal', 'period_start', 'period_end', 'as_of',
          'days_elapsed', 'days_total', 'days_remaining', 'revenue_to_date', 'pace_basis',
          'attainment_pct', 'expected_pct', 'expected_amount', 'gap_to_pace', 'gap_to_goal',
          'projected_amount', 'on_track', 'goal_source'],
  'v_account_goal_progress: column list unchanged');

select pg_temp.assert(
  (select reloptions from pg_class where oid = 'public.v_account_goal_progress'::regclass)
    @> array['security_invoker=true'],
  'still security_invoker');

--------------------------------------------------------------------------
-- 2. Production: no closed or internal account carries an ERP goal, and
--    the PMI book's goal equals the admin dashboard's figure for it.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*)
     from public.v_account_goal_progress g
     join erp.dim_customer c on c.customer_key = g.customer_key
    where g.goal_source = 'erp'
      and (c.active_flag is distinct from 'Y'
           or coalesce(c.internal_customer_flag, 'N') = 'Y')) = 0,
  'no ERP-sourced goal row for an inactive or internal account');

do $$
begin
  if not exists (select 1 from erp.dim_customer
                  where assigned_sales_rep_id = 'DUST GIBB'
                    and active_flag is distinct from 'Y'
                    and yearly_sales_goal > 0) then
    raise notice 'note: no closed DUST GIBB account with a goal remains in the ERP — '
                 'the next assertion is now vacuous';
  end if;
end $$;

select pg_temp.assert(
  not exists (select 1
                from public.v_account_goal_progress g
                join erp.dim_customer c on c.customer_key = g.customer_key
               where g.goal_source = 'erp'
                 and c.assigned_sales_rep_id = 'DUST GIBB'),
  'the closed DUST GIBB account''s goal ($250,000 on 2026-10-26) is gone from the book');

-- The principal's book, read the way the portal reads it (RLS, security
-- invoker), against v_rep_goal_dashboard's per-rep total for the same user.
create temporary table t_pmi (book_goal numeric, goal_rows bigint) on commit drop;
grant insert, select on t_pmi to authenticated;

select pg_temp.become('pmi');
insert into t_pmi
select coalesce(sum(target_amount), 0), count(*)
from public.v_account_goal_progress
where period_year = extract(year from current_date)::int;
reset role;

select pg_temp.assert(
  abs((select book_goal from t_pmi)
      - (select goal_total from public.v_rep_goal_dashboard
          where user_id = (select id from t_user where label = 'pmi'))) <= 1,
  'PMI book goal (' || (select book_goal from t_pmi) || ' over '
    || (select goal_rows from t_pmi) || ' accounts) = v_rep_goal_dashboard.goal_total');

--------------------------------------------------------------------------
-- 3. Fixtures: each case of the rule.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name, assigned_sales_rep_id,
                              active_flag, internal_customer_flag, yearly_sales_goal)
values ('GA-ACT',  'GA-ACT',  'Goal Active',          'GA REPA', 'Y', 'N',  1000),
       ('GA-NULL', 'GA-NULL', 'Goal Active NullFlag', 'GA REPA', 'Y', null, 1500),
       ('GA-OFF',  'GA-OFF',  'Goal Closed',          'GA REPA', 'N', 'N',  2000),
       ('GA-INT',  'GA-INT',  'Goal Internal',        'GA REPA', 'Y', 'Y',  3000),
       ('GA-CRM',  'GA-CRM',  'Goal Closed With CRM', 'GA REPA', 'N', 'N',  4000);

insert into public.account_goals (customer_key, period_year, target_amount, created_by)
values ('GA-CRM', extract(year from current_date)::int, 4500,
        (select id from t_user where label = 'rep'));

select pg_temp.become('rep');

select pg_temp.assert(
  (select array_agg(customer_key || ':' || goal_source || ':' || target_amount::int
                    order by customer_key)
     from public.v_account_goal_progress where customer_key like 'GA-%')
  = array['GA-ACT:erp:1000', 'GA-CRM:crm:4500', 'GA-NULL:erp:1500'],
  'ERP goals: active external kept (null internal flag = external); closed and internal '
  'dropped; a typed-in CRM goal still shows even on a closed account');

reset role;

do $$ begin raise notice 'ALL GOAL ACTIVE CUSTOMER TESTS PASSED'; end $$;

rollback;
