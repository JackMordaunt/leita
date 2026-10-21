# Fixture checks that do not build Leita. A signature here is throwaway.

import base64
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
import tempfile

import fixture


def post(url, payload):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8"))


class FixtureTest(unittest.TestCase):
    def test_mint_verifies_and_tamper_does_not(self):
        key = fixture.keygen()
        line = fixture.mint_licence(
            key.seed, "ord_fixture", "ada@example.com", "personal", "pro",
            "2027-01-01T00:00:00Z", "2026-10-19T12:00:00Z",
        )
        head, _, sig = line.rpartition(".")
        self.assertTrue(fixture.verify_bytes(key.public_hex, head.encode("ascii"), base64.b64decode(sig)))
        tampered = fixture.tamper_line(line)
        head, _, sig = tampered.rpartition(".")
        self.assertFalse(fixture.verify_bytes(key.public_hex, head.encode("ascii"), base64.b64decode(sig)))
        self.assertNotEqual(key.seed.hex(), "")

    def test_activation_answers_and_stall_close_returns(self):
        shop = fixture.Shop()
        shop.lines["FIXTURE-KEY-OK"] = "leita.example"
        shop.stall.add("FIXTURE-KEY-STALL")
        shop.stall_seconds = 30
        with fixture.ActivationServer(shop) as server:
            status, body = post(server.url, {"key": "FIXTURE-KEY-OK"})
            self.assertEqual(status, 200)
            self.assertEqual(body["licence"], "leita.example")
            status, body = post(server.url, {"key": "FIXTURE-KEY-UNKNOWN"})
            self.assertEqual(status, 404)
            self.assertIn("message", body)
            started = time.time()
            thread = threading.Thread(target=lambda: post(server.url, {"key": "FIXTURE-KEY-STALL"}))
            thread.start()
            deadline = time.time() + 2
            while not any(hit["key"] == "FIXTURE-KEY-STALL" for hit in shop.seen) and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(any(hit["key"] == "FIXTURE-KEY-STALL" for hit in shop.seen))
        self.assertLess(time.time() - started, 5)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())

    def test_release_signature_is_raw_and_not_in_the_sums(self):
        key = fixture.keygen()
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            fixture.write_release(
                directory,
                {"leita-window-linux-amd64": b"window-bytes"},
                "v0.2.0",
                "2026-12-01T00:00:00Z",
                key.seed,
            )
            sums = (directory / "sha256sums.txt").read_bytes()
            sig = (directory / "sha256sums.txt.sig").read_bytes()
            self.assertEqual(len(sig), 64)
            self.assertNotIn(b"sha256sums.txt.sig", sums)
            self.assertEqual(len((directory / fixture.RELEASED_NAME).read_bytes()), 21)
            source = Path(__file__).resolve().parents[2] / "update" / "update.odin"
            self.assertIn(f'RELEASED_FILE :: "{fixture.RELEASED_NAME}"', source.read_text(encoding="utf-8"))
            self.assertTrue(fixture.verify_bytes(key.public_hex, sums, sig))
            with fixture.ReleaseServer(directory, delay=0) as server:
                with urllib.request.urlopen(server.url + "/version.txt", timeout=2) as response:
                    self.assertEqual(response.read(), b"v0.2.0\n")
                self.assertEqual(server.requests[0]["path"], "version.txt")


if __name__ == "__main__":
    unittest.main()
