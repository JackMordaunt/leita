#!/usr/bin/env python3
"""Fail when a Mach-O file asks for a newer macOS than the floor.

    check_minos.py [--floor 11.0] [--system-only] FILE...

FILE may be an executable, a dylib, an object or a static archive. It is run
through `otool -arch all -l` (LLVM's llvm-otool prints the same lines), and
every LC_BUILD_VERSION `minos` and LC_VERSION_MIN_MACOSX `version` it names
is compared with the floor. A fat file's slices are each checked when otool
prints them. A file with no such load command, or a platform other than
macOS, fails too: silence is not a minimum.

With --system-only, non-system dylib dependencies are rejected too: a
standalone Leita binary must not depend on a library installed by Homebrew.

This reads what the compiler and linker wrote. It does not show that a system
symbol or framework the binary calls exists on the floor release; only a run
on that release does.
"""
import argparse
import re
import shutil
import subprocess
import sys


def version(text):
    """'11.0' or '11.0.1' as a tuple of ints."""
    parts = tuple(int(p) for p in text.split("."))
    return parts + (0,) * max(0, 3 - len(parts))


def minimums(otool_output):
    """(platform, minimum version) per version load command in otool -l output.

    A platform is the name otool prints after `platform`, or macos for the
    older LC_VERSION_MIN_MACOSX. The result is empty when no command names one.
    """
    found = []
    cmd = None
    platform = None
    for line in otool_output.splitlines():
        s = line.strip()
        m = re.match(r"cmd (\S+)", s)
        if m:
            cmd = m.group(1)
            platform = None
            continue
        if cmd == "LC_BUILD_VERSION":
            m = re.match(r"platform (\S+)", s)
            if m:
                # A number (1 is PLATFORM_MACOS in <mach-o/loader.h>) or a name,
                # as the tool in use prints it.
                platform = {"1": "macos"}.get(m.group(1), m.group(1)).lower()
            m = re.match(r"minos (\S+)", s)
            if m:
                found.append((platform or "unknown", m.group(1)))
        elif cmd == "LC_VERSION_MIN_MACOSX":
            m = re.match(r"version (\S+)", s)
            if m:
                found.append(("macos", m.group(1)))
    return found


def verdict(name, otool_output, floor):
    """The failures in one file's otool output, as sentences."""
    found = minimums(otool_output)
    if not found:
        return [f"{name}: no LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX"]
    problems = []
    for platform, minos in found:
        if platform != "macos":
            problems.append(f"{name}: platform {platform}, not macos")
        elif version(minos) > version(floor):
            problems.append(f"{name}: needs macOS {minos}, the floor is {floor}")
    return list(dict.fromkeys(problems))


def external_libraries(otool_output):
    """Dylib install names outside the macOS system library directories."""
    found = []
    cmd = None
    for line in otool_output.splitlines():
        s = line.strip()
        m = re.match(r"cmd (\S+)", s)
        if m:
            cmd = m.group(1)
            continue
        if cmd in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                   "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}:
            m = re.match(r"name (.+) \(offset \d+\)$", s)
            if m and not m.group(1).startswith(("/usr/lib/", "/System/Library/")):
                found.append(m.group(1))
    return list(dict.fromkeys(found))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--floor", default="11.0")
    ap.add_argument("--system-only", action="store_true",
                    help="reject non-system dylib dependencies in standalone binaries")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args(argv)
    otool = shutil.which("otool") or shutil.which("llvm-otool")
    if otool is None:
        print("check_minos: neither otool nor llvm-otool is installed", file=sys.stderr)
        return 2
    bad = []
    for path in args.files:
        out = subprocess.run([otool, "-arch", "all", "-l", path], capture_output=True, text=True)
        if out.returncode != 0:
            bad.append(f"{path}: otool failed: {out.stderr.strip()}")
            continue
        problems = verdict(path, out.stdout, args.floor)
        if args.system_only:
            problems.extend(f"{path}: non-system dependency {lib}"
                            for lib in external_libraries(out.stdout))
        bad.extend(problems)
        if not problems:
            shown = ", ".join(sorted({m for _, m in minimums(out.stdout)}))
            print(f"{path}: minos {shown} (floor {args.floor})")
    for line in bad:
        print(line, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
