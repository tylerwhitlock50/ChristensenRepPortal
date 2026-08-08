# etl

Pushes the governed SQL Server `bi.vw_*` views into Supabase (`erp` schema).

- **Pattern:** truncate-and-load per table, inside one transaction each, so
  the app never sees a half-loaded table. Facts and dims are small enough
  (single-site rifle manufacturer) that full reloads beat incremental logic.
- **Schedule:** daily minimum, hourly capable. Hook `push_to_supabase.py`
  into the existing scheduler, or run the container in `../docker`.
- **Post-load:** after a full successful run it executes
  `select public.generate_recommendations();` so recommendations are
  generated the moment fresh data lands (see `views.yml → post_load_sql`).

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
  contract: same mapping, same truncate-and-load semantics, same post-load call.

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
