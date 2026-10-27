"""
SQL Server bi.vw_* -> Supabase Postgres erp.* push.

Stage-and-swap, one short swap transaction per table, so readers never see a
half-loaded table and never wait on one either. A full run then runs the
rollup refresh, scoring and QC steps after the last load and logs one
'etl:run' row that the portal's freshness stamp reads.

Usage:
    python push_to_supabase.py                       # full run: every table
    python push_to_supabase.py --profile hourly      # order/invoice/shipment tier
    python push_to_supabase.py --profile ats --if-idle   # stock only
    python push_to_supabase.py --no-http             # full run, no AI batch
    python push_to_supabase.py dim_customer fact_invoice_line   # legacy subset

Profiles (views.yml `profiles:`) say which tables a run loads, whether it
runs post-load and the AI batch, which ledger row it writes and which lock
it takes. A legacy subset (positional table names) is what it always was:
those tables, no post-load, no ledger row. It cannot be combined with a
non-default --profile.

Exit codes (push.ps1 alerts on them):
    0  every table and every required post-load step succeeded
    1  a table, or a required post-load step, failed
    2  usage or configuration error (bad arguments, views.yml, PG_CONN)
    3  skipped because busy: the core run lock stayed taken for the
       profile's lock_wait_minutes, or --if-idle skipped a table another
       run was loading

Environment (see .env.example):
    MSSQL_CONN   ODBC connection string to the SQL Server instance (VECA)
    PG_CONN      Postgres connection string to Supabase, role postgres. Must
                 be a SESSION: the direct connection or the session pooler
                 (port 5432). Port 6543 (transaction pooler) is refused.
    ETL_MIN_ROW_RATIO
                 Refuse a load that returns fewer than this fraction of the
                 rows the previous successful load of the same table had
                 (default 0.5). 0 disables the floor — for a known shrink.
    ETL_STATEMENT_TIMEOUT
                 Per-statement cap for this session (default 15min) when the
                 profile sets no statement_timeout of its own.
    ETL_SWAP_MODE=replace
                 Escape hatch: every table swaps with DELETE + INSERT, as
                 before merge existed, whatever views.yml says.
    ETL_MERGE_WORK_MEM
                 work_mem for a merge swap's transaction (default 64MB;
                 0 = the server's). See merge_work_mem().
    ETL_SKIP_POST_LOAD_HTTP=1
                 Same as --no-http.
    ETL_MSSQL_SNAPSHOT=1
                 Read each view under SNAPSHOT isolation (needs the DBA to
                 enable ALLOW_SNAPSHOT_ISOLATION on VECA first). Off by default.
"""

from __future__ import annotations

import argparse
import io
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import NamedTuple

import pyodbc
import psycopg
import yaml

from dotenv import load_dotenv
from psycopg.conninfo import conninfo_to_dict

load_dotenv()

HERE = os.path.dirname(os.path.abspath(__file__))
BATCH_ROWS = 50_000

# Where a table lands before it is swapped into erp.* — a schema PostgREST
# does not expose and no app role can read (migration 20260901190400).
STAGE_SCHEMA = "etl_stage"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_BUSY = 3

PROFILE_NAMES = ("full", "hourly", "ats")
PROFILE_KEYS = {"tables", "post_load", "http", "ledger", "lock",
                "lock_wait_minutes", "statement_timeout"}
SWAP_MODES = ("replace", "merge")

# What a views.yml without a `profiles:` key means: the full run exactly as
# it was before profiles existed, so an older views.yml keeps working.
DEFAULT_PROFILES = {
    "full": {"tables": "all", "post_load": True, "http": True,
             "ledger": "etl:run", "lock": "core", "lock_wait_minutes": 45},
}

# The supavisor transaction-mode port. A transaction pooler hands each
# transaction to whichever backend is free, so a session advisory lock and
# the staging table would land on one backend and the swap on another.
TRANSACTION_POOLER_PORT = "6543"

# Session advisory locks. One key for "a run that rebuilds the rollups"
# (full and hourly), and one per target table around its staging table and
# swap, so the 15-minute stock run and a full run never DROP each other's
# etl_stage table mid-COPY.
CORE_LOCK_KEY = "etl:core-run"
LOCK_RETRY_SECONDS = 15.0
SQL_TRY_CORE_LOCK = "select pg_try_advisory_lock(hashtextextended('etl:core-run', 0))"
SQL_UNLOCK_CORE = "select pg_advisory_unlock(hashtextextended('etl:core-run', 0))"
SQL_TRY_TABLE_LOCK = "select pg_try_advisory_lock(hashtextextended('etl:table:' || %s, 0))"
SQL_TABLE_LOCK = "select true from pg_advisory_lock(hashtextextended('etl:table:' || %s, 0))"
SQL_UNLOCK_TABLE = "select pg_advisory_unlock(hashtextextended('etl:table:' || %s, 0))"
# Who holds an advisory lock, for the "busy" line. pg_locks splits a bigint
# key into classid (high 32 bits) and objid (low 32 bits), objsubid 1.
SQL_LOCK_HOLDER = """
    select a.pid, a.application_name, a.state, a.backend_start, a.query_start
    from pg_locks l
    join pg_stat_activity a on a.pid = l.pid
    where l.locktype = 'advisory' and l.granted and l.objsubid = 1
      and l.classid = ((hashtextextended(%s, 0) >> 32) & 4294967295)::oid
      and l.objid   = (hashtextextended(%s, 0) & 4294967295)::oid
"""


class LoadRefused(Exception):
    """A load that would have replaced good data with bad. Nothing was swapped."""


class ConfigError(Exception):
    """views.yml, the arguments or the environment are wrong. Exit 2, load nothing."""


def load_config() -> dict:
    with open(os.path.join(HERE, "views.yml"), encoding="utf-8") as f:
        return yaml.safe_load(f)


def to_snake(name: str, overrides: dict[str, str]) -> str:
    if name in overrides:
        return overrides[name]
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", name)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", s)
    return s.lower()


