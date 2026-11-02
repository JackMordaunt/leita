"""Archive safety/contents checks; these do not claim native FreeBSD execution."""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("freebsd_native", Path(__file__).with_name("native.py"))
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


class DependencyTests(unittest.TestCase):
    SOURCE = ('sqlite_defines := "-DSQLITE_THREADSAFE=1 " + ' + chr(92) + "\n" +
              '  "-DSQLITE_ENABLE_FTS5 -DSQLITE_OMIT_LOAD_EXTENSION"\n'
              '_hot name mode dirs: unavailable_freebsd_dependency\n'
              '    echo unused\n')

    @unittest.skipUnless(shutil.which("just"), "just is needed to reproduce the invalid recipe graph")
    def test_invalid_jm_recipe_graph_does_not_block_literal_define_read(self):
        with tempfile.TemporaryDirectory() as directory:
            justfile = Path(directory) / "justfile"
            justfile.write_text(self.SOURCE)
            result = subprocess.run(["just", "--justfile", str(justfile), "--evaluate", "sqlite_defines"],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown dependency", result.stderr)
            with patch.object(native, "run", side_effect=AssertionError("must not execute jm justfile")):
                self.assertEqual(native.sqlite_defines(justfile),
                                 "-DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_OMIT_LOAD_EXTENSION")

    def test_define_expressions_and_non_defines_fail_explicitly(self):
        for expression in ['env("FLAGS")', '"-DSQLITE_THREADSAFE=1" + other', '"-O0"', '""']:
            with self.subTest(expression=expression), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "justfile"
                path.write_text("sqlite_defines := " + expression + "\n")
                with self.assertRaises(ValueError):
                    native.sqlite_defines(path)

    def test_native_build_uses_root_flags_and_direct_odin_without_jm_recipes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jm = root / "jm"
            jm.mkdir()
            (jm / "justfile").write_text(self.SOURCE)
            values = {"jm": str(jm), "speed_opt": "-debug -o:speed",
                      "flags": "-vet -collection:jm=jm -define:LEITA_VERSION=v9.8.7"}
            with patch.object(native, "ROOT", root), patch.object(native, "native_host"), \
                 patch.object(native, "value", side_effect=values.__getitem__), \
                 patch.object(native, "run") as command, patch.dict(os.environ, {"ODIN": "odin"}):
                binary = native.build("speed")
            calls = [call.args[0] for call in command.call_args_list]
            self.assertFalse(any(argv[0] == "just" for argv in calls))
            sqlite = next(argv for argv in calls if "-DSQLITE_THREADSAFE=1" in argv)
            self.assertIn("-DSQLITE_ENABLE_FTS5", sqlite)
            self.assertIn("-DSQLITE_OMIT_LOAD_EXTENSION", sqlite)
            self.assertEqual((jm / "sqlite3/lib/defines").read_text(),
                             "-DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_OMIT_LOAD_EXTENSION\n")
            odin = calls[-1]
            self.assertEqual(odin[:4], ["odin", "build", "cmd/cli", "-target:freebsd_amd64"])
            self.assertIn("-define:LEITA_VERSION=v9.8.7", odin)
            self.assertEqual(odin[-1], f"-out:{binary}")


class PackageTests(unittest.TestCase):
    def test_archive_carries_cli_notices_link_metadata_and_matching_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary = work / "leita"
            binary.write_bytes(b"candidate executable")
            metadata = {"version": "v1.2.3", "native_ufs_zfs_acceptance": False}
            archive = native.write_archive(binary, work / "out", "v1.2.3", metadata)
            with tarfile.open(archive) as tar:
                base = "leita-v1.2.3-freebsd-amd64"
                self.assertEqual(tar.extractfile(f"{base}/bin/leita").read(), binary.read_bytes())
                self.assertEqual(tar.getmember(f"{base}/bin/leita").mode, 0o755)
                short = tar.getmember(f"{base}/bin/le")
                self.assertTrue(short.issym())
                self.assertEqual(short.linkname, "leita")
                for notice in ["LICENSE.md", "THIRD_PARTY.md"]:
                    self.assertEqual(tar.extractfile(f"{base}/share/doc/leita/{notice}").read(),
                                     (native.ROOT / notice).read_bytes())
                self.assertEqual(json.load(tar.extractfile(f"{base}/BUILD.json")), metadata)
                self.assertFalse(any(name.endswith((".so", ".a")) for name in tar.getnames()))
            self.assertEqual(archive.with_suffix(".gz.sha256").read_text(),
                             f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")

    def test_version_cannot_create_paths_or_control_characters(self):
        for version in ["../escape", "/tmp/x", "a/b", "a\nb", "", " space", "a\\b"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                native.archive_name(version)

    def test_native_guard_refuses_other_platforms_and_architectures(self):
        for system, machine in [("Darwin", "arm64"), ("Linux", "x86_64"), ("FreeBSD", "aarch64")]:
            with self.subTest(system=system, machine=machine), \
                 patch.object(native.platform, "system", return_value=system), \
                 patch.object(native.platform, "machine", return_value=machine), \
                 self.assertRaises(SystemExit):
                native.native_host()


if __name__ == "__main__":
    unittest.main()
