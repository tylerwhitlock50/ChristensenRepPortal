/*============================================================================
  20261027_shipped_value.sql — assertions for 20261027090300_shipped_value.sql
      v_account_shipment_lines.shipped_value           per line
      v_account_recent_shipment_headers.shipped_value  per packlist
      v_territory_recent_events.shipped_value          'shipped' rows only

  Runs in a transaction and ROLLS BACK; writes throwaway users and ERP rows.
  The Midway USA figure is pinned to production data (a closed year, so it
  only moves if the ERP restates 2025 shipments). Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_shipped_value.sql

  A clean run prints "ALL SHIPPED VALUE TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-9292-4292-8292-929292929292'),
  ('admin', 'cccccccc-9393-4393-8393-939393939393');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@shipval.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'SV REPA'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Shape: existing columns in place, shipped_value appended last.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_account_shipment_lines')
  = array['customer_key', 'packlist_id', 'line_num', 'order_id', 'invoice_id', 'ship_date',
          'actual_delivery_date', 'part_key', 'part_id', 'part_description', 'shipped_qty',
          'shipped_revenue', 'tracking_number', 'shipped_value'],
  'v_account_shipment_lines: shipped_value appended last');

select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_account_recent_shipment_headers')
  = array['customer_key', 'packlist_id', 'ship_date', 'actual_delivery_date',
          'shipment_state', 'shipper_status_desc', 'tracking_number', 'ship_via',
          'order_ids', 'line_count', 'shipped_qty', 'shipped_revenue', 'rn',
          'shipped_value'],
  'v_account_recent_shipment_headers: rn stays where it was, shipped_value after it');

select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_territory_recent_events')
  = array['customer_key', 'customer_name', 'kind', 'occurred_on', 'order_id',
          'customer_po_number', 'packlist_id', 'line_no', 'part_id', 'part_description',
          'amount', 'qty', 'line_count', 'tracking_numbers', 'ship_via', 'promise_before',
          'promise_after', 'has_backlog', 'event_id', 'shipped_value'],
  'v_territory_recent_events: shipped_value appended last');

select pg_temp.assert(
  (select bool_and(c.reloptions @> array['security_invoker=true']
                   and has_table_privilege('authenticated', c.oid, 'select')
                   and not has_table_privilege('anon', c.oid, 'select'))
     from pg_class c
    where c.oid in ('public.v_account_shipment_lines'::regclass,
                    'public.v_account_recent_shipment_headers'::regclass,
                    'public.v_territory_recent_events'::regclass)),
  'all three still security_invoker, authenticated-only');

--------------------------------------------------------------------------
-- 2. Production: Midway USA's 2025 packlists (as an admin, through RLS).
--------------------------------------------------------------------------
select pg_temp.become('admin');

select pg_temp.assert(
  abs((select sum(shipped_value) from public.v_account_shipment_lines
        where customer_key = 'MIDW USA'
          and ship_date between date '2025-01-01' and date '2025-12-31')
      - 442975.01) <= 0.01,
  'Midway USA 2025 packlist value = $442,975.01 (shipped_revenue is a different figure)');

select pg_temp.assert(
  (select count(*)
     from public.v_account_recent_shipment_headers h
    where h.customer_key = 'MIDW USA'
      and h.ship_date between date '2025-01-01' and date '2025-12-31'
      and h.shipped_value is distinct from
          (select coalesce(sum(l.shipped_value), 0) from public.v_account_shipment_lines l
            where l.customer_key = h.customer_key and l.packlist_id = h.packlist_id)) = 0,
  'every Midway 2025 packlist header equals the sum of its lines');

select pg_temp.assert(
  (select sum(shipped_revenue) from public.v_account_recent_shipment_headers
    where customer_key = 'MIDW USA'
      and ship_date between date '2025-01-01' and date '2025-12-31')
  = (select sum(s.shipped_revenue) from erp.fact_shipment_line s
      where s.customer_key = 'MIDW USA'
        and s.ship_date between date '2025-01-01' and date '2025-12-31'),
  'shipped_revenue unchanged on the headers');

select pg_temp.assert(
  (select count(*) from public.v_account_shipment_lines
    where ship_date = current_date and shipped_value is null) = 0,
  'no line shipped today has a null shipped_value ('
    || (select count(*) from public.v_account_shipment_lines where ship_date = current_date)
    || ' lines today)');

reset role;

-- Only a missing price (or qty) may leave it null, anywhere in the fact.
select pg_temp.assert(
  (select count(*)
     from public.v_account_shipment_lines l
     join erp.fact_shipment_line s using (packlist_id, line_num)
    where l.shipped_value is null
      and s.unit_price is not null and s.shipped_qty is not null) = 0,
  'shipped_value is null only where the ERP line has no price or qty');

--------------------------------------------------------------------------
-- 3. Fixtures: the formula, the feed, and RLS.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, internal_customer_flag)
values ('SV-A1', 'SV-A1', 'Shipval A One', 'SV REPA', 'Y', 'N'),
       ('SV-B1', 'SV-B1', 'Shipval B One', 'SV REPB', 'Y', 'N');

-- PL-SV1: 2 × $1,000 at 10% off + 1 × $50 no discount (null pct) = $1,850.
-- shipped_revenue deliberately different, to prove it is untouched.
-- ship_date is generated from ship_date_key (erp.key_to_date).
insert into erp.fact_shipment_line (packlist_id, line_num, order_id, order_line_no,
                                    customer_key, ship_date_key, shipped_qty, unit_price,
                                    trade_discount_pct, shipped_revenue, tracking_number)
values ('PL-SV1', 1, 'SV-O1', 1, 'SV-A1', to_char(current_date - 1, 'YYYYMMDD')::int, 2, 1000, 10,   1700, '1ZSV0001'),
       ('PL-SV1', 2, 'SV-O1', 2, 'SV-A1', to_char(current_date - 1, 'YYYYMMDD')::int, 1,   50, null,   50, null),
       ('PL-SV2', 1, 'SV-O2', 1, 'SV-B1', to_char(current_date - 1, 'YYYYMMDD')::int, 4,  100, 0,     400, null);

insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key,
                                 bookings, is_backlog_line, order_status, customer_po_number)
values ('SV-O1', 1, 'SV-A1', to_char(current_date - 3, 'YYYYMMDD')::int, 1800, false, 'R', 'PO-SV-1'),
       ('SV-O1', 2, 'SV-A1', to_char(current_date - 3, 'YYYYMMDD')::int,   50, false, 'R', 'PO-SV-1');

select pg_temp.become('rep');

select pg_temp.assert(
  (select array_agg(line_num || ':' || shipped_value::numeric(12,2) || ':'
                    || shipped_revenue::numeric(12,2) order by line_num)
     from public.v_account_shipment_lines where packlist_id = 'PL-SV1')
  = array['1:1800.00:1700.00', '2:50.00:50.00'],
  'line value = qty × price × (100 - pct)/100, null pct = no discount; shipped_revenue as landed');

select pg_temp.assert(
  (select shipped_value = 1850 and shipped_revenue = 1750 and rn = 1
     from public.v_account_recent_shipment_headers where packlist_id = 'PL-SV1'),
  'header shipped_value is the sum of its lines; shipped_revenue and rn unchanged');

select pg_temp.assert(
  (select kind = 'shipped' and amount = 1750 and shipped_value = 1850
          and customer_po_number = 'PO-SV-1'
     from public.v_territory_recent_events where packlist_id = 'PL-SV1'),
  'feed: a shipped row carries shipped_value beside its unchanged amount');

select pg_temp.assert(
  (select count(*) from public.v_territory_recent_events
    where customer_key like 'SV-%' and kind <> 'shipped' and shipped_value is not null) = 0
  and exists (select 1 from public.v_territory_recent_events
               where order_id = 'SV-O1' and kind = 'order_new' and shipped_value is null),
  'feed: shipped_value is null on every other kind (order_new here)');

select pg_temp.assert(
  (select count(*) from public.v_account_shipment_lines where packlist_id = 'PL-SV2') = 0
  and (select count(*) from public.v_territory_recent_events where packlist_id = 'PL-SV2') = 0,
  'another rep''s packlist stays invisible');

reset role;

do $$ begin raise notice 'ALL SHIPPED VALUE TESTS PASSED'; end $$;

rollback;
