# The capture build's define spelling and the Windows shell it may call.

import unittest
from pathlib import Path

import host


class HostBuildTest(unittest.TestCase):
    def test_define_flag_is_a_single_quoted_string(self):
        value = "12" * 32
        flag = host.define_flag("LEITA_UPDATE_KEY", value)
        self.assertEqual(flag, f"-define:LEITA_UPDATE_KEY='{value}'")
        self.assertNotIn('"', flag)
        released = host.define_flag("LEITA_RELEASED", "2027-01-01T00:00:00Z")
        self.assertEqual(released, "-define:LEITA_RELEASED='2027-01-01T00:00:00Z'")

    def test_capture_build_passes_single_quotes_through(self):
        text = Path(__file__).resolve().parents[1].joinpath("capture", "build").read_text(encoding="utf-8")
        self.assertIn("-define:${capture_name}='${capture_value}'", text)

    def test_wsl_bash_is_not_the_build_shell(self):
        chosen = host.prefer_bash([
            str(Path("C:/Windows/System32/bash.exe")),
            str(Path("C:/Windows/System32/bash")),
            str(Path("C:/Users/runner/AppData/Local/Microsoft/WindowsApps/bash.exe")),
            str(Path("C:/Program Files/Git/bin/bash.exe")),
        ])
        self.assertEqual(Path(chosen), Path("C:/Program Files/Git/bin/bash.exe"))
        self.assertEqual(host.prefer_bash([str(Path("C:/Windows/System32/bash.exe"))]), "")


if __name__ == "__main__":
    unittest.main()
