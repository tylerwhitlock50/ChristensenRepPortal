/*============================================================================
  20261027_book_lists.sql — assertions for 20261027090600_book_lists.sql
      v_open_order_lines        every open line in the book, with flags
      report_book_shipments()   shipment lines in a window, PO + invoice
      idx_fil_invoice_id        the covering index the invoice probe uses

  Runs in a transaction and ROLLS BACK; writes throwaway users and ERP rows.
  Section 3 reads production data: the LUD agency's 2025 shipments through
  a throwaway principal, and Midway USA's open lines. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_book_lists.sql

  A clean run prints "ALL BOOK LIST TESTS PASSED".

  Speed is not asserted here (a guard that fails on a busy afternoon is
  noise); the EXPLAIN ANALYZE timings for the PMI principal, the largest
  single-rep book and an admin are in the build report.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-9797-4797-8797-979797979797'),
  ('rep_b', 'bbbbbbbb-9898-4898-8898-989898989898'),
  ('lud',   'dddddddd-9999-4999-8999-999999999999'),
  ('admin', 'cccccccc-9a9a-4a9a-8a9a-9a9a9a9a9a9a');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@booklists.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'BL REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'BL REPB'
  where user_id = (select id from t_user where label = 'rep_b');
-- A principal over the LUD agency, the shape of the real one.
update public.profiles set rep_group_vendor_id = 'LUDW ASSO'
  where user_id = (select id from t_user where label = 'lud');
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

/* The call must fail with exactly this SQLSTATE. */
create or replace function pg_temp.assert_raises(p_sql text, p_state text, p_what text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      raise notice 'ok  % (%: %)', p_what, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAILED: % — raised % (%), expected %', p_what, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAILED: % — did not raise', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Shape and privileges: the column contracts the frontend codes to.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_open_order_lines')
  = array['customer_key', 'customer_id', 'customer_name', 'customer_reporting_name',
          'assigned_sales_rep_id', 'assigned_sales_rep_name', 'order_id', 'line_num',
          'order_date', 'customer_po_number', 'order_status', 'order_status_desc',
          'desired_ship_date', 'promise_date', 'part_key', 'part_id', 'part_description',
          'product_code', 'product_family', 'upc', 'program_code', 'unit_price',
          'trade_discount_pct', 'backlog_qty', 'backlog_amount', 'credit_status', 'is_rma',
          'is_non_part', 'is_past_want', 'is_past_promise'],
  'v_open_order_lines: the 30 contract columns, in order');

select pg_temp.assert(
  (select array_agg(n order by o)
     from pg_proc p,
          unnest(p.proargnames, p.proargmodes::text[]) with ordinality as a(n, m, o)
    where p.oid = 'public.report_book_shipments(date, date, text)'::regprocedure
      and a.m = 't')
  = array['packlist_id', 'line_num', 'ship_date', 'customer_key', 'customer_name',
          'assigned_sales_rep_name', 'order_id', 'order_line_no', 'customer_po_number',
          'part_id', 'part_description', 'product_code', 'shipped_qty', 'unit_price',
          'trade_discount_pct', 'shipped_value', 'invoice_id', 'invoice_status', 'ship_via',
          'tracking_number', 'ship_to_name', 'ship_to_city', 'ship_to_state'],
  'report_book_shipments: the 23 contract columns, in order');

select pg_temp.assert(
  (select reloptions from pg_class where oid = 'public.v_open_order_lines'::regclass)
    @> array['security_invoker=true']
  and has_table_privilege('authenticated', 'public.v_open_order_lines', 'select')
  and not has_table_privilege('anon', 'public.v_open_order_lines', 'select'),
  'v_open_order_lines: security_invoker, authenticated-only');

