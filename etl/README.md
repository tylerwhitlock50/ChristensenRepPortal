# etl

Pushes the governed SQL Server `bi.vw_*` views into Supabase (`erp` schema).

- **Pattern:** truncate-and-load per table, inside one transaction each, so
  the app never sees a half-loaded table. Facts and dims are small enough
  (single-site rifle manufacturer) that full reloads beat incremental logic.
- **Schedule:** daily minimum, hourly capable. Hook `push_to_supabase.py`
  into the existing scheduler, or run the container in `../docker`.
- **Post-load:** after a full successful run it rebuilds territory rollups,
  refreshes account signals/scores, and conditionally generates recommendations
  according to `feature.recommendations`. It then best-effort pre-generates AI
  summaries when the required URL and batch secret are configured (see
  `views.yml → post_load_sql` / `post_load_http`).

## Files

- `views.yml` — view→table mapping, snake_case overrides, post-load SQL
- `push_to_supabase.py` — the job (pyodbc → psycopg COPY)
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
