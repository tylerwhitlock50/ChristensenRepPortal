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

## Applying

With the Supabase CLI (recommended — keeps migration history):

```bash
supabase link --project-ref <your-project-ref>
for f in migrations/*.sql; do supabase db push --include-all; done
```

or paste each file in order into the Dashboard SQL editor, or apply via MCP
`apply_migration` (one call per file, keep the numeric order).

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
- Rule thresholds live in `rule_settings.params` (jsonb) — tune with an
  UPDATE, not a migration.
