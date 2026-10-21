import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import harness


class ChildEnvironmentTest(unittest.TestCase):
    def test_licence_folder_matches_each_native_history_location(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for system in ("linux", "darwin", "windows"):
                with self.subTest(system=system), patch.object(harness, "system_name", return_value=system):
                    env, folder = harness.child_env(work)
                    if system == "darwin":
                        expected = Path(env["HOME"]) / "Library" / "Application Support" / "leita"
                    elif system == "windows":
                        expected = Path(env["LOCALAPPDATA"]) / "leita"
                    else:
                        expected = Path(env["XDG_DATA_HOME"]) / "leita"
                    self.assertEqual(folder, expected)
                    self.assertTrue(folder.is_relative_to(work))
