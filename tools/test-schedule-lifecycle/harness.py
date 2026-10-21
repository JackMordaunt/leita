#!/usr/bin/env python3
"""Write scheduler lifecycle evidence from the desk schedule test.

The native lifecycle workflow runs this file when it is present:

    LIFECYCLE_DIR=build/lifecycle LIFECYCLE_SHA="$(git rev-parse HEAD)" \
        python3 tools/test-schedule-lifecycle/harness.py

It runs `just schedule-evidence` (clock-boundary and real-host HTTP tests) and writes
evidence-schedule.json. automatic_startup_check and automatic_daily_check
pass only when both tests exit 0. production_signature stays false.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = ("automatic_startup_check", "automatic_daily_check")


def system_name():
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("win"):
        return "windows"
    raise SystemExit(f"no operating system name for {sys.platform}")


def git_sha():
    given = os.environ.get("LIFECYCLE_SHA", "").strip()
    if given:
        return given
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()


def main():
    sha = git_sha()
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        raise SystemExit(f"sha {sha!r} is not the 40-character git sha")
    system = system_name()
    directory = Path(os.environ.get("LIFECYCLE_DIR", ROOT / "build" / "lifecycle"))
    directory.mkdir(parents=True, exist_ok=True)
    # Keep just's default -sanitize:address. Windows cleanup must not call
    # os.remove_all; that path is SHFileOperationW and ASan aborts in it.
    proc = subprocess.run(["just", "schedule-evidence"], cwd=ROOT)
    status = "pass" if proc.returncode == 0 else "fail"
    detail = "" if status == "pass" else f"just schedule-evidence exited {proc.returncode}"
    doc = {
        "schema": 1,
        "producer": "schedule",
        "sha": sha,
        "os": system,
        "production_signature": False,
        "fixture": "throwaway-ed25519",
        "cases": [{"id": case_id, "status": status, "detail": detail} for case_id in CASES],
    }
    (directory / "evidence-schedule.json").write_text(json.dumps(doc, indent=2) + "\n")
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


if __name__ == "__main__":
    main()