select pg_temp.assert(
  (select not prosecdef and provolatile = 's' and proconfig @> array['search_path=""']
     from pg_proc where oid = 'public.report_book_shipments(date, date, text)'::regprocedure)
  and has_function_privilege('authenticated', 'public.report_book_shipments(date, date, text)', 'execute')
  and not has_function_privilege('anon', 'public.report_book_shipments(date, date, text)', 'execute'),
  'report_book_shipments: SECURITY INVOKER, stable, empty search_path, authenticated-only');

select pg_temp.assert(
  (select pg_get_indexdef(i.indexrelid)
     from pg_index i where i.indexrelid = 'erp.idx_fil_invoice_id'::regclass)
  like '%(invoice_id) INCLUDE (invoice_status_desc, customer_key)',
  'idx_fil_invoice_id covers the invoice-status probe and the RLS column');

--------------------------------------------------------------------------
-- 2. The window rules.
--------------------------------------------------------------------------
select pg_temp.become('admin');

select pg_temp.assert_raises(
  'select * from public.report_book_shipments(null, current_date)', '22004',
  'a missing p_from is refused');
select pg_temp.assert_raises(
  'select * from public.report_book_shipments(current_date, null)', '22004',
  'a missing p_to is refused');
select pg_temp.assert_raises(
  'select * from public.report_book_shipments(current_date - 401, current_date)', '22023',
  'a window over 400 days is refused');
select pg_temp.assert_raises(
  'select * from public.report_book_shipments(current_date, current_date - 1)', '22023',
  'p_to before p_from is refused');

select pg_temp.assert(
  (select count(*) >= 0 from public.report_book_shipments(current_date - 400, current_date, 'BL-NONE')),
  'exactly 400 days is allowed');

reset role;

--------------------------------------------------------------------------
-- 3. Production figures.
--------------------------------------------------------------------------
-- LUD agency, 2025: the Tableau "Shipment Details" total the list must tie
-- to. Through the function as a principal over the agency (RLS, invoker).
create temporary table t_lud (qty numeric, value numeric, lines bigint) on commit drop;
grant insert, select on t_lud to authenticated;

select pg_temp.become('lud');
insert into t_lud
select sum(shipped_qty), sum(shipped_value), count(*)
from public.report_book_shipments(date '2025-01-01', date '2025-12-31');
reset role;

select pg_temp.assert(
  (select qty = 8164 and abs(value - 5956062.34) <= 0.01 from t_lud),
  'LUD agency 2025 via report_book_shipments: 8,164 units / $5,956,062.34 ('
    || (select lines from t_lud) || ' lines)');

-- Midway USA's open lines: the view drops none and doubles none.
create temporary table t_mid (n bigint, amt numeric) on commit drop;
grant insert, select on t_mid to authenticated;

select pg_temp.become('admin');
insert into t_mid
select count(*), sum(backlog_amount) from public.v_open_order_lines where customer_key = 'MIDW USA';
reset role;

select pg_temp.assert(
  (select (n, amt) from t_mid)
  = (select (count(*), sum(backlog_amount)) from erp.fact_order_line
      where customer_key = 'MIDW USA' and is_backlog_line),
  'Midway USA: v_open_order_lines has every is_backlog_line line ('
    || (select n from t_mid) || ') and its value');

select pg_temp.assert(
  (select count(*) from public.v_open_order_lines)
  = (select count(*) from erp.fact_order_line where is_backlog_line),
  'company-wide: one view row per open line (left joins drop and double nothing)');

--------------------------------------------------------------------------
-- 4. Fixtures: flags, lookups, RLS.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name, customer_reporting_name,
                              assigned_sales_rep_id, assigned_sales_rep_name, active_flag,
                              internal_customer_flag, credit_status)
values ('BL-A1', 'BL-A1', 'Booklist A One', 'Booklist A', 'BL REPA', 'Rep A', 'Y', 'N', 'APPROVED'),
       ('BL-B1', 'BL-B1', 'Booklist B One', 'Booklist B', 'BL REPB', 'Rep B', 'Y', 'N', 'HOLD');

insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family, upc)
values ('BL-MESA', 'BL-MESA', 'Mesa FFT test', 'MESA FFT', 'Mesa', '000000000017');

insert into erp.dim_ship_to (ship_to_key, customer_id, ship_to_name, city, state)
values ('BL-A1|1', 'BL-A1', 'Booklist A Warehouse', 'Gunnison', 'UT');

-- Open lines for A (one closed line that must not show), one for B.
--   O1/1 Mesa, program MDF, want date past, promise in the future
--   O1/2 the (Unknown) non-part line: a discount, negative value
--   O2/1 PO says RMA;  O3/1 a WARRANTY program line;  O5/1 no promise date
insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, product_code,
                                 customer_po_number, order_status, order_status_desc,
                                 order_date_key, desired_ship_date_key, promise_date_key,
                                 unit_price, trade_discount_pct, backlog_qty, backlog_amount,
                                 is_backlog_line)
values ('BL-O1', 1, 'BL-A1', 'BL-MESA',   'MDF',      'PO-BL-1',  'R', 'Released',
        to_char(current_date - 30, 'YYYYMMDD')::int, to_char(current_date - 3, 'YYYYMMDD')::int,
        to_char(current_date + 9, 'YYYYMMDD')::int, 2000, 10, 2, 3600, true),
       ('BL-O1', 2, 'BL-A1', '(Unknown)', null,       'PO-BL-1',  'R', 'Released',
        to_char(current_date - 30, 'YYYYMMDD')::int, to_char(current_date - 3, 'YYYYMMDD')::int,
        to_char(current_date + 9, 'YYYYMMDD')::int, -50, 0, 1, -50, true),
       ('BL-O2', 1, 'BL-A1', 'BL-MESA',   'MESA FFT', 'RMA 7781', 'F', 'Firmed',
        to_char(current_date - 20, 'YYYYMMDD')::int, to_char(current_date + 5, 'YYYYMMDD')::int,
        to_char(current_date - 1, 'YYYYMMDD')::int, 2000, 0, 1, 2000, true),
       ('BL-O3', 1, 'BL-A1', 'BL-MESA',   'WARRANTY', 'PO-BL-3',  'H', 'Hold',
        to_char(current_date - 10, 'YYYYMMDD')::int, to_char(current_date + 5, 'YYYYMMDD')::int,
        to_char(current_date + 5, 'YYYYMMDD')::int, 0, 0, 1, 0, true),
       ('BL-O4', 1, 'BL-A1', 'BL-MESA',   'MESA FFT', 'PO-BL-4',  'C', 'Closed',
        to_char(current_date - 90, 'YYYYMMDD')::int, null, null, 2000, 0, 0, 0, false),
       ('BL-O5', 1, 'BL-A1', 'BL-MESA',   'MESA FFT', '',         'R', 'Released',
        to_char(current_date - 5, 'YYYYMMDD')::int, to_char(current_date + 20, 'YYYYMMDD')::int,
        null, 2000, 0, 1, 2000, true),
       ('BL-O9', 1, 'BL-B1', 'BL-MESA',   'MESA FFT', 'PO-BL-9',  'R', 'Released',
        to_char(current_date - 5, 'YYYYMMDD')::int, to_char(current_date + 20, 'YYYYMMDD')::int,
        to_char(current_date + 20, 'YYYYMMDD')::int, 2000, 0, 1, 2000, true);

-- Shipments: PL1 (two lines of O1, invoiced, line 2 has only a waybill),
-- PL3 for A but 500 days ago (outside any window), PL9 for B.
insert into erp.fact_shipment_line (packlist_id, line_num, order_id, order_line_no, customer_key,
                                    part_key, ship_to_key, ship_date_key, shipped_qty, unit_price,
                                    trade_discount_pct, shipped_revenue, invoice_id, ship_via,
                                    tracking_number, waybill_number)
