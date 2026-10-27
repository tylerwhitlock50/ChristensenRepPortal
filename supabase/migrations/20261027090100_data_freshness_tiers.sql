/*============================================================================
  20261027090100_data_freshness_tiers.sql — the freshness stamp learns the
  new refresh tiers.

  Why
  ---
  The ETL moves from one evening run to four scheduled tasks on the BI
  server (etl/views.yml `profiles:`; the runbook is etl/README.md):

    ats      every 15 min, weekdays 05:00–17:45   erp.fact_available_to_sell
    hourly   weekdays 06:05–16:05                 customers, parts, orders,
                                                  invoices, shipments + the
                                                  rollup rebuild
    full     04:30 daily and 17:00 weekdays       everything

  The full run still writes the `etl:run` ledger row; the hourly run writes
  `etl:run:hourly` with the same meaning — every table of the profile
  loaded and every required post-load step (the rollups) ran. Either one
  is a load the Overview's figures are as-of, so `data_loaded_at` must take
  the newer of the two, or the stamp says "4:30 AM" all afternoon while the
  numbers are an hour old.

  The ATS tier writes no ledger row of its own (it has no post-load), only
  the per-table `etl:erp.fact_available_to_sell` row the loader writes for
  every table. Its success is the moment the In-stock list was last
  confirmed against the ERP — whether or not anything changed — so that is
  `ats_loaded_at`. Deliberately NOT max(fact_available_to_sell.loaded_at):
  that is the as-of of the rows, which a load that found no change (or a
  future merge swap) would not move.

  What
  ----
  public.v_data_freshness restated from LIVE (pg_get_viewdef, identical to
  20261013160000_territory_brief_facts.sql on 2026-10-26):
    data_loaded_at   newest successful etl:run OR etl:run:hourly; the
                     pre-ledger fallback (any etl:erp.* success) unchanged
    data_through     verbatim
    orders_through   verbatim
    facts_loaded_at  verbatim
    ats_loaded_at    NEW, appended last: newest successful load of
                     erp.fact_available_to_sell

  Plus a partial index for the lookups: the view is now read by every
  signed-in client every 5 minutes (the heartbeat), and job_runs grows by
  ~170 rows a weekday under the new cadence (52 ATS runs alone). With the
  index each max() is one index probe instead of a walk over every run of
  that job since the beginning.

  Still OWNER-rights (no security_invoker) — the documented exception from
  024: the output is five timestamps and nothing else, and reps cannot
  read job_runs or the whole invoice fact.
============================================================================*/

create index if not exists idx_job_runs_success_finished
  on public.job_runs (job_name, finished_at desc)
  where status = 'success';

create or replace view public.v_data_freshness as
select
    coalesce(
      -- Two probes rather than `job_name in (...)`, so each is a single
      -- index lookup; greatest() ignores the null of a ledger that has
      -- never run (no hourly run has ever happened before this deploy).
      greatest(
        (select max(j.finished_at)
           from public.job_runs j
          where j.status = 'success'
            and j.job_name = 'etl:run'),
        (select max(j.finished_at)
           from public.job_runs j
          where j.status = 'success'
            and j.job_name = 'etl:run:hourly')
      ),
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
      where o.order_date <= current_date)            as orders_through,
    -- The last time the facts the rollups are built from landed, whatever
    -- else that night did. Newer than the rollups' refreshed_at (by more
    -- than a load's own duration) means the post-load rebuild has not run
    -- over them: the brief's figures are behind.
    (select max(j.finished_at)
       from public.job_runs j
      where j.status = 'success'
        and j.job_name in ('etl:erp.fact_invoice_line',
                           'etl:erp.fact_order_line'))
                                                     as facts_loaded_at,
    -- The In-stock list's own clock: the last successful ATS load, from any
    -- tier (the 15-minute ats run, or the full runs, which load it too).
    (select max(j.finished_at)
       from public.job_runs j
      where j.status = 'success'
        and j.job_name = 'etl:erp.fact_available_to_sell')
                                                     as ats_loaded_at;

revoke all on public.v_data_freshness from anon, public;
grant select on public.v_data_freshness to authenticated;

comment on view public.v_data_freshness is
  'One row: finish time of the last fully successful ETL run (etl:run — '
  'the full run — or etl:run:hourly, whichever is newer; every table of '
  'the profile loaded and every post-load step ran), newest non-memo '
  'invoice date (data_through — the revenue horizon), newest order entry '
  'date (orders_through), the last successful load of the invoice or '
  'order facts (facts_loaded_at, 20261013160000), and the last successful '
  'load of erp.fact_available_to_sell (ats_loaded_at, 20261027090100 — '
  'the In-stock list''s as-of; refreshed every 15 min on weekdays). '
  'Future-dated ERP rows are ignored for the two horizons. OWNER-rights on '
  'purpose (documented exception): output is five timestamps and nothing '
  'else. Powers the freshness stamp, the ATS stamp and the AI brief''s '
  'figures-behind check.';
