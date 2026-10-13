/*============================================================================
  20261013_territory_brief_facts.sql — assertions for
    20261013160000_territory_brief_facts.sql
      report_territory_brief_facts()     rollup date, bookings, new accounts,
                                         the whole 14-day order count/value
      report_territory_product_mix()     families and SKUs, same months of
                                         two years

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_territory_brief_facts.sql

  A clean run prints "ALL TERRITORY BRIEF FACT TESTS PASSED".

  Both functions are SECURITY INVOKER, so RLS on the rollups is the only
  thing scoping them; the isolation tests below are that scope.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-8181-4181-8181-818181818181'),
  ('rep_b', 'bbbbbbbb-8282-4282-8282-828282828282'),
  ('admin', 'cccccccc-8383-4383-8383-838383838383');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@tbfacts.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'TB REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'TB REPB'
  where user_id = (select id from t_user where label = 'rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

-- Rep A: two active accounts, one inactive, one internal (the last two are
-- outside the territory definition and must not count).
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag,
                              internal_customer_flag, customer_reporting_group)
values ('TB-A1',  'TB-A1',  'Brief A One',     'TB REPA', 'Y', 'N', 'Dealer'),
       ('TB-A2',  'TB-A2',  'Brief A Two',     'TB REPA', 'Y', 'N', '  '),
       ('TB-A3',  'TB-A3',  'Brief A Closed',  'TB REPA', 'N', 'N', null),
       ('TB-INT', 'TB-INT', 'Brief A Internal','TB REPA', 'Y', 'Y', 'Internal'),
       ('TB-B1',  'TB-B1',  'Brief B One',     'TB REPB', 'Y', 'N', 'Special Programs');

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
-- 1. report_territory_brief_facts()
--------------------------------------------------------------------------
-- A rollup refreshed ten days ago (the 2026-10-13 incident's shape). The
-- refresh writes one now() for every row; B's row carries the same stamp.
-- A1 is new this year ($50k, nothing last year); A2 is long-standing.
insert into erp.agg_account_rollup
  (customer_key, revenue_ytd, revenue_prior_ytd, bookings_ytd, bookings_prior_ytd,
   first_invoice_date, refreshed_at)
values
  ('TB-A1',  50000,     0, 10000, 8000, date_trunc('year', (now() - interval '10 days')::date)::date, now() - interval '10 days'),
  ('TB-A2',  20000, 30000,  5000, 9000, '2019-05-01',                                                 now() - interval '10 days'),
  ('TB-A3',  99000, 99000, 70000, 1000, date_trunc('year', (now() - interval '10 days')::date)::date, now() - interval '10 days'),
  ('TB-INT', 99000, 99000, 90000, 1000, date_trunc('year', (now() - interval '10 days')::date)::date, now() - interval '10 days'),
  ('TB-B1',   7000,  6000,  3000, 3000, date_trunc('year', (now() - interval '10 days')::date)::date, now() - interval '10 days');

-- Orders: two inside the 14-day window for A (one of them two lines), one
-- for A that is too old, one CANCELLED $500k order for A (status X), one
-- for the inactive A3, one for B.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key,
                                 bookings, is_backlog_line, order_status)
values ('TB-O1', 1, 'TB-A1', to_char(current_date - 2,  'YYYYMMDD')::int,   1200, true,  'R'),
       ('TB-O1', 2, 'TB-A1', to_char(current_date - 2,  'YYYYMMDD')::int,    300, false, 'R'),
       ('TB-O2', 1, 'TB-A2', to_char(current_date - 13, 'YYYYMMDD')::int,    500, false, null),
       ('TB-O3', 1, 'TB-A1', to_char(current_date - 30, 'YYYYMMDD')::int,   9999, false, 'R'),
       ('TB-OX', 1, 'TB-A1', to_char(current_date - 1,  'YYYYMMDD')::int, 500000, true,  'X'),
       ('TB-O4', 1, 'TB-A3', to_char(current_date - 1,  'YYYYMMDD')::int,   7777, false, 'R'),
       ('TB-O5', 1, 'TB-B1', to_char(current_date - 1,  'YYYYMMDD')::int,    640, false, 'R');

select pg_temp.become('rep_a');

select pg_temp.assert(
  (select (bookings_ytd, bookings_prior_ytd)::text
     from public.report_territory_brief_facts()) = '(15000,17000)',
  'rep A: bookings sum the active external accounts only (inactive and internal left out)');

select pg_temp.assert(
  (select (new_accounts_ytd, new_accounts_revenue_ytd)::text
     from public.report_territory_brief_facts()) = '(1,50000)',
  'rep A: one account whose first invoice ever is in the rollup''s year (A1), with its revenue; '
  'A3/internal not counted');

select pg_temp.assert(
  (select accounts_with_revenue_prior_ytd from public.report_territory_brief_facts()) = 1,
  'rep A: one account bought in last year''s window (A2) — the base to compare buyers with');

select pg_temp.assert(
  (select (orders_14d_count, orders_14d_amount)::text
     from public.report_territory_brief_facts()) = '(2,2000)',
  'rep A: ALL orders in the last 14 days are counted and totalled (two orders, $2,000), '
  'not a 15-row excerpt; the 30-day-old, CANCELLED and inactive-account orders are not');

select pg_temp.assert(
  (select array_agg((e->>'order_id') || ':' || (e->>'amount')::numeric::int || ':' || (e->>'has_open_lines'))
     from public.report_territory_brief_facts(), jsonb_array_elements(largest_orders) e)
  = array['TB-O1:1500:true', 'TB-O2:500:false'],
  'largest_orders: biggest first, lines summed per order, open lines flagged, cancelled left out');

select pg_temp.assert(
  (select orders_14d_since from public.report_territory_brief_facts()) = current_date - 14,
  'the 14-day window is stated');

select pg_temp.assert(
  (select figures_refreshed_at::date from public.report_territory_brief_facts())
    = (now() - interval '10 days')::date,
  'figures_refreshed_at is the rollup rebuild, not the fact horizon');

select pg_temp.become('rep_b');

select pg_temp.assert(
  (select (bookings_ytd, bookings_prior_ytd, new_accounts_ytd, orders_14d_count, orders_14d_amount)::text
     from public.report_territory_brief_facts()) = '(3000,3000,1,1,640)'
  and (select jsonb_array_length(largest_orders) from public.report_territory_brief_facts()) = 1,
  'rep B sees only their own book');

select pg_temp.become('admin');

select pg_temp.assert(
  (select bookings_ytd >= 18000 and orders_14d_count >= 3
     from public.report_territory_brief_facts()),
  'an admin''s book is every active external account');

select public.start_impersonation((select id from t_user where label = 'rep_a'));
select pg_temp.assert(
  (select (bookings_ytd, orders_14d_count)::text
     from public.report_territory_brief_facts()) = '(15000,2)',
  'an admin viewing as rep A gets rep A''s facts (view-as through RLS)');
select public.stop_impersonation();

--------------------------------------------------------------------------
-- 2. report_territory_product_mix(): the same months of two years.
--------------------------------------------------------------------------
reset role;

-- dim_part's production column grants (see 20261013_reorder_candidates.sql):
-- the function must work without the cost columns.
do $$
declare cols text;
begin
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into cols
  from information_schema.columns c
  where c.table_schema = 'erp' and c.table_name = 'dim_part'
    and c.column_name <> all (array[
      'wholesale_unit_cost', 'unit_material_cost', 'unit_labor_cost',
      'unit_burden_cost', 'unit_service_cost', 'fixed_cost',
      'burden_percent', 'standard_unit_cost']);
  execute 'revoke select on erp.dim_part from authenticated';
  execute format('grant select (%s) on erp.dim_part to authenticated', cols);
end $$;

insert into erp.dim_part (part_key, part_id, part_description, product_code,
                          product_family, chambering)
values ('TB-MESA',  'TB-MESA',  'Mesa',      'FINISHED',  'Mesa',      '308 WIN'),
       ('TB-RIDGE', 'TB-RIDGE', 'Ridgeline', 'FINISHED',  'Ridgeline', '6.5 CM'),
       ('TB-TRAV',  'TB-TRAV',  'Traverse',  'FINISHED',  'Traverse',  '300 WM'),
       ('TB-COMP',  'TB-COMP',  'Barrel',    'COMPONENT', 'N/A',       'N/A');

-- Through March 2026: this period = Jan..Mar 2026, prior = Jan..Mar 2025.
--   Mesa      A1 2026-02 $3,000 + A2 2026-03 $1,000 | A1 2025-01 $1,000
--   Ridgeline nothing this period                 | A1 2025-02 $4,000
--             A1 2025-11 $9,000 is between the windows (the old YTD-vs-
--             full-year comparison counted it) → not counted
--   Traverse  A1 2026-04 $5,000 is after the through month → not counted
--   Barrel    A1 2026-01 $50,000, family N/A → a SKU row, never a family
--   Inactive A3 and internal TB-INT sell Mesa too → not counted
--   Rep B     B1 2026-02 Mesa $7,000 → only in B's (and an admin's) mix
insert into erp.agg_sku_month (customer_key, part_key, sales_month, revenue, qty, invoice_count)
values ('TB-A1',  'TB-MESA',  '2026-02-01',  3000,   3, 1),
       ('TB-A2',  'TB-MESA',  '2026-03-01',  1000,   1, 1),
       ('TB-A1',  'TB-MESA',  '2025-01-01',  1000,   1, 1),
       ('TB-A1',  'TB-RIDGE', '2025-02-01',  4000,   2, 1),
       ('TB-A1',  'TB-RIDGE', '2025-11-01',  9000,   5, 1),
       ('TB-A1',  'TB-RIDGE', '2026-04-01',   800,   1, 1),
       ('TB-A1',  'TB-TRAV',  '2026-04-01',  5000,   2, 1),
       ('TB-A1',  'TB-COMP',  '2026-01-01', 50000, 100, 1),
       ('TB-A3',  'TB-MESA',  '2026-02-01', 60000,  60, 1),
       ('TB-INT', 'TB-MESA',  '2026-02-01', 80000,  80, 1),
       ('TB-B1',  'TB-MESA',  '2026-02-01',  7000,   7, 1);

select pg_temp.become('rep_a');

select pg_temp.assert(
  (select array_agg((product_family, revenue, qty, prior_revenue, prior_qty, revenue_after_period)::text
                    order by product_family)
     from public.report_territory_product_mix('2026-03-01')
    where grain = 'family')
  = array['(Mesa,4000,4,1000,1,0)', '(Ridgeline,0,0,4000,2,800)'],
  'families: same months both years; Ridgeline''s Nov sale is between the windows; its Apr '
  'sale and Traverse''s are after the period (only in revenue_after_period, and Traverse, '
  'with nothing in either window, is not listed); N/A family left out; inactive/internal '
  'accounts left out');

select pg_temp.assert(
  (select (period_start, period_end, prior_start, prior_end)::text
     from public.report_territory_product_mix('2026-03-15') limit 1)
  = '(2026-01-01,2026-03-01,2025-01-01,2025-03-01)',
  'windows snap to whole months and are reported');

select pg_temp.assert(
  (select array_agg(part_id order by part_id)
     from public.report_territory_product_mix('2026-03-01', 2)
    where grain = 'sku')
  = array['TB-MESA', 'TB-RIDGE'],
  'SKUs: the top 2 of EITHER window — this period''s leader (Mesa) plus last year''s '
  'leader that fell away (Ridgeline); the $50k OEM barrel (no product family) is never '
  'a leading product');

select pg_temp.assert(
  (select count(*) from public.report_territory_product_mix('2026-03-01')
    where grain = 'sku' and part_id = 'TB-TRAV') = 0,
  'a SKU with no revenue in either window is not listed');

select pg_temp.become('rep_b');

select pg_temp.assert(
  (select array_agg((product_family, revenue, prior_revenue)::text)
     from public.report_territory_product_mix('2026-03-01')
    where grain = 'family')
  = array['(Mesa,7000,0)'],
  'rep B sees only their own book''s mix');

select pg_temp.become('admin');

select pg_temp.assert(
  (select revenue from public.report_territory_product_mix('2026-03-01')
    where grain = 'family' and product_family = 'Mesa') >= 11000,
  'an admin''s mix covers every active external account (A1+A2+B1 Mesa)');

--------------------------------------------------------------------------
-- 3. Appended view columns.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select array_agg(customer_key || '=' || coalesce(channel, 'null') order by customer_key)
     from public.v_territory_account_yoy where customer_key like 'TB-%')
  = array['TB-A1=Dealer', 'TB-A2=null'],
  'v_territory_account_yoy.channel is the ERP reporting group, blank as null, rep-scoped');

reset role;

select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_territory_account_yoy')
  = array['customer_key','customer_name','sold_to_city','sold_to_state','yearly_sales_goal',
          'revenue_ytd','revenue_prior_ytd','revenue_trailing_12m','last_invoice_date',
          'open_order_value','backlog_qty','backlog_amount','yoy_change_amount',
          'yoy_change_pct','first_invoice_date','channel'],
  'v_territory_account_yoy: every existing column in place, channel appended last');

select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_data_freshness')
  = array['data_loaded_at','data_through','orders_through','facts_loaded_at'],
  'v_data_freshness: existing columns in place, facts_loaded_at appended');

select public.log_job_run('etl:erp.fact_invoice_line', 'success', 10, null, now() - interval '2 days');
select public.log_job_run('etl:erp.dim_customer_contact', 'success', 10, null, now());
select public.log_job_run('etl:erp.fact_order_line', 'error', null, 'boom', now());

select pg_temp.assert(
  (select facts_loaded_at from public.v_data_freshness)
    = (select max(finished_at) from public.job_runs
        where job_name = 'etl:erp.fact_invoice_line' and status = 'success'),
  'facts_loaded_at: the last SUCCESSFUL invoice/order fact load — not another table, not a failure');

--------------------------------------------------------------------------
-- 4. Shape and privileges.
--------------------------------------------------------------------------
reset role;

select pg_temp.assert(
  not has_function_privilege('anon', 'public.report_territory_brief_facts()', 'execute')
  and has_function_privilege('authenticated', 'public.report_territory_brief_facts()', 'execute')
  and not has_function_privilege('anon', 'public.report_territory_product_mix(date, int)', 'execute')
  and has_function_privilege('authenticated', 'public.report_territory_product_mix(date, int)', 'execute'),
  'authenticated may execute both, anon neither');

select pg_temp.assert(
  (select bool_and(not prosecdef) from pg_proc
    where oid in ('public.report_territory_brief_facts()'::regprocedure,
                  'public.report_territory_product_mix(date, int)'::regprocedure)),
  'both are SECURITY INVOKER (RLS is the scope)');

select pg_temp.assert(
  (select bool_and(proconfig @> array['search_path=""'])
     from pg_proc
    where oid in ('public.report_territory_brief_facts()'::regprocedure,
                  'public.report_territory_product_mix(date, int)'::regprocedure)),
  'both pin an empty search_path');

do $$ begin raise notice 'ALL TERRITORY BRIEF FACT TESTS PASSED'; end $$;

rollback;
