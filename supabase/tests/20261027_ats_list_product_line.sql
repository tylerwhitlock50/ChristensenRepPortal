/*============================================================================
  20261027_ats_list_product_line.sql — assertions for
    20261027090200_ats_list_product_line.sql
      v_ats_list.part_id                    coalesce(dim_part.part_id, part_key)
      v_ats_list.product_code               NEW (appended)
      v_ats_list.product_code_description   NEW (appended)

  Runs in a transaction and ROLLS BACK; writes throwaway ATS/part rows.
  Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_ats_list_product_line.sql

  A clean run prints "ALL ATS PRODUCT LINE TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Shape: the 032 contract in place, the two columns appended.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_ats_list')
  = array['part_key', 'part_id', 'part_description', 'product_family', 'chambering',
          'barrel_length', 'upc', 'on_hand_qty', 'committed_qty', 'backlog_qty',
          'inbound_qty', 'ats_qty', 'next_avail_date', 'availability_status',
          'is_oversold', 'loaded_at', 'product_code', 'product_code_description'],
  'v_ats_list: every 032 column in place, product_code + description appended');

select pg_temp.assert(
  (select reloptions from pg_class where oid = 'public.v_ats_list'::regclass)
    @> array['security_invoker=true']
  and has_table_privilege('authenticated', 'public.v_ats_list', 'select')
  and not has_table_privilege('anon', 'public.v_ats_list', 'select'),
  'still security_invoker; authenticated reads, anon does not');

--------------------------------------------------------------------------
-- 2. Values, on fixtures: a catalogued part and one dim_part has not seen.
--------------------------------------------------------------------------
insert into erp.dim_part (part_key, part_id, part_description, product_code,
                          product_code_description, product_family)
values ('AP-RIDGE', 'AP-RIDGE', 'Ridgeline test rifle', 'RIDGELINE', 'Ridgeline rifles', 'Ridgeline');

insert into erp.fact_available_to_sell (part_key, site_key, shipping_on_hand_qty,
                                        available_to_sell_qty, availability_status)
values ('AP-RIDGE',  'AP-SITE', 5, 3, 'Available'),
       ('AP-NOPART', 'AP-SITE', 2, 2, 'Available');

select pg_temp.assert(
  (select array_agg((part_key, part_id, coalesce(product_code, '-'),
                     coalesce(product_code_description, '-'))::text order by part_key)
     from public.v_ats_list where part_key like 'AP-%')
  = array['(AP-NOPART,AP-NOPART,-,-)',
          '(AP-RIDGE,AP-RIDGE,RIDGELINE,"Ridgeline rifles")'],
  'product line from dim_part; a part missing from dim_part still shows its id');

-- On live data: never a null part_id, and product_code is dim_part's.
select pg_temp.assert(
  (select count(*) from public.v_ats_list where part_id is null) = 0,
  'no row of the live snapshot has a null part_id');

select pg_temp.assert(
  (select count(*)
     from public.v_ats_list v
     join erp.dim_part p on p.part_key = v.part_key
    where v.product_code is distinct from p.product_code
       or v.product_code_description is distinct from p.product_code_description) = 0,
  'product_code / description equal dim_part''s on every live row');

--------------------------------------------------------------------------
-- 3. A signed-in rep (any book) reads both new columns — dim_part's
--    column grants (20260901190300) must cover them.
--------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
set local role authenticated;

select pg_temp.assert(
  (select product_code from public.v_ats_list where part_key = 'AP-RIDGE') = 'RIDGELINE'
  and (select count(*) from public.v_ats_list) > 0,
  'authenticated reads v_ats_list with the new columns');

reset role;

do $$ begin raise notice 'ALL ATS PRODUCT LINE TESTS PASSED'; end $$;

rollback;
