/*============================================================================
  20261030_order_ship_to_ffl.sql — assertions for migrations 20261030120000,
  20261030140000 and 20261030150000: submit_order() requires an active ship-to on the
  order's own account; an order with a firearm line ships under an FFL —
  the ship-to's licence on file when it is current, else one the rep enters
  (full and unexpired); accessory-only orders need none. Both are snapshot
  for order entry, and run_order_qc() flags an ERP order that ships
  somewhere else.

  Same harness as 20260817_orders.sql: one transaction, ROLLED BACK,
  throwaway users and ERP rows, run against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/20261030_order_ship_to_ffl.sql

  A clean run prints "ALL SHIP-TO/FFL TESTS PASSED"; any error is a failure.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'a1a1a1a1-1111-4111-8111-111111111111'),
  ('entry', 'b2b2b2b2-2222-4222-8222-222222222222');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@shipto.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'ST REP'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set role = 'order_entry'
  where user_id = (select id from t_user where label = 'entry');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag)
values ('ST-CUST', 'ST-CUST', 'Ship-To Dealer', 'ST REP', 'ST-DEALER', 'Y'),
       ('ST-OTHER', 'ST-OTHER', 'Someone Else', 'ST NOBODY', 'ST-DEALER', 'Y');

insert into erp.dim_ship_to
  (ship_to_key, customer_id, addr_no, ship_to_id, ship_to_name, address1, city, state, zip_code,
   active_flag, ffl_license_number, ffl_expiration_raw, address_source, is_unknown_ship_to)
values
  -- A real licence runs three years; parse_ffl_expiry refuses dates 25+ years out.
  ('ST-CUST|1', 'ST-CUST', 1, 'STORE', 'Dealer Store', '1 Main St', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false),
  ('ST-CUST|2', 'ST-CUST', 2, 'OLD', 'Old Warehouse', '2 Side St', 'Boise', 'ID', '83702',
   'N', '1-23-456-78-9A-12345', '01/31/2099', 'ShipTo', false),
  ('ST-CUST|3', 'ST-CUST', 3, 'NOFFL', 'Range Annex', '3 Range Rd', 'Boise', 'ID', '83702',
   'Y', null, null, 'ShipTo', false),
  ('ST-CUST|4', 'ST-CUST', 4, 'LAPSED', 'Lapsed Store', '4 Old Rd', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-54321', '1/1/2020', 'ShipTo', false),
  ('ST-CUST|CUST', 'ST-CUST', null, null, 'Dealer (sold-to)', '1 Main St', 'Boise', 'ID', '83702',
   'Y', null, null, 'CustomerMaster', false),
  ('ST-OTHER|1', 'ST-OTHER', 1, 'THEIRS', 'Someone Else', '9 Far Rd', 'Reno', 'NV', '89501',
   'Y', '9-87-654-32-1B-54321', '01/31/2099', 'ShipTo', false);

-- A finished rifle (spec'd family) and an accessory (component-free code, no spec).
insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family, chambering)
values ('STPK-1', 'ST-PART-1', 'Rifle', 'FG-RIFLE', 'Ridgeline', '6.5 Creedmoor'),
       ('STPK-2', 'ST-PART-2', 'Scope rings', 'FG-ACC', 'N/A', 'N/A');

create temporary table t_ids (label text primary key, id bigint) on commit drop;
grant select, insert on t_ids to authenticated;
with ins as (
  insert into public.price_lists (name, customer_type, is_special, effective_from)
  values ('ST general', 'ST-DEALER', false, current_date - 30) returning id
)
insert into t_ids select 'pl', id from ins;
insert into public.price_list_items (price_list_id, part_id, unit_price)
values ((select id from t_ids where label = 'pl'), 'ST-PART-1', 1000.00),
       ((select id from t_ids where label = 'pl'), 'ST-PART-2', 50.00);

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

-- Fails, and with the expected message.
create or replace function pg_temp.assert_fails(p_sql text, p_like text, p_what text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not ilike p_like then
      raise exception 'FAILED: % — rejected, but with "%"', p_what, sqlerrm;
    end if;
    raise notice 'ok  % (rejected: %)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAILED: % — statement succeeded but should have been rejected', p_what;
end $$;

-- A draft with one line (the rifle unless told otherwise), as the rep.
create or replace function pg_temp.draft(p_label text, p_part text default 'ST-PART-1') returns bigint
language plpgsql as $$
declare oid bigint;
begin
  insert into public.orders (user_id, customer_key)
  values ((select id from t_user where label = 'rep'), 'ST-CUST') returning id into oid;
  insert into public.order_lines (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price)
  values (oid, (select id from t_ids where label = 'pl'), p_part, 1,
          case when p_part = 'ST-PART-1' then 1000.00 else 50.00 end,
          case when p_part = 'ST-PART-1' then 1000.00 else 50.00 end);
  insert into t_ids values (p_label, oid);
  return oid;
end $$;

--------------------------------------------------------------------------
-- 1. submit_order refuses what it must
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.draft('o1');

create or replace function pg_temp.submit(p_label text) returns text
language sql as $$ select format('select public.submit_order(%s)', (select id from t_ids where label = p_label)) $$;
create or replace function pg_temp.set(p_label text, p_set text) returns void
language plpgsql as $$
begin
  execute format('update public.orders set %s where id = %s', p_set, (select id from t_ids where label = p_label));
end $$;

select pg_temp.assert_fails(pg_temp.submit('o1'), '%pick a ship-to%', 'no ship-to');

select pg_temp.set('o1', $$ship_to_key = 'ST-OTHER|1'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%not one of this account%', 'another account''s ship-to');

select pg_temp.set('o1', $$ship_to_key = 'ST-CUST|CUST'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%not one of this account%',
  'the sold-to fallback row is not a ship-to (no SHIPTO_ID)');

select pg_temp.set('o1', $$ship_to_key = 'ST-CUST|404'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%not one of this account%', 'a ship-to that does not exist');

select pg_temp.set('o1', $$ship_to_key = 'ST-CUST|2'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%inactive%', 'an inactive ship-to');

-- NOFFL has no licence on file, so a rifle order needs the rep's FFL.
select pg_temp.set('o1', $$ship_to_key = 'ST-CUST|3'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%no current FFL on file%', 'no FFL and none on file');

select pg_temp.set('o1', $$ffl_license_number = '1-23-456'$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%no current FFL on file%', 'a short FFL number');

select pg_temp.set('o1', $$ffl_license_number = ' 1-23-456-78-9a-12345 '$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%expiration date is required%', 'no FFL expiry');

select pg_temp.set('o1', $$ffl_expires_on = current_date - 1$$);
select pg_temp.assert_fails(pg_temp.submit('o1'), '%FFL expired%', 'an expired FFL');

-- LAPSED's licence on file expired in 2020: not usable, so the rep must enter one.
select pg_temp.draft('o_lapsed');
select pg_temp.set('o_lapsed', $$ship_to_key = 'ST-CUST|4'$$);
select pg_temp.assert_fails(pg_temp.submit('o_lapsed'), '%no current FFL on file%',
  'an expired licence on file is not used');

--------------------------------------------------------------------------
-- 2. What submits, and what it carries
--------------------------------------------------------------------------
-- Rep-entered FFL where none is on file.
select pg_temp.set('o1', $$ffl_expires_on = current_date + 400$$);
select public.submit_order((select id from t_ids where label = 'o1'));
select pg_temp.assert(
  (select ship_to_id = 'NOFFL' and ship_to_addr_no = 3 and ship_to_name = 'Range Annex'
          and ship_to_address = '3 Range Rd, Boise, ID 83702'
          and requires_ffl and ffl_license_number = '1-23-456-78-9A-12345'
          and ffl_expires_on = current_date + 400 and ffl_on_file_number is null
     from public.orders where id = (select id from t_ids where label = 'o1')),
  'submit stamps the ship-to and the rep''s FFL, normalising the number');

-- A current licence on file: the rep enters nothing and the order carries it.
select pg_temp.draft('o2');
select pg_temp.set('o2', $$ship_to_key = 'ST-CUST|1'$$);
select public.submit_order((select id from t_ids where label = 'o2'));
select pg_temp.assert(
  (select requires_ffl and ffl_license_number = '1-23-456-78-9A-12345'
          and ffl_expires_on = date '2028-01-31' and ffl_on_file_number = '1-23-456-78-9A-12345'
     from public.orders where id = (select id from t_ids where label = 'o2')),
  'a current licence on file is used without the rep entering it');

-- Accessories only: no FFL asked for, none stored, even with nothing on file.
select pg_temp.draft('o_acc', 'ST-PART-2');
select pg_temp.set('o_acc', $$ship_to_key = 'ST-CUST|3', ffl_license_number = 'junk'$$);
select public.submit_order((select id from t_ids where label = 'o_acc'));
select pg_temp.assert(
  (select requires_ffl = false and ffl_license_number is null and ffl_expires_on is null
     from public.orders where id = (select id from t_ids where label = 'o_acc')),
  'an accessory-only order needs no FFL');

-- Masked EZ Check numbers have 15 characters too and are accepted.
select pg_temp.draft('o_mask');
select pg_temp.set('o_mask', $$ship_to_key = 'ST-CUST|3', ffl_license_number = '1-XX-XXX-XX-XX-12345',
                         ffl_expires_on = current_date$$);
select public.submit_order((select id from t_ids where label = 'o_mask'));
select pg_temp.assert(
  (select status = 'submitted' from public.orders where id = (select id from t_ids where label = 'o_mask')),
  'a masked EZ Check number expiring today submits');

-- The writer's context comes from the same functions.
select pg_temp.assert(
  (select (c ->> 'requires_ffl')::boolean = true
          and (select (x ->> 'ffl_current')::boolean from jsonb_array_elements(c -> 'ship_tos') x
                where x ->> 'ship_to_key' = 'ST-CUST|1')
          and not (select (x ->> 'ffl_current')::boolean from jsonb_array_elements(c -> 'ship_tos') x
                    where x ->> 'ship_to_key' = 'ST-CUST|4')
          and jsonb_array_length(c -> 'ship_tos') = 5
     from (select public.order_ffl_context('ST-CUST', array['ST-PART-2', 'ST-PART-1']) c) q),
  'order_ffl_context: a rifle needs an FFL; STORE''s licence is current, LAPSED''s is not');
select pg_temp.assert(
  (select (public.order_ffl_context('ST-CUST', array['ST-PART-2']) ->> 'requires_ffl')::boolean = false),
  'order_ffl_context: accessories alone need none');
select pg_temp.assert(
  (select jsonb_array_length(public.order_ffl_context('ST-OTHER', array['ST-PART-1']) -> 'ship_tos') = 0),
  'order_ffl_context shows no ship-tos outside the rep''s book');

-- Order entry, which cannot read erp.dim_ship_to, sees the snapshot.
select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from erp.dim_ship_to where customer_id = 'ST-CUST') = 0,
  'order entry cannot read dim_ship_to');
select pg_temp.assert(
  (select ship_to_id from public.orders where id = (select id from t_ids where label = 'o1')) = 'NOFFL',
  'order entry reads the ship-to snapshot on the order');

--------------------------------------------------------------------------
-- 3. QC: the ERP order must ship where the rep chose
--------------------------------------------------------------------------
select public.mark_order_entered((select id from t_ids where label = 'o1'), 'ST-ERP-1');
select public.mark_order_entered((select id from t_ids where label = 'o2'), 'ST-ERP-2');
reset role;
insert into erp.fact_order_line
  (order_id, line_num, customer_key, ship_to_key, part_key, order_qty, unit_price,
   order_date_key, promise_date_key, desired_ship_date_key)
values ('ST-ERP-1', 1, 'ST-CUST', 'ST-CUST|3',    'STPK-1', 1, 1000.00, 20261030, 20261115, 20261110),
       ('ST-ERP-2', 1, 'ST-CUST', 'ST-CUST|CUST', 'STPK-1', 1, 1000.00, 20261030, 20261115, 20261110);

select pg_temp.become('entry');
select public.run_order_qc();

select pg_temp.assert(
  (select status from public.orders where id = (select id from t_ids where label = 'o1')) = 'verified',
  'the ERP order on the chosen ship-to verifies');
select pg_temp.assert(
  (select status from public.orders where id = (select id from t_ids where label = 'o2')) = 'discrepancy',
  'an ERP order on another address is a discrepancy');
select pg_temp.assert(
  (select detail like 'ERP order ST-ERP-2 ships to ST-CUST|CUST; the portal order chose ST-CUST|1 (STORE)'
     from public.order_qc_results
    where order_id = (select id from t_ids where label = 'o2') and result = 'ship_to_mismatch'),
  'the finding names both addresses');

--------------------------------------------------------------------------
-- 4. The rules the order loader shares (20261030150000)
--------------------------------------------------------------------------
reset role;

-- USER_5 strings: the same list as order_loader tests/test_portal.py
-- FFL_EXPIRY_VECTORS. Both sides must read them identically.
select pg_temp.assert(
  (select count(*) = 0 from (values
     ('1/31/2027', '2027-01-31'), ('01-31-27', '2027-01-31'), ('1.31.2027', '2027-01-31'),
     ('2027-01-31', '2027-01-31'), ('01312027', '2027-01-31'), ('Jan 31 2027', '2027-01-31'),
     ('January 31, 2027', '2027-01-31'), ('Sept. 30, 2027', '2027-09-30'), ('31-Jan-2027', '2027-01-31'),
     ('31-jan-27', '2027-01-31'), ('Exp 1/31/27', '2027-01-31'), ('EXPIRATION: 1/31/2027', '2027-01-31'),
     ('Exp Date 1/31/27', '2027-01-31'), ('Valid until 01/31/2027.', '2027-01-31'),
     ('1/31/2027 renewed', '2027-01-31'), ('13/45/2027', null), ('2/30/2027', null), ('see file', null),
     ('Junk 31 2027', null), ('12/31/1950', null), ('1/31/2099', null), ('', null)) v(raw, want)
   where public.parse_ffl_expiry(v.raw)::text is distinct from v.want),
  'parse_ffl_expiry reads every shared USER_5 string as the loader does');

-- Free-text 'n/a' (any case, stray whitespace) is "no spec", as in isGunRow and the loader.
insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family, chambering)
values ('STPK-3', 'ST-PART-3', 'Sling', 'FG-ACC', E' n/a\t', 'N/a');
select pg_temp.assert(
  not public.part_requires_ffl('ST-PART-3') and public.part_requires_ffl('ST-PART-1')
  and not public.part_requires_ffl('ST-PART-2'),
  'part_requires_ffl: a rifle needs one; accessories marked N/A in any case do not');

do $$ begin raise notice 'ALL SHIP-TO/FFL TESTS PASSED'; end $$;
rollback;
