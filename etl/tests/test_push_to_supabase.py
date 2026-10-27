"""Unit tests for push_to_supabase.py — no database, no SQL Server.

    venv\\Scripts\\python.exe -m unittest discover -s tests -v      (from etl/)

Stdlib unittest only, so the ETL box needs nothing beyond requirements.txt.
Connections are fakes that record every statement; the real-database proof
of the merge SQL is tests/merge_integration.py (TEMP tables, rolled back).
"""
from __future__ import annotations

import contextlib
import copy
import io
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import push_to_supabase as p  # noqa: E402

REAL_CFG = p.load_config()


def cfg_copy() -> dict:
    return copy.deepcopy(REAL_CFG)


def quiet():
    """Swallow the loader's progress prints."""
    stack = contextlib.ExitStack()
    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
    return stack


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

class FakeCursor:
    def __init__(self, conn):
        self.conn = conn
        self.rowcount = -1
        self._rows: list = []

    def execute(self, sql, params=None):
        self.conn.log.append(sql)
        self._rows, self.rowcount = self.conn.respond(sql, params)
        return self

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return list(self._rows)

    @contextlib.contextmanager
    def copy(self, sql):
        self.conn.log.append(sql)
        yield self.conn.copy_sink


class CopySink:
    def __init__(self):
        self.data = ""

    def write(self, s):
        self.data += s


class FakePg:
    """A psycopg-shaped connection: execute/cursor/transaction/commit.

    `answers` maps a substring of the SQL to the rows it returns (first
    match wins); a callable answer gets the call count for that key.
    """

    def __init__(self, answers=None, rowcounts=None):
        self.log: list[str] = []
        self.answers = answers or {}
        self.rowcounts = rowcounts or {}
        self.calls: dict[str, int] = {}
        self.copy_sink = CopySink()
        self.closed = False

    def respond(self, sql, params):
        for key, ans in self.answers.items():
            if key in sql:
                n = self.calls[key] = self.calls.get(key, 0) + 1
                rows = ans(n) if callable(ans) else ans
                return rows, self.rowcounts.get(key, len(rows))
        for key, rc in self.rowcounts.items():
            if key in sql:
                return [], rc
        return [], -1

    def execute(self, sql, params=None):
        return FakeCursor(self).execute(sql, params)

    def cursor(self):
        return FakeCursor(self)

    @contextlib.contextmanager
    def transaction(self):
        self.log.append("BEGIN")
        try:
            yield
        except BaseException:
            self.log.append("ROLLBACK")
            raise
        self.log.append("COMMIT")

    def commit(self):
        self.log.append("COMMIT")

    def close(self):
        self.closed = True

    def ran(self, fragment: str) -> list[str]:
        return [s for s in self.log if fragment in s]


class FakeMsCursor:
    def __init__(self, cols, rows):
        self.description = [(c,) for c in cols]
        self._rows = list(rows)

    def execute(self, sql):
        self.sql = sql
        return self

    def fetchmany(self, n):
        out, self._rows = self._rows[:n], self._rows[n:]
        return out


class FakeMs:
    def __init__(self, cols=("A",), rows=()):
        self.cols, self.rows = cols, rows
        self.closed = False

    def cursor(self):
        return FakeMsCursor(self.cols, self.rows)

    def close(self):
        self.closed = True


def args_for(*argv):
    return p.parse_args(list(argv))


# ---------------------------------------------------------------------------
# Arguments and profile resolution
# ---------------------------------------------------------------------------