def csv_field(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "t" if v else "f"
    s = str(v)
    if any(c in s for c in (",", '"', "\n", "\r")):
        s = '"' + s.replace('"', '""') + '"'
    return s


def quote_ident(name: str) -> str:
    """A Postgres identifier, always quoted (embedded quotes doubled)."""
    return '"' + str(name).replace('"', '""') + '"'


def qualified(schema: str, name: str) -> str:
    return f"{quote_ident(schema)}.{quote_ident(name)}"


# ---------------------------------------------------------------------------
# Command line, profiles and views.yml validation
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="push_to_supabase.py",
        description="Push the SQL Server bi.vw_* views into Supabase erp.*. "
                    "No arguments: the full run.",
        epilog="Exit codes: 0 ok, 1 a table or required post-load step failed, "
               "2 usage/config error, 3 skipped because busy.",
    )
    p.add_argument("--profile", choices=PROFILE_NAMES, default="full",
                   help="refresh tier from views.yml `profiles:` (default: full)")
    p.add_argument("--if-idle", action="store_true",
                   help="skip a table another run is loading instead of waiting for it")
    p.add_argument("--no-http", action="store_true",
                   help="do not call post_load_http (the AI batch); "
                        "same as ETL_SKIP_POST_LOAD_HTTP=1")
    p.add_argument("tables", nargs="*", metavar="TABLE",
                   help="legacy subset by short name (dim_customer ...): those "
                        "tables only, no post-load, no ledger row")
    return p


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Arguments, or SystemExit(2) with argparse's usage line."""
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.tables and args.profile != "full":
        # A subset is "these tables, nothing after"; a profile is a tier
        # with its own tables, post-load and ledger. Mixing them would make
        # one of the two silently meaningless.
        parser.error(f"table names cannot be combined with --profile {args.profile}: "
                     f"a legacy subset is its own kind of run")
    return args


def env_flag(env, name: str) -> bool:
    return str(env.get(name, "")).strip().lower() in ("1", "true", "yes", "on")


def table_short_name(t: dict) -> str:
    return str(t["target_table"]).split(".")[-1].lower()


def post_load_required_tables(cfg: dict, *, quiet: bool = False) -> set[str] | None:
    """views.yml `post_load_requires`: the target tables post-load reads.

    Post-load used to run only when EVERY table loaded. That kept the
    rollups from being rebuilt over a mix of old and new facts, but it also
    meant one table nothing downstream reads (a contact list, the ATS feed)
    failing night after night froze every rollup, the account signals and
    the AI batch while the fact tables kept moving — October 2026: ten days
    of a stale Overview over current invoices. With this key, post-load runs
    when every table it names loaded in this run, whatever else failed.

    None (the key absent, or an empty list) means every table is required —
    exactly the behaviour before the key existed, so an older views.yml
    keeps working unchanged. Names are compared lower-cased. A name no
    `tables` entry loads (a typo, a removed table) can never be satisfied:
    post-load then waits for a run where every table loads, which is the
    old rule — safe, but it is printed so it does not go unnoticed.
    """
    entries = cfg.get("post_load_requires")
    if not entries:
        return None
    requires = {str(t).strip().lower() for t in entries}
    known = {str(t["target_table"]).lower() for t in cfg.get("tables") or []}
    unknown = sorted(requires - known)
    if unknown and not quiet:
        print(f"views.yml post_load_requires names {', '.join(unknown)}, which no "
              f"`tables` entry loads — post-load will run only when every table "
              f"loads", file=sys.stderr)
    return requires


def validate_config(cfg: dict) -> dict[str, dict]:
    """Every profile in views.yml, normalised — or ConfigError (exit 2).

    Checked up front, before any connection, because a scheduled task that
    loads tables and only then finds its profile cannot run post-load has
    already spent the ERP read and still leaves the stamp where it was. All
    profiles are checked on every run, not just the one asked for: a broken
    hourly profile then fails the 15-minute stock run too, where it is seen
    the same hour instead of at the next hourly start.

    The rule that matters: a profile that runs post-load must load every
    table post-load reads (`post_load_requires`, or every table when that
    key is absent). Otherwise its post-load would rebuild the rollups over
    tables it never refreshed — or, by the post-load rule, never run at all.
    """
    tables = cfg.get("tables") or []
    if not tables:
        raise ConfigError("views.yml has no `tables`")
    known = [str(t["target_table"]).lower() for t in tables]
    for t in tables:
        swap = t.get("swap")
        if swap is not None and str(swap).lower() not in SWAP_MODES:
            raise ConfigError(f"views.yml {t['target_table']}: swap must be one of "
                              f"{', '.join(SWAP_MODES)}, not {swap!r}")
        excl = t.get("exclude_columns")
        if excl is not None and (not isinstance(excl, list)
                                 or not all(isinstance(c, str) and c for c in excl)):
            raise ConfigError(f"views.yml {t['target_table']}: exclude_columns must "
                              f"be a list of target column names")

    raw = cfg.get("profiles")
    if raw is None:
        raw = DEFAULT_PROFILES
    if not isinstance(raw, dict) or not raw:
        raise ConfigError("views.yml profiles: must map a profile name to its settings")

    requires = post_load_required_tables(cfg, quiet=True)
    # Names no table loads are already warned about at run time and can
    # never be met; coverage is judged on the ones that can.
    requires_known = None if requires is None else requires & set(known)

    profiles: dict[str, dict] = {}
    for name, p in raw.items():
        where = f"views.yml profiles.{name}"
        if not isinstance(p, dict):
            raise ConfigError(f"{where}: must be a mapping")
        unknown_keys = sorted(set(p) - PROFILE_KEYS)
        if unknown_keys:
            raise ConfigError(f"{where}: unknown key(s) {', '.join(unknown_keys)} "
                              f"(allowed: {', '.join(sorted(PROFILE_KEYS))})")

        sel = p.get("tables", "all")
        if sel == "all":
            chosen = list(known)
        elif isinstance(sel, list) and sel:
            chosen = [str(x).strip().lower() for x in sel]
            missing = sorted(set(chosen) - set(known))
            if missing:
                raise ConfigError(f"{where}.tables: {', '.join(missing)} "
                                  f"is not a `tables` entry")
        else:
            raise ConfigError(f"{where}.tables: must be `all` or a list of target tables")

        for flag in ("post_load", "http"):
            if not isinstance(p.get(flag, False), bool):
                raise ConfigError(f"{where}.{flag}: must be true or false")
        post_load = bool(p.get("post_load", False))
        http = bool(p.get("http", False))
        if http and not post_load:
            raise ConfigError(f"{where}: http needs post_load — the AI batch reads "
                              f"what post-load rebuilds")

        ledger = p.get("ledger")
        if ledger is not None and (not isinstance(ledger, str) or not ledger.strip()):
            raise ConfigError(f"{where}.ledger: must be a job name or null")
        lock = p.get("lock")
        if lock not in (None, "core"):
            raise ConfigError(f"{where}.lock: must be `core` or null, not {lock!r}")
        wait = p.get("lock_wait_minutes", 0)
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or wait < 0:
            raise ConfigError(f"{where}.lock_wait_minutes: must be a number >= 0")
        timeout = p.get("statement_timeout")
        if timeout is not None and (not isinstance(timeout, str) or not timeout.strip()):
            raise ConfigError(f"{where}.statement_timeout: must be a Postgres "
                              f"interval like 60s, or absent")

        if post_load:
            if requires_known is None:
                if set(chosen) != set(known):
                    raise ConfigError(
                        f"{where}: runs post-load over a subset of tables, but "
                        f"views.yml has no post_load_requires, so post-load needs "
                        f"every table. Add post_load_requires or load every table.")
            else:
                uncovered = sorted(requires_known - set(chosen))
                if uncovered:
                    raise ConfigError(
                        f"{where}: runs post-load but does not load "
                        f"{', '.join(uncovered)} (post_load_requires). Its rollups "
                        f"would be rebuilt over tables this run never refreshed.")

        profiles[name] = {
            "tables": chosen,
            "post_load": post_load,
            "http": http,
            "ledger": ledger.strip() if isinstance(ledger, str) else None,
            "lock": lock,
            "lock_wait_minutes": float(wait),
            "statement_timeout": timeout.strip() if isinstance(timeout, str) else None,
        }

    for entry in cfg.get("post_load_sql") or []:
        if isinstance(entry, dict) and entry.get("profiles") is not None:
            names = entry["profiles"]
            if not isinstance(names, list) or not names:
                raise ConfigError(f"views.yml post_load_sql {entry.get('sql')!r}: "
                                  f"profiles must be a list of profile names")
            undefined = sorted(set(map(str, names)) - set(profiles))
            if undefined:
                raise ConfigError(f"views.yml post_load_sql {entry.get('sql')!r}: "
                                  f"profile(s) {', '.join(undefined)} not defined")
    return profiles


