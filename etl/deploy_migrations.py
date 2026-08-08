"""
Apply ../supabase/migrations/*.sql to the Supabase Postgres, in filename
order, tracking what has already run.

Runs from the same box and .env as push_to_supabase.py — PG_CONN is the only
credential it needs. Each migration file executes inside one transaction
together with its tracking-table insert, so a failed file leaves nothing
half-applied and the next run retries it. Files are keyed by full filename
(not numeric prefix), so the two 032_* files coexist without colliding.

Usage:
    python deploy_migrations.py                 # apply everything pending
    python deploy_migrations.py --dry-run       # list pending, change nothing
    python deploy_migrations.py --baseline      # mark ALL current files as
                                                # applied WITHOUT running them
                                                # (first run against a prod DB
                                                # that was migrated by hand)
    python deploy_migrations.py --baseline-through 033_global_intel_units_only.sql
                                                # baseline only files <= NAME,
                                                # then apply the rest normally
    python deploy_migrations.py --reapply 032_tracking_ats_contacts_reporting.sql
                                                # force one file to run again
                                                # (it must be replay-safe)

Environment (see .env.example):
    PG_CONN      Postgres connection string to Supabase
                 (direct/session pooler, role: postgres — same as the ETL)
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import time
from datetime import datetime, timezone

import psycopg

from dotenv import load_dotenv

load_dotenv()

HERE = os.path.dirname(os.path.abspath(__file__))
MIGRATIONS_DIR = os.environ.get("MIGRATIONS_DIR") or os.path.normpath(
    os.path.join(HERE, "..", "supabase", "migrations")
)

# Session-level advisory lock so two deploys can't interleave. Arbitrary
# constant, unique to this tool.
DEPLOY_LOCK_KEY = 743_291_650

# Our own tracking table — deliberately NOT supabase_migrations.schema_migrations,
# which belongs to the Supabase CLI and keys on the numeric version prefix
# (where 032_* + 032_* would collide). RLS on + grants revoked: only the
# postgres/service role that runs deploys can read it.
TRACKING_DDL = """
create table if not exists public.deployed_migrations (
    filename   text primary key,
    checksum   text not null,
    applied_at timestamptz not null default now(),
    baselined  boolean not null default false
);
alter table public.deployed_migrations enable row level security;
revoke all on table public.deployed_migrations from anon, authenticated;
"""


def sha256(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def migration_files() -> list[str]:
    return sorted(
        f for f in os.listdir(MIGRATIONS_DIR)
        if f.endswith(".sql") and not f.startswith(".")
    )


def log_job_run(pg, job_name, started_at, status, rows=None, error=None):
    try:
        with pg.transaction():
            pg.execute(
                "select public.log_job_run(%s, %s, %s, %s, %s)",
                (job_name, status, rows, error, started_at),
            )
    except Exception as exc:  # audit failure must not fail the deploy itself
        print(f"job_runs logging failed for {job_name}: {exc}", file=sys.stderr)


def apply_file(pg, fname: str, baselined: bool = False) -> None:
    path = os.path.join(MIGRATIONS_DIR, fname)
    digest = sha256(path)
    with pg.transaction():
        if not baselined:
            with open(path, encoding="utf-8") as f:
                # No parameters -> psycopg uses the simple query protocol,
                # which accepts the multi-statement script as-is.
                pg.execute(f.read())
        pg.execute(
            """
            insert into public.deployed_migrations (filename, checksum, baselined)
            values (%s, %s, %s)
            on conflict (filename) do update
              set checksum = excluded.checksum,
                  applied_at = now(),
                  baselined = excluded.baselined
            """,
            (fname, digest, baselined),
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--dry-run", action="store_true",
                    help="list pending migrations without applying")
    ap.add_argument("--baseline", action="store_true",
                    help="record all unrecorded files as applied without running them")
    ap.add_argument("--baseline-through", metavar="FILENAME",
                    help="baseline unrecorded files up to and including FILENAME, "
                         "then apply the rest")
    ap.add_argument("--reapply", metavar="FILENAME",
                    help="run one already-recorded file again (must be replay-safe)")
    args = ap.parse_args()

    files = migration_files()
    if not files:
        print(f"no .sql files in {MIGRATIONS_DIR}", file=sys.stderr)
        return 2
    if args.baseline_through and args.baseline_through not in files:
        print(f"--baseline-through: no such file {args.baseline_through}", file=sys.stderr)
        return 2
    if args.reapply and args.reapply not in files:
        print(f"--reapply: no such file {args.reapply}", file=sys.stderr)
        return 2

    pg = psycopg.connect(os.environ["PG_CONN"])
    pg.execute("select pg_advisory_lock(%s)", (DEPLOY_LOCK_KEY,))
    with pg.transaction():
        pg.execute(TRACKING_DDL)

    recorded = {
        r[0]: r[1]
        for r in pg.execute(
            "select filename, checksum from public.deployed_migrations"
        ).fetchall()
    }
    pg.commit()

    # A recorded file whose content changed is drift — warn, never re-run
    # silently. Use --reapply for the deliberate case.
    for fname, old in sorted(recorded.items()):
        if fname in files and sha256(os.path.join(MIGRATIONS_DIR, fname)) != old:
            print(f"WARNING: {fname} changed since it was applied "
                  f"(use --reapply {fname} if that is intended)", file=sys.stderr)

    if args.reapply:
        started_at = datetime.now(timezone.utc)
        try:
            apply_file(pg, args.reapply)
            print(f"reapplied {args.reapply}")
            log_job_run(pg, "deploy:migrations", started_at, "success", 1)
            return 0
        except Exception as exc:
            print(f"{args.reapply}: FAILED — {exc}", file=sys.stderr)
            log_job_run(pg, "deploy:migrations", started_at, "error", None, str(exc))
            return 1
        finally:
            pg.close()

    pending = [f for f in files if f not in recorded]
    to_baseline = []
    if args.baseline:
        to_baseline, pending = pending, []
    elif args.baseline_through:
        cut = args.baseline_through
        to_baseline = [f for f in pending if f <= cut]
        pending = [f for f in pending if f > cut]

    if args.dry_run:
        for f in to_baseline:
            print(f"would baseline: {f}")
        for f in pending:
            print(f"pending: {f}")
        if not to_baseline and not pending:
            print("up to date")
        pg.close()
        return 0

    started_at = datetime.now(timezone.utc)
    applied = 0
    try:
        for f in to_baseline:
            apply_file(pg, f, baselined=True)
            print(f"baselined {f}")
        for f in pending:
            t0 = time.monotonic()
            apply_file(pg, f)
            applied += 1
            print(f"applied {f} in {time.monotonic() - t0:.1f}s")
    except Exception as exc:
        # apply_file's transaction already rolled back; everything before it
        # stays applied and recorded, and the next run resumes here.
        print(f"{f}: FAILED — {exc}", file=sys.stderr)
        log_job_run(pg, "deploy:migrations", started_at, "error", applied, str(exc))
        pg.close()
        return 1

    if not to_baseline and not applied:
        print("up to date")
    log_job_run(pg, "deploy:migrations", started_at, "success", applied)
    pg.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