class ArgsAndProfiles(unittest.TestCase):
    def test_no_arguments_is_the_full_run(self):
        args = args_for()
        self.assertEqual((args.profile, args.tables, args.if_idle, args.no_http),
                         ("full", [], False, False))
        plan = p.resolve_plan(cfg_copy(), args, {})
        self.assertEqual(plan.profile, "full")
        self.assertEqual([t["target_table"] for t in plan.tables],
                         [t["target_table"] for t in REAL_CFG["tables"]])
        self.assertTrue(plan.post_load)
        self.assertTrue(plan.http)
        self.assertEqual(plan.ledger, "etl:run")
        self.assertEqual(plan.lock, "core")
        self.assertEqual(plan.lock_wait_minutes, 45)
        self.assertIsNone(plan.statement_timeout)

    def test_hourly(self):
        plan = p.resolve_plan(cfg_copy(), args_for("--profile", "hourly"), {})
        self.assertEqual([t["target_table"] for t in plan.tables],
                         ["erp.dim_customer", "erp.dim_part", "erp.fact_order_line",
                          "erp.fact_invoice_line", "erp.fact_shipment_line"])
        self.assertEqual((plan.post_load, plan.http, plan.ledger, plan.lock, plan.lock_wait_minutes),
                         (True, False, "etl:run:hourly", "core", 0))

    def test_ats(self):
        plan = p.resolve_plan(cfg_copy(), args_for("--profile", "ats", "--if-idle"), {})
        self.assertEqual([t["target_table"] for t in plan.tables], ["erp.fact_available_to_sell"])
        self.assertEqual((plan.post_load, plan.http, plan.ledger, plan.lock), (False, False, None, None))
        self.assertEqual(plan.statement_timeout, "60s")
        self.assertTrue(plan.if_idle)
        self.assertEqual(p.statement_timeout(plan.statement_timeout), "60s")

    def test_profile_timeout_wins_over_env_and_env_over_default(self):
        with mock.patch.dict(os.environ, {"ETL_STATEMENT_TIMEOUT": "30min"}):
            self.assertEqual(p.statement_timeout("60s"), "60s")
            self.assertEqual(p.statement_timeout(None), "30min")
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(p.statement_timeout(None), "15min")

    def test_legacy_subset_is_unchanged(self):
        with quiet():
            plan = p.resolve_plan(cfg_copy(), args_for("dim_part", "FACT_ORDER_LINE", "nope"), {})
        self.assertEqual(plan.profile, "subset")
        self.assertEqual([t["target_table"] for t in plan.tables],
                         ["erp.dim_part", "erp.fact_order_line"])  # views.yml order
        self.assertEqual((plan.post_load, plan.http, plan.ledger, plan.lock), (False, False, None, None))

    def test_subset_with_default_profile_spelled_out_is_allowed(self):
        self.assertEqual(args_for("--profile", "full", "dim_part").tables, ["dim_part"])

    def test_subset_with_another_profile_is_a_usage_error(self):
        with quiet(), self.assertRaises(SystemExit) as cm:
            args_for("--profile", "ats", "dim_part")
        self.assertEqual(cm.exception.code, 2)

    def test_unknown_profile_is_a_usage_error(self):
        with quiet(), self.assertRaises(SystemExit) as cm:
            args_for("--profile", "weekly")
        self.assertEqual(cm.exception.code, 2)

    def test_subset_matching_nothing_is_a_config_error(self):
        with self.assertRaises(p.ConfigError):
            p.resolve_plan(cfg_copy(), args_for("no_such_table"), {})

    def test_no_http_and_its_env_twin(self):
        self.assertFalse(p.resolve_plan(cfg_copy(), args_for("--no-http"), {}).http)
        self.assertFalse(p.resolve_plan(cfg_copy(), args_for(),
                                        {"ETL_SKIP_POST_LOAD_HTTP": "1"}).http)
        self.assertTrue(p.resolve_plan(cfg_copy(), args_for(),
                                       {"ETL_SKIP_POST_LOAD_HTTP": "0"}).http)

    def test_swap_mode_and_the_escape_hatch(self):
        merge_table = {"target_table": "erp.fact_order_line", "swap": "merge"}
        self.assertEqual(p.swap_mode(merge_table, {}), "merge")
        self.assertEqual(p.swap_mode(merge_table, {"ETL_SWAP_MODE": "replace"}), "replace")
        self.assertEqual(p.swap_mode({"target_table": "erp.x"}, {}), "replace")
        with self.assertRaises(p.ConfigError):
            p.resolve_plan(cfg_copy(), args_for(), {"ETL_SWAP_MODE": "merge-everything"})

    def test_views_yml_swap_choices(self):
        by_table = {t["target_table"]: p.swap_mode(t, {}) for t in REAL_CFG["tables"]}
        self.assertEqual(by_table["erp.fact_available_to_sell"], "replace")
        self.assertEqual(by_table["erp.dim_sales_rep"], "replace")
        for t in ("erp.dim_customer", "erp.dim_part", "erp.dim_ship_to",
                  "erp.dim_customer_contact", "erp.fact_order_line",
                  "erp.fact_invoice_line", "erp.fact_shipment_line",
                  "erp.fact_inventory_on_hand"):
            self.assertEqual(by_table[t], "merge", t)

    def test_views_yml_without_profiles_still_means_full(self):
        cfg = cfg_copy()
        del cfg["profiles"]
        for entry in cfg["post_load_sql"]:
            if isinstance(entry, dict):
                entry.pop("profiles", None)
        plan = p.resolve_plan(cfg, args_for(), {})
        self.assertEqual((plan.ledger, plan.lock, plan.lock_wait_minutes, plan.post_load),
                         ("etl:run", "core", 45, True))
        with self.assertRaises(p.ConfigError):
            p.resolve_plan(cfg, args_for("--profile", "hourly"), {})


