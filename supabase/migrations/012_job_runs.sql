/*============================================================================
  010_job_runs.sql
  Purpose: Audit trail for every scheduled job — each ETL table load and
           each generate_recommendations() run writes a row. Surfaced on
           the admin dashboard so a failed overnight load is visible to
           the admin before the reps notice stale data.
  Writers: service_role only (ETL / recommendation job). No app-side
           insert/update policies exist.
============================================================================*/

create table if not exists public.job_runs (
    id             bigint generated always as identity primary key,
    job_name       text not null,          -- e.g. 'etl:erp.fact_invoice_line', 'generate_recommendations'
    started_at     timestamptz not null default now(),
    finished_at    timestamptz,
    status         text not null default 'running'
                   check (status in ('running','success','error')),
    rows_affected  bigint,
    error          text
);
alter table public.job_runs enable row level security;
create index if not exists idx_job_runs_name on public.job_runs (job_name, started_at desc);

create policy "admin reads job runs" on public.job_runs
  for select to authenticated using (public.is_admin());

-- Log recommendation runs from inside the generator itself
create or replace function public.log_job_run(
    p_job_name text, p_status text, p_rows bigint, p_error text default null,
    p_started_at timestamptz default now()
) returns void
language sql security definer set search_path = public
as $$
  insert into public.job_runs (job_name, started_at, finished_at, status, rows_affected, error)
  values (p_job_name, p_started_at, now(), p_status, p_rows, p_error);
$$;
revoke execute on function public.log_job_run(text, text, bigint, text, timestamptz)
  from public, anon, authenticated;
