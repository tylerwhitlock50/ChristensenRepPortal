/*============================================================================
  20261013_account_page.sql — assertions for migration
  20261013110000_account_page.sql: v_account_revenue_monthly and
  v_account_list read the nightly rollups instead of the fact tables.

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_account_page.sql

  A clean run prints "ALL ACCOUNT PAGE VIEW TESTS PASSED".

  The fact rows are seeded and refresh_territory_rollups() is run for real,
  so "values match" compares the new views against the old live
  expressions over the same facts — not against hand-filled rollup rows.
============================================================================*/

begin;

\set ON_ERROR_STOP on

-- Production's calendar (20260901190000): the views and the refresh agree
-- on "this month" because both run on Mountain time.
set local timezone to 'America/Denver';

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-1310-4310-8310-131013101310'),
  ('rep_b', 'bbbbbbbb-1310-4310-8310-131013101310'),
  ('admin', 'cccccccc-1310-4310-8310-131013101310');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@accountpage.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'ACPG REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'ACPG REPB'
  where user_id = (select id from t_user where label='rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label='admin');

-- ACPG-A   rep A, invoices and orders
-- ACPG-ERP rep A, the ERP's own last_order_date is NEWER than any order line
-- ACPG-NIL rep A, no history at all (no rollup row), ERP date only
-- ACPG-B   rep B, invoices and orders
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, last_order_date)
values ('ACPG-A',   'ACPG-A',   'Account Page A',   'ACPG REPA', 'Y', null),
       ('ACPG-ERP', 'ACPG-ERP', 'Account Page ERP', 'ACPG REPA', 'Y', current_date - 2),
       ('ACPG-NIL', 'ACPG-NIL', 'Account Page Nil', 'ACPG REPA', 'Y', current_date - 400),
       ('ACPG-B',   'ACPG-B',   'Account Page B',   'ACPG REPB', 'Y', null);

--------------------------------------------------------------------------
-- Invoice lines, by month offset from the current one. Each case below is
-- something the old live view handled and the rollup must handle the same:
--
--   two invoices in one month, one of them with two lines → invoice_count 2
--   a memo line (credit)                                  → excluded
--   a line with no invoice date                            → excluded
--   23 months ago                                          → the window's edge, in
--   24 and 30 months ago                                   → outside, out
--   the current, partial month                             → in
--------------------------------------------------------------------------
create temporary table t_inv (
  customer_key text, invoice_id text, line_no int, months_ago int,
  revenue numeric, is_memo boolean, no_date boolean
) on commit drop;
insert into t_inv values
  ('ACPG-A',   'IA-1', 1,  0, 1200, false, false),
  ('ACPG-A',   'IA-2', 1,  2,  500, false, false),
  ('ACPG-A',   'IA-2', 2,  2,  250, false, false),
  ('ACPG-A',   'IA-3', 1,  2,  100, false, false),
  ('ACPG-A',   'IA-4', 1,  2, -300, true,  false),
  ('ACPG-A',   'IA-5', 1,  5,  999, null,  true),
  ('ACPG-A',   'IA-6', 1, 11, 4100, null,  false),
  ('ACPG-A',   'IA-7', 1, 23,  700, false, false),
  ('ACPG-A',   'IA-8', 1, 24,  800, false, false),
  ('ACPG-A',   'IA-9', 1, 30,  900, false, false),
  ('ACPG-ERP', 'IE-1', 1,  3,  640, false, false),
  ('ACPG-B',   'IB-1', 1,  1, 3300, false, false),
  ('ACPG-B',   'IB-2', 1, 12, 2100, false, false);

-- invoice_date / order_date are generated from the ERP's yyyymmdd keys.
insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, invoice_date_key, revenue, is_memo)
select i.invoice_id, i.line_no, 'E1', i.customer_key,
       case when i.no_date then null
            -- the 10th of the month: never straddles a month edge
            else to_char((date_trunc('month', current_date)
                          - make_interval(months => i.months_ago))::date + 9,
                         'YYYYMMDD')::int end,
       i.revenue, i.is_memo
from t_inv i;

-- Order lines: last order dates in the past, plus a cancelled line that is
-- still the newest (the old max() did not skip cancelled lines either).
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key,
                                 order_status, bookings, backlog_amount,
                                 backlog_qty, is_backlog_line)
