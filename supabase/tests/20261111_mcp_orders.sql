/*============================================================================
  20261111_mcp_orders.sql — assertions for 20261111100000_mcp_order_drafting
  and 20261111100100_mcp_order_rpcs: Claude drafts portal orders over MCP and
  never submits. Since 20261111150000_mcp_orders_any_token the gate ignores
  token scopes: any live MCP token of an allowed, active user may draft.

  Covers: the feature flag, the mcp_order_users allow-list (admin-only
  writes, own-row reads, never from an MCP session), and token scopes (the 3-arg mcp_token_create is
  gone, resolve returns scopes); every mcp_orders_gate refusal; customer
  scope for a rep vs an admin; no price/FFL inputs; caps; idempotent replay
  and conflict; the duplicate block and its override; the submit dry run
  leaves a draft and reports ship-to / FFL problems; update/cancel refused
  on submitted and portal orders; a portal session cannot forge provenance
  or the acknowledgement; submit_order needs the acknowledgement for MCP
  orders and stamps it, portal orders submit as before; the audit log; the
  middleware view; product search from a messy spoken phrase.

  Same harness as 20261030_order_ship_to_ffl.sql / 034_mcp_access.sql: one
  transaction, ROLLED BACK, throwaway users and ERP rows. JWTs are faked
  with request.jwt.claims, with and without app_metadata.provider='mcp'.

      psql "$DATABASE_URL" -f supabase/tests/20261111_mcp_orders.sql

  A clean run prints "ALL MCP ORDER TESTS PASSED"; any error is a failure.
============================================================================*/

begin;

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
-- 1. Catalog: signatures, grants, the seeded setting
--------------------------------------------------------------------------
select pg_temp.assert(
  to_regprocedure('public.mcp_token_create(text,uuid,integer)') is null
  and to_regprocedure('public.mcp_token_create(text,uuid,integer,text[])') is not null,
  'the 3-arg mcp_token_create is gone; the 4-arg one exists');
select pg_temp.assert(
  to_regprocedure('public.submit_order(bigint)') is null
  and to_regprocedure('public.submit_order(bigint,boolean)') is not null,
  'submit_order is (bigint, boolean default false)');
select pg_temp.assert(
  pg_get_function_result('public.mcp_token_resolve(text)'::regprocedure) like '%scopes text[]%',
  'mcp_token_resolve returns scopes');
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.mcp_token_resolve(text)', 'execute')
  and has_function_privilege('service_role', 'public.mcp_token_resolve(text)', 'execute')
  and has_function_privilege('authenticated', 'public.mcp_token_create(text,uuid,integer,text[])', 'execute')
  and not has_function_privilege('anon', 'public.mcp_token_create(text,uuid,integer,text[])', 'execute')
  and has_function_privilege('authenticated', 'public.submit_order(bigint,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.submit_order(bigint,boolean)', 'execute'),
  'token/submit grants as before');
select pg_temp.assert(
  (select bool_and(has_function_privilege('authenticated', f, 'execute')
                   and not has_function_privilege('anon', f, 'execute'))
     from unnest(array['public.mcp_create_order_draft(jsonb)', 'public.mcp_update_order_draft(bigint,jsonb)',
                       'public.mcp_cancel_order_draft(bigint)', 'public.mcp_log_call(text,jsonb,text,text,bigint)',
                       'public.order_context(text)', 'public.order_product_search(text,text,integer)']) f)
  and not has_function_privilege('authenticated', 'public.mcp_order_apply(bigint,jsonb,jsonb,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.mcp_order_preview(bigint,boolean)', 'execute'),
  'mcp_* RPCs: authenticated yes, anon no; internals unreachable');
select pg_temp.assert(
  (select not (params ? 'allowed_user_ids')
          and (params ->> 'max_lines')::int = 40 and (params ->> 'max_units_per_line')::int = 200
          and (params ->> 'max_order_value')::numeric = 250000
          and (params ->> 'max_drafts_per_user_per_day')::int = 25
          and (params ->> 'duplicate_window_days')::int = 14
     from public.app_settings where setting_key = 'feature.mcp_orders'),
  'feature.mcp_orders carries the caps and no allowed_user_ids param');
-- Seeded OFF, but production has since turned it on (2026-11-11): start
-- every run from OFF (rolled back with everything else).
select pg_temp.flag(false);
select pg_temp.assert(
  has_table_privilege('authenticated', 'public.mcp_order_users', 'select')
  and has_table_privilege('authenticated', 'public.mcp_order_users', 'insert')
  and has_table_privilege('authenticated', 'public.mcp_order_users', 'delete')
  and not has_table_privilege('authenticated', 'public.mcp_order_users', 'update')
  and not has_table_privilege('anon', 'public.mcp_order_users', 'select')
  and not has_table_privilege('anon', 'public.mcp_order_users', 'insert')
  and (select relrowsecurity from pg_class where oid = 'public.mcp_order_users'::regclass)
  and not has_function_privilege('authenticated', 'public.mcp_orders_user_allowed(uuid)', 'execute'),
  'mcp_order_users: RLS on; authenticated select/insert/delete, no update; anon nothing');
select pg_temp.assert(
  not exists (select 1 from public.mcp_order_users where user_id in (select id from t_user)),
  'no test user starts on the order-drafting list');

--------------------------------------------------------------------------
-- 2. Token scopes
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select * from public.mcp_token_create('w', p_scopes => array['orders:draft'])$$,
  'mcp_orders_disabled:%', 'no write token while the flag is off');

select pg_temp.flag(true);
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select * from public.mcp_token_create('w', p_scopes => array['orders:draft'])$$,
  'mcp_user_not_allowed:%', 'no write token without an mcp_order_users row');
select pg_temp.assert_fails(
  $$select * from public.mcp_token_create('w', p_scopes => array['orders:submit'])$$,
  'invalid_scope:%', 'orders:draft is the only scope');

-- The allow-list: only an admin, in a portal session, adds people.
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$insert into public.mcp_order_users (user_id) select id from t_user where label = 'rep'$$,
  '%row-level security%', 'a rep cannot add themselves to the order-drafting list');

