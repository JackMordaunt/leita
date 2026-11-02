#!/usr/bin/env python3
"""Enforce the native VM result on the host after copying/uploading evidence."""
from pathlib import Path
import re
import sys


def check_status(path):
    try:
        content = path.read_text()
    except (OSError, UnicodeError) as error:
        print(f"native VM status is unavailable: {error}", file=sys.stderr)
        return 1
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,2})\n?", content) or int(content) > 255:
        print("native VM status is malformed; acceptance was not established", file=sys.stderr)
        return 1
    status = int(content)
    print(f"native VM gate status: {status}")
    return status


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_gate.py STATUS_FILE")
    raise SystemExit(check_status(Path(sys.argv[1])))
