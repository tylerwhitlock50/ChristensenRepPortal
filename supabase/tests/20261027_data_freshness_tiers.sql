/*============================================================================
  20261027_data_freshness_tiers.sql — assertions for
    20261027090100_data_freshness_tiers.sql
      v_data_freshness.data_loaded_at   newest of etl:run / etl:run:hourly
      v_data_freshness.ats_loaded_at    NEW (appended): last ATS load

  Runs in a transaction and ROLLS BACK; writes throwaway job_runs rows
  dated in the future so they are the newest whatever the live ledger
  holds. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_data_freshness_tiers.sql

  A clean run prints "ALL DATA FRESHNESS TIER TESTS PASSED".
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
-- 1. Shape: the four existing columns in place, ats_loaded_at appended.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select array_agg(column_name::text order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'v_data_freshness')
  = array['data_loaded_at', 'data_through', 'orders_through', 'facts_loaded_at',
          'ats_loaded_at'],
  'v_data_freshness: existing columns in place, ats_loaded_at appended last');

select pg_temp.assert(
  (select array_agg(format_type(a.atttypid, a.atttypmod) order by a.attnum)
     from pg_attribute a
    where a.attrelid = 'public.v_data_freshness'::regclass and a.attnum > 0)
  = array['timestamp with time zone', 'date', 'date', 'timestamp with time zone',
          'timestamp with time zone'],
  'column types unchanged; ats_loaded_at is timestamptz');

select pg_temp.assert(
  has_table_privilege('authenticated', 'public.v_data_freshness', 'select')
  and not has_table_privilege('anon', 'public.v_data_freshness', 'select'),
  'authenticated reads it, anon does not');

select pg_temp.assert(
  exists (select 1 from pg_indexes
           where schemaname = 'public' and indexname = 'idx_job_runs_success_finished'),
  'partial index on successful runs exists');

--------------------------------------------------------------------------
-- 2. data_loaded_at: the newer of the full and hourly ledgers; failures and
--    per-table rows never count.
--------------------------------------------------------------------------
insert into public.job_runs (job_name, started_at, finished_at, status, rows_affected, error)
values ('etl:run',        now() + interval '50 min', now() + interval '1 hour',  'success', 9, null),
       ('etl:run:hourly', now() + interval '110 min', now() + interval '2 hours', 'success', 5, null);

select pg_temp.assert(
  (select data_loaded_at from public.v_data_freshness) = now() + interval '2 hours',
  'an hourly run newer than the full run moves data_loaded_at');

insert into public.job_runs (job_name, started_at, finished_at, status, rows_affected, error)
values ('etl:run',          now() + interval '170 min', now() + interval '3 hours', 'success', 9, null),
       ('etl:run:hourly',   now() + interval '230 min', now() + interval '4 hours', 'error', null, 'boom'),
       ('etl:erp.dim_part', now() + interval '290 min', now() + interval '5 hours', 'success', 1, null);

select pg_temp.assert(
  (select data_loaded_at from public.v_data_freshness) = now() + interval '3 hours',
  'a newer full run wins back; a FAILED hourly run and a lone table load do not count');

--------------------------------------------------------------------------
-- 3. ats_loaded_at: the last SUCCESSFUL ATS table load only.
--------------------------------------------------------------------------
insert into public.job_runs (job_name, started_at, finished_at, status, rows_affected, error)
values ('etl:erp.fact_available_to_sell', now() + interval '55 min',  now() + interval '1 hour',  'success', 818, null),
       ('etl:erp.fact_available_to_sell', now() + interval '115 min', now() + interval '2 hours', 'error', null, 'boom');

select pg_temp.assert(
  (select ats_loaded_at from public.v_data_freshness) = now() + interval '1 hour',
  'ats_loaded_at is the last successful ATS load — not a failure, not another table');

--------------------------------------------------------------------------
-- 4. The verbatim columns still mean what they meant.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select data_through from public.v_data_freshness)
    is not distinct from (select max(f.invoice_date) from erp.fact_invoice_line f
                           where f.is_memo is not true and f.invoice_date <= current_date)
  and (select orders_through from public.v_data_freshness)
    is not distinct from (select max(o.order_date) from erp.fact_order_line o
                           where o.order_date <= current_date)
  and (select facts_loaded_at from public.v_data_freshness)
    is not distinct from (select max(finished_at) from public.job_runs
                           where status = 'success'
                             and job_name in ('etl:erp.fact_invoice_line',
                                              'etl:erp.fact_order_line')),
  'data_through / orders_through / facts_loaded_at unchanged');

--------------------------------------------------------------------------
-- 5. A rep can read it (owner-rights view over tables reps cannot read).
--------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
set local role authenticated;

select pg_temp.assert(
  (select count(*) from public.v_data_freshness) = 1
  and (select ats_loaded_at from public.v_data_freshness) = now() + interval '1 hour',
  'authenticated (no book at all) reads the one row, ats_loaded_at included');

reset role;

do $$ begin raise notice 'ALL DATA FRESHNESS TIER TESTS PASSED'; end $$;

rollback;
