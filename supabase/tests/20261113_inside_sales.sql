/*============================================================================
  20261113_inside_sales.sql — assertions for
  20261113090000_inside_sales_and_order_documents: inside sales (order_entry)
  reads every account and changes nothing outside orders; drafts, prices and
  submits orders for any customer; a PO is optional (PORTAL-<id>); the same
  part may sit on two hand-priced lines; order documents follow the order.

  Harness and fixtures copied from 20261111_admin_order_pricing.sql, plus an
  order_entry user. One transaction, ROLLED BACK.

      etl/venv/Scripts/python.exe etl/run_sql_guard.py supabase/tests/20261113_inside_sales.sql

  A clean run prints "ALL INSIDE SALES TESTS PASSED".
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
  ('admin', 'c3c3c3c3-3333-4333-8333-333333333333'),
  ('entry', 'c4c4c4c4-4444-4444-8444-444444444444');
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
update public.profiles set role = 'order_entry'      where user_id = (select id from t_user where label = 'entry');

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


select pg_temp.flag(true, '{"max_lines": 40, "max_order_value": 250000}'::jsonb);
select pg_temp.become('admin');
insert into public.mcp_order_users (user_id, note)
select id, 'test' from t_user where label in ('rep', 'admin', 'entry')
on conflict do nothing;
select pg_temp.mint('rep', 'w_rep', array['orders:draft']);
select pg_temp.mint('entry', 'w_entry', array['orders:draft']);

--------------------------------------------------------------------------
-- 1. Inside sales reads every account
--------------------------------------------------------------------------
select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from erp.dim_customer where customer_key in ('MO-CUST', 'MO-ONE', 'MO-HOLD', 'MO-OTHER')) = 4,
  'inside sales reads accounts on every rep''s book');
select pg_temp.assert(
  (select count(*) from public.my_customer_keys()) = (select count(*) from erp.dim_customer),
  'my_customer_keys() is every customer for inside sales');
select pg_temp.assert(
  (select count(*) from erp.dim_ship_to where customer_id in ('MO-CUST', 'MO-OTHER')) >= 5,
  'inside sales reads ship-tos');
select pg_temp.assert(
  public.has_account_access('MO-OTHER') and public.can_price_orders() and not public.is_admin(),
  'has_account_access and can_price_orders are true; is_admin is not');

select pg_temp.become('rep');
select pg_temp.assert(
  (select count(*) from erp.dim_customer where customer_key = 'MO-OTHER') = 0
  and not public.can_price_orders(),
  'a rep is unchanged: own book only, cannot price');

--------------------------------------------------------------------------
-- 2. ...and changes nothing outside orders
--------------------------------------------------------------------------
select pg_temp.become('entry');
select pg_temp.assert_fails(
  $$insert into public.notes (customer_key, body) values ('MO-CUST', 'x')$$,
  'read_only_role:%', 'inside sales cannot add a note');
select pg_temp.assert_fails(
  $$insert into public.account_goals (customer_key, period_year, target_amount)
    values ('MO-CUST', extract(year from current_date)::int, 1000)$$,
  'read_only_role:%', 'inside sales cannot set a goal');
select pg_temp.assert_fails(
  $$insert into public.contacts (customer_key, name) values ('MO-CUST', 'x')$$,
  'read_only_role:%', 'inside sales cannot add a contact');
select pg_temp.assert(
  pg_temp.rows($$update public.profiles set role = 'admin'$$) = 0,
  'inside sales cannot change a profile, their own included');
select pg_temp.assert_fails(
  $$insert into storage.objects (bucket_id, name) values ('account-photos', 'MO-CUST/x.jpg')$$,
  '%row-level security%', 'inside sales cannot upload an account photo');
reset role;
select pg_temp.assert(
  not exists (
    select 1 from pg_tables t
    where t.schemaname = 'public' and t.rowsecurity
      and t.tablename not in ('orders', 'order_lines', 'order_qc_results', 'order_change_events',
                              'order_line_snapshot', 'mcp_tokens', 'mcp_tool_calls',
                              'support_requests', 'support_messages', 'ai_summaries', 'ai_briefs',
                              'ai_feedback', 'ai_batch_checks', 'ai_usage_events', 'login_events',
                              'job_runs', 'impersonation', 'impersonation_events')
      and not exists (select 1 from pg_trigger g
                      where g.tgrelid = format('public.%I', t.tablename)::regclass
                        and g.tgname = 'trg_' || t.tablename || '_read_only_role')),
  'every RLS table outside the exempt list carries the read-only trigger');

--------------------------------------------------------------------------
-- 3. Inside sales drafts for any customer, at the PO's prices
--------------------------------------------------------------------------
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.create('is1', jsonb_build_object(
  'idempotency_key', 'is-0001-aaaa', 'customer_key', 'MO-OTHER', 'po_number', 'PO-IS-1',
  'customer_contact_key', 'MO-OTHER|C1',
  'price_override_reason', '5% off, agreed with the buyer',
  'lines', '[{"part_id":"MO-RL-BG","qty":10,"unit_price":1900.00,"part_confirmed":true},
             {"part_id":"MO-RL-BG","qty":1,"unit_price":0,"part_confirmed":true},
             {"part_id":"MO-ACC","qty":4,"part_confirmed":true}]'::jsonb));
select pg_temp.assert(
  (select count(*) from public.order_lines where order_id = pg_temp.oid('is1')) = 3
  and (select count(*) from public.order_lines
        where order_id = pg_temp.oid('is1') and part_id = 'MO-RL-BG' and price_source = 'admin') = 2
  and (select price_source from public.order_lines
        where order_id = pg_temp.oid('is1') and part_id = 'MO-ACC') = 'list',
  'another rep''s account, 10 paid + 1 free of the same part, and a list-priced line');
select pg_temp.assert(
  (pg_temp.prev('is1') ->> 'total_amount')::numeric = 10 * 1900 + 0 + 4 * 50,
  'the total is the paid units plus the list line');
select pg_temp.assert_fails(
  pg_temp.create_sql(jsonb_build_object(
    'idempotency_key', 'is-0002-aaaa', 'customer_key', 'MO-OTHER', 'po_number', 'PO-IS-2',
    'price_override_reason', 'x',
    'lines', '[{"part_id":"MO-RL-BG","qty":2,"unit_price":1900,"part_confirmed":true},
               {"part_id":"MO-RL-BG","qty":3,"unit_price":1900,"part_confirmed":true}]'::jsonb)),
  'invalid_input:duplicate_line:%', 'the same part twice at the SAME price is still one line');
select pg_temp.assert_fails(
  pg_temp.create_sql(jsonb_build_object(
    'idempotency_key', 'is-0003-aaaa', 'customer_key', 'MO-OTHER', 'po_number', 'PO-IS-3',
    'lines', '[{"part_id":"MO-ACC","qty":2,"part_confirmed":true},
               {"part_id":"MO-ACC","qty":3,"part_confirmed":true}]'::jsonb)),
  'invalid_input:duplicate_line:%', 'list-priced lines never repeat a part');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-rep-0001', '[{"part_id":"MO-RL-BG","qty":1,"unit_price":1}]')),
  'price_not_allowed:%', 'a rep still cannot send a price');

--------------------------------------------------------------------------
-- 4. The PO is asked for, not required
--------------------------------------------------------------------------
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]') - 'po_number'),
  'po_confirmation_required:%', 'no PO and no word from the user: refused, ask');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]', '{"po_number":"  "}')),
  'po_confirmation_required:%', 'a blank PO is no PO');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]', '{"no_po_confirmed":"yes"}') - 'po_number'),
  'invalid_input:no_po_confirmed:%', 'no_po_confirmed must be a boolean');
select pg_temp.create('nopo', pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":1}]',
                                          '{"no_po_confirmed":true}') - 'po_number');
select pg_temp.assert(
  (select po_number is null from public.orders where id = pg_temp.oid('nopo'))
  and exists (select 1 from jsonb_array_elements(pg_temp.prev('nopo') -> 'alerts') a
              where a ->> 'type' = 'no_customer_po'
                and a ->> 'assigned_reference' = 'PORTAL-' || pg_temp.oid('nopo'))
  and (pg_temp.prev('nopo') -> 'would_submit' ->> 'ok')::boolean,
  'the user said there is none: saved without a PO, flagged, and it would submit');

select pg_temp.become('rep');
select public.submit_order(pg_temp.oid('nopo'), true);
select pg_temp.assert(
  (select po_number = 'PORTAL-' || id and status = 'submitted'
     from public.orders where id = pg_temp.oid('nopo')),
  'submitted without a PO: the order is given PORTAL-<id>');
select pg_temp.assert(
  (select po_number = 'PORTAL-' || order_id from public.v_orders_ready_for_erp
    where order_id = pg_temp.oid('nopo')),
  'and the ERP handoff view shows the same reference');

--------------------------------------------------------------------------
-- 5. Submitting a hand-priced order: its owner in inside sales, or an admin
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, true)', pg_temp.oid('is1')),
  '%only the order''s owner%', 'a rep cannot submit inside sales'' draft');
select pg_temp.become('entry');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, false)', pg_temp.oid('is1')),
  'acknowledge_required:%', 'inside sales must acknowledge a Claude draft');
select pg_temp.assert(
  (select (public.admin_set_order_line_price(
             (select id from public.order_lines where order_id = pg_temp.oid('is1') and part_id = 'MO-ACC'),
             45.00, null) ->> 'price_source') = 'admin'),
  'inside sales sets a line price in the portal');
select public.submit_order(pg_temp.oid('is1'), true);
select pg_temp.assert(
  (select status = 'submitted' and po_number = 'PO-IS-1'
          and acknowledged_by = (select id from t_user where label = 'entry')
          and total_amount = 10 * 1900 + 0 + 4 * 45
     from public.orders where id = pg_temp.oid('is1')),
  'inside sales submits their own hand-priced order; a given PO is kept');
select pg_temp.assert(
  (select jsonb_array_length(lines) = 3 and price_override_reason = '5% off, agreed with the buyer'
          and (select count(*) from jsonb_array_elements(lines) l where l ->> 'price_source' = 'admin') = 3
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('is1')),
  'the handoff view carries the price source and the reason');
select pg_temp.assert(
  (select contact_name = 'Someone' and contact_email = 'x@other.test' and contact_phone is null
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('is1'))
  and (select contact_name is null from public.orders where id = pg_temp.oid('nopo')),
  'the buyer contact is snapshotted at submit (none chosen: none stamped)');

-- A rep's own draft that an admin priced by hand: the rep still cannot submit it.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('repd', pg_temp.req('is-rep-0002', '[{"part_id":"MO-ACC","qty":2}]'));
select pg_temp.become('admin');
select public.admin_set_order_line_price(
  (select id from public.order_lines where order_id = pg_temp.oid('repd')), 40.00, 'show special');
select pg_temp.become('rep');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, true)', pg_temp.oid('repd')),
  'admin_price_requires_admin:%', 'a rep cannot submit a hand-priced order');

-- Keying it: inside sales records the ERP number as before (orders are exempt
-- from the read-only trigger).
select pg_temp.become('entry');
select public.mark_order_entered(pg_temp.oid('is1'), 'EDI-90001');
select pg_temp.assert(
  (select status = 'entered' and erp_order_number = 'EDI-90001'
     from public.orders where id = pg_temp.oid('is1')),
  'inside sales marks the order entered');

--------------------------------------------------------------------------
-- 6. Order documents follow the order
--------------------------------------------------------------------------
select pg_temp.assert(
  public.order_document_order_id('123/po.pdf') = 123
  and public.order_document_order_id('123') is null
  and public.order_document_order_id('abc/po.pdf') is null
  and public.order_document_order_id('../123/po.pdf') is null
  and public.order_document_order_id('') is null,
  'the order id is the first path segment, and only a number');

select pg_temp.become('rep');   -- MO-CUST is on their book; 'repd' is their order
insert into storage.objects (bucket_id, name, owner)
values ('order-documents', pg_temp.oid('repd') || '/1-po.pdf', (select id from t_user where label = 'rep'));
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 1,
  'a rep adds and reads a document on their own order');
select pg_temp.assert_fails(
  format($$insert into storage.objects (bucket_id, name) values ('order-documents', '%s/x.pdf')$$, pg_temp.oid('is1')),
  '%row-level security%', 'but not on an order they cannot read');
select pg_temp.assert_fails(
  $$insert into storage.objects (bucket_id, name) values ('order-documents', 'loose.pdf')$$,
  '%row-level security%', 'nor outside an order folder');

select pg_temp.become('rep2');
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 0,
  'another rep sees none of it');

select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 1,
  'inside sales reads the document on a rep''s order');
insert into storage.objects (bucket_id, name, owner)
values ('order-documents', pg_temp.oid('is1') || '/2-signed-po.pdf', (select id from t_user where label = 'entry'));
select pg_temp.assert(
  pg_temp.rows($$delete from storage.objects where bucket_id = 'order-documents'$$) = 2,
  'inside sales adds one after the order was entered, and may remove documents');

do $$ begin raise notice 'ALL INSIDE SALES TESTS PASSED'; end $$;
rollback;
