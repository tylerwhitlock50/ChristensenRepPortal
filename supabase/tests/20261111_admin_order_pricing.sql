/*============================================================================
  20261111_admin_order_pricing.sql — assertions for
  20261112120000_admin_order_pricing: an admin's Claude stages a customer PO
  as sent (off-list parts, non-list prices, unmatched item numbers) as a
  flagged draft only an admin can submit; reps still cannot price anything.

  Harness copied from 20261111_mcp_orders.sql (same fixtures). One
  transaction, ROLLED BACK.

      etl/venv/Scripts/python.exe etl/run_sql_guard.py supabase/tests/20261111_admin_order_pricing.sql

  A clean run prints "ALL ADMIN ORDER PRICING TESTS PASSED".
============================================================================*/

begin;

-- Hand entry on for this file (rolled back): the order writer's own rules are
-- under test here. 20261111_mcp_orders.sql section 8c covers it switched off.
update public.app_settings set enabled = true where setting_key = 'feature.orders';

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'c1c1c1c1-1111-4111-8111-111111111111'),
  ('rep2',  'c2c2c2c2-2222-4222-8222-222222222222'),
  ('admin', 'c3c3c3c3-3333-4333-8333-333333333333');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@mcporders.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'MO REP'  where user_id = (select id from t_user where label = 'rep');
update public.profiles set sales_rep_key = 'MO REP2' where user_id = (select id from t_user where label = 'rep2');
update public.profiles set role = 'admin'            where user_id = (select id from t_user where label = 'admin');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag, credit_status)
values ('MO-CUST',  'MO-CUST',  'MCP Test Dealer',   'MO REP',  'MO-DEALER', 'Y', 'APPROVED'),
       ('MO-ONE',   'MO-ONE',   'One Address Dealer', 'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MO-HOLD',  'MO-HOLD',  'Held Dealer',        'MO REP', 'MO-NOLIST', 'Y', 'HOLD'),
       ('MO-OTHER', 'MO-OTHER', 'Another Reps Dealer', 'MO REP2', 'MO-DEALER', 'Y', 'APPROVED');

insert into erp.dim_ship_to
  (ship_to_key, customer_id, addr_no, ship_to_id, ship_to_name, address1, city, state, zip_code,
   active_flag, ffl_license_number, ffl_expiration_raw, address_source, is_unknown_ship_to)
values
  ('MO-CUST|1', 'MO-CUST', 1, 'STORE', 'Dealer Store', '1 Main St', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false),
  ('MO-CUST|2', 'MO-CUST', 2, 'OLD', 'Old Warehouse', '2 Side St', 'Boise', 'ID', '83702',
   'N', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false),
  ('MO-CUST|3', 'MO-CUST', 3, 'NOFFL', 'Range Annex', '3 Range Rd', 'Boise', 'ID', '83702',
   'Y', null, null, 'ShipTo', false),
  ('MO-CUST|CUST', 'MO-CUST', null, null, 'Dealer (sold-to)', '1 Main St', 'Boise', 'ID', '83702',
   'Y', null, null, 'CustomerMaster', false),
  ('MO-ONE|1', 'MO-ONE', 1, 'ONLY', 'Only Store', '5 Elm St', 'Nampa', 'ID', '83651',
   'Y', '1-23-456-78-9A-22222', '01/31/2028', 'ShipTo', false),
  ('MO-OTHER|1', 'MO-OTHER', 1, 'THEIRS', 'Someone Else', '9 Far Rd', 'Reno', 'NV', '89501',
   'Y', '9-87-654-32-1B-54321', '01/31/2028', 'ShipTo', false);

insert into erp.dim_customer_contact
  (customer_contact_key, customer_key, contact_id, contact_name, email, primary_contact_flag, contact_active_flag)
values ('MO-CUST|C1', 'MO-CUST', 'BUYER', 'Pat Buyer', 'pat@dealer.test', 'Y', 'Y'),
       ('MO-OTHER|C1', 'MO-OTHER', 'THEM', 'Someone', 'x@other.test', 'Y', 'Y');

