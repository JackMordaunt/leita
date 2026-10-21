# The fixture signs with OpenSSL. A passing test is not a production signature.

import hashlib
import tempfile
import unittest
from pathlib import Path

import fixture

ROOT = Path(__file__).resolve().parents[2]
THROWAWAY = ROOT / "licence" / "testdata" / "throwaway"


class KeyTest(unittest.TestCase):
    def test_public_half_of_the_published_licence_vector(self):
        seed = (THROWAWAY / "ed25519.seed.hex").read_text(encoding="ascii").strip()
        want = (THROWAWAY / "ed25519.public.hex").read_text(encoding="ascii").strip()
        self.assertEqual(fixture.public_hex(seed), want)

    def test_sign_verifies_and_a_flipped_byte_does_not(self):
        key = fixture.keygen()
        message = b"sha256sums.txt"
        sig = fixture.sign_bytes(key.seed, message)
        self.assertEqual(len(sig), 64)
        self.assertTrue(fixture.verify_bytes(key.public_hex, message, sig))
        flipped = bytearray(sig)
        flipped[0] ^= 1
        self.assertFalse(fixture.verify_bytes(key.public_hex, message, bytes(flipped)))

    def test_minted_line_matches_the_published_vector(self):
        seed = (THROWAWAY / "ed25519.seed.hex").read_text(encoding="ascii").strip()
        line = fixture.mint_licence(
            seed,
            ident="lic_7f3a9c2e1b",
            email="ada@example.com",
            scope="personal",
            features="pro",
            paid_through="2027-10-19T00:00:00Z",
            issued="2026-10-19T12:00:00Z",
        )
        want = (THROWAWAY / "vector-1.line").read_text(encoding="ascii").strip()
        self.assertEqual(line, want)


class ReleaseTest(unittest.TestCase):
    def test_checksums_include_version_before_the_signature(self):
        key = fixture.keygen()
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            fixture.write_release(
                directory,
                {"leita-linux-amd64": b"new-bytes"},
                version="v0.0.2",
                released="2026-10-21T00:00:00Z",
                seed=key.seed,
            )
            sums = (directory / fixture.SUMS_NAME).read_bytes()
            sig = (directory / fixture.SIG_NAME).read_bytes()
            self.assertNotIn(b"sha256sums.txt.sig", sums)
            self.assertIn(b"version.txt", sums)
            self.assertIn(b"released.txt", sums)
            self.assertTrue(fixture.verify_bytes(key.public_hex, sums, sig))
            version = (directory / "version.txt").read_bytes()
            released = (directory / "released.txt").read_bytes()
            self.assertEqual(version, b"v0.0.2\n")
            self.assertEqual(released, b"2026-10-21T00:00:00Z\n")
            self.assertIn(hashlib.sha256(version).hexdigest().encode("ascii"), sums)
            self.assertIn(hashlib.sha256(released).hexdigest().encode("ascii"), sums)

    def test_bad_signature_does_not_verify(self):
        key = fixture.keygen()
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            fixture.write_release(
                directory,
                {"leita-linux-amd64": b"new-bytes"},
                version="v0.0.2",
                released="2026-10-21T00:00:00Z",
                seed=key.seed,
                bad_sig=True,
            )
            sums = (directory / fixture.SUMS_NAME).read_bytes()
            sig = (directory / fixture.SIG_NAME).read_bytes()
            good = fixture.sign_bytes(key.seed, sums)
            self.assertTrue(fixture.verify_bytes(key.public_hex, sums, good))
            self.assertNotEqual(sig, good)
            self.assertFalse(fixture.verify_bytes(key.public_hex, sums, sig))

    def test_server_records_the_user_agent(self):
        key = fixture.keygen()
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            fixture.write_release(
                directory,
                {"leita-linux-amd64": b"new-bytes"},
                version="v0.0.2",
                released="2026-10-21T00:00:00Z",
                seed=key.seed,
            )
            with fixture.ReleaseServer(directory) as server:
                import urllib.request
                self.assertTrue(server.url.startswith("http://127.0.0.1:"))
                request = urllib.request.Request(server.url + "/version.txt", headers={"User-Agent": "leita/v0.0.1"})
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(response.read(), b"v0.0.2\n")
                self.assertEqual(server.requests[0]["user_agent"], "leita/v0.0.1")
                self.assertEqual(server.requests[0]["path"], "version.txt")


if __name__ == "__main__":
    unittest.main()
