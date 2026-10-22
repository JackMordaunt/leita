#!/usr/bin/env python3
"""zigcc names the target and rewrites the two arguments zig's linker refuses,
checked against a stand-in zig that prints what it was given."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ZIGCC = Path(__file__).resolve().parent / "zigcc"


class ZigccTest(unittest.TestCase):
    def run_as(self, name: str, *args: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "zig"
            fake.write_text('#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n')
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            link = Path(tmp) / name
            link.symlink_to(ZIGCC)
            env = dict(os.environ, LEITA_ZIG=str(fake), LEITA_ZIG_TARGET="x86_64-linux-gnu.2.35")
            out = subprocess.run([str(link), *args], env=env, capture_output=True, text=True, check=True)
            return out.stdout.splitlines()

    def test_cc_names_the_target(self):
        self.assertEqual(self.run_as("cc", "-c", "a.c"), ["cc", "-target", "x86_64-linux-gnu.2.35", "-c", "a.c"])

    def test_cxx_and_clang(self):
        self.assertEqual(self.run_as("c++", "-c", "a.cc")[:3], ["c++", "-target", "x86_64-linux-gnu.2.35"])
        self.assertEqual(self.run_as("clang", "-c", "a.c")[:3], ["cc", "-target", "x86_64-linux-gnu.2.35"])

    def test_archiver_takes_no_target(self):
        self.assertEqual(self.run_as("ar", "rcs", "x.a", "y.o"), ["ar", "rcs", "x.a", "y.o"])

    def test_a_library_by_path_stands_alone(self):
        got = self.run_as("clang", '-l:"/lib/a.a"', "-l:/lib/b.a")
        self.assertEqual(got[3:], ["/lib/a.a", "/lib/b.a"])

    def test_stdcxx_becomes_libcxx(self):
        self.assertEqual(self.run_as("clang", "-lstdc++", "-lm")[3:], ["-lc++", "-lm"])


if __name__ == "__main__":
    unittest.main()
