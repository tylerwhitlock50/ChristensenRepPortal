# supabase

Postgres schema for the Sales Execution Portal, as ordered Supabase migrations.

## Migrations

| File | What it creates |
|---|---|
| `001_schemas.sql` | `erp` schema + grants |
| `002_erp_read_tables.sql` | Landing tables mirroring the SQL Server `bi.vw_*` views (snake_cased), generated date columns from yyyymmdd keys, indexes |
| `003_app_core.sql` | `profiles` (auto-created via auth trigger; `sales_rep_key` + `rep_group_vendor_id` drive derived ownership), `account_assignments` (grant/revoke override layer), `is_admin()` / `has_account_access()` |
| `004_app_crm.sql` | `contacts`, `notes`, `photos` (metadata), `tasks` |
| `005_app_execution.sql` | `rule_settings`, `recommendations` (outcome required to close, idempotency index), `actions`, `visits` (structured survey), auto-`acted` trigger |
| `006_ai_and_events.sql` | `ai_summaries` cache (context hash + prompt version), `login_events` + `log_login()` RPC, `v_user_accounts` resolved-ownership view, `rep_execution_summary` + `account_coverage` admin views |
| `007_rls_policies.sql` | All RLS policies — reps see only assigned accounts; erp is select-only |
| `008_recommendation_engine.sql` | `generate_recommendations()` — nightly job, rules driven by `rule_settings.params` |
| `009_storage.sql` | Private `account-photos` bucket + path-based RLS (`<customer_key>/<file>`) |
| `010_access_performance.sql` | `my_customer_keys()` / `placeholder_rep_keys()`, policy rewrite for performance |
| `011_account_views.sql` | Account list/summary/revenue/orders/shipments views (`security_invoker`) |
| `012_job_runs.sql` | `job_runs` audit table + `log_job_run()` — written by the ETL and the recommendation job |
| `013_photo_updates.sql` | Author UPDATE grant so photos can attach to a just-saved visit |
| `014_erp_column_drift.sql` | ERP landing-table column drift fixes |
| `015_account_last_order_date.sql` | `v_account_list` with harmonized `last_order_date` |
| `016_missions_admin.sql` | Missions: `mission_batches`, `recommendations.requires_visit`/`batch_id`, visit-required close trigger, `create_mission()` bulk RPC with dry-run, progress/detail/activity views, `profiles.email` mirror, profile placeholder guard, login-events + `v_user_accounts` cleanups |
| `017_function_hardening.sql` | Function grants + pinned `search_path` |
| `018_account_header_views.sql` | Order/shipment views at header grain + line detail for the drill-in |
| `019_account_scoring.sql` | `account_signals` (a TABLE — matviews cannot carry RLS), `score_settings`, `score_account()`, `refresh_account_signals()` / `apply_account_scores()` split, `preview_account_scores()` |
| `020_recommendation_engine_v2.sql` | `generate_recommendations()` on the score: banded priority, why-now `reason`, `cadence_overdue` (seeded off), per-rule cooldown after a resolution, `preview_recommendation_counts()` |
| `021_ai_summary_batch.sql` | `ai_summaries.headline`, `ai_batch_targets()` for the nightly pre-generation |
| `022_job_run_duration.sql` | `log_job_run()` stamps `finished_at` with `clock_timestamp()`, so job durations are real |
| `023_account_deactivations.sql` | `account_deactivations` — rep-side "stop working this account" override with reason + history; dismiss/de-score trigger; exclusions in `v_account_list`, `refresh_account_signals()`, `create_mission()`, coverage views |
| `20260803223924_account_goals.sql` | Reconstructed production migration for per-account yearly goals and goal-progress views; retains the real remote migration version |
| `024_app_settings.sql` | Admin-managed feature flags and the `v_data_freshness` read path |
| `025_intel_views.sql` | Territory-level sales, SKU, and backlog intelligence views |
| `026_global_intel.sql` | Security-definer global product aggregates; superseded by the units-only output contract in 033 |
| `027_ats.sql` | Legacy ATS landing design for the never-created `vw_FactATS`; superseded and removed by the certified ATS migration in the comprehensive 032 file |
| `028_ai_actions.sql` | Per-user AI action cache and usage ledger |
| `029_intel_view_filters.sql` | Aligns territory intelligence with active/external account filters |
| `030_territory_rollups.sql` | Precomputed territory rollup tables and ETL refresh function |
| `031_backlog_ship_date.sql` | Adds earliest desired-ship date to the backlog-by-SKU read path |
| `032_shipment_line_tracking.sql` | Parallel-branch migration landing line-level shipment tracking |
| `032_tracking_ats_contacts_reporting.sql` | Comprehensive BI catch-up: reporting hierarchy, tracking, certified ATS landing, ERP contacts, and merged read views |
| `033_global_intel_units_only.sql` | Removes company-wide dollar outputs from global intelligence; exposes units and mix only |