insert into erp.dim_part
  (part_key, part_id, part_description, product_code, product_family, chambering,
   barrel_length, finish, stock_color, handedness, status, is_kit_flag)
values
  ('MOPK-BG', 'MO-RL-BG', 'RL FFT 6.5 CRD 22IN CBNW BLK/GRY', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '6.5 CREEDMOOR', '22', 'CARBON', 'BLACK / GRAY', 'RIGHT', 'A', 'N'),
  ('MOPK-CG', 'MO-RL-CG', 'RL FFT 6.5 CRD 22IN CBNW/GRY', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '6.5 CREEDMOOR', '22', 'CARBON', 'CARBON / GRAY', 'RIGHT', 'A', 'N'),
  ('MOPK-TI', 'MO-RL-TI', 'RL TI FFT 6.5 CRD 22IN BLK/GRY', 'RIDGELINE FFT',
   'RIDGELINE TITANIUM FLASH FORGED TECHNOLOGY', '6.5 CREEDMOOR', '22', 'CARBON', 'BLACK / GRAY', 'RIGHT', 'A', 'N'),
  ('MOPK-270', 'MO-RL-270', 'RL FFT 270 WSM 24IN BLK/GRY', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '270 WSM', '24', 'CARBON', 'BLACK / GRAY', 'RIGHT', 'A', 'N'),
  ('MOPK-ACC', 'MO-ACC', 'Scope rings', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N'),
  ('MOPK-SPC', 'MO-SPC', 'Bipod promo', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N'),
  ('MOPK-KIT', 'MO-KIT', 'Cleaning kit', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'Y'),
  ('MOPK-UNP', 'MO-UNP', 'Ridgeline FFT 6.5 Creedmoor unpriced', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '6.5 CREEDMOOR', '22', 'CARBON', 'BLACK / GRAY', 'RIGHT', 'A', 'N');

insert into erp.fact_available_to_sell (part_key, site_key, shippable_warehouse_id, available_to_sell_qty)
values ('MOPK-BG', 'MO-SITE', 'MAIN', 5);

create temporary table t_ids (label text primary key, id bigint) on commit drop;
create temporary table t_tok (label text primary key, id uuid, token text) on commit drop;
create temporary table t_prev (label text primary key, j jsonb) on commit drop;
grant select, insert, update on t_ids, t_tok, t_prev to authenticated;

with g as (
  insert into public.price_lists (name, customer_type, is_special, effective_from)
  values ('MO general', 'MO-DEALER', false, current_date - 30) returning id
) insert into t_ids select 'pl', id from g;
with s as (
  insert into public.price_lists (name, customer_type, is_special, effective_from, promo_buy_qty, promo_get_qty)
  values ('MO promo', 'MO-DEALER', true, current_date - 30, 2, 1) returning id
) insert into t_ids select 'pl_special', id from s;
insert into public.price_list_items (price_list_id, part_id, unit_price)
select (select id from t_ids where label = 'pl'), v.part, v.price
from (values ('MO-RL-BG', 2000.00), ('MO-RL-CG', 2000.00), ('MO-RL-TI', 3000.00), ('MO-RL-270', 2000.00),
             ('MO-ACC', 50.00), ('MO-KIT', 100.00)) v(part, price);
insert into public.price_list_items (price_list_id, part_id, unit_price)
values ((select id from t_ids where label = 'pl_special'), 'MO-SPC', 500.00);

-- Portal hand entry (feature.orders) is independent of MCP drafting and may
-- be off live; the portal-order cases below need it on (rolled back).
update public.app_settings set enabled = true where setting_key = 'feature.orders';

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
-- A portal session: a signed-in user, no MCP app_metadata.
create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from t_user where label = p_label), 'role', 'authenticated',
                      'app_metadata', json_build_object('provider', 'email'))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- An MCP session as the edge function mints it: provider mcp, the token id,
