"""Allocation reconciliation and safe fixture ownership, without a Leita build."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("truth_runner", Path(__file__).with_name("runner.py"))
assert SPEC and SPEC.loader
truth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(truth)


def oracle(**extra):
    result = {"unique_regular_files": 2, "symlinks": 1, "directories": 2, "unread_paths": [],
              "identities_known": True, "blocks_known": True, "other_entries": [],
              "stat_regular_allocated_bytes": 1024, "directory_allocated_bytes": 512,
              "symlink_allocated_bytes": 0}
    return result | extra


def report(**extra):
    return {"schema": "leita.report/1", "accounting": {"logical": False, "scan_order": False},
            "totals": {"bytes": 1024, "files": 3, "directories": 2, "unread": 0} | extra}


class Workspace(unittest.TestCase):
    def test_existing_directory_and_contents_are_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "keep").write_text("untouched")
            with self.assertRaisesRegex(ValueError, "already exists"):
                truth.create_workspace(root)
            self.assertEqual((root / "keep").read_text(), "untouched")

    def test_dangling_symlink_is_not_a_fresh_workspace(self):
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "link"
            link.symlink_to(Path(tmp) / "missing")
            with self.assertRaises(ValueError):
                truth.create_workspace(link)
            self.assertTrue(link.is_symlink())
            self.assertFalse((Path(tmp) / "missing").exists())

    def test_missing_parent_does_not_create_path_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            absent = Path(tmp) / "absent"
            with self.assertRaises(FileNotFoundError):
                truth.create_workspace(absent / "child")
            self.assertFalse(absent.exists())

    def test_fresh_workspace_is_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = truth.create_workspace(Path(tmp) / "fresh")
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)


@unittest.skipUnless(os.name == "posix", "native POSIX allocation metadata")
class NativeOracle(unittest.TestCase):
    def test_cross_directory_aliases_count_one_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "links"
            truth.materialize(root, "hard-links", random.Random(7))
            measured = truth.snapshot(root)
            self.assertEqual(measured["unique_regular_files"], 2)
            self.assertEqual(measured["hard_link_aliases"], 2)
            self.assertEqual(measured["directories"], 2)
            self.assertEqual(measured["apparent_regular_bytes"], 200000)
            expected = sum((root / name).stat().st_blocks * 512 for name in ("a/payer", "independent"))
            self.assertEqual(measured["stat_regular_allocated_bytes"], expected)

    def test_symlinks_are_recorded_without_following_or_charging_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "symlinks"
            truth.materialize(root, "symlinks", random.Random(8))
            measured = truth.snapshot(root)
            self.assertEqual(measured["unique_regular_files"], 1)
            self.assertEqual(measured["symlinks"], 4)
            self.assertEqual(measured["apparent_regular_bytes"], 70000)
            self.assertFalse(any("must-not-follow" in e["path"] for e in measured["entries"]))
            self.assertEqual(measured["stat_regular_allocated_bytes"], (root / "target").stat().st_blocks * 512)

    def test_holes_use_actual_allocation_not_file_length(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "sparse"
            feature = truth.materialize(root, "sparse", random.Random(9))
            measured = truth.snapshot(root)
            self.assertEqual(measured["apparent_regular_bytes"], 2 * 1048576)
            self.assertEqual(measured["stat_regular_allocated_bytes"], sum(p.stat().st_blocks * 512 for p in root.iterdir()))
            self.assertEqual(set(feature["sparse_files"]), {"hole-only", "data-and-holes"})

    def test_fixture_mutation_changes_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "f").write_bytes(b"first")
            before = truth.snapshot(root)
            (root / "f").write_bytes(b"second")
            self.assertNotEqual(before, truth.snapshot(root))

    def test_unread_fixture_is_explicit_when_permissions_are_bypassed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "unread"
            try:
                feature = truth.materialize(root, "unread", random.Random(10))
                measured = truth.snapshot(root)
                self.assertEqual(bool(measured["unread_paths"]), feature["permission_denial_observed"])
            finally:
                (root / "sealed").chmod(0o700)


class Judgement(unittest.TestCase):
    def test_exact_semantics_pass(self):
        self.assertEqual(truth.verdict(truth.compare(report(), oracle(), "apfs", True)), "pass")

    def test_wrong_charge_and_duplicate_file_count_fail(self):
        checks = truth.compare(report(bytes=2048, files=5), oracle(), "apfs", True)
        self.assertEqual(truth.verdict(checks), "fail")
        self.assertEqual({c["name"] for c in checks if c["verdict"] == "fail"}, {"files", "allocated-bytes"})

    def test_boolean_is_not_an_integer_byte_total(self):
        checks = truth.compare(report(bytes=True), oracle(stat_regular_allocated_bytes=1), "apfs", True)
        self.assertEqual(truth.verdict(checks), "fail")

    def test_unknown_filesystem_does_not_infer_allocation_truth(self):
        checks = truth.compare(report(bytes=999999), oracle(), None, True)
        self.assertEqual(checks[-1]["verdict"], "unknown")
        self.assertNotEqual(truth.verdict(checks), "fail")

    def test_unestablished_btrfs_shared_allocation_is_unknown(self):
        self.assertEqual(truth.compare(report(), oracle(), "btrfs", True)[-1]["verdict"], "unknown")

    def test_unknown_identity_does_not_deduplicate_by_guess(self):
        checks = truth.compare(report(files=99), oracle(identities_known=False), "apfs", True)
        self.assertTrue(all(c["verdict"] == "unknown" for c in checks))

    def test_logical_and_scan_order_reports_are_not_allocation_oracles(self):
        for flag in ("logical", "scan_order"):
            doc = report()
            doc["accounting"][flag] = True
            self.assertEqual(truth.compare(doc, oracle(), "apfs", True)[-1]["verdict"], "unknown")

    def test_mutated_fixture_is_not_a_correctness_failure(self):
        checks = truth.compare(report(bytes=999), oracle(), "apfs", False)
        self.assertEqual(truth.verdict(checks), "unknown")

    def test_bad_schema_and_nonobject_json_fail(self):
        for doc in ({}, [], {"schema": "future/2", "totals": {}}):
            self.assertEqual(truth.verdict(truth.compare(doc, oracle(), "apfs", True)), "fail")

    def test_unread_count_is_part_of_the_contract(self):
        self.assertEqual(truth.verdict(truth.compare(report(), oracle(unread_paths=["sealed"]), "apfs", True)), "fail")

    def test_du_reconciles_metadata_extras_and_rounds_total_once(self):
        result = {"exit": 0, "stdout": "2\t/single-operand\n"}
        check = truth.compare_du(result, oracle(), True, "apfs")
        self.assertEqual(check["verdict"], "pass")
        self.assertEqual(check["expected_kib"], 2)  # ceil((1024 + 512 + 0)/1024)
        result["stdout"] = "3\t/single-operand\n"
        self.assertEqual(truth.compare_du(result, oracle(), True, "apfs")["verdict"], "fail")

    def test_failed_du_and_partial_trees_are_unknown(self):
        for result, measured in (({"exit": 1, "stdout": "2\troot\n"}, oracle()),
                                 ({"exit": 0, "stdout": "2\troot\n"}, oracle(unread_paths=["sealed"]))):
            self.assertEqual(truth.compare_du(result, measured, True, "apfs")["verdict"], "unknown")

    def test_unknown_identity_prevents_du_deduplication_claim(self):
        result = {"exit": 0, "stdout": "99\troot\n"}
        self.assertEqual(truth.compare_du(result, oracle(identities_known=False), True, "apfs")["verdict"], "unknown")

    def test_successful_unparseable_du_is_a_failure(self):
        self.assertEqual(truth.compare_du({"exit": 0, "stdout": "nonsense"}, oracle(), True, "apfs")["verdict"], "fail")

    def test_failed_cli_run_is_retained_as_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(truth, "command", return_value={"exit": 7, "stdout": "[]", "stderr": "failed"}):
                result = truth.run_case(Path(tmp) / "dense", "dense", Path("/fake/leita"), {}, "apfs", random.Random(1))
            self.assertEqual(result["verdict"], "fail")
            self.assertEqual(result["leita"]["exit"], 7)
            self.assertEqual(result["coverage"], "not-completed")

    def test_nonobject_totals_remain_structured_failed_cases(self):
        for totals in (None, [], "wrong type"):
            with self.subTest(totals=totals), tempfile.TemporaryDirectory() as tmp:
                process = {"exit": 0, "stdout": json.dumps({"schema": "leita.report/1", "totals": totals}), "stderr": ""}
                with patch.object(truth, "command", return_value=process):
                    result = truth.run_case(Path(tmp) / "dense", "dense", Path("/fake/leita"), {}, "apfs", random.Random(1))
                self.assertEqual(result["verdict"], "fail")
                self.assertEqual(result["coverage"], "not-completed")
                self.assertEqual(result["report"]["totals"], totals)

    def test_main_retains_nonobject_totals_in_json_and_table(self):
        for totals in (None, [], "wrong type"):
            with self.subTest(totals=totals), tempfile.TemporaryDirectory() as tmp:
                binary = Path(tmp) / "leita"
                binary.write_text("fixture executable identity only")
                binary.chmod(0o700)
                workspace = Path(tmp) / "fresh"
                process = {"exit": 0, "stdout": json.dumps({"schema": "leita.report/1", "totals": totals}), "stderr": ""}
                with patch.object(truth, "command", return_value=process), \
                     patch.object(truth, "filesystem", return_value={"name": "apfs", "evidence": []}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    code = truth.main(["--leita", str(binary), "--workspace", str(workspace)])
                result = json.loads((workspace / "results.json").read_text())
                self.assertEqual(code, 1)
                self.assertGreater(result["summary"]["fail"], 0)
                self.assertEqual(result["cases"][0]["report"]["totals"], totals)
                self.assertIn("unknown | fail", (workspace / "table.md").read_text())

    def test_main_emits_json_and_nonzero_for_wrong_tool_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "leita"
            binary.write_text("fixture executable identity only")
            binary.chmod(0o700)
            with patch.object(truth, "command", return_value={"exit": 0, "stdout": json.dumps(report(bytes=999)), "stderr": ""}), \
                 patch.object(truth, "filesystem", return_value={"name": "apfs", "evidence": []}):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    code = truth.main(["--leita", str(binary), "--workspace", str(Path(tmp) / "fresh")])
            result = json.loads(stdout.getvalue())
            self.assertEqual(code, 1)
            self.assertGreater(result["summary"]["fail"], 0)
            self.assertEqual(result["schema"], truth.SCHEMA)
            self.assertTrue((Path(tmp) / "fresh" / "results.json").exists())


@unittest.skipUnless(os.name == "posix", "command pipe selectors and owned process groups are POSIX")
class Processes(unittest.TestCase):
    def test_nonzero_exit_retains_stdout_and_stderr(self):
        result = truth.command([sys.executable, "-c", "import sys; print('output'); sys.stderr.write('diagnostic'); sys.exit(7)"])
        self.assertEqual(result["exit"], 7)
        self.assertEqual(result["stdout"], "output\n")
        self.assertEqual(result["stderr"], "diagnostic")
        self.assertIsNone(result["error"])

    def test_output_limits_retain_a_bounded_prefix_and_fail(self):
        for name in ("stdout", "stderr"):
            with self.subTest(stream=name), patch.object(truth, "STDOUT_LIMIT", 1024), \
                 patch.object(truth, "STDERR_LIMIT", 1024):
                result = truth.command([sys.executable, "-c", f"import sys; sys.{name}.write('x'*2048)"])
            self.assertIsNone(result["exit"])
            self.assertEqual(result["error"], name + "-limit")
            self.assertTrue(result[name + "_truncated"])
            if name == "stdout":
                self.assertEqual(result[name], "x" * 1024)
            else:
                self.assertTrue(result[name].startswith("x" * 1024))
                self.assertLess(len(result[name]), 1200)

    def test_deadline_stops_a_descendant_that_keeps_pipes_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            heartbeat = Path(tmp) / "heartbeat"
            child = "from pathlib import Path; import sys,time; p=Path(sys.argv[1]);\nwhile True: p.write_text(str(time.time_ns())); time.sleep(.01)"
            # The parent exits immediately; its child still holds both pipes.
            parent = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]]); print(p.pid,flush=True)"
            started = time.monotonic()
            with patch.object(truth, "COMMAND_TIMEOUT", 0.5):
                result = truth.command([sys.executable, "-c", parent, child, str(heartbeat)])
            self.assertLess(time.monotonic() - started, 3)
            self.assertIsNone(result["exit"])
            self.assertEqual(result["error"], "timeout")
            self.assertTrue(heartbeat.exists(), result)
            value = heartbeat.read_text()
            time.sleep(0.1)
            self.assertEqual(heartbeat.read_text(), value, "the descendant stops writing after timeout")

    def test_cancellation_during_pipe_setup_reaps_the_child(self):
        original = subprocess.Popen
        started = []

        def launch(*args, **kwargs):
            process = original(*args, **kwargs)
            started.append(process)
            return process

        with patch.object(truth.subprocess, "Popen", side_effect=launch), \
             patch.object(truth.selectors, "DefaultSelector", side_effect=KeyboardInterrupt):
            result = truth.command([sys.executable, "-c", "import time; time.sleep(30)"])
        self.assertEqual(result["error"], "cancelled")
        self.assertIsNotNone(started[0].poll())
        self.assertEqual(started[0].returncode, -signal.SIGKILL)

    def test_sigterm_cancels_and_reaps_the_scanner(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "pid"
            child = "from pathlib import Path; import os,sys,time; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
            controller = "import importlib.util,json,sys; s=importlib.util.spec_from_file_location('truth',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(m.command([sys.executable,'-c',sys.argv[2],sys.argv[3]])))"
            process = subprocess.Popen([sys.executable, "-B", "-c", controller, truth.__file__, child, str(pid_file)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 3
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists())
                process.terminate()
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(json.loads(stdout)["error"], "cancelled")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
