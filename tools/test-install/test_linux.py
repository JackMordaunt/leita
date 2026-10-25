# tools/test-install/linux starts no systemd guest off a CI runner:
#   python3 -m unittest discover -s tools/test-install -p 'test_*.py'
# A docker on PATH that records any call shows nothing was started.

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

LINUX = Path(__file__).resolve().parent / "linux"


class SystemdGuestOffCi(unittest.TestCase):
    def run_linux(self, *guests, ci=""):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            called = tmp / "called"
            docker = bin_dir / "docker"
            docker.write_text(f"#!/bin/sh\necho \"$@\" >> '{called}'\nexit 1\n")
            docker.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if k not in ("CI", "GITHUB_ACTIONS")}
            env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
            if ci:
                env["CI"] = ci
            proc = subprocess.run(["bash", str(LINUX), str(tmp), str(tmp), *guests], env=env, capture_output=True, text=True, timeout=60)
            return proc, called.exists()

    def test_named_systemd_guest_is_refused(self):
        proc, called = self.run_linux("deb:debian-12", "deb:debian-12:systemd")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("only on a CI runner", proc.stderr)
        self.assertFalse(called, "docker was run")

    def test_default_guests_are_refused(self):
        # The default list holds systemd guests, so it is refused whole.
        proc, called = self.run_linux()
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(called, "docker was run")

    def test_ci_false_is_not_ci(self):
        proc, called = self.run_linux("rpm:fedora-42:systemd", ci="false")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(called, "docker was run")


if __name__ == "__main__":
    unittest.main()
