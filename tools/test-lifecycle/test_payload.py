# Payload extraction rewrites absolute package links so they stay inside the
# extract directory. These tests do not sign a release and are not a
# production signature.

import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

import harness


def newc_member(name, mode, data):
    name_bytes = name.encode("utf-8") + b"\x00"
    fields = (
        0,
        mode,
        0,
        0,
        1,
        0,
        len(data),
        0,
        0,
        0,
        0,
        len(name_bytes),
        0,
    )
    blob = b"070701" + b"".join(f"{field:08X}".encode("ascii") for field in fields)
    blob += name_bytes
    blob += b"\x00" * ((4 - (len(blob) % 4)) % 4)
    blob += data
    blob += b"\x00" * ((4 - (len(data) % 4)) % 4)
    return blob


class PayloadTest(unittest.TestCase):
    def test_absolute_tar_symlink_is_rewritten_inside_the_extract(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            payload = b"cli-bytes"
            info = tarfile.TarInfo("usr/bin/leita")
            info.size = len(payload)
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(payload))
            link = tarfile.TarInfo("usr/libexec/leita/leita")
            link.type = tarfile.SYMTYPE
            link.linkname = "/usr/bin/leita"
            tar.addfile(link)
        with tempfile.TemporaryDirectory() as directory:
            dest = Path(directory)
            harness.extract_tar_bytes(buf.getvalue(), dest, "r:")
            binary = dest / "usr" / "bin" / "leita"
            link_path = dest / "usr" / "libexec" / "leita" / "leita"
            self.assertEqual(binary.read_bytes(), payload)
            stored = os.readlink(link_path)
            self.assertFalse(os.path.isabs(stored))
            self.assertEqual(link_path.read_bytes(), payload)
            self.assertTrue(link_path.resolve().is_relative_to(dest.resolve()))

    def test_relative_symlink_that_leaves_the_extract_is_refused(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            link = tarfile.TarInfo("usr/bin/leita")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../../../etc/passwd"
            tar.addfile(link)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                harness.extract_tar_bytes(buf.getvalue(), Path(directory), "r:")

    def test_dotdot_member_is_refused(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            info = tarfile.TarInfo("../outside")
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                harness.extract_tar_bytes(buf.getvalue(), Path(directory), "r:")

    def test_newc_cpio_rewrites_an_absolute_symlink(self):
        blob = b"".join((
            newc_member("./usr/bin/leita", 0o100755, b"cli-bytes"),
            newc_member("./usr/libexec/leita/leita", 0o120777, b"/usr/bin/leita"),
            newc_member("TRAILER!!!", 0, b""),
        ))
        with tempfile.TemporaryDirectory() as directory:
            dest = Path(directory)
            harness.extract_newc(blob, dest)
            link_path = dest / "usr" / "libexec" / "leita" / "leita"
            self.assertFalse(os.path.isabs(os.readlink(link_path)))
            self.assertEqual(link_path.read_bytes(), b"cli-bytes")
            self.assertTrue(link_path.resolve().is_relative_to(dest.resolve()))


if __name__ == "__main__":
    unittest.main()