select pg_temp.become('admin');
-- rep2's row names someone else (and admin's names null) as added_by: the
-- insert trigger overwrites both with the caller, so attribution can't be faked.
insert into public.mcp_order_users (user_id, note, added_by)
select id, 'test',
       case label when 'rep2' then (select id from t_user where label = 'rep') end
from t_user where label in ('rep', 'rep2', 'admin');
select pg_temp.assert(
  (select count(*) = 3 and bool_and(added_by is not distinct from (select id from t_user where label = 'admin'))
                       and bool_and(added_at is not null)
     from public.mcp_order_users where user_id in (select id from t_user)),
  'an admin adds people; added_by is always that admin, whatever the insert says');
select pg_temp.assert_fails(
  $$update public.mcp_order_users set note = 'x' where user_id in (select id from t_user)$$,
  '%permission denied%', 'no UPDATE on the allow-list (delete + insert instead)');

select pg_temp.become('rep');
select pg_temp.assert(
  (select count(*) = 1 and bool_and(user_id = (select id from t_user where label = 'rep'))
     from public.mcp_order_users),
  'a rep sees only their own row');
select pg_temp.assert(
  pg_temp.rows($$delete from public.mcp_order_users where user_id in (select id from t_user)$$) = 0,
  'a rep cannot remove anyone, themselves included');

select pg_temp.mint('rep', 'w_rep', array['orders:draft']);
select pg_temp.mint('rep', 'ro_rep', '{}');
select pg_temp.mint('admin', 'w_admin', array['orders:draft']);
select pg_temp.mint('rep2', 'w_rep2_revoked', array['orders:draft']);

-- Claude can never change who may draft, not even on an admin's token.
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.assert_fails(
  $$delete from public.mcp_order_users where user_id = (select id from t_user where label = 'rep')$$,
  'mcp_cannot_change_allow_list:%', 'an MCP session (admin token) cannot remove a row');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert(
  pg_temp.rows($$delete from public.mcp_order_users where user_id = (select id from t_user where label = 'rep')$$) = 0
  and (select count(*) = 1 from public.mcp_order_users),
  'an MCP session (rep token) removes nothing and still sees its own row');

select pg_temp.become('rep');
select pg_temp.assert(
  (select scopes = array['orders:draft'] and expires_at <= now() + interval '90 days 1 minute'
     from public.mcp_tokens where id = (select id from t_tok where label = 'w_rep'))
  and (select scopes = '{}' from public.mcp_tokens where id = (select id from t_tok where label = 'ro_rep')),
  'write token carries orders:draft and lasts 90 days at most; a plain token has no scopes');
select pg_temp.assert_fails(
  $$select * from public.mcp_token_create('w2', null, 30, array['orders:draft'])$$,
  'write_token_exists:%', 'one live write token per user');
select pg_temp.assert(
  (select count(*) = 1 from public.mcp_token_create('positional', null, 30)),
  'positional 3-argument calls still mint a read-only token');

reset role;
select pg_temp.assert(
  (select r.scopes = array['orders:draft'] and r.user_id = (select id from t_user where label = 'rep')
     from public.mcp_token_resolve((select token from t_tok where label = 'w_rep')) r)
  and (select r.scopes = '{}' from public.mcp_token_resolve((select token from t_tok where label = 'ro_rep')) r),
  'mcp_token_resolve returns each token''s scopes');

--------------------------------------------------------------------------
-- 3. The gate refuses on its own, each way
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('gate-key-1', '[{"part_id":"MO-ACC","qty":1}]')),
  'not_mcp_session:%', 'a portal session cannot call the MCP draft RPC');
select pg_temp.assert_fails(
  $$select public.mcp_log_call('create_order_draft', '{}'::jsonb, 'ok', null, null)$$,
  'not_mcp_session:%', 'a portal session cannot write the MCP call log');

-- 20261111150000_mcp_orders_any_token: scopes no longer matter. Any live
-- token of an allowed, active user passes - a read-only token row, an empty
-- scope claim (URL-delivered), or no mcp_scopes claim at all.
select pg_temp.become_mcp('rep', 'w_rep', '{}');
select pg_temp.assert(
  (public.mcp_orders_gate() ->> 'max_lines')::int = 40,
  'a URL-delivered token (empty scope claim) passes the gate for an allowed user');
select pg_temp.become_mcp('rep', 'ro_rep', '{}');
select pg_temp.assert(
  (public.mcp_orders_gate() ->> 'max_lines')::int = 40,
  'a token with NO scopes, on an allowed user, passes the gate');
select pg_temp.become_mcp('rep', 'ro_rep');
select pg_temp.assert(
  (public.mcp_orders_gate() ->> 'max_lines')::int = 40,
  'a stray orders:draft claim on a read-only token row changes nothing (passes)');
select pg_temp.become_mcp_bare('rep', 'ro_rep');
select pg_temp.assert(
  (public.mcp_orders_gate() ->> 'max_lines')::int = 40,
  'no mcp_scopes claim at all still passes');
select pg_temp.assert(
  (select pg_get_functiondef('public.mcp_orders_gate()'::regprocedure) not ilike '%scope%')
  and (select prosecdef and proconfig @> array['search_path=public']
         from pg_proc where oid = 'public.mcp_orders_gate()'::regprocedure)
  and has_function_privilege('authenticated', 'public.mcp_orders_gate()', 'execute')
  and not has_function_privilege('anon', 'public.mcp_orders_gate()', 'execute'),
  'mcp_orders_gate: no scope check left; security definer, pinned search_path, grants unchanged');

-- The token row is still the truth: someone else's token, an expired one,
-- a missing or malformed token id, or a non-MCP provider all stop here.
select pg_temp.become_mcp('rep', 'w_admin', '{}');
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'not_mcp_session:%', 'another user''s token id is refused');
select pg_temp.become_mcp('rep', 'no_such_token', '{}');
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'not_mcp_session:%', 'an MCP session with no token id is refused');
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t_user where label = 'rep'), 'role', 'authenticated',
                    'app_metadata', json_build_object('provider', 'mcp', 'mcp_token_id', 'not-a-uuid'))::text, true);
