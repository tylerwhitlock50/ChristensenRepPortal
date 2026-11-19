/*============================================================================
  20261119_open_order_lines_chambering.sql — assertions for
    20261119130000_open_order_lines_chambering.sql
      v_open_order_lines.chambering   appended

  Also pins the invariant the merged Open orders tab leans on: the open
  lines, added up by (account, SKU), are v_backlog_by_sku row for row — so
  the tab's "By SKU" cut (built in the browser from the lines) shows what the
  old Backlog tab showed.

  Runs in a transaction and ROLLS BACK; writes throwaway users and ERP rows.
  Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261119_open_order_lines_chambering.sql

  A clean run prints "ALL OPEN ORDER LINE CHAMBERING TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep', 'aaaaaaaa-9b9b-4b9b-8b9b-9b9b9b9b9b9b');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@oolchamber.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'OC REPA'
  where user_id = (select id from t_user where label = 'rep');

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
-- 1. Shape: the 30 columns of 20261027090600 in place, chambering appended.
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
          'is_non_part', 'is_past_want', 'is_past_promise', 'chambering'],
  'v_open_order_lines: chambering appended last, the 30 earlier columns unmoved');

select pg_temp.assert(
  (select reloptions from pg_class where oid = 'public.v_open_order_lines'::regclass)
    @> array['security_invoker=true']
  and has_table_privilege('authenticated', 'public.v_open_order_lines', 'select')
  and not has_table_privilege('anon', 'public.v_open_order_lines', 'select'),
  'v_open_order_lines: still security_invoker, authenticated-only');

--------------------------------------------------------------------------
-- 2. Live data, whole company (owner bypasses RLS).
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.v_open_order_lines)
  = (select count(*) from erp.fact_order_line where is_backlog_line),
  'still one view row per open line ('
    || (select count(*) from public.v_open_order_lines) || ')');

select pg_temp.assert(
  (select count(*) from public.v_open_order_lines v
     left join erp.dim_part p on p.part_key = v.part_key
    where v.chambering is distinct from p.chambering) = 0,
  'chambering equals dim_part.chambering on every line');

-- The lines added up by (account, SKU) are v_backlog_by_sku. That view
-- inner-joins the customer, so a line with no dim_customer row is left out
-- of the comparison (the list keeps it; RLS never shows a rep one).
select pg_temp.assert(
  (select count(*)
     from (select l.customer_key, coalesce(l.part_key, '') as part_key,
                  sum(l.backlog_qty) as qty, sum(l.backlog_amount) as amount,
                  count(*) as line_count
             from public.v_open_order_lines l
            where exists (select 1 from erp.dim_customer c
                           where c.customer_key = l.customer_key)
            group by 1, 2) l
     full join (select customer_key, coalesce(part_key, '') as part_key,
                       backlog_qty, backlog_amount, open_line_count
                  from public.v_backlog_by_sku) b
       using (customer_key, part_key)
    where l.qty is distinct from b.backlog_qty
       or l.amount is distinct from b.backlog_amount
       or l.line_count is distinct from b.open_line_count) = 0,
  'the open lines summed by (account, SKU) equal v_backlog_by_sku: qty, value '
  'and line count, no row missing on either side ('
    || (select count(*) from public.v_backlog_by_sku) || ' rows)');

--------------------------------------------------------------------------
-- 3. A rep reads it through RLS.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, internal_customer_flag)
values ('OC-A1', 'OC-A1', 'Chamber A One', 'OC REPA', 'Y', 'N'),
       ('OC-B1', 'OC-B1', 'Chamber B One', 'OC REPB', 'Y', 'N');

insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family,
                          chambering)
values ('OC-PRC', 'OC-PRC', 'Ridgeline FFT 6.5 PRC test', 'RIDGELINE FFT', 'Ridgeline', '6.5 PRC'),
       ('OC-ACC', 'OC-ACC', 'Bipod test', 'ACCESSORY', 'Accessories', null);

insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, order_date_key,
                                 backlog_qty, backlog_amount, is_backlog_line, order_status)
values ('OC-O1', 1, 'OC-A1', 'OC-PRC', to_char(current_date - 5, 'YYYYMMDD')::int, 2, 3000, true, 'R'),
       ('OC-O1', 2, 'OC-A1', 'OC-ACC', to_char(current_date - 5, 'YYYYMMDD')::int, 1,  100, true, 'R'),
       ('OC-O2', 1, 'OC-A1', 'OC-PRC', to_char(current_date - 2, 'YYYYMMDD')::int, 1, 1500, true, 'F'),
       ('OC-O9', 1, 'OC-B1', 'OC-PRC', to_char(current_date - 5, 'YYYYMMDD')::int, 9, 9000, true, 'R');

select pg_temp.become('rep');

select pg_temp.assert(
  (select array_agg(order_id || '/' || line_num || ':' || coalesce(chambering, '(none)')
                    order by order_id, line_num)
     from public.v_open_order_lines where customer_key like 'OC-%')
  = array['OC-O1/1:6.5 PRC', 'OC-O1/2:(none)', 'OC-O2/1:6.5 PRC'],
  'the rep''s three lines carry the part''s chambering (null where the part has none); '
  'the other rep''s line is hidden');

select pg_temp.assert(
  (select (sum(backlog_qty), sum(backlog_amount), count(*))::text
     from public.v_open_order_lines
    where customer_key = 'OC-A1' and part_key = 'OC-PRC')
  = (select (backlog_qty, backlog_amount, open_line_count::bigint)::text
       from public.v_backlog_by_sku
      where customer_key = 'OC-A1' and part_key = 'OC-PRC'),
  'one SKU open on two orders: the lines add up to its v_backlog_by_sku row');

reset role;

do $$ begin raise notice 'ALL OPEN ORDER LINE CHAMBERING TESTS PASSED'; end $$;

rollback;
