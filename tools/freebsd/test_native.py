"""Archive safety/contents checks; these do not claim native FreeBSD execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("freebsd_native", Path(__file__).with_name("native.py"))
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


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