select v.order_id, 1, v.customer_key, to_char(current_date - v.days_ago, 'YYYYMMDD')::int,
       v.status, v.bookings, v.backlog, v.backlog_qty, v.is_backlog
from (values ('OA-1', 'ACPG-A',   40, 'C', 100,   0, 0, false),
             ('OA-2', 'ACPG-A',    9, 'X',  50,   0, 0, false),
             ('OE-1', 'ACPG-ERP', 30, 'C', 100,   0, 0, false),
             ('OB-1', 'ACPG-B',    3, 'R', 300, 300, 3, true))
     as v (order_id, customer_key, days_ago, status, bookings, backlog, backlog_qty, is_backlog);

-- What the nightly ETL does after loading the facts.
select public.refresh_territory_rollups();

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
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
-- 0. Shape. Everything that reads these views (the frontend, the edge
--    functions, the MCP tools) reads them by name; create or replace
--    would refuse a change anyway, but pin it so a later restatement
--    cannot drift.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) order by attnum)
     from pg_attribute
    where attrelid = 'public.v_account_revenue_monthly'::regclass and attnum > 0
      and not attisdropped)
  = array['customer_key text', 'month date', 'revenue numeric', 'invoice_count integer'],
  'v_account_revenue_monthly keeps its four columns, names and types');

select pg_temp.assert(
  (select array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) order by attnum)
     from pg_attribute
    where attrelid = 'public.v_account_list'::regclass and attnum > 0
      and not attisdropped)
  = array['customer_key text', 'customer_name text', 'sold_to_city text',
          'sold_to_state text', 'assigned_sales_rep_id text',
          'assigned_sales_rep_name text', 'territory text', 'active_flag text',
          'last_order_date date', 'deactivated_at timestamp with time zone',
          'deactivation_reason text'],
  'v_account_list keeps its eleven columns, names and types');

select pg_temp.assert(
  (select bool_and('security_invoker=true' = any (coalesce(reloptions, '{}')))
     from pg_class
    where oid in ('public.v_account_revenue_monthly'::regclass,
                  'public.v_account_list'::regclass)),
  'both views are still security_invoker');

select pg_temp.assert(
  (select pg_get_viewdef('public.v_account_revenue_monthly'::regclass) ~ 'agg_customer_month'
          and pg_get_viewdef('public.v_account_revenue_monthly'::regclass) !~ 'fact_invoice_line'),
  'v_account_revenue_monthly reads the month rollup, not the invoice facts');
select pg_temp.assert(
  (select pg_get_viewdef('public.v_account_list'::regclass) ~ 'agg_account_rollup'
          and pg_get_viewdef('public.v_account_list'::regclass) !~ 'fact_order_line'),
  'v_account_list reads the account rollup, not the order facts');

--------------------------------------------------------------------------
-- 1. Values: the new views against 011's and 023's live expressions over
--    the same seeded facts. Run as the table owner, so RLS is not in play
--    here — section 2 is about scope.
--------------------------------------------------------------------------
create temporary table t_live_monthly on commit drop as
select
    f.customer_key,
    date_trunc('month', f.invoice_date)::date        as month,
    coalesce(sum(f.revenue), 0)::numeric             as revenue,
    count(distinct f.invoice_id)::int                as invoice_count
from erp.fact_invoice_line f
where f.is_memo is not true
  and f.invoice_date is not null
  and f.invoice_date >= (date_trunc('month', current_date) - interval '23 months')::date
  and f.customer_key like 'ACPG-%'
group by f.customer_key, date_trunc('month', f.invoice_date)::date;

select pg_temp.assert(
  not exists (
    (select * from public.v_account_revenue_monthly where customer_key like 'ACPG-%'
     except select * from t_live_monthly)
    union all
    (select * from t_live_monthly
     except select * from public.v_account_revenue_monthly where customer_key like 'ACPG-%')
  ),
  'v_account_revenue_monthly equals the old live GROUP BY, row for row');