set local role authenticated;
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'not_mcp_session:%', 'a malformed token id is refused');
select pg_temp.become('rep');
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'not_mcp_session:%', 'a non-MCP (portal) JWT is refused, even for an allowed user');
select pg_temp.mint('rep', 'ro_rep_expired', '{}');
reset role;
update public.mcp_tokens set expires_at = now() - interval '1 minute'
 where id = (select id from t_tok where label = 'ro_rep_expired');
select pg_temp.become_mcp('rep', 'ro_rep_expired', '{}');
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'not_mcp_session:%', 'an expired token is refused');

select pg_temp.become('rep2');
select public.mcp_token_revoke((select id from t_tok where label = 'w_rep2_revoked'));
select pg_temp.become_mcp('rep2', 'w_rep2_revoked');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('gate-key-1', '[{"part_id":"MO-ACC","qty":1}]')),
  'not_mcp_session:%', 'a revoked token stops at the gate within the JWT''s life');

select pg_temp.flag(false);
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('gate-key-1', '[{"part_id":"MO-ACC","qty":1}]')),
  'mcp_orders_disabled:%', 'flag off refuses');
select pg_temp.flag(true);

-- rep2: a fresh write token, then an admin removes their row.
select pg_temp.mint('rep2', 'w_rep2', array['orders:draft']);
select pg_temp.become('admin');
select pg_temp.assert(
  pg_temp.rows($$delete from public.mcp_order_users where user_id = (select id from t_user where label = 'rep2')$$) = 1,
  'an admin removes a person from the list');
select pg_temp.become_mcp('rep2', 'w_rep2');
select pg_temp.assert_fails(
  $$select public.mcp_create_order_draft('{"idempotency_key":"gate-key-2","customer_key":"MO-OTHER","lines":[{"part_id":"MO-ACC","qty":1}]}')$$,
  'mcp_user_not_allowed:%', 'removing the row refuses the next call, live token or not');
select pg_temp.mint('rep2', 'ro_rep2', '{}');
select pg_temp.become_mcp('rep2', 'ro_rep2', '{}');
select pg_temp.assert_fails('select public.mcp_orders_gate()',
  'mcp_user_not_allowed:%', 'an unlisted user with a plain (no-scope) token is refused');
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.assert_fails(
  $$insert into public.mcp_order_users (user_id) select id from t_user where label = 'rep2'$$,
  'mcp_cannot_change_allow_list:%', 'an MCP session (admin token) cannot add a row');
select pg_temp.become('admin');
insert into public.mcp_order_users (user_id) select id from t_user where label = 'rep2';

--------------------------------------------------------------------------
-- 4. Customer scope, inputs, caps
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  $$select public.mcp_create_order_draft('{"idempotency_key":"scope-key-1","customer_key":"MO-OTHER","lines":[{"part_id":"MO-ACC","qty":1}]}')$$,
  'customer_not_in_book:%', 'a rep cannot draft for another rep''s account');
select pg_temp.assert_fails(
  $$select public.mcp_create_order_draft('{"idempotency_key":"scope-key-1","customer_key":"NO-SUCH-CUSTOMER","lines":[{"part_id":"MO-ACC","qty":1}]}')$$,
  'customer_not_in_book:%', 'an unknown account looks the same as someone else''s');

select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]', '{"unit_price": 1}')),
  'invalid_input:unit_price:%', 'no price input on the header');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1,"price":0.01}]')),
  'invalid_input:price:%', 'no price input on a line');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-RL-BG","qty":1}]',
                                                           '{"ffl_license_number":"1-23-456-78-9A-99999"}')),
  'invalid_input:ffl_license_number:%', 'no FFL input');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]', '{"status":"submitted"}')),
  'invalid_input:unknown_field:status:%', 'unknown fields (status) are refused, not ignored');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('short', '[{"part_id":"MO-ACC","qty":1}]')),
  'invalid_input:idempotency_key:%', 'idempotency_key is 8-100 characters');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-UNP","qty":1}]')),
  'part_not_orderable:MO-UNP:%', 'a part on no effective list is not orderable');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-SPC","qty":1}]')),
  'part_not_orderable:MO-SPC:%', 'a special-only part needs its price_list_id');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-KIT","qty":1}]')),
  'kit_not_supported:MO-KIT:%', 'kits are refused');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":0}]')),
  'qty_out_of_range:MO-ACC:%', 'qty 0');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":201}]')),
  'qty_out_of_range:MO-ACC:%', 'qty above max_units_per_line');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1.5}]')),
  'invalid_input:qty:%', 'fractional qty');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]', '{"ship_to_key":"MO-OTHER|1"}')),
  'ship_to_invalid:MO-OTHER|1:%', 'another account''s ship-to');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]', '{"ship_to_key":"MO-CUST|2"}')),
  'ship_to_invalid:MO-CUST|2:%', 'an inactive ship-to');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]',
                                                           jsonb_build_object('requested_ship_date', (current_date - 1)::text))),
  'invalid_input:requested_ship_date:%', 'a ship date in the past');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]',
                                                           jsonb_build_object('po_number', repeat('9', 41)))),
  'invalid_input:po_number:%', 'PO over 40 characters');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-ACC","qty":1}]', '{"customer_contact_key":"MO-OTHER|C1"}')),
  'invalid_input:customer_contact_key:%', 'a contact from another account');

select pg_temp.flag(true, '{"max_lines": 2, "max_order_value": 1000}');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1',
    '[{"part_id":"MO-ACC","qty":1},{"part_id":"MO-RL-CG","qty":1},{"part_id":"MO-RL-TI","qty":1}]')),
  'too_many_lines:%', 'max_lines');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('input-key-1', '[{"part_id":"MO-RL-BG","qty":1}]')),
  'order_value_cap:%', 'max_order_value');
select pg_temp.flag(true, '{"max_lines": 40, "max_order_value": 250000}');

--------------------------------------------------------------------------
-- 5. Create: priced on the server, dry-run submit, still a draft
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('d1', pg_temp.req('order-key-0001', '[{"part_id":"MO-RL-BG","qty":6}]',
  '{"po_number":"PO-MO-1","customer_contact_key":"MO-CUST|C1","notes":"Truck delivery"}'));