values ('BL-PL1', 1, 'BL-O1', 1, 'BL-A1', 'BL-MESA',   'BL-A1|1',
        to_char(current_date - 2, 'YYYYMMDD')::int, 1, 2000, 10, 1800, 'BL-INV1', 'UPS GROUND', '1ZBL0001', 'WB-1'),
       ('BL-PL1', 2, 'BL-O1', 2, 'BL-A1', '(Unknown)', 'BL-A1|1',
        to_char(current_date - 2, 'YYYYMMDD')::int, 1, -50, null, -50, 'BL-INV1', 'UPS GROUND', null, 'WB-1'),
       ('BL-PL3', 1, 'BL-O1', 1, 'BL-A1', 'BL-MESA',   'BL-A1|1',
        to_char(current_date - 500, 'YYYYMMDD')::int, 1, 2000, 0, 2000, null, null, null, null),
       ('BL-PL9', 1, 'BL-O9', 1, 'BL-B1', 'BL-MESA',   null,
        to_char(current_date - 2, 'YYYYMMDD')::int, 3, 2000, 0, 6000, 'BL-INV9', null, null, null);

insert into erp.fact_invoice_line (invoice_entity_id, invoice_id, invoice_line_no, customer_key,
                                   invoice_status, invoice_status_desc, invoice_date_key)
values ('BL', 'BL-INV1', 1, 'BL-A1', 'OPEN',   'Open',   to_char(current_date - 1, 'YYYYMMDD')::int),
       ('BL', 'BL-INV1', 2, 'BL-A1', 'OPEN',   'Open',   to_char(current_date - 1, 'YYYYMMDD')::int),
       ('BL', 'BL-INV9', 1, 'BL-B1', 'CLOSED', 'Closed', to_char(current_date - 1, 'YYYYMMDD')::int);

select pg_temp.become('rep_a');

-- v_open_order_lines --------------------------------------------------
select pg_temp.assert(
  (select array_agg(order_id || '/' || line_num order by order_id, line_num)
     from public.v_open_order_lines where customer_key like 'BL-%')
  = array['BL-O1/1', 'BL-O1/2', 'BL-O2/1', 'BL-O3/1', 'BL-O5/1'],
  'open lines: rep A''s five open lines; the closed line and rep B''s line are not listed');

select pg_temp.assert(
  (select customer_id = 'BL-A1' and customer_name = 'Booklist A One'
          and customer_reporting_name = 'Booklist A' and assigned_sales_rep_id = 'BL REPA'
          and assigned_sales_rep_name = 'Rep A' and customer_po_number = 'PO-BL-1'
          and order_status = 'R' and order_status_desc = 'Released'
          and order_date = current_date - 30 and desired_ship_date = current_date - 3
          and promise_date = current_date + 9 and part_id = 'BL-MESA'
          and part_description = 'Mesa FFT test' and product_code = 'MESA FFT'
          and product_family = 'Mesa' and upc = '000000000017' and program_code = 'MDF'
          and unit_price = 2000 and trade_discount_pct = 10 and backlog_qty = 2
          and backlog_amount = 3600 and credit_status = 'APPROVED'
          and not is_rma and not is_non_part and is_past_want and not is_past_promise
     from public.v_open_order_lines where order_id = 'BL-O1' and line_num = 1),
  'open line columns: product line from the part, program from the order line, '
  'want date past / promise not');

select pg_temp.assert(
  (select array_agg(order_id || '/' || line_num || ':' || is_rma || ',' || is_non_part
                    || ',' || is_past_promise order by order_id, line_num)
     from public.v_open_order_lines where customer_key like 'BL-%')
  = array['BL-O1/1:false,false,false', 'BL-O1/2:false,true,false',
          'BL-O2/1:true,false,true', 'BL-O3/1:true,false,false',
          'BL-O5/1:false,false,false'],
  'flags: (Unknown) part = non-part; RMA in the PO or a WARRANTY line = RMA; '
  'a null promise date is not past');

