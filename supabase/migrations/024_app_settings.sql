/*============================================================================
  024_app_settings.sql
  Purpose: The data-first restructure's control plane.

  Numbering note: 019–023 are reserved — an account-scoring/goals workstream
  applied migrations with those numbers to the shared project on 2026-08-03
  (019_account_scoring … 023_account_goals) from a branch not yet merged
  here. This restructure therefore starts at 024.

  1. public.app_settings — admin-managed feature flags. The portal is
     pivoting from "tell reps what to do" to "get data into reps' hands"
     (CEO direction, Aug 2026): every data-CAPTURE surface (recommendations/
     missions, visit surveys & photos, tasks, action logging & notes) is
     hidden behind a flag so it can be re-enabled per feature, without a
     deploy, once the tool has become the reps' daily habit.

     Deliberately a NEW table, not rows in public.rule_settings (rec-engine
     rule config) or public.score_settings (scoring tuning) — "enabled"
     must not mean three different things in one relation.

  2. public.v_data_freshness — one row powering the "As of … · Data through …"
     stamp every intel page and AI brief displays.

  ── What this migration deliberately does NOT do ───────────────────────────
  It does not touch generate_recommendations(). The recommendation engine
  was rewritten remotely by 020_recommendation_engine_v2 (the unmerged
  branch above), and re-stating any body here would silently revert it.
  The "stop minting invisible recommendations while the feature is hidden"
  behaviour lives at the CALL SITE instead: etl/views.yml's post_load_sql
  now guards the call with an EXISTS over this table, so the gate works
  against every engine version without owning the function.
============================================================================*/

--------------------------------------------------------------------------
-- app_settings — one row per feature flag / app-level switch
--------------------------------------------------------------------------
create table if not exists public.app_settings (
    setting_key text primary key,
    enabled     boolean not null default true,
    params      jsonb not null default '{}'::jsonb,
    description text,
    updated_at  timestamptz not null default now(),
    updated_by  uuid references auth.users (id)
);
alter table public.app_settings enable row level security;

drop trigger if exists trg_app_settings_touch on public.app_settings;
create trigger trg_app_settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- Everyone signed in reads flags (the shell decides what to render);
-- only admins flip them. Scalar subqueries so is_admin() is an InitPlan
-- evaluated once per query, matching 010_access_performance.sql.
create policy "read settings" on public.app_settings
  for select to authenticated using (true);
create policy "admin manages settings" on public.app_settings
  for all to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- All four capture features start HIDDEN — that is the point of this
-- migration. Flip enabled=true from the admin Settings page to restore one.
insert into public.app_settings (setting_key, enabled, description) values
  ('feature.recommendations', false,
   'Recommendations & missions: Today list, mission banners, recommendation cards, admin mission composer, nightly generator'),
  ('feature.visits', false,
   'Visit surveys, visit history, and photo capture on the account page'),
  ('feature.tasks', false,
   'Personal task list page and quick-add'),
  ('feature.action_logging', false,
   'Log-a-contact buttons and free-text notes on the account page')
on conflict (setting_key) do nothing;

revoke all on public.app_settings from anon, public;
grant select, insert, update on public.app_settings to authenticated;  -- RLS gates writes to admins

comment on table public.app_settings is
  'Admin-managed feature flags and app-level switches. Reps read, admins '
  'write. Not recommendation-rule or scoring config — those live in '
  'rule_settings / score_settings.';

--------------------------------------------------------------------------
-- v_data_freshness — one row: when the ETL last finished, and the newest
-- invoice date in the warehouse.
--
-- DELIBERATE EXCEPTION to the security_invoker contract in 011: this view
-- runs with OWNER rights, because both sources are unreadable to reps by
-- design (job_runs is admin-only; an invoker MAX over fact_invoice_line
-- would be the rep's own book, not the warehouse). The exception is safe
-- for the same reason report_global_product_sales (026) is: the output
-- shape — two timestamps — structurally cannot leak account data. Do NOT
-- widen this view's column list without re-justifying that.
--------------------------------------------------------------------------
create or replace view public.v_data_freshness as
select
    (select max(j.finished_at)
       from public.job_runs j
      where j.status = 'success'
        and j.job_name like 'etl:%')                 as data_loaded_at,
    (select max(f.invoice_date)
       from erp.fact_invoice_line f
      where f.is_memo is not true)                   as data_through;

revoke all on public.v_data_freshness from anon, public;
grant select on public.v_data_freshness to authenticated;

comment on view public.v_data_freshness is
  'One row: last successful ETL finish time and newest invoice date. '
  'OWNER-rights on purpose (documented exception): output is two timestamps '
  'and nothing else. Powers the "As of / Data through" stamp.';