-- and an mcp_scopes claim (ignored by the gate since 20261111150000).
create or replace function pg_temp.become_mcp(p_label text, p_token_label text,
                                             p_scopes text[] default array['orders:draft']) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from t_user where label = p_label), 'role', 'authenticated',
                      'app_metadata', json_build_object(
                        'provider', 'mcp',
                        'mcp_token_id', (select id from t_tok where label = p_token_label),
                        'mcp_scopes', to_json(coalesce(p_scopes, '{}'::text[]))))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- The same without any mcp_scopes claim.
create or replace function pg_temp.become_mcp_bare(p_label text, p_token_label text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from t_user where label = p_label), 'role', 'authenticated',
                      'app_metadata', json_build_object(
                        'provider', 'mcp',
                        'mcp_token_id', (select id from t_tok where label = p_token_label)))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- feature.mcp_orders: on/off and params (merged), as the superuser.
create or replace function pg_temp.flag(p_enabled boolean, p_params jsonb default '{}') returns void
language plpgsql as $$
begin
  reset role;
  update public.app_settings
     set enabled = p_enabled, params = params || p_params
   where setting_key = 'feature.mcp_orders';
end $$;

-- Rows a statement touched (a data-modifying CTE cannot sit in a subquery).
create or replace function pg_temp.rows(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

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

-- A create request for MO-CUST at the STORE ship-to; p_extra overrides.
-- Since 20261112090000 every draft carries a PO, the ship-to confirmation
-- (MO-CUST has two orderable ship-tos) and part_confirmed on each line;
-- 20261112_mcp_order_confirmations.sql tests those rules themselves.
create or replace function pg_temp.confirmed(p_lines jsonb) returns jsonb
language sql as $$
  select case when jsonb_typeof(p_lines) = 'array'
              then coalesce((select jsonb_agg(case when jsonb_typeof(e) = 'object'
                                                   then jsonb_build_object('part_confirmed', true) || e
                                                   else e end order by n)
                               from jsonb_array_elements(p_lines) with ordinality as x(e, n)), '[]'::jsonb)
              else p_lines end
$$;
create or replace function pg_temp.req(p_key text, p_lines jsonb, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('idempotency_key', p_key, 'customer_key', 'MO-CUST',
                            'ship_to_key', 'MO-CUST|1', 'ship_to_confirmed', true,
                            'po_number', 'PO-' || p_key,
                            'lines', pg_temp.confirmed(p_lines)) || p_extra
$$;
create or replace function pg_temp.create_sql(p jsonb) returns text
language sql as $$ select format('select public.mcp_create_order_draft(%L::jsonb)', p) $$;
create or replace function pg_temp.create(p_label text, p jsonb) returns jsonb
language plpgsql as $$
declare j jsonb;
begin
  j := public.mcp_create_order_draft(p);
  insert into t_prev values (p_label, j) on conflict (label) do update set j = excluded.j;
  insert into t_ids values (p_label, (j ->> 'order_id')::bigint) on conflict (label) do nothing;
  return j;
end $$;
create or replace function pg_temp.prev(p_label text) returns jsonb
language sql as $$ select j from t_prev where label = p_label $$;
create or replace function pg_temp.oid(p_label text) returns bigint
language sql as $$ select id from t_ids where label = p_label $$;
create or replace function pg_temp.mint(p_user text, p_label text, p_scopes text[]) returns void
language plpgsql as $$
declare r record;
begin
  perform pg_temp.become(p_user);
  select * into r from public.mcp_token_create(p_label, p_scopes => p_scopes);
  insert into t_tok values (p_label, r.token_id, r.token);
end $$;

--------------------------------------------------------------------------
-- Admin pricing fixtures: numeric part ids (as distributors print them),
-- a past ERP order line carrying the customer's own item number.
--------------------------------------------------------------------------
insert into erp.dim_part
  (part_key, part_id, part_description, product_code, product_family, chambering,
   barrel_length, finish, stock_color, handedness, status, is_kit_flag)
values
  ('APPK-1', '899-00001-01', 'TEST SMU RIFLE 6.5 CRD 20IN', 'TEST', 'TEST FAMILY', '6.5 CREEDMOOR',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'A', 'N'),
  ('APPK-1M', '899-00001-01-M', 'TEST SMU RIFLE (old)', 'TEST', 'TEST FAMILY', '6.5 CREEDMOOR',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'O', 'N'),
  ('APPK-2', '899-00002-00', 'TEST HISTORY PART', 'TEST', 'TEST FAMILY', '308 WIN',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'A', 'N');

insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, customer_part_id,
                                 unit_price, trade_discount_pct, order_date_key)
values ('AP-HIST-1', 1, 'MO-CUST', 'APPK-2', 'DEALER-SKU-77', 1234.00, 0, to_char(current_date - 40, 'YYYYMMDD')::int);

select pg_temp.flag(true, '{"max_lines": 40, "max_order_value": 250000}'::jsonb);
select pg_temp.become('admin');
insert into public.mcp_order_users (user_id, note)
select id, 'test' from t_user where label in ('rep', 'admin')
on conflict do nothing;
select pg_temp.mint('rep', 'w_rep', array['orders:draft']);
select pg_temp.mint('admin', 'w_admin', array['orders:draft']);

--------------------------------------------------------------------------
-- 1. The reserved admin price list
--------------------------------------------------------------------------
reset role;
select pg_temp.assert(
  (select count(*) = 1 and bool_and(not active) and bool_and(is_special)
     from public.price_lists where is_admin_override)
  and public.admin_price_list_id() is not null,
  'one reserved admin price list, inactive');
select pg_temp.assert(
  not exists (select 1 from public.effective_price_lists('MO-DEALER') l where l.is_admin_override),
  'the admin list is never effective');
select pg_temp.assert_fails(
  $$update public.price_lists set active = true where is_admin_override$$,
  '%admin_override_never_active%', 'the admin list cannot be activated');
select pg_temp.assert_fails(
  $$insert into public.price_list_items (price_list_id, part_id, unit_price)
    values (public.admin_price_list_id(), 'MO-RL-BG', 1)$$,
  'admin_price_list:%', 'the admin list holds no items');
select pg_temp.assert_fails(
  $$delete from public.price_lists where is_admin_override$$,
  'admin_price_list:%', 'the admin list cannot be deleted');

--------------------------------------------------------------------------
-- 2. A rep still cannot price anything
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-rep-price-1',
    '[{"part_id": "MO-RL-BG", "qty": 1, "unit_price": 1500}]')),
  'price_not_allowed:%', 'a rep cannot send unit_price');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-rep-price-2',
    '[{"part_id": "MO-RL-BG", "qty": 1}]', '{"price_override_reason": "because"}')),
  'price_not_allowed:%', 'a rep cannot send price_override_reason');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-rep-price-3',
    '[{"part_id": "MO-RL-BG", "qty": 1, "price": 1500}]')),
  'invalid_input:%', 'other price keys stay refused for everyone');

