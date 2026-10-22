#!/usr/bin/env python3
"""List the versioned GLIBC symbols an ELF needs and fail above a floor.

    abi_gate.py --kind cli|gui --arch amd64|arm64 [--floors FILE]
                [--floor X.Y] [--require-floor] ELF...

The floor comes from --floor, else from the line "<kind> <arch> <floor>" in
FILE (default floors.conf beside this script). A floor of "-" is undeclared:
the symbols are listed and the run passes, unless --require-floor is given,
which turns an undeclared floor into a failure. Every undefined dynamic symbol
bound to a GLIBC_x.y version counts, weak references included. Exit 0 when
every ELF is at or under the floor, 1 when one is above it (or the floor is
required and missing), 2 on a usage or read error.
"""
import argparse
import os
import re
import subprocess
import sys

MACHINES = {"amd64": "Advanced Micro Devices X86-64", "arm64": "AArch64"}
SYM = re.compile(r"\sUND\s+(\S+?)@+(GLIBC_[0-9][0-9.]*)")
HERE = os.path.dirname(os.path.abspath(__file__))


def ver(text):
    return tuple(int(p) for p in text.split("."))


def readelf(*args):
    # Python 3.6 is the python3 of manylinux_2_28, which has no capture_output.
    r = subprocess.run(
        ["readelf", "-W", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if r.returncode != 0:
        raise OSError(r.stderr.strip() or "readelf failed")
    return r.stdout


def needed(path):
    """Return (machine, {version: [symbols]}) for one ELF."""
    machine = ""
    for line in readelf("-h", path).splitlines():
        if line.strip().startswith("Machine:"):
            machine = line.split(":", 1)[1].strip()
    found = {}
    for line in readelf("--dyn-syms", path).splitlines():
        m = SYM.search(line)
        if m:
            found.setdefault(m.group(2)[len("GLIBC_"):], []).append(m.group(1))
    return machine, found


def declared(floors, kind, arch):
    with open(floors) as f:
        for line in f:
            line = line.split("#", 1)[0].split()
            if len(line) == 3 and line[0] == kind and line[1] == arch:
                return None if line[2] == "-" else line[2]
    return None


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--kind", required=True, choices=["cli", "gui"])
    p.add_argument("--arch", required=True, choices=sorted(MACHINES))
    p.add_argument("--floors", default=os.path.join(HERE, "floors.conf"))
    p.add_argument("--floor")
    p.add_argument("--require-floor", action="store_true")
    p.add_argument("files", nargs="+")
    a = p.parse_args(argv)
    try:
        floor = a.floor or declared(a.floors, a.kind, a.arch)
        if floor:
            ver(floor)
    except (OSError, ValueError) as e:
        print(f"abi-gate: {e}", file=sys.stderr)
        return 2
    status = 0
    if not floor:
        print(f"abi-gate: no floor declared for {a.kind} {a.arch}")
        if a.require_floor:
            status = 1
    for path in a.files:
        try:
            machine, found = needed(path)
        except OSError as e:
            print(f"abi-gate: {path}: {e}", file=sys.stderr)
            return 2
        if machine != MACHINES[a.arch]:
            print(f"FAIL {path}: machine {machine!r}, expected {a.arch}")
            status = 1
            continue
        top = max(found, key=ver) if found else None
        print(f"{path}: {a.kind} {a.arch} needs GLIBC_{top or 'none'}"
              f" (floor {floor or 'undeclared'})")
        for v in sorted(found, key=ver, reverse=True)[:5]:
            print(f"    GLIBC_{v}: {', '.join(sorted(set(found[v]))[:6])}")
        if floor:
            over = sorted((v for v in found if ver(v) > ver(floor)), key=ver)
            if over:
                status = 1
                syms = sorted(set(s for v in over for s in found[v]))
                print(f"FAIL {path}: GLIBC_{over[-1]} above floor {floor}: "
                      + ", ".join(syms[:10]))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
