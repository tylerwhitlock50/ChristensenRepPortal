"""Prove a migration and its guard test against the live catalog, then roll back.

    venv/Scripts/python.exe run_sql_guard.py [MIGRATION.sql ...] TEST.sql

Every file is run in ONE transaction, in order, and the transaction is rolled
back at the end: nothing persists, so a new migration can be checked against
the real database before deploy_migrations.py applies it. With no migration
argument the test alone runs against what is already live.

The tests in supabase/tests/*.sql are written for psql (a leading `\\set
ON_ERROR_STOP on`, their own begin/rollback). There is no psql on the ETL box,
so this strips those lines and supplies the transaction itself. PG_CONN comes
from etl/.env, same as the loader.
"""
from __future__ import annotations

import os
import sys

import psycopg
from dotenv import load_dotenv

HERE = os.path.dirname(os.path.abspath(__file__))
# Next to this script first; then the current directory, which is how a git
# worktree (no .env of its own) borrows the main checkout's: run it from there.
load_dotenv(os.path.join(HERE, ".env"))
load_dotenv(os.path.join(os.getcwd(), ".env"))

TX_LINES = {"begin;", "rollback;", "commit;"}


def body(path: str, strip_tx: bool) -> str:
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip().lower()
            if s.startswith("\\set"):
                continue
            if strip_tx and s in TX_LINES:
                continue
            out.append(line)
    return "".join(out)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    *migrations, test = argv
    sql = "begin;\n"
    for m in migrations:
        sql += body(m, strip_tx=False) + "\n"
    sql += body(test, strip_tx=True) + "\nrollback;\n"

    with psycopg.connect(os.environ["PG_CONN"], autocommit=True) as conn:
        conn.add_notice_handler(lambda d: print("NOTICE:", d.message_primary))
        conn.execute("set statement_timeout = '300s'")
        try:
            conn.execute(sql)
        except Exception as exc:  # noqa: BLE001 — the message IS the result
            print("FAIL:", exc)
            return 1
    print(f"OK (rolled back): {os.path.basename(test)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
