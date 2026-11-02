#!/usr/bin/env python3
"""Native FreeBSD CLI build, tests and an installable candidate archive."""
import argparse
import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def progress(state, argv, **details):
    event = dict(state=state, argv=argv, at=time.time(), **details)
    destination = ROOT / "build" / "freebsd" / "progress.jsonl"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("a") as stream:
        stream.write(json.dumps(event) + "\n")
    print(f"[freebsd {state}] {shlex.join(argv)} {json.dumps(details)}", file=sys.stderr, flush=True)


def kill_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def run(argv, timeout=30, **kwargs):
    """Bound the whole compiler/test process group and retain timeout evidence."""
    argv = [str(arg) for arg in argv]
    started = time.monotonic()
    progress("start", argv, timeout=timeout)
    process = subprocess.Popen(argv, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(process, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            kill_group(process, signal.SIGKILL)
            stdout, stderr = process.communicate()
        finally:
            # A parent may exit on TERM while a child ignores it. Kill the
            # remaining group even when communicate has already returned.
            kill_group(process, signal.SIGKILL)
        progress("timeout", argv, timeout=timeout, elapsed=time.monotonic() - started)
        raise subprocess.TimeoutExpired(argv, timeout, output=stdout, stderr=stderr)
    except BaseException:
        kill_group(process, signal.SIGKILL)
        process.communicate()
        raise
    progress("end", argv, returncode=process.returncode, elapsed=time.monotonic() - started)
    completed = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
    completed.check_returncode()
    return completed


def value(name):
    # Only the application justfile is portable to FreeBSD; jm has GUI-only
    # prerequisites whose disabled recipes make even --evaluate fail there.
    return run(["just", "--justfile", ROOT / "justfile", "--evaluate", name],
               text=True, stdout=subprocess.PIPE).stdout.strip()



def sqlite_defines(justfile):
    """Read jm's literal string assignment without evaluating its recipe graph."""
    lines = justfile.read_text().splitlines()
    for index, line in enumerate(lines):
        match = re.fullmatch(r"sqlite_defines\s*:=\s*(.*)", line)
        if match:
            expression = match[1]
            while expression.rstrip().endswith("\\"):
                index += 1
                if index == len(lines):
                    raise ValueError("unterminated sqlite_defines assignment")
                expression = expression.rstrip()[:-1] + lines[index].strip()
            quoted = r'"(?:[^"\\]|\\.)*"'
            if not re.fullmatch(r"\s*" + quoted + r"(?:\s*\+\s*" + quoted + r")*\s*", expression):
                raise ValueError("sqlite_defines must remain a concatenation of literal strings")
            result = "".join(json.loads(part) for part in re.findall(quoted, expression))
            if not result or any(not re.fullmatch(r"-D[A-Za-z_][A-Za-z0-9_]*(?:=[A-Za-z0-9_()+.-]+)?", arg)
                                 for arg in shlex.split(result)):
                raise ValueError("sqlite_defines contains an unsupported compile option")
            return result
    raise ValueError("sqlite_defines assignment is missing")


def native_host():
    if platform.system() != "FreeBSD" or platform.machine().lower() not in {"amd64", "x86_64"}:
        raise SystemExit("this recipe builds and runs on FreeBSD amd64; use just check-freebsd for source checks")


def dependencies():
    """Always rebuild: an archive copied from another OS must never be reused."""
    jm = Path(value("jm"))
    if not (jm / "justfile").exists():
        if jm != ROOT / "jm":
            raise SystemExit(f"JM collection is missing: {jm}")
        run(["git", "submodule", "update", "--init", "jm"], cwd=ROOT, timeout=300)
    cc = shlex.split(os.environ.get("CC", "cc"))
    ar = shlex.split(os.environ.get("AR", "ar"))
    defines_text = sqlite_defines(jm / "justfile")
    options = shlex.split(defines_text)
    for package, defines in [("sqlite3", options), ("zstd", [])]:
        output = jm / package / "lib"
        output.mkdir(parents=True, exist_ok=True)
        obj = output / f"{package}.o"
        archive = output / f"{package}.a"
        run(cc + ["-O2", "-fPIC", "-c", jm / package / "vendor" / f"{package}.c",
                  "-o", obj] + defines, timeout=300)
        archive.unlink(missing_ok=True)
        run(ar + ["rcs", archive, obj])
        if package == "sqlite3":
            (output / "defines").write_text(defines_text + "\n")
    output = ROOT / "scan" / "lib"
    output.mkdir(parents=True, exist_ok=True)
    obj = ROOT / "build" / "freebsd" / "native.o"
    obj.parent.mkdir(parents=True, exist_ok=True)
    run(cc + ["-std=c11", "-O2", "-fPIC", "-Wall", "-Wextra", "-Werror", "-c",
              ROOT / "scan" / "native_freebsd.c", "-o", obj], timeout=300)
    archive = output / "freebsd.a"
    archive.unlink(missing_ok=True)
    run(ar + ["rcs", archive, obj])


def build(mode):
    native_host()
    if mode == "release":
        # Keep the same public-key validation as every other platform.
        keys = [run(["just", recipe], cwd=ROOT, text=True, stdout=subprocess.PIPE).stdout.strip()
                for recipe in ["release-key", "update-key"]]
        options = ["-o:speed", f"-define:LEITA_LICENCE_KEY={keys[0]}",
                   f"-define:LEITA_UPDATE_KEY={keys[1]}"]
    elif mode in {"minimal", "speed"}:
        options = shlex.split(value(f"{mode}_opt"))
    else:
        raise ValueError(f"unsupported native build mode: {mode}")
    dependencies()
    binary = ROOT / "build" / mode / "leita"
    binary.parent.mkdir(parents=True, exist_ok=True)
    # Do not enter root's sqlite prerequisite or any jm recipe. Their native
    # archives were rebuilt above; flags and version still come from the root.
    odin = shlex.split(os.environ.get("ODIN", "odin"))
    run(odin + ["build", "cmd/cli", "-target:freebsd_amd64"] + options +
        shlex.split(value("flags")) + [f"-out:{binary}"], cwd=ROOT, timeout=600)
    return binary


def test_suite():
    output = ROOT / "build" / "freebsd"
    output.mkdir(parents=True, exist_ok=True)
    flags = shlex.split(value("flags"))
    odin = shlex.split(os.environ.get("ODIN", "odin"))
    binary = output / "tests"
    # Separate compiler and suite budgets so timeout evidence identifies which
    # stalled; every imported package and test still runs.
    run(odin + ["build", "cmd/cli", "-build-mode:test", "-all-packages", "-debug",
                "-define:ODIN_TEST_LOG_STATE_CHANGES=true", "-define:ODIN_TEST_FANCY=false"] + flags +
        shlex.split(os.environ.get("SAN", "")) + [f"-out:{binary}"], cwd=ROOT, timeout=600)
    # Odin's POSIX test launcher passes only the basename as argv[0] while
    # posix_spawn executes the exact output path (pinned src/main.cpp).
    run([binary.name], executable=str(binary), cwd=ROOT, timeout=300)


def tests():
    binary = build("speed")
    test_suite()
    # Run against a private home so no installed licence/history is read or changed.
    with tempfile.TemporaryDirectory(prefix="leita-freebsd-") as directory:
        work = Path(directory)
        tree = work / "tree"
        tree.mkdir()
        (tree / "file.txt").write_bytes(b"leita freebsd smoke\n" * 1024)
        os.link(tree / "file.txt", tree / "hardlink.txt")
        env = dict(os.environ, HOME=str(work / "home"), XDG_DATA_HOME=str(work / "data"),
                   XDG_CONFIG_HOME=str(work / "config"), LEITA_LICENCE="")
        report = work / "report.json"
        run([binary, "--whole", "--no-history", "--report", report, tree], env=env, timeout=60)
        parsed = json.loads(report.read_text())
        expected = (tree / "file.txt").stat().st_blocks * 512
        if parsed.get("totals", {}).get("bytes") != expected:
            raise SystemExit(f"native allocation/hardlink check failed: {parsed.get('totals')}, expected {expected} bytes")
        if parsed["totals"].get("unread") != 0:
            raise SystemExit("native smoke fixture was not fully read")
        run([binary, "--version"], env=env)
    print("FreeBSD native CLI tests and scan/report smoke passed; UFS/ZFS fixture acceptance is separate")


def archive_name(version):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", version):
        raise ValueError("LEITA_VERSION must contain only letters, numbers, dot, underscore, + or -")
    return f"leita-{version}-freebsd-amd64"


def write_archive(binary, output, version, metadata):
    """Copy the executable and notices, recording dependencies without bundling them."""
    name = archive_name(version)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="leita-package-") as directory:
        payload = Path(directory) / name
        (payload / "bin").mkdir(parents=True)
        shutil.copy2(binary, payload / "bin" / "leita")
        (payload / "bin" / "leita").chmod(0o755)
        (payload / "bin" / "le").symlink_to("leita")
        docs = payload / "share" / "doc" / "leita"
        docs.mkdir(parents=True)
        for notice in ["LICENSE.md", "THIRD_PARTY.md"]:
            shutil.copy2(ROOT / notice, docs / notice)
        (payload / "BUILD.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (payload / "INSTALL.md").write_text(
            "FreeBSD amd64 command line candidate\n\n"
            "Install libcurl with `pkg install curl` before running. BUILD.json records the\n"
            "build host and dynamic libraries; the archive does not bundle those libraries.\n"
            "From this directory, install with:\n\n"
            "    install -m 755 bin/leita /usr/local/bin/leita\n\n"
            "Or run bin/leita directly as your normal user. Keep the notices in share/doc/leita.\n"
            "This archive is a CLI candidate; it does not establish native UFS/ZFS acceptance\n"
            "or publish an updater artifact. Snapshot/pool use and deletion reclaim are unknown.\n"
        )
        archive = output / f"{name}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(payload, arcname=name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(archive.suffix + ".sha256").write_text(f"{digest}  {archive.name}\n")
    return archive


def package(mode):
    binary = build(mode)
    linked = run(["ldd", binary], text=True, stdout=subprocess.PIPE).stdout
    if "not found" in linked.lower():
        raise SystemExit("package has unresolved dynamic libraries")
    metadata = {
        "version": value("version"), "mode": mode, "system": platform.platform(),
        "freebsd_version": run(["freebsd-version", "-ku"], text=True, stdout=subprocess.PIPE).stdout.strip(),
        "source": run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stdout=subprocess.PIPE).stdout.strip(),
        "odin": run(shlex.split(os.environ.get("ODIN", "odin")) + ["version"], text=True,
                    stdout=subprocess.PIPE).stdout.strip(),
        "ldd": linked, "native_ufs_zfs_acceptance": False,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }
    print(write_archive(binary, ROOT / "build" / "package", metadata["version"], metadata))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test", "package"])
    parser.add_argument("mode", nargs="?", choices=["minimal", "speed", "release"], default="speed")
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.action == "build":
        build(args.mode)
    elif args.action == "test":
        tests()
    else:
        package(args.mode)


if __name__ == "__main__":
    main()