# ---------------------------------------------------------------------------
# views.yml validation
# ---------------------------------------------------------------------------

class ConfigValidation(unittest.TestCase):
    def test_real_views_yml_is_valid_and_hourly_is_post_load_requires(self):
        profiles = p.validate_config(cfg_copy())
        self.assertEqual(set(profiles), {"full", "hourly", "ats"})
        self.assertEqual(set(profiles["hourly"]["tables"]),
                         {t.lower() for t in REAL_CFG["post_load_requires"]})

    def assertConfigError(self, cfg, *fragments):
        with self.assertRaises(p.ConfigError) as cm:
            p.validate_config(cfg)
        for f in fragments:
            self.assertIn(f, str(cm.exception))

    def test_hourly_missing_a_required_table(self):
        cfg = cfg_copy()
        cfg["profiles"]["hourly"]["tables"].remove("erp.fact_shipment_line")
        self.assertConfigError(cfg, "profiles.hourly", "erp.fact_shipment_line", "post_load_requires")

    def test_subset_post_load_without_post_load_requires(self):
        cfg = cfg_copy()
        del cfg["post_load_requires"]
        self.assertConfigError(cfg, "profiles.hourly", "no post_load_requires")

    def test_profile_naming_an_unknown_table(self):
        cfg = cfg_copy()
        cfg["profiles"]["ats"]["tables"] = ["erp.fact_ats"]
        self.assertConfigError(cfg, "erp.fact_ats")

    def test_unknown_key_bad_lock_and_http_without_post_load(self):
        cfg = cfg_copy()
        cfg["profiles"]["ats"]["post-load"] = True
        self.assertConfigError(cfg, "unknown key", "post-load")
        cfg = cfg_copy()
        cfg["profiles"]["ats"]["lock"] = "table"
        self.assertConfigError(cfg, "lock")
        cfg = cfg_copy()
        cfg["profiles"]["ats"]["http"] = True
        self.assertConfigError(cfg, "http needs post_load")
        cfg = cfg_copy()
        cfg["profiles"]["full"]["lock_wait_minutes"] = -1
        self.assertConfigError(cfg, "lock_wait_minutes")

    def test_post_load_step_naming_an_undefined_profile(self):
        cfg = cfg_copy()
        cfg["post_load_sql"].append({"sql": "select 1", "profiles": ["nightly"]})
        self.assertConfigError(cfg, "nightly")

    def test_bad_swap_and_exclude_columns(self):
        cfg = cfg_copy()
        cfg["tables"][0]["swap"] = "upsert"
        self.assertConfigError(cfg, "swap")
        cfg = cfg_copy()
        cfg["tables"][0]["exclude_columns"] = "tax_id_number"
        self.assertConfigError(cfg, "exclude_columns")

    def test_leaked_columns_are_excluded(self):
        excl = {t["target_table"]: t.get("exclude_columns") for t in REAL_CFG["tables"]}
        self.assertEqual(excl["erp.dim_customer"], ["tax_id_number"])
        self.assertEqual(excl["erp.dim_customer_contact"], ["salutation"])

    def test_main_exits_2_on_config_error_before_connecting(self):
        cfg = cfg_copy()
        cfg["profiles"]["hourly"]["tables"].remove("erp.dim_part")
        with mock.patch.object(p, "load_config", return_value=cfg), \
                mock.patch.object(p.psycopg, "connect", side_effect=AssertionError("connected")), \
                mock.patch.object(p, "mssql_connect", side_effect=AssertionError("connected")), \
                quiet():
            self.assertEqual(p.main(["--profile", "ats"]), 2)