select pg_temp.assert(
  (select j ->> 'status' = 'draft' and j ->> 'source' = 'mcp' and not (j ->> 'replayed')::boolean
          and j ->> 'customer_name' = 'MCP Test Dealer'
          and j -> 'ship_to' ->> 'ship_to_key' = 'MO-CUST|1' and j -> 'ship_to' ->> 'city' = 'Boise'
          and j -> 'contact' ->> 'name' = 'Pat Buyer'
          and (j ->> 'requires_ffl')::boolean and (j -> 'ffl' ->> 'current')::boolean
          and (j -> 'ffl' ->> 'on_file')::boolean
          and (j -> 'would_submit' ->> 'ok')::boolean and j -> 'would_submit' ->> 'error' is null
          and jsonb_array_length(j -> 'lines') = 1
          and (j -> 'lines' -> 0 ->> 'unit_price')::numeric = 2000
          and j -> 'lines' -> 0 ->> 'price_list_name' = 'MO general'
          and (j -> 'lines' -> 0 ->> 'line_total')::numeric = 12000
          and (j -> 'lines' -> 0 ->> 'ats_qty')::numeric = 5
          and (j ->> 'total_amount')::numeric = 12000
          and j ->> 'portal_path' = '/orders/' || (j ->> 'order_id')
     from t_prev where label = 'd1'),
  'create returns the preview: server price, ship-to, contact, FFL on file, would_submit ok');
select pg_temp.assert(
  (select exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'Stock: MO-RL-BG has 5 available%')
     from t_prev where label = 'd1'),
  'stock short of the qty is a warning, not a refusal');

select pg_temp.assert(
  (select o.status = 'draft' and o.source = 'mcp' and o.submitted_at is null and o.total_amount is null
          and o.acknowledged_at is null and o.created_by = (select id from t_user where label = 'rep')
          and o.user_id = (select id from t_user where label = 'rep')
          and o.mcp_token_id = (select id from t_tok where label = 'w_rep')
          and o.client_request_id = 'order-key-0001' and length(o.request_hash) = 64
          and o.customer_contact_key = 'MO-CUST|C1'
          and jsonb_array_length(o.mcp_warnings) >= 1
     from public.orders o where o.id = pg_temp.oid('d1')),
  'the dry run left a DRAFT, with provenance and warnings stored');

-- Replay and conflict
select pg_temp.create('d1_replay', pg_temp.req('order-key-0001', '[{"part_id":"MO-RL-BG","qty":6}]',
  '{"po_number":"PO-MO-1","customer_contact_key":"MO-CUST|C1","notes":"Truck delivery"}'));
select pg_temp.assert(
  (pg_temp.prev('d1_replay') ->> 'replayed')::boolean
  and (pg_temp.prev('d1_replay') ->> 'order_id')::bigint = pg_temp.oid('d1')
  and (select count(*) from public.orders where client_request_id = 'order-key-0001') = 1,
  'same key + same body replays the same draft');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('order-key-0001', '[{"part_id":"MO-RL-BG","qty":7}]')),
  'idempotency_conflict:%', 'same key + different body is a conflict');

-- Duplicate block, and the override
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('order-key-0002', '[{"part_id":"MO-ACC","qty":3}]', '{"po_number":"po-mo-1"}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('d1')), 'same PO (any case) within the window is blocked');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('order-key-0002', '[{"part_id":"MO-RL-BG","qty":6}]', '{"po_number":"PO-OTHER"}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('d1')), 'same line set within the window is blocked');
select pg_temp.create('d1_dup', pg_temp.req('order-key-0002', '[{"part_id":"MO-RL-BG","qty":6}]',
  '{"po_number":"PO-OTHER","allow_duplicate":true}'));
select pg_temp.assert(pg_temp.oid('d1_dup') is not null and pg_temp.oid('d1_dup') <> pg_temp.oid('d1'),
  'allow_duplicate drafts it anyway');

-- No ship-to given and two orderable addresses: refused since
-- 20261112090000 (ship_to_confirmation_required). d_noship is now drafted
-- to the Range Annex (no FFL on file) and moved to the store by update.
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('order-key-0003', '[{"part_id":"MO-RL-CG","qty":2}]', '{"ship_to_key":null}')),
  'ship_to_confirmation_required:MO-CUST:%', 'no ship-to with two orderable addresses is refused');
select pg_temp.create('d_noship', pg_temp.req('order-key-0003', '[{"part_id":"MO-RL-CG","qty":2}]', '{"ship_to_key":"MO-CUST|3"}'));
select pg_temp.assert(
  (select j ->> 'status' = 'draft' and j -> 'ship_to' ->> 'ship_to_key' = 'MO-CUST|3'
          and not (j -> 'would_submit' ->> 'ok')::boolean
     from t_prev where label = 'd_noship')
  and (select status = 'draft' from public.orders where id = pg_temp.oid('d_noship')),
  'dry run reports the problem and leaves a draft');

-- The ship-to has no FFL on file: Claude cannot supply one, the dry run says so.
select pg_temp.create('d_noffl', pg_temp.req('order-key-0004', '[{"part_id":"MO-RL-CG","qty":3}]', '{"ship_to_key":"MO-CUST|3"}'));
select pg_temp.assert(
  (select (j ->> 'requires_ffl')::boolean and not (j -> 'ffl' ->> 'current')::boolean
          and not (j -> 'would_submit' ->> 'ok')::boolean
          and j -> 'would_submit' ->> 'error' ilike '%no current FFL on file%'
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like '%must enter the current FFL in the portal%')
     from t_prev where label = 'd_noffl')
  and (select status = 'draft' and ffl_license_number is null from public.orders where id = pg_temp.oid('d_noffl')),
  'dry run reports the FFL problem and leaves a draft');

-- One orderable ship-to is used without asking; accessories need no FFL.
select pg_temp.create('d_one', '{"idempotency_key":"order-key-0005","customer_key":"MO-ONE","po_number":"PO-ONE-5","lines":[{"part_id":"MO-ACC","qty":4,"part_confirmed":true}]}');
select pg_temp.assert(
  (select j -> 'ship_to' ->> 'ship_to_key' = 'MO-ONE|1' and not (j ->> 'requires_ffl')::boolean
          and (j -> 'would_submit' ->> 'ok')::boolean
     from t_prev where label = 'd_one'),
  'the only orderable ship-to is used; an accessory order would submit');

