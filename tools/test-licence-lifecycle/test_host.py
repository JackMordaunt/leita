# The capture build's define spelling and the Windows shell it may call.

import os
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

    def test_wsl_program_files_launcher_is_not_the_build_shell(self):
        wsl = str(Path("C:/Program Files/WSL/bash.exe"))
        git = str(Path("C:/Program Files/Git/bin/bash.exe"))
        self.assertEqual(host.prefer_bash([wsl]), "")
        self.assertEqual(host.prefer_bash([wsl, git]), git)

    def test_only_wsl_launchers_select_nothing_even_when_the_files_exist(self):
        paths = [
            str(Path("C:/Windows/System32/bash.exe")),
            str(Path("C:/Windows/Sysnative/bash.exe")),
            str(Path("C:/Program Files/WSL/bash.exe")),
            str(Path("C:/Users/runner/AppData/Local/Microsoft/WindowsApps/bash.exe")),
        ]
        git = str(Path("C:/Program Files/Git/bin/bash.exe"))
        self.assertEqual(host.first_bash(paths, exists=lambda _path: True), "")
        self.assertEqual(host.first_bash(paths + [git], exists=lambda _path: True), git)

    def test_a_missing_earlier_bash_is_not_createprocess_target(self):
        # The eighth Windows log's Path starts in the MSVC bin directory.
        earlier = str(Path("C:/Program Files/Microsoft Visual Studio/18/Enterprise/VC/Tools/MSVC/bin/HostX64/x64/bash.exe"))
        git = str(Path("C:/Program Files/Git/bin/bash.exe"))
        wsl = str(Path("C:/Program Files/WSL/bash.exe"))
        chosen = host.first_bash([earlier, wsl, git], exists=lambda path: Path(path) == Path(git))
        self.assertEqual(Path(chosen), Path(git))

    def test_plain_dict_path_key_is_seen(self):
        git = "/usr/local/git/bin"
        system = "/usr/bin"
        entries = host.path_entries({"Path": git + os.pathsep + system})
        self.assertEqual(entries, [git, system])


if __name__ == "__main__":
    unittest.main()
