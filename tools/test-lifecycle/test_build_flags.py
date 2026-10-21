"""Build and run the release recipe with fixed numeric public-key defines."""

import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseKeyBuildTest(unittest.TestCase):
    def test_release_build_runs_with_numeric_key_defines(self):
        env = os.environ.copy()
        # Fixed values keep this command-line input identical on each OS.
        # This build test does not sign a licence or release.
        env.update({
            "LEITA_LICENCE_KEY": "12" * 32,
            "LEITA_UPDATE_KEY": "34" * 32,
            "LEITA_VERSION": "v0.0.1-key-shape-test",
            "LEITA_RELEASED": "2026-10-21T00:00:00Z",
        })
        build = subprocess.run(
            ["just", "cli", "release"], cwd=ROOT, env=env,
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        binary = ROOT / "build" / "release" / ("leita.exe" if os.name == "nt" else "leita")
        run = subprocess.run(
            [str(binary), "--version"], cwd=ROOT, env=env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(env["LEITA_VERSION"], run.stdout)