-- A special list by id, with its buy-2-get-1 settled as a prorated percent.
select pg_temp.create('d_promo', jsonb_build_object('idempotency_key', 'order-key-0006', 'customer_key', 'MO-ONE', 'po_number', 'PO-ONE-6',
  'lines', jsonb_build_array(jsonb_build_object('part_id', 'MO-SPC', 'qty', 3, 'part_confirmed', true,
                                                'price_list_id', pg_temp.oid('pl_special')))));
select pg_temp.assert(
  (select (j -> 'lines' -> 0 ->> 'discount_pct')::numeric = 33.3333
          and (j -> 'lines' -> 0 ->> 'effective_unit_price')::numeric = 333.33
          and (j ->> 'total_amount')::numeric = 999.99
          and j -> 'lines' -> 0 ->> 'price_list_name' = 'MO promo'
          and (j -> 'would_submit' ->> 'ok')::boolean
     from t_prev where label = 'd_promo'),
  'a special list by id prices with the submit_order promo formula');

-- Admin (no book of their own) may draft for any account.
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.create('d_admin', '{"idempotency_key":"admin-key-0001","customer_key":"MO-OTHER","po_number":"PO-ADMIN-1","lines":[{"part_id":"MO-ACC","qty":5,"part_confirmed":true}]}');
select pg_temp.assert(
  (select o.user_id = (select id from t_user where label = 'admin') and o.customer_key = 'MO-OTHER' and o.ship_to_key = 'MO-OTHER|1'
     from public.orders o where o.id = pg_temp.oid('d_admin')),
  'an admin drafts for an account on nobody''s book of theirs');

-- Daily cap
select pg_temp.flag(true, jsonb_build_object('max_drafts_per_user_per_day',
  (select count(*) from public.orders where created_by = (select id from t_user where label = 'rep') and source <> 'portal')));
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('order-key-0007', '[{"part_id":"MO-ACC","qty":7}]')),
  'daily_draft_cap:%', 'max_drafts_per_user_per_day');
select pg_temp.assert(
  (pg_temp.create('d1_replay2', pg_temp.req('order-key-0001', '[{"part_id":"MO-RL-BG","qty":6}]',
     '{"po_number":"PO-MO-1","customer_contact_key":"MO-CUST|C1","notes":"Truck delivery"}')) ->> 'replayed')::boolean,
  'a replay is not a new draft and passes the daily cap');
select pg_temp.flag(true, '{"max_drafts_per_user_per_day": 25}');

--------------------------------------------------------------------------
-- 6. Update and cancel
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
insert into t_prev
select 'upd', public.mcp_update_order_draft(pg_temp.oid('d_noship'),
  '{"ship_to_key":"MO-CUST|1","ship_to_confirmed":true,"po_number":"PO-NOSHIP","lines":[{"part_id":"MO-RL-CG","qty":1,"part_confirmed":true},{"part_id":"MO-ACC","qty":2,"part_confirmed":true}]}');
select pg_temp.assert(
  (select (j -> 'would_submit' ->> 'ok')::boolean and j -> 'ship_to' ->> 'ship_to_key' = 'MO-CUST|1'
          and jsonb_array_length(j -> 'lines') = 2 and (j ->> 'total_amount')::numeric = 2100
     from t_prev where label = 'upd')
  and (select count(*) = 2 from public.order_lines where order_id = pg_temp.oid('d_noship'))
  and (select customer_key = 'MO-CUST' from public.orders where id = pg_temp.oid('d_noship')),
  'update replaces header and lines (customer kept), and now would submit');

select pg_temp.become_mcp('rep2', 'w_rep2');
select pg_temp.assert_fails(
  format($$select public.mcp_update_order_draft(%s, '{"lines":[{"part_id":"MO-ACC","qty":1}]}')$$, pg_temp.oid('d_noship')),
  'order_not_found:%', 'another rep cannot update my draft');
select pg_temp.assert_fails(format('select public.mcp_cancel_order_draft(%s)', pg_temp.oid('d_noship')),
  'order_not_found:%', 'another rep cannot cancel my draft');

-- A portal-typed draft is not Claude's to touch.
select pg_temp.become('rep');
with ins as (
  insert into public.orders (user_id, customer_key, ship_to_key)
  values ((select id from t_user where label = 'rep'), 'MO-CUST', 'MO-CUST|1') returning id
) insert into t_ids select 'portal', id from ins;
insert into public.order_lines (order_id, price_list_id, part_id, qty, unit_price, effective_unit_price)
values (pg_temp.oid('portal'), pg_temp.oid('pl'), 'MO-RL-BG', 9, 2000.00, 2000.00);
select pg_temp.assert(
  (select source = 'portal' and created_by = (select id from t_user where label = 'rep')
     from public.orders where id = pg_temp.oid('portal')),
  'a portal insert is source portal, created_by stamped');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  format($$select public.mcp_update_order_draft(%s, '{"lines":[{"part_id":"MO-ACC","qty":1}]}')$$, pg_temp.oid('portal')),
  'order_not_mcp:%', 'update refused on a portal order');
select pg_temp.assert_fails(format('select public.mcp_cancel_order_draft(%s)', pg_temp.oid('portal')),
  'order_not_mcp:%', 'cancel refused on a portal order');

select pg_temp.assert(
  (select j ->> 'status' = 'cancelled' and (j ->> 'order_id')::bigint = pg_temp.oid('d1_dup')
     from (select public.mcp_cancel_order_draft(pg_temp.oid('d1_dup')) j) q),
  'cancel an MCP draft');
select pg_temp.assert_fails(format('select public.mcp_cancel_order_draft(%s)', pg_temp.oid('d1_dup')),
  'order_not_draft:%', 'a cancelled draft cannot be cancelled again');

--------------------------------------------------------------------------
-- 7. A portal session cannot forge provenance or the acknowledgement
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$insert into public.orders (user_id, customer_key, source) values ('c1c1c1c1-1111-4111-8111-111111111111', 'MO-CUST', 'mcp')$$,
  'protected_column:%', 'portal insert cannot claim source mcp');
