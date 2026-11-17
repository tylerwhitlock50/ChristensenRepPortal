/*============================================================================
  20261116_rep_confidentiality.sql — assertions for
  20261116110000_rep_confidentiality_tightening.sql

    1. a deactivated user's explicit account grants stop with their book
    2. erp.dim_sales_rep rows follow the caller's book
    3. own orders need the account on the caller's book today
    4. company-wide unit counts need four dealers for reps

  Throwaway fixtures, one transaction, ROLLED BACK. Runs on the bare
  _local_harness.sql cluster and on dev. Run with the migration, before it
  is deployed:

      etl/venv/Scripts/python.exe etl/run_sql_guard.py \
        supabase/migrations/20261116110000_rep_confidentiality_tightening.sql \
        supabase/tests/20261116_rep_confidentiality.sql

  A clean run prints "ALL REP CONFIDENTIALITY TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

-- Hand entry on for this file (rolled back), so a rep can hold a draft.
update public.app_settings set enabled = true where setting_key = 'feature.orders';

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a',     'd1d1d1d1-1111-4111-8111-111111111111'),
  ('principal', 'd2d2d2d2-2222-4222-8222-222222222222'),
  ('rep_c',     'd3d3d3d3-3333-4333-8333-333333333333'),
  ('admin',     'd4d4d4d4-4444-4444-8444-444444444444'),
  ('entry',     'd5d5d5d5-5555-4555-8555-555555555555'),
  ('gone',      'd6d6d6d6-6666-4666-8666-666666666666');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@repconf.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

-- Agency RC-AG1 has reps A and B (the principal is over both); agency
-- RC-AG2 has rep C.
insert into erp.dim_sales_rep (sales_rep_key, sales_rep_name, vendor_id) values
  ('RC REPA', 'Rep A', 'RC-AG1'),
  ('RC REPB', 'Rep B', 'RC-AG1'),
  ('RC REPC', 'Rep C', 'RC-AG2');

update public.profiles set sales_rep_key = 'RC REPA'
 where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set rep_group_vendor_id = 'RC-AG1'
 where user_id = (select id from t_user where label = 'principal');
update public.profiles set sales_rep_key = 'RC REPC'
 where user_id = (select id from t_user where label = 'rep_c');
update public.profiles set role = 'admin'
 where user_id = (select id from t_user where label = 'admin');
update public.profiles set role = 'order_entry'
 where user_id = (select id from t_user where label = 'entry');
update public.profiles set active = false
 where user_id = (select id from t_user where label = 'gone');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag)
values
  ('RC-CUST-A', 'RC-CUST-A', 'Conf Dealer A', 'RC REPA', 'RC-DEALER', 'Y'),
  ('RC-CUST-B', 'RC-CUST-B', 'Conf Dealer B', 'RC REPB', 'RC-DEALER', 'Y'),
  ('RC-CUST-C', 'RC-CUST-C', 'Conf Dealer C', 'RC REPC', 'RC-DEALER', 'Y'),
  ('RC-CUST-D', 'RC-CUST-D', 'Conf Dealer D', 'RC REPC', 'RC-DEALER', 'Y'),
  ('RC-CUST-E', 'RC-CUST-E', 'Conf Dealer E', 'RC REPC', 'RC-DEALER', 'Y');

-- The deactivated user holds an explicit grant.
insert into public.account_assignments (user_id, customer_key, access)
values ((select id from t_user where label = 'gone'), 'RC-CUST-A', 'grant');

-- Part one: four dealers company-wide (A, C, D, E). Part two: one (C).
insert into erp.dim_part (part_key, part_id, part_description, product_family)
values ('RCPK-1', 'RC-PART-1', 'Conf part one', 'RC FAMILY'),
       ('RCPK-2', 'RC-PART-2', 'Conf part two', 'RC FAMILY');

insert into erp.fact_invoice_line
  (invoice_entity_id, invoice_id, invoice_line_no, customer_key, part_key,
   invoice_qty, revenue, is_memo, invoice_date_key)
values
  ('RC-E', 'RC-INV-1', 1, 'RC-CUST-A', 'RCPK-1', 3, 300.00, false, to_char(current_date, 'YYYYMMDD')::int),
  ('RC-E', 'RC-INV-2', 1, 'RC-CUST-C', 'RCPK-1', 4, 400.00, false, to_char(current_date, 'YYYYMMDD')::int),
  ('RC-E', 'RC-INV-2', 2, 'RC-CUST-C', 'RCPK-2', 7, 700.00, false, to_char(current_date, 'YYYYMMDD')::int),
  ('RC-E', 'RC-INV-3', 1, 'RC-CUST-D', 'RCPK-1', 5, 500.00, false, to_char(current_date, 'YYYYMMDD')::int),
  ('RC-E', 'RC-INV-4', 1, 'RC-CUST-E', 'RCPK-1', 6, 600.00, false, to_char(current_date, 'YYYYMMDD')::int);

-- Both parts are in stock, so the gap report can offer them.
insert into erp.fact_available_to_sell (part_key, site_key, available_to_sell_qty)
values ('RCPK-1', 'RC-SITE', 10), ('RCPK-2', 'RC-SITE', 10);

select * from public.refresh_territory_rollups();

-- Rep A's draft on their own account.
create temporary table t_order (label text primary key, id bigint) on commit drop;
grant select, insert on t_order to authenticated;
with ins as (
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep_a'), 'RC-CUST-A')
  returning id
)
insert into t_order select 'o1', id from ins;

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  perform set_config('role', 'postgres', true);
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
  raise notice 'ok  %', p_what;
end $$;

-- The fixture reps the caller can read, as a sorted list.
create or replace function pg_temp.reps() returns text
language sql as $$
  select coalesce(string_agg(sales_rep_key, ',' order by sales_rep_key), '')
  from erp.dim_sales_rep
  where sales_rep_key like 'RC REP%';
$$;

--------------------------------------------------------------------------
-- 1. A deactivated user's explicit grant no longer resolves.
--------------------------------------------------------------------------
select pg_temp.become('gone');
select pg_temp.assert(
  (select count(*) from public.my_customer_keys()) = 0,
  'a deactivated user with an explicit grant has an empty book');
select pg_temp.assert(
  (select count(*) from erp.dim_customer where customer_key like 'RC-CUST-%') = 0,
  '…and reads no account');

--------------------------------------------------------------------------
-- 2. The rep roster follows the book.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(pg_temp.reps() = 'RC REPA',
  'a rep reads only their own rep row');
select pg_temp.assert(
  (select count(*) from erp.dim_sales_rep where vendor_id = 'RC-AG2') = 0,
  '…and cannot list another agency''s reps');

select pg_temp.become('principal');
select pg_temp.assert(pg_temp.reps() = 'RC REPA,RC REPB',
  'a principal reads their agency''s reps and no other agency''s');
select pg_temp.assert(
  (select string_agg(customer_key, ',' order by customer_key)
     from erp.dim_customer where customer_key like 'RC-CUST-%') = 'RC-CUST-A,RC-CUST-B',
  '…and still has the agency book (my_customer_keys reads the roster as definer)');

select pg_temp.become('rep_c');
select pg_temp.assert(pg_temp.reps() = 'RC REPC',
  'a rep in the other agency reads only their own rep row');

select pg_temp.become('admin');
select pg_temp.assert(pg_temp.reps() = 'RC REPA,RC REPB,RC REPC', 'an admin reads every rep');
select pg_temp.become('entry');
select pg_temp.assert(pg_temp.reps() = 'RC REPA,RC REPB,RC REPC', 'inside sales reads every rep');

select pg_temp.become('gone');
select pg_temp.assert(pg_temp.reps() = '', 'a deactivated user reads no rep');

-- An explicit grant brings the granted account's rep with it, so the
-- account page can still name them.
select set_config('role', 'postgres', true);
insert into public.account_assignments (user_id, customer_key, access)
values ((select id from t_user where label = 'rep_a'), 'RC-CUST-C', 'grant');
select pg_temp.become('rep_a');
select pg_temp.assert(pg_temp.reps() = 'RC REPA,RC REPC',
  'a granted account brings its assigned rep''s row, and only that one');
select set_config('role', 'postgres', true);
delete from public.account_assignments
 where user_id = (select id from t_user where label = 'rep_a') and customer_key = 'RC-CUST-C';

--------------------------------------------------------------------------
-- 3. Own orders need the account on the book today.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.orders where id = (select id from t_order where label = 'o1')) = 1
  and (select id from t_order where label = 'o1') in (select public.my_order_ids()),
  'a rep reads their own draft while the account is theirs');

-- INSERT ... RETURNING still works for a fresh draft (the direct branch).
with ins as (
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep_a'), 'RC-CUST-A')
  returning id
)
insert into t_order select 'o2', id from ins;
select pg_temp.assert(
  (select id from t_order where label = 'o2') is not null,
  'a rep can still insert a draft and read it back in the same statement');

select pg_temp.become('principal');
select pg_temp.assert(
  (select count(*) from public.orders where id = (select id from t_order where label = 'o1')) = 1,
  'the principal reads the agency rep''s order');

select pg_temp.become('rep_c');
select pg_temp.assert(
  (select count(*) from public.orders where id in (select id from t_order)) = 0,
  'a rep in another agency does not');

-- The account moves to rep C.
select set_config('role', 'postgres', true);
update erp.dim_customer set assigned_sales_rep_id = 'RC REPC' where customer_key = 'RC-CUST-A';

select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.orders where id in (select id from t_order)) = 0
  and not exists (select 1 from public.my_order_ids() m where m in (select id from t_order)),
  'after the account moves, the rep who drafted the order no longer reads it');
select pg_temp.assert(
  (select count(*) from public.order_owner_names(array[(select id from t_user where label = 'rep_c')])) = 0,
  '…nor anything that follows my_order_ids()');

select pg_temp.become('rep_c');
select pg_temp.assert(
  (select count(*) from public.orders where id in (select id from t_order)) = 2,
  'the rep who now has the account reads its orders');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.orders where id in (select id from t_order)) = 2,
  'an admin reads them');

select set_config('role', 'postgres', true);
update erp.dim_customer set assigned_sales_rep_id = 'RC REPA' where customer_key = 'RC-CUST-A';

--------------------------------------------------------------------------
-- 4. Company-wide unit counts: four dealers for reps.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.report_global_product_sales(12, 2000) where account_count < 4) = 0,
  'a rep gets no global SKU bought by fewer than four dealers');
select pg_temp.assert(
  (select qty = 18 and account_count = 4
     from public.report_global_product_sales(12, 2000) where part_key = 'RCPK-1'),
  '…and still gets the four-dealer SKU, with its company-wide units');
select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('RC-CUST-A', 12, 1, 100)
    where part_key = 'RCPK-2') = 0,
  'a rep asking the gap report for min_dealers 1 does not get the one-dealer SKU');
select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('RC-CUST-A', 12, 4, 100)
    where part_key = 'RCPK-1') = 1,
  '…and still gets the four-dealer SKU');
select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('RC-CUST-C', 12, 1, 100)) = 0,
  '…and nothing for an account that is not theirs');

select pg_temp.become('principal');
select pg_temp.assert(
  (select count(*) from public.report_global_product_sales(12, 2000) where part_key = 'RCPK-2') = 0,
  'a principal is held to four dealers too');

select pg_temp.become('admin');
select pg_temp.assert(
  (select account_count = 1 from public.report_global_product_sales(12, 2000) where part_key = 'RCPK-2'),
  'an admin still gets the one-dealer SKU');
select pg_temp.assert(
  (select count(*) from public.report_account_sku_gaps('RC-CUST-A', 12, 1, 100)
    where part_key = 'RCPK-2') = 1,
  '…and can ask the gap report below four');

select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from public.report_global_product_sales(12, 2000) where part_key = 'RCPK-2') = 1,
  'inside sales still gets the one-dealer SKU');

select set_config('role', 'postgres', true);
do $$ begin raise notice 'ALL REP CONFIDENTIALITY TESTS PASSED'; end $$;

rollback;
