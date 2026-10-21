# _finish must read both pipes. A child that fills them has to exit on its own.

import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

import transaction

PIPE_PAST_CAPACITY = 256 * 1024
MARKER = "update refused the second copy"


def _child(script):
    return subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


class FinishPipesTest(unittest.TestCase):
    def test_a_full_pipe_is_drained_and_the_child_is_not_killed(self):
        script = (
            "import sys\n"
            f"blob = b'x' * {PIPE_PAST_CAPACITY}\n"
            "sys.stdout.buffer.write(blob)\n"
            "sys.stderr.buffer.write(blob)\n"
        )
        proc = _child(script)
        seen = []

        def version(binary, args, env, timeout=90):
            seen.append((binary, list(args), dict(env), timeout))
            return 0, "leita v0.0.2", "version-step-stderr"

        env = {
            "PATH": "/usr/bin",
            "LEITA_UPDATE_HOLD_COMMIT": "hold",
            "LEITA_RELEASE_BASE": "http://127.0.0.1/release",
        }
        box = []

        def run():
            with patch.object(transaction.harness, "invoke", version):
                box.append(transaction._finish(proc, env, "leita"))

        thread = threading.Thread(target=run)
        thread.start()
        thread.join(15)
        if thread.is_alive():
            proc.kill()
            proc.wait(timeout=5)
            self.fail("finish blocked on a full pipe")
        self.assertEqual(proc.returncode, 0)
        code, out, err = box[0]
        self.assertEqual(code, 0)
        self.assertEqual(out, "leita v0.0.2")
        self.assertEqual(err, "version-step-stderr")
        self.assertEqual(len(seen), 1)
        binary, args, got, timeout = seen[0]
        self.assertEqual(binary, "leita")
        self.assertEqual(args, ["--version"])
        self.assertEqual(timeout, 90)
        self.assertNotIn("LEITA_UPDATE_HOLD_COMMIT", got)
        self.assertNotIn("LEITA_RELEASE_BASE", got)
        self.assertEqual(got["PATH"], "/usr/bin")

    def test_a_failed_update_reports_its_own_stderr(self):
        script = (
            "import sys\n"
            f"sys.stderr.buffer.write(b'e' * {PIPE_PAST_CAPACITY})\n"
            f"sys.stderr.buffer.write({MARKER!r}.encode())\n"
            "sys.stdout.buffer.write(b'stdout-side')\n"
            "raise SystemExit(3)\n"
        )
        proc = _child(script)
        seen = []

        def version(*_args, **_kwargs):
            seen.append(True)
            return 0, "leita v0.0.2", "version-step-stderr"

        with patch.object(transaction.harness, "invoke", version):
            code, out, err = transaction._finish(proc, {}, "leita")
        self.assertEqual(seen, [])
        self.assertEqual(code, 3)
        self.assertEqual(out, "stdout-side")
        self.assertGreaterEqual(len(err), PIPE_PAST_CAPACITY)
        self.assertTrue(err.endswith(MARKER))
        self.assertNotIn("version-step-stderr", err)
        self.assertEqual(proc.returncode, 3)