select pg_temp.assert_fails(
  $$insert into public.orders (user_id, customer_key, acknowledged_at) values ('c1c1c1c1-1111-4111-8111-111111111111', 'MO-CUST', now())$$,
  'protected_column:%', 'portal insert cannot pre-acknowledge');
select pg_temp.assert_fails(
  $$insert into public.orders (user_id, customer_key, created_by) values ('c1c1c1c1-1111-4111-8111-111111111111', 'MO-CUST', 'c3c3c3c3-3333-4333-8333-333333333333')$$,
  'protected_column:%', 'portal insert cannot name someone else as creator');
select pg_temp.assert_fails(format($$update public.orders set source = 'portal' where id = %s$$, pg_temp.oid('d1')),
  'protected_column:%', 'portal update cannot launder an MCP draft into a portal one');
select pg_temp.assert_fails(format($$update public.orders set acknowledged_at = now(), acknowledged_by = auth.uid() where id = %s$$, pg_temp.oid('d1')),
  'protected_column:%', 'portal update cannot stamp the acknowledgement');
select pg_temp.assert_fails(format($$update public.orders set mcp_warnings = '[]' where id = %s$$, pg_temp.oid('d1')),
  'protected_column:%', 'portal update cannot clear the MCP warnings');
select pg_temp.assert_fails(format($$update public.orders set client_request_id = 'x' where id = %s$$, pg_temp.oid('d1')),
  'protected_column:%', 'portal update cannot touch the idempotency key');
update public.orders set notes = 'Edited in the portal' where id = pg_temp.oid('d1');
select pg_temp.assert(
  (select notes = 'Edited in the portal' and source = 'mcp' from public.orders where id = pg_temp.oid('d1')),
  'the owner can still edit an MCP draft''s ordinary fields in the portal');

--------------------------------------------------------------------------
-- 8. submit_order: acknowledgement for MCP orders; portal unchanged
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(format('select public.submit_order(%s)', pg_temp.oid('d1')),
  'acknowledge_required:%', 'an MCP draft does not submit without the acknowledgement');
select pg_temp.assert_fails(format('select public.submit_order(%s, false)', pg_temp.oid('d1')),
  'acknowledge_required:%', 'nor with p_acknowledged false');
select public.submit_order(pg_temp.oid('d1'), p_acknowledged => true);
select pg_temp.assert(
  (select status = 'submitted' and acknowledged_at is not null
          and acknowledged_by = (select id from t_user where label = 'rep')
          and total_amount = 12000 and requires_ffl and ffl_license_number = '1-23-456-78-9A-12345'
     from public.orders where id = pg_temp.oid('d1')),
  'acknowledged submit goes through and stamps who acknowledged');

select public.submit_order(pg_temp.oid('portal'));
select pg_temp.assert(
  (select status = 'submitted' and acknowledged_at is null and total_amount = 18000
     from public.orders where id = pg_temp.oid('portal')),
  'a portal order submits positionally as before, no acknowledgement needed');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  format($$select public.mcp_update_order_draft(%s, '{"lines":[{"part_id":"MO-ACC","qty":1}]}')$$, pg_temp.oid('d1')),
  'order_not_draft:%', 'update refused once submitted');
select pg_temp.assert_fails(format('select public.mcp_cancel_order_draft(%s)', pg_temp.oid('d1')),
  'order_not_draft:%', 'cancel refused once submitted');
select pg_temp.assert(
  (select (j -> 'would_submit' ->> 'ok')::boolean = false and j ->> 'status' = 'submitted' and (j ->> 'replayed')::boolean
     from (select public.mcp_create_order_draft(pg_temp.req('order-key-0001', '[{"part_id":"MO-RL-BG","qty":6}]',
             '{"po_number":"PO-MO-1","customer_contact_key":"MO-CUST|C1","notes":"Truck delivery"}')) j) q),
  'replaying the key of a submitted order shows its status; it does not resubmit');

-- The middleware's read
select pg_temp.become('rep');
select pg_temp.assert(
  (select source = 'mcp' and acknowledged_at is not null and ship_to_id = 'STORE'
          and jsonb_array_length(lines) = 1 and lines -> 0 ->> 'part_id' = 'MO-RL-BG'
          and (lines -> 0 ->> 'qty')::int = 6
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('d1'))
  and (select source = 'portal' from public.v_orders_ready_for_erp where order_id = pg_temp.oid('portal'))
  and not exists (select 1 from public.v_orders_ready_for_erp where order_id = pg_temp.oid('d_noffl')),
  'v_orders_ready_for_erp: submitted orders only, with source, acknowledgement, snapshot and lines');

--------------------------------------------------------------------------
-- 8b. Claude never submits, and nobody submits around submit_order
--------------------------------------------------------------------------
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.assert_fails(
  format($$select public.mcp_update_order_draft(%s, '{"lines":[{"part_id":"MO-ACC","qty":1}]}')$$, pg_temp.oid('d_noship')),
  'order_not_found:%', 'an admin''s Claude cannot update someone else''s draft');
select pg_temp.assert_fails(format('select public.mcp_cancel_order_draft(%s)', pg_temp.oid('d_noship')),
  'order_not_found:%', 'an admin''s Claude cannot cancel someone else''s draft');
select pg_temp.assert_fails(format($$update public.orders set status = 'submitted' where id = %s$$, pg_temp.oid('d_noship')),
  'mcp_direct_write:%', 'an admin''s MCP session cannot move an order''s status');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('d_noship')),
  'mcp_cannot_submit:%', 'an MCP session cannot call submit_order, acknowledged or not');
select pg_temp.assert_fails(format($$update public.orders set notes = 'x' where id = %s$$, pg_temp.oid('d_noship')),
  'mcp_direct_write:%', 'an MCP session cannot update orders directly');
select pg_temp.assert_fails(format('delete from public.orders where id = %s', pg_temp.oid('d_noship')),
  'mcp_direct_write:%', 'an MCP session cannot delete orders directly');