# ---------------------------------------------------------------------------
# Post-load steps per profile
# ---------------------------------------------------------------------------

class PostLoadFiltering(unittest.TestCase):
    FULL_ONLY = ("generate_recommendations", "refresh_account_signals", "apply_account_scores")

    def test_full_runs_every_step_in_order(self):
        full = p.post_load_steps(REAL_CFG["post_load_sql"], "full")
        self.assertEqual(full, p.post_load_steps(REAL_CFG["post_load_sql"]))
        self.assertIn("refresh_territory_rollups", full[0][0])
        self.assertFalse(full[0][1])  # required
        for name in self.FULL_ONLY:
            self.assertTrue(any(name in sql for sql, _ in full), name)

    def test_hourly_skips_scoring_and_recommendations(self):
        hourly = p.post_load_steps(REAL_CFG["post_load_sql"], "hourly")
        sqls = [sql for sql, _ in hourly]
        self.assertEqual(len(hourly), 4)
        self.assertIn("refresh_territory_rollups", sqls[0])
        self.assertIn("analyze_territory_rollups", sqls[1])
        self.assertIn("capture_order_changes", sqls[2])
        self.assertIn("run_order_qc", sqls[3])
        self.assertEqual([opt for _, opt in hourly], [False, True, True, False])
        for name in self.FULL_ONLY:
            self.assertFalse(any(name in s for s in sqls), name)

    def test_plain_strings_and_unscoped_dicts_run_everywhere(self):
        entries = ["select a()", {"sql": "select b()", "optional": True},
                   {"sql": "select c()", "profiles": ["full"]}]
        self.assertEqual(p.post_load_steps(entries, "hourly"),
                         [("select a()", False), ("select b()", True)])
        self.assertEqual(len(p.post_load_steps(entries, "full")), 3)


# ---------------------------------------------------------------------------
# Merge SQL
# ---------------------------------------------------------------------------

def norm(sql: str) -> str:
    return " ".join(sql.split())