-- Customer refs are fine for a rep: information for the reviewer only.
select pg_temp.assert(
  (pg_temp.create('rep_ref', pg_temp.req('ap-rep-ref-1',
     '[{"part_id": "MO-RL-BG", "qty": 1, "customer_part_ref": "CHR-RLBG", "customer_description": "Ridgeline black grey"}]'))
     -> 'lines' -> 0 ->> 'customer_part_ref') = 'CHR-RLBG',
  'a rep may pass the PO''s item number and description');

-- A portal session cannot forge an admin-priced line on its own draft.
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$insert into public.order_lines (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price, price_source)
    values (pg_temp.oid('rep_ref'), public.admin_price_list_id(), 'MO-RL-CG', 1, 1, 1, 'admin')$$,
  'protected_line:%', 'a portal session cannot insert an admin-priced line');
select pg_temp.assert_fails(
  $$update public.order_lines set price_source = 'admin' where order_id = pg_temp.oid('rep_ref')$$,
  'protected_line:%', 'a portal session cannot flip a line to admin pricing');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  $$update public.order_lines set qty = 9 where order_id = pg_temp.oid('rep_ref')$$,
  'mcp_direct_write:%', 'an MCP session cannot write lines directly');

--------------------------------------------------------------------------
-- 3. Admin: stage a PO as sent
--------------------------------------------------------------------------
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-admin-noreason',
    '[{"part_id": "MO-RL-CG", "qty": 2, "unit_price": 1700}]')),
  'invalid_input:price_override_reason%', 'admin pricing needs a reason');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-admin-noprice',
    '[{"part_id": "MO-UNP", "qty": 1}]')),
  'part_not_orderable:%send unit_price%', 'an off-list part without a price says to send one');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-admin-unknown',
    '[{"part_id": "CHR-NOPE-1", "qty": 1}]')),
  'part_unknown:%', 'an unknown part without a price is refused');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('ap-admin-badprice',
    '[{"part_id": "MO-UNP", "qty": 1, "unit_price": 10.005}]', '{"price_override_reason": "x"}')),
  'invalid_input:unit_price%', 'prices have at most 2 decimals');

