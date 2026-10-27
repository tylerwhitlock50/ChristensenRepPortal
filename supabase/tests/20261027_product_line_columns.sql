/*============================================================================
  20261027_product_line_columns.sql — assertions for
    20261027090500_product_line_columns.sql
      v_backlog_by_sku.product_code         appended
      v_territory_sku_sales.product_code    appended
      v_sku_sales_by_account.product_code   appended

  Runs in a transaction and ROLLS BACK; writes throwaway users and ERP rows.
  Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_product_line_columns.sql

  A clean run prints "ALL PRODUCT LINE COLUMN TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep', 'aaaaaaaa-9696-4696-8696-969696969696');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@prodline.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'PL REPA'
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

create or replace function pg_temp.cols(p_view text) returns text[]
language sql as $$
  select array_agg(column_name::text order by ordinal_position)
  from information_schema.columns
  where table_schema = 'public' and table_name = p_view
$$;

--------------------------------------------------------------------------
-- 1. Shape: every existing column in place, product_code appended.
--------------------------------------------------------------------------
select pg_temp.assert(
  pg_temp.cols('v_backlog_by_sku')
  = array['customer_key', 'customer_id', 'customer_name', 'part_key', 'part_id',
          'part_description', 'product_family', 'chambering', 'backlog_qty',
          'backlog_amount', 'open_line_count', 'earliest_promise_date',
          'earliest_desired_ship_date', 'latest_order_date', 'product_code'],
  'v_backlog_by_sku: product_code appended last');

select pg_temp.assert(
  pg_temp.cols('v_territory_sku_sales')
  = array['part_key', 'part_id', 'part_description', 'product_family', 'chambering', 'upc',
          'sales_year', 'revenue', 'qty', 'invoice_count', 'last_invoice_date',
          'product_code'],
  'v_territory_sku_sales: product_code appended last');

select pg_temp.assert(
  pg_temp.cols('v_sku_sales_by_account')
  = array['customer_key', 'part_key', 'part_id', 'part_description', 'product_family',
          'chambering', 'upc', 'sales_year', 'revenue', 'qty', 'invoice_count',
          'last_invoice_date', 'product_code'],
  'v_sku_sales_by_account: product_code appended last');

select pg_temp.assert(
  (select bool_and(c.reloptions @> array['security_invoker=true']
                   and has_table_privilege('authenticated', c.oid, 'select')
                   and not has_table_privilege('anon', c.oid, 'select'))
     from pg_class c
    where c.oid in ('public.v_backlog_by_sku'::regclass,
                    'public.v_territory_sku_sales'::regclass,
                    'public.v_sku_sales_by_account'::regclass)),
  'all three still security_invoker, authenticated-only');

--------------------------------------------------------------------------
-- 2. Live data, whole company (owner bypasses RLS): no group split, and
--    the value is dim_part's.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.v_backlog_by_sku)
  = (select count(*) from (select distinct o.customer_key, o.part_key
                             from erp.fact_order_line o
                             join erp.dim_customer c on c.customer_key = o.customer_key
                            where o.is_backlog_line) x),
  'v_backlog_by_sku: one row per (account, part) as before ('
    || (select count(*) from public.v_backlog_by_sku) || ')');

select pg_temp.assert(
  (select count(*) from public.v_territory_sku_sales)
  = (select count(*) from (select distinct s.part_key, s.sales_year
                             from erp.agg_sku_year s
                             join erp.dim_customer c on c.customer_key = s.customer_key
                            where c.active_flag = 'Y'
                              and coalesce(c.internal_customer_flag, 'N') <> 'Y') x),
  'v_territory_sku_sales: one row per (part, year) as before');

select pg_temp.assert(
  (select count(*) from public.v_sku_sales_by_account)
  = (select count(*) from erp.agg_sku_year),
  'v_sku_sales_by_account: one row per rollup row as before');

select pg_temp.assert(
  (select count(*) from public.v_backlog_by_sku v
     left join erp.dim_part p on p.part_key = v.part_key
    where v.product_code is distinct from p.product_code) = 0
  and (select count(*) from public.v_territory_sku_sales v
     left join erp.dim_part p on p.part_key = v.part_key
    where v.product_code is distinct from p.product_code) = 0
  and (select count(*) from public.v_sku_sales_by_account v
     left join erp.dim_part p on p.part_key = v.part_key
    where v.product_code is distinct from p.product_code) = 0,
  'product_code equals dim_part.product_code on every row of all three');

--------------------------------------------------------------------------
-- 3. A rep reads it through RLS.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, internal_customer_flag)
values ('PL-A1', 'PL-A1', 'Prodline A One', 'PL REPA', 'Y', 'N'),
       ('PL-B1', 'PL-B1', 'Prodline B One', 'PL REPB', 'Y', 'N');

insert into erp.dim_part (part_key, part_id, part_description, product_code, product_family)
values ('PL-FFT', 'PL-FFT', 'Ridgeline FFT test', 'RIDGELINE FFT', 'Ridgeline');

insert into erp.fact_order_line (order_id, line_num, customer_key, part_key, order_date_key,
                                 backlog_qty, backlog_amount, is_backlog_line, order_status)
values ('PL-O1', 1, 'PL-A1', 'PL-FFT', to_char(current_date - 5, 'YYYYMMDD')::int, 2, 3000, true, 'R'),
       ('PL-O2', 1, 'PL-B1', 'PL-FFT', to_char(current_date - 5, 'YYYYMMDD')::int, 9, 9000, true, 'R');

insert into erp.agg_sku_year (customer_key, part_key, sales_year, revenue, qty, invoice_count,
                              last_invoice_date)
values ('PL-A1', 'PL-FFT', extract(year from current_date)::int, 5000, 3, 1, current_date - 9),
       ('PL-B1', 'PL-FFT', extract(year from current_date)::int, 7000, 4, 1, current_date - 9);

select pg_temp.become('rep');

select pg_temp.assert(
  (select array_agg(customer_key || ':' || product_code || ':' || backlog_amount::int)
     from public.v_backlog_by_sku where part_key = 'PL-FFT')
  = array['PL-A1:RIDGELINE FFT:3000'],
  'v_backlog_by_sku: the rep''s line, with its product line; the other rep''s is hidden');

select pg_temp.assert(
  (select array_agg(product_code || ':' || revenue::int)
     from public.v_territory_sku_sales where part_key = 'PL-FFT')
  = array['RIDGELINE FFT:5000'],
  'v_territory_sku_sales: product line on the rep''s own totals');

select pg_temp.assert(
  (select array_agg(customer_key || ':' || product_code)
     from public.v_sku_sales_by_account where part_key = 'PL-FFT')
  = array['PL-A1:RIDGELINE FFT'],
  'v_sku_sales_by_account: product line, rep-scoped');

reset role;

do $$ begin raise notice 'ALL PRODUCT LINE COLUMN TESTS PASSED'; end $$;

rollback;
