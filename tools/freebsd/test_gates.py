"""Run the native gate shell with fake commands; preserve every failure status."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

GATES = Path(__file__).with_name("gates").resolve()


class GateTests(unittest.TestCase):
    def check_gate(self, unit, fixtures, expected, binary=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "commands"
            commands.mkdir()
            for name, status in [("su", unit), ("python3", fixtures)]:
                script = commands / name
                script.write_text(f'#!/bin/sh\nprintf "%s\\n" {name} >> "$GATE_LOG"\nexit {status}\n')
                script.chmod(0o755)
            if binary:
                cli = root / "build/speed/leita"
                cli.parent.mkdir(parents=True)
                cli.write_text("#!/bin/sh\nexit 0\n")
                cli.chmod(0o755)
            log = root / "calls"
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                       GATE_LOG=str(log), ODIN="/opt/leita-odin/odin")
            result = subprocess.run(["sh", str(GATES)], cwd=root, env=env,
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["su", "python3"] if binary else ["su"])

    def test_both_gates_pass(self):
        self.check_gate(0, 0, 0)

    def test_unit_failure_still_runs_filesystem_matrix_and_fails(self):
        self.check_gate(7, 0, 7)

    def test_incomplete_filesystem_matrix_fails(self):
        self.check_gate(0, 2, 2)

    def test_both_failures_preserve_unit_status_and_run_filesystem_matrix(self):
        self.check_gate(7, 9, 7)

    def test_missing_binary_fails(self):
        self.check_gate(0, 0, 1, binary=False)

    def test_missing_binary_preserves_unit_failure(self):
        self.check_gate(7, 0, 7, binary=False)


if __name__ == "__main__":
    unittest.main()