@dataclass(frozen=True)
class RunPlan:
    """What this invocation does, resolved from the arguments and views.yml."""
    profile: str               # full | hourly | ats; "subset" for a legacy list
    tables: list               # views.yml `tables` entries, in views.yml order
    post_load: bool
    http: bool
    ledger: str | None         # job_runs row for the run as a whole
    lock: str | None           # "core" or None
    lock_wait_minutes: float
    statement_timeout: str | None
    if_idle: bool


def resolve_plan(cfg: dict, args: argparse.Namespace, env=os.environ) -> RunPlan:
    """The run plan, or ConfigError (exit 2)."""
    profiles = validate_config(cfg)

    forced = str(env.get("ETL_SWAP_MODE", "")).strip().lower()
    if forced not in ("", "replace"):
        raise ConfigError(f"ETL_SWAP_MODE={forced!r}: the only override is `replace` "
                          f"(unset it to use views.yml's swap per table)")

    if args.tables:
        # Legacy subset, exactly as before profiles: the named tables, no
        # post-load (part of tonight's data is not a refresh), no ledger row,
        # no core lock. The per-table lock still applies: a hand-run subset
        # must not DROP a staging table a scheduled run is filling.
        only = {a.lower() for a in args.tables}
        tables = [t for t in cfg["tables"] if table_short_name(t) in only]
        unknown = sorted(only - {table_short_name(t) for t in cfg["tables"]})
        if not tables:
            raise ConfigError(f"No tables matched {sorted(only)}")
        if unknown:
            print(f"ignoring unknown table name(s): {', '.join(unknown)}", file=sys.stderr)
        return RunPlan(profile="subset", tables=tables, post_load=False, http=False,
                       ledger=None, lock=None, lock_wait_minutes=0.0,
                       statement_timeout=None, if_idle=args.if_idle)

    if args.profile not in profiles:
        raise ConfigError(f"profile {args.profile!r} is not defined in views.yml profiles")
    p = profiles[args.profile]
    wanted = set(p["tables"])
    tables = [t for t in cfg["tables"] if str(t["target_table"]).lower() in wanted]
    http = p["http"] and not args.no_http and not env_flag(env, "ETL_SKIP_POST_LOAD_HTTP")
    return RunPlan(profile=args.profile, tables=tables, post_load=p["post_load"],
                   http=http, ledger=p["ledger"], lock=p["lock"],
                   lock_wait_minutes=p["lock_wait_minutes"],
                   statement_timeout=p["statement_timeout"], if_idle=args.if_idle)


def swap_mode(table_cfg: dict, env=os.environ) -> str:
    """replace (DELETE + INSERT) or merge, per views.yml; ETL_SWAP_MODE=replace wins."""
    if str(env.get("ETL_SWAP_MODE", "")).strip().lower() == "replace":
        return "replace"
    return str(table_cfg.get("swap") or "replace").lower()


def post_load_steps(entries, profile: str | None = None) -> list[tuple[str, bool]]:
    """views.yml `post_load_sql` as (sql, optional) pairs, for one profile.

    A plain string is a required step: if it raises, the list stops there
    (later steps read what it should have produced) and the run's ledger row
    is logged as an error. `{sql: ..., optional: true}` is housekeeping —
    planner statistics, change capture: a failure is logged as
    'etl:post_load' and printed, and the list carries on. It never counts
    against the run, so the freshness stamp still moves when the data and
    rollups landed (and a step whose migration is not applied yet cannot
    hold the stamp back every night).

    `{sql: ..., profiles: [full]}` runs only in those profiles; without the
    key a step runs in every profile that runs post-load. The scoring and
    recommendation steps are full-only: an account's signals are 12/24-month
    figures that do not move hour to hour, and they are the expensive part.
    profile None returns every step (the behaviour before profiles).
    """
    steps: list[tuple[str, bool]] = []
    for entry in entries or []:
        if isinstance(entry, dict):
            only = entry.get("profiles")
            if profile is not None and only is not None and profile not in only:
                continue
            steps.append((str(entry["sql"]), bool(entry.get("optional"))))
        else:
            steps.append((str(entry), False))
    return steps


# ---------------------------------------------------------------------------
# Connections, the session guard and locks
# ---------------------------------------------------------------------------

def session_mode_problem(conninfo: str, env=os.environ) -> str | None:
    """Why PG_CONN cannot be used, or None. Never echoes the string itself."""
    try:
        params = conninfo_to_dict(conninfo)
    except Exception:  # the message can quote the string, password and all
        return "PG_CONN does not parse as a libpq connection string or URI"
    ports = str(params.get("port") or env.get("PGPORT") or "5432")
    if TRANSACTION_POOLER_PORT in [p.strip() for p in ports.split(",")]:
        return ("PG_CONN uses port 6543, the transaction pooler. The loader needs "
                "one session for the whole run (advisory locks, the staging table): "
                "use the session pooler on port 5432 or the direct connection.")
    return None