select pg_temp.create('adm', pg_temp.req('ap-admin-po-1',
  '[{"part_id": "MO-RL-BG", "qty": 2, "unit_price": 2000, "customer_part_ref": "CHRMO-RL-BG"},
    {"part_id": "MO-RL-CG", "qty": 2, "unit_price": 1700, "customer_part_ref": "CHRMO-RL-CG"},
    {"part_id": "MO-UNP", "qty": 3, "unit_price": 1500, "customer_description": "SMU unpriced"},
    {"part_id": "CHR-NOPE-1", "qty": 1, "unit_price": 999, "customer_description": "Mystery rifle"}]',
  '{"price_override_reason": "Excess stock buy-in, approved by test", "po_number": "AP-PO-1"}'));

select pg_temp.assert(
  (select count(*) = 4
          and count(*) filter (where part_id = 'MO-RL-BG' and price_source = 'list' and unit_price = 2000
                                 and list_unit_price = 2000 and customer_part_ref = 'CHRMO-RL-BG') = 1
          and count(*) filter (where part_id = 'MO-RL-CG' and price_source = 'admin' and unit_price = 1700
                                 and list_unit_price = 2000
                                 and price_list_id = public.admin_price_list_id()) = 1
          and count(*) filter (where part_id = 'MO-UNP' and price_source = 'admin' and unit_price = 1500
                                 and list_unit_price is null and description is not null) = 1
          and count(*) filter (where part_id = 'CHR-NOPE-1' and part_unresolved and price_source = 'admin'
                                 and customer_part_ref = 'CHR-NOPE-1' and description = 'Mystery rifle') = 1
     from public.order_lines where order_id = pg_temp.oid('adm')),
  'list price stays a list line; a different price, an off-list part and an unknown item are admin lines');
select pg_temp.assert(
  (select price_override_reason = 'Excess stock buy-in, approved by test'
     from public.orders where id = pg_temp.oid('adm')),
  'the reason is on the order');
select pg_temp.assert(
  pg_temp.prev('adm') -> 'warnings' ->> 0 like 'UNMATCHED PARTS:%CHR-NOPE-1%'
  and pg_temp.prev('adm') -> 'warnings' ->> 1 like 'ADMIN PRICING%3 of 4 lines%'
  and (pg_temp.prev('adm') -> 'admin_pricing' ->> 'lines')::int = 3
  and (pg_temp.prev('adm') -> 'admin_pricing' ->> 'below_list')::numeric = 600,
  'the preview leads with UNMATCHED PARTS and ADMIN PRICING');
select pg_temp.assert(
  (pg_temp.prev('adm') -> 'would_submit' ->> 'ok')::boolean = false
  and pg_temp.prev('adm') -> 'would_submit' ->> 'error' like 'unmatched_parts:%',
  'an unmatched line blocks submission');

