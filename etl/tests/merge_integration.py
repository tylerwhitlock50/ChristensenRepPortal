"""Prove the merge swap's SQL against the real Supabase — on TEMP tables only.

    venv\\Scripts\\python.exe tests\\merge_integration.py [--rows 20000]   (from etl/)

Not a unittest module on purpose (the name does not match test*.py): it
needs PG_CONN, and the unit suite must run anywhere. Run it after changing
build_merge_sql / run_merge / table_shape, and before trusting a new
`swap: merge` table.

What it does, in ONE transaction that is rolled back at the end:

1. Copies ~20k rows of erp.fact_order_line into a TEMP "live" table built
   LIKE the real one INCLUDING ALL (primary key, generated columns, the
   loaded_at default, indexes), and the same rows into a TEMP "stage"
   table built the way the loader builds etl_stage (LIKE … INCLUDING
   DEFAULTS, no key). loaded_at on the live copy is pinned to 2000-01-01.
2. Mutates the stage: changes values (including NULL <-> value), deletes
   rows, adds rows with new keys, and "updates" some rows to the value they
   already had (must NOT count as a change).
3. Switches the transaction to READ ONLY — from here Postgres itself
   refuses any write to a non-temporary table — and runs the merge through
   the loader's own build_merge_sql + run_merge, with the primary key read
   from pg_index by table_shape.
4. Asserts the live copy now equals the stage exactly over the loaded
   columns, that -D/+I are exactly the rows changed, deleted and added,
   that unchanged rows kept their old loaded_at (they were not rewritten),
   and that generated columns were computed on the inserted rows.
5. Scenario 2, exclude_columns: drops a column from the load and proves the
   merge erases the values the live copy still held. Then a source that
   repeats a key (one copy equal to the live row): silent to the merge
   statements, refused by check_merged_rows.
6. Advisory lock round-trip between two sessions on a throwaway key (no
   table involved): try-lock busy, holder lookup, blocking lock.

It reads erp.fact_order_line and writes nothing that survives: TEMP tables
(ON COMMIT DROP, and the transaction is rolled back anyway). PG_CONN comes
from etl/.env — from a git worktree, run it with the main checkout's etl/
as the working directory, like run_sql_guard.py.
"""
from __future__ import annotations

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ETL = os.path.dirname(HERE)
sys.path.insert(0, ETL)

import psycopg  # noqa: E402
from dotenv import load_dotenv  # noqa: E402

load_dotenv(os.path.join(ETL, ".env"))
load_dotenv(os.path.join(os.getcwd(), ".env"))

import push_to_supabase as p  # noqa: E402

LIVE = ("pg_temp", "merge_it_live")
STAGE = ("pg_temp", "merge_it_stage")
PINNED = "2000-01-01 00:00:00+00"
NEW_SUFFIX = "-MERGE-IT"
EXCLUDED = "customer_po_number"


class Check:
    def __init__(self):
        self.failed = 0

    def __call__(self, ok: bool, what: str):
        print(f"  {'PASS' if ok else 'FAIL'}  {what}")
        if not ok:
            self.failed += 1


