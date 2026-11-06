"""Exercise the actual adapters with disposable process/report fixtures."""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent
BASH = shutil.which("bash")
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


def report(code=0):
    free = {0: 500, 1: 500, 2: 150, 3: 20}[code]
    return {"schema": "leita.report/1", "generated": "2026-11-06T12:00:00Z",
            "generator": {"name": "leita", "version": "fixture"},
            "target": {"path": "/replaced/by/fixture", "engine": "walk"},
            "scan": {"started": "2026-11-06T12:00:00Z", "duration": "PT1.000S"},
            "totals": {"bytes": 123, "files": 2, "directories": 1, "unread": 0},
            "space": {"total": 1000, "free": free},
            "thresholds": {"warn_used": 80, "fail_used": 95, "min_free": None,
                           "used_percent": (1000 - free) / 10,
                           "verdict": {0: "ok", 1: "ok", 2: "warn", 3: "fail"}[code],
                           "reasons": []}}


SPEC = importlib.util.spec_from_file_location("rmm_check", ROOT / "check.py")
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class CaptureCancellation(unittest.TestCase):
    def arguments(self):
        return argparse.Namespace(leita="/fixture/leita", target="/fixture/target", warn_used=80,
                                  fail_used=95, min_free_bytes=0, timeout_seconds=1)

    def child(self):
        child = MagicMock()
        child.stdout, child.stderr = io.BytesIO(), io.BytesIO()
        child.returncode = -9
        child.poll.return_value = 0
        return child

    def test_cancellation_during_capture_setup_stops_the_owned_scanner(self):
        child = self.child()
        with patch.object(CHECK.subprocess, "Popen", return_value=child), \
             patch.object(CHECK, "Capture", side_effect=KeyboardInterrupt), \
             patch.object(CHECK, "stop") as stop:
            code, output, errors, reason = CHECK.scan(self.arguments())
        stop.assert_called_once_with(child)
        self.assertEqual((code, output, errors, reason), (-9, b"", b"", "scan cancelled"))
        self.assertTrue(child.stdout.closed)
        self.assertTrue(child.stderr.closed)

    def test_cancellation_during_capture_join_still_stops_and_closes(self):
        child = self.child()
        captures = []
        for stream in (child.stdout, child.stderr):
            capture = MagicMock()
            capture.stream, capture.data = stream, bytearray()
            capture.thread.ident = 123
            capture.thread.is_alive.return_value = False
            captures.append(capture)
        captures[0].thread.join.side_effect = [KeyboardInterrupt, None]
        with patch.object(CHECK.subprocess, "Popen", return_value=child), \
             patch.object(CHECK, "Capture", side_effect=captures), \
             patch.object(CHECK, "stop") as stop:
            _, _, _, reason = CHECK.scan(self.arguments())
        self.assertEqual(reason, "scan cancelled")
        stop.assert_called_once_with(child)
        self.assertEqual(captures[0].thread.join.call_count, 2)
        self.assertTrue(child.stdout.closed)
        self.assertTrue(child.stderr.closed)

    def test_capture_start_error_stops_the_owned_scanner(self):
        child = self.child()
        capture = MagicMock()
        capture.stream, capture.data = child.stdout, bytearray()
        capture.thread.start.side_effect = RuntimeError("reader unavailable")
        capture.thread.ident = None
        capture.thread.is_alive.return_value = False
        with patch.object(CHECK.subprocess, "Popen", return_value=child), \
             patch.object(CHECK, "Capture", return_value=capture), \
             patch.object(CHECK, "stop") as stop:
            _, _, _, reason = CHECK.scan(self.arguments())
        self.assertIn("cannot capture Leita output", reason)
        stop.assert_called_once_with(child)
        self.assertTrue(child.stderr.closed)

    def test_second_signal_during_cleanup_preserves_timeout_status(self):
        child = self.child()
        child.poll.return_value = None
        captures = []
        for stream in (child.stdout, child.stderr):
            capture = MagicMock()
            capture.stream, capture.data = stream, bytearray()
            capture.thread.ident = 123
            capture.thread.is_alive.return_value = False
            captures.append(capture)
        with patch.object(CHECK.subprocess, "Popen", return_value=child), \
             patch.object(CHECK, "Capture", side_effect=captures), \
             patch.object(CHECK.time, "monotonic", side_effect=[100, 101]), \
             patch.object(CHECK, "stop", side_effect=lambda _child: signal.raise_signal(signal.SIGTERM)):
            _, _, _, reason = CHECK.scan(self.arguments())
        self.assertEqual(reason, "scan timed out")

    def test_cleanup_defers_second_signal_and_restores_handlers(self):
        original = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        with CHECK.cleanup_signals():
            for sig in original:
                self.assertEqual(signal.getsignal(sig), signal.SIG_IGN)
        for sig, handler in original.items():
            self.assertEqual(signal.getsignal(sig), handler)


