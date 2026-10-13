/*============================================================================
  20261013_reorder_candidates.sql — assertions for migration
  20261013100000_foundation_contacts_reorders.sql:
  report_reorder_candidates() and v_account_contacts.display_name.

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_reorder_candidates.sql

  A clean run prints "ALL REORDER CANDIDATE TESTS PASSED".

  erp.agg_sku_month is seeded DIRECTLY: the nightly refresh is not run here,
  and months are relative to today so "due" means the same thing whenever
  this file runs.

  The function is SECURITY INVOKER, so RLS on agg_sku_month is the only
  scope. Test 1 proves that scope holds; the rest is correctness.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-9191-4191-8191-919191919191'),
  ('rep_b', 'bbbbbbbb-9292-4292-8292-929292929292'),
  ('admin', 'cccccccc-9393-4393-8393-939393939393');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@reorder.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'REORD REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'REORD REPB'
  where user_id = (select id from t_user where label='rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label='admin');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('REORD-A', 'REORD-A', 'Reorder Dealer A', 'REORD REPA', 'Y'),
       ('REORD-B', 'REORD-B', 'Reorder Dealer B', 'REORD REPB', 'Y');

--------------------------------------------------------------------------
-- Catalog. Five finished guns the account repeats on, and four parts that
-- must never come back: oversold, zero ATS, a component, a part with no
-- real family or chambering.
--------------------------------------------------------------------------
insert into erp.dim_part (part_key, part_id, part_description, product_code,
                          product_family, chambering)
values ('RP-DUE',    'CA-DUE',    'Due Gun',      'FINISHED',  'Ridgeline', '6.5 CM'),
       ('RP-MEDIAN', 'CA-MEDIAN', 'Median Gun',   'FINISHED',  'Mesa',      '308 WIN'),
       ('RP-EVEN',   'CA-EVEN',   'Even Gun',     'FINISHED',  'Mesa',      '7MM PRC'),
       ('RP-LATER',  'CA-LATER',  'Not Due Gun',  'FINISHED',  'Traverse',  '300 WM'),
       ('RP-ONCE',   'CA-ONCE',   'Once Gun',     'FINISHED',  'Summit',    '28 NOS'),
       ('RP-OVER',   'CA-OVER',   'Oversold Gun', 'FINISHED',  'Mesa',      '6.5 PRC'),
       ('RP-ZERO',   'CA-ZERO',   'Zero ATS Gun', 'FINISHED',  'Mesa',      '270 WIN'),
       ('RP-COMP',   'CA-COMP',   'OEM Barrel',   'COMPONENT', 'N/A',       'N/A'),
       ('RP-NA',     'CA-NA',     'Mystery',      'FINISHED',  'N/A',       ''),
       ('RP-BONLY',  'CA-BONLY',  'B Only Gun',   'FINISHED',  'Ridgeline', '7MM');

-- Available to sell. RP-LATER is split over two sites (3 + 2): the
-- function sums sites.
insert into erp.fact_available_to_sell (part_key, site_key, available_to_sell_qty)
values ('RP-DUE',    'S1', 10),
       ('RP-MEDIAN', 'S1',  4),
       ('RP-EVEN',   'S1',  2),
       ('RP-LATER',  'S1',  3),
       ('RP-LATER',  'S2',  2),
       ('RP-ONCE',   'S1',  1),
       ('RP-OVER',   'S1', -2),
       ('RP-ZERO',   'S1',  0),
       ('RP-COMP',   'S1', 50),
       ('RP-NA',     'S1', 20),
       ('RP-BONLY',  'S1',  8);

--------------------------------------------------------------------------
-- Purchase history, in months before the current one.
--
--   RP-DUE     12, 9, 6, 3  gaps 3,3,3   median 3   next = this month → DUE
--              (plus a net return 1 month ago, which is not a buy)
--   RP-MEDIAN  20,19,15, 5  gaps 1,4,10  median 4   next = last month → DUE
--   RP-EVEN    10, 8, 4     gaps 2,4     median 3   next = last month → DUE
--   RP-LATER   14, 8, 2     gaps 6,6     median 6   next = +4 months  → not due
--   RP-ONCE    1            no gap       median —   next —            → not due
--------------------------------------------------------------------------
create temporary table t_buy (customer_key text, part_key text, months_ago int, qty numeric)
  on commit drop;
insert into t_buy values
  ('REORD-A', 'RP-DUE',    12, 2), ('REORD-A', 'RP-DUE',    9, 3),
  ('REORD-A', 'RP-DUE',     6, 2), ('REORD-A', 'RP-DUE',    3, 4),
  ('REORD-A', 'RP-DUE',     1, -1),
  ('REORD-A', 'RP-MEDIAN', 20, 1), ('REORD-A', 'RP-MEDIAN', 19, 1),
  ('REORD-A', 'RP-MEDIAN', 15, 2), ('REORD-A', 'RP-MEDIAN',  5, 1),
  ('REORD-A', 'RP-EVEN',   10, 1), ('REORD-A', 'RP-EVEN',    8, 1),
  ('REORD-A', 'RP-EVEN',    4, 2),
  ('REORD-A', 'RP-LATER',  14, 1), ('REORD-A', 'RP-LATER',   8, 1),
  ('REORD-A', 'RP-LATER',   2, 5),
  ('REORD-A', 'RP-ONCE',    1, 6),
  ('REORD-A', 'RP-OVER',    6, 3), ('REORD-A', 'RP-OVER',    3, 3),
  ('REORD-A', 'RP-ZERO',    6, 3), ('REORD-A', 'RP-ZERO',    3, 3),
  ('REORD-A', 'RP-COMP',    6, 40), ('REORD-A', 'RP-COMP',   3, 40),
  ('REORD-A', 'RP-NA',      6, 1), ('REORD-A', 'RP-NA',      3, 1),
  -- Rep B's account: its own repeat buy, plus one of A's parts.
  ('REORD-B', 'RP-BONLY',   6, 2), ('REORD-B', 'RP-BONLY',   3, 2),
  ('REORD-B', 'RP-DUE',     6, 1), ('REORD-B', 'RP-DUE',     3, 1);

insert into erp.agg_sku_month (customer_key, part_key, sales_month, revenue, qty, invoice_count)
select b.customer_key, b.part_key,
       (date_trunc('month', current_date) - make_interval(months => b.months_ago))::date,
       b.qty * 1000, b.qty, 1
from t_buy b;

--------------------------------------------------------------------------
-- Contacts for display_name.
--------------------------------------------------------------------------
insert into erp.dim_customer_contact
  (customer_contact_key, customer_key, contact_id, contact_name, first_name,
   last_name, contact_active_flag)
values ('RC-1', 'REORD-A', '0027284', null,      'Dana',  'Fox', 'Y'),
       ('RC-2', 'REORD-A', 'C2',      'INVOICE', null,    null,  'Y'),
       ('RC-3', 'REORD-A', '0018901', '0018901', ' Sam ', 'Lee', 'Y'),
       ('RC-4', 'REORD-A', 'C4',      null,      null,    null,  'Y'),
       ('RC-5', 'REORD-A', 'C5',      '',        '',      '',    'Y');

-- dim_part's production grants (20260901190300) are column-level: the cost
-- columns are revoked from authenticated. _local_harness_grants.sql re-grants
-- the whole table, so restate the real grant here — this function runs as
-- the caller and must work with exactly what a rep holds.
do $$
declare cols text;
begin
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into cols
  from information_schema.columns c
  where c.table_schema = 'erp' and c.table_name = 'dim_part'
    and c.column_name <> all (array[
      'wholesale_unit_cost', 'unit_material_cost', 'unit_labor_cost',
      'unit_burden_cost', 'unit_service_cost', 'fixed_cost',
      'burden_percent', 'standard_unit_cost']);
  execute 'revoke select on erp.dim_part from authenticated';
  execute format('grant select (%s) on erp.dim_part to authenticated', cols);
end $$;

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
-- 0. display_name, and that 034's columns did not move.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(attname::text order by attnum) from pg_attribute
    where attrelid = 'public.v_account_contacts'::regclass and attnum > 0
      and not attisdropped)
  = array['contact_key','source','id','customer_key','name','title','phone',
          'email','is_primary','notes','updated_at','do_not_call',
          'do_not_email','display_name'],
  'v_account_contacts keeps every column in place, display_name appended last');

select pg_temp.assert(
  (select display_name from public.v_account_contacts where contact_key = 'erp-RC-1')
    = 'Dana Fox',
  'no contact_name: first + last, not the bare id');
select pg_temp.assert(
  (select name from public.v_account_contacts where contact_key = 'erp-RC-1')
    = '0027284',
  'name keeps its old meaning');
select pg_temp.assert(
  (select display_name from public.v_account_contacts where contact_key = 'erp-RC-2')
    = 'INVOICE',
  'contact_name wins when it is a name');
select pg_temp.assert(
  (select display_name from public.v_account_contacts where contact_key = 'erp-RC-3')
    = 'Sam Lee',
  'a contact_name that is only an id loses to first + last (trimmed)');
select pg_temp.assert(
  (select display_name from public.v_account_contacts where contact_key = 'erp-RC-4')
    = 'C4',
  'nothing else: the contact id');
select pg_temp.assert(
  (select display_name from public.v_account_contacts where contact_key = 'erp-RC-5')
    = 'C5',
  'blank strings count as nothing');

insert into public.contacts (customer_key, name, created_by)
values ('REORD-A', 'Tucker Rep', (select id from t_user where label='rep_a'));
select pg_temp.assert(
  (select display_name from public.v_account_contacts
    where source = 'rep' and customer_key = 'REORD-A') = 'Tucker Rep',
  'rep rows: display_name is name');

select pg_temp.assert(
  not has_column_privilege('authenticated', 'erp.dim_part', 'standard_unit_cost', 'select')
  and has_column_privilege('authenticated', 'erp.dim_part', 'part_description', 'select'),
  'dim_part carries its production column grants for the rest of this file');

--------------------------------------------------------------------------
-- 1. Scope. SECURITY INVOKER: agg_sku_month's RLS decides.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-B')) = 0,
  'rep A gets ZERO rows for rep B''s account');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('NO-SUCH-ACCOUNT')) = 0,
  'an account that does not exist returns nothing');

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A')) = 0,
  'rep B gets ZERO rows for rep A''s account');
select pg_temp.assert(
  (select array_agg(part_key order by part_key) from public.report_reorder_candidates('REORD-B'))
    = array['RP-BONLY','RP-DUE'],
  'rep B gets their own account''s candidates');

--------------------------------------------------------------------------
-- 2. Correctness for the owning rep.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select array_agg(part_key) from public.report_reorder_candidates('REORD-A', 50))
    = array['RP-DUE','RP-MEDIAN','RP-EVEN','RP-LATER','RP-ONCE'],
  'due first; then most buy months; then most recent buy');

select pg_temp.assert(
  not exists (select 1 from public.report_reorder_candidates('REORD-A', 50)
               where part_key in ('RP-OVER','RP-ZERO')),
  'oversold and zero-ATS parts are never offered');
select pg_temp.assert(
  not exists (select 1 from public.report_reorder_candidates('REORD-A', 50)
               where part_key = 'RP-COMP'),
  'components are screened out');
select pg_temp.assert(
  not exists (select 1 from public.report_reorder_candidates('REORD-A', 50)
               where part_key = 'RP-NA'),
  'a part with no real family or chambering is screened out');

select pg_temp.assert(
  (select (months_with_buys, median_months_between_buys, is_due, last_qty, total_qty,
           last_bought_month, expected_next_month, ats_qty)
     from public.report_reorder_candidates('REORD-A') where part_key = 'RP-DUE')
  = (4, 3.0::numeric, true, 4::numeric, 11::numeric,
     (date_trunc('month', current_date) - interval '3 months')::date,
     date_trunc('month', current_date)::date, 10::numeric),
  'RP-DUE: 4 buy months, median gap 3, due this month; the net return is not a buy');

select pg_temp.assert(
  (select (median_months_between_buys, is_due, expected_next_month)
     from public.report_reorder_candidates('REORD-A') where part_key = 'RP-MEDIAN')
  = (4.0::numeric, true, (date_trunc('month', current_date) - interval '1 month')::date),
  'odd count: median of gaps 1,4,10 is 4 (not the mean 5)');

select pg_temp.assert(
  (select median_months_between_buys
     from public.report_reorder_candidates('REORD-A') where part_key = 'RP-EVEN')
  = 3.0,
  'even count: median of gaps 2,4 is 3');

select pg_temp.assert(
  (select (is_due, expected_next_month, ats_qty)
     from public.report_reorder_candidates('REORD-A') where part_key = 'RP-LATER')
  = (false, (date_trunc('month', current_date) + interval '4 months')::date, 5::numeric),
  'RP-LATER: next buy 4 months out is not due; ATS sums both sites');

select pg_temp.assert(
  (select (months_with_buys, median_months_between_buys is null,
           expected_next_month is null, is_due)
     from public.report_reorder_candidates('REORD-A') where part_key = 'RP-ONCE')
  = (1, true, true, false),
  'one buy month: no median, no expected month, not due');

select pg_temp.assert(
  (select part_description from public.report_reorder_candidates('REORD-A')
    where part_key = 'RP-DUE') = 'Due Gun',
  'carries the catalog attributes');

--------------------------------------------------------------------------
-- 3. Limit clamp.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A', 2)) = 2,
  'p_limit is honoured');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A', 0)) = 1,
  'p_limit below 1 clamps to 1');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A', null)) = 5,
  'p_limit null means the default (10)');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A')) = 5,
  'default limit');

--------------------------------------------------------------------------
-- 4. Admin, and admin viewing as rep A.
--------------------------------------------------------------------------
select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A')) = 5
  and (select count(*) from public.report_reorder_candidates('REORD-B')) = 2,
  'an admin sees every account''s candidates');

select public.start_impersonation((select id from t_user where label='rep_a'));
select pg_temp.assert(
  (select count(*) from public.report_reorder_candidates('REORD-A')) = 5
  and (select count(*) from public.report_reorder_candidates('REORD-B')) = 0,
  'an admin viewing as rep A sees exactly rep A''s scope');
select public.stop_impersonation();

--------------------------------------------------------------------------
-- 5. Grants.
--------------------------------------------------------------------------
reset role;
select pg_temp.assert(
  not has_function_privilege('anon', 'public.report_reorder_candidates(text, int)', 'execute'),
  'anon cannot execute');
select pg_temp.assert(
  has_function_privilege('authenticated', 'public.report_reorder_candidates(text, int)', 'execute'),
  'authenticated can execute');
select pg_temp.assert(
  (select not prosecdef from pg_proc
    where oid = 'public.report_reorder_candidates(text, int)'::regprocedure),
  'SECURITY INVOKER (RLS is the scope)');

do $$ begin raise notice 'ALL REORDER CANDIDATE TESTS PASSED'; end $$;

rollback;
