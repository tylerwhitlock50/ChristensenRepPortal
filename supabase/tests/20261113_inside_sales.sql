/*============================================================================
  20261113_inside_sales.sql — assertions for
  20261113090000_inside_sales_and_order_documents: inside sales (order_entry)
  reads every account (an admin's revoke excepted) and changes nothing
  account-side; drafts for any customer; prices and submits its OWN orders
  (an admin prices and submits any); a PO is optional (PORTAL-<id>) and its
  rules; the same part may sit on two hand-priced lines, never at the same
  price; a hand price re-runs the order's promo; order documents follow the
  order, with set-based policies; order_owner_names().

  Harness and fixtures copied from 20261111_admin_order_pricing.sql, plus an
  order_entry user. One transaction, ROLLED BACK. Safe on the live project
  too: direct deletes from storage.objects set storage.allow_delete_query
  first, as hosted Storage requires.

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

update public.profiles set sales_rep_key = 'MO REP', full_name = 'Rex Rep'
 where user_id = (select id from t_user where label = 'rep');
update public.profiles set sales_rep_key = 'MO REP2', full_name = 'Rae Rep'
 where user_id = (select id from t_user where label = 'rep2');
update public.profiles set role = 'admin', full_name = '  '
 where user_id = (select id from t_user where label = 'admin');
update public.profiles set role = 'order_entry', full_name = 'Ivy Inside'
 where user_id = (select id from t_user where label = 'entry');

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

-- What MO-OTHER paid for MO-RL-BG on its last ERP order: two paid lines and
-- two free ones ($0, and 100% off), all on the same order and day. The free
-- lines (highest line numbers) are not a price paid; of the paid two the
-- higher line wins.
insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, unit_price,
                                 trade_discount_pct, order_date_key)
values ('IS-HIST-1', 1, 'MO-OTHER', 'MOPK-BG', 1950.00,   0, to_char(current_date - 20, 'YYYYMMDD')::int),
       ('IS-HIST-1', 2, 'MO-OTHER', 'MOPK-BG', 1980.00,   0, to_char(current_date - 20, 'YYYYMMDD')::int),
       ('IS-HIST-1', 3, 'MO-OTHER', 'MOPK-BG',    0.00,   0, to_char(current_date - 20, 'YYYYMMDD')::int),
       ('IS-HIST-1', 4, 'MO-OTHER', 'MOPK-BG', 2000.00, 100, to_char(current_date - 20, 'YYYYMMDD')::int);

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
-- The promo list (buy 2 get 1) carries the bipod and, at 60, the rings.
insert into public.price_list_items (price_list_id, part_id, unit_price)
values ((select id from t_ids where label = 'pl_special'), 'MO-SPC', 500.00),
       ((select id from t_ids where label = 'pl_special'), 'MO-ACC', 60.00);

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

-- The superuser with no signed-in user: fixtures written mid-test (the
-- read-only trigger would otherwise see the last user's claims).
create or replace function pg_temp.as_postgres() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
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

-- feature.mcp_orders: on/off and params (merged), as the superuser with no
-- signed-in user (an inside-sales session would trip the read-only trigger).
create or replace function pg_temp.flag(p_enabled boolean, p_params jsonb default '{}') returns void
language plpgsql as $$
begin
  perform pg_temp.as_postgres();
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
create or replace function pg_temp.update_sql(p_id bigint, p jsonb) returns text
language sql as $$ select format('select public.mcp_update_order_draft(%s, %L::jsonb)', p_id, p) $$;
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
create or replace function pg_temp.uid(p_label text) returns uuid
language sql as $$ select id from t_user where label = p_label $$;
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
-- 2. ...and changes nothing account-side
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

-- The AI summary is the account's one shared row: inside sales reads it,
-- never writes it (the edge function's cache upsert is refused, tolerated).
select pg_temp.become('rep');
insert into public.ai_summaries (customer_key, content) values ('MO-CUST', 'The rep''s summary');
select pg_temp.become('entry');
select pg_temp.assert(
  (select content from public.ai_summaries where customer_key = 'MO-CUST') = 'The rep''s summary',
  'inside sales reads an account''s AI summary');
select pg_temp.assert(
  pg_temp.rows($$update public.ai_summaries set content = 'overwritten' where customer_key = 'MO-CUST'$$) = 0,
  'inside sales cannot overwrite it');
select pg_temp.assert_fails(
  $$insert into public.ai_summaries (customer_key, content) values ('MO-CUST', 'x')
    on conflict (customer_key) do update set content = excluded.content$$,
  '%row-level security%', 'nor upsert it, as ai-account-summary would');
select pg_temp.assert_fails(
  $$insert into public.ai_summaries (customer_key, content) values ('MO-OTHER', 'x')$$,
  '%row-level security%', 'nor write one for another account');

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
select pg_temp.assert(
  (select count(*) from public.order_lines
    where order_id = pg_temp.oid('is1') and part_id = 'MO-RL-BG' and last_paid_price = 1980) = 2,
  'last paid ignores the free ERP lines and breaks the tie on the line number');
select pg_temp.assert(
  (public.order_resolve_parts('MO-OTHER', '[{"ref":"MO-RL-BG"}]')
     -> 'items' -> 0 -> 'candidates' -> 0 ->> 'last_paid_price')::numeric = 1980,
  'order_resolve_parts: last paid ignores the free ERP lines and breaks the tie on the line number');
select pg_temp.assert(
  pg_temp.prev('is1') -> 'warnings' ->> 0 like 'HAND PRICING - CHECK EVERY FLAGGED LINE: 2 of 3 lines%'
  and pg_temp.prev('is1') -> 'warnings' ->> 0 like '%Hand-priced value $19,000.00%'
  and pg_temp.prev('is1') -> 'warnings' ->> 0 like '%An admin, or inside sales on their own order, submits it%'
  and pg_temp.prev('is1') -> 'warnings' ->> 1
        = 'PRICE VS LAST PAID: 2 hand-priced line(s) differ from what this customer last paid for the part.'
  and not exists (select 1 from jsonb_array_elements_text(pg_temp.prev('is1') -> 'warnings') w
                  where w ilike '%admin pricing%' or w ilike '%admin-priced%'
                     or w like '%last_paid_price%' or w like '%Only an admin or inside sales%')
  and exists (select 1 from jsonb_array_elements(pg_temp.prev('is1') -> 'alerts') a
              where a ->> 'type' = 'admin_pricing'
                and a ->> 'message' like '%an admin, or inside sales on their own order, submits it%'),
  'the preview says HAND PRICING and who submits; no column names, no "admin-priced"');
select pg_temp.assert(
  (select count(*) from jsonb_array_elements_text(pg_temp.prev('is1') -> 'warnings') w
    where w like 'Stock: MO-RL-BG %') = 1
  and exists (select 1 from jsonb_array_elements_text(pg_temp.prev('is1') -> 'warnings') w
              where w = 'Stock: MO-RL-BG has 5 available to sell; 11 ordered in all. Stock does not block the order.'),
  'stock is checked once per part, over both lines (10 paid + 1 free against 5)');
select pg_temp.as_postgres();
update erp.dim_part set status = 'O' where part_id = 'MO-RL-BG';
select pg_temp.assert(
  (select count(*) from jsonb_array_elements_text(public.mcp_order_preview(pg_temp.oid('is1'), false) -> 'warnings') w
    where w like 'MO-RL-BG is not an active part%') = 1,
  'and an inactive part is reported once, not once per line');
update erp.dim_part set status = 'A' where part_id = 'MO-RL-BG';
select pg_temp.become_mcp('entry', 'w_entry');
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

-- An admin's revoke hides an account from inside sales, and stops their
-- Claude drafting for it (the pricing right is not a right to every book).
select pg_temp.become('admin');
insert into public.account_assignments (customer_key, user_id, access)
values ('MO-ONE', pg_temp.uid('entry'), 'revoke');
select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from erp.dim_customer where customer_key = 'MO-ONE') = 0,
  'a revoked account is hidden from inside sales');
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.assert_fails(
  pg_temp.create_sql('{"idempotency_key":"is-rev-0001","customer_key":"MO-ONE","po_number":"PO-REV-1",
                       "lines":[{"part_id":"MO-ACC","qty":1,"part_confirmed":true}]}'::jsonb),
  'customer_not_in_book:%', 'and inside sales'' Claude cannot draft for it');
select pg_temp.become('admin');
delete from public.account_assignments where customer_key = 'MO-ONE' and user_id = pg_temp.uid('entry');

-- Daily cap: a pricer reads admin_max_drafts_per_user_per_day, a rep
-- max_drafts_per_user_per_day; raising one never raises the other.
select pg_temp.flag(true, '{"max_drafts_per_user_per_day": 0}'::jsonb);
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-cap-0001', '[{"part_id":"MO-RL-TI","qty":1}]')),
  'daily_draft_cap:%', 'a rep at the rep cap is refused');
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.create('cap1', '{"idempotency_key":"is-cap-0002","customer_key":"MO-OTHER","po_number":"PO-IS-CAP",
                                "lines":[{"part_id":"MO-ACC","qty":9,"part_confirmed":true}]}'::jsonb);
select pg_temp.assert(pg_temp.oid('cap1') is not null, 'inside sales is not held to the rep cap');
select pg_temp.become('admin');
select pg_temp.flag(true, jsonb_build_object('admin_max_drafts_per_user_per_day',
  (select count(*) from public.orders where created_by = pg_temp.uid('entry') and source <> 'portal')));
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.assert_fails(
  pg_temp.create_sql('{"idempotency_key":"is-cap-0003","customer_key":"MO-OTHER","po_number":"PO-IS-CAP-2",
                       "lines":[{"part_id":"MO-ACC","qty":8,"part_confirmed":true}]}'::jsonb),
  'daily_draft_cap:%', 'inside sales has its own cap, admin_max_drafts_per_user_per_day');
select pg_temp.flag(true, '{"max_drafts_per_user_per_day": 25, "admin_max_drafts_per_user_per_day": null}'::jsonb);

-- The duplicate probe is per account, not per drafter: the rep and inside
-- sales both received the same PO.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('shared', pg_temp.req('is-dup-0001', '[{"part_id":"MO-RL-TI","qty":2}]',
                                            '{"po_number":"PO-SHARED-1"}'));
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-dup-0002', '[{"part_id":"MO-ACC","qty":5}]', '{"po_number":"po-shared-1"}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('shared')),
  'inside sales drafting the rep''s PO for the same account is a possible duplicate');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-dup-0003', '[{"part_id":"MO-RL-TI","qty":2}]', '{"po_number":"PO-SHARED-2"}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('shared')),
  'and so is the same set of lines');

--------------------------------------------------------------------------
-- 4. The PO is asked for, not required
--------------------------------------------------------------------------
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]') - 'po_number'),
  'po_confirmation_required:%', 'no PO and no word from the user: refused, ask');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]', '{"po_number":"  "}')),
  'po_confirmation_required:%', 'a blank PO is no PO');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]', '{"po_number":"\t\u00a0\r\n"}')),
  'po_confirmation_required:%', 'nor is one of tabs, line breaks and no-break spaces');
select pg_temp.assert_fails(
  pg_temp.create_sql(pg_temp.req('is-po-0001', '[{"part_id":"MO-ACC","qty":1}]', '{"po_number":"portal-424242"}')),
  'invalid_input:po_number:%assigned by the portal%', 'a PORTAL-<n> reference is not a customer PO');
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
  and exists (select 1 from jsonb_array_elements_text(pg_temp.prev('nopo') -> 'warnings') w
              where w like 'No customer PO:%')
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

-- Recalled, it is a draft with no PO again.
select public.recall_order(pg_temp.oid('nopo'));
select pg_temp.assert(
  (select status = 'draft' and po_number is null from public.orders where id = pg_temp.oid('nopo')),
  'a recall clears the PORTAL-<id> it was given');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.update_sql(pg_temp.oid('nopo'),
    pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":1}]',
                jsonb_build_object('po_number', 'PORTAL-' || pg_temp.oid('nopo')))),
  'po_confirmation_required:%', 'the order''s own PORTAL-<id> counts as no PO');
select pg_temp.assert_fails(
  pg_temp.update_sql(pg_temp.oid('nopo'),
    pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":1}]',
                jsonb_build_object('po_number', 'PORTAL-' || pg_temp.oid('is1'), 'no_po_confirmed', true))),
  'invalid_input:po_number:%', 'another order''s PORTAL-<id> is refused on an update too');
select public.mcp_update_order_draft(pg_temp.oid('nopo'),
  pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":1}]',
              jsonb_build_object('po_number', 'PORTAL-' || pg_temp.oid('nopo'), 'no_po_confirmed', true)));
select pg_temp.assert(
  (select po_number is null from public.orders where id = pg_temp.oid('nopo')),
  'confirmed: saved with no PO, not with the reference');

-- A person adds the PO in the portal; a later Claude update keeps it.
select pg_temp.become('rep');
select pg_temp.assert(
  pg_temp.rows(format($$update public.orders set po_number = 'PO-LATE-1' where id = %s$$, pg_temp.oid('nopo'))) = 1,
  'the PO turns up and the rep types it into the draft');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  pg_temp.update_sql(pg_temp.oid('nopo'),
    pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":4}]', '{"no_po_confirmed":true}') - 'po_number'),
  'po_would_be_removed:%PO-LATE-1%', 'an update without the PO (no_po_confirmed or not) is refused, naming it');
select pg_temp.assert_fails(
  pg_temp.update_sql(pg_temp.oid('nopo'),
    pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":4}]',
                jsonb_build_object('po_number', 'PORTAL-' || pg_temp.oid('nopo'), 'no_po_confirmed', true))),
  'po_would_be_removed:%PO-LATE-1%', 'sending the draft''s own reference instead does not remove it either');
select public.mcp_update_order_draft(pg_temp.oid('nopo'),
  pg_temp.req('is-po-0002', '[{"part_id":"MO-ACC","qty":4}]', '{"po_number":"PO-LATE-1"}'));
select pg_temp.assert(
  (select po_number = 'PO-LATE-1' from public.orders where id = pg_temp.oid('nopo')),
  'sent again, the PO stays');

-- A draft still carrying its own PORTAL-<id> (recalled before this
-- migration) has no customer PO: the preview flags it.
select pg_temp.become('rep');
select pg_temp.rows(format($$update public.orders set po_number = 'PORTAL-' || id where id = %s$$, pg_temp.oid('nopo')));
reset role;
select pg_temp.assert(
  exists (select 1 from jsonb_array_elements(public.mcp_order_preview(pg_temp.oid('nopo'), false) -> 'alerts') a
          where a ->> 'type' = 'no_customer_po'),
  'a draft whose PO is its own PORTAL-<id> is flagged as having none');
select pg_temp.become('rep');
select pg_temp.rows(format($$update public.orders set po_number = null where id = %s$$, pg_temp.oid('nopo')));

--------------------------------------------------------------------------
-- 5. Pricing and submitting by hand: the owner in inside sales, or an admin
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, true)', pg_temp.oid('is1')),
  '%only the order''s owner%', 'a rep cannot submit inside sales'' draft');
select pg_temp.become('entry');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, false)', pg_temp.oid('is1')),
  'acknowledge_required:%', 'inside sales must acknowledge a Claude draft');
select pg_temp.assert_fails(
  format('select public.admin_set_order_line_price(%s, 1900.00, null)',
         (select id from public.order_lines where order_id = pg_temp.oid('is1') and unit_price = 0)),
  'invalid_input:duplicate_line:MO-RL-BG:%',
  'the free line cannot be priced like its paid sibling: the same part at the same price is one line');
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

-- A rep's draft that an admin priced by hand: inside sales cannot price it,
-- the rep cannot submit it, an admin can.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('repd', pg_temp.req('is-rep-0002', '[{"part_id":"MO-ACC","qty":2}]'));
select pg_temp.become('admin');
select public.admin_set_order_line_price(
  (select id from public.order_lines where order_id = pg_temp.oid('repd')), 40.00, 'show special');
select pg_temp.become('entry');
select pg_temp.assert_fails(
  format('select public.admin_set_order_line_price(%s, 30.00, %L)',
         (select id from public.order_lines where order_id = pg_temp.oid('repd')), 'inside sales special'),
  'not_owner:%', 'inside sales cannot price a rep''s draft');
select pg_temp.assert(
  (select unit_price = 40 from public.order_lines where order_id = pg_temp.oid('repd'))
  and (select price_override_reason = 'show special' from public.orders where id = pg_temp.oid('repd')),
  'the admin''s price and reason stand');
select pg_temp.become('rep');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, true)', pg_temp.oid('repd')),
  'admin_price_requires_admin:%only an admin, or inside sales on their own order, can submit it',
  'a rep cannot submit a hand-priced order');
-- The portal's header editor: a direct update of the owner's own draft.
select pg_temp.assert(
  pg_temp.rows(format($$update public.orders
                          set po_number = 'PO-REPD-2', requested_ship_date = current_date + 7,
                              notes = 'Leave at the dock',
                              ffl_license_number = '1-23-456-78-9A-12345', ffl_expires_on = current_date + 365
                        where id = %s$$, pg_temp.oid('repd'))) = 1,
  'the owner edits PO, ship date, notes and FFL on their hand-priced Claude draft');
select pg_temp.assert(
  (select po_number = 'PO-REPD-2' and notes = 'Leave at the dock'
          and requested_ship_date = current_date + 7 and ffl_expires_on = current_date + 365
     from public.orders where id = pg_temp.oid('repd')),
  'and the edits are stored');
select pg_temp.become('entry');
select pg_temp.assert(
  pg_temp.rows(format($$update public.orders set notes = 'x', po_number = 'PO-X' where id = %s$$, pg_temp.oid('repd'))) = 0,
  'inside sales cannot edit someone else''s draft');
select pg_temp.become('admin');
select pg_temp.assert(
  (select status = 'submitted' and total_amount = 2 * 40 and po_number = 'PO-REPD-2'
          and acknowledged_by = pg_temp.uid('admin') and user_id = pg_temp.uid('rep')
     from public.submit_order(pg_temp.oid('repd'), true)),
  'an admin submits the rep''s hand-priced draft');

-- Keying it: inside sales records the ERP number as before (orders are exempt
-- from the read-only trigger).
select pg_temp.become('entry');
select public.mark_order_entered(pg_temp.oid('is1'), 'EDI-90001');
select pg_temp.assert(
  (select status = 'entered' and erp_order_number = 'EDI-90001'
     from public.orders where id = pg_temp.oid('is1')),
  'inside sales marks the order entered');

-- A ship date that passed while the draft waited: the dry run reports it,
-- submit refuses it, today is fine.
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.create('late', '{"idempotency_key":"is-late-0001","customer_key":"MO-OTHER","po_number":"PO-IS-LATE",
                                "lines":[{"part_id":"MO-ACC","qty":3,"part_confirmed":true}]}'::jsonb);
select pg_temp.become('entry');
select pg_temp.rows(format($$update public.orders set requested_ship_date = current_date - 1 where id = %s$$,
                           pg_temp.oid('late')));
reset role;
select pg_temp.assert(
  public.mcp_order_preview(pg_temp.oid('late'), false) -> 'would_submit' ->> 'error' like 'ship_date_past:%',
  'the dry run reports a requested ship date that has passed');
select pg_temp.become('entry');
select pg_temp.assert_fails(
  format('select public.submit_order(%s, true)', pg_temp.oid('late')),
  'ship_date_past: the requested ship date % has passed; change it before submitting',
  'submit refuses it');
select pg_temp.rows(format($$update public.orders set requested_ship_date = current_date where id = %s$$,
                           pg_temp.oid('late')));
select pg_temp.assert(
  (select status = 'submitted' from public.submit_order(pg_temp.oid('late'), true)),
  'a ship date of today submits');

-- The buyer snapshot comes only from an active contact of the account.
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.create('buyer', pg_temp.req('is-buy-0001', '[{"part_id":"MO-ACC","qty":6}]',
                                           '{"customer_contact_key":"MO-CUST|C1"}'));
select pg_temp.as_postgres();
update erp.dim_customer_contact set contact_active_flag = 'N' where customer_contact_key = 'MO-CUST|C1';
select pg_temp.become('entry');
select pg_temp.assert(
  (select status = 'submitted' and customer_contact_key = 'MO-CUST|C1'
          and contact_name is null and contact_phone is null and contact_email is null
     from public.submit_order(pg_temp.oid('buyer'), true)),
  'a buyer deactivated in the ERP since the draft is not stamped');
select pg_temp.as_postgres();
update erp.dim_customer_contact set contact_active_flag = 'Y' where customer_contact_key = 'MO-CUST|C1';

-- Hand-pricing a line of a promo order re-runs the promo for the lines left
-- on the list, so the draft shows the total submit_order computes.
select pg_temp.become_mcp('entry', 'w_entry');
select pg_temp.create('promo', jsonb_build_object(
  'idempotency_key', 'is-promo-0001', 'customer_key', 'MO-CUST', 'ship_to_key', 'MO-CUST|1',
  'ship_to_confirmed', true, 'po_number', 'PO-IS-PROMO',
  'lines', jsonb_build_array(
    jsonb_build_object('part_id', 'MO-SPC', 'qty', 2, 'part_confirmed', true, 'price_list_id', pg_temp.oid('pl_special')),
    jsonb_build_object('part_id', 'MO-ACC', 'qty', 1, 'part_confirmed', true, 'price_list_id', pg_temp.oid('pl_special')))));
select pg_temp.assert(
  (pg_temp.prev('promo') ->> 'total_amount')::numeric = 2 * 333.33 + 40.00
  and (select bool_and(discount_pct = 33.3333) from public.order_lines where order_id = pg_temp.oid('promo')),
  'buy 2 get 1 over 3 units on the promo list: a third off every line');
select pg_temp.become('entry');
select public.admin_set_order_line_price(
  (select id from public.order_lines where order_id = pg_temp.oid('promo') and part_id = 'MO-ACC'),
  30.00, 'counter display');
select pg_temp.assert(
  (select discount_pct = 0 and effective_unit_price = 500
     from public.order_lines where order_id = pg_temp.oid('promo') and part_id = 'MO-SPC')
  and (select sum(line_total) from public.order_lines where order_id = pg_temp.oid('promo')) = 2 * 500 + 30,
  'the rings moved to a hand price: 2 units left on the promo list, no free one, and the draft says so');
insert into t_prev
select 'promo_draft_lines', jsonb_agg(jsonb_build_object('id', id, 'pct', discount_pct, 'eff', effective_unit_price,
                                                        'total', line_total) order by id)
from public.order_lines where order_id = pg_temp.oid('promo');
select pg_temp.assert(
  pg_temp.rows(format($$update public.orders
                          set po_number = 'PO-IS-PROMO-2', requested_ship_date = current_date + 3,
                              notes = 'Counter display',
                              ffl_license_number = '1-23-456-78-9A-12345', ffl_expires_on = current_date + 365
                        where id = %s$$, pg_temp.oid('promo'))) = 1,
  'inside sales edits the header of its own hand-priced Claude draft');
select pg_temp.assert(
  (select status = 'submitted' and total_amount = 2 * 500 + 30 and po_number = 'PO-IS-PROMO-2'
     from public.submit_order(pg_temp.oid('promo'), true)),
  'submit computes the total the draft showed');
select pg_temp.assert(
  pg_temp.prev('promo_draft_lines') =
    (select jsonb_agg(jsonb_build_object('id', id, 'pct', discount_pct, 'eff', effective_unit_price,
                                         'total', line_total) order by id)
       from public.order_lines where order_id = pg_temp.oid('promo')),
  'and leaves every line as the draft showed it (one promo pass, order_apply_promo)');

--------------------------------------------------------------------------
-- 6. order_owner_names(): who an order belongs to
--------------------------------------------------------------------------
reset role;
select pg_temp.assert(
  pg_get_function_result('public.order_owner_names(uuid[])'::regprocedure)
    = 'TABLE(user_id uuid, display_name text, role text)',
  'order_owner_names returns a name and a role, never an email');
select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.order_owner_names(array(select id from t_user))) = 4
  and (select display_name = 'Ivy Inside' and role = 'inside_sales'
         from public.order_owner_names(array[pg_temp.uid('entry')]))
  and (select display_name = 'Portal user' and role = 'admin'
         from public.order_owner_names(array[pg_temp.uid('admin')])),
  'an admin names anyone; order_entry reads as inside_sales; a blank name reads as Portal user');
select pg_temp.become('entry');
select pg_temp.assert(
  (select count(*) from public.order_owner_names(array(select id from t_user))) = 4,
  'inside sales names anyone');
select pg_temp.become('rep');
select pg_temp.assert(
  (select display_name = 'Ivy Inside' and role = 'inside_sales'
     from public.order_owner_names(array[pg_temp.uid('entry')])),
  'a rep names inside sales, who drafted orders on their account');
select pg_temp.assert(
  (select count(*) = 1 and min(display_name) = 'Rex Rep'
     from public.order_owner_names(array[pg_temp.uid('rep'), pg_temp.uid('rep2')])),
  'a rep names themselves; a stranger (no order they can read) gets nothing');
select pg_temp.become('rep2');
select pg_temp.assert(
  not exists (select 1 from public.order_owner_names(array[pg_temp.uid('rep')]))
  and exists (select 1 from public.order_owner_names(array[pg_temp.uid('entry')])),
  'rep2 cannot name the rep, but can name inside sales, who drafted on rep2''s account');

--------------------------------------------------------------------------
-- 7. Order documents follow the order
--------------------------------------------------------------------------
select pg_temp.assert(
  public.order_document_order_id('123/po.pdf') = 123
  and public.order_document_order_id('999999999999999999/po.pdf') = 999999999999999999
  and public.order_document_order_id('123') is null
  and public.order_document_order_id('123/') is null
  and public.order_document_order_id('0123/po.pdf') is null
  and public.order_document_order_id('123/sub/po.pdf') is null
  and public.order_document_order_id('1234567890123456789/po.pdf') is null
  and public.order_document_order_id('abc/po.pdf') is null
  and public.order_document_order_id('../123/po.pdf') is null
  and public.order_document_order_id('') is null,
  'the order id is the first path segment, in the one shape the portal writes: <id>/<file>');

select pg_temp.become('rep');   -- MO-CUST is on their book; 'repd' is their order
insert into storage.objects (bucket_id, name, owner, owner_id)
values ('order-documents', pg_temp.oid('repd') || '/1-po.pdf', pg_temp.uid('rep'), pg_temp.uid('rep')::text);
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 1,
  'a rep adds and reads a document on their own order');
select pg_temp.assert_fails(
  format($$insert into storage.objects (bucket_id, name) values ('order-documents', '%s/x.pdf')$$, pg_temp.oid('is1')),
  '%row-level security%', 'but not on an order they cannot read');
select pg_temp.assert_fails(
  $$insert into storage.objects (bucket_id, name) values ('order-documents', 'loose.pdf')$$,
  '%row-level security%', 'nor outside an order folder');
select pg_temp.assert_fails(
  format($$insert into storage.objects (bucket_id, name) values ('order-documents', '0%s/x.pdf')$$, pg_temp.oid('repd')),
  '%row-level security%', 'nor under a leading-zero folder no listing shows');
select pg_temp.assert_fails(
  format($$insert into storage.objects (bucket_id, name) values ('order-documents', '%s/sub/x.pdf')$$, pg_temp.oid('repd')),
  '%row-level security%', 'nor in a sub-folder');

select pg_temp.become('rep2');
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 0,
  'another rep sees none of it');

select pg_temp.become('entry');
-- Counted in this test's folders only: inside sales reads every order, and
-- the live bucket holds real documents.
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents'
      and name like pg_temp.oid('repd') || '/%') = 1,
  'inside sales reads the document on a rep''s order');
insert into storage.objects (bucket_id, name, owner, owner_id)
values ('order-documents', pg_temp.oid('repd') || '/2-signed-po.pdf', pg_temp.uid('entry'), pg_temp.uid('entry')::text),
       ('order-documents', pg_temp.oid('is1') || '/3-signed-po.pdf', pg_temp.uid('entry'), pg_temp.uid('entry')::text);

-- Hosted Storage refuses direct deletes from storage.objects unless this is
-- set (the Storage API sets it itself); harmless on the local harness.
select set_config('storage.allow_delete_query', 'true', true);
select pg_temp.become('rep');
select pg_temp.assert(
  (select count(*) from storage.objects where bucket_id = 'order-documents') = 2,
  'the rep sees both documents on their order');
select pg_temp.assert(
  pg_temp.rows(format($$delete from storage.objects where bucket_id = 'order-documents' and name = '%s/2-signed-po.pdf'$$,
                      pg_temp.oid('repd'))) = 0,
  'a rep cannot remove a document someone else added to their order');
select pg_temp.assert(
  pg_temp.rows(format($$delete from storage.objects where bucket_id = 'order-documents' and name = '%s/1-po.pdf'$$,
                      pg_temp.oid('repd'))) = 1,
  'but removes the one they uploaded (owner_id)');
select pg_temp.become('entry');
select pg_temp.assert(
  pg_temp.rows(format($$delete from storage.objects where bucket_id = 'order-documents'
                              and (name like '%s/%%' or name like '%s/%%')$$, pg_temp.oid('repd'), pg_temp.oid('is1'))) = 2,
  'inside sales adds one after the order was entered, and may remove any');

-- Listing one order's folder costs the same however full the bucket is: the
-- policies build the readable order set once per statement. 3,000 accounts,
-- 300 orders, a document on each; per object (the earlier draft) this took
-- well over a second locally, set-based about 10 ms.
select pg_temp.as_postgres();
insert into erp.dim_customer (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag)
select 'MO-T-' || g, 'MO-T-' || g, 'Timing Dealer ' || g, 'MO TIMING', 'MO-DEALER', 'Y'
from generate_series(1, 3000) g;
with o as (
  insert into public.orders (user_id, created_by, customer_key, customer_name, status, source)
  select pg_temp.uid('rep'), pg_temp.uid('rep'), 'MO-T-' || (g * 10), 'Timing Dealer', 'draft', 'portal'
  from generate_series(1, 300) g
  returning id
)
insert into storage.objects (bucket_id, name, owner_id)
select 'order-documents', o.id || '/1-po.pdf', pg_temp.uid('rep')::text from o;
insert into t_ids select 'timing', min(id) from public.orders where customer_key like 'MO-T-%';
select pg_temp.become('entry');
do $$
declare
  v_id bigint := pg_temp.oid('timing');
  t0   timestamptz;
  n    bigint;
  ms   numeric;
begin
  t0 := clock_timestamp();
  select count(*) into n from storage.objects
   where bucket_id = 'order-documents' and name like v_id || '/%';
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform pg_temp.assert(n = 1 and ms < 500,
    format('inside sales lists one order''s folder among 300 documents in %s ms (bound 500 ms)', round(ms, 1)));
end $$;

do $$ begin raise notice 'ALL INSIDE SALES TESTS PASSED'; end $$;
rollback;
