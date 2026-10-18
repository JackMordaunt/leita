#!/usr/bin/env python3
"""The CI ratchet's comparison, without mounting anything."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
# The tool is a script, not a module: it has no .py suffix, so the default
# file finder will not load it. dataclasses looks the class up in sys.modules
# while the body runs, so the module has to be registered first.
loader = importlib.machinery.SourceFileLoader("fsbench", str(ROOT / "fsbench"))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
fsbench = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = fsbench
loader.exec_module(fsbench)


class Judgement(unittest.TestCase):
    def test_within_tolerance_prints_both_numbers(self) -> None:
        ok, line = fsbench.judgement("tmpfs", 24.0, 24.1, 0.20)
        self.assertTrue(ok)
        self.assertIn("24.0", line)
        self.assertIn("24.1", line)
        self.assertIn("delta", line)

    def test_over_tolerance_fails_and_prints_the_delta(self) -> None:
        ok, line = fsbench.judgement("tmpfs", 40.0, 24.1, 0.20)
        self.assertFalse(ok)
        self.assertIn("40.0", line)
        self.assertIn("24.1", line)
        self.assertIn("15.9", line)

    def test_the_limit_itself_passes(self) -> None:
        ok, line = fsbench.judgement("tmpfs", 12.0, 10.0, 0.20)
        self.assertTrue(ok)
        self.assertIn("12.0", line)
        self.assertIn("10.0", line)

    def test_just_past_the_limit_fails(self) -> None:
        ok, _line = fsbench.judgement("tmpfs", 12.1, 10.0, 0.20)
        self.assertFalse(ok)


class Baseline(unittest.TestCase):
    def test_update_keeps_another_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            fsbench.write_baseline(path, "ext4", 30.0, 200_000, fsbench.SEED)
            fsbench.write_baseline(path, "tmpfs", 24.1, 200_000, fsbench.SEED)
            data = json.loads(path.read_text())
            self.assertEqual(data["tolerance"], 0.20)
            self.assertIn("runner", data["comment"].lower())
            self.assertEqual(data["filesystems"]["ext4"]["median_ms"], 30.0)
            self.assertEqual(data["filesystems"]["tmpfs"]["median_ms"], 24.1)

    def test_a_different_seed_drops_stale_medians(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            fsbench.write_baseline(path, "ext4", 30.0, 200_000, fsbench.SEED)
            fsbench.write_baseline(path, "tmpfs", 24.1, 200_000, fsbench.SEED + 1)
            data = json.loads(path.read_text())
            self.assertEqual(list(data["filesystems"]), ["tmpfs"])
            self.assertEqual(data["seed"], fsbench.SEED + 1)

    def test_check_rejects_a_missing_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            fsbench.write_baseline(path, "ext4", 30.0, 200_000, fsbench.SEED)
            with self.assertRaises(SystemExit):
                fsbench.conclude("tmpfs", 24.0, 200_000, fsbench.SEED, path, update=False)

    def test_check_passes_against_what_update_wrote(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            code = fsbench.conclude("tmpfs", 24.14, 200_000, fsbench.SEED, path, update=True)
            self.assertEqual(code, 0)
            code = fsbench.conclude("tmpfs", 24.1, 200_000, fsbench.SEED, path, update=False)
            self.assertEqual(code, 0)

    def test_check_fails_a_lower_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            fsbench.write_baseline(path, "tmpfs", 1.0, 200_000, fsbench.SEED)
            code = fsbench.conclude("tmpfs", 24.0, 200_000, fsbench.SEED, path, update=False)
            self.assertEqual(code, 1)

    def test_a_different_file_count_is_not_a_speed_regression(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            fsbench.write_baseline(path, "tmpfs", 24.0, 200_000, fsbench.SEED)
            with self.assertRaises(SystemExit) as raised:
                fsbench.conclude("tmpfs", 24.0, 100, fsbench.SEED, path, update=False)
            self.assertIn("files", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
