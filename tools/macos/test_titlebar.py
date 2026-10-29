#!/usr/bin/env python3
"""Build and run native macOS title-bar regressions on AppKit's main thread.

Requires the normal GUI dependencies (just deps). Preferences are overridden
through each child's NSArgumentDomain; this never writes user defaults.
The visible test window is owned by the child and closes when the child exits.
This checks the current Mac, not the macOS 11 compatibility floor.
"""
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    if sys.platform != "darwin":
        print("native title-bar tests require macOS", file=sys.stderr)
        return 2
    jm = Path(os.environ.get("JM", ROOT / "jm")).resolve()
    output = ROOT / "build/test/native-titlebar"
    output.parent.mkdir(parents=True, exist_ok=True)
    link = subprocess.check_output(
        ["just", "--evaluate", "sdl3_link"], cwd=ROOT, text=True
    ).strip()
    command = [
        os.environ.get("ODIN", "odin"), "build", str(jm / "ui/shell"),
        f"-collection:jm={jm}", "-define:JM_UI_NATIVE_TITLE_TEST=true",
        "-debug", "-sanitize:address", "-vet", "-strict-style", f"-out:{output}",
        *shlex.split(link),
    ]
    subprocess.run(command, cwd=ROOT, check=True, timeout=180)
    print(f"Native title-bar checks on macOS {platform.mac_ver()[0]} {platform.machine()}", flush=True)
    for action in ("Maximize", "Fill", "Minimize", "None"):
        print(f"Process-local title-bar preference: {action}", flush=True)
        subprocess.run(
            [str(output), "-AppleActionOnDoubleClick", action],
            cwd=ROOT, check=True, timeout=45,
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"native title-bar check failed: {error}", file=sys.stderr)
        sys.exit(1)