select pg_temp.assert(
  (select customer_po_number is null from public.v_open_order_lines where order_id = 'BL-O5'),
  'a blank PO reads as null');

-- report_book_shipments ------------------------------------------------
select pg_temp.assert(
  (select array_agg(packlist_id || '/' || line_num)
     from public.report_book_shipments(current_date - 30, current_date)
    where packlist_id like 'BL-%')
  = array['BL-PL1/1', 'BL-PL1/2'],
  'shipments: rep A''s packlist in the window, in line order; the 500-day-old one '
  'and rep B''s are not returned');

select pg_temp.assert(
  (select ship_date = current_date - 2 and customer_key = 'BL-A1'
          and customer_name = 'Booklist A One' and assigned_sales_rep_name = 'Rep A'
          and order_id = 'BL-O1' and order_line_no = 1 and customer_po_number = 'PO-BL-1'
          and part_id = 'BL-MESA' and part_description = 'Mesa FFT test'
          and product_code = 'MESA FFT' and shipped_qty = 1 and unit_price = 2000
          and trade_discount_pct = 10 and shipped_value = 1800
          and invoice_id = 'BL-INV1' and invoice_status = 'Open' and ship_via = 'UPS GROUND'
          and tracking_number = '1ZBL0001' and ship_to_name = 'Booklist A Warehouse'
          and ship_to_city = 'Gunnison' and ship_to_state = 'UT'
     from public.report_book_shipments(current_date - 30, current_date)
    where packlist_id = 'BL-PL1' and line_num = 1),
  'shipment columns: PO from the order, invoice status, packlist value, ship-to');

select pg_temp.assert(
  (select tracking_number = 'WB-1' and shipped_value = -50 and customer_po_number = 'PO-BL-1'
     from public.report_book_shipments(current_date - 30, current_date)
    where packlist_id = 'BL-PL1' and line_num = 2),
  'tracking falls back to the waybill; a credit line''s value is negative');

select pg_temp.assert(
  (select count(*) from public.report_book_shipments(current_date - 30, current_date, 'BL-A1')) = 2
  and (select count(*) from public.report_book_shipments(current_date - 30, current_date, 'BL-B1')) = 0,
  'p_customer_key: one account; another rep''s account returns nothing (RLS, not an error)');

select pg_temp.assert(
  (select count(*) from public.report_book_shipments(current_date - 600, current_date - 200)
    where packlist_id = 'BL-PL3') = 1,
  'an older window finds the older packlist');

select pg_temp.become('admin');

select pg_temp.assert(
  (select array_agg(packlist_id || ':' || invoice_status || ':' || shipped_value::int
                    order by packlist_id)
     from public.report_book_shipments(current_date - 30, current_date, 'BL-B1'))
  = array['BL-PL9:Closed:6000'],
  'an admin reads any account');

-- The admin arm (no p_customer_key): the whole company's window, and the
-- rep arm stays shut, so no line comes back twice.
select pg_temp.assert(
  (select array_agg(packlist_id || '/' || line_num order by packlist_id, line_num)
     from public.report_book_shipments(current_date - 30, current_date)
    where packlist_id like 'BL-%')
  = array['BL-PL1/1', 'BL-PL1/2', 'BL-PL9/1'],
  'an admin with no account gets every rep''s lines in the window, each once');

select public.start_impersonation((select id from t_user where label = 'rep_a'));
select pg_temp.assert(
  (select count(*) from public.report_book_shipments(current_date - 30, current_date)
    where packlist_id like 'BL-%') = 2
  and (select count(*) from public.v_open_order_lines where customer_key like 'BL-%') = 5,
  'an admin viewing as rep A gets rep A''s lists (view-as through RLS)');
select public.stop_impersonation();

reset role;

do $$ begin raise notice 'ALL BOOK LIST TESTS PASSED'; end $$;

rollback;