def backend_is_stable(pg) -> bool:
    """Same backend across two transactions — i.e. we really hold a session.

    The port check catches the usual mistake; this catches the rest (a
    pooler in transaction mode on another port, a proxy). Without a stable
    backend a session advisory lock is taken on one backend and "released"
    on another, and the staging table filled in one transaction is missing
    in the next.
    """
    with pg.transaction():
        first = pg.execute("select pg_backend_pid()").fetchone()[0]
    with pg.transaction():
        second = pg.execute("select pg_backend_pid()").fetchone()[0]
    return first == second


def mssql_connect():
    """The SQL Server connection, read-committed as always unless opted in.

    ETL_MSSQL_SNAPSHOT=1: autocommit, then SNAPSHOT isolation for the
    session, so each view's SELECT is one consistent snapshot that neither
    blocks nor is blocked by ERP writers — and, being autocommit, releases
    its row versions as soon as that SELECT finishes instead of holding the
    version store for the whole run. It needs ALLOW_SNAPSHOT_ISOLATION on
    the database (a DBA decision), so it is off by default. The SET is
    session-scoped in SQL Server: once, before the first SELECT, covers
    every view this connection reads.
    """
    if env_flag(os.environ, "ETL_MSSQL_SNAPSHOT"):
        ms = pyodbc.connect(os.environ["MSSQL_CONN"], autocommit=True)
        ms.execute("SET TRANSACTION ISOLATION LEVEL SNAPSHOT")
        print("SQL Server reads: SNAPSHOT isolation (ETL_MSSQL_SNAPSHOT=1)")
        return ms
    return pyodbc.connect(os.environ["MSSQL_CONN"])


def lock_holder(pg, key: str) -> str:
    """'pid 123 (etl push hourly, active since 05:01:02)' or '' — for the busy line."""
    try:
        with pg.transaction():
            row = pg.execute(SQL_LOCK_HOLDER, (key, key)).fetchone()
    except Exception:
        return ""
    if not row:
        return ""
    pid, app, state, backend_start, query_start = row
    since = backend_start.strftime("%Y-%m-%d %H:%M:%S") if backend_start else "?"
    return f"pid {pid} ({app or 'no application_name'}, {state}, connected since {since})"


def acquire_core_lock(pg, wait_minutes: float, *, sleep=time.sleep,
                      clock=time.monotonic, retry_seconds: float = LOCK_RETRY_SECONDS) -> bool:
    """Take the core run lock, retrying every 15 s for up to wait_minutes.

    Full and hourly both rebuild the rollups and both write the facts those
    rollups read, so only one of them runs at a time. The full run waits
    (45 min): the 17:00 run outlasts a slow 16:05 hourly. The hourly run
    does not (0): if a full run is going, this hour's data arrives with it.
    A session lock, so a crashed run's lock dies with its connection.
    """
    deadline = clock() + max(0.0, float(wait_minutes)) * 60
    announced = False
    while True:
        with pg.transaction():
            got = bool(pg.execute(SQL_TRY_CORE_LOCK).fetchone()[0])
        if got:
            if announced:
                print("core run lock acquired")
            return True
        remaining = deadline - clock()
        if remaining <= 0:
            return False
        if not announced:
            holder = lock_holder(pg, CORE_LOCK_KEY)
            print(f"core run lock busy{' — held by ' + holder if holder else ''}; "
                  f"retrying every {retry_seconds:.0f}s for up to {wait_minutes:g} min")
            announced = True
        sleep(min(retry_seconds, remaining))


def release_core_lock(pg) -> None:
    try:
        with pg.transaction():
            pg.execute(SQL_UNLOCK_CORE)
    except Exception:  # closing the connection releases it anyway
        pass


def lock_table(pg, target_table: str, *, wait: bool) -> bool:
    """The per-table lock around staging + swap. wait=False: try once."""
    with pg.transaction():
        if wait:
            pg.execute(SQL_TABLE_LOCK, (target_table,)).fetchone()
            return True
        return bool(pg.execute(SQL_TRY_TABLE_LOCK, (target_table,)).fetchone()[0])


def unlock_table(pg, target_table: str) -> None:
    try:
        with pg.transaction():
            pg.execute(SQL_UNLOCK_TABLE, (target_table,))
    except Exception:  # a broken connection has already released it
        pass


# ---------------------------------------------------------------------------
# Loading one table
# ---------------------------------------------------------------------------

def log_job_run(pg, job_name, started_at, status, rows=None, error=None):
    try:
        with pg.transaction():
            pg.execute(
                "select public.log_job_run(%s, %s, %s, %s, %s)",
                (job_name, status, rows, error, started_at),
            )
    except Exception as exc:  # audit failure must not fail the load itself
        print(f"job_runs logging failed for {job_name}: {exc}", file=sys.stderr)


def last_good_rows(pg, job_name: str) -> int | None:
    # A transaction block, not execute + commit: if this read fails, the
    # block rolls back, so the table's lock release and the next table do
    # not inherit an aborted transaction.
    with pg.transaction():
        row = pg.execute(
            """
            select rows_affected from public.job_runs
            where job_name = %s and status = 'success' and rows_affected is not null
            order by finished_at desc limit 1
            """,
            (job_name,),
        ).fetchone()
    return int(row[0]) if row else None


def statement_timeout(profile_timeout: str | None = None) -> str:
    """The profile's statement_timeout if it sets one (ats: 60s — a stock
    run that cannot finish in a minute should give up, not pile up behind
    itself every 15 minutes); otherwise ETL_STATEMENT_TIMEOUT (default
    15min). Per-statement cap for this session, loads and post-load steps
    alike. Any Postgres interval text."""
    if profile_timeout:
        return profile_timeout
    return os.environ.get("ETL_STATEMENT_TIMEOUT", "15min").strip() or "15min"


def min_row_ratio() -> float:
    try:
        return float(os.environ.get("ETL_MIN_ROW_RATIO", "0.5"))
    except ValueError:
        return 0.5