select pg_temp.assert(
  (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-A') = 4,
  'ACPG-A: this month, 2, 11 and 23 months ago — 24 and 30 are outside the window');

select pg_temp.assert(
  (select (revenue, invoice_count) from public.v_account_revenue_monthly
    where customer_key = 'ACPG-A'
      and month = (date_trunc('month', current_date) - interval '2 months')::date)
  = (850::numeric, 2),
  'two months ago: memo excluded, two distinct invoices across three lines');

select pg_temp.assert(
  (select revenue from public.v_account_revenue_monthly
    where customer_key = 'ACPG-A'
      and month = (date_trunc('month', current_date) - interval '11 months')::date)
  = 4100,
  'is_memo NULL counts as revenue (NULL-safe, as in 011)');

select pg_temp.assert(
  (select min(month) from public.v_account_revenue_monthly where customer_key = 'ACPG-A')
  = (date_trunc('month', current_date) - interval '23 months')::date,
  'the window starts 23 months before the current month');

create temporary table t_live_last_order on commit drop as
select c.customer_key,
       greatest(c.last_order_date,
                (select max(o.order_date) from erp.fact_order_line o
                  where o.customer_key = c.customer_key)) as last_order_date
from erp.dim_customer c
where c.customer_key like 'ACPG-%';

select pg_temp.assert(
  not exists (
    select 1 from t_live_last_order t
    join public.v_account_list v using (customer_key)
    where v.last_order_date is distinct from t.last_order_date
  )
  and (select count(*) from public.v_account_list where customer_key like 'ACPG-%') = 4,
  'v_account_list.last_order_date equals the old correlated max, account for account');

select pg_temp.assert(
  (select last_order_date from public.v_account_list where customer_key = 'ACPG-A')
    = current_date - 9,
  'the newest order line wins, cancelled or not (as before)');
select pg_temp.assert(
  (select last_order_date from public.v_account_list where customer_key = 'ACPG-ERP')
    = current_date - 2,
  'a newer ERP field still wins over the order history (015''s greatest)');
select pg_temp.assert(
  (select last_order_date from public.v_account_list where customer_key = 'ACPG-NIL')
    = current_date - 400,
  'no history, no rollup row: the ERP field alone, not NULL');

--------------------------------------------------------------------------
-- 2. Scope: a second rep sees nothing of the first rep's book, through
--    either view; an admin sees both; an admin viewing as rep A sees
--    exactly rep A's.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-A') = 4
  and (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-B') = 0,
  'rep A: own months, ZERO of rep B''s');
select pg_temp.assert(
  (select array_agg(customer_key order by customer_key) from public.v_account_list
    where customer_key like 'ACPG-%')
  = array['ACPG-A', 'ACPG-ERP', 'ACPG-NIL'],
  'rep A: own accounts in the list, not rep B''s');
select pg_temp.assert(
  (select last_order_date from public.v_account_list where customer_key = 'ACPG-A')
    = current_date - 9,
  'rep A reads the rollup date through RLS, not NULL');

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.v_account_revenue_monthly where customer_key like 'ACPG-%')
  = (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-B')
  and (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-B') = 2,
  'rep B: own two months only');
select pg_temp.assert(
  (select array_agg(customer_key) from public.v_account_list where customer_key like 'ACPG-%')
  = array['ACPG-B'],
  'rep B: only ACPG-B in the list');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(distinct customer_key) from public.v_account_revenue_monthly
    where customer_key like 'ACPG-%') = 3
  and (select count(*) from public.v_account_list where customer_key like 'ACPG-%') = 4,
  'an admin sees every account');

select public.start_impersonation((select id from t_user where label='rep_a'));
select pg_temp.assert(
  (select count(*) from public.v_account_revenue_monthly where customer_key = 'ACPG-B') = 0
  and (select count(*) from public.v_account_list where customer_key like 'ACPG-%') = 3,
  'an admin viewing as rep A sees exactly rep A''s book');
select public.stop_impersonation();

--------------------------------------------------------------------------
-- 3. Grants: unchanged — authenticated reads, anon does not.
--------------------------------------------------------------------------
reset role;
select pg_temp.assert(
  has_table_privilege('authenticated', 'public.v_account_revenue_monthly', 'select')
  and has_table_privilege('authenticated', 'public.v_account_list', 'select'),
  'authenticated can select both views');
select pg_temp.assert(
  not has_table_privilege('anon', 'public.v_account_revenue_monthly', 'select')
  and not has_table_privilege('anon', 'public.v_account_list', 'select'),
  'anon cannot select either view');

do $$ begin raise notice 'ALL ACCOUNT PAGE VIEW TESTS PASSED'; end $$;

rollback;
