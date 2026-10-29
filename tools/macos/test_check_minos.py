import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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

    def test_trailing_zero_versions_are_equal(self):
        self.assertEqual(c.verdict("a", BUILD % "11.0.0", "11.0"), [])

    def test_archive_checks_later_members_and_deduplicates_failures(self):
        out = "safe.a(first.o):\n" + BUILD % "11.0"
        out += "safe.a(second.o):\n" + BUILD % "15.0"
        out += "safe.a(third.o):\n" + BUILD % "15.0"
        self.assertEqual(c.verdict("safe.a", out, "11.0"),
                         ["safe.a: needs macOS 15.0, the floor is 11.0"])

    def test_non_system_library_load_commands(self):
        out = ""
        for kind in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                     "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"):
            out += f"cmd {kind}\nname /opt/homebrew/lib/liblocal.dylib (offset 24)\n"
        out += "cmd LC_LOAD_DYLIB\nname @rpath/liblocal.dylib (offset 24)\n"
        self.assertEqual(c.external_libraries(out),
                         ["/opt/homebrew/lib/liblocal.dylib", "@rpath/liblocal.dylib"])

    def test_system_dependencies_and_own_install_name_are_allowed(self):
        out = "cmd LC_LOAD_DYLIB\nname /usr/lib/libSystem.B.dylib (offset 24)\n"
        out += "cmd LC_LOAD_WEAK_DYLIB\nname /System/Library/Frameworks/Metal.framework/Metal (offset 24)\n"
        out += "cmd LC_ID_DYLIB\nname @rpath/libself.dylib (offset 24)\n"
        self.assertEqual(c.external_libraries(out), [])

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


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("cc") and shutil.which("otool"),
                     "native Mach-O checks require macOS and its C toolchain")
class NativeMinosTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checker = Path(c.__file__).resolve()

    def compile(self, name, text, *flags):
        source = self.root / (name + ".c")
        source.write_text(text)
        output = self.root / name
        subprocess.run(["cc", *flags, str(source), "-o", str(output)],
                       check=True, capture_output=True, text=True)
        return output

    def check(self, path, *flags):
        return subprocess.run([sys.executable, str(self.checker), *flags, str(path)],
                              capture_output=True, text=True)

    def test_archive_rejects_a_newer_member_even_with_an_older_first_member(self):
        old = self.compile("old.o", "int old(void) { return 0; }", "-c", "-mmacosx-version-min=11.0")
        new = self.compile("new.o", "int new(void) { return 1; }", "-c", "-mmacosx-version-min=15.0")
        archive = self.root / "mixed.a"
        subprocess.run(["ar", "rcs", str(archive), str(old), str(new)], check=True)
        got = self.check(archive)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("needs macOS 15.0", got.stderr)

    def test_good_binary_passes_but_external_dylib_dependency_fails(self):
        good = self.compile("good", "int main(void) { return 0; }", "-mmacosx-version-min=11.0")
        got = self.check(good, "--system-only")
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        library = self.compile("external.dylib", "int answer(void) { return 0; }",
                               "-dynamiclib", "-mmacosx-version-min=11.0")
        linked = self.compile("linked", "int answer(void); int main(void) { return answer(); }",
                              "-mmacosx-version-min=11.0", str(library))
        got = self.check(linked, "--system-only")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn(f"non-system dependency {library}", got.stderr)


if __name__ == "__main__":
    unittest.main()
