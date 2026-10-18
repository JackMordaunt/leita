"""Exercise the release manifest generator without downloads or publishing."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.2.3"
ASSETS = (
    "windows-amd64-setup.exe", "windows-amd64-setup-unsigned.exe",
    "darwin-universal.dmg", "darwin-universal-unsigned.dmg",
    "windows-amd64.zip", "windows-amd64-unsigned.zip",
    "darwin-universal-cli.tar.zst", "linux-amd64.tar.zst", "linux-arm64.tar.zst",
)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.sums = {name: hashlib.sha256(name.encode()).hexdigest() for name in ASSETS}

    def generate(self):
        sums = self.work / "sha256sums.txt"
        sums.write_text("".join(
            f"{digest}  leita-v{VERSION}-{name}\n" for name, digest in self.sums.items()
        ), newline="\n")
        return subprocess.run(
            [os.environ.get("MANIFEST_TEST_BASH", "bash"),
             (ROOT / "packaging/fill-manifests.sh").as_posix(), sums.as_posix(),
             (self.work / "out").as_posix()],
            env={**os.environ, "VERSION": f"v{VERSION}"},
            text=True, capture_output=True, timeout=30,
        )

    def test_signed_preference_and_unsigned_fallback(self):
        for unsigned in (False, True):
            with self.subTest(unsigned=unsigned):
                if unsigned:
                    for name in ("windows-amd64-setup.exe", "darwin-universal.dmg",
                                 "windows-amd64.zip"):
                        del self.sums[name]
                result = self.generate()
                self.assertEqual(result.returncode, 0, result.stderr)
                out = self.work / "out"
                files = [p for p in out.rglob("*") if p.is_file()]
                self.assertEqual(len(files), 8)
                for path in files:
                    text = path.read_text()
                    self.assertIn(VERSION, text, str(path))
                    self.assertNotRegex(text, r"__[A-Z][A-Z0-9_]*__")
                suffix = "-unsigned" if unsigned else ""
                scoop = json.loads((out / "scoop/leita.json").read_text())
                self.assertEqual(scoop["version"], VERSION)
                self.assertEqual(scoop["bin"], ["leita.exe"])
                self.assertEqual(scoop["shortcuts"], [["app/Leita.exe", "Leita"]])
                self.assertEqual(scoop["extract_dir"], f"leita-v{VERSION}-windows-amd64")
                for file, asset in (
                    ("scoop/leita.json", f"windows-amd64{suffix}.zip"),
                    ("homebrew/Casks/leita.rb", f"darwin-universal{suffix}.dmg"),
                    ("winget/Librium.Leita.installer.yaml", f"windows-amd64-setup{suffix}.exe"),
                ):
                    text = (out / file).read_text()
                    self.assertIn(f"leita-v{VERSION}-{asset}", text)
                    self.assertIn(self.sums[asset], text)
                for file in ("aur/PKGBUILD", "aur/.SRCINFO", "homebrew/Formula/leita.rb"):
                    text = (out / file).read_text()
                    for asset in ("linux-amd64.tar.zst", "linux-arm64.tar.zst"):
                        self.assertIn(self.sums[asset], text)
                formula = (out / "homebrew/Formula/leita.rb").read_text()
                self.assertIn(self.sums["darwin-universal-cli.tar.zst"], formula)
                for file in ("aur/PKGBUILD", "aur/.SRCINFO"):
                    text = (out / file).read_text()
                    for source in ("packaging/linux/dev.mordaunt.Leita.desktop",
                                   "packaging/linux/dev.mordaunt.Leita.metainfo.xml",
                                   "packaging/linux/leita-journal.service", "branding/mark-light.svg"):
                        self.assertIn(hashlib.sha256((ROOT / source).read_bytes()).hexdigest(), text)

    def test_missing_checksum_rejected(self):
        del self.sums["linux-amd64.tar.zst"]
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256sums.txt has no leita-v1.2.3-linux-amd64.tar.zst", result.stderr)

    def test_malformed_checksum_rejected(self):
        self.sums["windows-amd64-setup.exe"] = "not-a-sha256"
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not 64 hex characters", result.stderr)


if __name__ == "__main__":
    unittest.main()