def merge_work_mem() -> str | None:
    """ETL_MERGE_WORK_MEM (default 64MB): work_mem for the merge swap only.

    The merge DELETE is a hash anti-join that hashes the live table's
    loaded columns — 120–145 MB of tuple data for each big fact (sampled
    2026-10-26). At the project's 2184kB work_mem that hash spills nearly
    all of it to temp files, then reads it back: ~250 MB of temp writes per
    fact, ~750 MB per hourly run, which is much of the disk IO merge exists
    to save. SET LOCAL in the swap transaction, so it ends with the commit;
    one ETL backend at a time (the core lock), never the app's sessions.
    64MB (128MB of hash memory) keeps the dims in memory and halves the
    facts' spill without betting Micro's 1 GB on one query. `0` or
    `default` leaves the server's setting.
    """
    v = os.environ.get("ETL_MERGE_WORK_MEM", "64MB").strip()
    return None if v.lower() in ("", "0", "default") else v


def loaded_columns(src_cols: list[str], exclude) -> tuple[list[str], list[int] | None, list[str]]:
    """(columns to COPY, their positions in the source row, excludes not in the source).

    views.yml `exclude_columns` names target columns that must never reach
    Supabase (a tax ID, a card number typed into a salutation field — see
    migration 20261027090000). They are dropped from the COPY column list
    and from every row, so the value is never sent, not merely hidden.
    Positions are None when nothing is excluded: the row is used as is.
    """
    drop = {c.lower() for c in (exclude or [])}
    if not drop:
        return list(src_cols), None, []
    keep = [i for i, c in enumerate(src_cols) if c.lower() not in drop]
    present = {c.lower() for c in src_cols}
    return [src_cols[i] for i in keep], keep, sorted(drop - present)


def csv_line(row, keep: list[int] | None) -> str:
    fields = row if keep is None else [row[i] for i in keep]
    return ",".join(csv_field(v) for v in fields) + "\n"


class TableShape(NamedTuple):
    columns: list[str]          # every live column, in table order
    pk: list[str]               # primary key columns in key order; [] if none
    generated: set[str]         # GENERATED ALWAYS AS … STORED
    defaulted: set[str]         # columns with a DEFAULT (loaded_at)


SQL_TABLE_SHAPE = """
    select a.attname,
           a.attgenerated <> ''                    as is_generated,
           a.atthasdef and a.attgenerated = ''     as has_default,
           (select k.ord
              from pg_index i
              cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
             where i.indrelid = a.attrelid and i.indisprimary
               and k.attnum = a.attnum)            as pk_position
    from pg_attribute a
    where a.attrelid = %s::regclass and a.attnum > 0 and not a.attisdropped
    order by a.attnum
"""


def table_shape(pg, relation: str) -> TableShape:
    """Columns, primary key (from pg_index), generated and defaulted columns."""
    rows = pg.execute(SQL_TABLE_SHAPE, (relation,)).fetchall()
    pk = [r[0] for r in sorted((r for r in rows if r[3] is not None), key=lambda r: r[3])]
    return TableShape(columns=[r[0] for r in rows], pk=pk,
                      generated={r[0] for r in rows if r[1]},
                      defaulted={r[0] for r in rows if r[2]})


def unsupplied_null_columns(shape: TableShape, loaded: list[str]) -> list[str]:
    """Live columns the load leaves NULL: not loaded, not generated, no default.

    Under replace these come back NULL on every row (exclude_columns, or a
    column the view stopped publishing). Merge must land in the same place,
    so a live row still holding a value there counts as changed — that is
    what erases tax_id_number and salutation on the first merge after they
    were excluded, without waiting for a migration. Defaulted columns
    (loaded_at) are left out: their stage value is "now", never equal.
    """
    supplied = set(loaded)
    return [c for c in shape.columns
            if c not in supplied and c not in shape.generated and c not in shape.defaulted]


class MergeSQL(NamedTuple):
    analyze: str
    delete: str
    insert: str
    drop: str


def build_merge_sql(live: tuple[str, str], stage: tuple[str, str], pk: list[str],
                    columns: list[str], null_columns=()) -> MergeSQL:
    """The merge swap's statements. Pure: no connection, unit-tested.

    DELETE every live row that no staged row matches exactly — same primary
    key and the same value in every LOADED column, NULLs equal (IS NOT
    DISTINCT FROM) — then INSERT every staged row whose key is no longer
    live. Unchanged rows are not touched: no new tuple, no index entry, no
    WAL, no dead row for autovacuum. That is the whole point on Micro
    compute: an hourly run writes the few thousand rows that changed, not
    1.5M.

    Only loaded columns are compared. Generated columns (order_date, …) are
    functions of loaded ones, and defaulted columns (loaded_at) would differ
    on every row and rewrite the table. Consequence, by design: loaded_at
    on a merged table is when the row last CHANGED, not the last load (the
    readers were checked when merge was chosen — views.yml). null_columns
    (unsupplied_null_columns) must be NULL in live for a row to survive.
    The primary key is compared by equality and left out of the row
    comparison; it cannot be NULL.
    """
    if not pk:
        raise ValueError("merge needs a primary key")
    missing = [c for c in pk if c not in columns]
    if missing:
        raise ValueError(f"primary key column(s) {', '.join(missing)} are not loaded")
    live_rel = qualified(*live)
    stage_rel = qualified(*stage)
    cols = ", ".join(quote_ident(c) for c in columns)
    s_cols = ", ".join(f"s.{quote_ident(c)}" for c in columns)
    key_eq = " AND ".join(f"s.{quote_ident(c)} = l.{quote_ident(c)}" for c in pk)
    compare = [c for c in columns if c not in pk]
    match = key_eq
    if compare:
        match += (f"\n      AND ROW({', '.join(f's.{quote_ident(c)}' for c in compare)})"
                  f"\n          IS NOT DISTINCT FROM"
                  f"\n          ROW({', '.join(f'l.{quote_ident(c)}' for c in compare)})")
    for c in null_columns:
        match += f"\n      AND l.{quote_ident(c)} IS NULL"
    return MergeSQL(
        analyze=f"ANALYZE {stage_rel}",
        delete=(f"DELETE FROM {live_rel} AS l\n"
                f"WHERE NOT EXISTS (\n"
                f"    SELECT 1 FROM {stage_rel} AS s\n"
                f"    WHERE {match}\n)"),
        insert=(f"INSERT INTO {live_rel} ({cols})\n"
                f"SELECT {s_cols} FROM {stage_rel} AS s\n"
                f"WHERE NOT EXISTS (\n"
                f"    SELECT 1 FROM {live_rel} AS l\n"
                f"    WHERE {key_eq}\n)"),
        drop=f"DROP TABLE {stage_rel}",
    )


