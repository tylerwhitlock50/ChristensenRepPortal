/*============================================================================
  20261112_mcp_order_confirmations.sql — assertions for
  20261112090000_mcp_order_confirmations: the order-drafting confirmations
  are enforced in Postgres, not just asked for in the prompt.

  Covers: same-name accounts need customer_confirmed (choices in DETAIL);
  more than one orderable ship-to needs ship_to_key + ship_to_confirmed
  (choices with FFL number / expiry / current in DETAIL), one does not;
  every line needs part_confirmed (choices = the part and its siblings);
  po_number required; expected_unit_price -> price_mismatch alert (and none
  when it matches); an expired-FFL ship-to is orderable with a hard
  ffl_not_current alert; is_test drafts are labelled and never submit, and
  a portal session cannot set or clear is_test; the line description is the
  ERP part's, not the uploaded sheet's UPC; a nameless contact is named by
  its e-mail; order_context reports same_name_accounts, FFL expires_on and
  the last ETL run as data_as_of.

  Same harness as 20261111_mcp_orders.sql: one transaction, ROLLED BACK.

      python etl/run_sql_guard.py supabase/tests/20261112_mcp_order_confirmations.sql

  A clean run prints "ALL MCP ORDER CONFIRMATION TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'd1d1d1d1-1111-4111-8111-111111111111'),
  ('admin', 'd3d3d3d3-3333-4333-8333-333333333333');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@mcpconfirm.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'CF REP' where user_id = (select id from t_user where label = 'rep');
update public.profiles set role = 'admin'           where user_id = (select id from t_user where label = 'admin');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag, credit_status, sold_to_city, sold_to_state)
values ('CF-A1', 'CF-A1', 'CFX''S SPORTING GOODS',       'CF REP', 'CF-TYPE', 'Y', 'APPROVED', 'Logan', 'UT'),
       ('CF-A2', 'CF-A2', 'CFXs Sporting Goods LLC',   'CF REP', null,      'Y', 'APPROVED', 'Orem',  'UT'),
       ('CF-A3', 'CF-A3', 'CFXS SPORTING GOODS',         'CF REP', 'CF-TYPE', 'N', 'APPROVED', 'Boise', 'ID'),
       ('CF-B',  'CF-B',  'CFX Unique Range',           'CF REP', 'CF-TYPE', 'Y', 'APPROVED', 'Logan', 'UT');

insert into erp.dim_ship_to
  (ship_to_key, customer_id, addr_no, ship_to_id, ship_to_name, address1, city, state, zip_code,
   active_flag, ffl_license_number, ffl_expiration_raw, address_source, is_unknown_ship_to)
values
  ('CF-A1|1', 'CF-A1', 1, '001', 'Main Store', '1 Main', 'Logan', 'UT', '84321',
   'Y', '1-87-000-01-2A-11111', '01/31/2028', 'ShipTo', false),
  ('CF-B|1', 'CF-B', 1, '191.002', 'Logan North', '2 North', 'Logan', 'UT', '84321',
   'Y', '1-87-000-01-2A-22222', '01/31/2028', 'ShipTo', false),
  ('CF-B|2', 'CF-B', 2, '003', 'Orem Store', '3 State', 'Orem', 'UT', '84057',
   'Y', '1-87-000-01-2A-33333', '09/01/2026', 'ShipTo', false),
  ('CF-B|3', 'CF-B', 3, 'OLD', 'Closed', '4 Gone', 'Provo', 'UT', '84601',
   'N', null, null, 'ShipTo', false);

insert into erp.dim_customer_contact
  (customer_contact_key, customer_key, contact_id, contact_name, first_name, last_name, email, primary_contact_flag, contact_active_flag)
values ('CF-B|0027570', 'CF-B', '0027570', null, null, null, 'buyer@cfx.test', 'Y', 'Y');

insert into erp.dim_part
  (part_key, part_id, part_description, product_code, product_family, chambering,
   barrel_length, finish, stock_color, handedness, status, is_kit_flag)
values
  ('CFPK-RH', 'CF-RH', 'RL FFT, BB, 300 PRC, 22 IN, CBN/GRY', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '300 PRC', '22', 'CARBON', 'CARBON / GRAY', 'RIGHT', 'A', 'N'),
  ('CFPK-LH', 'CF-LH', 'RL FFT, LH BB, 300 PRC, 22 IN, CBN/GRY', 'RIDGELINE FFT',
   'RIDGELINE FLASH FORGED TECHNOLOGY', '300 PRC', '22', 'CARBON', 'CARBON / GRAY', 'LEFT', 'A', 'N'),
  ('CFPK-TI', 'CF-TI', 'RL FFT, TI BB, 300 PRC, 22 IN, CBN/MTLC GRY', 'RIDGELINE FFT',
   'RIDGELINE TITANIUM FLASH FORGED TECHNOLOGY', '300 PRC', '22', 'CARBON', 'CARBON / METALLIC GRAY', 'RIGHT', 'A', 'N'),
  ('CFPK-ACC', 'CF-ACC', 'Scope rings', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N');

create temporary table t_ids (label text primary key, id bigint) on commit drop;
create temporary table t_tok (label text primary key, id uuid, token text) on commit drop;
grant select, insert, update on t_ids, t_tok to authenticated;

with g as (
  insert into public.price_lists (name, customer_type, is_special, effective_from)
  values ('CF Buy Group', 'CF-TYPE', false, current_date - 30) returning id
) insert into t_ids select 'pl', id from g;
-- The Buy Group sheet put the UPC in the description column.
insert into public.price_list_items (price_list_id, part_id, unit_price, description)
select (select id from t_ids where label = 'pl'), v.part, v.price, v.upc
from (values ('CF-RH', 1566.67, '696528091165'), ('CF-LH', 1566.67, '696528091172'),
             ('CF-TI', 2310.79, '696528091189'), ('CF-ACC', 50.00, '696528000000')) v(part, price, upc);

update public.app_settings set enabled = true where setting_key = 'feature.orders';

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from t_user where label = p_label), 'role', 'authenticated',
                      'app_metadata', json_build_object('provider', 'email'))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.become_mcp(p_label text, p_token_label text) returns void
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

create or replace function pg_temp.assert(p_ok boolean, p_what text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

-- Run p_sql, expect a refusal LIKE p_like; return {message, detail(jsonb)}.
create or replace function pg_temp.refusal(p_sql text, p_like text, p_what text) returns jsonb
language plpgsql as $$
declare
  v_msg text;
  v_det text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_det = pg_exception_detail;
    if v_msg not ilike p_like then
      raise exception 'FAILED: % — rejected, but with "%"', p_what, v_msg;
    end if;
    raise notice 'ok  % (rejected: %)', p_what, v_msg;
    return jsonb_build_object('message', v_msg,
                              'detail', case when v_det like '{%' then v_det::jsonb end);
  end;
  raise exception 'FAILED: % — statement succeeded but should have been rejected', p_what;
end $$;

create or replace function pg_temp.create_sql(p jsonb) returns text
language sql as $$ select format('select public.mcp_create_order_draft(%L::jsonb)', p) $$;

-- A complete, confirmed CF-B request; p_extra overrides.
create or replace function pg_temp.req(p_key text, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object(
    'idempotency_key', p_key, 'customer_key', 'CF-B',
    'ship_to_key', 'CF-B|1', 'ship_to_confirmed', true,
    'po_number', 'PO-' || p_key,
    'lines', jsonb_build_array(jsonb_build_object('part_id', 'CF-RH', 'qty', 1, 'part_confirmed', true))) || p_extra
$$;

--------------------------------------------------------------------------
-- Setup: allow-list, flag, tokens
--------------------------------------------------------------------------
reset role;
update public.app_settings set enabled = true where setting_key = 'feature.mcp_orders';
select pg_temp.become('admin');
insert into public.mcp_order_users (user_id, note)
select id, 'confirmation test' from t_user;

select pg_temp.become('rep');
insert into t_tok select 'rep', r.token_id, r.token from public.mcp_token_create('cf rep', p_scopes => '{}') r;
select pg_temp.become('admin');
insert into t_tok select 'admin', r.token_id, r.token from public.mcp_token_create('cf admin', p_scopes => '{}') r;

--------------------------------------------------------------------------
-- 1. Catalog
--------------------------------------------------------------------------
reset role;
select pg_temp.assert(
  exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'orders' and column_name = 'is_test'
            and is_nullable = 'NO' and column_default = 'false')
  and exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'order_lines' and column_name = 'mcp_expected_unit_price'),
  'orders.is_test (not null, default false) and order_lines.mcp_expected_unit_price exist');
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.order_ship_to_choices(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.order_part_choices(text,text,integer)', 'execute')
  and has_function_privilege('authenticated', 'public.order_same_name_accounts(text)', 'execute'),
  'choice helpers are internal; same-name lookup is RLS-scoped and callable');
select pg_temp.assert(
  public.customer_name_key('AL''S SPORTING GOODS') = public.customer_name_key('Als Sporting Goods')
  and public.customer_name_key('Sports South LLC') = public.customer_name_key('SPORTS SOUTH')
  and public.customer_name_key('Sports South') <> public.customer_name_key('Mark Miller - Sports South'),
  'customer_name_key: apostrophes, case and a trailing LLC do not make a new name');

--------------------------------------------------------------------------
-- 2. order_context
--------------------------------------------------------------------------
select pg_temp.become('rep');
create temporary table t_ctx on commit drop as
  select public.order_context('CF-B') b, public.order_context('CF-A1') a;
select pg_temp.assert(
  (select (b ->> 'data_as_of')::timestamptz is not distinct from (select data_loaded_at from public.v_data_freshness)
          and b ? 'account_changed_at'
     from t_ctx),
  'data_as_of is the last ETL run, not the account row''s own stamp');
select pg_temp.assert(
  (select jsonb_array_length(a -> 'same_name_accounts') = 2
          and a -> 'same_name_accounts' -> 0 ->> 'customer_key' = 'CF-A1'
          and (a -> 'same_name_accounts' -> 0 ->> 'this_one')::boolean
          and a -> 'same_name_accounts' -> 1 ->> 'customer_key' = 'CF-A2'
          and not (a -> 'same_name_accounts' -> 1 ->> 'has_price_list')::boolean
          and jsonb_array_length(b -> 'same_name_accounts') = 0
     from t_ctx),
  'same_name_accounts: active look-alikes (inactive CF-A3 left out), this one first; [] when unique');
select pg_temp.assert(
  (select (b ->> 'orderable_ship_to_count')::int = 2
          and exists (select 1 from jsonb_array_elements(b -> 'ship_tos') s
                      where s ->> 'ship_to_key' = 'CF-B|2' and (s -> 'ffl' ->> 'expires_on')::date = date '2026-09-01'
                        and not (s -> 'ffl' ->> 'current')::boolean and (s ->> 'orderable')::boolean)
          and exists (select 1 from jsonb_array_elements(b -> 'contacts') c
                      where c ->> 'customer_contact_key' = 'CF-B|0027570' and c ->> 'name' = 'buyer@cfx.test')
     from t_ctx),
  'ship-tos carry the parsed FFL expiry (an expired one stays orderable); a nameless contact is named by e-mail');

--------------------------------------------------------------------------
-- 3. Account confirmation
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'rep');
create temporary table t_r on commit drop as
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-acct-0001', '{"customer_key":"CF-A1","ship_to_key":"CF-A1|1"}')),
  'customer_confirmation_required:CF-A1:%', 'two active accounts with this name: refused without customer_confirmed') j;
select pg_temp.assert(
  (select j -> 'detail' ->> 'error' = 'customer_confirmation_required'
          and jsonb_array_length(j -> 'detail' -> 'choices') = 2
          and (select bool_and(c ? 'city' and c ? 'has_price_list' and c ? 'orderable_ship_tos')
                 from jsonb_array_elements(j -> 'detail' -> 'choices') c)
     from t_r),
  'the refusal DETAIL lists the accounts to choose from');
select pg_temp.assert(
  (select public.mcp_create_order_draft(pg_temp.req('cf-acct-0001',
     '{"customer_key":"CF-A1","ship_to_key":"CF-A1|1","customer_confirmed":true}')) ->> 'status') = 'draft',
  'customer_confirmed: true drafts it (one ship-to: no ship-to confirmation needed)');
select pg_temp.assert(
  (select public.mcp_create_order_draft(pg_temp.req('cf-acct-0002',
     '{"customer_key":"CF-A1","customer_confirmed":true,"lines":[{"part_id":"CF-ACC","qty":1,"part_confirmed":true}]}') - 'ship_to_key' - 'ship_to_confirmed')
     -> 'ship_to' ->> 'ship_to_key') = 'CF-A1|1',
  'the only orderable ship-to is used without asking');

--------------------------------------------------------------------------
-- 4. Ship-to confirmation
--------------------------------------------------------------------------
truncate t_r;
insert into t_r
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-ship-0001') - 'ship_to_key' - 'ship_to_confirmed'),
  'ship_to_confirmation_required:CF-B:%', 'two orderable ship-tos and none given: refused');
select pg_temp.assert(
  (select j -> 'detail' ->> 'error' = 'ship_to_confirmation_required'
          and jsonb_array_length(j -> 'detail' -> 'choices') = 2
          and j -> 'detail' -> 'choices' -> 0 ->> 'ship_to_key' = 'CF-B|1'
          and (j -> 'detail' -> 'choices' -> 0 ->> 'ffl_current')::boolean
          and j -> 'detail' -> 'choices' -> 0 ->> 'ffl_number' = '1-87-000-01-2A-22222'
          and j -> 'detail' -> 'choices' -> 1 ->> 'ship_to_key' = 'CF-B|2'
          and not (j -> 'detail' -> 'choices' -> 1 ->> 'ffl_current')::boolean
          and (j -> 'detail' -> 'choices' -> 1 ->> 'ffl_expires')::date = date '2026-09-01'
          and (select bool_and(c ?& array['ship_to_id', 'name', 'address', 'city', 'state'])
                 from jsonb_array_elements(j -> 'detail' -> 'choices') c)
     from t_r),
  'the DETAIL lists the orderable ship-tos (inactive left out), current FFL first, with number and expiry');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-ship-0001') - 'ship_to_confirmed'),
  'ship_to_confirmation_required:CF-B:%', 'a ship_to_key without ship_to_confirmed: refused');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-ship-0001', '{"ship_to_confirmed":false}')),
  'ship_to_confirmation_required:CF-B:%', 'ship_to_confirmed false: refused');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-ship-0001', '{"ship_to_confirmed":"yes"}')),
  'invalid_input:ship_to_confirmed:%', 'a non-boolean confirmation is invalid, not truthy');
select pg_temp.assert(
  (select public.mcp_create_order_draft(pg_temp.req('cf-ship-0001')) -> 'ship_to' ->> 'ship_to_key') = 'CF-B|1',
  'ship_to_key + ship_to_confirmed drafts it');

--------------------------------------------------------------------------
-- 5. Part confirmation
--------------------------------------------------------------------------
truncate t_r;
insert into t_r
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-part-0001',
    '{"lines":[{"part_id":"CF-RH","qty":1},{"part_id":"CF-ACC","qty":2,"part_confirmed":true}]}')),
  'part_confirmation_required:CF-RH:%', 'a line without part_confirmed: refused');
select pg_temp.assert(
  (select j -> 'detail' ->> 'error' = 'part_confirmation_required'
          and jsonb_array_length(j -> 'detail' -> 'lines') = 1
          and (j -> 'detail' -> 'lines' -> 0 ->> 'line')::int = 0
          and j -> 'detail' -> 'lines' -> 0 -> 'choices' -> 0 ->> 'part_id' = 'CF-RH'
          and (j -> 'detail' -> 'lines' -> 0 -> 'choices' -> 0 ->> 'as_sent')::boolean
          and (select array_agg(c ->> 'part_id' order by c ->> 'part_id')
                 from jsonb_array_elements(j -> 'detail' -> 'lines' -> 0 -> 'choices') c) = array['CF-LH', 'CF-RH', 'CF-TI']
          and (select bool_and(c ?& array['handedness', 'family', 'stock_color', 'unit_price', 'price_list'])
                 from jsonb_array_elements(j -> 'detail' -> 'lines' -> 0 -> 'choices') c)
     from t_r),
  'the DETAIL names the unconfirmed line and offers the part with its RH/LH/Ti siblings');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-part-0001',
    '{"lines":[{"part_id":"CF-RH","qty":1,"part_confirmed":false}]}')),
  'part_confirmation_required:%', 'part_confirmed false: refused');

--------------------------------------------------------------------------
-- 6. PO required
--------------------------------------------------------------------------
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-po-0001') - 'po_number'),
  'po_required:%', 'no PO: refused');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-po-0001', '{"po_number":"   "}')),
  'po_required:%', 'a blank PO: refused');

--------------------------------------------------------------------------
-- 7. Expected price, description, contact, expired FFL
--------------------------------------------------------------------------
create temporary table t_p (label text primary key, j jsonb) on commit drop;
grant select, insert on t_p to authenticated;
insert into t_p
select 'mismatch', public.mcp_create_order_draft(pg_temp.req('cf-price-0001',
  '{"customer_contact_key":"CF-B|0027570","lines":[{"part_id":"CF-LH","qty":1,"part_confirmed":true,"expected_unit_price":1485}]}'));
select pg_temp.assert(
  (select j -> 'alerts' @> '[{"type":"price_mismatch","part_id":"CF-LH","expected":1485.00,"list":1566.67,"price_list":"CF Buy Group"}]'
          and (j -> 'lines' -> 0 ->> 'unit_price')::numeric = 1566.67
          and (j -> 'lines' -> 0 ->> 'expected_unit_price')::numeric = 1485
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w
                      where w like 'Price: the user expected $1,485.00 for CF-LH; CF Buy Group prices it at $1,566.67 (+$81.67 each)%')
     from t_p where label = 'mismatch'),
  'expected_unit_price: line still at the list price; price_mismatch alert and a warning for the reviewer');
select pg_temp.assert(
  (select j -> 'lines' -> 0 ->> 'description' = 'RL FFT, LH BB, 300 PRC, 22 IN, CBN/GRY'
          and j -> 'contact' ->> 'name' = 'buyer@cfx.test'
     from t_p where label = 'mismatch')
  and (select description = 'RL FFT, LH BB, 300 PRC, 22 IN, CBN/GRY' and mcp_expected_unit_price = 1485
         from public.order_lines where order_id = (select (j ->> 'order_id')::bigint from t_p where label = 'mismatch')),
  'the line description is the ERP part''s, not the sheet''s UPC; a nameless contact shows its e-mail');

insert into t_p
select 'match', public.mcp_create_order_draft(pg_temp.req('cf-price-0002',
  '{"lines":[{"part_id":"CF-TI","qty":1,"part_confirmed":true,"expected_unit_price":2310.79}]}'));
select pg_temp.assert(
  (select not (j -> 'alerts' @> '[{"type":"price_mismatch"}]') from t_p where label = 'match'),
  'an expected price that matches raises no alert');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-price-0003',
    '{"lines":[{"part_id":"CF-RH","qty":1,"part_confirmed":true,"expected_unit_price":-5}]}')),
  'invalid_input:expected_unit_price:%', 'a negative expected price is invalid');
select pg_temp.refusal(pg_temp.create_sql(pg_temp.req('cf-price-0003',
    '{"lines":[{"part_id":"CF-RH","qty":1,"part_confirmed":true,"unit_price":1485}]}')),
  'invalid_input:unit_price:%', 'unit_price is still never accepted');

insert into t_p
select 'expired', public.mcp_create_order_draft(pg_temp.req('cf-ffl-0001',
  '{"ship_to_key":"CF-B|2","lines":[{"part_id":"CF-RH","qty":2,"part_confirmed":true}]}'));
select pg_temp.assert(
  (select j ->> 'status' = 'draft'
          and j -> 'alerts' @> '[{"type":"ffl_not_current","severity":"hard","ship_to_id":"003","ffl_expires":"2026-09-01"}]'
          and not (j -> 'would_submit' ->> 'ok')::boolean
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w
                      where w like 'FFL: ship-to 003 has an FFL on file that expired 2026-09-01%')
     from t_p where label = 'expired'),
  'an expired-FFL ship-to drafts with a hard ffl_not_current alert; it would not submit');

--------------------------------------------------------------------------
-- 8. Test orders
--------------------------------------------------------------------------
insert into t_p
select 'test', public.mcp_create_order_draft(pg_temp.req('cf-test-0001',
  '{"is_test":true,"lines":[{"part_id":"CF-ACC","qty":3,"part_confirmed":true}]}'));
select pg_temp.assert(
  (select (j ->> 'is_test')::boolean
          and j -> 'alerts' @> '[{"type":"test_order"}]'
          and not (j -> 'would_submit' ->> 'ok')::boolean
          and j -> 'would_submit' ->> 'error' like 'test_order:%'
     from t_p where label = 'test')
  and (select is_test from public.orders where id = (select (j ->> 'order_id')::bigint from t_p where label = 'test')),
  'is_test: stored, flagged, and the dry run says it cannot be submitted');

-- Codex review on PR #59: an update that leaves is_test out (or sends
-- false) must not turn a test draft into a submittable one.
select pg_temp.assert(
  (select (public.mcp_update_order_draft((select (j ->> 'order_id')::bigint from t_p where label = 'test'),
     '{"customer_key":"CF-B","ship_to_key":"CF-B|1","ship_to_confirmed":true,"po_number":"PO-cf-test-0001","lines":[{"part_id":"CF-ACC","qty":5,"part_confirmed":true}]}')
     ->> 'is_test')::boolean)
  and (select (public.mcp_update_order_draft((select (j ->> 'order_id')::bigint from t_p where label = 'test'),
     '{"customer_key":"CF-B","ship_to_key":"CF-B|1","ship_to_confirmed":true,"po_number":"PO-cf-test-0001","is_test":false,"lines":[{"part_id":"CF-ACC","qty":6,"part_confirmed":true}]}')
     ->> 'is_test')::boolean)
  and (select is_test from public.orders where id = (select (j ->> 'order_id')::bigint from t_p where label = 'test')),
  'an update keeps a test draft a test, whether is_test is left out or sent as false');

select pg_temp.become('rep');
select pg_temp.refusal(
  format('select public.submit_order(%s, true)', (select (j ->> 'order_id')::bigint from t_p where label = 'test')),
  'test_order:%', 'a person cannot submit a test draft either');
select pg_temp.refusal(
  format('update public.orders set is_test = false where id = %s', (select (j ->> 'order_id')::bigint from t_p where label = 'test')),
  'protected_column:%', 'the portal cannot clear is_test');
select pg_temp.refusal(
  format('update public.orders set is_test = true where id = %s', (select (j ->> 'order_id')::bigint from t_p where label = 'match')),
  'protected_column:%', 'nor set it');
select pg_temp.assert(
  (select (public.submit_order((select (j ->> 'order_id')::bigint from t_p where label = 'match'), true)).status = 'submitted'),
  'a confirmed, non-test MCP draft still submits with the acknowledgement');
select public.cancel_order((select (j ->> 'order_id')::bigint from t_p where label = 'test'));
select pg_temp.assert(
  (select status = 'cancelled' from public.orders where id = (select (j ->> 'order_id')::bigint from t_p where label = 'test')),
  'a test draft can be cancelled in the portal');

--------------------------------------------------------------------------
-- 9. Update is a full replacement: confirmations again
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'rep');
select pg_temp.refusal(
  format($$select public.mcp_update_order_draft(%s, '{"customer_key":"CF-B","po_number":"PO-X","lines":[{"part_id":"CF-RH","qty":1,"part_confirmed":true}]}')$$,
         (select (j ->> 'order_id')::bigint from t_p where label = 'expired')),
  'ship_to_confirmation_required:%', 'update without the ship-to confirmation: refused');
select pg_temp.assert(
  (select public.mcp_update_order_draft((select (j ->> 'order_id')::bigint from t_p where label = 'expired'),
     '{"customer_key":"CF-B","ship_to_key":"CF-B|1","ship_to_confirmed":true,"po_number":"PO-X","lines":[{"part_id":"CF-RH","qty":4,"part_confirmed":true}]}')
     -> 'would_submit' ->> 'ok')::boolean,
  'update with every confirmation moves it to the current-FFL store, and it would submit');

do $$ begin raise notice 'ALL MCP ORDER CONFIRMATION TESTS PASSED'; end $$;
rollback;