@unittest.skipUnless(os.name == "posix" and BASH, "process fixtures require POSIX executable scripts and Bash")
class BashRecipes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="leita rmm ")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.leita = self.work / "Leita CLI"
        self.fixture = self.work / "fixture.json"
        self.arguments = self.work / "arguments.json"
        self.pid_file = self.work / "pid"
        self.target = str(self.work / "target with spaces 'quotes' $() ; 日本語\nnext")
        self.leita.write_text("#!" + sys.executable + "\n" + '''import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
Path(os.environ['RMM_ARGUMENTS']).write_text(json.dumps(args))
Path(os.environ['RMM_PID']).write_text(str(os.getpid()))
fixture = json.loads(Path(os.environ['RMM_FIXTURE']).read_text())
time.sleep(fixture.get('sleep', 0))
sys.stderr.write(fixture.get('stderr', ''))
if 'raw' in fixture:
    sys.stdout.write(fixture['raw'])
else:
    data = fixture.get('report')
    if data is not None:
        if not fixture.get('keep_target'):
            data['target']['path'] = args[0]
        print(json.dumps(data))
sys.exit(fixture.get('code', 0))
''')
        self.leita.chmod(0o755)
        self.environment = dict(os.environ, LEITA_RMM_PYTHON=sys.executable,
                                RMM_FIXTURE=str(self.fixture), RMM_ARGUMENTS=str(self.arguments),
                                RMM_PID=str(self.pid_file))

    def command(self, *extra):
        return [BASH, str(ROOT / "check.sh"), "--leita", str(self.leita),
                "--target", self.target, *extra]

    def invoke(self, fixture, *extra):
        self.fixture.write_text(json.dumps(fixture))
        return subprocess.run(self.command(*extra), env=self.environment, capture_output=True,
                              text=True, timeout=10)

    def result(self, completed):
        self.assertEqual(len(completed.stdout.splitlines()), 1)
        return json.loads(completed.stdout)

    def test_all_scan_exit_codes_keep_their_meaning(self):
        for code in (0, 1, 2, 3):
            with self.subTest(code=code):
                completed = self.invoke({"code": code, "report": report(code)})
                self.assertEqual(completed.returncode, code)
                result = self.result(completed)
                self.assertEqual(result["leita_exit"], code)
                self.assertEqual(result["outcome"], {0: "ok", 1: "error", 2: "warn", 3: "fail"}[code])

    def test_argument_boundaries_and_read_only_flags(self):
        completed = self.invoke({"report": report(), "stderr": "fixture diagnostic\n"})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        args = json.loads(self.arguments.read_text())
        self.assertEqual(args[0], self.target)
        self.assertEqual(args[1:], ["--whole", "--no-history", "--report", "-", "--format", "json",
                                   "--top", "1", "--color", "never", "--warn-used", "80", "--fail-used", "95"])
        self.assertIn("fixture diagnostic\n", completed.stderr)
        self.assertEqual(self.result(completed)["requested_target"], self.target)

    def test_custom_limits_and_minimum_free_boundary(self):
        data = report()
        data["thresholds"].update(warn_used=None, fail_used=None, min_free=500)
        completed = self.invoke({"report": data}, "--warn-used", "0", "--fail-used", "0", "--min-free-bytes", "500")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        data["space"]["free"] = 499
        data["thresholds"].update(used_percent=50.1, verdict="fail")
        completed = self.invoke({"report": data, "code": 3}, "--warn-used", "0", "--fail-used", "0", "--min-free-bytes", "500")
        self.assertEqual(completed.returncode, 3, completed.stderr)

    def test_report_percentage_is_rounded_to_six_decimals(self):
        data = report(2)
        data["space"] = {"total": 100000003, "free": 19999999}
        data["thresholds"]["used_percent"] = 80.000002
        completed = self.invoke({"report": data, "code": 2})
        self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_incomplete_missing_malformed_or_wrong_target_is_never_healthy(self):
        fixtures = [{"raw": ""}, {"raw": "not JSON"}, {"raw": "[]"},
                    {"raw": '{"schema":"leita.report/1","schema":"leita.report/1"}'}]
        for key in ("schema", "generator", "generated", "scan", "totals", "space", "thresholds"):
            data = report()
            del data[key]
            fixtures.append({"report": data})
        for change in (lambda d: d.update(schema="leita.report/2"),
                       lambda d: d["totals"].update(unread=1),
                       lambda d: d["totals"].update(unread=True),
                       lambda d: d["totals"].pop("files"),
                       lambda d: d["target"].update(engine="synthetic"),
                       lambda d: d["scan"].update(duration="still scanning"),
                       lambda d: d["scan"].update(started=None),
                       lambda d: d.update(space=None),
                       lambda d: d["space"].update(free=1001),
                       lambda d: d["thresholds"].update(used_percent=float("nan")),
                       lambda d: d["thresholds"].update(used_percent=0),
                       lambda d: d["thresholds"].update(warn_used=90),
                       lambda d: d["thresholds"].update(verdict="warn")):
            data = report()
            change(data)
            fixtures.append({"report": data})
        fixtures.append({"report": report(), "keep_target": True})
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                completed = self.invoke(fixture)
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertEqual(self.result(completed)["outcome"], "error")

    def test_error_exit_cannot_be_hidden_by_valid_json_and_unknown_exit_is_error(self):
        for code in (1, 7):
            completed = self.invoke({"report": report(), "code": code})
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(self.result(completed)["outcome"], "error")

    def test_missing_executable_is_an_error(self):
        self.leita.unlink()
        completed = self.invoke({"report": report()})
        self.assertEqual(completed.returncode, 1)
        self.assertIsNone(self.result(completed)["leita_exit"])
        self.assertIn("cannot start Leita", completed.stderr)

    def test_timeout_stops_the_scanner(self):
        completed = self.invoke({"sleep": 10}, "--timeout-seconds", "0.5")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("timed out", self.result(completed)["error"])
        with self.assertRaises(ProcessLookupError):
            os.kill(int(self.pid_file.read_text()), 0)

    def test_cancellation_stops_the_scanner(self):
        self.fixture.write_text(json.dumps({"sleep": 10}))
        process = subprocess.Popen(self.command(), env=self.environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not self.pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.pid_file.exists())
            process.terminate()
            stdout, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1)
            self.assertIn("cancelled", json.loads(stdout)["error"])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(self.pid_file.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_output_is_bounded_and_oversized_reports_fail(self):
        completed = self.invoke({"raw": " " * (1024 * 1024 + 1)})
        self.assertEqual(completed.returncode, 1)
        self.assertIn("exceeded", self.result(completed)["error"])
        completed = self.invoke({"report": report(), "stderr": "x" * 5000})
        self.assertEqual(completed.returncode, 0)
        self.assertLess(len(completed.stderr), 4300)
        self.assertIn("omitted", completed.stderr)

    def test_bad_adapter_arguments_are_errors_not_threshold_warnings(self):
        completed = self.invoke({}, "--not-a-flag")
        self.assertEqual(completed.returncode, 1)
        completed = self.invoke({}, "--warn-used", "0", "--fail-used", "0")
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(self.result(completed)["outcome"], "error")

    @unittest.skipUnless(POWERSHELL, "PowerShell runtime not installed")
    def test_powershell_preserves_arguments_and_exit_codes(self):
        # These fixtures need no network. Configure the runtime before it starts,
        # rather than letting unrelated telemetry/update checks obscure a stall.
        # https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_environment_variables
        environment = dict(self.environment, POWERSHELL_TELEMETRY_OPTOUT="1",
                           POWERSHELL_UPDATECHECK="Off")

        def run_stage(stage, arguments):
            started = time.monotonic()
            try:
                completed = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", *arguments],
                                           env=environment, capture_output=True, text=True, timeout=10)
            except subprocess.TimeoutExpired as exc:
                self.fail(f"PowerShell {stage} exceeded 10s; "
                          f"scanner_started={self.pid_file.exists()}, "
                          f"arguments_written={self.arguments.exists()}; "
                          f"stdout={(exc.stdout or b'')[:4096]!r}; "
                          f"stderr={(exc.stderr or b'')[:4096]!r}")
            print(f"PowerShell fixture {stage}: {time.monotonic() - started:.3f}s, "
                  f"exit={completed.returncode}, scanner_started={self.pid_file.exists()}, "
                  f"arguments_written={self.arguments.exists()}", file=sys.stderr)
            return completed

        # Keep cold-runtime failure separate from the wrapper and fake scanner.
        # This is a real bounded native check, not a retry or a larger deadline.
        startup = run_stage("startup", ["-Command", "[Console]::WriteLine($PSVersionTable.PSVersion.ToString())"])
        self.assertEqual(startup.returncode, 0, startup.stderr)
        self.assertRegex(startup.stdout.strip(), r"^\d+\.\d+\.\d+(?:\.\d+)?(?:[-+].*)?$")
        print(f"PowerShell fixture runtime version: {startup.stdout.strip()}", file=sys.stderr)
        for code in (0, 1, 2, 3):
            with self.subTest(code=code):
                self.arguments.unlink(missing_ok=True)
                self.pid_file.unlink(missing_ok=True)
                self.fixture.write_text(json.dumps({"report": report(code), "code": code,
                                                    "stderr": "fixture diagnostic\n"}))
                completed = run_stage(f"wrapper scan exit {code}", [
                    "-File", str(ROOT / "check.ps1"), "-PythonPath", sys.executable,
                    "-LeitaPath", str(self.leita), "-Target", self.target,
                    "-TimeoutSeconds", "2"])
                self.assertEqual(completed.returncode, code, completed.stderr)
                self.assertEqual(json.loads(self.arguments.read_text()), [self.target,
                                 "--whole", "--no-history", "--report", "-", "--format", "json",
                                 "--top", "1", "--color", "never", "--warn-used", "80", "--fail-used", "95"])
                result = self.result(completed)
                self.assertEqual(result["leita_exit"], code)
                self.assertEqual(result["requested_target"], self.target)
                self.assertEqual(result["outcome"], {0: "ok", 1: "error", 2: "warn", 3: "fail"}[code])
                self.assertIn("fixture diagnostic", completed.stderr)


if __name__ == "__main__":
    unittest.main()