class MergeSql(unittest.TestCase):
    def build(self, pk=("order_id", "line_num"), cols=("order_id", "line_num", "order_qty", "line_status"),
              nulls=()):
        return p.build_merge_sql(("erp", "fact_order_line"), ("etl_stage", "fact_order_line"),
                                 list(pk), list(cols), list(nulls))

    def test_pk_equality_and_is_not_distinct_from_over_loaded_columns(self):
        m = self.build()
        d = norm(m.delete)
        self.assertTrue(d.startswith('DELETE FROM "erp"."fact_order_line" AS l WHERE NOT EXISTS'))
        self.assertIn('SELECT 1 FROM "etl_stage"."fact_order_line" AS s', d)
        self.assertIn('s."order_id" = l."order_id" AND s."line_num" = l."line_num"', d)
        self.assertIn('ROW(s."order_qty", s."line_status") IS NOT DISTINCT FROM '
                      'ROW(l."order_qty", l."line_status")', d)
        # The key is compared by equality, not again inside the row.
        self.assertNotIn('ROW(s."order_id"', d)

    def test_insert_only_keys_no_longer_live(self):
        i = norm(self.build().insert)
        self.assertEqual(
            i,
            'INSERT INTO "erp"."fact_order_line" ("order_id", "line_num", "order_qty", "line_status") '
            'SELECT s."order_id", s."line_num", s."order_qty", s."line_status" '
            'FROM "etl_stage"."fact_order_line" AS s WHERE NOT EXISTS ( '
            'SELECT 1 FROM "erp"."fact_order_line" AS l '
            'WHERE s."order_id" = l."order_id" AND s."line_num" = l."line_num" )')

    def test_analyze_and_drop_target_the_stage(self):
        m = self.build()
        self.assertEqual(m.analyze, 'ANALYZE "etl_stage"."fact_order_line"')
        self.assertEqual(m.drop, 'DROP TABLE "etl_stage"."fact_order_line"')

    def test_generated_and_defaulted_columns_are_never_compared(self):
        shape = p.TableShape(
            columns=["order_id", "line_num", "order_qty", "order_date", "loaded_at", "secret"],
            pk=["order_id", "line_num"], generated={"order_date"}, defaulted={"loaded_at"})
        loaded = ["order_id", "line_num", "order_qty"]
        nulls = p.unsupplied_null_columns(shape, loaded)
        self.assertEqual(nulls, ["secret"])
        m = self.build(cols=loaded, nulls=nulls)
        for sql in m:
            self.assertNotIn("order_date", sql)
            self.assertNotIn("loaded_at", sql)
        self.assertIn('AND l."secret" IS NULL', norm(m.delete))
        self.assertNotIn("secret", m.insert)

    def test_quoting(self):
        m = p.build_merge_sql(("erp", 'we"ird'), ("etl_stage", 'we"ird'), ["Key"],
                              ["Key", 'col"q', "MixedCase"])
        d = norm(m.delete)
        self.assertIn('DELETE FROM "erp"."we""ird" AS l', d)
        self.assertIn('s."Key" = l."Key"', d)
        self.assertIn('ROW(s."col""q", s."MixedCase") IS NOT DISTINCT FROM ROW(l."col""q", l."MixedCase")', d)
        self.assertEqual(p.quote_ident('a"b'), '"a""b"')

    def test_key_only_table_has_no_row_comparison(self):
        m = self.build(pk=("k",), cols=("k",))
        self.assertNotIn("IS NOT DISTINCT FROM", m.delete)

    def test_needs_a_loaded_primary_key(self):
        with self.assertRaises(ValueError):
            self.build(pk=())
        with self.assertRaises(ValueError):
            self.build(pk=("order_id", "line_num"), cols=("order_id", "order_qty"))

    def test_run_merge_order_and_counts(self):
        pg = FakePg(rowcounts={"DELETE FROM": 7, "INSERT INTO": 9})
        m = self.build()
        self.assertEqual(p.run_merge(pg.cursor(), m), (7, 9))
        self.assertEqual(pg.log, [m.analyze, m.delete, m.insert, m.drop])
        pg2 = FakePg(rowcounts={"DELETE FROM": 0, "INSERT INTO": 0})
        p.run_merge(pg2.cursor(), m, drop_stage=False)
        self.assertEqual(pg2.log, [m.analyze, m.delete, m.insert])

    def test_table_shape_reads_pk_in_key_order(self):
        pg = FakePg(answers={"pg_attribute": [
            ("line_num", False, False, 2), ("order_id", False, False, 1),
            ("order_date", True, False, None), ("loaded_at", False, True, None)]})
        shape = p.table_shape(pg, '"erp"."fact_order_line"')
        self.assertEqual(shape.pk, ["order_id", "line_num"])
        self.assertEqual(shape.generated, {"order_date"})
        self.assertEqual(shape.defaulted, {"loaded_at"})


# ---------------------------------------------------------------------------
# exclude_columns and push_table
# ---------------------------------------------------------------------------

SHAPE_ROWS = [("customer_key", False, False, 1), ("customer_name", False, False, None),
              ("tax_id_number", False, False, None), ("loaded_at", False, True, None)]


