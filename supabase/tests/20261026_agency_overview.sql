/*============================================================================
  20261026_agency_overview.sql — assertions for
    20261026180000_agency_overview.sql
      v_agency_rep_performance        the book at (rep, channel) grain
      agency_rep_activity()           who in the agency uses the portal
      report_agency_sales_by_month()  revenue per (month, rep)
      report_agency_large_orders()    biggest recent orders, with their rep
      v_backlog_by_sku                + the account's assigned rep

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261026_agency_overview.sql

  A clean run prints "ALL AGENCY OVERVIEW TESTS PASSED".

  What is being protected:
    - the principal sees their agency cut by rep, to the dollar, and the
      numbers reconcile with the Overview's v_territory_account_yoy and the
      admin's v_rep_group_performance;
    - agency_rep_activity() is the one new disclosure, so it gets the most
      tests: a principal sees their own agency's people and nobody else's,
      cannot widen it with the argument, a plain rep sees nothing, an
      admin sees exactly the agency they name, and view-as follows the
      principal;
    - every vendor argument narrows and never widens.

  The principal here has NO rep code of their own — the shape that showed a
  blank Overview in production: their whole book is the group book.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('principal',     'aaaaaaaa-2610-4610-8610-261026102610'),
  ('rep_a',         'bbbbbbbb-2610-4610-8610-261026102610'),
  ('rep_b',         'cccccccc-2610-4610-8610-261026102610'),
  ('other_rep',     'dddddddd-2610-4610-8610-261026102610'),
  ('other_princ',   'eeeeeeee-2610-4610-8610-261026102610'),
  ('admin',         'ffffffff-2610-4610-8610-261026102610'),
  ('empty',         '11111111-2610-4610-8610-261026102610'),
  ('gone_princ',    '22222222-2610-4610-8610-261026102610');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@agency.test', '',
       now(), now(), now(), '{}'::jsonb,
       jsonb_build_object('full_name', initcap(replace(u.label, '_', ' '))), false
from t_user u;

update public.profiles set rep_group_vendor_id = 'AO AGENCY'
  where user_id = (select id from t_user where label = 'principal');
update public.profiles set sales_rep_key = 'AO REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'AO REPB'
  where user_id = (select id from t_user where label = 'rep_b');
update public.profiles set sales_rep_key = 'AO REPX'
  where user_id = (select id from t_user where label = 'other_rep');
update public.profiles set rep_group_vendor_id = 'AO OTHER'
  where user_id = (select id from t_user where label = 'other_princ');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');
update public.profiles set rep_group_vendor_id = 'AO AGENCY', active = false
  where user_id = (select id from t_user where label = 'gone_princ');

-- Two agencies. AO AGENCY: reps A and B. AO OTHER: rep X.
insert into erp.dim_sales_rep (sales_rep_key, sales_rep_name, vendor_id) values
  ('AO REPA', 'Rep Alpha', 'AO AGENCY'),
  ('AO REPB', 'Rep Bravo', 'AO AGENCY'),
  ('AO REPX', 'Rep Xray',  'AO OTHER');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, assigned_sales_rep_name,
                              active_flag, internal_customer_flag,
                              customer_reporting_group, yearly_sales_goal)
values ('AO-A1', 'AO A1', 'Agency A One',    'AO REPA', 'Rep Alpha', 'Y', 'N', 'Dealer',    100000),
       ('AO-A2', 'AO A2', 'Agency A Two',    'AO REPA', 'Rep Alpha', 'Y', 'N', 'Buy Group', null),
       ('AO-A3', 'AO A3', 'Agency A Closed', 'AO REPA', 'Rep Alpha', 'N', 'N', 'Dealer',    null),
       ('AO-B1', 'AO B1', 'Agency B One',    'AO REPB', 'Rep Bravo', 'Y', 'N', 'Dealer',    null),
       ('AO-X1', 'AO X1', 'Other X One',     'AO REPX', 'Rep Xray',  'Y', 'N', 'Dealer',    null);

-- A1 long-standing and growing; A2 new this year; A3 inactive (must never
-- count); B1 lapsed (bought last year, nothing yet this year); X1 the
-- other agency's.
insert into erp.agg_account_rollup
  (customer_key, revenue_ytd, revenue_prior_ytd, revenue_trailing_12m,
   revenue_prior_full, bookings_ytd, bookings_prior_ytd, open_order_value,
   backlog_amount, first_invoice_date, last_invoice_date)
values
  ('AO-A1', 50000, 40000, 60000, 45000, 55000, 41000, 5000, 1000, '2019-01-01', current_date - 3),
  ('AO-A2', 10000,     0, 10000,     0, 12000,     0,    0,    0, date_trunc('year', current_date)::date, current_date - 9),
  ('AO-A3', 99999, 99999, 99999, 99999, 99999, 99999,    0,    0, '2019-01-01', current_date - 1),
  ('AO-B1',     0, 20000, 15000, 25000,     0, 18000,    0,    0, '2018-06-01', current_date - 200),
  ('AO-X1', 77777, 70000, 80000, 75000, 70000, 60000,    0,    0, '2019-01-01', current_date - 2);

insert into public.account_goals (customer_key, period_year, target_amount, created_by)
values ('AO-A2', extract(year from current_date)::int, 30000,
        (select id from t_user where label = 'admin'));

insert into erp.agg_customer_month (customer_key, sales_month, revenue, qty, invoice_count)
values ('AO-A1', date_trunc('month', current_date)::date,                          1000, 2, 1),
       ('AO-A1', (date_trunc('month', current_date) - interval '12 months')::date,  800, 1, 1),
       ('AO-A2', date_trunc('month', current_date)::date,                           250, 1, 1),
       ('AO-B1', (date_trunc('month', current_date) - interval '3 months')::date,   500, 1, 1),
       ('AO-A3', date_trunc('month', current_date)::date,                          4444, 9, 1),
       ('AO-X1', date_trunc('month', current_date)::date,                          9999, 9, 1);

insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key,
                                 bookings, backlog_qty, backlog_amount,
                                 is_backlog_line, order_status)
values ('AO-O1',   1, 'AO-A1', to_char(current_date - 2,   'YYYYMMDD')::int,   3000, 2, 3000, true,  'R'),
       ('AO-O1',   2, 'AO-A1', to_char(current_date - 2,   'YYYYMMDD')::int,   2000, 0,    0, false, 'R'),
       ('AO-O2',   1, 'AO-B1', to_char(current_date - 10,  'YYYYMMDD')::int,   7000, 0,    0, false, null),
       ('AO-OX',   1, 'AO-A1', to_char(current_date - 1,   'YYYYMMDD')::int, 900000, 9, 9000, true,  'X'),
       ('AO-OOLD', 1, 'AO-A1', to_char(current_date - 100, 'YYYYMMDD')::int,  50000, 0,    0, false, 'R'),
       ('AO-O3',   1, 'AO-X1', to_char(current_date - 1,   'YYYYMMDD')::int, 123456, 1,  500, true,  'R'),
       ('AO-O4',   1, 'AO-A3', to_char(current_date - 1,   'YYYYMMDD')::int,   8888, 0,    0, false, 'R');

-- Portal use. Rep A: three app opens in 30 days on two business days, plus
-- one long ago; a visit and a call. Rep B: never. Rep X: busy, other agency.
insert into public.login_events (user_id, logged_at)
select (select id from t_user where label = 'rep_a'), at
from (values (now() - interval '1 minute'),
             (now() - interval '2 minutes'),
             (now() - interval '20 days'),
             (now() - interval '60 days')) v(at)
union all
select (select id from t_user where label = 'other_rep'), now() - interval '1 day';

insert into public.actions (customer_key, user_id, action_type, action_date) values
  ('AO-A1', (select id from t_user where label = 'rep_a'),     'visit', current_date - 3),
  ('AO-A2', (select id from t_user where label = 'rep_a'),     'call',  current_date - 40),
  ('AO-X1', (select id from t_user where label = 'other_rep'), 'visit', current_date - 1);

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
-- 1. v_agency_rep_performance
--------------------------------------------------------------------------
select pg_temp.become('principal');

select pg_temp.assert(
  (select array_agg(distinct sales_rep_key order by sales_rep_key)
     from public.v_agency_rep_performance) = array['AO REPA', 'AO REPB'],
  'principal (no rep code of their own): one row set per agency rep, nobody else''s');

select pg_temp.assert(
  (select (sum(accounts), sum(revenue_ytd), sum(revenue_prior_ytd), sum(bookings_ytd))::text
     from public.v_agency_rep_performance) = '(3,60000,60000,67000)',
  'principal: the agency''s active accounts summed to the dollar (inactive A3 left out)');

select pg_temp.assert(
  (select sum(revenue_ytd) from public.v_agency_rep_performance)
  = (select sum(revenue_ytd) from public.v_territory_account_yoy),
  'principal: reconciles with the Overview''s v_territory_account_yoy');

select pg_temp.assert(
  (select (sum(accounts), sum(buying_accounts), sum(lapsed_accounts), sum(new_accounts),
           sum(goal_total)::int, sum(accounts_with_goal), sum(contacted_30d))::text
     from public.v_agency_rep_performance where sales_rep_key = 'AO REPA')
  = '(2,2,0,1,130000,2,1)',
  'rep A row: 2 accounts buying, A2 new this year, ERP goal on A1 + CRM goal on A2, '
  'A1 touched in 30 days (A2''s call is 40 days old)');

select pg_temp.assert(
  (select (lapsed_accounts, sales_rep_name, vendor_id)::text
     from public.v_agency_rep_performance where sales_rep_key = 'AO REPB')
  = '(1,"Rep Bravo","AO AGENCY")',
  'rep B row: B1 lapsed; carries the ERP rep name and the agency');

select pg_temp.assert(
  (select array_agg(channel || ':' || accounts order by channel)
     from public.v_agency_rep_performance where sales_rep_key = 'AO REPA')
  = array['Buy Group:1', 'Dealer:1'],
  'grain is (rep, channel)');

select pg_temp.assert(
  (select count(*) from public.v_agency_rep_performance where vendor_id = 'AO OTHER') = 0,
  'principal filtering on another agency gets nothing (RLS already removed it)');

select pg_temp.become('rep_a');
select pg_temp.assert(
  (select array_agg(distinct sales_rep_key) from public.v_agency_rep_performance)
  = array['AO REPA'],
  'a plain rep sees only their own rep row');

select pg_temp.become('empty');
select pg_temp.assert(
  (select count(*) from public.v_agency_rep_performance) = 0,
  'an empty book sees nothing, and does not error');

select pg_temp.become('gone_princ');
select pg_temp.assert(
  (select count(*) from public.v_agency_rep_performance) = 0,
  'an inactive principal derives nothing');

select pg_temp.become('admin');
select pg_temp.assert(
  (select sum(revenue_ytd) from public.v_agency_rep_performance where vendor_id = 'AO AGENCY')
  = (select revenue_ytd from public.v_rep_group_performance where rep_group_id = 'AO AGENCY'),
  'admin, one agency: matches the Reports tab''s rep-group row');

select pg_temp.assert(
  (select sum(revenue_ytd) from public.v_agency_rep_performance where vendor_id = 'AO AGENCY')
  = 60000,
  'admin, one agency: the same figure the principal sees');

--------------------------------------------------------------------------
-- 2. agency_rep_activity() — the new disclosure.
--------------------------------------------------------------------------
select pg_temp.become('principal');

select pg_temp.assert(
  (select array_agg(full_name order by full_name) from public.agency_rep_activity())
  = array['Gone Princ', 'Principal', 'Rep A', 'Rep B'],
  'principal: themselves, their co-principal and their agency''s reps — not the other agency''s');

select pg_temp.assert(
  (select (is_principal, logins_7d, logins_30d, active_days_30d, actions_30d, visits_30d,
           last_action_date = current_date - 3, last_login_at > now() - interval '2 hours')::text
     from public.agency_rep_activity() where full_name = 'Rep A')
  = '(f,2,3,2,1,1,t,t)',
  'rep A: 2 opens this week, 3 in 30 days on 2 days, 1 action (a visit) in 30 days');

select pg_temp.assert(
  (select (is_principal, logins_30d, last_login_at is null, actions_30d)::text
     from public.agency_rep_activity() where full_name = 'Rep B')
  = '(f,0,t,0)',
  'rep B: never signed in, nothing logged — the row a principal needs to see');

select pg_temp.assert(
  (select (is_principal, vendor_id)::text
     from public.agency_rep_activity() where full_name = 'Principal')
  = '(t,"AO AGENCY")',
  'the principal row is marked, and every row names the agency');

select pg_temp.assert(
  (select array_agg(full_name order by full_name) from public.agency_rep_activity('AO OTHER'))
  = array['Gone Princ', 'Principal', 'Rep A', 'Rep B'],
  'principal: the argument is IGNORED — another agency cannot be asked for');

select pg_temp.assert(
  (select (is_principal, active)::text
     from public.agency_rep_activity() where full_name = 'Gone Princ') = '(t,f)',
  'an inactive co-principal is still listed, marked inactive, for the active one');

select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.agency_rep_activity()) = 0
  and (select count(*) from public.agency_rep_activity('AO AGENCY')) = 0,
  'a plain rep sees nobody''s activity, even naming their own agency');

select pg_temp.become('empty');
select pg_temp.assert(
  (select count(*) from public.agency_rep_activity('AO AGENCY')) = 0,
  'an empty-book user sees nothing');

select pg_temp.become('gone_princ');
select pg_temp.assert(
  (select count(*) from public.agency_rep_activity()) = 0,
  'an inactive principal sees nothing');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.agency_rep_activity()) = 0,
  'admin without an agency: nothing (the page always names one)');
select pg_temp.assert(
  (select array_agg(full_name order by full_name) from public.agency_rep_activity('AO OTHER'))
  = array['Other Princ', 'Other Rep'],
  'admin: exactly the agency named');
select pg_temp.assert(
  (select array_agg(full_name order by full_name) from public.agency_rep_activity(' AO AGENCY '))
  = array['Gone Princ', 'Principal', 'Rep A', 'Rep B'],
  'admin: the agency argument is trimmed');

-- View-as: the admin sees the principal's page, and only theirs.
select public.start_impersonation((select id from t_user where label = 'principal'));
select pg_temp.assert(
  (select array_agg(full_name order by full_name) from public.agency_rep_activity('AO OTHER'))
  = array['Gone Princ', 'Principal', 'Rep A', 'Rep B'],
  'admin viewing as the principal: the principal''s agency, the argument ignored');
select pg_temp.assert(
  (select sum(revenue_ytd) from public.v_agency_rep_performance) = 60000,
  'admin viewing as the principal: the principal''s numbers');
select public.stop_impersonation();

--------------------------------------------------------------------------
-- 3. report_agency_sales_by_month()
--------------------------------------------------------------------------
select pg_temp.become('principal');

select pg_temp.assert(
  (select array_agg(sales_rep_key || ':' || revenue::int order by sales_month, sales_rep_key)
     from public.report_agency_sales_by_month(24))
  = array['AO REPA:800', 'AO REPB:500', 'AO REPA:1250'],
  'principal: per (month, rep), agency only, inactive A3 left out, accounts summed per rep');

select pg_temp.assert(
  (select account_count from public.report_agency_sales_by_month(24)
    where sales_month = date_trunc('month', current_date)::date) = 2,
  'buying accounts are counted per (month, rep)');

select pg_temp.assert(
  (select count(*) from public.report_agency_sales_by_month(1)) = 1,
  'p_months bounds the window (this month only)');

select pg_temp.assert(
  (select count(*) from public.report_agency_sales_by_month(24, 'AO OTHER')) = 0,
  'principal naming another agency gets nothing — narrows, never widens');

select pg_temp.become('admin');
select pg_temp.assert(
  (select array_agg(distinct sales_rep_key) from public.report_agency_sales_by_month(24, 'AO OTHER'))
  = array['AO REPX'],
  'admin: one agency by vendor');

--------------------------------------------------------------------------
-- 4. report_agency_large_orders()
--------------------------------------------------------------------------
select pg_temp.become('principal');

select pg_temp.assert(
  (select array_agg(order_id || ':' || amount::int || ':' || has_open_lines || ':' || sales_rep_name
                    order by amount desc)
     from public.report_agency_large_orders(30, 15))
  = array['AO-O2:7000:false:Rep Bravo', 'AO-O1:5000:true:Rep Alpha'],
  'principal: biggest first, lines summed, open lines flagged, rep named; cancelled, '
  'too-old, inactive-account and other-agency orders left out');

select pg_temp.assert(
  (select count(*) from public.report_agency_large_orders(30, 1)) = 1,
  'p_limit caps the list');

select pg_temp.assert(
  (select count(*) from public.report_agency_large_orders(365, 15)) = 3,
  'p_days widens the window (the 100-day-old order comes in)');

select pg_temp.assert(
  (select count(*) from public.report_agency_large_orders(30, 15, 'AO OTHER')) = 0,
  'principal naming another agency gets nothing');

select pg_temp.become('admin');
select pg_temp.assert(
  (select array_agg(order_id) from public.report_agency_large_orders(30, 15, 'AO OTHER'))
  = array['AO-O3'],
  'admin: one agency by vendor');

--------------------------------------------------------------------------
-- 5. v_backlog_by_sku names the rep.
--------------------------------------------------------------------------
select pg_temp.become('principal');
select pg_temp.assert(
  (select array_agg(customer_key || ':' || assigned_sales_rep_id || ':' || assigned_sales_rep_name
                    order by customer_key)
     from public.v_backlog_by_sku)
  = array['AO-A1:AO REPA:Rep Alpha'],
  'backlog carries the account''s assigned rep; the principal sees only their agency''s');

select pg_temp.assert(
  (select backlog_amount from public.v_backlog_by_sku where customer_key = 'AO-A1') = 12000,
  'backlog grain unchanged by the appended columns (two open lines on A1, one SKU)');

reset role;

--------------------------------------------------------------------------
-- 6. Shape: definer only where it has to be; grants.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select prosecdef from pg_proc where oid = 'public.agency_rep_activity(text)'::regprocedure)
  and not (select bool_or(prosecdef) from pg_proc
            where oid in ('public.report_agency_sales_by_month(int, text)'::regprocedure,
                          'public.report_agency_large_orders(int, int, text)'::regprocedure)),
  'activity is SECURITY DEFINER (login_events is not rep-readable); the reports are INVOKER');

select pg_temp.assert(
  (select bool_and(proconfig @> array['search_path=""'])
     from pg_proc
    where oid in ('public.agency_rep_activity(text)'::regprocedure,
                  'public.report_agency_sales_by_month(int, text)'::regprocedure,
                  'public.report_agency_large_orders(int, int, text)'::regprocedure)),
  'all three pin an empty search_path');

select pg_temp.assert(
  not has_function_privilege('anon', 'public.agency_rep_activity(text)', 'execute')
  and has_function_privilege('authenticated', 'public.agency_rep_activity(text)', 'execute')
  and not has_table_privilege('anon', 'public.v_agency_rep_performance', 'select')
  and has_table_privilege('authenticated', 'public.v_agency_rep_performance', 'select'),
  'authenticated may read, anon may not');

do $$ begin raise notice 'ALL AGENCY OVERVIEW TESTS PASSED'; end $$;

rollback;