-- 20261111150000: the common path now is a read-only token pasted in a
-- connector URL (no scopes on the row, empty scope claim). End to end it
-- drafts, updates and cancels, but it can never submit or write orders.
select pg_temp.become_mcp('rep', 'ro_rep', '{}');
select pg_temp.create('d_ro', '{"idempotency_key":"ro-url-key-0001","customer_key":"MO-ONE","po_number":"PO-RO-1","lines":[{"part_id":"MO-ACC","qty":2,"part_confirmed":true}]}');
select pg_temp.assert(
  (select o.source = 'mcp' and o.status = 'draft'
          and o.user_id = (select id from t_user where label = 'rep')
     from public.orders o where o.id = pg_temp.oid('d_ro'))
  and (select j ->> 'status' = 'draft' and (j -> 'would_submit' ->> 'ok')::boolean from t_prev where label = 'd_ro'),
  'a read-only URL token (no scopes) drafts an order: source mcp, status draft');
select pg_temp.assert(
  (select (j ->> 'order_id')::bigint = pg_temp.oid('d_ro')
     from (select public.mcp_update_order_draft(pg_temp.oid('d_ro'),
             '{"po_number":"PO-RO-1","lines":[{"part_id":"MO-ACC","qty":3,"part_confirmed":true}]}') j) q)
  and (select status = 'draft' from public.orders where id = pg_temp.oid('d_ro')),
  'a read-only URL token updates its draft, which stays a draft');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('d_ro')),
  'mcp_cannot_submit:%', 'a read-only URL token cannot submit, acknowledged or not');
select pg_temp.assert_fails(format('select public.submit_order(%s)', pg_temp.oid('d_ro')),
  'mcp_cannot_submit:%', 'nor without the acknowledgement');
select pg_temp.assert_fails(format($$update public.orders set status = 'submitted', submitted_at = now() where id = %s$$, pg_temp.oid('d_ro')),
  'mcp_direct_write:%', 'a read-only URL token cannot move an order''s status directly');
select pg_temp.assert_fails(format($$update public.orders set notes = 'x' where id = %s$$, pg_temp.oid('d_ro')),
  'mcp_direct_write:%', 'a read-only URL token cannot update orders directly');
select pg_temp.assert_fails(
  $$insert into public.mcp_order_users (user_id) select id from t_user where label = 'rep'$$,
  'mcp_cannot_change_allow_list:%', 'a read-only URL token cannot touch the allow-list');
select public.mcp_cancel_order_draft(pg_temp.oid('d_ro'));
select pg_temp.assert(
  (select status <> 'submitted' and submitted_at is null from public.orders where id = pg_temp.oid('d_ro')),
  'a read-only URL token cancels its draft; it was never submitted');

select pg_temp.become('admin');
select pg_temp.assert_fails(format($$update public.orders set status = 'submitted', submitted_at = now() where id = %s$$, pg_temp.oid('d_noship')),
  'protected_status:%', 'an admin portal session cannot PATCH a draft to submitted');
select pg_temp.assert_fails(
  $$insert into public.orders (user_id, customer_key, status) values ('c3c3c3c3-3333-4333-8333-333333333333', 'MO-CUST', 'submitted')$$,
  'protected_status:%', 'a new order cannot be inserted already submitted');
select pg_temp.assert_fails(
  format($$select * from public.mcp_token_create('for-rep', %L::uuid, 30, array['orders:draft'])$$,
         (select id from t_user where label = 'rep')),
  'invalid_scope:%', 'an admin cannot mint an order-drafting token for someone else');

select pg_temp.become('rep');
select public.submit_order(pg_temp.oid('d_noship'), p_acknowledged => true);
select public.recall_order(pg_temp.oid('d_noship'));
select pg_temp.assert(
  (select status = 'draft' and acknowledged_at is null and acknowledged_by is null
     from public.orders where id = pg_temp.oid('d_noship')),
  'a recall clears the acknowledgement');
-- As maintenance would (no user identity): the trigger lets it through, the view must not.
reset role;
select set_config('request.jwt.claims', '', true);
update public.orders set status = 'submitted', submitted_at = now() where id = pg_temp.oid('d_noship');
select pg_temp.become('rep');
select pg_temp.assert(
  not exists (select 1 from public.v_orders_ready_for_erp where order_id = pg_temp.oid('d_noship')),
  'v_orders_ready_for_erp leaves out a submitted MCP order nobody acknowledged');

--------------------------------------------------------------------------
-- 9. The call log
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert(
  (public.mcp_log_call('create_order_draft', '{"customer_key":"MO-CUST"}', 'ok', null, pg_temp.oid('d1')) ->> 'logged')::boolean
  and (public.mcp_log_call('create_order_draft', '{}', 'refused', 'customer_not_in_book: x', null) ->> 'logged')::boolean,
  'mcp_log_call records ok and refused calls');
select pg_temp.assert_fails($$select public.mcp_log_call('x', '{}', 'maybe', null, null)$$,
  'invalid_input:%', 'outcome is ok, refused or error');
select pg_temp.assert(
  (select count(*) = 2 and bool_and(token_id = (select id from t_tok where label = 'w_rep'))
     from public.mcp_tool_calls where user_id = (select id from t_user where label = 'rep')),
  'the rep reads their own log rows, with the token');
select pg_temp.assert_fails(
  $$insert into public.mcp_tool_calls (user_id, tool, outcome) values (auth.uid(), 'forged', 'ok')$$,
  '%permission denied%', 'nobody writes the log directly');
select pg_temp.become('rep2');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_tool_calls where user_id = (select id from t_user where label = 'rep')),
  'another rep cannot read my log');
select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) = 2 from public.mcp_tool_calls where user_id = (select id from t_user where label = 'rep')),
  'an admin reads every log row');

--------------------------------------------------------------------------
-- 10. order_context and product search
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert(
  (select (c ->> 'orderable')::boolean and c -> 'blockers' = '[]'::jsonb
          and c -> 'customer' ->> 'customer_type' = 'MO-DEALER'
          and jsonb_array_length(c -> 'ship_tos') = 3
          and c -> 'default_ship_to_key' = 'null'::jsonb
          and (select not (s ->> 'orderable')::boolean and not (s ->> 'active')::boolean
                 from jsonb_array_elements(c -> 'ship_tos') s where s ->> 'ship_to_key' = 'MO-CUST|2')
          and (select (s -> 'ffl' ->> 'current')::boolean and s -> 'ffl' ->> 'number_on_file' = '1-23-456-78-9A-12345'
                 from jsonb_array_elements(c -> 'ship_tos') s where s ->> 'ship_to_key' = 'MO-CUST|1')
          and (select not (s -> 'ffl' ->> 'current')::boolean
                 from jsonb_array_elements(c -> 'ship_tos') s where s ->> 'ship_to_key' = 'MO-CUST|3')
          and jsonb_array_length(c -> 'price_lists') = 2
          and c -> 'contacts' -> 0 ->> 'customer_contact_key' = 'MO-CUST|C1'
          and exists (select 1 from jsonb_array_elements(c -> 'recent_orders') r where r ->> 'source' = 'mcp')
     from (select public.order_context('MO-CUST') c) q),
  'order_context: blockers, ship-tos (inactive = not orderable), FFL on file, lists, contacts, recent orders');