def run_merge(cur, m: MergeSQL, *, drop_stage: bool = True) -> tuple[int, int]:
    """Execute a MergeSQL on a cursor inside the caller's transaction.

    ANALYZE first: the stage is a fresh unlogged table with no statistics,
    and both anti-joins are planned from its row estimate. Returns
    (deleted, inserted).
    """
    cur.execute(m.analyze)
    cur.execute(m.delete)
    deleted = cur.rowcount
    cur.execute(m.insert)
    inserted = cur.rowcount
    if drop_stage:
        cur.execute(m.drop)
    return deleted, inserted


def check_merged_rows(cur, live_rel: str, target_table: str, staged: int) -> None:
    """After a merge, the live table must hold exactly the staged row count.

    Replace fails loudly on a source that repeats a primary key: its INSERT
    hits the key. Merge does not when one of the repeats equals the live
    row — that row is kept, the NOT EXISTS skips every repeat, and the swap
    would "succeed" a row short while job_runs logs the staged count (a
    fan-out in a view's join is exactly that). Raising inside the swap
    transaction rolls it back, so the table fails as it would under
    replace. The count is an index-only scan of the smallest index:
    ~15–30 MB on the big facts (2026-10-26), a fraction of the merge's own
    scan of the live table.
    """
    live_rows = cur.execute(f"SELECT count(*) FROM {live_rel}").fetchone()[0]
    if live_rows != staged:
        raise LoadRefused(
            f"{target_table}: merge would leave {live_rows} live rows but the source "
            f"returned {staged} — a primary key repeated in the source? Swap rolled "
            f"back; live table left untouched."
        )


class Pushed(NamedTuple):
    rows: int                  # rows staged = rows the source returned
    swap: str                  # replace | merge (after any fallback)
    deleted: int | None = None
    inserted: int | None = None


def push_table(ms, pg, source_view: str, target_table: str, overrides: dict,
               floor_rows: int | None, *, exclude=(), swap: str = "replace") -> Pushed:
    """Stream one view into a staging table, then swap it into the live one.

    Two transactions on purpose. The first holds only the staging table
    while it waits on SQL Server (tens of seconds for the big facts); the
    live table is untouched and readers are unaffected. The second is the
    swap — no ACCESS EXCLUSIVE lock either way, so a rep's query blocks on
    nothing and sees the previous load or this one, never a mix and never a
    lock timeout. (TRUNCATE would be faster, but it takes the exclusive lock
    for the whole local copy, and the authenticator role gives up after
    8 s.)

    swap: replace — DELETE every row, INSERT … SELECT every staged row. Simple
    and the escape hatch, but it rewrites the whole table: ~1.2 GB written
    per full run across the three big facts, fine nightly, not hourly.
    swap: merge — build_merge_sql: only rows that changed are deleted and
    re-inserted. Needs the live table's primary key; without one it falls
    back to replace with a warning. A merge that would leave a live row
    count other than the staged one is rolled back (check_merged_rows), as
    replace's INSERT would fail on the same source. Either way the row
    count returned is the staged count, so the row floor reads it exactly
    as before.
    """
    schema, name = target_table.split(".", 1)
    stage = qualified(STAGE_SCHEMA, name)
    live = qualified(schema, name)

    cur = ms.cursor()
    cur.execute(f"SELECT * FROM {source_view}")
    src_cols = [to_snake(d[0], overrides) for d in cur.description]
    cols, keep, absent = loaded_columns(src_cols, exclude)
    if absent:
        print(f"{target_table}: exclude_columns {', '.join(absent)} not in "
              f"{source_view} — nothing to drop", file=sys.stderr)
    col_list = ", ".join(quote_ident(c) for c in cols)

    total = 0
    with pg.transaction():
        pcur = pg.cursor()
        # Fresh each run so a column added to the live table by a migration
        # is picked up, not a stale staging shape from last night.
        pcur.execute(f"DROP TABLE IF EXISTS {stage}")
        pcur.execute(
            f"CREATE UNLOGGED TABLE {stage} (LIKE {live} INCLUDING DEFAULTS)"
        )
        copy_sql = (
            f"COPY {stage} ({col_list}) "
            f"FROM STDIN WITH (FORMAT csv, NULL '')"
        )
        with pcur.copy(copy_sql) as copy:
            while True:
                rows = cur.fetchmany(BATCH_ROWS)
                if not rows:
                    break
                buf = io.StringIO()
                for row in rows:
                    buf.write(csv_line(row, keep))
                copy.write(buf.getvalue())
                total += len(rows)

    # A source view that comes back empty (or nearly) is a broken feed, not
    # a business event: committing it would zero every rollup and delete
    # every account signal downstream. Refuse before the swap.
    ratio = min_row_ratio()
    if floor_rows and ratio > 0 and total < floor_rows * ratio:
        raise LoadRefused(
            f"{target_table}: source returned {total} rows, last good load had "
            f"{floor_rows} (floor {ratio:.0%}). Live table left untouched. "
            f"Set ETL_MIN_ROW_RATIO=0 to force."
        )

    with pg.transaction():
        pcur = pg.cursor()
        merge_sql = None
        if swap == "merge":
            shape = table_shape(pcur, live)
            try:
                merge_sql = build_merge_sql(
                    (schema, name), (STAGE_SCHEMA, name), shape.pk, cols,
                    unsupplied_null_columns(shape, cols))
            except ValueError as exc:
                print(f"{target_table}: cannot merge ({exc}) — swapping with replace",
                      file=sys.stderr)
        if merge_sql is not None:
            mem = merge_work_mem()
            if mem:
                pcur.execute("select set_config('work_mem', %s, true)", (mem,))
            deleted, inserted = run_merge(pcur, merge_sql)
            check_merged_rows(pcur, live, target_table, total)
            return Pushed(total, "merge", deleted, inserted)
        pcur.execute(f"DELETE FROM {live}")
        # Generated columns (order_date, ship_date, …) are computed by
        # Postgres on insert — copy only the columns the source supplied.
        pcur.execute(f"INSERT INTO {live} ({col_list}) SELECT {col_list} FROM {stage}")
        pcur.execute(f"DROP TABLE {stage}")
    return Pushed(total, "replace")


class LoadResult(NamedTuple):
    loaded: set                # target tables (lower-case) that loaded
    failed_tables: list
    failures: list             # "table: message" lines for the ledger
    skipped: list              # busy under --if-idle: no job_runs row
    total_rows: int


