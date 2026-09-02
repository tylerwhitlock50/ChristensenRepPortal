# etl

Pushes the governed SQL Server `bi.vw_*` views into Supabase (`erp` schema).

- **Pattern:** stage-and-swap per table. Each view streams into
  `etl_stage.<table>` (a schema PostgREST never sees), then one short
  `DELETE` + `INSERT … SELECT` transaction swaps it into `erp.<table>` —
  no exclusive lock, so a rep querying during the 5 PM run sees yesterday's
  rows or tonight's, never a mix and never a lock timeout. Facts and dims
  are small enough (single-site rifle manufacturer) that full reloads beat
  incremental logic.
- **Row-count floor:** a view that returns fewer than `ETL_MIN_ROW_RATIO`
  (default 0.5) of its previous successful row count is refused before the
  swap — an empty feed must not zero every rollup. Set it to `0` for a
  known shrink.
- **Schedule:** the "Run CRM update" scheduled task runs `push.ps1` at
  5 PM Mountain daily. It exits with the loader's code and appends to
  `push.log`, so Task Scheduler's *Last Run Result* is the alarm.
- **Post-load:** after every table loads it runs `views.yml → post_load_sql`
  in order (rollup refresh first, then scoring/recommendations, then order
  QC) and finally logs one `etl:run` row in `public.job_runs`. That row is
  `success` only when every table AND every post-load step succeeded; the
  portal's freshness stamp reads it, so a partial night shows as stale
  instead of fresh.

## Files

- `views.yml` — view→table mapping, snake_case overrides, post-load SQL
- `push_to_supabase.py` — the job (pyodbc → psycopg COPY)
- `deploy_migrations.py` — applies `../supabase/migrations/*.sql` to Supabase
  (same box, same `.env`, needs only `PG_CONN`)
- `.env.example` — required environment variables

## Setup

```bash
pip install pyodbc "psycopg[binary]" pyyaml
cp .env.example .env   # fill in real connection strings
python push_to_supabase.py
```

Notes:
- `PG_CONN` must use the **direct / session-pooler** connection with the
  `postgres` role (bypasses RLS; COPY needs a real session). Never the anon key.
- The SQL Server login needs SELECT on schema `bi` only
  (`GRANT SELECT ON SCHEMA::bi TO <etl_login>`).
- Generated columns (`order_date`, `ship_date`, …) are computed by Postgres;
  the job pushes only the columns the view returns.
- If you already have a working push tool + scheduler, `views.yml` is the
  contract: same mapping, same replace-on-load semantics, same post-load call.

## Deploying migrations

`deploy_migrations.py` runs everything in `../supabase/migrations` that has
not run yet, in filename order, one transaction per file, recording each in
`public.deployed_migrations` (keyed by full filename, so the two `032_*`
files don't collide the way the Supabase CLI's numeric versions would).

First run against the existing prod database — which was migrated by hand —
must baseline instead of re-running history:

```bash
python deploy_migrations.py --dry-run                      # see what it would do
python deploy_migrations.py --baseline-through <last-file-you-know-is-applied>
python deploy_migrations.py                                # applies the rest
```

If everything currently in the folder is already live, `--baseline` records
it all without executing. After that, deploying new work is just
`python deploy_migrations.py` (idempotent, safe on a schedule before the
nightly load: `python deploy_migrations.py && python push_to_supabase.py`).
A recorded file whose content later changes is flagged as drift, never
silently re-run; `--reapply <file>` is the deliberate way to re-run a
replay-safe file.

**One apply path.** On 2026-09-01 five files had been applied through the
Supabase CLI / MCP without a row in `deployed_migrations`, and a CLI hotfix
had no file at all; the next deployer run would have replayed the lot and
undone the hotfix. If a file ever has to go in by hand (Dashboard, CLI,
MCP), commit it to the folder and record it the same day:

```bash
python deploy_migrations.py --dry-run          # it must NOT list the file
python deploy_migrations.py --baseline-through <that-file>   # if it does
```
