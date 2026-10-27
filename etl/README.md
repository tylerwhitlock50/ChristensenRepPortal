# etl

Pushes the governed SQL Server `bi.vw_*` views into Supabase (`erp` schema).

- **Pattern:** stage-and-swap per table. Each view streams into
  `etl_stage.<table>` (a schema PostgREST never sees), then one short
  transaction swaps it into `erp.<table>`. There is no exclusive lock, so
  a rep querying during a run sees the previous load or this one, never a
  mix and never a lock timeout. Every run still reads the whole view (no
  incremental extract logic). The swap is per table in `views.yml`:
  - `replace`: `DELETE` everything + `INSERT … SELECT` everything.
  - `merge`: delete only the live rows no staged row matches exactly (same
    primary key, same value in every loaded column, NULLs equal), then
    insert the staged rows whose key is gone. Unchanged rows are not
    written at all, which is what makes an hourly tier affordable on Micro
    compute.

  Under merge, `loaded_at` on a merged table means "row last changed". The
  readers were checked: only `v_ats_list` exposes `loaded_at`, and its
  table (`fact_available_to_sell`) stays on replace. `ETL_SWAP_MODE=replace`
  forces replace everywhere.
- **Never loaded:** `exclude_columns` in `views.yml` (`dim_customer.tax_id_number`,
  `dim_customer_contact.salutation`) are dropped from the COPY before any
  row leaves this machine, and the first merge erases values already live.
- **Statement timeout:** the loader sets `statement_timeout` on its own
  session to `ETL_STATEMENT_TIMEOUT` (default `15min`) right after it
  connects, because the project default of 120 s is shorter than
  `refresh_territory_rollups()` takes. It is session-scoped and leaves the
  app roles' 8 s cap alone. A profile's own `statement_timeout` wins: the
  ats profile sets `60s`, so a stuck stock run gives up instead of piling
  up behind itself.
- **Row-count floor:** a view that returns fewer than `ETL_MIN_ROW_RATIO`
  (default 0.5) of its previous successful row count is refused before the
  swap — an empty feed must not zero every rollup. Set it to `0` for a
  known shrink.
