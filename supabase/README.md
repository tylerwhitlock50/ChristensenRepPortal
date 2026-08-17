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
| `20260803223924_account_goals.sql` | `account_goals` (rep-entered annual goal, one per account/year), `v_account_goal_progress` (seasonal pace), `v_my_goal_rollup`, `v_rep_goal_attainment` — reconstructed from prod, where it was applied as "023_account_goals" |
| `20260816120000_mcp_access.sql` | `mcp_tokens` (SHA-256 at rest, column-granted so `token_hash` is unreadable over PostgREST) + `mcp_token_create()` / `mcp_token_revoke()` / `mcp_token_resolve()` — credentials for the `mcp` Edge Function. A token is an identity, not a grant: it confers no access of its own |
| `20260816140000_admin_view_as_rep.sql` | Admin "view as rep": `impersonation` state + `impersonation_events` audit, `is_real_admin()` / `acting_as_user_id()` / `effective_user_id()`, `is_admin()` and `my_customer_keys()` re-pointed at the effective user, `start_impersonation()` / `stop_impersonation()` / `acting_context()` / `impersonatable_profiles()`, and a read-only trigger on every RLS-enabled `public` table |

## Applying

With the deployer that lives next to the ETL (recommended — runs on the same
box, uses the same `.env`, and tracks history in `public.deployed_migrations`
keyed by full filename, so duplicate numeric prefixes like the two `032_*`
files can't collide):

```bash
python ../etl/deploy_migrations.py --dry-run   # list pending
python ../etl/deploy_migrations.py             # apply pending, in order
```

On a database that was previously migrated by hand, baseline first — see
`etl/README.md → Deploying migrations`.

Alternatively: the Supabase CLI (`supabase link` + `supabase db push` —
note the CLI keys history on the numeric prefix, which the duplicate `032`
filenames break), or paste each file in order into the Dashboard SQL editor,
or apply via MCP `apply_migration` (one call per file, keep the order).

## Post-migration checklist (Dashboard)

1. **Settings → API → Exposed schemas**: add `erp` (so PostgREST serves the read models).
2. **Auth → Providers → Email**: disable signups ("Allow new users to sign up" = off). Users are created by the admin only.
3. Create your own auth user, then promote it:
   `update public.profiles set role = 'admin' where user_id = '<your-uuid>';`
4. **Edge Function secrets**: `MCP_JWT_SECRET` (Settings → API → JWT Secret)
   if the MCP endpoint is deployed — see `supabase/functions/mcp/README.md`.
5. Schedule the recommendation job — either call
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
- **An MCP token is an identity, not a grant.** The `mcp` Edge Function
  resolves a token to a `user_id` with one `service_role` call and then mints
  a five-minute `authenticated` JWT for that user, so every read it makes goes
  through the same policies the SPA hits. The tempting alternative — read with
  `service_role`, filter by the rep's book in TypeScript — is a second
  implementation of the rules in 010, in a language with no RLS. Nothing in
  `functions/mcp/` may scope by customer; RLS is the only filter.
- **A goal belongs to the account, not to the rep who typed it.**
  `account_goals` is unique on `(customer_key, period_year)`, so a principal
  and their rep report against the same number and the admin rollup never has
  to pick whose copy counts. `created_by`/`updated_by` record who touched it.
- Goal pace is **seasonal, not straight-line**: `v_account_goal_progress`
  takes the share of the goal that should be in by today from the account's
  own prior-year shape, and only falls back to days-elapsed when there is no
  prior year (`pace_basis` says which). A straight line tells a dealer that
  books its year in the order season that it is behind every June, which
  trains reps to ignore the number.
- `erp.dim_customer.yearly_sales_goal` is **not** replaced by this. The UI
  shows both, because the drift between the ERP's goal and the rep's is the
  interesting part — and it is what an outbound push to Visual would
  reconcile. Nothing in the app writes to `erp.*`.