def load_tables(pg, ms, plan: RunPlan, overrides: dict, env=os.environ, *,
                push=push_table) -> LoadResult:
    """Load every table in the plan, each under its own advisory lock.

    The lock covers the staging table's DROP/CREATE through the swap commit.
    Without --if-idle a run waits for it (a full run waits seconds for the
    stock run to finish its table); with it, a busy table is skipped and
    printed — no job_runs row, since nothing was attempted — and the run
    exits 3 if nothing failed.
    """
    loaded: set[str] = set()
    failed_tables: list[str] = []
    failures: list[str] = []
    skipped: list[str] = []
    total_rows = 0
    for t in plan.tables:
        target = t["target_table"]
        started = time.monotonic()
        started_at = datetime.now(timezone.utc)
        job_name = f"etl:{target}"
        try:
            if not lock_table(pg, target, wait=not plan.if_idle):
                skipped.append(target)
                print(f"{target}: skipped — another run is loading it (--if-idle)")
                continue
        except Exception as exc:  # e.g. the profile's statement_timeout while waiting
            failures.append(f"{target}: lock: {exc}")
            failed_tables.append(target)
            log_job_run(pg, job_name, started_at, "error", None, f"lock: {exc}")
            print(f"{target}: FAILED waiting for its lock — {exc}", file=sys.stderr)
            continue
        try:
            floor_rows = last_good_rows(pg, job_name)
            res = push(ms, pg, t["source_view"], target, overrides, floor_rows,
                       exclude=t.get("exclude_columns") or (), swap=swap_mode(t, env))
            total_rows += res.rows
            loaded.add(target.lower())
            log_job_run(pg, job_name, started_at, "success", res.rows)
            merged = (f" — merged: -{res.deleted} +{res.inserted}"
                      if res.swap == "merge" else "")
            print(f"{target}: {res.rows} rows in {time.monotonic() - started:.1f}s{merged}")
        except Exception as exc:  # keep loading the rest; report at the end
            failures.append(f"{target}: {exc}")
            failed_tables.append(target)
            log_job_run(pg, job_name, started_at, "error", None, str(exc))
            print(f"{target}: FAILED — {exc}", file=sys.stderr)
        finally:
            unlock_table(pg, target)
    return LoadResult(loaded, failed_tables, failures, skipped, total_rows)


def exit_code(failures: list, skipped: list) -> int:
    if failures:
        return EXIT_FAILED
    if skipped:
        return EXIT_BUSY
    return EXIT_OK


def post_load_http(call):
    """Fire a post-load Edge Function, e.g. the nightly AI summary batch.

    Deliberately best-effort: the ERP data is loaded and the recommendations
    are generated by the time this runs, so a summary batch that fails — or a
    missing secret on a dev box — must not mark the whole load failed. It logs
    loudly and moves on; the function is idempotent and the next run picks up
    whatever it missed.

    Kept here rather than in pg_cron + pg_net because this is already the
    sanctioned nightly hook and it already knows whether the tables and
    post-load steps the batch reads landed cleanly (TECH_STACK §4.2). A
    separate schedule is a second thing to drift.

    `repeat_until_idle: N` (optional, views.yml) calls the function again
    while its JSON reply reports progress — `generated + checked > 0` — at
    most N calls in all. It exists for ai-summary-batch, which does a small
    bounded slice per call so each request stays well inside the Edge
    Function time limit; the function skips what it already wrote or looked
    at tonight (`checked`: unchanged, too thin or failed accounts it stamped),
    so each repeat picks up the next accounts and a reply with neither means
    there is nothing left to look at. A function without `checked` (older
    deploy) is judged on `generated` alone. Without the key: one call,
    exactly as before. A failed call ends the loop — the next night picks up
    the rest.
    """
    import json
    import urllib.error
    import urllib.request

    name = call["function"]
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    secret = os.environ.get("AI_BATCH_SECRET", "")
    if not base or not secret:
        print(f"post_load_http: skipping {name} — SUPABASE_URL/AI_BATCH_SECRET not set",
              file=sys.stderr)
        return

    try:
        max_calls = max(1, int(call.get("repeat_until_idle") or 1))
    except (TypeError, ValueError):
        max_calls = 1

    body = json.dumps(call.get("body") or {}).encode()
    for attempt in range(1, max_calls + 1):
        req = urllib.request.Request(
            f"{base}/functions/v1/{name}",
            data=body,
            headers={"content-type": "application/json", "x-batch-secret": secret},
            method="POST",
        )
        label = name if max_calls == 1 else f"{name} [{attempt}/{max_calls}]"
        try:
            # Generous: a call makes up to a few dozen model calls before replying.
            with urllib.request.urlopen(req, timeout=900) as res:
                reply = res.read().decode()
                print(f"post_load_http: {label} -> {reply[:400]}")
        except urllib.error.HTTPError as exc:
            print(f"post_load_http: {label} FAILED {exc.code} — {exc.read().decode()[:400]}",
                  file=sys.stderr)
            return
        except Exception as exc:
            print(f"post_load_http: {label} FAILED — {exc}", file=sys.stderr)
            return

        if attempt == max_calls:
            break
        try:
            parsed = json.loads(reply) or {}
            progress = int(parsed.get("generated") or 0) + int(parsed.get("checked") or 0)
        except (ValueError, TypeError, AttributeError):
            progress = 0
        if progress <= 0:
            break