## Applying

The project uses imperative, forward-only migrations. For a linked environment
whose migration history already matches this repository, inspect the installed
CLI's current options with `supabase db push --help` and then run one push—not a
loop that repeats the same command for every file.

```bash
supabase link --project-ref <your-project-ref>
supabase db push --include-all
```

### Legacy migration-version caveat

Two replay-safe files have the same historical version prefix, `032`, because
they arrived from parallel branches:

- `032_shipment_line_tracking.sql`
- `032_tracking_ats_contacts_reporting.sql`

The comprehensive tracking/ATS/contacts migration repeats the tracking change
and adds the remaining BI catch-up. Existing production history must not be
renamed casually. Before bootstrapping a fresh project with the CLI, reconcile
these two local filenames with the linked project's migration-history table or
apply them in an explicitly recorded order through the approved migration
workflow. Do not assume that sorting only by the numeric prefix is sufficient.

## Post-migration checklist (Dashboard)

1. **Settings → API → Exposed schemas**: add `erp` (so PostgREST serves the read models).
2. **Auth → Providers → Email**: disable signups ("Allow new users to sign up" = off). Users are created by the admin only.
3. Create your own auth user, then promote it:
   `update public.profiles set role = 'admin' where user_id = '<your-uuid>';`
4. Schedule the recommendation job — either call
   `select public.generate_recommendations();` as the last step of the ETL
   (recommended), or enable the `pg_cron` extension and use the schedule in
   the header of `008_recommendation_engine.sql`.

## Design rules

- `erp.*` is written **only** by the ETL over the service-role/direct
  connection (truncate-and-load per table, in a transaction). No app-side
  insert/update/delete policies exist — app writes are impossible.
- App tables reference ERP accounts by `customer_key` **without** foreign
  keys across schemas (the erp side is reloaded wholesale).
- **Ownership is derived from the ERP** (customer's `assigned_sales_rep_id`;
  principal via `dim_sales_rep.vendor_id`). `account_assignments` is only a
  grant/revoke override layer — revoke beats derive. Per-user setup is just
  stamping `sales_rep_key` (and `rep_group_vendor_id` for principals) on the
  profile. Never stamp placeholder rep codes (WEB/HOUSE) on a profile.
- Recommendations: reps never create them (system job or admin only), an
  action auto-advances `open → acted`, and a CHECK constraint blocks
  closing/dismissing without an outcome.
- Rule thresholds live in `rule_settings.params` (jsonb) — tune from
  /admin/settings, or with an UPDATE. Not a migration.
- **Scoring weights live in `score_settings`, NOT in `rule_settings`.**
  `recommendations.rule_key` is a foreign key to `rule_settings.rule_key`, so
  every row in that table is a legal rule stamp on a recommendation. A weight
  vector is not a rule and must not be stampable.
- `account_signals` is a plain table and must stay one. Postgres does not
  support RLS on materialized views, and Supabase grants `authenticated`
  SELECT on new objects in `public` — so the obvious "nightly rollup" shape
  would serve every dealer's revenue to every rep while looking correct.
- Closed recommendations no longer re-fire the next night. `uq_recs_open_rule`
  only ever prevented duplicate *open* rows; the cooldown in 020 is what makes
  resolving something mean anything.
- The ERP's `active_flag` is not the whole story: `account_deactivations`
  (023) is the rep's own "stop working this account" override, and every
  active-only surface (account list, scoring, missions, coverage) must check
  both. Deactivation never removes *access* — `my_customer_keys()` and
  `has_account_access()` are deliberately untouched, so the rep can still
  open the account and undo it.