-- Correct the unknown line (drop it): now it would submit.
select pg_temp.assert(
  (select (j -> 'would_submit' ->> 'ok')::boolean
     from (select public.mcp_update_order_draft(pg_temp.oid('adm'),
       '{"customer_key": "MO-CUST", "ship_to_key": "MO-CUST|1", "ship_to_confirmed": true,
         "po_number": "AP-PO-1",
         "price_override_reason": "Excess stock buy-in, approved by test",
         "lines": [{"part_id": "MO-RL-BG", "qty": 2, "part_confirmed": true},
                   {"part_id": "MO-RL-CG", "qty": 2, "unit_price": 1700, "part_confirmed": true},
                   {"part_id": "MO-UNP", "qty": 3, "unit_price": 1500, "part_confirmed": true}]}'::jsonb) as j) x),
  'with the unmatched line gone the dry run passes (admin, acknowledged)');

--------------------------------------------------------------------------
-- 4. The portal: price controls, trigger, submit
--------------------------------------------------------------------------
select pg_temp.become('admin');
select pg_temp.assert_fails(
  $$update public.order_lines set unit_price = 1 where order_id = pg_temp.oid('adm') and part_id = 'MO-RL-CG'$$,
  'protected_line:%', 'an admin-priced line is not edited directly, even by an admin');

select pg_temp.assert(
  (select (public.admin_set_order_line_price(
            (select id from public.order_lines where order_id = pg_temp.oid('adm') and part_id = 'MO-RL-CG'),
            1800, null) ->> 'unit_price')::numeric = 1800),
  'an admin sets a new price');
select pg_temp.assert(
  (select (j ->> 'price_source') = 'list' and (j ->> 'unit_price')::numeric = 2000
          and (j ->> 'price_list_id')::bigint = (select id from t_ids where label = 'pl')
     from (select public.admin_set_order_line_price(
            (select id from public.order_lines where order_id = pg_temp.oid('adm') and part_id = 'MO-RL-CG'),
            null) as j) x),
  'reset puts the line back on the published price');
select pg_temp.assert(
  (select (public.admin_set_order_line_price(
            (select id from public.order_lines where order_id = pg_temp.oid('adm') and part_id = 'MO-RL-CG'),
            1700) ->> 'price_source') = 'admin'),
  'and back to an admin price');
select pg_temp.assert_fails(
  $$select public.admin_set_order_line_price(
      (select id from public.order_lines where order_id = pg_temp.oid('adm') and part_id = 'MO-UNP'), null)$$,
  'no_list_price:%', 'an off-list part cannot be reset to a list price');

select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select public.admin_set_order_line_price(1, 1)$$,
  'not_admin:%', 'a rep cannot set prices');
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.assert_fails(
  $$select public.admin_set_order_line_price(1, 1)$$,
  'mcp_direct_write:%', 'an MCP session cannot use the portal price control');

select pg_temp.become('admin');
select pg_temp.assert_fails(
  $$select public.submit_order(pg_temp.oid('adm'))$$,
  'acknowledge_required:%', 'admin-priced orders need the acknowledgement');
select pg_temp.assert(
  (select status = 'submitted' and total_amount = 2 * 2000 + 2 * 1700 + 3 * 1500
     from public.submit_order(pg_temp.oid('adm'), true)),
  'an admin submits it, acknowledged, at the admin prices');
select pg_temp.assert(
  (select effective_unit_price = 1700 and discount_pct = 0
     from public.order_lines where order_id = pg_temp.oid('adm') and part_id = 'MO-RL-CG'),
  'admin lines take no promo and keep their price through submit');

-- An order with admin lines owned by a rep (an admin recalled and reassigned
-- it, say) cannot be submitted by the rep.
reset role;
select set_config('request.jwt.claims', '', true);
with o as (
  insert into public.orders (user_id, created_by, customer_key, customer_name, customer_type, status, source, ship_to_key)
  select id, id, 'MO-CUST', 'MCP Test Dealer', 'MO-DEALER', 'draft', 'mcp', 'MO-CUST|1'
  from t_user where label = 'rep'
  returning id
) insert into t_ids select 'rep_admin_lines', id from o;
insert into public.order_lines (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price, price_source)
values (pg_temp.oid('rep_admin_lines'), public.admin_price_list_id(), 'MO-UNP', 1, 10, 10, 'admin');
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select public.submit_order(pg_temp.oid('rep_admin_lines'), true)$$,
  'admin_price_requires_admin:%', 'only an admin submits admin-priced lines');

