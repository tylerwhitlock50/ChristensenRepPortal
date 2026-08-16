/*============================================================================
  036_sku_gaps.sql — assertions for report_account_sku_gaps (migration 036).

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/036_sku_gaps.sql

  A clean run prints "ALL SKU GAP TESTS PASSED".

  Why this file is not optional
  -----------------------------
  report_account_sku_gaps is SECURITY DEFINER, so RLS is NOT protecting it.
  The only thing between a rep and another dealer's purchase history is the
  has_account_access() guard in its first CTE. If that guard is ever dropped,
  reordered so the data CTEs stop depending on it, or defeated by a planner
  change, nothing else in the system will notice.

  Test 1 below is that guard. Everything else is correctness.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-7777-4777-8777-777777777777'),
  ('rep_b', 'bbbbbbbb-8888-4888-8888-888888888888');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@gaps.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'GAPS REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'GAPS REPB'
  where user_id = (select id from t_user where label='rep_b');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('GAPS-A', 'GAPS-A', 'Gaps Dealer A', 'GAPS REPA', 'Y'),
       ('GAPS-B', 'GAPS-B', 'Gaps Dealer B', 'GAPS REPB', 'Y');

--------------------------------------------------------------------------
-- Catalog. RIDGELINE is a broadly-stocked gun; SMU is a dealer-exclusive
-- run that must be screened out by p_min_dealers; BARREL is a component
-- that must be screened out by the product_code / spec test.
--------------------------------------------------------------------------
insert into erp.dim_part (part_key, part_id, part_description, product_code,
                          product_family, chambering)
values ('P-RIDGE', 'CA-RIDGE', 'Ridgeline 6.5', 'FINISHED', 'Ridgeline', '6.5 CM'),
       ('P-MESA',  'CA-MESA',  'Mesa 308',      'FINISHED', 'Mesa',      '308 WIN'),
       ('P-SMU',   'CA-SMU',   'Dealer SMU',    'FINISHED', 'Ridgeline', '7MM'),
       ('P-BARREL','CA-BARREL','OEM Barrel',    'COMPONENT', 'N/A',      'N/A'),
       ('P-OOS',   'CA-OOS',   'Out Of Stock',  'FINISHED', 'Mesa',      '300 WM');

-- Available to sell. P-OOS is oversold and must never be offered.
insert into erp.fact_available_to_sell (part_key, site_key, available_to_sell_qty)
values ('P-RIDGE','S1', 14),
       ('P-MESA', 'S1',  6),
       ('P-SMU',  'S1',  9),
       ('P-BARREL','S1', 50),
       ('P-OOS',  'S1', -3);

--------------------------------------------------------------------------
-- Company-wide invoice history. Dealer breadth comes from distinct
-- customer_key, so these extra dealers are what make P-RIDGE "broadly
-- stocked" and leave P-SMU below the threshold.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
select 'GAPS-X' || i, 'GAPS-X' || i, 'Other Dealer ' || i, 'GAPS REPX', 'Y'
from generate_series(1, 5) i;

-- P-RIDGE bought by 5 other dealers → dealer_count 5, over the threshold.
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
select 'INV-R' || i, 1, 'E', 'GAPS-X' || i, 'P-RIDGE', 20260601, 2, 2000, false
from generate_series(1, 5) i;

-- P-MESA bought by 5 other dealers AND by GAPS-A (so it is NOT a gap).
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
select 'INV-M' || i, 1, 'E', 'GAPS-X' || i, 'P-MESA', 20260601, 1, 1500, false
from generate_series(1, 5) i;
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
values ('INV-MA', 1, 'E', 'GAPS-A', 'P-MESA', 20260610, 1, 1500, false);

-- P-SMU: only 2 dealers → below the default min of 4.
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
select 'INV-S' || i, 1, 'E', 'GAPS-X' || i, 'P-SMU', 20260601, 1, 1200, false
from generate_series(1, 2) i;

-- P-BARREL: plenty of dealers, but a component.
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
select 'INV-B' || i, 1, 'E', 'GAPS-X' || i, 'P-BARREL', 20260601, 20, 400, false
from generate_series(1, 5) i;

-- P-OOS: broadly bought, but oversold, so it must not be offered.
insert into erp.fact_invoice_line
  (invoice_id, invoice_line_no, invoice_entity_id, customer_key, part_key,
   invoice_date_key, invoice_qty, revenue, is_memo)
select 'INV-O' || i, 1, 'E', 'GAPS-X' || i, 'P-OOS', 20260601, 1, 1800, false
from generate_series(1, 5) i;

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
  if not p_ok then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. THE GUARD. A DEFINER function taking a customer_key must refuse one
--    the caller does not own. If only one test in this file survives, this
--    is the one.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('GAPS-B')) = 0,
  'rep A gets ZERO rows for rep B''s account (the DEFINER guard holds)');

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('GAPS-A')) = 0,
  'rep B gets ZERO rows for rep A''s account');

select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('NO-SUCH-ACCOUNT')) = 0,
  'an account that does not exist returns nothing rather than everything');

--------------------------------------------------------------------------
-- 2. Correctness for the owning rep.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('GAPS-A')) > 0,
  'rep A does get gaps for their OWN account (the zeros above are the guard, '
  'not a broken query)');

select pg_temp.assert(
  exists (select 1 from public.report_account_sku_gaps('GAPS-A')
           where part_key = 'P-RIDGE' and not bought_before),
  'a broadly-stocked gun the account never bought IS offered');

select pg_temp.assert(
  (select ats_qty from public.report_account_sku_gaps('GAPS-A')
    where part_key = 'P-RIDGE') = 14,
  'and it carries the real available-to-sell quantity');

select pg_temp.assert(
  (select dealer_count from public.report_account_sku_gaps('GAPS-A')
    where part_key = 'P-RIDGE') = 5,
  'dealer breadth counts distinct dealers company-wide');

--------------------------------------------------------------------------
-- 3. The screens. Each of these being wrong makes the card useless in a
--    different way.
--------------------------------------------------------------------------
select pg_temp.assert(
  not exists (select 1 from public.report_account_sku_gaps('GAPS-A')
               where part_key = 'P-OOS'),
  'an OVERSOLD sku is never offered (we cannot ship it)');

select pg_temp.assert(
  not exists (select 1 from public.report_account_sku_gaps('GAPS-A')
               where part_key = 'P-BARREL'),
  'a COMPONENT sku is screened out (it would crowd out every gun)');

select pg_temp.assert(
  not exists (select 1 from public.report_account_sku_gaps('GAPS-A')
               where part_key = 'P-SMU'),
  'a thin-breadth SMU is screened out at the default 4-dealer floor');

select pg_temp.assert(
  exists (select 1 from public.report_account_sku_gaps('GAPS-A', 12, 2)
           where part_key = 'P-SMU'),
  'and lowering p_min_dealers brings it back');

--------------------------------------------------------------------------
-- 4. "They used to carry this" — bought_before is a different conversation
--    from a true gap, so it must be reported, not filtered away.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select bought_before from public.report_account_sku_gaps('GAPS-A')
    where part_key = 'P-MESA') = true,
  'a sku the account HAS bought comes back flagged bought_before');

select pg_temp.assert(
  (select last_bought_date from public.report_account_sku_gaps('GAPS-A')
    where part_key = 'P-MESA') = date '2026-06-10',
  'with the date they last bought it');

select pg_temp.assert(
  (select part_key from public.report_account_sku_gaps('GAPS-A') limit 1)
    = 'P-RIDGE',
  'never-bought ranks above already-bought');

reset role;

do $$ begin raise notice 'ALL SKU GAP TESTS PASSED'; end $$;

rollback;