select pg_temp.assert(
  (public.order_context('MO-ONE') ->> 'default_ship_to_key') = 'MO-ONE|1',
  'order_context: the default ship-to when exactly one is orderable');
select pg_temp.assert(
  (select not (c ->> 'orderable')::boolean and c -> 'blockers' ? 'credit_hold'
          and c -> 'blockers' ? 'no_price_list_for_type' and c -> 'blockers' ? 'no_orderable_ship_to'
     from (select public.order_context('MO-HOLD') c) q),
  'order_context: credit hold, no price list, no ship-to are blockers');
select pg_temp.assert_fails($$select public.order_context('MO-OTHER')$$,
  'customer_not_in_book:%', 'order_context is limited to the rep''s book');
select pg_temp.assert_fails($$select public.order_product_search('MO-OTHER', 'ridgeline')$$,
  'customer_not_in_book:%', 'product search is limited to the rep''s book');

select pg_temp.assert(
  (select s -> 'items' -> 0 ->> 'part_id' = 'MO-RL-BG'
          and (s -> 'items' -> 0 ->> 'match_score')::numeric = 1
          and (s -> 'items' -> 0 ->> 'requires_ffl')::boolean
          and not (s -> 'items' -> 0 ->> 'is_kit')::boolean
          and (s -> 'items' -> 0 -> 'options' -> 0 ->> 'unit_price')::numeric = 2000
          and (s -> 'items' -> 0 -> 'stock' ->> 'ats_qty')::numeric = 5
          and s -> 'items' -> 0 -> 'stock' ->> 'warehouse' = 'MAIN'
          and s ->> 'customer_type' = 'MO-DEALER'
          and not exists (select 1 from jsonb_array_elements(s -> 'items') i where i ->> 'part_id' = 'MO-UNP')
     from (select public.order_product_search('MO-CUST', 'one 6.5 Creedmoor Ridgeline FFT in black and grey') s) q),
  'search: "one 6.5 Creedmoor Ridgeline FFT in black and grey" -> the black/gray Ridgeline FFT 6.5 CM first; unpriced parts never appear');
select pg_temp.assert(
  (select s -> 'items' -> 0 ->> 'part_id' = 'MO-RL-BG'
     from (select public.order_product_search('MO-CUST', 'RL FFT 6.5cm blk/gry 22"') s) q),
  'search: shorthand (RL, 6.5cm, blk/gry, 22") finds it too');
select pg_temp.assert(
  (select (s -> 'items' -> 0 ->> 'part_id') = 'MO-RL-BG' and s ->> 'note' like '%products match equally%'
     from (select public.order_product_search('MO-CUST', 'ridgeline fft 6.5 creedmoor') s) q),
  'search: an ambiguous phrase says to ask one question');
select pg_temp.assert(
  (select s -> 'items' -> 0 ->> 'part_id' in ('MO-RL-BG', 'MO-RL-TI')
          and (s ->> 'ties')::int = 2
          and (select not (i ->> 'fits_request')::boolean
                 from jsonb_array_elements(s -> 'items') i where i ->> 'part_id' = 'MO-RL-270')
     from (select public.order_product_search('MO-CUST', '6.5 creedmoor ridgeline black') s) q),
  'search: a part in another chambering never ties with the one asked for, however many colour words it matches');
select pg_temp.assert(
  (select s -> 'items' -> 0 ->> 'part_id' = 'MO-RL-270' and (s -> 'items' -> 0 ->> 'fits_request')::boolean
          and s ->> 'note' = 'One clear best match.'
     from (select public.order_product_search('MO-CUST', 'ridgeline 270 wsm black grey') s) q),
  'search: naming the other chambering finds it');
select pg_temp.assert(
  (select (s -> 'items' -> 0 ->> 'chambering') = '6.5 CREEDMOOR' and (s -> 'items' -> 0 ->> 'fits_request')::boolean
          and (select not (i ->> 'fits_request')::boolean
                 from jsonb_array_elements(s -> 'items') i where i ->> 'part_id' = 'MO-RL-270')
     from (select public.order_product_search('MO-CUST', '10 ridgelines 6.5') s) q),
  'search: a quantity is not a product word; plurals and a bare caliber ("6.5") match');
select pg_temp.assert(
  (select (s -> 'items' -> 0 ->> 'chambering') = '6.5 CREEDMOOR' and (s -> 'items' -> 0 ->> 'barrel_length') = '22'
     from (select public.order_product_search('MO-CUST', 'ridgeline 6.5 creedmoor 22 inch') s) q),
  'search: a barrel length after the product words is kept');
select pg_temp.assert(
  (select jsonb_array_length(s -> 'items') = 0
     from (select public.order_product_search('MO-CUST', 'one of the') s) q),
  'search: a phrase with no product words returns nothing, with a note');

--------------------------------------------------------------------------
-- 11. account_inactive (last: it deactivates rep2)
--------------------------------------------------------------------------
reset role;
update public.profiles set active = false where user_id = (select id from t_user where label = 'rep2');
select pg_temp.become_mcp('rep2', 'w_rep2');
select pg_temp.assert_fails(
  $$select public.mcp_create_order_draft('{"idempotency_key":"gate-key-9","customer_key":"MO-OTHER","lines":[{"part_id":"MO-ACC","qty":1}]}')$$,
  'account_inactive:%', 'a deactivated account is refused at the gate');

do $$ begin raise notice 'ALL MCP ORDER TESTS PASSED'; end $$;
rollback;
