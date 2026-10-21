# schedule-evidence keeps AddressSanitizer. Windows must not pass SAN="".

import unittest
from pathlib import Path


class ScheduleSanitizerTest(unittest.TestCase):
    def test_harness_does_not_clear_the_sanitizer(self):
        text = Path(__file__).resolve().parent.joinpath("harness.py").read_text(encoding="utf-8")
        self.assertNotIn('env["SAN"]', text)
        self.assertNotIn("SAN=", text)
        self.assertIn('["just", "schedule-evidence"], cwd=ROOT)', text)


if __name__ == "__main__":
    unittest.main()
