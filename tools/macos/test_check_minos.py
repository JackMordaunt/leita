import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import check_minos as c  # noqa: E402

# llvm-otool -l of a release build's load command, as CI produced it.
BUILD = """Load command 10
       cmd LC_BUILD_VERSION
   cmdsize 32
  platform 1
       sdk 27.0
     minos %s
    ntools 1
      tool 3
   version 1267.0
"""

APPLE = BUILD.replace("platform 1", "platform macos") % "11.0"

LEGACY = """Load command 9
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version %s
      sdk 10.15
"""


class MinosTest(unittest.TestCase):
    def test_floor_passes(self):
        self.assertEqual(c.verdict("a", BUILD % "11.0", "11.0"), [])

    def test_older_than_floor_passes(self):
        self.assertEqual(c.verdict("a", BUILD % "10.13", "11.0"), [])

    def test_newer_fails_by_name(self):
        got = c.verdict("Leita", BUILD % "12.0", "11.0")
        self.assertEqual(got, ["Leita: needs macOS 12.0, the floor is 11.0"])

    def test_version_compares_as_numbers(self):
        self.assertEqual(c.verdict("a", BUILD % "11.10", "11.2"), ["a: needs macOS 11.10, the floor is 11.2"])
        self.assertEqual(c.verdict("a", BUILD % "9.0", "11.0"), [])

    def test_apple_otool_names_the_platform(self):
        self.assertEqual(c.verdict("a", APPLE, "11.0"), [])

    def test_legacy_command(self):
        self.assertEqual(c.verdict("a", LEGACY % "10.15", "11.0"), [])
        self.assertEqual(len(c.verdict("a", LEGACY % "12.0", "11.0")), 1)

    def test_fat_file_checks_every_slice(self):
        out = BUILD % "11.0" + BUILD % "13.0"
        self.assertEqual(len(c.verdict("fat", out, "11.0")), 1)

    def test_silence_is_not_a_minimum(self):
        self.assertEqual(len(c.verdict("a", "Load command 0\n      cmd LC_SEGMENT_64\n", "11.0")), 1)

    def test_other_platform_fails(self):
        out = BUILD.replace("platform 1", "platform 2") % "11.0"
        self.assertEqual(c.verdict("a", out, "11.0"), ["a: platform 2, not macos"])


if __name__ == "__main__":
    unittest.main()