- **Schedule:** four Task Scheduler tasks in `\CRM\` on the BI server
  (see [Runbook](#runbook)). They run `push.ps1` with a profile and append
  to that profile's log. `push.ps1` exits with the loader's code and turns
  failures into a webhook alert and a heartbeat ping.
- **Post-load:** after the tables load, the full and hourly profiles run
  `views.yml → post_load_sql` in order: rollup refresh first, then
  scoring/recommendations (full only), then order change capture and order
  QC. Then the run logs one ledger row in `public.job_runs`: `etl:run` for
  full, `etl:run:hourly` for hourly. That row is `success` only when every
  table in the profile AND every required post-load step succeeded. The
  portal's freshness stamp reads it, so a partial run shows as stale
  instead of fresh. Steps marked `optional: true` (statistics, order change
  capture) are logged as `etl:post_load` errors when they fail and never
  hold the stamp back. `post_load_http` (the AI batch) runs after the
  ledger row, only on the 04:30 full run, and never affects it.
- **When post-load runs:** never on a subset run
  (`python push_to_supabase.py dim_customer …`) or an ats run. On a full or
  hourly run: when every table loaded, or — if some failed — when every table in
  `views.yml → post_load_requires` (the tables the post-load steps read:
  `dim_customer`, `dim_part`, `fact_invoice_line`, `fact_order_line`,
  `fact_shipment_line`) loaded. So one failing feed that nothing downstream
  reads (contacts, ATS, inventory) no longer freezes the rollups, signals and
  AI batch; `push.log` prints a `WARNING: … table(s) FAILED` banner first.
  That night's `etl:run` is still `error`: its message names the failed
  tables and ends `post-load ran anyway: …` (or, when a required table
  failed, `post-load skipped: required table(s) did not load: …`), and the
  exit code is still 1. The AI batch runs only when every required
  post-load step succeeded. Without `post_load_requires` every table is
  required (the old rule). Add a table to the list whenever a post-load
  step starts reading it.

## Files

- `views.yml` — view→table mapping, swap mode and `exclude_columns` per
  table, snake_case overrides, the refresh `profiles`, the tables post-load
  needs (`post_load_requires`), post-load SQL and HTTP calls
- `push_to_supabase.py` — the job (pyodbc → psycopg COPY)
- `push.ps1` — what the scheduled tasks run: profile, log, alert, heartbeat
- `push-ats.ps1`, `push-hourly.ps1` — one-line wrappers for a hand run
- `schedule/Register-CrmTasks.ps1` — registers the four `\CRM\` tasks
- `tests/test_push_to_supabase.py` — unit tests (stdlib unittest, no DB):
  `venv\Scripts\python.exe -m unittest discover -s tests -v`
- `tests/merge_integration.py` — proves the merge SQL against Supabase on
  TEMP tables, rolled back (needs `PG_CONN`)
- `deploy_migrations.py` — applies `../supabase/migrations/*.sql` to Supabase
  (same box, same `.env`, needs only `PG_CONN`)
- `requirements.txt` — pinned Python packages, shared by local setup and the ETL container
- `.env.example` — every environment variable, with notes

## Setup

Run from `etl/` with the ETL virtual environment activated:

```bash
python -m pip install -r requirements.txt
cp .env.example .env   # fill in real connection strings
python push_to_supabase.py
```

For the Windows scheduled task's existing environment, install packages with
`venv\Scripts\python.exe -m pip install -r requirements.txt` from `etl/`.
Python and Microsoft ODBC Driver 18 for SQL Server must be installed separately.

Notes:
- `PG_CONN` must use the **direct / session-pooler** connection (port 5432)
  with the `postgres` role (bypasses RLS; COPY, the advisory locks and the
  staging table need a real session). The loader refuses port 6543, the
  transaction pooler, with exit 2. Never the anon key.
- The SQL Server login needs SELECT on schema `bi` only
  (`GRANT SELECT ON SCHEMA::bi TO <etl_login>`).
- Generated columns (`order_date`, `ship_date`, …) are computed by Postgres;
  the job pushes only the columns the view returns.
- If you already have a working push tool + scheduler, `views.yml` is the
  contract: same mapping, same swap semantics, same post-load call.

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

**Prove it first.** `run_sql_guard.py` runs a migration and one of the
`supabase/tests/*.sql` guards in a single transaction against the live
database and rolls it back, so a new file is checked against the real
catalog before the deployer makes it permanent (there is no psql on this
box; the runner strips the tests' psql-isms). Run it from this folder so it
finds `.env` — a git worktree has none of its own:

```bash
venv/Scripts/python.exe run_sql_guard.py ../supabase/migrations/<new>.sql ../supabase/tests/<guard>.sql
venv/Scripts/python.exe run_sql_guard.py ../supabase/tests/<guard>.sql     # the guard alone, against what is live
```

## Runbook

### The four tasks

All four live in Task Scheduler folder `\CRM\` on the BI server. Times are
the server clock, which must be **Mountain Standard Time** (America/Denver).
Each task runs Windows PowerShell 5.1:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<etl>\push.ps1" -Profile …`.

| Task | When | `push.ps1` args | Loads | After the load | Ledger row | Log |
|---|---|---|---|---|---|---|
| ERP push - ATS | Mon–Fri every 15 min, 05:00–17:45 (52 runs) | `-Profile ats -IfIdle` | `fact_available_to_sell` | nothing | none (per-table `etl:erp.fact_available_to_sell` only) | `push-ats.log` |
| ERP push - hourly | Mon–Fri hourly, 06:05–16:05 (11 runs) | `-Profile hourly` | `dim_customer`, `dim_part`, `fact_order_line`, `fact_invoice_line`, `fact_shipment_line` | rollups, their statistics, order change capture, order QC | `etl:run:hourly` | `push-hourly.log` |
| ERP push - full 0430 | daily 04:30, catches up a missed start | `-Profile full` | every table | everything, then the AI batch | `etl:run` | `push.log` |
| ERP push - full 1700 | Mon–Fri 17:00, catches up a missed start | `-Profile full -SkipAi` | every table | everything except the AI batch | `etl:run` | `push.log` |

Every task is set to IgnoreNew (a run still going means the next start is
dropped), has battery conditions off, and runs whether or not anyone is
logged on. Time limits: ATS 10 min, hourly 50 min, full 2 h. Only the two
full tasks catch up a missed start. A missed stock or hourly run is
superseded by the next one, but a missed full run costs a day of scores,
signals and briefings.

The profiles themselves (tables, post-load, ledger, lock, timeout) live in
`views.yml → profiles`. The loader checks them at startup. A profile that
runs post-load without loading every table in `post_load_requires` is a
config error (exit 2) before anything connects.

### Locks and exit codes

- **Core run lock.** `full` and `hourly` hold the session advisory lock
  `hashtextextended('etl:core-run', 0)` for the whole run, so only one
  rollup rebuild happens at a time. The lock is retried every 15 s for the
  profile's `lock_wait_minutes`:
  - full waits 45 min, so the 17:00 run waits out a slow 16:05 hourly.
  - hourly waits 0: if a full run is going, that hour's data arrives with it.

  A run that never gets the lock prints `SKIPPED: … core run lock (pid …)`,
  writes no ledger row and exits 3.
- **Table lock.** Every run, including a hand-run subset, takes
  `hashtextextended('etl:table:' || '<erp.table>', 0)` from the staging
  table's DROP/CREATE through the swap commit, and releases it in
  `finally`.
  - Without `--if-idle` the run waits for the lock. A full run waits a few
    seconds for the stock run to finish.
  - With `--if-idle` (the ATS task) a busy table is skipped and printed,
    with no `job_runs` row. An ATS run whose only table was skipped exits 3.
- **Exit codes:**

  | Code | Meaning |
  |---|---|
  | 0 | OK |
  | 1 | a table or a required post-load step failed |
  | 2 | usage or config error: bad arguments, `views.yml`, `PG_CONN` on port 6543 or not a session |
  | 3 | skipped because busy |
  | 103 | (`push.ps1`) `venv\Scripts\python.exe` is missing |

  Task Scheduler's *Last Run Result* shows the same number (0x3, 0x67, …).
- **A stuck lock.** The locks are session locks, so a killed run's lock
  dies with its connection. Checked 2026-10-26 through the session pooler:
  a client that closed, and one that was killed while holding the lock,
  both left no lock behind within a second, even though Supavisor handed
  the same backend to the next client. If runs keep exiting 3 and nothing is
  running, find the holder. The `SKIPPED` line prints its pid. Then
  terminate it as `postgres`:

  ```sql
  select l.pid, a.state, a.backend_start, a.query
  from pg_locks l join pg_stat_activity a using (pid)
  where l.locktype = 'advisory';
  -- select pg_terminate_backend(<pid>);
  ```

### Pausing the stock (ATS) run

- Task Scheduler → `\CRM\` → *ERP push - ATS* → **Disable**, or
  `Disable-ScheduledTask -TaskPath '\CRM\' -TaskName 'ERP push - ATS'`.
- Enable it again the same way.
- The portal's "Stock as of" time just stops moving while it is off. The
  full runs still load the stock table twice a day.

### A one-off run

Run from `etl\` on the BI server, as the task account or an admin:

```powershell
.\push.ps1                          # full run with the AI batch (push.log)
.\push.ps1 -SkipAi                  # full run, no AI batch
.\push-hourly.ps1                   # = .\push.ps1 -Profile hourly
.\push-ats.ps1                      # = .\push.ps1 -Profile ats -IfIdle
.\push.ps1 -Tables dim_part,fact_order_line   # legacy subset: no post-load, no ledger row
```

Or start a registered task, which uses the same account, logs and alerts:
`Start-ScheduledTask -TaskPath '\CRM\' -TaskName 'ERP push - full 1700'`.

`push.ps1` alerts on a failed hand run exactly as on a scheduled one. A
`-Tables` subset alerts too but sends no heartbeat ping, so it never
stands in for (or fails) the full tier's check. To skip the alert, call
the loader directly:
`venv\Scripts\python.exe -u push_to_supabase.py --profile hourly`.
A subset run (`-Tables`) never rebuilds the rollups. Follow it with a full
or hourly run when the tables feed the Overview.

### Alert setup

`push.ps1` reads these from the environment, then from `etl\.env`:

- `ETL_ALERT_WEBHOOK`: an incoming webhook that accepts `{"text": "…"}`.
  Use a Slack incoming webhook, or a Teams *Workflows* "Post to a channel
  when a webhook request is received" flow. The message names the host,
  profile and exit code, followed by the run's last 15 log lines.
- `ETL_HEARTBEAT_URL_FULL`, `_HOURLY`, `_ATS`: one healthchecks.io check
  per tier. A successful run sends a GET to the URL; a failure sends a GET
  to `<url>/fail`. Suggested settings:

  | Check | Period | Grace | Active hours |
  |---|---|---|---|
  | full | 1 day | 2 h | every day |
  | hourly | 1 h | 30 min | weekdays 06–16 |
  | ats | 15 min | 45 min | weekdays 05–18 |

What gets an alert:

- **Any failure** of full or hourly.
- **Exit 3:**
  - on full it is an alert: the run gave up after waiting 45 min for the
    lock.
  - on hourly or ATS it is only a notice in the log, with no alert and no
    ping. The heartbeat's grace period covers it.
- **ATS:**
  - It alerts and pings `/fail` only from the **3rd consecutive failure**,
    counted in `push-ats.failcount`.
  - It alerts once per streak, then says once when it recovers.
  - A success resets the count to 0.

A failed webhook or ping is logged and never changes the exit code. Logs
roll over to `<log>.1` past 10 MB.

To test the alert path, point `ETL_ALERT_WEBHOOK` at a test channel and run
`.\push.ps1 -Tables no_such_table`. The loader exits 2 ("No tables
matched") and the alert posts.

### Moving to the BI server

1. **Python.** Install a pinned Python (3.14.x, the version
   `requirements.txt` was tested with) for all users. Put it at a path
   Datto RMM does not manage, e.g. `C:\Python\3.14`, not
   `C:\Program Files\Python314`. On 2026-10-26 Datto's managed-software
   pass reinstalled Python elsewhere overnight, and the venv lost its base
   interpreter.
2. **Code.** Put the repo's `etl\` folder on the server, e.g. `D:\crm\etl`.
   Then, from that folder:

   ```powershell
   C:\Python\3.14\python.exe -m venv venv
   venv\Scripts\python.exe -m pip install -r requirements.txt
   ```
3. **ODBC.** Install *Microsoft ODBC Driver 18 for SQL Server*. Use
   `Server=tcp:<host>,1433` in `MSSQL_CONN`.
4. **`.env`.** Copy `.env.example` to `.env` and fill it in. Make it
   readable only by the task account and Administrators:

   ```powershell
   icacls .env /inheritance:r /grant:r "DOMAIN\svc-crm-etl:R" "Administrators:F"
   ```

   A gMSA keeps its trailing `$` here too (`DOMAIN\svc-crm-etl$`). The task
   account also needs Modify on the `etl` folder itself: `push.ps1` writes
   the `push*.log` files and `push-ats.failcount` there. Without it the
   runs still load, but leave no log, and the ATS task can never count to
   its 3rd failure, so it never alerts.
5. **Check it by hand, as the task account:**
   - `venv\Scripts\python.exe -m unittest discover -s tests`
   - then `.\push-ats.ps1`. It should exit 0, and `push-ats.log` should show
     `erp.fact_available_to_sell: … rows`.
6. **Register the tasks.** From an elevated prompt:
   - Preview first: `.\schedule\Register-CrmTasks.ps1 -WhatIf`.
   - Then: `.\schedule\Register-CrmTasks.ps1 -User 'DOMAIN\svc-crm-etl$'`
     for a gMSA, or `-User DOMAIN\svc-crm-etl` to be prompted for its
     password.
   - S4U stores no password, but it has no network credentials, so
     integrated auth to a remote SQL Server fails. Use S4U only with SQL
     auth in `MSSQL_CONN`.
   - The script warns if the time zone is not Mountain.
7. **The same day,** disable the old PC task ("Run CRM update" on Tyler's
   machine). Otherwise both machines load every evening. On that PC, from
   an elevated prompt, run `Disable-ScheduledTask -TaskName 'Run CRM update'`,
   or disable it in Task Scheduler.
   - Do not run `Register-CrmTasks.ps1` there: it would register the four
     tasks on the PC as well.
   - `-DisableLegacyTask` is for a server that also carries the old task.
8. **Watch the first day:**
   - `push-ats.log` fills every 15 min from 05:00.
   - `push-hourly.log` fills at :05 past each hour from 06:05.
   - `push.log` gets a run at 17:00.
   - `public.job_runs` shows `etl:run:hourly` and `etl:run` rows.

**After the ERP's ATS view change (R01–R09 only).** The stock table may
come back with far fewer rows than the last load. If it drops below half,
the row-count floor refuses it (exit 1), and the ATS task alerts after 3
tries. Run it once with the floor off:

```powershell
$env:ETL_MIN_ROW_RATIO = '0'; .\push.ps1 -Profile ats; Remove-Item Env:ETL_MIN_ROW_RATIO
```
