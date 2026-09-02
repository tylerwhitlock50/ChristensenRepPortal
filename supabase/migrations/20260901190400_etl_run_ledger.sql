/*============================================================================
  20260901190400_etl_run_ledger.sql — the freshness stamp reads the RUN,
  not the luckiest table; and a home for the loader's staging tables.

  Why
  ---
  v_data_freshness.data_loaded_at was max(finished_at) over any successful
  'etl:%' job. When one table fails (2026-08-18: fact_order_line timed out
  in COPY), push_to_supabase.py keeps loading the rest, skips every
  post_load_sql step, and the stamp still advances — so the portal shows
  a fresh date over a day-stale Overview. The loader now writes one
  'etl:run' row per run (success only when every table loaded AND every
  post-load step ran), and that is what the stamp reads.

  The staging schema: the loader used to TRUNCATE the live table and then
  stream from SQL Server inside the same transaction, holding ACCESS
  EXCLUSIVE for the whole read — ~60 s on fact_invoice_line at 5 PM
  Mountain, against readers with an 8 s lock_timeout. It now streams into
  etl_stage.<table> and swaps in one short transaction. The schema is not
  exposed to PostgREST and carries no grants, so a half-loaded staging
  table (which holds the cost columns 20260901190300 fenced) is never
  reachable from the API.
============================================================================*/

create schema if not exists etl_stage;
revoke all on schema etl_stage from public, anon, authenticated;
comment on schema etl_stage is
  'Landing zone for etl/push_to_supabase.py: each erp table is streamed '
  'here first, then swapped into erp.* in one short transaction. Never '
  'exposed to PostgREST; never granted.';

create or replace view public.v_data_freshness as
select
    coalesce(
      (select max(j.finished_at)
         from public.job_runs j
        where j.status = 'success'
          and j.job_name = 'etl:run'),
      -- Before the first run that logs 'etl:run' (loader < 2026-09-01).
      (select max(j.finished_at)
         from public.job_runs j
        where j.status = 'success'
          and j.job_name like 'etl:erp.%')
    )                                                as data_loaded_at,
    (select max(f.invoice_date)
       from erp.fact_invoice_line f
      where f.is_memo is not true
        and f.invoice_date <= current_date)          as data_through,
    (select max(o.order_date)
       from erp.fact_order_line o
      where o.order_date <= current_date)            as orders_through;

revoke all on public.v_data_freshness from anon, public;
grant select on public.v_data_freshness to authenticated;

comment on view public.v_data_freshness is
  'One row: finish time of the last fully successful ETL run (etl:run — '
  'every table loaded and every post-load step ran), newest non-memo '
  'invoice date (data_through — the revenue horizon), and newest order '
  'entry date (orders_through). Future-dated ERP rows are ignored for the '
  'two horizons. OWNER-rights on purpose (documented exception): output is '
  'three timestamps and nothing else. Powers the freshness stamp.';
