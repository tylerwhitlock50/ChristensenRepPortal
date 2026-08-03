/*============================================================================
  022_job_run_duration.sql
  Purpose: Make job_runs durations measurable.

  log_job_run() (012_job_runs.sql) stamps finished_at with now(), which is the
  TRANSACTION timestamp — fixed for the life of the transaction. Every caller
  runs inside one transaction, so finished_at has never described when the job
  finished; it describes when the job's transaction began.

  For callers that let p_started_at default to now() the two are identical and
  every job has recorded a duration of exactly zero. 019's
  refresh_account_signals() is the first caller to pass a real
  clock_timestamp() start, which makes the bug visible rather than merely
  useless: clock_timestamp() advances during the transaction and now() does
  not, so finished_at lands BEFORE started_at and the duration comes out
  negative.

      job_name                 started_at        finished_at       seconds
      refresh_account_signals  20:58:19.484866   20:58:19.483711     -0.00

  clock_timestamp() on both ends is the whole fix. Nothing else changes: the
  signature, the grants and the column list are untouched, and existing rows
  are left alone — they are not wrong so much as unmeasured, and rewriting
  history to a duration nobody recorded would be worse than leaving it.

  This matters beyond tidiness. 019's own checklist says to run
  refresh_account_signals() "and TIME IT" because it is two whole-book fact
  scans inside the nightly ETL window. job_runs is where that time was
  supposed to be visible, and until now it could not be.
============================================================================*/

create or replace function public.log_job_run(
    p_job_name   text,
    p_status     text,
    p_rows       bigint,
    p_error      text        default null,
    p_started_at timestamptz default clock_timestamp()
) returns void
language sql
security definer set search_path = 'public'
as $$
  insert into public.job_runs (job_name, started_at, finished_at, status, rows_affected, error)
  values (p_job_name, p_started_at, clock_timestamp(), p_status, p_rows, p_error);
$$;

comment on function public.log_job_run(text, text, bigint, text, timestamptz) is
  'Record one job run. Both ends are clock_timestamp(), NOT now(): now() is '
  'the transaction timestamp, so a job that logs its own start and finish '
  'inside one transaction would record a zero — or, if it passes a real '
  'clock_timestamp() start, a negative — duration.';
