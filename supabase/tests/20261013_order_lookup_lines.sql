/*============================================================================
  20261013_order_lookup_lines.sql — per-line tracking on
  v_account_order_lines (20261013150000), the lookup's trigram indexes
  (20261013150001), and the lock-free rollup refresh + post-load ANALYZE
  (20261013150002).

  Runs in a transaction and ROLLS BACK; creates throwaway auth users and ERP
  rows. Dev or a local harness only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_order_lookup_lines.sql

  A clean run prints "ALL ORDER LOOKUP LINE TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

-- The production grant on the ANALYZE step (the harness re-grants all).
revoke execute on function public.analyze_territory_rollups() from public, anon, authenticated;

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-1212-4121-8121-121212121212'),
  ('rep_b', 'bbbbbbbb-3434-4343-8343-343434343434');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@lines.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'OLT REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'OLT REPB'
  where user_id = (select id from t_user where label = 'rep_b');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('OLT-A', 'OLT-A', 'Lines Dealer A', 'OLT REPA', 'Y'),
       ('OLT-B', 'OLT-B', 'Lines Dealer B', 'OLT REPB', 'Y');

-- OLT-SO1: line 1 shipped in two parcels, line 2 by freight with only a
-- waybill (and a blank line-level number, which must not win), line 3 not
-- shipped yet.
insert into erp.fact_order_line
  (order_id, line_num, customer_key, customer_po_number, order_date_key,
   promise_date_key, order_qty, bookings, total_shipped_qty_to_date,
   backlog_qty, is_backlog_line)
values
  ('OLT-SO1', 1, 'OLT-A', 'OLT-PO-41', 20260901, 20260920, 4, 4000, 4, 0, false),
  ('OLT-SO1', 2, 'OLT-A', 'OLT-PO-41', 20260901, 20260920, 1, 1000, 1, 0, false),
  ('OLT-SO1', 3, 'OLT-A', 'OLT-PO-41', 20260901, 20261101, 2, 2000, 0, 2, true),
  ('OLT-SO9', 1, 'OLT-B', 'OLT-PO-99', 20260902, 20260921, 1, 1000, 1, 0, false);

insert into erp.fact_shipment_line
  (packlist_id, line_num, order_id, order_line_no, customer_key,
   tracking_number, waybill_number, ship_date_key, shipped_qty, shipped_revenue)
values
  ('OLT-PL2', 1, 'OLT-SO1', 1, 'OLT-A', '1ZOLTBBB', null,      20260912, 2, 2000),
  ('OLT-PL1', 1, 'OLT-SO1', 1, 'OLT-A', '1ZOLTAAA', null,      20260910, 2, 2000),
  ('OLT-PL1', 2, 'OLT-SO1', 1, 'OLT-A', '1ZOLTAAA', null,      20260910, 0, 0),
  ('OLT-PL3', 1, 'OLT-SO1', 2, 'OLT-A', '',         'WB-OLT-7', 20260911, 1, 1000),
  ('OLT-PL9', 1, 'OLT-SO9', 1, 'OLT-B', '1ZOLTZZZ', null,      20260913, 1, 1000);

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
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. v_account_order_lines: append-only, tracking per line.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(attname::text order by attnum) from pg_attribute
    where attrelid = 'public.v_account_order_lines'::regclass and attnum > 0
      and not attisdropped)
  = array['customer_key','order_id','line_num','order_date','promise_date',
          'line_status_desc','part_key','part_id','part_description',
          'order_qty','bookings','backlog_qty','is_backlog_line',
          'customer_po_number','desired_ship_date','total_shipped_qty_to_date',
          'tracking_numbers'],
  'every 035 column in place, tracking_numbers appended last');

select pg_temp.become('rep_a');

select pg_temp.assert(
  (select array_agg(coalesce(tracking_numbers, '∅') order by line_num)
     from public.v_account_order_lines
    where customer_key = 'OLT-A' and order_id = 'OLT-SO1')
  = array['1ZOLTAAA, 1ZOLTBBB', 'WB-OLT-7', '∅'],
  'two parcels: both numbers, once each, sorted; waybill when the line number is blank; null when unshipped');

select pg_temp.assert(
  (select sum(bookings) from public.v_account_order_lines
    where customer_key = 'OLT-A' and order_id = 'OLT-SO1') = 7000,
  'no fan-out: three lines, bookings summed once each despite four shipment lines');

-- The MCP list_orders tool names its columns; it must keep working.
select pg_temp.assert(
  (select count(*) from (
     select order_id, line_num, order_date, promise_date, line_status_desc, part_id,
            part_description, order_qty, bookings, backlog_qty, is_backlog_line
       from public.v_account_order_lines
      where customer_key = 'OLT-A' and order_id = 'OLT-SO1') x) = 3,
  'the MCP''s explicit column list still reads the view');

select pg_temp.assert(
  (select count(*) from public.v_account_order_lines where order_id = 'OLT-SO9') = 0,
  'rep A cannot read rep B''s order lines');

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select tracking_numbers from public.v_account_order_lines
    where customer_key = 'OLT-B' and order_id = 'OLT-SO9') = '1ZOLTZZZ'
  and (select count(*) from public.v_account_order_lines where order_id = 'OLT-SO1') = 0,
  'rep B reads their own line tracking and none of rep A''s lines');

--------------------------------------------------------------------------
-- 2. lookup_orders still finds by any fragment, through the new indexes.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.lookup_orders('OLT-SO')) = 1
  and (select matched_on from public.lookup_orders('LT-PO-4')) = 'po'
  and (select matched_on from public.lookup_orders('OLTBB')) = 'tracking'
  and (select count(*) from public.lookup_orders('OLTZZ')) = 0,
  'lookup_orders: order, PO and tracking fragments, still scoped to the caller');
reset role;

select pg_temp.assert(
  (select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pg_trgm') is not null,
  'pg_trgm is installed');

select pg_temp.assert(
  (select count(*) from pg_index i
     join pg_class c on c.oid = i.indexrelid
     join pg_opclass oc on oc.oid = i.indclass[0]
    where c.relname in ('idx_fol_order_id_trgm', 'idx_fol_po_number_trgm', 'idx_fsl_tracking_trgm')
      and oc.opcname = 'gin_trgm_ops') = 3,
  'the three trigram indexes exist with gin_trgm_ops');

select pg_temp.assert(
  (select pg_get_indexdef('erp.idx_fsl_tracking_trgm'::regclass))
    like '%COALESCE(tracking_number, waybill_number)%',
  'the tracking index is on the function''s exact expression');

-- The planner CAN answer the function's own query from the indexes. EXPLAIN
-- the body of lookup_orders() as written, with the term inlined, over a few
-- thousand filler rows, with sequential scans and whole-index walks priced
-- out (a fixture this small is cheaper to read end to end, which is not the
-- question). At production size the planner picks the trigram indexes
-- unprompted: see the migration header for the measured plan.
insert into erp.dim_customer (customer_key, customer_id, customer_name, active_flag)
values ('OLT-FILL', 'OLT-FILL', 'Filler', 'Y');
insert into erp.fact_order_line
  (order_id, line_num, customer_key, customer_po_number, order_date_key, order_qty, bookings)
select 'FILL' || g, 1, 'OLT-FILL', 'FPO' || g, 20250101 + (g % 28), 1, 1
from generate_series(1, 5000) g;
insert into erp.fact_shipment_line
  (packlist_id, line_num, order_id, order_line_no, customer_key, tracking_number, ship_date_key)
select 'FPL' || g, 1, 'FILL' || g, 1, 'OLT-FILL', '1ZFILL' || g, 20250101 + (g % 28)
from generate_series(1, 5000) g;
analyze erp.fact_order_line;
analyze erp.fact_shipment_line;
-- Freshly inserted rows sit in GIN's fast-update pending list, which the
-- planner prices as a full read on every probe (the nightly load leaves up
-- to 4 MB there until autovacuum flushes it). Flush it, as autovacuum would.
select count(gin_clean_pending_list(c.oid)) from pg_class c
 where c.relname in ('idx_fol_order_id_trgm', 'idx_fol_po_number_trgm', 'idx_fsl_tracking_trgm');
set local enable_seqscan = off;
set local enable_indexscan = off;
set local enable_indexonlyscan = off;
do $$
declare
  q    text;
  plan text := '';
  r    record;
begin
  select prosrc into q from pg_proc
   where oid = 'public.lookup_orders(text, int)'::regprocedure;
  q := replace(replace(q, 'p_term', quote_literal('OLTB')), 'p_limit', '25');
  q := rtrim(btrim(q), ';');
  for r in execute 'explain ' || q loop
    plan := plan || r."QUERY PLAN" || E'\n';
  end loop;
  if plan not like '%idx_fol_order_id_trgm%'
     or plan not like '%idx_fol_po_number_trgm%'
     or plan not like '%idx_fsl_tracking_trgm%' then
    raise exception 'FAILED: lookup_orders() plan does not use the trigram indexes:%', E'\n' || plan;
  end if;
  raise notice 'ok  lookup_orders() can use all three trigram indexes';
end $$;
reset enable_seqscan;
reset enable_indexscan;
reset enable_indexonlyscan;

--------------------------------------------------------------------------
-- 3. The rollup refresh holds no ACCESS EXCLUSIVE lock, and ANALYZE runs
--    inside a transaction, the way the loader calls it.
--------------------------------------------------------------------------
select count(*) from public.refresh_territory_rollups();

select pg_temp.assert(
  not exists (
    select 1 from pg_locks l
      join pg_class c on c.oid = l.relation
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'erp' and c.relname like 'agg\_%'
       and l.pid = pg_backend_pid()
       and l.mode = 'AccessExclusiveLock'),
  'refresh_territory_rollups() takes no ACCESS EXCLUSIVE lock on any rollup');

select pg_temp.assert(
  (select count(distinct c.relname) from pg_locks l
     join pg_class c on c.oid = l.relation
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'erp' and c.relkind = 'r' and c.relname like 'agg\_%'
      and l.pid = pg_backend_pid()
      and l.mode = 'RowExclusiveLock') = 4,
  'it clears all four rollups under ROW EXCLUSIVE (readers keep reading)');

-- Twice in one transaction: the second run clears what the first wrote.
select pg_temp.assert(
  (select array_agg(row_count order by rollup_name) from public.refresh_territory_rollups())
  = (select array_agg(row_count order by rollup_name) from public.refresh_territory_rollups()),
  'a rerun rebuilds the same rows (DELETE clears, nothing doubles)');

select pg_temp.assert(
  (select array_agg(rollup_name) from public.analyze_territory_rollups())
  = array['agg_account_rollup', 'agg_sku_year', 'agg_customer_month', 'agg_sku_month'],
  'analyze_territory_rollups() runs inside a transaction and names all four');

select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.analyze_territory_rollups()', 'execute')
  and not has_function_privilege('anon', 'public.analyze_territory_rollups()', 'execute'),
  'the ANALYZE step is job-only');

select pg_temp.assert(
  (select proconfig @> array['TimeZone=America/Denver'] from pg_proc
    where oid = 'public.refresh_territory_rollups()'::regprocedure),
  'the restated refresh kept its Mountain-time pin');

do $$ begin raise notice 'ALL ORDER LOOKUP LINE TESTS PASSED'; end $$;

rollback;