class ExcludeColumns(unittest.TestCase):
    def test_loaded_columns_and_csv_line(self):
        cols, keep, absent = p.loaded_columns(["a", "tax_id_number", "b"], ["TAX_ID_NUMBER", "zzz"])
        self.assertEqual((cols, keep, absent), (["a", "b"], [0, 2], ["zzz"]))
        self.assertEqual(p.csv_line(("x", "123-45-6789", "y,z"), keep), 'x,"y,z"\n')
        cols, keep, absent = p.loaded_columns(["a", "b"], [])
        self.assertEqual((cols, keep, absent), (["a", "b"], None, []))
        self.assertEqual(p.csv_line(("x", None), None), "x,\n")

    def push(self, swap, shape_rows=SHAPE_ROWS, env=None, live_rows=2):
        pg = FakePg(answers={"pg_attribute": shape_rows,
                             'SELECT count(*) FROM "erp"."dim_customer"': [(live_rows,)]},
                    rowcounts={"DELETE FROM": 1, "INSERT INTO": 2})
        ms = FakeMs(cols=("CustomerKey", "CustomerName", "TaxIDNumber"),
                    rows=[("C1", "Acme, Inc", "123-45-6789"), ("C2", "Bolt", None)])
        with mock.patch.dict(os.environ, env or {}, clear=False), quiet() as _:
            res = p.push_table(ms, pg, "bi.vw_DimCustomer", "erp.dim_customer",
                               {"TaxIDNumber": "tax_id_number"}, None,
                               exclude=["tax_id_number"], swap=swap)
        return pg, res

    def test_excluded_column_never_leaves_the_machine(self):
        pg, res = self.push("replace")
        copy_sql = pg.ran("COPY ")[0]
        self.assertIn('("customer_key", "customer_name")', copy_sql)
        self.assertNotIn("tax_id_number", copy_sql)
        self.assertEqual(pg.copy_sink.data, 'C1,"Acme, Inc"\nC2,Bolt\n')
        self.assertNotIn("123-45-6789", pg.copy_sink.data)
        self.assertEqual(res, p.Pushed(2, "replace"))
        self.assertEqual(norm(pg.ran('INSERT INTO "erp"')[0]),
                         'INSERT INTO "erp"."dim_customer" ("customer_key", "customer_name") '
                         'SELECT "customer_key", "customer_name" FROM "etl_stage"."dim_customer"')

    def test_merge_erases_an_excluded_value_still_live(self):
        pg, res = self.push("merge")
        self.assertEqual(res, p.Pushed(2, "merge", 1, 2))
        delete = norm(pg.ran('DELETE FROM "erp"')[0])
        self.assertIn('ROW(s."customer_name") IS NOT DISTINCT FROM ROW(l."customer_name")', delete)
        self.assertIn('AND l."tax_id_number" IS NULL', delete)
        self.assertNotIn("loaded_at", delete)
        self.assertTrue(pg.ran('DROP TABLE "etl_stage"."dim_customer"'))
        # The live count is checked inside the swap, after the INSERT.
        count = pg.ran('SELECT count(*) FROM "erp"."dim_customer"')
        self.assertEqual(len(count), 1)
        self.assertLess(pg.log.index(pg.ran('INSERT INTO "erp"')[0]), pg.log.index(count[0]))
        self.assertEqual(pg.log[-1], "COMMIT")

    def test_merge_short_of_the_staged_rows_rolls_back(self):
        # A key repeated in the source, one copy equal to the live row: merge
        # keeps that row and inserts neither repeat — replace would have hit
        # the key. The swap must fail and roll back instead.
        with self.assertRaises(p.LoadRefused) as cm:
            self.push("merge", live_rows=1)
        self.assertIn("primary key repeated", str(cm.exception))

    def test_merge_rollback_leaves_live_untouched(self):
        pg = FakePg(answers={"pg_attribute": SHAPE_ROWS,
                             'SELECT count(*) FROM "erp"."dim_customer"': [(3,)]},
                    rowcounts={"DELETE FROM": 0, "INSERT INTO": 0})
        ms = FakeMs(cols=("CustomerKey", "CustomerName"), rows=[("C1", "A"), ("C1", "A")])
        with quiet(), self.assertRaises(p.LoadRefused):
            p.push_table(ms, pg, "bi.vw_DimCustomer", "erp.dim_customer", {}, None, swap="merge")
        self.assertEqual(pg.log[-1], "ROLLBACK")
        self.assertEqual(pg.log.count("COMMIT"), 1)  # only the staging transaction committed

    def test_merge_work_mem_is_local_to_the_merge_swap(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(p.merge_work_mem(), "64MB")
        pg, _ = self.push("merge")
        sets = pg.ran("set_config('work_mem', %s, true)")  # true = SET LOCAL
        self.assertEqual(len(sets), 1)
        self.assertLess(pg.log.index(sets[0]), pg.log.index(pg.ran('DELETE FROM "erp"')[0]))
        pg, _ = self.push("replace")
        self.assertFalse(pg.ran("work_mem"))
        pg, _ = self.push("merge", env={"ETL_MERGE_WORK_MEM": "0"})
        self.assertFalse(pg.ran("work_mem"))

    def test_merge_without_a_primary_key_falls_back_to_replace(self):
        no_pk = [(n, g, d, None) for n, g, d, _ in SHAPE_ROWS]
        pg, res = self.push("merge", shape_rows=no_pk)
        self.assertEqual(res.swap, "replace")
        self.assertIn('DELETE FROM "erp"."dim_customer"', pg.log)  # whole-table delete

    def test_row_floor_still_reads_the_staged_count(self):
        pg = FakePg(answers={"pg_attribute": SHAPE_ROWS})
        ms = FakeMs(cols=("CustomerKey",), rows=[("C1",)])
        with mock.patch.dict(os.environ, {"ETL_MIN_ROW_RATIO": "0.5"}), \
                self.assertRaises(p.LoadRefused):
            p.push_table(ms, pg, "bi.vw_DimCustomer", "erp.dim_customer", {}, 10, swap="merge")
        self.assertFalse(pg.ran('DELETE FROM "erp"'))


# ---------------------------------------------------------------------------
# Locks, the session guard and exit codes
# ---------------------------------------------------------------------------

class FakeClock:
    def __init__(self):
        self.t = 0.0
        self.sleeps: list[float] = []

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


def lock_pg(core=False, table=True, pids=(4242, 4242)):
    pid_iter = iter(pids)
    return FakePg(answers={
        "pg_backend_pid": lambda n: [(next(pid_iter),)],
        "pg_try_advisory_lock(hashtextextended('etl:core-run'": lambda n: [(core(n) if callable(core) else core,)],
        "pg_try_advisory_lock(hashtextextended('etl:table:'": [(table,)],
        "pg_advisory_lock(": [(True,)],
        "pg_advisory_unlock": [(True,)],
        "set_config": [("x",)],
        "pg_locks": [],
    })


class Locks(unittest.TestCase):
    def test_core_lock_wait_zero_tries_once(self):
        pg, clock = lock_pg(core=False), FakeClock()
        with quiet():
            got = p.acquire_core_lock(pg, 0, sleep=clock.sleep, clock=clock)
        self.assertFalse(got)
        self.assertEqual(len(pg.ran("pg_try_advisory_lock(hashtextextended('etl:core-run'")), 1)
        self.assertEqual(clock.sleeps, [])

    def test_core_lock_retries_every_15s_until_the_wait_runs_out(self):
        pg, clock = lock_pg(core=False), FakeClock()
        with quiet():
            got = p.acquire_core_lock(pg, 1, sleep=clock.sleep, clock=clock)
        self.assertFalse(got)
        self.assertEqual(clock.sleeps, [15, 15, 15, 15])
        # Tries at 0, 15, 30, 45 and 60 s; the holder is looked up once, for the log line.
        self.assertEqual(len(pg.ran("pg_try_advisory_lock(hashtextextended('etl:core-run'")), 5)
        self.assertEqual(len(pg.ran("pg_locks")), 1)

    def test_core_lock_acquired_on_a_retry(self):
        pg, clock = lock_pg(core=lambda n: n >= 3), FakeClock()
        with quiet():
            self.assertTrue(p.acquire_core_lock(pg, 45, sleep=clock.sleep, clock=clock))
        self.assertEqual(clock.sleeps, [15, 15])

    def plan(self, if_idle, tables=("erp.fact_available_to_sell",)):
        by_name = {t["target_table"]: t for t in REAL_CFG["tables"]}
        return p.RunPlan(profile="ats", tables=[by_name[t] for t in tables], post_load=False,
                         http=False, ledger=None, lock=None, lock_wait_minutes=0,
                         statement_timeout="60s", if_idle=if_idle)

    def test_if_idle_skips_a_busy_table_without_a_job_runs_row(self):
        pg = lock_pg(table=False)
        push = mock.Mock()
        with quiet():
            res = p.load_tables(pg, FakeMs(), self.plan(if_idle=True), {}, {}, push=push)
        push.assert_not_called()
        self.assertEqual(res.skipped, ["erp.fact_available_to_sell"])
        self.assertEqual(res.failures, [])
        self.assertFalse(pg.ran("log_job_run"))
        self.assertFalse(pg.ran("pg_advisory_unlock"))  # never held
        self.assertEqual(p.exit_code(res.failures, res.skipped), 3)

    def test_without_if_idle_the_lock_blocks_and_is_released_even_on_failure(self):
        pg = lock_pg()
        push = mock.Mock(side_effect=RuntimeError("boom"))
        with quiet():
            res = p.load_tables(pg, FakeMs(), self.plan(if_idle=False), {}, {}, push=push)
        self.assertTrue(pg.ran("pg_advisory_lock(hashtextextended('etl:table:'"))
        self.assertFalse(pg.ran("pg_try_advisory_lock"))
        self.assertEqual(len(pg.ran("pg_advisory_unlock")), 1)
        self.assertEqual(res.failed_tables, ["erp.fact_available_to_sell"])
        self.assertEqual(len(pg.ran("log_job_run")), 1)
        self.assertEqual(p.exit_code(res.failures, res.skipped), 1)

    def test_success_logs_and_unlocks(self):
        pg = lock_pg()
        push = mock.Mock(return_value=p.Pushed(818, "replace"))
        with quiet():
            res = p.load_tables(pg, FakeMs(), self.plan(if_idle=True), {}, {}, push=push)
        self.assertEqual(res.loaded, {"erp.fact_available_to_sell"})
        self.assertEqual(res.total_rows, 818)
        self.assertEqual(push.call_args.kwargs["swap"], "replace")
        self.assertEqual(len(pg.ran("pg_advisory_unlock")), 1)
        self.assertEqual(p.exit_code(res.failures, res.skipped), 0)

    def test_session_mode_guard(self):
        self.assertIsNone(p.session_mode_problem(
            "postgresql://postgres.x:hunter2@aws-0.pooler.supabase.com:5432/postgres", {}))
        msg = p.session_mode_problem(
            "postgresql://postgres.x:hunter2@aws-0.pooler.supabase.com:6543/postgres", {})
        self.assertIn("6543", msg)
        self.assertNotIn("hunter2", msg)
        self.assertIn("6543", p.session_mode_problem("host=h port=6543 password=hunter2", {}))
        self.assertIn("6543", p.session_mode_problem("host=h dbname=postgres", {"PGPORT": "6543"}))
        bad = p.session_mode_problem("postgresql://u:hunter2@h:notaport/db x=", {})
        self.assertIsNotNone(bad)
        self.assertNotIn("hunter2", bad)

    def test_backend_pid_must_not_change(self):
        self.assertTrue(p.backend_is_stable(lock_pg(pids=(1, 1))))
        self.assertFalse(p.backend_is_stable(lock_pg(pids=(1, 2))))


class MainBusyPaths(unittest.TestCase):
    ENV = {"PG_CONN": "postgresql://u:pw@db.example:5432/postgres", "MSSQL_CONN": "Driver=x"}

    def run_main(self, argv, pg):
        ms = FakeMs()
        with mock.patch.dict(os.environ, self.ENV), \
                mock.patch.object(p.psycopg, "connect", return_value=pg), \
                mock.patch.object(p, "mssql_connect", return_value=ms) as msc, \
                mock.patch.object(p.time, "sleep", side_effect=AssertionError("slept")), \
                quiet():
            code = p.main(argv)
        return code, msc

    def test_hourly_skips_when_a_full_run_holds_the_core_lock(self):
        pg = lock_pg(core=False)
        code, msc = self.run_main(["--profile", "hourly"], pg)
        self.assertEqual(code, 3)
        msc.assert_not_called()                     # no ERP read
        self.assertFalse(pg.ran("log_job_run"))     # no ledger, no table rows
        self.assertFalse(pg.ran("pg_advisory_unlock(hashtextextended('etl:core-run'"))
        self.assertTrue(pg.closed)

    def test_ats_whose_only_table_is_busy_exits_3(self):
        pg = lock_pg(table=False)
        code, msc = self.run_main(["--profile", "ats", "--if-idle"], pg)
        self.assertEqual(code, 3)
        msc.assert_called_once()
        self.assertFalse(pg.ran("etl:core-run"))    # ats takes no core lock
        self.assertFalse(pg.ran("log_job_run"))
        self.assertIn("select set_config('statement_timeout', %s, false)", pg.log)

    def test_pooler_that_changes_backend_is_refused(self):
        pg = lock_pg(pids=(1, 2))
        code, msc = self.run_main(["--profile", "ats"], pg)
        self.assertEqual(code, 2)
        msc.assert_not_called()

    def test_transaction_pooler_port_refused_before_connecting(self):
        with mock.patch.dict(os.environ, {"PG_CONN": "postgresql://u:pw@h:6543/postgres",
                                          "MSSQL_CONN": "x"}), \
                mock.patch.object(p.psycopg, "connect", side_effect=AssertionError("connected")), \
                quiet():
            self.assertEqual(p.main([]), 2)


if __name__ == "__main__":
    unittest.main()
