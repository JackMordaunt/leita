import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import compat_probe as p  # noqa: E402


def pe(machine):
    head = bytearray(0x80)
    head[:2] = b"MZ"
    struct.pack_into("<I", head, 0x3C, 0x40)
    head[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<H", head, 0x44, machine)
    return bytes(head)


class ProbeTest(unittest.TestCase):
    def machine(self, code):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(pe(code))
        try:
            return p.pe_machine(f.name)
        finally:
            os.unlink(f.name)

    def test_pe_machine(self):
        self.assertEqual(self.machine(0x8664), "AMD64")
        self.assertEqual(self.machine(0xAA64), "ARM64")
        self.assertEqual(self.machine(0x1234), "0x1234")

    def test_not_a_pe(self):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"ELF")
        try:
            with self.assertRaises(ValueError):
                p.pe_machine(f.name)
        finally:
            os.unlink(f.name)

    def test_server_proves_nothing(self):
        # A hosted windows-2022 or 2025 runner is neither Windows 10 22H2 nor
        # a Windows 11 desktop, whatever its build number.
        self.assertEqual(p.proves(20348, "Microsoft Windows Server 2022 Datacenter", "X64", "AMD64"), [])
        self.assertEqual(p.proves(26100, "Microsoft Windows Server 2025 Datacenter", "X64", "AMD64"), [])
        # The edition alone is the difference from a desktop at the same build.
        self.assertEqual(p.proves(26100, "Microsoft Windows 11 Pro", "X64", "AMD64"), ["windows-11-x64"])
        self.assertEqual(p.proves(19045, "Microsoft Windows Server 2019", "X64", "AMD64"), [])

    def test_windows_10_22h2(self):
        self.assertEqual(p.proves(19045, "Microsoft Windows 10 Pro", "X64", "AMD64"), ["windows-10-22h2-x64"])
        self.assertEqual(p.proves(19044, "Microsoft Windows 10 Pro", "X64", "AMD64"), [])

    def test_windows_11_x64(self):
        self.assertEqual(p.proves(26100, "Microsoft Windows 11 Pro", "X64", "AMD64"), ["windows-11-x64"])

    def test_arm_pilot_needs_an_x64_binary_on_an_arm_os(self):
        got = p.proves(26100, "Microsoft Windows 11 Enterprise", "Arm64", "AMD64")
        self.assertEqual(got, ["windows-11-arm64-x64-emulation"])
        self.assertEqual(p.proves(26100, "Microsoft Windows 11 Enterprise", "Arm64", "ARM64"), [])

    def test_engine(self):
        mft = "target C:\\\n\nvolume    100 GB, 4096 B clusters\nmft       900 slots, 880 records, 0 unreadable, read in 3 ms\n"
        walk = "target D:\\x\nwalk: 8 readers at Full pace\n"
        self.assertEqual(p.classify_engine(mft), "mft")
        self.assertEqual(p.classify_engine(walk), "walk")
        self.assertEqual(p.classify_engine("nothing"), "unknown")

    def test_mft_walk_is_a_fallback_not_a_pass(self):
        self.assertEqual(p.stage_status_mft(0, "walk: 8 readers at Full pace\n"), "fallback")
        self.assertEqual(p.stage_status_mft(0, "mft  1 slots, 1 records"), "passed")
        self.assertEqual(p.stage_status_mft(0, ""), "failed")
        self.assertEqual(p.stage_status_mft(1, "mft  1 slots"), "failed")
        self.assertEqual(p.stage_status_mft(0xC0000005, "mft  1 slots"), "failed")

    def test_scan_needs_every_name(self):
        self.assertEqual(p.stage_status_scan(0, "a,b", ["a", "b"]), "passed")
        self.assertEqual(p.stage_status_scan(0, "a", ["a", "b"]), "failed")
        self.assertEqual(p.stage_status_scan(1, "a,b", ["a", "b"]), "failed")


if __name__ == "__main__":
    unittest.main()