def fmt_elapsed(seconds: float) -> str:
    m, s = divmod(int(round(seconds)), 60)
    h, m = divmod(m, 60)
    return f"{h}h {m}m {s}s" if h else f"{m}m {s}s"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)  # SystemExit(2) on a usage error
    run_started = time.monotonic()
    run_started_at = datetime.now(timezone.utc)

    try:
        cfg = load_config()
        plan = resolve_plan(cfg, args)
        for var in ("PG_CONN", "MSSQL_CONN"):
            if not os.environ.get(var):
                raise ConfigError(f"{var} is not set (etl/.env)")
        problem = session_mode_problem(os.environ["PG_CONN"])
        if problem:
            raise ConfigError(problem)
    except ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return EXIT_USAGE

    label = (f"subset: {', '.join(table_short_name(t) for t in plan.tables)}"
             if plan.profile == "subset" else f"profile {plan.profile}")
    print(f"push started at {datetime.now():%Y-%m-%d %H:%M:%S} ({label})")
    overrides = cfg.get("column_map") or {}

    pg = psycopg.connect(os.environ["PG_CONN"],
                         application_name=f"etl push_to_supabase ({plan.profile})")
    ms = None
    core_locked = False
    try:
        if not backend_is_stable(pg):
            print("config error: PG_CONN is not a session — pg_backend_pid() changed "
                  "between two transactions (a transaction pooler?). Use the session "
                  "pooler on port 5432 or the direct connection.", file=sys.stderr)
            return EXIT_USAGE

        # The postgres role inherits the project's 120 s statement_timeout, and
        # refresh_territory_rollups() alone has taken longer than that most
        # nights since late September 2026 (etl:post_load errors at exactly
        # 120 s). The limit is session-scoped: the app's 8 s cap on the
        # authenticated role is untouched.
        pg.execute("select set_config('statement_timeout', %s, false)",
                   (statement_timeout(plan.statement_timeout),))
        pg.commit()

        if plan.lock == "core":
            core_locked = acquire_core_lock(pg, plan.lock_wait_minutes)
            if not core_locked:
                holder = lock_holder(pg, CORE_LOCK_KEY)
                print(f"SKIPPED: another full/hourly run holds the core run lock"
                      f"{' (' + holder + ')' if holder else ''}; gave up after "
                      f"{plan.lock_wait_minutes:g} min. Nothing loaded, no "
                      f"{plan.ledger or 'ledger'} row. Exit 3.", file=sys.stderr)
                return EXIT_BUSY

        ms = mssql_connect()
        result = load_tables(pg, ms, plan, overrides)
        loaded, failed_tables = result.loaded, result.failed_tables
        failures = list(result.failures)
        skipped = result.skipped
        not_loaded = failed_tables + skipped

        # Post-load never runs on a subset run or a profile without it (ats).
        # Otherwise it runs when every table landed, or — when views.yml lists
        # post_load_requires — when every table the post-load steps read
        # landed, whatever else failed (see post_load_required_tables: one
        # table nothing downstream reads must not freeze the rollups). Either
        # way the rollups are never rebuilt over a mix of old and new copies
        # of the tables they combine. A table skipped as busy did not land.
        requires = post_load_required_tables(cfg)
        if not plan.post_load:
            run_post_load = False
        elif not not_loaded:
            run_post_load = True
        elif requires is None:
            run_post_load = False
        else:
            run_post_load = requires <= loaded

        # What the ledger row's error text adds about post-load when a table
        # failed, so job_runs answers "did the rollups move?" without
        # push.log. Nothing is added without post_load_requires: that run
        # reads exactly as it always has.
        run_notes: list[str] = []
        if skipped:
            run_notes.append("skipped (busy): " + ", ".join(skipped))
        if not_loaded and plan.post_load and requires is not None:
            if run_post_load:
                note = ("post-load ran anyway: every table in post_load_requires "
                        "loaded")
                banner = "!" * 72
                print(banner, file=sys.stderr)
                print(f"WARNING: {len(not_loaded)} table(s) did not load: "
                      f"{', '.join(not_loaded)}", file=sys.stderr)
                print("Running post-load anyway — every table it reads "
                      "(views.yml post_load_requires) loaded in this run. The "
                      "table(s) above keep their previous load; the ledger row "
                      "is still logged as an error.", file=sys.stderr)
                print(banner, file=sys.stderr)
            else:
                note = ("post-load skipped: required table(s) did not load: "
                        + ", ".join(sorted(requires - loaded)))
                print(note, file=sys.stderr)
            run_notes.append(note)

        post_load_ok = False
        if run_post_load:
            post_load_ok = True
            for sql, optional in post_load_steps(cfg.get("post_load_sql"), plan.profile):
                step_started = time.monotonic()
                step_started_at = datetime.now(timezone.utc)
                try:
                    with pg.transaction():
                        res = pg.execute(sql).fetchall()
                    print(f"post_load: {sql} -> {res} "
                          f"({time.monotonic() - step_started:.1f}s)")
                except Exception as exc:
                    log_job_run(pg, "etl:post_load", step_started_at, "error", None,
                                f"{sql}: {exc}")
                    if optional:
                        # Housekeeping (see post_load_steps): logged, not fatal.
                        print(f"post_load: {sql} FAILED (optional, carrying on) — {exc}",
                              file=sys.stderr)
                        continue
                    # Stop here: later steps read what this one should have
                    # produced (views.yml explains the ordering).
                    failures.append(f"post_load: {sql}: {exc}")
                    post_load_ok = False
                    print(f"post_load: {sql} FAILED — {exc}", file=sys.stderr)
                    break

        # The one row the freshness stamp reads (20260901190400): 'etl:run'
        # for the full run, 'etl:run:hourly' for the hourly tier. success
        # means every table in the profile loaded AND every required
        # post-load step ran. A run whose post-load ran over its required
        # tables while another table failed is still an error — the stamp's
        # data_loaded_at keeps meaning "everything is current" — and the
        # error text names the failed tables and says post-load ran. A
        # subset run and the stock run log no ledger row at all. Logged
        # BEFORE post_load_http on purpose: those calls never count toward
        # success, and the AI batch can take ~20 minutes of repeated calls —
        # the stamp (and the app's cache invalidation, which also watches the
        # data horizons) should move when the data lands, on a connection
        # that has not sat idle all that time.
        if plan.ledger:
            ok = not failures and not skipped
            log_job_run(
                pg, plan.ledger, run_started_at,
                "success" if ok else "error",
                result.total_rows if ok else None,
                None if ok else "; ".join(failures + run_notes),
            )

        # The AI batch reads the scores and rollups post-load just rebuilt, so
        # it runs only after a post-load whose required steps all succeeded —
        # on a clean run, or on one where only tables it does not read failed.
        if post_load_ok and plan.http:
            for call in cfg.get("post_load_http") or []:
                post_load_http(call)
        elif post_load_ok and cfg.get("post_load_http") and plan.profile == "full":
            print("post_load_http: skipped (--no-http / ETL_SKIP_POST_LOAD_HTTP)")

        print(f"push finished at {datetime.now():%Y-%m-%d %H:%M:%S} "
              f"— elapsed {fmt_elapsed(time.monotonic() - run_started)}"
              + (f" (with {len(failures)} failure(s))" if failures else "")
              + (f" ({len(skipped)} table(s) skipped as busy)" if skipped else ""))
        return exit_code(failures, skipped)
    finally:
        if ms is not None:
            ms.close()
        if core_locked:
            release_core_lock(pg)
        pg.close()  # also releases any session lock still held


if __name__ == "__main__":
    sys.exit(main())