def one(pg, sql, params=None):
    return pg.execute(sql, params).fetchone()[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=20_000)
    n_rows = ap.parse_args().rows
    check = Check()

    pg = psycopg.connect(os.environ["PG_CONN"],
                         application_name="etl merge_integration (temp tables)")
    try:
        pg.execute("set statement_timeout = '300s'")
        live = p.qualified(*LIVE)
        stage = p.qualified(*STAGE)

        # 1. The two copies.
        pg.execute(f"create temp table {p.quote_ident(LIVE[1])} "
                   f"(like erp.fact_order_line including all) on commit drop")
        shape = p.table_shape(pg, live)
        src = [c for c in shape.columns if c not in shape.generated and c not in shape.defaulted]
        cols = ", ".join(p.quote_ident(c) for c in src)
        print(f"live copy: pk from pg_index = {shape.pk}; generated = {sorted(shape.generated)}; "
              f"defaulted = {sorted(shape.defaulted)}; {len(src)} loaded columns")
        check(shape.pk == ["order_id", "line_num"], "primary key read from pg_index on the TEMP table")

        pg.execute(f"insert into {live} ({cols}, loaded_at) "
                   f"select {cols}, %s::timestamptz from erp.fact_order_line "
                   f"order by order_id desc, line_num limit %s", (PINNED, n_rows))
        pg.execute(f"create temp table {p.quote_ident(STAGE[1])} "
                   f"(like erp.fact_order_line including defaults) on commit drop")
        pg.execute(f"insert into {stage} ({cols}) select {cols} from {live}")
        n_live = one(pg, f"select count(*) from {live}")
        print(f"copied {n_live} rows into both")

        # 2. Mutations, in disjoint buckets of a stable row number.
        pg.execute(f"""
            create temp table merge_it_bucket on commit drop as
            select order_id, line_num, (row_number() over (order by order_id, line_num)) % 50 as b
            from {stage}""")

        def bucket(b):
            return (f"(order_id, line_num) in (select order_id, line_num "
                    f"from merge_it_bucket where b = {b})")

        changed_qty = pg.execute(
            f"update {stage} set order_qty = coalesce(order_qty, 0) + 1 where {bucket(1)}").rowcount
        changed_null = pg.execute(
            f"update {stage} set customer_po_number = case when customer_po_number is null "
            f"then 'MERGE-IT' else null end where {bucket(2)}").rowcount
        changed_bool = pg.execute(
            f"update {stage} set is_backlog_line = case when is_backlog_line is true "
            f"then false else true end where {bucket(3)}").rowcount
        deleted = pg.execute(f"delete from {stage} where {bucket(4)}").rowcount
        added = pg.execute(
            f"insert into {stage} ({cols}) "
            f"select {', '.join('order_id || %s' if c == 'order_id' else p.quote_ident(c) for c in src)} "
            f"from {stage} where {bucket(5)}", (NEW_SUFFIX,)).rowcount
        noop = pg.execute(
            f"update {stage} set order_qty = order_qty, customer_po_number = customer_po_number "
            f"where {bucket(6)}").rowcount
        changed = changed_qty + changed_null + changed_bool
        exp_d, exp_i = changed + deleted, changed + added
        print(f"stage mutated: {changed} changed ({changed_qty} qty, {changed_null} NULL<->value, "
              f"{changed_bool} boolean), {deleted} deleted, {added} added, {noop} same-value updates")
        print(f"expected: -{exp_d} +{exp_i}")

        # 3. Read-only from here: any write outside pg_temp is refused by Postgres.
        pg.execute("set transaction_read_only = on")
        m = p.build_merge_sql(LIVE, STAGE, shape.pk, src, p.unsupplied_null_columns(shape, src))
        check(p.unsupplied_null_columns(shape, src) == [],
              "no unsupplied columns besides loaded_at (nothing extra compared)")

        # The DELETE's plan, at the server's work_mem and at the loader's
        # merge work_mem, each on a savepoint that is rolled back so the real
        # run below starts from the same state. (The join filter line —
        # one IS DISTINCT FROM per column — is left out of the print.)
        for label, mem in (("server work_mem", None), ("ETL_MERGE_WORK_MEM", p.merge_work_mem())):
            with pg.transaction(force_rollback=True):
                if mem:
                    pg.execute("select set_config('work_mem', %s, true)", (mem,))
                shown = one(pg, "show work_mem")
                pg.execute(m.analyze)
                plan = [r[0] for r in pg.execute(
                    "explain (analyze, buffers, costs off, timing off, summary on) " + m.delete)]
            print(f"DELETE plan, {label} = {shown} (savepoint, rolled back):")
            for line in plan:
                if "Join Filter" not in line:
                    print("    " + line)

        # The real run, as push_table does it.
        t0 = time.monotonic()
        with pg.transaction():
            cur = pg.cursor()
            if p.merge_work_mem():
                cur.execute("select set_config('work_mem', %s, true)", (p.merge_work_mem(),))
            d, i = p.run_merge(cur, m, drop_stage=False)
        secs = time.monotonic() - t0
        print(f"merged: -{d} +{i} in {secs:.2f}s")

        # 4. Assertions.
        check((d, i) == (exp_d, exp_i), f"-D/+I = -{d} +{i}, expected -{exp_d} +{exp_i}")
        diff_ls = one(pg, f"select count(*) from (select {cols} from {live} "
                          f"except all select {cols} from {stage}) x")
        diff_sl = one(pg, f"select count(*) from (select {cols} from {stage} "
                          f"except all select {cols} from {live}) x")
        check(diff_ls == 0 and diff_sl == 0,
              f"live == stage over the loaded columns (live-stage {diff_ls}, stage-live {diff_sl})")
        n_after, n_stage = (one(pg, f"select count(*) from {live}"),
                            one(pg, f"select count(*) from {stage}"))
        check(n_after == n_stage == n_live - deleted + added,
              f"row counts: live {n_after} = stage {n_stage} = {n_live} - {deleted} + {added}")
        kept = one(pg, f"select count(*) from {live} where loaded_at = %s::timestamptz", (PINNED,))
        check(kept == n_live - d, f"unchanged rows not rewritten: {kept} still carry the pinned "
                                  f"loaded_at (= {n_live} - {d})")
        fresh = one(pg, f"select count(*) from {live} where loaded_at <> %s::timestamptz", (PINNED,))
        check(fresh == i, f"only inserted rows have a new loaded_at ({fresh} = {i})")
        gen_bad = one(pg, f"""
            select count(*) from {live} n
            join {live} o on o.order_id || %s = n.order_id and o.line_num = n.line_num
            where (n.order_date, n.promise_date, n.desired_ship_date, n.last_shipped_date)
                  is distinct from
                  (o.order_date, o.promise_date, o.desired_ship_date, o.last_shipped_date)""",
                      (NEW_SUFFIX,))
        gen_new = one(pg, f"select count(*) from {live} where order_id like %s "
                          f"and order_date is not null", ("%" + NEW_SUFFIX,))
        check(gen_bad == 0 and gen_new > 0,
              f"generated columns computed on inserted rows ({gen_new} new rows with order_date, "
              f"{gen_bad} mismatches)")

        # 5. exclude_columns: the stage no longer carries the column (NULL, as
        # the loader leaves it); the merge must erase what live still holds.
        held = one(pg, f"select count(*) from {live} where {p.quote_ident(EXCLUDED)} is not null")
        pg.execute(f"update {stage} set {p.quote_ident(EXCLUDED)} = null")
        loaded2 = [c for c in src if c != EXCLUDED]
        nulls2 = p.unsupplied_null_columns(shape, loaded2)
        check(nulls2 == [EXCLUDED], f"unsupplied_null_columns from the real catalog = {nulls2}")
        m2 = p.build_merge_sql(LIVE, STAGE, shape.pk, loaded2, nulls2)
        with pg.transaction():
            d2, i2 = p.run_merge(pg.cursor(), m2, drop_stage=False)
        print(f"exclude scenario: {held} live rows held {EXCLUDED}; merged: -{d2} +{i2}")
        left = one(pg, f"select count(*) from {live} where {p.quote_ident(EXCLUDED)} is not null")
        check((d2, i2) == (held, held) and left == 0,
              f"excluded column erased: -{d2} +{i2} (expected -{held} +{held}), {left} values left")
        cols2 = ", ".join(p.quote_ident(c) for c in src)
        diff2 = one(pg, f"select count(*) from ((select {cols2} from {live} except all "
                        f"select {cols2} from {stage}) union all (select {cols2} from {stage} "
                        f"except all select {cols2} from {live})) x")
        check(diff2 == 0, f"live == stage after the exclude merge ({diff2} differing rows)")

        # 5b. A key repeated in the source, one copy equal to the live row
        # (a fan-out in a view's join). Replace's INSERT would fail on the
        # key; the merge statements alone keep the row and insert neither
        # repeat, so push_table's check_merged_rows must refuse. On a
        # savepoint, rolled back.
        with pg.transaction(force_rollback=True):
            pg.execute(f"insert into {stage} ({cols}) select {cols} from {stage} "
                       f"order by order_id, line_num limit 1")
            n_stage3 = one(pg, f"select count(*) from {stage}")
            d3, i3 = p.run_merge(pg.cursor(), m2, drop_stage=False)
            try:
                p.check_merged_rows(pg.cursor(), live, "merge-it live", n_stage3)
                refused = ""
            except p.LoadRefused as exc:
                refused = str(exc)
        print(f"repeated-key scenario: merged -{d3} +{i3}; guard: {refused or 'did NOT refuse'}")
        check((d3, i3) == (0, 0) and "primary key repeated" in refused,
              "a repeated source key is silent to the merge statements and refused by check_merged_rows")
        with pg.transaction(force_rollback=True):
            p.check_merged_rows(pg.cursor(), live, "merge-it live", one(pg, f"select count(*) from {stage}"))
        check(True, "check_merged_rows passes when live and stage counts agree")

        # The DROP is the one statement read-only refuses even on a TEMP
        # table; ON COMMIT DROP and the rollback dispose of both copies.
        check(m.drop == f"DROP TABLE {stage}", "drop statement targets the stage")
        persistence = pg.execute(
            "select relname, relpersistence from pg_class where oid in (%s::regclass, %s::regclass)",
            (live, stage)).fetchall()
        check(all(rp == "t" for _, rp in persistence), f"both tables are temporary: {persistence}")
    finally:
        pg.rollback()
        pg.close()

    # 6. Advisory locks between two real sessions, on a throwaway key.
    key_table = "merge-integration.selftest"
    a = psycopg.connect(os.environ["PG_CONN"], application_name="etl merge_integration lock A")
    b = psycopg.connect(os.environ["PG_CONN"], application_name="etl merge_integration lock B")
    try:
        check(p.backend_is_stable(a), "session pooler keeps one backend across transactions")
        check(p.lock_table(a, key_table, wait=False), "session A takes the table lock")
        check(not p.lock_table(b, key_table, wait=False), "session B: try-lock reports busy")
        a_pid = one(a, "select pg_backend_pid()")
        a.commit()
        holder = p.lock_holder(b, "etl:table:" + key_table)
        check(f"pid {a_pid}" in holder, f"holder lookup finds A: {holder!r}")
        check(p.lock_holder(b, p.CORE_LOCK_KEY) == "", "core lock is free (holder lookup empty)")
        p.unlock_table(a, key_table)
        check(p.lock_table(b, key_table, wait=True), "session B: blocking lock after A released")
        p.unlock_table(b, key_table)
        left = one(a, "select count(*) from pg_locks where locktype = 'advisory' and pid in (%s, %s)",
                   (a_pid, one(b, "select pg_backend_pid()")))
        a.commit()
        b.commit()
        check(left == 0, "no advisory lock left behind")
    finally:
        a.close()
        b.close()

    print("ALL PASS" if not check.failed else f"{check.failed} CHECK(S) FAILED")
    return 0 if not check.failed else 1


if __name__ == "__main__":
    sys.exit(main())