--------------------------------------------------------------------------
-- 5. order_resolve_parts
--------------------------------------------------------------------------
select pg_temp.become('admin');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'match' = 'digits'
          and j -> 'items' -> 1 ->> 'status' = 'matched'
          and j -> 'items' -> 1 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
          and j -> 'items' -> 2 ->> 'status' = 'matched'
          and j -> 'items' -> 2 -> 'candidates' -> 0 ->> 'part_id' = '899-00002-00'
          and j -> 'items' -> 2 -> 'candidates' -> 0 ->> 'match' = 'customer_history'
          and (j -> 'items' -> 2 -> 'candidates' -> 0 ->> 'last_paid_price')::numeric = 1234
          and j -> 'items' -> 3 ->> 'status' = 'matched'
          and j -> 'items' -> 3 -> 'candidates' -> 0 ->> 'match' = 'exact'
          and (j -> 'items' -> 3 -> 'candidates' -> 0 ->> 'list_price')::numeric = 2000
          and j -> 'items' -> 4 ->> 'status' = 'unmatched'
     from (select public.order_resolve_parts('MO-CUST',
       '[{"ref": "CHR899-00001-01"}, {"ref": "G8990000101"}, {"ref": "dealer-sku-77"},
         {"ref": "MO-RL-BG"}, {"ref": "ZZZ"}]'::jsonb) as j) x),
  'resolve: RSR-style prefix, Zanders-style digits (active part over the -M copy), the customer''s own SKU, exact, nothing');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'check_description'
          and (j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'description_agreement')::numeric = 0
     from (select public.order_resolve_parts('MO-CUST',
       '[{"ref": "899-00002-00", "description": "Christensen Ridgeline 6.5 PRC 22in"}]'::jsonb) as j) x),
  'resolve: a number that matches a part in another chambering is check_description');

-- The draft carries the same check and the customer's last price.
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.create('adm2', pg_temp.req('ap-admin-po-2',
  '[{"part_id": "899-00002-00", "qty": 1, "unit_price": 1200, "customer_part_ref": "DEALER-SKU-77",
     "customer_description": "Christensen Ridgeline 6.5 PRC 22in"},
    {"part_id": "899-00001-01", "qty": 1, "unit_price": 900, "customer_description": "SMU rifle 6.5 Creedmoor 20in"}]',
  '{"price_override_reason": "SMU for this dealer"}'));
select pg_temp.assert(
  (select count(*) filter (where part_id = '899-00002-00' and description_mismatch
                             and last_paid_price = 1234 and last_paid_date = current_date - 40) = 1
          and count(*) filter (where part_id = '899-00001-01' and description_mismatch = false
                                 and last_paid_price is null) = 1
     from public.order_lines where order_id = pg_temp.oid('adm2')),
  'lines carry description_mismatch and the customer''s last paid price');
select pg_temp.assert(
  exists (select 1 from jsonb_array_elements_text(pg_temp.prev('adm2') -> 'warnings') w
          where w like 'DESCRIPTION CHECK:%DEALER-SKU-77 matched to 899-00002-00%')
  and exists (select 1 from jsonb_array_elements_text(pg_temp.prev('adm2') -> 'warnings') w
              where w like 'PRICE VS LAST PAID: 1 %'),
  'the preview warns on the description and on the price vs last paid');

select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select public.order_resolve_parts('MO-OTHER', '[{"ref": "MO-RL-BG"}]')$$,
  'customer_not_in_book:%', 'resolve is limited to the caller''s book');

do $$ begin raise notice 'ALL ADMIN ORDER PRICING TESTS PASSED'; end $$;
rollback;
