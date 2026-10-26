"""The endurance gate must reject actual resource, cadence, log and state faults."""
from contextlib import closing
import json
import os
import runpy
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import harness as h


class Bounds(unittest.TestCase):
    def rows(self, n=40):
        return [dict(rss_bytes=16*1024**2, fds=8, threads=2) for _ in range(n)]

    def test_stable_resources_pass(self):
        rows = self.rows()
        self.assertIsNone(h.check_resources(rows))
        rows[-1]["rss_bytes"] = h.BOUNDS["rss_bytes"] + 1
        with self.assertRaisesRegex(RuntimeError, "rss_bytes"):
            h.check_resources(rows)

    def test_each_absolute_limit_can_fail(self):
        for key in ("rss_bytes", "fds", "threads"):
            with self.subTest(key=key):
                rows = self.rows()
                rows[-1][key] = h.BOUNDS[key] + 1
                with self.assertRaisesRegex(RuntimeError, key):
                    h.check_resources(rows)

    def test_each_growth_limit_can_fail_below_absolute_limit(self):
        for key, growth in (("rss_bytes", "rss_growth_bytes"), ("fds", "fd_growth"), ("threads", "thread_growth")):
            with self.subTest(key=key):
                rows = self.rows()
                for row in rows[-12:]:
                    row[key] += h.BOUNDS[growth] + 1
                with self.assertRaisesRegex(RuntimeError, "growth"):
                    h.check_resources(rows)

    def test_zero_or_single_samples_fail(self):
        for rows in ([], self.rows(1)):
            with self.assertRaisesRegex(RuntimeError, "fewer than 2"):
                h.check_resources(rows)

    def cadence(self):
        return [dict(started=1+15*i, seconds=0.2, code=0, samples=2) for i in range(4)]

    def test_nominal_cadence_passes(self):
        self.assertIsNone(h.check_cadence(self.cadence(), 60, 15))
        with self.assertRaises(RuntimeError):
            h.check_cadence(self.cadence()[::2], 60, 15)

    def test_missing_first_last_and_middle_runs_fail(self):
        for rows in (self.cadence()[1:], self.cadence()[:-1], self.cadence()[::2]):
            with self.assertRaises(RuntimeError):
                h.check_cadence(rows, 60, 15)

    def test_early_late_failed_unsampled_and_stuck_runs_fail(self):
        for key, value in (("started", 8), ("started", 28), ("code", 1), ("samples", 0), ("seconds", 11)):
            rows = self.cadence()
            rows[1][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                h.check_cadence(rows, 60, 15)

    def test_log_growth_can_fail(self):
        h.check_logs(1024, 60)
        with self.assertRaisesRegex(RuntimeError, "log bytes"):
            h.check_logs(h.BOUNDS["log_base_bytes"]+61*h.BOUNDS["log_bytes_per_second"], 60)

    def test_process_sampling_is_real(self):
        row = h.resources(os.getpid())
        self.assertGreater(row["rss_bytes"], 0)
        self.assertGreater(row["fds"], 0)
        self.assertGreater(row["threads"], 0)
        self.assertIsNone(h.resources(999999999))

    def test_module_imports_from_the_shallow_guest_mount(self):
        source = h.Path(h.__file__).resolve()
        self.assertEqual(h.ROOT / "tools/test-endurance/harness.py", source)
        with patch.object(h.Path, "resolve", return_value=Path("/harness/harness.py")):
            module = runpy.run_path(str(source), run_name="endurance_guest_import")
        self.assertEqual(module["ROOT"], Path("/"))

    def test_host_rejects_desktop_before_docker(self):
        class Args:
            pass
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), \
             patch.object(h, "run", side_effect=AssertionError("docker ran")):
            with self.assertRaisesRegex(RuntimeError, "disposable GitHub Actions"):
                h.host(Args())

    def test_journal_requires_real_changed_record_and_complete_record(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            log = folder / "ext4.log"
            header = b"LEITAJL1" + (9).to_bytes(2, "little") + b"/workload"
            log.write_bytes(header + bytes([1]) + bytes(16))
            with self.assertRaisesRegex(RuntimeError, "no directory changes"):
                h.check_journal(folder)
            log.write_bytes(header + bytes([3]) + bytes(16))
            self.assertEqual(h.check_journal(folder)["changed"], 1)
            log.write_bytes(log.read_bytes() + b"x")
            with self.assertRaisesRegex(RuntimeError, "partial journal"):
                h.check_journal(folder)


class History(unittest.TestCase):
    def fixture(self, directory):
        data = directory / "data/leita"
        data.mkdir(parents=True)
        with closing(sqlite3.connect(data / "settings.db")) as db, db:
            db.executescript("CREATE TABLE run(id INTEGER PRIMARY KEY, started INTEGER, bytes INTEGER, problem TEXT, updated INTEGER); INSERT INTO run VALUES(1,100,8192,'',1);")
        with closing(sqlite3.connect(data / "history.db")) as db, db:
            db.executescript("CREATE TABLE snapshot(id INTEGER PRIMARY KEY, taken INTEGER, bytes INTEGER); CREATE TABLE entry(snapshot INTEGER); INSERT INTO snapshot VALUES(1,100,8192);")
        return data

    def test_consistent_stores_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            self.assertEqual(h.check_database(directory, 1)["latest_bytes"], 8192)

    def test_store_mismatch_failed_scan_no_incremental_and_orphans_fail(self):
        for filename, sql, error in (
            ("history.db", "UPDATE snapshot SET bytes=4096", "disagrees"),
            ("settings.db", "UPDATE run SET problem='scan failed'", "scan failure"),
            ("settings.db", "UPDATE run SET updated=0", "incremental"),
            ("history.db", "INSERT INTO entry VALUES(999)", "orphaned"),
        ):
            with self.subTest(sql=sql), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                data = self.fixture(directory)
                with closing(sqlite3.connect(data / filename)) as db, db:
                    db.execute(sql)
                with self.assertRaisesRegex(RuntimeError, error):
                    h.check_database(directory, 1)

    def test_each_invocation_requires_a_new_matching_history_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            data = self.fixture(directory)
            self.assertIsNone(h.check_run(directory, 100, 101))
            with self.assertRaisesRegex(RuntimeError, "did not commit a new run"):
                h.check_run(directory, 115, 116)
            with closing(sqlite3.connect(data / "history.db")) as db, db:
                db.execute("UPDATE snapshot SET taken=101")
            self.assertIsNone(h.check_run(directory, 100, 101))
            with closing(sqlite3.connect(data / "history.db")) as db, db:
                db.execute("UPDATE snapshot SET bytes=4096")
            with self.assertRaisesRegex(RuntimeError, "inconsistent history"):
                h.check_run(directory, 100, 101)

    def test_missing_run_and_snapshot_fail(self):
        for filename, sql in (("settings.db", "DELETE FROM run"),
                              ("history.db", "DELETE FROM snapshot")):
            with self.subTest(sql=sql), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                data = self.fixture(directory)
                with closing(sqlite3.connect(data / filename)) as db, db:
                    db.execute(sql)
                with self.assertRaisesRegex(RuntimeError, "retention mismatch"):
                    h.check_database(directory, 1)

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            with self.assertRaisesRegex(RuntimeError, "retention mismatch"):
                h.check_database(directory, 2)


if __name__ == "__main__":
    unittest.main()
