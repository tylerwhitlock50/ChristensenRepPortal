/*============================================================================
  20260817_orders.sql — RLS + lifecycle assertions for the order writer
  (migrations 20260817000000/000200): who reads which orders, the draft-only
  direct-write rule, every transition RPC's role and status checks, the
  authoritative promo recompute in submit_order(), and run_order_qc()
  against fixture erp.fact_order_line rows.

  Same harness rules as 010_access_rules.sql / 035_order_lookup.sql: runs in
  a transaction and ROLLS BACK, creates throwaway auth users and throwaway
  ERP rows, run against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/20260817_orders.sql

  A clean run prints "ALL ORDER TESTS PASSED"; any error is a failure.

  What is at stake: orders carry negotiated prices and dealer identities.
  A read hole leaks a competitor rep's order book; a write hole lets a rep
  forge an ERP order number or edit a submitted order after the fact. The
  cross-rep probes and the status-pinning probes are the point of this file.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a',     'aaaaaaaa-7777-4777-8777-777777777777'),
  ('rep_b',     'bbbbbbbb-8888-4888-8888-888888888888'),
  ('principal', 'cccccccc-9999-4999-8999-999999999999'),
  ('entry',     'dddddddd-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('admin',     'eeeeeeee-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@orders.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'OW REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'OW REPB'
  where user_id = (select id from t_user where label = 'rep_b');
update public.profiles set rep_group_vendor_id = 'OW VENDOR'
  where user_id = (select id from t_user where label = 'principal');
update public.profiles set role = 'order_entry'
  where user_id = (select id from t_user where label = 'entry');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

-- The principal's agency covers rep A.
insert into erp.dim_sales_rep (sales_rep_key, vendor_id)
values ('OW REPA', 'OW VENDOR');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id,
   customer_type, active_flag)
values
  ('OW-CUST-A', 'OW-CUST-A', 'Rep A Dealer', 'OW REPA', 'OW-DEALER', 'Y'),
  ('OW-CUST-B', 'OW-CUST-B', 'Rep B Dealer', 'OW REPB', 'OW-DEALER', 'Y');

insert into erp.dim_part (part_key, part_id, part_description)
values ('OWPK-1', 'OW-PART-1', 'General part'),
       ('OWPK-2', 'OW-PART-2', 'Promo part');

-- One general list and one buy-10-get-2 special, both live today.
create temporary table t_pl (label text primary key, id bigint) on commit drop;
grant select on t_pl to authenticated;
with ins as (
  insert into public.price_lists
    (name, customer_type, is_special, effective_from, promo_buy_qty, promo_get_qty)
  values
    ('OW general', 'OW-DEALER', false, current_date - 30, null, null),
    ('OW special', 'OW-DEALER', true,  current_date - 7,  10,   2)
  returning id, name
)
insert into t_pl select name, id from ins;

insert into public.price_list_items (price_list_id, part_id, unit_price)
values ((select id from t_pl where label = 'OW general'), 'OW-PART-1', 100.00),
       ((select id from t_pl where label = 'OW special'), 'OW-PART-2', 50.00);

create temporary table t_order (label text primary key, id bigint) on commit drop;
grant select, insert on t_order to authenticated;

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------
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
  if not p_ok then
    raise exception 'FAILED: %', p_what;
  end if;
  raise notice 'ok  %', p_what;
end $$;

create or replace function pg_temp.assert_fails(p_sql text, p_what text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'ok  % (rejected: %)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAILED: % — statement succeeded but should have been rejected', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Rep A drafts an order: a general line (2 × $100) and a promo line
--    (18 × $50 — one full buy-10-get-2 block plus 6 remainder units).
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

with ins as (
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep_a'), 'OW-CUST-A')
  returning id
)
insert into t_order select 'o1', id from ins;

insert into public.order_lines
  (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price)
values
  ((select id from t_order where label = 'o1'),
   (select id from t_pl where label = 'OW general'), 'OW-PART-1', 2, 100.00, 100.00),
  ((select id from t_order where label = 'o1'),
   (select id from t_pl where label = 'OW special'), 'OW-PART-2', 18, 50.00, 50.00);

select pg_temp.assert(
  (select count(*) from public.orders where id = (select id from t_order where label='o1')) = 1,
  'rep A reads their own draft');

-- A rep cannot draft onto an account outside their book.
select pg_temp.assert_fails(
  format($q$ insert into public.orders (user_id, customer_key)
             values ('%s', 'OW-CUST-B') $q$,
         (select id from t_user where label = 'rep_a')),
  'rep A cannot draft an order for rep B''s account');

-- And cannot leave draft by direct update (WITH CHECK pins the status).
select pg_temp.assert_fails(
  format($q$ update public.orders set status = 'submitted' where id = %s $q$,
         (select id from t_order where label = 'o1')),
  'rep A cannot flip a draft to submitted with a direct update');

--------------------------------------------------------------------------
-- 2. Who else can see the draft: nobody but the principal and admin.
--------------------------------------------------------------------------
select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.orders where customer_key = 'OW-CUST-A') = 0,
  'rep B sees none of rep A''s orders');
select pg_temp.assert(
  (select count(*) from public.order_lines
    where order_id = (select id from t_order where label='o1')) = 0,
  'rep B sees none of rep A''s order lines');

select pg_temp.become('principal');
select pg_temp.assert(
  (select count(*) from public.orders where customer_key = 'OW-CUST-A') = 1,
  'the principal sees their agency''s order');

select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from public.orders) = 0,
  'order entry does NOT see drafts');

--------------------------------------------------------------------------
-- 3. submit_order: owner-only, and the promo recompute is authoritative.
--    18 units / block of 12 → 1 multiple → 2 free-equivalents →
--    2/18 = 11.1111% off; 50.00 → 44.44. Total 2×100 + 18×44.44 = 999.92.
--------------------------------------------------------------------------
select pg_temp.become('rep_b');
select pg_temp.assert_fails(
  format('select public.submit_order(%s)', (select id from t_order where label='o1')),
  'rep B cannot submit rep A''s order');

select pg_temp.become('rep_a');
select public.submit_order((select id from t_order where label = 'o1'));

select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o1'))
    = 'submitted',
  'owner submit lands the order in submitted');

select pg_temp.assert(
  (select discount_pct from public.order_lines
    where order_id = (select id from t_order where label='o1')
      and part_id = 'OW-PART-2') = 11.1111,
  'the promo line''s discount is recomputed server-side to 11.1111%');

select pg_temp.assert(
  (select effective_unit_price from public.order_lines
    where order_id = (select id from t_order where label='o1')
      and part_id = 'OW-PART-2') = 44.44,
  'the promo line''s effective price rounds to 44.44');

select pg_temp.assert(
  (select discount_pct from public.order_lines
    where order_id = (select id from t_order where label='o1')
      and part_id = 'OW-PART-1') = 0,
  'the general line is not discounted');

select pg_temp.assert(
  (select total_amount from public.orders
    where id = (select id from t_order where label='o1')) = 999.92,
  'the order total is stamped from the recomputed lines');

select pg_temp.assert(
  (select customer_name from public.orders
    where id = (select id from t_order where label='o1')) = 'Rep A Dealer',
  'the customer snapshot is stamped at submit');

-- Once submitted, the owner's direct line edits hit zero rows.
update public.order_lines set qty = 99
  where order_id = (select id from t_order where label = 'o1');
select pg_temp.assert(
  (select max(qty) from public.order_lines
    where order_id = (select id from t_order where label='o1')) = 18,
  'rep A''s direct line edit on a submitted order changes nothing');

--------------------------------------------------------------------------
-- 4. Entry queue: sees it now, transitions only through the RPC.
--------------------------------------------------------------------------
select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from public.orders where status = 'submitted') = 1,
  'order entry sees the submitted order');

update public.orders set status = 'entered'
  where id = (select id from t_order where label = 'o1');
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o1'))
    = 'submitted',
  'order entry''s direct status update changes nothing');

select pg_temp.become('rep_a');
select pg_temp.assert_fails(
  format($q$ select public.mark_order_entered(%s, 'OW-ERP-1') $q$,
         (select id from t_order where label = 'o1')),
  'a rep cannot mark an order entered');

select pg_temp.become('entry');
select public.mark_order_entered((select id from t_order where label='o1'), 'ow-erp-1');

select pg_temp.assert(
  (select erp_order_number from public.orders
    where id = (select id from t_order where label='o1')) = 'OW-ERP-1',
  'mark_order_entered normalises and records the ERP order number');

-- A second order cannot reuse the same ERP number.
select pg_temp.become('rep_a');
with ins as (
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep_a'), 'OW-CUST-A')
  returning id
)
insert into t_order select 'o2', id from ins;
insert into public.order_lines
  (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price)
values ((select id from t_order where label = 'o2'),
        (select id from t_pl where label = 'OW general'), 'OW-PART-1', 1, 100.00, 100.00);
select public.submit_order((select id from t_order where label = 'o2'));

select pg_temp.become('entry');
select pg_temp.assert_fails(
  format($q$ select public.mark_order_entered(%s, 'OW-ERP-1') $q$,
         (select id from t_order where label = 'o2')),
  'a duplicate ERP order number is rejected');
select public.mark_order_entered((select id from t_order where label='o2'), 'OW-ERP-2');

--------------------------------------------------------------------------
-- 5. run_order_qc — matching ERP rows verify; drifted rows flag.
--    The ERP writes the promo as unit_price 50 + trade_discount 11.1111%:
--    effective 44.4445, within the $0.011 tolerance of the app's 44.44.
--------------------------------------------------------------------------
reset role;

insert into erp.fact_order_line
  (order_id, line_num, customer_key, part_key, order_qty, unit_price,
   trade_discount_pct, order_date_key, promise_date_key, desired_ship_date_key)
values
  ('OW-ERP-1', 1, 'OW-CUST-A', 'OWPK-1',  2, 100.00, null,    20260817, 20260901, 20260825),
  ('OW-ERP-1', 2, 'OW-CUST-A', 'OWPK-2', 18,  50.00, 11.1111, 20260817, 20260901, 20260825);

select pg_temp.become('rep_b');
select pg_temp.assert_fails(
  'select public.run_order_qc()',
  'a rep cannot run the QC');

select pg_temp.become('entry');
select public.run_order_qc();

select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o1'))
    = 'verified',
  'a clean ERP match verifies the order');
select pg_temp.assert(
  (select count(*) from public.order_qc_results
    where order_id = (select id from t_order where label='o1')) = 0,
  'a verified order carries no findings');

-- OW-ERP-2 has no ERP rows yet but was entered minutes ago: ETL-lag grace.
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o2'))
    = 'entered',
  'a freshly entered order with no ERP rows stays entered (grace period)');

-- Push it past the grace window: now it is a real discrepancy.
reset role;
update public.orders set entered_at = now() - interval '4 days'
  where id = (select id from t_order where label = 'o2');
select pg_temp.become('entry');
select public.run_order_qc();
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o2'))
    = 'discrepancy'
  and (select result from public.order_qc_results
        where order_id = (select id from t_order where label='o2')) = 'order_not_found',
  'past the grace window a missing ERP order flags order_not_found');

-- Drift the ERP price on the verified order and re-check it explicitly.
reset role;
update erp.fact_order_line set unit_price = 105.00
  where order_id = 'OW-ERP-1' and line_num = 1;
select pg_temp.become('entry');
select public.run_order_qc((select id from t_order where label = 'o1'));

select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o1'))
    = 'discrepancy',
  'an ERP price drift flips a verified order to discrepancy on re-check');
select pg_temp.assert(
  (select count(*) from public.order_qc_results
    where order_id = (select id from t_order where label='o1')
      and result = 'price_mismatch' and part_id = 'OW-PART-1'
      and erp_unit_price = 105.00) = 1,
  'the finding carries the part and both prices');

-- The rep sees the finding on their own order; rep B sees nothing.
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.order_qc_results
    where order_id = (select id from t_order where label='o1')) = 1,
  'rep A reads the QC finding on their own order');
select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.order_qc_results) = 0,
  'rep B reads no QC findings at all');

--------------------------------------------------------------------------
-- 6. resolve_discrepancy is admin-only; a clean re-check auto-verifies.
--------------------------------------------------------------------------
select pg_temp.become('entry');
select pg_temp.assert_fails(
  format('select public.resolve_discrepancy(%s, null)',
         (select id from t_order where label = 'o1')),
  'order entry cannot resolve a discrepancy');

-- The ERP side gets fixed; the nightly run auto-verifies without an admin.
reset role;
update erp.fact_order_line set unit_price = 100.00
  where order_id = 'OW-ERP-1' and line_num = 1;
select pg_temp.become('entry');
select public.run_order_qc();
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o1'))
    = 'verified',
  'a discrepancy auto-verifies once the ERP side matches again');

--------------------------------------------------------------------------
-- 7. recall and cancel guard their statuses.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert_fails(
  format('select public.recall_order(%s)', (select id from t_order where label='o1')),
  'a verified order cannot be recalled');
select pg_temp.assert_fails(
  format('select public.cancel_order(%s)', (select id from t_order where label='o1')),
  'a verified order cannot be cancelled');

-- A fresh draft cancels fine.
with ins as (
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep_a'), 'OW-CUST-A')
  returning id
)
insert into t_order select 'o3', id from ins;
select public.cancel_order((select id from t_order where label = 'o3'));
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_order where label='o3'))
    = 'cancelled',
  'the owner cancels their own draft');

reset role;

do $$ begin raise notice 'ALL ORDER TESTS PASSED'; end $$;

rollback;
