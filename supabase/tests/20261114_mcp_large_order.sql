/*============================================================================
  20261114_mcp_large_order.sql — assertions for
  20261114090000_mcp_large_order_fixes: the fixes found staging a 195-line
  distributor PO through the MCP order tools. One section per fix.

  Harness and fixtures copied from 20261113_inside_sales.sql. One
  transaction, ROLLED BACK. Run with the migration, before it is deployed:

      etl/venv/Scripts/python.exe etl/run_sql_guard.py \
        supabase/migrations/20261114090000_mcp_large_order_fixes.sql \
        supabase/tests/20261114_mcp_large_order.sql

  A clean run prints "ALL MCP LARGE ORDER TESTS PASSED".
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


select pg_temp.mint('admin', 'w_admin', array['orders:draft']);

--------------------------------------------------------------------------
-- 1. resolve: tokenizer, conflicts, UPC, named columns, description cap
--------------------------------------------------------------------------
select pg_temp.as_postgres();
-- Numeric part ids as distributors print them, with UPCs; an obsolete -M
-- twin whose UPC is not the active part's; a steel Ridgeline Elite.
insert into erp.dim_part
  (part_key, part_id, part_description, product_code, product_family, chambering,
   barrel_length, finish, stock_color, handedness, status, is_kit_flag, upc)
values
  ('LOPK-1', '899-00001-01', 'TEST SMU RIFLE 6.5 CRD 20IN', 'TEST', 'TEST FAMILY', '6.5 CREEDMOOR',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'A', 'N', '899000000014'),
  ('LOPK-1M', '899-00001-01-M', 'TEST SMU RIFLE (old)', 'TEST', 'TEST FAMILY', '6.5 CREEDMOOR',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'O', 'N', '899000000038'),
  ('LOPK-2', '899-00002-00', 'TEST HISTORY PART', 'TEST', 'TEST FAMILY', '308 WIN',
   '20', 'BLACK', 'BLACK', 'RIGHT', 'A', 'N', '899000000021'),
  ('LOPK-3', '899-00003-00', 'TEST RIDGELINE ELITE STL 6.5 PRC 22IN', 'TEST', 'RIDGELINE ELITE STEEL',
   '6.5 PRC', '22', 'BLACK', 'BLACK', 'RIGHT', 'A', 'N', null);

-- Token sets compare as sets (array_agg distinct sorts by collation).
create or replace function pg_temp.toks_are(p text, p_want text[]) returns boolean
language sql as $$
  select public.order_desc_tokens(p) @> p_want and public.order_desc_tokens(p) <@ p_want
$$;
create or replace function pg_temp.conf(p_po text, p_part text) returns text[]
language sql as $$
  select public.order_desc_conflicts(public.order_desc_tokens(p_po), public.order_desc_tokens(p_part))
$$;
create or replace function pg_temp.res(p_items jsonb, p_customer text default 'MO-CUST') returns jsonb
language sql as $$ select public.order_resolve_parts(p_customer, p_items) $$;

-- 1a. Tokenizer: run-together distributor text, calibre aliases.
select pg_temp.assert(pg_temp.toks_are('CHRIS 8011500501 EVOKE7MMRM22"BB/GRN', '{22,7rm,burntbronze,evoke,green}'),
  'tokens: EVOKE7MMRM22 splits, 7MMRM folds to 7rm, the PO''s own item number is dropped');
select pg_temp.assert(pg_temp.toks_are('CHRIS 8010910900 RAM-CORE556/223 16.25"', '{16.25,223,556,core,ram}'),
  'tokens: RAM-CORE556/223 16.25');
select pg_temp.assert(public.order_desc_tokens('EVOKE CARBON 30816.25"') @> '{308win,16.25}',
  'tokens: a calibre run into a length (30816.25) splits');
select pg_temp.assert(pg_temp.toks_are('MODERN PRE 338L 27 5RBLK', '{27,338lapua,black,mpr}'),
  'tokens: MODERN PRE -> mpr, 338L -> 338lapua, 5R round count dropped');
select pg_temp.assert(public.order_desc_tokens('RAM-15 PRO 350L 16.25') @> '{ram-15,350legend}',
  'tokens: RAM-15 kept as a model, 350L -> 350legend');
select pg_temp.assert(pg_temp.toks_are('VANTAGE STEEL300WM22"', '{22,300wm,steel,vantage}'),
  'tokens: STEEL300WM22');
select pg_temp.assert(public.order_desc_tokens('MPR FFT556/22312.5"') @> '{556,223,12.5}',
  'tokens: 22312.5 -> 223 12.5');
select pg_temp.assert(public.order_desc_tokens('RDGL ELT CBTI 65PRC 20') @> '{ridgeline,elite,carbon,titanium,6.5prc}',
  'tokens: RDGL ELT, CBTI is carbon AND titanium, 65PRC -> 6.5prc');
select pg_temp.assert(pg_temp.toks_are('CHR801-15025-01', '{}'),
  'tokens: a prefixed part number leaves nothing (no 15025, no chr)');
select pg_temp.assert(pg_temp.toks_are('22-250 REM 24IN', '{22250,24}'),
  'tokens: 22-250 REM stays one chambering (not a 22 length)');
select pg_temp.assert(pg_temp.toks_are('30-06 SPRG', '{3006}') and pg_temp.toks_are('7MM-08 REM 22', '{7mm08,22}'),
  'tokens: 30-06 SPRG and 7MM-08 REM');
select pg_temp.assert(public.order_desc_tokens('MPR 6.5CRD 24 10 RD') @> '{24}'
                      and not public.order_desc_tokens('MPR 6.5CRD 24 10 RD') @> '{10}',
  'tokens: "10 RD" is a round count, not a 10in barrel');

-- 1b. Conflicts only: chambering, length, material, model.
select pg_temp.assert(pg_temp.conf('65PRC 20', 'EVOKE CBN 6.5 PRC 22 IN') = '{length}', 'conflict: length');
select pg_temp.assert(pg_temp.conf('RDGL ELT STL 65PRC22', 'RL ELITE CBN 6.5 PRC 22 IN TWILL CBN') = '{material}',
  'conflict: steel vs carbon');
select pg_temp.assert(pg_temp.conf('Ridgeline 6.5 PRC 22', '308 WIN 22') = '{chambering}', 'conflict: chambering');
select pg_temp.assert(pg_temp.conf('VANTAGE 300PRC 22', 'RIDGELINE ELITE CARBON 300 PRC 22') = '{model}',
  'conflict: model line');
select pg_temp.assert(pg_temp.conf('22-250 REM 24', 'RIDGELINE 6.5 PRC 24') = '{chambering}',
  'conflict: 22-250 is a chambering against 6.5 PRC');
select pg_temp.assert(pg_temp.conf('556/223 16', '223 REM 16.25') = '{}',
  'no conflict: 556/223 vs 223 REM, 16 vs 16.25');
select pg_temp.assert(pg_temp.conf('EVOKE 7MMRM22 BB/GRN', 'EVOKE 7MM REM MAG 22IN SMOKE BRONZE') = '{}',
  'no conflict: a colour missing is not a conflict');
select pg_temp.assert(
  public.order_desc_score(public.order_desc_tokens('CHRIS 8011500501 EVOKE7MMRM22"BB/GRN'),
    public.order_desc_tokens('EVOKE BASE SMK BZ 7MM REM MAG 22IN 1/9 BASIC GRN TP EVOKE 7MM REM MAG 22 SMOKE BRONZE GREEN / SMOKE BRONZE')) = 0.8,
  'score: PO line 198 against 801-15005-01 is 0.8 (was 0.25)');
select pg_temp.assert(
  public.order_upc_norm('0899000000014') = '899000000014' and public.order_upc_norm('899-000-000014') = '899000000014'
  and public.order_upc_norm('12') is null and public.order_upc_norm('PENDING') is null,
  'order_upc_norm: EAN-13 with a leading 0 equals the UPC-A; short or text is null');

-- 1c. resolve as a signed-in admin (role authenticated, SECURITY INVOKER).
select pg_temp.become('admin');
-- The description fallback no longer reads dim_part.* (42501 on the cost
-- columns): a 12-digit ref that is no UPC on file, with a description.
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'description_only'
          and exists (select 1 from jsonb_array_elements(j -> 'items' -> 0 -> 'candidates') c
                      where c ->> 'part_id' = '899-00001-01' and c ->> 'match' = 'description')
     from pg_temp.res('[{"ref": "000000000000", "description": "TEST SMU RIFLE 6.5 CRD 20IN"}]') j),
  'resolve: the description fallback runs as authenticated (no permission error on dim_part)');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'match' = 'upc'
          and j -> 'items' -> 0 ->> 'upc_check' = 'upc_only'
          and j -> 'items' -> 1 ->> 'status' = 'matched'
          and j -> 'items' -> 1 -> 'candidates' -> 0 ->> 'match' = 'upc'
          and not (j -> 'items' -> 1 ? 'upc_check')
     from pg_temp.res('[{"upc": "899000000014"}, {"ref": "899000000014"}]') j),
  'resolve: a UPC alone matches (upc_only); a 12-digit ref is read as a UPC');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched'
          and j -> 'items' -> 0 ->> 'upc_check' = 'agrees'
          and j -> 'items' -> 0 ->> 'upc' = '0899000000014'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
          and j -> 'items' -> 0 -> 'candidates' -> 0 -> 'match_sources' @> '["digits", "upc"]'
     from pg_temp.res('[{"ref": "8990000101", "upc": "0899000000014"}]') j),
  'resolve: number and UPC agree (EAN-13 leading 0); match_sources lists both');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'ambiguous'
          and j -> 'items' -> 0 ->> 'upc_check' = 'disagrees'
          and j -> 'items' -> 0 -> 'check_reasons' = '["upc_disagrees"]'
          and (select count(*) from jsonb_array_elements(j -> 'items' -> 0 -> 'candidates') c
                where c ->> 'part_id' in ('899-00001-01', '899-00002-00')) = 2
     from pg_temp.res('[{"ref": "899-00001-01", "upc": "899000000021"}]') j),
  'resolve: a UPC naming another part makes the item ambiguous, both parts offered');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched' and j -> 'items' -> 0 ->> 'upc_check' = 'invalid'
          and j -> 'items' -> 1 ->> 'status' = 'matched' and j -> 'items' -> 1 ->> 'upc_check' = 'not_found'
     from pg_temp.res('[{"ref": "899-00001-01", "upc": "12"}, {"ref": "899-00001-01", "upc": "899999999990"}]') j),
  'resolve: an unreadable UPC is invalid, an unknown one not_found; the number still matches');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched'
          and j -> 'items' -> 0 ->> 'upc_check' = 'agrees'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
     from pg_temp.res('[{"ref": "8990000101", "upc": "899000000038"}]') j),
  'resolve: the UPC on the obsolete -M twin agrees, but the active part ranks first');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched'
          and j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'part_id' = '899-00001-01'
     from pg_temp.res('[{"ref": 8990000101}]') j),
  'resolve: a JSON-number ref is read as its digits');

-- Conflicts-only check_description.
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'matched' and not (j -> 'items' -> 0 ? 'check_reasons')
     from pg_temp.res('[{"ref": "899-00001-01", "description": "6.5 CREED 20 SOMETHING TOTALLY OTHER WORDS"}]') j),
  'resolve: low word overlap with nothing conflicting is matched (was check_description)');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'check_description'
          and j -> 'items' -> 0 -> 'check_reasons' = '["length"]'
          and j -> 'items' -> 0 -> 'candidates' -> 0 -> 'description_conflicts' = '["length"]'
     from pg_temp.res('[{"ref": "899-00001-01", "description": "6.5 CRD 24IN"}]') j),
  'resolve: a barrel length conflict is check_description (check_reasons length)');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'check_description'
          and j -> 'items' -> 0 -> 'check_reasons' = '["material"]'
     from pg_temp.res('[{"ref": "899-00003-00", "description": "RDGL ELT CRB 65PRC22"}]') j),
  'resolve: carbon on the PO against a steel part is check_description (material)');
select pg_temp.assert(
  (select j -> 'items' -> 0 ->> 'status' = 'check_description'
          and j -> 'items' -> 0 -> 'check_reasons' @> '["chambering"]'
          and (j -> 'items' -> 0 -> 'candidates' -> 0 ->> 'description_agreement')::numeric = 0
     from pg_temp.res('[{"ref": "899-00002-00", "description": "Christensen Ridgeline 6.5 PRC 22in"}]') j),
  'resolve: a chambering conflict scores 0 and is check_description');

-- 25 items nothing matches by number: the first 20 are searched by
-- description, the rest come back not_searched; inside the 8 s timeout.
set local statement_timeout = '8s';
select pg_temp.assert(
  (select (select count(*) from jsonb_array_elements(j -> 'items') i
            where i ->> 'status' = 'not_searched' and i ->> 'description_search' = 'skipped_over_cap'
              and (i ->> 'index')::int >= 20) = 5
          and (select count(*) from jsonb_array_elements(j -> 'items') i
                where i ->> 'status' = 'description_only') = 20
          and (j ->> 'description_search_cap')::int = 20
     from pg_temp.res((select jsonb_agg(jsonb_build_object('ref', 'ZZZ-' || g,
                                                           'description', 'TEST SMU RIFLE 6.5 CRD 20IN'))
                         from generate_series(1, 25) g)) j),
  'resolve: 25 description-only items: 20 searched, 5 not_searched, under the 8 s timeout');
set local statement_timeout = '300s';

select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select public.order_resolve_parts('MO-OTHER', '[{"upc": "899000000014"}]')$$,
  'customer_not_in_book:%', 'resolve is still limited to the caller''s book');

-- 1d. Draft time agrees: description_mismatch only on a conflict.
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.create('lo_desc', pg_temp.req('lo-desc-1',
  '[{"part_id": "899-00001-01", "qty": 1, "unit_price": 900,
     "customer_description": "6.5 CREED 20 WITH MANY QUITE UNRELATED EXTRA WORDS"},
    {"part_id": "899-00003-00", "qty": 1, "unit_price": 900, "customer_description": "RDGL ELT CRB 65PRC22"}]',
  '{"price_override_reason": "large order test"}'));
select pg_temp.assert(
  (select count(*) filter (where part_id = '899-00001-01' and not description_mismatch) = 1
          and count(*) filter (where part_id = '899-00003-00' and description_mismatch) = 1
     from public.order_lines where order_id = pg_temp.oid('lo_desc')),
  'draft: low overlap is no description_mismatch (was < 0.3); a material conflict is');

--------------------------------------------------------------------------
-- 2. dup: a PO already in the ERP (order_po_norm, order_erp_po_matches)
--------------------------------------------------------------------------
select pg_temp.as_postgres();
insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, customer_po_number,
                                 order_status, order_status_desc, line_status, order_qty, order_date_key)
select v.oid, v.ln, v.ck, 'MOPK-ACC', v.po, v.st, v.sd, v.ls, v.q, to_char(current_date - v.age, 'YYYYMMDD')::int
from (values
  ('ZZEDI-1',     1, 'MO-CUST',  ' 0215647 ', 'R', 'Released', 'A', 2, 1),
  ('ZZEDI-1',     2, 'MO-CUST',  ' 0215647 ', 'R', 'Released', 'A', 2, 1),
  ('ZZEDI-1',     3, 'MO-CUST',  ' 0215647 ', 'R', 'Released', 'A', 2, 1),
  ('ZZEDI-1',     4, 'MO-CUST',  ' 0215647 ', 'R', 'Released', 'X', 9, 1),   -- a cancelled line
  ('ZZEDI-X',     1, 'MO-CUST',  '777001',    'X', 'Canceled', 'A', 1, 1),
  ('ZZEDI-OLD',   1, 'MO-CUST',  '888001',    'C', 'Closed',   'A', 1, 400),
  ('ZZEDI-WAR',   1, 'MO-CUST',  'WARRANTY ', 'C', 'Closed',   'A', 1, 5),
  ('ZZEDI-OTHER', 1, 'MO-OTHER', '999001',    'R', 'Released', 'A', 1, 1)
) v(oid, ln, ck, po, st, sd, ls, q, age);

-- 2a. The normaliser.
select pg_temp.assert(public.order_po_norm('PO# 0215647') = '215647' and public.order_po_norm('po-215647') = '215647'
                      and public.order_po_norm(' 215647 ') = '215647',
  'order_po_norm: PO prefix, punctuation, case, leading zeros and edge spaces go');
select pg_temp.assert(public.order_po_norm('POINT REDEMPTION') = 'POINTREDEMPTION'
                      and public.order_po_norm('000') is null and public.order_po_norm(null) is null,
  'order_po_norm: POINT keeps its PO (no digit follows); all zeros and null are null');

-- 2b. The probe itself, as the owning rep (RLS) and another rep.
select pg_temp.become('rep');
select pg_temp.assert(
  (select jsonb_array_length(j) = 1 and j -> 0 ->> 'erp_order_id' = 'ZZEDI-1'
          and (j -> 0 ->> 'lines')::int = 3 and (j -> 0 ->> 'units')::numeric = 6
          and j -> 0 ->> 'po_as_entered' = '0215647'
     from public.order_erp_po_matches('MO-CUST', 'PO 215647') j),
  'order_erp_po_matches: one ERP order, the cancelled line not counted');
select pg_temp.assert(
  public.order_erp_po_matches('MO-CUST', '777001') = '[]'
  and public.order_erp_po_matches('MO-CUST', '888001') = '[]'
  and public.order_erp_po_matches('MO-CUST', '888001', 500) -> 0 ->> 'erp_order_id' = 'ZZEDI-OLD'
  and public.order_erp_po_matches('MO-CUST', 'WARRANTY') = '[]'
  and public.order_erp_po_matches('MO-CUST', '999001') = '[]',
  'order_erp_po_matches: a cancelled order, one outside the window, a no-digit PO and another account''s PO never match');
select pg_temp.become('rep2');
select pg_temp.assert(public.order_erp_po_matches('MO-CUST', '215647') = '[]',
  'order_erp_po_matches: RLS - another rep sees nothing of MO-CUST');

-- 2c. Draft time: refused before any line is priced.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-erp-1', '[{"part_id": "NOPE", "qty": 1}]',
                                                           '{"po_number": "215647"}')),
  'possible_duplicate_erp:ZZEDI-1:%', 'create: a PO already on an ERP order is refused, before pricing (unknown part)');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-erp-2', '[{"part_id": "MO-ACC", "qty": 11}]',
                                                           '{"po_number": "PO 215647"}')),
  'possible_duplicate_erp:ZZEDI-1:%', 'create: "PO 215647" is the same PO');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-erp-3', '[{"part_id": "MO-ACC", "qty": 11}]',
                                                           '{"po_number": "po#0215647"}')),
  'possible_duplicate_erp:ZZEDI-1:%', 'create: "po#0215647" is the same PO');
select pg_temp.assert(
  (select count(*) = 0 from public.orders o
    where o.customer_key = 'MO-CUST' and public.order_po_norm(o.po_number) = '215647'),
  'create: nothing was saved by the refusals');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-erp-4', '[{"part_id": "MO-ACC", "qty": 12}]',
                                                           '{"po_number": "215647", "is_test": true}')),
  'possible_duplicate_erp:ZZEDI-1:%', 'create: a test draft is checked against the ERP too');

-- 2d. allow_duplicate drafts it; the preview leads with the ERP alert.
select pg_temp.create('dup_allowed', pg_temp.req('dup-erp-5', '[{"part_id": "MO-ACC", "qty": 13}]',
                                                 '{"po_number": "215647", "allow_duplicate": true}'));
select pg_temp.assert(
  (select j -> 'alerts' @> '[{"type": "erp_po_match", "severity": "warning"}]'
          and j -> 'alerts' @> '[{"type": "erp_po_match", "erp_orders": [{"erp_order_id": "ZZEDI-1"}]}]'
          and j -> 'warnings' ->> 0 like 'ALREADY IN THE ERP:%ZZEDI-1%'
          and (j -> 'would_submit' ->> 'ok')::boolean
     from pg_temp.prev('dup_allowed') j),
  'preview: erp_po_match alert, ALREADY IN THE ERP first, would_submit still ok');
select pg_temp.assert(
  (select mcp_warnings ->> 0 like 'ALREADY IN THE ERP:%ZZEDI-1%' from public.orders where id = pg_temp.oid('dup_allowed')),
  'create: the ALREADY IN THE ERP warning is stored for the reviewer');
select pg_temp.create('dup_test_allowed', pg_temp.req('dup-erp-6', '[{"part_id": "MO-ACC", "qty": 14}]',
                                                      '{"po_number": "215647", "is_test": true, "allow_duplicate": true}'));
select pg_temp.assert(pg_temp.oid('dup_test_allowed') is not null, 'create: a test draft with allow_duplicate drafts');

-- 2e. What never matches.
select pg_temp.create('dup_x',   pg_temp.req('dup-erp-7',  '[{"part_id": "MO-ACC", "qty": 15}]', '{"po_number": "777001"}'));
select pg_temp.create('dup_old', pg_temp.req('dup-erp-8',  '[{"part_id": "MO-ACC", "qty": 16}]', '{"po_number": "888001"}'));
select pg_temp.create('dup_war', pg_temp.req('dup-erp-9',  '[{"part_id": "MO-ACC", "qty": 17}]', '{"po_number": "WARRANTY"}'));
select pg_temp.create('dup_oth', pg_temp.req('dup-erp-10', '[{"part_id": "MO-ACC", "qty": 18}]', '{"po_number": "999001"}'));
select pg_temp.assert(
  pg_temp.oid('dup_x') is not null and pg_temp.oid('dup_old') is not null
  and pg_temp.oid('dup_war') is not null and pg_temp.oid('dup_oth') is not null
  and not (pg_temp.prev('dup_x') -> 'alerts' @> '[{"type": "erp_po_match"}]'),
  'create: a cancelled ERP order, one 400 days old, WARRANTY and another account''s PO all draft');

-- 2f. The window is a param.
select pg_temp.flag(true, '{"erp_duplicate_window_days": 500}');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-erp-11', '[{"part_id": "MO-ACC", "qty": 19}]',
                                                           '{"po_number": "888001", "allow_duplicate": false}')),
  'possible_duplicate_erp:ZZEDI-OLD:%', 'create: erp_duplicate_window_days 500 reaches the 400-day-old order');
select pg_temp.flag(true, '{"erp_duplicate_window_days": 180}');
select pg_temp.become_mcp('rep', 'w_rep');

-- 2g. Test drafts in the portal probe.
select pg_temp.create('dup_t', pg_temp.req('dup-tst-1', '[{"part_id": "MO-ACC", "qty": 31}]',
                                           '{"po_number": "TST-5001", "is_test": true}'));
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-tst-2', '[{"part_id": "MO-ACC", "qty": 33}]',
                                                           '{"po_number": "TST-5001", "is_test": true}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('dup_t')), 'create: a second test draft is blocked by the first');
select pg_temp.create('dup_real', pg_temp.req('dup-tst-3', '[{"part_id": "MO-ACC", "qty": 32}]',
                                              '{"po_number": "TST-5001"}'));
select pg_temp.create('dup_real_set', pg_temp.req('dup-tst-4', '[{"part_id": "MO-ACC", "qty": 31}]',
                                                  '{"po_number": "TST-5002"}'));
select pg_temp.assert(pg_temp.oid('dup_real') is not null and pg_temp.oid('dup_real_set') is not null
                      and not (pg_temp.prev('dup_real_set') -> 'alerts' @> '[{"type": "erp_po_match"}]'),
  'create: a real draft is never blocked by a test draft (same PO, or same lines)');

-- 2h. The portal probe compares normalised POs.
select pg_temp.create('dup_r', pg_temp.req('dup-nrm-1', '[{"part_id": "MO-ACC", "qty": 41}]',
                                           '{"po_number": "PO-MO-9001"}'));
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.req('dup-nrm-2', '[{"part_id": "MO-ACC", "qty": 42}]',
                                                           '{"po_number": "PO MO 9001"}')),
  format('possible_duplicate:%s:%%', pg_temp.oid('dup_r')), 'create: "PO MO 9001" is the same portal PO as "PO-MO-9001"');

-- 2i. Submit time: an ERP order that loaded after the draft was reviewed.
select pg_temp.as_postgres();
insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, customer_po_number,
                                 order_status, order_status_desc, line_status, order_qty, order_date_key)
values ('ZZEDI-LATE', 1, 'MO-CUST', 'MOPK-ACC', 'PO-MO-9001', 'R', 'Released', 'A', 41,
        to_char(current_date, 'YYYYMMDD')::int);
select pg_temp.become('rep');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('dup_r')),
  'erp_duplicate_unreviewed:%ZZEDI-LATE%', 'submit: refused while the ERP order is in none of the stored warnings');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.update_sql(pg_temp.oid('dup_r'),
    jsonb_build_object('po_number', 'PO-MO-9001', 'ship_to_key', 'MO-CUST|1', 'ship_to_confirmed', true,
                       'lines', '[{"part_id": "MO-ACC", "qty": 41, "part_confirmed": true}]'::jsonb)),
  'possible_duplicate_erp:ZZEDI-LATE:%', 'update: the ERP twin refuses an update without allow_duplicate');
select public.mcp_update_order_draft(pg_temp.oid('dup_r'),
  jsonb_build_object('po_number', 'PO-MO-9001', 'ship_to_key', 'MO-CUST|1', 'ship_to_confirmed', true,
                     'allow_duplicate', true,
                     'lines', '[{"part_id": "MO-ACC", "qty": 41, "part_confirmed": true}]'::jsonb));
select pg_temp.become('rep');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('dup_r'), true)).status = 'submitted'),
  'submit: once the warning is stored (update with allow_duplicate) it submits');

-- Review fix: recall clears acknowledged_at, so the 'may be its own entry'
-- hint keys on recalled_at, which survives the recall.
select pg_temp.assert(
  (select (public.recall_order(pg_temp.oid('dup_r'))).recalled_at is not null),
  'recall: stamps recalled_at');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert(
  (select public.mcp_update_order_draft(pg_temp.oid('dup_r'),
            jsonb_build_object('po_number', 'PO-MO-9001', 'ship_to_key', 'MO-CUST|1', 'ship_to_confirmed', true,
                               'allow_duplicate', true,
                               'lines', '[{"part_id": "MO-ACC", "qty": 41, "part_confirmed": true}]'::jsonb)) -> 'alerts'
          @> '[{"type": "erp_po_match", "may_be_this_order": true}]'),
  'preview after a recall: erp_po_match says the ERP order may be this draft''s own entry');
select pg_temp.become('rep');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('dup_r'), true)).status = 'submitted'),
  'and it submits again (section 3 reads it from v_orders_ready_for_erp)');

-- 2j. Guard: a later restatement must keep the probes.
select pg_temp.as_postgres();
select pg_temp.assert(
  pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%order_erp_po_matches%'
  and pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%order_po_norm(o.po_number)%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%order_erp_po_matches%'
  and pg_get_functiondef('public.submit_order(bigint, boolean)'::regprocedure) like '%erp_duplicate_unreviewed%',
  'guard: mcp_order_apply, mcp_order_preview and submit_order still carry the ERP duplicate checks');


--------------------------------------------------------------------------
-- 3. shipto: the account's main (sold-to) address as a ship-to
--------------------------------------------------------------------------
select pg_temp.as_postgres();
insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag, credit_status)
values ('MA-NOSHIP', 'MA-NOSHIP', 'Main Only Dealer',   'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MA-BOTH',   'MA-BOTH',   'Both Address Dealer', 'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MA-BLANK',  'MA-BLANK',  'Blank Main Dealer',  'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MA-INACT',  'MA-INACT',  'Inactive Main Dealer', 'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MA-TWIN-A', 'MA-TWIN-A', 'Twin Main Dealer',   'MO REP', 'MO-DEALER', 'Y', 'APPROVED'),
       ('MA-TWIN-B', 'MA-TWIN-B', 'Twin Main Dealer',   'MO REP', 'MO-DEALER', 'Y', 'APPROVED');
insert into erp.dim_ship_to
  (ship_to_key, customer_id, addr_no, ship_to_id, ship_to_name, address1, city, state, zip_code,
   active_flag, ffl_license_number, ffl_expiration_raw, address_source, is_unknown_ship_to)
values
  ('MA-NOSHIP|CUST', 'MA-NOSHIP', null, null, 'Main Only Dealer', '1 Main', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'CustomerMaster', false),
  ('MA-BOTH|1', 'MA-BOTH', 1, 'STORE', 'Both Store', '4 Oak St', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-33333', '01/31/2028', 'ShipTo', false),
  ('MA-BOTH|CUST', 'MA-BOTH', null, null, 'Both Address Dealer', '8 Pine St', 'Meridian', 'ID', null,
   'Y', null, null, 'CustomerMaster', false),
  ('MA-BLANK|CUST', 'MA-BLANK', null, null, 'Blank Main Dealer', '', 'Boise', 'ID', '83702',
   'Y', null, null, 'CustomerMaster', false),
  ('MA-INACT|CUST', 'MA-INACT', null, null, 'Inactive Main Dealer', '7 Elm', 'Boise', 'ID', '83702',
   'N', null, null, 'CustomerMaster', false),
  ('MA-TWIN-A|CUST', 'MA-TWIN-A', null, null, 'Twin Main Dealer', '2 Main', 'Boise', 'ID', '83702',
   'Y', null, null, 'CustomerMaster', false),
  ('MA-TWIN-B|1', 'MA-TWIN-B', 1, 'TWINB', 'Twin B Store', '3 Main', 'Boise', 'ID', '83702',
   'Y', null, null, 'ShipTo', false);

-- feature.order_main_address_ship_to, as the superuser.
create or replace function pg_temp.main_flag(p_on boolean) returns void
language plpgsql as $$
begin
  perform pg_temp.as_postgres();
  update public.app_settings set enabled = p_on where setting_key = 'feature.order_main_address_ship_to';
end $$;
-- A request with no ship-to for p_ck; p_extra overrides.
create or replace function pg_temp.sreq(p_key text, p_ck text, p_lines jsonb, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('idempotency_key', p_key, 'customer_key', p_ck,
                            'po_number', 'PO-' || p_key,
                            'lines', pg_temp.confirmed(p_lines)) || p_extra
$$;

-- The rep drafts a lot in this file.
select pg_temp.flag(true, '{"max_drafts_per_user_per_day": 200}');

-- 3a. The setting exists and is off; helpers and grants.
select pg_temp.assert(
  (select not enabled from public.app_settings where setting_key = 'feature.order_main_address_ship_to'),
  'setting: feature.order_main_address_ship_to exists and is off');
select pg_temp.assert(
  public.order_ship_to_kind('A|1', 'A', 'ShipTo', 'STORE', false) = 'ship_to'
  and public.order_ship_to_kind('A|CUST', 'A', 'CustomerMaster', null, false) = 'customer_address'
  and public.order_ship_to_kind('B|CUST', 'A', 'CustomerMaster', null, false) is null
  and public.order_ship_to_kind('A|2', 'A', 'ShipTo', ' ', false) is null
  and public.order_ship_to_kind('(Unknown)', '(Unknown)', 'Unknown', null, true) is null,
  'order_ship_to_kind: ship_to, customer_address, or null');
select pg_temp.assert(
  has_function_privilege('authenticated', 'public.order_ship_to_kind(text,text,text,text,boolean)', 'execute')
  and has_function_privilege('authenticated', 'public.order_ship_to_orderable(text,text,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.order_ship_to_kind(text,text,text,text,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.order_ship_to_orderable(text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.order_ship_to_choices(text)', 'execute'),
  'grants: helpers for authenticated only; order_ship_to_choices still closed');

-- 3b. Flag off: order_context unchanged, and nothing offers the main address.
select pg_temp.become('rep');
select pg_temp.assert(
  (select j -> 'blockers' ? 'no_orderable_ship_to' and j -> 'default_ship_to_key' = 'null'::jsonb
          and j -> 'ship_tos' = '[]'::jsonb and j -> 'main_address_orderable' = 'false'::jsonb
          and j -> 'ship_to_alerts' = '[]'::jsonb
     from public.order_context('MA-NOSHIP') j),
  'flag off: a main-only account is still no_orderable_ship_to, its main row not listed');
select pg_temp.assert(
  (select not (j -> 'ship_tos' @> '[{"kind": "customer_address"}]')
          and (j ->> 'orderable_ship_to_count')::int = 2
     from public.order_context('MO-CUST') j),
  'flag off: MO-CUST lists its ship-tos only (its |CUST row is not offered)');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-off-1', 'MA-NOSHIP', '[{"part_id": "MO-ACC", "qty": 3}]')),
  'no_orderable_ship_to:MA-NOSHIP:%not enabled%', 'flag off: create refused up front, naming the flag');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-off-2', 'MA-NOSHIP', '[{"part_id": "MO-ACC", "qty": 3}]',
                                                            '{"ship_to_key": "MA-NOSHIP|CUST"}')),
  'ship_to_invalid:MA-NOSHIP|CUST:%not enabled%', 'flag off: the main address given explicitly is refused');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-off-3', 'MA-INACT', '[{"part_id": "MO-ACC", "qty": 3}]')),
  'no_orderable_ship_to:MA-INACT:%inactive%', 'flag off: an inactive main address is called inactive, not "not enabled"');

-- 3c. Flag on: order_context.
select pg_temp.main_flag(true);
select pg_temp.become('rep');
select pg_temp.assert(
  (select (j ->> 'orderable')::boolean and j -> 'blockers' = '[]'::jsonb
          and j ->> 'default_ship_to_key' = 'MA-NOSHIP|CUST'
          and (j ->> 'main_address_orderable')::boolean
          and j ->> 'main_address_ship_to_key' = 'MA-NOSHIP|CUST'
          and (j ->> 'orderable_ship_to_count')::int = 0
          and j -> 'ship_tos' -> 0 ->> 'kind' = 'customer_address'
          and (j -> 'ship_tos' -> 0 -> 'ffl' ->> 'current')::boolean
          and j -> 'ship_to_alerts' ? 'ship_to_main_address'
     from public.order_context('MA-NOSHIP') j),
  'order_context: a main-only account is orderable, defaults to |CUST, flags ship_to_main_address');
select pg_temp.assert(
  (select j ->> 'default_ship_to_key' = 'MA-BOTH|1' and (j ->> 'orderable_ship_to_count')::int = 1
          and jsonb_array_length(j -> 'ship_tos') = 2
          and j -> 'ship_tos' -> 1 ->> 'kind' = 'customer_address'
          and j -> 'ship_to_alerts' = '[]'::jsonb
     from public.order_context('MA-BOTH') j),
  'order_context: a ship-to stays the default; the main address is listed last');
select pg_temp.assert(
  (select j -> 'blockers' ? 'no_orderable_ship_to' and not (j ->> 'main_address_orderable')::boolean
     from public.order_context('MA-BLANK') j)
  and (select j -> 'blockers' ? 'no_orderable_ship_to' from public.order_context('MA-INACT') j),
  'order_context: a blank or inactive main address does not count');
select pg_temp.assert(
  (select (e ->> 'orderable_ship_tos')::int = 0 and (e ->> 'main_address_orderable')::boolean
     from jsonb_array_elements(public.order_same_name_accounts('MA-TWIN-A')) e
    where e ->> 'customer_key' = 'MA-TWIN-A')
  and (select (e ->> 'orderable_ship_tos')::int = 1 and not (e ->> 'main_address_orderable')::boolean
     from jsonb_array_elements(public.order_same_name_accounts('MA-TWIN-A')) e
    where e ->> 'customer_key' = 'MA-TWIN-B'),
  'order_same_name_accounts: orderable_ship_tos counts real ship-tos; main_address_orderable is separate');

-- 3d. A draft for a main-only account ships to the main address by default.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('sh_main', pg_temp.sreq('shipto-1', 'MA-NOSHIP', '[{"part_id": "MO-RL-BG", "qty": 1}]'));
select pg_temp.assert(
  (select ship_to_key = 'MA-NOSHIP|CUST' from public.orders where id = pg_temp.oid('sh_main'))
  and (select j -> 'alerts' @> '[{"type": "ship_to_main_address", "severity": "warning"}]'
              and j -> 'ship_to' ->> 'kind' = 'customer_address'
              and j -> 'ship_to' ->> 'zip' = '83702'
              and (j -> 'ffl' ->> 'current')::boolean
              and (j -> 'would_submit' ->> 'ok')::boolean
         from pg_temp.prev('sh_main') j),
  'create: no ship-to -> the main address, flagged ship_to_main_address; would_submit ok on the customer FFL');
select pg_temp.create('sh_alias', pg_temp.sreq('shipto-2', 'MA-NOSHIP', '[{"part_id": "MO-ACC", "qty": 2}]',
                                               '{"ship_to_key": "MA-NOSHIP|MAIN"}'));
select pg_temp.assert(
  (select ship_to_key = 'MA-NOSHIP|CUST' from public.orders where id = pg_temp.oid('sh_alias')),
  'create: ship_to_key <ck>|MAIN is stored as <ck>|CUST');

-- 3e. Picking the main address while ship-tos exist needs the confirmation.
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-3', 'MA-BOTH', '[{"part_id": "MO-RL-BG", "qty": 1}]',
                                                            '{"ship_to_key": "MA-BOTH|CUST"}')),
  'ship_to_confirmation_required:MA-BOTH:%and its main address%', 'create: main address while a ship-to exists is confirmed');
select pg_temp.as_postgres();
select pg_temp.assert(
  (select jsonb_array_length(j) = 2 and j -> 0 ->> 'ship_to_key' = 'MA-BOTH|1'
          and j -> 1 ->> 'kind' = 'customer_address' and j -> 1 ->> 'label' like 'Main address - Both Address Dealer, Meridian%'
     from public.order_ship_to_choices('MA-BOTH') j),
  'order_ship_to_choices: the main address last, kind and label');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('sh_both_main', pg_temp.sreq('shipto-4', 'MA-BOTH', '[{"part_id": "MO-RL-BG", "qty": 1}]',
                                                   '{"ship_to_key": "MA-BOTH|CUST", "ship_to_confirmed": true}'));
select pg_temp.assert(
  (select ship_to_key = 'MA-BOTH|CUST' from public.orders where id = pg_temp.oid('sh_both_main'))
  and (select j -> 'alerts' @> '[{"type": "ffl_not_current", "severity": "hard"}]'
              and j -> 'alerts' @> '[{"type": "ship_to_main_address"}]'
              and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'FFL: ship-to the main address has%')
              and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'The main address has no state or ZIP%')
              and not (j -> 'would_submit' ->> 'ok')::boolean
         from pg_temp.prev('sh_both_main') j),
  'create: confirmed main address; no FFL on the customer record -> ffl_not_current names the main address; no ZIP warned');
select pg_temp.become('rep');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('sh_both_main')),
  '%ship-to the main address has no current FFL%', 'submit: firearms to a main address with no FFL on file');

-- 3f. An update that leaves ship_to_key out means the default (critique 3).
select pg_temp.become_mcp('rep', 'w_rep');
select public.mcp_update_order_draft(pg_temp.oid('sh_both_main'),
  jsonb_build_object('po_number', 'PO-shipto-4', 'lines', '[{"part_id": "MO-RL-BG", "qty": 1, "part_confirmed": true}]'::jsonb));
select pg_temp.assert(
  (select ship_to_key = 'MA-BOTH|1' from public.orders where id = pg_temp.oid('sh_both_main')),
  'update: no ship_to_key -> the single ship-to default, not the earlier main pick');
select pg_temp.create('sh_both_def', pg_temp.sreq('shipto-5', 'MA-BOTH', '[{"part_id": "MO-ACC", "qty": 4}]'));
select pg_temp.assert(
  (select ship_to_key = 'MA-BOTH|1' from public.orders where id = pg_temp.oid('sh_both_def')),
  'create: with one ship-to and a main address, the ship-to is still the default');

-- 3g. Refused up front: nothing orderable, a bad explicit key, another account's.
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-6', 'MA-BLANK', '[{"part_id": "MO-ACC", "qty": 5}]')),
  'no_orderable_ship_to:MA-BLANK:%street or city%', 'create: a blank main address is refused up front');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-7', 'MA-INACT', '[{"part_id": "MO-ACC", "qty": 5}]')),
  'no_orderable_ship_to:MA-INACT:%inactive%', 'create: an inactive main address is refused up front');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-8', 'MA-BLANK', '[{"part_id": "MO-ACC", "qty": 5}]',
                                                            '{"ship_to_key": "MA-BLANK|CUST"}')),
  'ship_to_invalid:MA-BLANK|CUST:%', 'create: a blank main address given explicitly is refused');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.sreq('shipto-9', 'MA-NOSHIP', '[{"part_id": "MO-ACC", "qty": 5}]',
                                                            '{"ship_to_key": "MA-BOTH|CUST"}')),
  'ship_to_invalid:MA-BOTH|CUST:%', 'create: another account''s main address is refused');
select pg_temp.as_postgres();
select pg_temp.assert(
  (select count(*) = 0 from public.orders where customer_key in ('MA-BLANK', 'MA-INACT')),
  'create: nothing was saved for the refused accounts');

-- 3h. Submit: no ship-to ID, the customer FFL, ship_to_source stamped.
select pg_temp.become('rep');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('sh_main'), true)).status = 'submitted'),
  'submit: a main-address order submits');
select pg_temp.assert(
  (select ship_to_id is null and ship_to_addr_no is null and ship_to_source = 'customer_address'
          and ship_to_address = '1 Main, Boise, ID 83702'
          and ffl_on_file_number = '1-23-456-78-9A-12345' and ffl_license_number = '1-23-456-78-9A-12345'
     from public.orders where id = pg_temp.oid('sh_main')),
  'submit: no ship-to ID, the main address, the customer-record FFL, ship_to_source customer_address');
select pg_temp.assert(
  (select use_customer_address and ship_to_source = 'customer_address' and ship_to_id is null
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('sh_main'))
  and (select not use_customer_address and ship_to_source = 'ship_to'
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('dup_r')),
  'v_orders_ready_for_erp: use_customer_address for the main address, ship_to for a ship-to');
select pg_temp.assert(
  (select (public.recall_order(pg_temp.oid('sh_main'))).ship_to_source is null),
  'recall: back in draft the order has no ship_to_source');

-- 3i. The flag turned off after drafting: submit refuses the main address.
select pg_temp.main_flag(false);
select pg_temp.become('rep');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('sh_alias')),
  '%main address cannot take an order%', 'submit: flag off -> a main-address draft is refused');
select pg_temp.as_postgres();
select pg_temp.assert(
  (select (j -> 'would_submit' ->> 'ok')::boolean is false
          and j -> 'alerts' @> '[{"type": "ship_to_main_address"}]'
     from public.mcp_order_preview(pg_temp.oid('sh_alias'), false) j),
  'preview: flag off -> still shows the main address, would_submit false');

-- 3j. Guard: a later restatement must keep the main address.
select pg_temp.assert(
  pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%no_orderable_ship_to%'
  and pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%order_ship_to_kind%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%ship_to_main_address%'
  and pg_get_functiondef('public.submit_order(bigint, boolean)'::regprocedure) like '%ship_to_source%'
  and pg_get_functiondef('public.order_context(text)'::regprocedure) like '%main_address_orderable%',
  'guard: mcp_order_apply, mcp_order_preview, submit_order and order_context still carry the main address');

--------------------------------------------------------------------------
-- 4. contact_header: the PO's contact matched, PO header fields stored
--------------------------------------------------------------------------
select pg_temp.as_postgres();
insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id, customer_type, active_flag, credit_status,
   ar_terms_rule_id, invoice_email)
values ('CH-CUST', 'CH-CUST', 'Header Test Dealer', 'MO REP', 'MO-DEALER', 'Y', 'APPROVED', '2%10 N30', 'inv@d.test'),
       ('CH-PRE',  'CH-PRE',  'Prepay Test Dealer', 'MO REP', 'MO-DEALER', 'Y', 'APPROVED', 'PREPAY', null);
insert into erp.dim_ship_to
  (ship_to_key, customer_id, addr_no, ship_to_id, ship_to_name, address1, city, state, zip_code,
   active_flag, ffl_license_number, ffl_expiration_raw, address_source, is_unknown_ship_to)
values
  ('CH-CUST|1', 'CH-CUST', 1, 'BLDG1', 'Building 1', '1 Dock Rd', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false),
  ('CH-CUST|2', 'CH-CUST', 2, 'BLDG2', 'Building 2', '2 Dock Rd', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false),
  ('CH-PRE|1', 'CH-PRE', 1, 'STORE', 'Prepay Store', '3 Dock Rd', 'Boise', 'ID', '83702',
   'Y', '1-23-456-78-9A-12345', '01/31/2028', 'ShipTo', false);
-- A buyer; the AP primary; one of ours; a phoneless twin of the buyer's
-- email; a phone-only person; a two-address email field; the invoice
-- mailbox (named, no phone).
insert into erp.dim_customer_contact
  (customer_contact_key, customer_key, contact_id, contact_name, first_name, last_name, position,
   email, phone, primary_contact_flag, contact_active_flag)
values ('CH|A', 'CH-CUST', 'A', 'Buyer Person', 'Buyer', 'Person', 'Buyer', 'Buyer@D.test ', '(555) 123-4567', 'N', 'Y'),
       ('CH|B', 'CH-CUST', 'B', null, null, null, null, 'ap@d.test', null, 'Y', 'Y'),
       ('CH|C', 'CH-CUST', 'C', 'Our Rep', null, null, null, 'rep@christensenarms.com', '555 000 1111', 'N', 'Y'),
       ('CH|D', 'CH-CUST', 'D', 'Buyer Person', null, null, null, 'buyer@d.test', null, 'N', 'Y'),
       ('CH|E', 'CH-CUST', 'E', 'Sam Phone', null, null, null, 'sam@d.test', '555-999-0000', 'N', 'Y'),
       ('CH|F', 'CH-CUST', 'F', 'Multi Mail', null, null, null, 'a@d.test; multi@d.test', null, 'N', 'Y'),
       ('CH|G', 'CH-CUST', 'G', 'Invoice Desk Person', null, null, null, 'inv@d.test', null, 'N', 'Y');
insert into erp.dim_part
  (part_key, part_id, part_description, product_code, product_family, chambering,
   barrel_length, finish, stock_color, handedness, status, is_kit_flag, upc)
values ('CHPK-UPC', 'CH-UPC', 'Header test sling', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N', '899000000045'),
       ('CHPK-TBD', 'CH-TBD', 'Header test cap', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N', 'TBD'),
       ('CHPK-SUG', 'CH-SUG', 'Header test strap', 'FG-ACC', 'N/A', 'N/A', null, null, null, null, 'A', 'N', '899000000052');
insert into public.price_list_items (price_list_id, part_id, unit_price)
select (select id from t_ids where label = 'pl'), v.part, v.price
from (values ('CH-UPC', 10.00), ('CH-TBD', 20.00)) v(part, price);
-- The customer's item 204665 was MO-ACC on their last ERP order.
insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, customer_po_number, customer_part_id,
                                 unit_price, order_qty, order_status, line_status, order_date_key)
values ('ZZCH-HIST', 1, 'CH-CUST', 'MOPK-ACC', 'HIST-ONLY', '204665', 50, 1, 'C', 'C',
        to_char(current_date - 30, 'YYYYMMDD')::int);

-- A create request for CH-CUST at BLDG1; p_extra overrides.
create or replace function pg_temp.hreq(p_key text, p_lines jsonb, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('idempotency_key', p_key, 'customer_key', 'CH-CUST',
                            'ship_to_key', 'CH-CUST|1', 'ship_to_confirmed', true,
                            'po_number', 'PO-' || p_key,
                            'lines', pg_temp.confirmed(p_lines)) || p_extra
$$;
create or replace function pg_temp.has_alert(j jsonb, p_type text) returns boolean
language sql as $$ select coalesce(j -> 'alerts' @> jsonb_build_array(jsonb_build_object('type', p_type)), false) $$;

-- 4a. Helpers.
select pg_temp.assert(
  public.order_terms_canon('2% 10/NET 30') = '2%10N30' and public.order_terms_canon('2%10 N30') = '2%10N30'
  and public.order_terms_canon('2.0% 10 NET 30') = '2%10N30'
  and public.order_terms_canon('NET30 FREE SHIP') = 'N30' and public.order_terms_canon('Net 30 days') = 'N30'
  and public.order_terms_canon('NET 30') = 'N30' and public.order_terms_canon('NET120 FREE SHI') = 'N120'
  and public.order_terms_canon('2%30 1%60 N90') <> public.order_terms_canon('2%30 N90')
  and public.order_terms_canon('PREPAY') <> 'N30' and public.order_terms_canon(null) is null,
  'order_terms_canon: one spelling for the same terms; different terms stay different');
select pg_temp.assert(
  public.order_first_email('Pat <Pat@X.com>; b@x.com') = 'pat@x.com'
  and public.order_first_email('no address') is null
  and public.order_name_canon('PERSON, Buyer') = public.order_name_canon('buyer person'),
  'order_first_email / order_name_canon');
-- Parity with contacts.test.ts (isBillingContact / isInternalContact) and
-- tools.ts' invoice_email rule.
select pg_temp.assert(
  public.order_contact_excluded(null, null, 'ap@x.com', null, null, null) = 'billing'
  and public.order_contact_excluded('Jo Smith', 'Purchasing / AP', 'jo@x.com', '5551234567', null, null) is null
  and public.order_contact_excluded('INVOICES', 'Purchasing', 'inv1@x.com', null, null, null) = 'billing'
  and public.order_contact_excluded('Tom Billings', null, 'tbillings@x.com', null, null, null) is null
  and public.order_contact_excluded('Billings Guns', null, 'billingsguns@x.com', null, null, null) is null
  and public.order_contact_excluded('AR-15 Specialist', null, 'sp@x.com', null, null, null) is null
  and public.order_contact_excluded('Accounts Payable', null, 'jo@x.com', null, null, null) = 'billing'
  and public.order_contact_excluded('Owner', null, 'ap@x.com', null, null, null) is null
  and public.order_contact_excluded('Jo', null, 'importinvoice@x.com', null, null, null) = 'billing'
  and public.order_contact_excluded('Our Rep', null, 'x@christensenarms.com', null, null, null) = 'internal'
  and public.order_contact_excluded('Our Rep', null, 'x@sub.christensenarms.com', null, null, null) = 'internal'
  and public.order_contact_excluded('inv@d.test', null, 'inv@d.test', null, 'inv@d.test; ar@d.test', null) = 'billing'
  and public.order_contact_excluded('Jo Owner', null, 'jo@d.test', '555-123-4567', 'jo@d.test', null) is null
  and public.order_contact_excluded('Jo Owner', null, 'jo@d.test', null, null, 'jo@d.test') = 'billing',
  'order_contact_excluded: the contacts.ts parity cases');

-- 4b. order_match_contact (as the DEFINER callers see it).
select pg_temp.assert(
  (select j ->> 'customer_contact_key' = 'CH|A' and j ->> 'matched_by' = 'email'
     from public.order_match_contact('CH-CUST', '  BUYER@d.test ', null, null) j)
  and public.order_match_contact('CH-CUST', 'buyer@d.test', null, null)
      = public.order_match_contact('CH-CUST', 'buyer@d.test', null, null),
  'match: email (case, spaces) -> the buyer, over the phoneless twin, deterministic');
select pg_temp.assert(
  (select j ->> 'customer_contact_key' is null and j ->> 'reason' = 'billing_only'
     from public.order_match_contact('CH-CUST', 'ap@d.test', null, null) j)
  and (select j ->> 'reason' = 'billing_only'
     from public.order_match_contact('CH-CUST', 'inv@d.test', null, null) j)
  and (select j ->> 'customer_contact_key' is null and j ->> 'reason' = 'internal_only'
     from public.order_match_contact('CH-CUST', 'rep@christensenarms.com', null, null) j),
  'match: a billing (AP, invoice_email) or internal contact is never chosen');
select pg_temp.assert(
  (select j ->> 'customer_contact_key' = 'CH|A' and j ->> 'matched_by' = 'name_phone'
     from public.order_match_contact('CH-CUST', null, 'buyer person', '+1 (555) 123-4567') j)
  and (select j ->> 'reason' = 'name_only' and j -> 'candidates' = '["CH|A", "CH|D"]'::jsonb
     from public.order_match_contact('CH-CUST', null, 'Buyer Person', null) j)
  and (select j ->> 'customer_contact_key' is null and j ->> 'reason' = 'phone_only'
              and j -> 'candidates' = '["CH|E"]'::jsonb
     from public.order_match_contact('CH-CUST', 'new@d.test', null, '555.999.0000') j)
  and (select j ->> 'reason' = 'no_match' from public.order_match_contact('CH-CUST', 'nobody@d.test', null, null) j)
  and (select j ->> 'customer_contact_key' = 'CH|F'
     from public.order_match_contact('CH-CUST', 'multi@d.test', null, null) j),
  'match: name + phone; name only and phone only list candidates; no match; a two-address ERP email');

-- 4c. Draft time.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('ch_plain', pg_temp.hreq('chhdr-key-1', '[{"part_id": "MO-ACC", "qty": 101}]'));
select pg_temp.assert(
  (select (j -> 'would_submit' ->> 'ok')::boolean and not (j ? 'po') and not (j ? 'po_contact')
          and not pg_temp.has_alert(j, 'contact_not_on_file') and not (j -> 'lines' -> 0 ? 'upc')
     from pg_temp.prev('ch_plain') j),
  'create: part + qty only drafts as before (no po block, no new alerts or line keys)');

select pg_temp.create('ch_email', pg_temp.hreq('chhdr-key-2', '[{"part_id": "MO-ACC", "qty": 102}]',
                                               '{"contact_email": "buyer@d.test"}'));
select pg_temp.assert(
  (select customer_contact_key = 'CH|A' and contact_match = 'email' and po_contact_email = 'buyer@d.test'
     from public.orders where id = pg_temp.oid('ch_email'))
  and (select not pg_temp.has_alert(j, 'contact_not_on_file') and j -> 'contact' ->> 'matched_by' = 'email'
         from pg_temp.prev('ch_email') j),
  'create: contact_email matches the ERP buyer (contact_match email)');

-- Review fix: an explicit customer_contact_key null clears the contact; the
-- kept PO email is not matched straight back.
select pg_temp.create('ch_clear', pg_temp.hreq('chhdr-key-2b', '[{"part_id": "MO-ACC", "qty": 112}]',
                                               '{"contact_email": "buyer@d.test"}'));
select public.mcp_update_order_draft(pg_temp.oid('ch_clear'),
  (pg_temp.hreq('chhdr-key-2b', '[{"part_id": "MO-ACC", "qty": 112}]') - 'idempotency_key')
  || '{"customer_contact_key": null}'::jsonb);
select pg_temp.assert(
  (select customer_contact_key is null and po_contact_email = 'buyer@d.test'
     from public.orders where id = pg_temp.oid('ch_clear')),
  'update: customer_contact_key null clears the contact and keeps the PO email as text');

select pg_temp.create('ch_nofile', pg_temp.hreq('chhdr-key-3', '[{"part_id": "MO-ACC", "qty": 103}]',
                                                '{"contact_email": "Pat New <pat.new@d.test>", "contact_phone": 2085551212}'));
select pg_temp.assert(
  (select customer_contact_key is null and contact_match is null and po_contact_phone = '2085551212'
     from public.orders where id = pg_temp.oid('ch_nofile'))
  and (select j -> 'alerts' @> '[{"type": "contact_not_on_file", "reason": "no_match"}]'
              and j -> 'warnings' ->> 0 like 'CONTACT NOT ON FILE:%'
              and j -> 'po_contact' ->> 'email' = 'Pat New <pat.new@d.test>'
              and (j -> 'would_submit' ->> 'ok')::boolean
         from pg_temp.prev('ch_nofile') j),
  'create: an unknown PO contact is staged (contact_not_on_file, no_match); the draft still submits');

select pg_temp.create('ch_given', pg_temp.hreq('chhdr-key-4', '[{"part_id": "MO-ACC", "qty": 104}]',
                                               '{"customer_contact_key": "CH|E", "contact_email": "buyer@d.test"}'));
select pg_temp.assert(
  (select customer_contact_key = 'CH|E' and contact_match = 'given' from public.orders where id = pg_temp.oid('ch_given'))
  and (select pg_temp.has_alert(j, 'contact_differs_from_po') from pg_temp.prev('ch_given') j),
  'create: the key the user sent wins over the PO email; contact_differs_from_po');

select pg_temp.create('ch_terms', pg_temp.hreq('chhdr-key-5', '[{"part_id": "MO-ACC", "qty": 105}]',
                                               '{"payment_terms": "2% 10/NET 30", "po_total": 5250.004, "vendor_number": 1167,
                                                 "po_date": "2026-01-02", "ship_via": "BEST WAY", "ship_to_location": "bldg1"}'));
select pg_temp.assert(
  (select not pg_temp.has_alert(j, 'terms_mismatch') and not pg_temp.has_alert(j, 'po_total_mismatch')
          and not pg_temp.has_alert(j, 'ship_to_location_mismatch')
          and (j -> 'ship_to' ->> 'po_location_matches')::boolean
          and j -> 'po' ->> 'vendor_number' = '1167' and j -> 'po' ->> 'customer_terms' = '2%10 N30'
          and (j -> 'po' ->> 'total')::numeric = 5250.00 and j -> 'po' ->> 'date' = '2026-01-02'
          and not exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'Ship via:%')
     from pg_temp.prev('ch_terms') j),
  'create: terms written differently, total within a cent, BEST WAY and the right location raise nothing');

select pg_temp.create('ch_off', pg_temp.hreq('chhdr-key-6', '[{"part_id": "MO-ACC", "qty": 106}]',
                                             '{"po_total": 5200, "ship_to_key": "CH-CUST|2", "ship_to_location": "BLDG1",
                                               "ship_via": "UPS Ground"}'));
select pg_temp.assert(
  (select j -> 'alerts' @> '[{"type": "po_total_mismatch", "difference": 100.00}]'
          and j -> 'alerts' @> '[{"type": "ship_to_location_mismatch", "matching_ship_to_key": "CH-CUST|1"}]'
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'PO TOTAL:%')
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'Ship via: the PO asks for UPS Ground%')
     from pg_temp.prev('ch_off') j),
  'create: po_total_mismatch (+100), ship_to_location_mismatch naming BLDG1, ship via warned');

select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.hreq('chhdr-key-7', '[{"part_id": "MO-ACC", "qty": 107}]',
                                                            '{"ship_to_key": null, "ship_to_location": "BLDG1"}')),
  'ship_to_confirmation_required:CH-CUST:%Ship To Location is BLDG1, which is ship_to_key CH-CUST|1%',
  'create: no ship-to on a two-ship-to account -> the refusal points at the PO''s location');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.hreq('chhdr-key-8', '[{"part_id": "MO-ACC", "qty": 108}]',
                                                            format('{"po_date": "%s"}', current_date + 3)::jsonb)),
  'invalid_input:po_date:%future%', 'create: a PO date in the future is refused');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.hreq('chhdr-key-9', '[{"part_id": "MO-ACC", "qty": 108}]',
                                                            '{"po_date": "11/12/2026"}')),
  'invalid_input:po_date:%YYYY-MM-DD%', 'create: a PO''s MM/DD/YYYY must be converted');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.hreq('chhdr-key-10', '[{"part_id": "MO-ACC", "qty": 108}]',
                                                            '{"po_total": "833264.17"}')),
  'invalid_input:po_total:%', 'create: po_total must be a number');

select pg_temp.create('ch_cancel', pg_temp.hreq('chhdr-key-11', '[{"part_id": "MO-ACC", "qty": 109}]',
                                                format('{"cancel_date": "%s"}', current_date - 1)::jsonb));
select pg_temp.assert(
  (select po_cancel_date = current_date - 1 from public.orders where id = pg_temp.oid('ch_cancel'))
  and (select j -> 'alerts' @> '[{"type": "cancel_date_passed", "severity": "hard"}]'
              and not (j -> 'would_submit' ->> 'ok')::boolean
              and j -> 'would_submit' ->> 'error' like 'cancel_date_passed:%'
         from pg_temp.prev('ch_cancel') j),
  'create: a passed cancel date is saved, flagged hard, and would_submit fails on it');
select pg_temp.create('ch_cancel2', pg_temp.hreq('chhdr-key-12', '[{"part_id": "MO-ACC", "qty": 110}]',
                                                 format('{"cancel_date": "%s", "requested_ship_date": "%s"}',
                                                        current_date + 3, current_date + 10)::jsonb));
select pg_temp.assert(
  (select pg_temp.has_alert(j, 'cancel_before_ship_date') and pg_temp.has_alert(j, 'cancel_date_soon')
          and (j -> 'would_submit' ->> 'ok')::boolean
     from pg_temp.prev('ch_cancel2') j),
  'create: ship date after the cancel date, and a cancel date within 7 days, are warnings');

select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('ch_upc', pg_temp.hreq('chhdr-key-13',
  '[{"part_id": "CH-UPC", "qty": 1, "upc": "0899000000045", "buyer_part_number": 204665},
    {"part_id": "CH-TBD", "qty": 1, "upc": "899000000099"},
    {"part_id": "MO-ACC", "qty": 111, "upc": "899-000-000-99", "buyer_part_number": "204665"}]'));
select pg_temp.assert(
  (select not pg_temp.has_alert(j, 'upc_mismatch')
          and j -> 'alerts' @> '[{"type": "buyer_part_conflict", "count": 1}]'
          and j -> 'lines' -> 0 ->> 'buyer_part_number' = '204665' and j -> 'lines' -> 0 ->> 'upc' = '0899000000045'
          and j -> 'lines' -> 2 ->> 'upc' = '89900000099'
          and j -> 'alerts' @> '[{"type": "buyer_part_conflict", "line_indexes": [0]}]'
     from pg_temp.prev('ch_upc') j),
  'create: an agreeing UPC (leading 0), a TBD part UPC and a part with no UPC raise no upc_mismatch; '
  'item 204665 on CH-UPC conflicts with the ERP history (MO-ACC), on MO-ACC it does not');
select pg_temp.create('ch_upc2', pg_temp.hreq('chhdr-key-14', '[{"part_id": "CH-UPC", "qty": 2, "upc": "899000000052"}]'));
select pg_temp.assert(
  (select j -> 'alerts' @> '[{"type": "upc_mismatch", "count": 1, "line_indexes": [0]}]'
          and exists (select 1 from jsonb_array_elements_text(j -> 'warnings') w where w like 'UPC CHECK:%')
     from pg_temp.prev('ch_upc2') j),
  'create: a PO UPC that is another part''s -> upc_mismatch');
select pg_temp.assert_fails(pg_temp.create_sql(pg_temp.hreq('chhdr-key-15', '[{"part_id": "CH-UPC", "qty": 3, "upc": "abc"}]')),
  'invalid_input:upc:%CH-UPC%', 'create: a UPC that is not 8-14 digits is refused');

select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.create('ch_unres', pg_temp.hreq('chhdr-key-16',
  '[{"part_id": "STRAP-X", "qty": 1, "unit_price": 5, "upc": "899000000052"}]',
  '{"price_override_reason": "test: unmatched strap"}'));
select pg_temp.assert(
  (select j -> 'alerts' @> '[{"type": "unmatched_parts", "upc_suggests": [{"ref": "STRAP-X", "part_id": "CH-SUG"}]}]'
     from pg_temp.prev('ch_unres') j),
  'create (admin): an unmatched line''s UPC suggests the part that carries it');

-- 4d. Update: header fields kept when left out, cleared by null; the user's
-- contact kept; replay.
select pg_temp.become_mcp('rep', 'w_rep');
select public.mcp_update_order_draft(pg_temp.oid('ch_terms'),
  jsonb_build_object('po_number', 'PO-chhdr-key-5', 'ship_to_key', 'CH-CUST|1', 'ship_to_confirmed', true,
                     'lines', '[{"part_id": "MO-ACC", "qty": 105, "part_confirmed": true}]'::jsonb));
select pg_temp.assert(
  (select po_payment_terms = '2% 10/NET 30' and po_date = '2026-01-02' and po_vendor_number = '1167'
          and po_total = 5250.00 and po_ship_to_location = 'bldg1'
     from public.orders where id = pg_temp.oid('ch_terms')),
  'update: PO header fields left out are kept');
select public.mcp_update_order_draft(pg_temp.oid('ch_terms'),
  jsonb_build_object('po_number', 'PO-chhdr-key-5', 'ship_to_key', 'CH-CUST|1', 'ship_to_confirmed', true,
                     'payment_terms', null, 'po_total', null,
                     'lines', '[{"part_id": "MO-ACC", "qty": 105, "part_confirmed": true}]'::jsonb));
select pg_temp.assert(
  (select po_payment_terms is null and po_total is null and po_date = '2026-01-02'
     from public.orders where id = pg_temp.oid('ch_terms')),
  'update: an explicit null clears a PO header field');
select public.mcp_update_order_draft(pg_temp.oid('ch_given'),
  jsonb_build_object('po_number', 'PO-chhdr-key-4', 'ship_to_key', 'CH-CUST|1', 'ship_to_confirmed', true,
                     'lines', '[{"part_id": "MO-ACC", "qty": 104, "part_confirmed": true}]'::jsonb));
select pg_temp.assert(
  (select customer_contact_key = 'CH|E' and contact_match = 'given' from public.orders where id = pg_temp.oid('ch_given')),
  'update: a contact the user gave is kept when the key is left out (the kept PO email does not re-match over it)');
select public.mcp_update_order_draft(pg_temp.oid('ch_given'),
  jsonb_build_object('po_number', 'PO-chhdr-key-4', 'ship_to_key', 'CH-CUST|1', 'ship_to_confirmed', true,
                     'customer_contact_key', null,
                     'lines', '[{"part_id": "MO-ACC", "qty": 104, "part_confirmed": true}]'::jsonb));
select pg_temp.assert(
  (select customer_contact_key is null and contact_match is null and po_contact_email = 'buyer@d.test'
     from public.orders where id = pg_temp.oid('ch_given')),
  'update: customer_contact_key null clears the contact (review fix: the kept PO email is not matched back; it stays as text)');
select pg_temp.assert(
  (select (public.mcp_create_order_draft(pg_temp.hreq('chhdr-key-3', '[{"part_id": "MO-ACC", "qty": 103}]',
             '{"contact_email": "Pat New <pat.new@d.test>", "contact_phone": 2085551212}')) ->> 'replayed')::boolean)
  and (select contact_match is null from public.orders where id = pg_temp.oid('ch_nofile')),
  'create: the same key and arguments replay');

-- 4e. Keys and grants.
select pg_temp.as_postgres();
select public.mcp_order_check_keys(
  '{"contact_email": "a@b.c", "contact_name": "x", "contact_phone": "1", "po_date": "2026-01-01",
    "cancel_date": null, "payment_terms": "N30", "ship_via": "x", "vendor_number": "1", "ship_to_location": "x",
    "po_total": 1, "lines": [{"part_id": "x", "qty": 1, "buyer_part_number": "1", "upc": "12345678"}]}'::jsonb, false);
select pg_temp.assert_fails($$select public.mcp_order_check_keys('{"total": 1}'::jsonb, false)$$,
  'invalid_input:total:%', 'check_keys: the new keys pass; total is still refused');
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.order_match_contact(text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.order_contact_excluded(text,text,text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.order_contact_rows(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.order_ship_to_for_location(text,text)', 'execute')
  and (select bool_and(p.proconfig is not null) from pg_proc p
        where p.prosecdef and p.proname in ('order_match_contact', 'order_contact_rows', 'order_ship_to_for_location')),
  'grants: contact matching is closed to clients; DEFINER helpers pin search_path');

-- 4f. Submit: the contact snapshot and the cancel date.
select pg_temp.become('rep');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('ch_nofile'), true)).contact_source = 'po'),
  'submit: an unmatched PO contact submits');
select pg_temp.assert(
  (select contact_source = 'po' and customer_contact_key is null and contact_email = 'Pat New <pat.new@d.test>'
          and contact_phone = '2085551212' and contact_name is null
     from public.orders where id = pg_temp.oid('ch_nofile')),
  'submit: contact_source po, the PO contact as the snapshot, no key');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('ch_email'), true)).contact_source = 'erp'),
  'submit: a matched contact submits');
select pg_temp.assert(
  (select contact_source = 'erp' and contact_email = 'Buyer@D.test' and contact_phone = '(555) 123-4567'
         from public.orders where id = pg_temp.oid('ch_email')),
  'submit: a matched contact -> contact_source erp, the ERP values');
select pg_temp.assert(
  (select (public.submit_order(pg_temp.oid('ch_plain'), true)).contact_source is null),
  'submit: no contact at all -> contact_source null');
select pg_temp.assert_fails(format('select public.submit_order(%s, true)', pg_temp.oid('ch_cancel')),
  'cancel_date_passed:%', 'submit: a passed PO cancel date is refused');
-- A key that no longer resolves never falls back to the PO contact.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('ch_stale', pg_temp.hreq('chhdr-key-17', '[{"part_id": "MO-ACC", "qty": 117}]',
                                               '{"customer_contact_key": "CH|A", "contact_email": "pat.new@d.test"}'));
select pg_temp.as_postgres();
update erp.dim_customer_contact set contact_active_flag = 'N' where customer_contact_key = 'CH|A';
select pg_temp.become('rep');
select pg_temp.assert(
  (select o.contact_source is null and o.contact_email is null and o.customer_contact_key = 'CH|A'
     from public.submit_order(pg_temp.oid('ch_stale'), true) o),
  'submit: a key gone inactive stamps nothing (never contact_source po next to a key)');
select pg_temp.assert(
  (select (public.recall_order(pg_temp.oid('ch_nofile'))).contact_source is null),
  'recall: back in draft the order has no contact_source');

-- 4g. The ready view: old columns where they were, the new ones appended.
select pg_temp.as_postgres();
select pg_temp.assert(
  (select array_agg(attname::text order by attnum) from pg_attribute
    where attrelid = 'public.v_orders_ready_for_erp'::regclass and attnum > 0)
  = array['order_id','status','source','user_id','created_by','created_at','submitted_at','acknowledged_at',
          'acknowledged_by','customer_key','customer_name','customer_type','po_number','requested_ship_date',
          'notes','customer_contact_key','ship_to_key','ship_to_id','ship_to_addr_no','ship_to_name',
          'ship_to_address','requires_ffl','ffl_license_number','ffl_expires_on','ffl_on_file_number',
          'ffl_on_file_expiration_raw','total_amount','mcp_token_id','client_request_id','source_ref',
          'mcp_warnings','updated_at','lines','price_override_reason','contact_name','contact_phone',
          'contact_email','ship_to_source','use_customer_address','contact_source','po_contact_name',
          'po_contact_email','po_contact_phone','contact_match','po_date','po_cancel_date','po_payment_terms',
          'po_ship_via','po_vendor_number','po_ship_to_location','po_total'],
  'v_orders_ready_for_erp: the old columns in order, then the appended ones');
select pg_temp.become('rep');
select pg_temp.assert(
  (select contact_source = 'erp' and lines -> 0 ? 'buyer_part_number' and lines -> 0 ? 'upc'
     from public.v_orders_ready_for_erp where order_id = pg_temp.oid('ch_email')),
  'v_orders_ready_for_erp: contact_source, and lines carry buyer_part_number and upc');

-- 4h. Guard: a later restatement must keep this section.
select pg_temp.as_postgres();
select pg_temp.assert(
  pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%order_match_contact%'
  and pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%po_cancel_date%'
  and pg_get_functiondef('public.mcp_order_apply(bigint, jsonb, jsonb, text, text)'::regprocedure) like '%buyer_part_number, upc)%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%contact_not_on_file%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%po_total_mismatch%'
  and pg_get_functiondef('public.submit_order(bigint, boolean)'::regprocedure) like '%cancel_date_passed%'
  and pg_get_functiondef('public.submit_order(bigint, boolean)'::regprocedure) like '%contact_source%'
  and pg_get_functiondef('public.mcp_order_check_keys(jsonb, boolean)'::regprocedure) like '%ship_to_location%',
  'guard: apply, preview, submit and check_keys still carry the contact and PO header fields');

--------------------------------------------------------------------------
-- 5. size: collapsed Stock / inactive / price_mismatch, stock_short, caps
--------------------------------------------------------------------------
select pg_temp.as_postgres();
-- Twelve accessories with 1 available each, four obsolete ones with plenty.
insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family, chambering, status, is_kit_flag)
select 'SZPK-' || n, 'SZ-' || lpad(n::text, 2, '0'), 'Size test part ' || n, 'FG-ACC', 'N/A', 'N/A', 'A', 'N'
from generate_series(1, 12) n
union all
select 'SZPK-I' || n, 'SZ-I' || n, 'Size test obsolete ' || n, 'FG-ACC', 'N/A', 'N/A', 'O', 'N'
from generate_series(1, 4) n;
insert into erp.fact_available_to_sell (part_key, site_key, shippable_warehouse_id, available_to_sell_qty)
select 'SZPK-' || n, 'MO-SITE', 'MAIN', 1 from generate_series(1, 12) n
union all
select 'SZPK-I' || n, 'MO-SITE', 'MAIN', 100 from generate_series(1, 4) n;
insert into public.price_list_items (price_list_id, part_id, unit_price)
select (select id from t_ids where label = 'pl'), d.part_id, 100.00
from erp.dim_part d where d.part_key like 'SZPK-%';

-- n lines SZ-01.. with qty q (and an expected price when given).
create or replace function pg_temp.sz_lines(p_n int, p_qty int, p_expected numeric default null) returns jsonb
language sql as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('part_id', 'SZ-' || lpad(n::text, 2, '0'), 'qty', p_qty,
                                                        'expected_unit_price', p_expected)) order by n)
  from generate_series(1, p_n) n
$$;
create or replace function pg_temp.n_like(j jsonb, p_like text) returns int
language sql as $$ select count(*)::int from jsonb_array_elements_text(j -> 'warnings') w where w like p_like $$;

-- 5a. The stored-warning collapse (and its one-off run on live drafts).
select pg_temp.assert(
  public.order_collapse_stock_warnings(
    '["Stock: A has 1 available to sell; 2 ordered in all. Stock does not block the order.",
      "Stock: B has -3 available to sell; 2 ordered in all. Stock does not block the order.",
      "X", "Stock: C has no available to sell; 1 ordered in all. Stock does not block the order."]'::jsonb)
    = '["Stock: A has 1 available to sell; 2 ordered in all. Stock does not block the order.",
        "Stock: B has -3 available to sell; 2 ordered in all. Stock does not block the order.",
        "X", "Stock: C has no available to sell; 1 ordered in all. Stock does not block the order."]'::jsonb
  and public.order_collapse_stock_warnings('null'::jsonb) = 'null'::jsonb
  and public.order_collapse_stock_warnings(null) is null,
  'collapse: 3 per-part Stock sentences and non-arrays are left alone');
select pg_temp.assert(
  public.order_collapse_stock_warnings(
    '["HAND PRICING x", "Stock: A B has 1 available to sell; 2 ordered in all. Stock does not block the order.",
      "TEST ORDER", "Stock: C has -3 available to sell; 2 ordered in all. Stock does not block the order.",
      "Stock: D has no available to sell; 1 ordered in all. Stock does not block the order.",
      "Stock: E has 0 available to sell; 4 ordered in all. Stock does not block the order."]'::jsonb)
    = '["HAND PRICING x",
        "Stock: 4 parts are short (ordered more than available to sell; shown as available/ordered): A B (1/2), C (-3/2), D (no/1), E (0/4). Stock does not block the order.",
        "TEST ORDER"]'::jsonb,
  'collapse: 4 become one sentence at the first one''s place (a part id with a space too); the rest keep their order');
select pg_temp.assert(
  (select x ->> 0 like 'Stock: 12 parts are short%: P1 (1/2), %, P10 (1/2) and 2 more. Stock does not block the order.'
          and jsonb_array_length(x) = 1
     from (select public.order_collapse_stock_warnings(jsonb_agg(
             format('Stock: P%s has 1 available to sell; 2 ordered in all. Stock does not block the order.', n) order by n)) x
             from generate_series(1, 12) n) z),
  'collapse: 12 name the first 10 and "and 2 more"');
select pg_temp.assert(
  not exists (select 1 from public.orders o
               where o.status = 'draft' and jsonb_typeof(o.mcp_warnings) = 'array'
                 and (select count(*) from jsonb_array_elements_text(o.mcp_warnings) w
                       where w ~ '^Stock: .+ has \S+ available to sell; \d+ ordered in all\.') > 3),
  'one-off: no draft keeps more than 3 per-part Stock sentences');

-- 5b. Twelve short parts: one sentence, the full list in stock_short.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('sz_12', pg_temp.req('size-key-12', pg_temp.sz_lines(12, 2)));
select pg_temp.assert(
  (select pg_temp.n_like(j, 'Stock: 12 of 12 parts are short%') = 1
          and pg_temp.n_like(j, 'Stock: % has % available to sell;%') = 0
          and pg_temp.n_like(j, '%: SZ-01 (1/2), SZ-02 (1/2), %, SZ-10 (1/2) and 2 more. Stock does not block the order.') = 1
          and jsonb_array_length(j -> 'stock_short') = 12 and (j ->> 'part_count')::int = 12
          and j -> 'stock_short' -> 0 = '{"part_id": "SZ-01", "ats_qty": 1, "qty": 2}'::jsonb
          and j -> 'inactive_parts' = '[]'::jsonb
          and j -> 'lines' -> 0 ->> 'ats_qty' = '1'
          and (j -> 'would_submit' ->> 'ok')::boolean
     from pg_temp.prev('sz_12') j),
  'preview: 12 short parts -> one Stock sentence naming 10; stock_short has all 12; ats_qty scaled (1, not 1.00000000)');
select pg_temp.as_postgres();
select pg_temp.assert(
  (select count(*) = 1 from public.orders o, jsonb_array_elements_text(o.mcp_warnings) w
    where o.id = pg_temp.oid('sz_12') and w like 'Stock:%'),
  'stored: mcp_warnings holds the one Stock sentence');

-- 5c. Three short parts keep today's sentences.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('sz_3', pg_temp.req('size-key-3', pg_temp.sz_lines(3, 3)));
select pg_temp.assert(
  (select pg_temp.n_like(j, 'Stock: SZ-0_ has 1 available to sell; 3 ordered in all. Stock does not block the order.') = 3
          and pg_temp.n_like(j, 'Stock: % of % parts are short%') = 0
          and jsonb_array_length(j -> 'stock_short') = 3
     from pg_temp.prev('sz_3') j),
  'preview: exactly 3 short parts keep one sentence each');

-- 5d. Four inactive parts: one sentence; inactive_parts lists them.
select pg_temp.create('sz_inact', pg_temp.req('size-key-in',
  '[{"part_id": "SZ-I1", "qty": 1}, {"part_id": "SZ-I2", "qty": 1}, {"part_id": "SZ-I3", "qty": 1}, {"part_id": "SZ-I4", "qty": 1}]'));
select pg_temp.assert(
  (select pg_temp.n_like(j, '4 parts are not active in the ERP: SZ-I1 (status O), SZ-I2 (status O), SZ-I3 (status O), SZ-I4 (status O).') = 1
          and pg_temp.n_like(j, '% is not an active part%') = 0
          and jsonb_array_length(j -> 'inactive_parts') = 4
          and j -> 'inactive_parts' -> 0 = '{"part_id": "SZ-I1", "status": "O"}'::jsonb
          and jsonb_array_length(j -> 'stock_short') = 0 and (j ->> 'part_count')::int = 4
     from pg_temp.prev('sz_inact') j),
  'preview: 4 inactive parts -> one sentence; inactive_parts has all 4');

-- 5e. Price mismatches: 2 keep their alerts; 12 collapse to one.
select pg_temp.create('sz_pm2', pg_temp.req('size-key-pm2', pg_temp.sz_lines(2, 5, 90)));
select pg_temp.assert(
  (select (select count(*) from jsonb_array_elements(j -> 'alerts') a where a ->> 'type' = 'price_mismatch') = 2
          and j -> 'alerts' @> '[{"type": "price_mismatch", "part_id": "SZ-02", "expected": 90, "effective": 100.00}]'
          and pg_temp.n_like(j, 'Price: the user expected $90.00 for SZ-0_;%') = 2
     from pg_temp.prev('sz_pm2') j),
  'preview: 2 price mismatches keep an alert and a sentence each');
select pg_temp.create('sz_pm', pg_temp.req('size-key-pm', pg_temp.sz_lines(12, 4, 90)));
select pg_temp.assert(
  (select (select count(*) from jsonb_array_elements(j -> 'alerts') a where a ->> 'type' = 'price_mismatch') = 1
          and (select (a ->> 'count')::int = 12 and jsonb_array_length(a -> 'parts') = 10
                      and (a ->> 'total_difference')::numeric = 480 and not (a ? 'part_id')
                      and a -> 'parts' -> 0 = '{"part_id": "SZ-01", "expected": 90, "effective": 100.00}'::jsonb
                 from jsonb_array_elements(j -> 'alerts') a where a ->> 'type' = 'price_mismatch')
          and pg_temp.n_like(j, 'Price:%') = 1
          and pg_temp.n_like(j, 'Price: on 12 lines the user expected a different price than the draft''s: '
                                'SZ-01 ($90.00 expected, $100.00 here), %and 2 more. Difference over those lines +$480.00.%') = 1
     from pg_temp.prev('sz_pm') j),
  'preview: 12 price mismatches -> one alert (count, 10 parts, total_difference) and one sentence');

-- 5f. Alert strings are capped; the counts keep the totals.
select pg_temp.become_mcp('admin', 'w_admin');
select pg_temp.create('sz_unres', pg_temp.req('size-key-un',
  (select jsonb_agg(jsonb_build_object('part_id', 'NO-SUCH-PART-NUMBER-LONG-' || lpad(n::text, 2, '0'),
                                       'qty', 1, 'unit_price', 5) order by n)
     from generate_series(1, 30) n),
  '{"price_override_reason": "test: size caps"}'));
select pg_temp.assert(
  (select length(a ->> 'refs') <= 600 and (a ->> 'count')::int = 30
     from pg_temp.prev('sz_unres') j, jsonb_array_elements(j -> 'alerts') a
    where a ->> 'type' = 'unmatched_parts'),
  'preview: unmatched_parts.refs capped at 600 characters, count 30');

-- 5g. Guard: a later restatement must keep the collapse.
select pg_temp.as_postgres();
select pg_temp.assert(
  pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%stock_short%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%parts are short%'
  and pg_get_functiondef('public.mcp_order_preview(bigint, boolean)'::regprocedure) like '%total_difference%'
  and not has_function_privilege('authenticated', 'public.order_collapse_stock_warnings(jsonb)', 'execute'),
  'guard: the preview still collapses; the collapse helper is closed to clients');

--------------------------------------------------------------------------
-- 6. docs: a PO stored through the MCP server (finding 6)
--------------------------------------------------------------------------
-- No schema change: attach_order_document / create_order_draft's documents
-- upload with the caller-JWT client (an MCP session, provider mcp), so the
-- portal's "add order documents" policy decides. Pinned here: that session
-- may add to its own draft (owner_id = the caller, user_metadata as the
-- server sends it), not to an order it cannot read, and the order's folder
-- is what get_order_status lists. Counted in this test's folders only: the
-- live bucket holds real documents.
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.create('doc_rep', pg_temp.req('docs-key-1', '[{"part_id": "MO-ACC", "qty": 77}]',
                                             '{"po_number": "DOC-9001"}'));
insert into storage.objects (bucket_id, name, owner, owner_id, user_metadata)
values ('order-documents', pg_temp.oid('doc_rep') || '/1731400000000-po215647_926271.csv',
        pg_temp.uid('rep'), pg_temp.uid('rep')::text,
        '{"source": "mcp", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}');
select pg_temp.assert(
  (select count(*) = 1 and bool_and(owner_id = pg_temp.uid('rep')::text) and bool_and(user_metadata ->> 'source' = 'mcp')
     from storage.objects
    where bucket_id = 'order-documents' and name like pg_temp.oid('doc_rep') || '/%'),
  'docs: an MCP session adds the PO to its own draft and lists it, owner_id the caller');
select pg_temp.as_postgres();
insert into public.orders (user_id, created_by, customer_key, customer_name, status, source)
values (pg_temp.uid('rep2'), pg_temp.uid('rep2'), 'MO-OTHER', 'Other Dealer', 'draft', 'portal');
insert into t_ids select 'doc_other', max(id) from public.orders where user_id = pg_temp.uid('rep2');
select pg_temp.become_mcp('rep', 'w_rep');
select pg_temp.assert_fails(
  format($$insert into storage.objects (bucket_id, name, owner_id) values ('order-documents', '%s/1731400000000-po.pdf', '%s')$$,
         pg_temp.oid('doc_other'), pg_temp.uid('rep')),
  '%row-level security%', 'docs: but not to an order that is not theirs');
select pg_temp.become('rep2');
select pg_temp.assert(
  (select count(*) from storage.objects
    where bucket_id = 'order-documents' and name like pg_temp.oid('doc_rep') || '/%') = 0,
  'docs: another rep cannot see the PO on that draft');
select pg_temp.as_postgres();

do $$ begin raise notice 'ALL MCP LARGE ORDER TESTS PASSED'; end $$;
rollback;
