#!/usr/bin/env python3
"""Reconcile Leita's allocation totals on fresh, disposable POSIX fixtures."""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import platform
import plistlib
import random
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "leita.truth/1"
REPO = Path(__file__).resolve().parents[2]
PLAIN_FILESYSTEMS = {"apfs", "hfs", "hfs+", "ext2/ext3", "ext4", "tmpfs", "xfs", "ufs", "zfs", "overlayfs"}
COMMAND_TIMEOUT = 60
STDOUT_LIMIT = 2 * 1024 * 1024
STDERR_LIMIT = 128 * 1024


def sha256(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def command(argv: list[str], env: dict[str, str] | None = None) -> dict:
    """Bound process lifetime and output, including descendants holding pipes."""
    process = None
    selector = None
    output = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": STDOUT_LIMIT, "stderr": STDERR_LIMIT}
    truncated = {"stdout": False, "stderr": False}
    error = None
    deadline = time.monotonic() + COMMAND_TIMEOUT

    def cancelled(_signum, _frame):
        raise KeyboardInterrupt

    previous_term = signal.signal(signal.SIGTERM, cancelled)
    try:
        process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        selector = selectors.DefaultSelector()
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map() or process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                error = "timeout"
                break
            for key, _ in selector.select(min(remaining, 0.05)):
                chunk = os.read(key.fd, 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                name = key.data
                available = limits[name] - len(output[name])
                output[name].extend(chunk[:available])
                if len(chunk) > available:
                    truncated[name] = True
                    error = name + "-limit"
                    break
            if error:
                break
    except KeyboardInterrupt:
        error = "cancelled"
    except OSError as exc:
        error = "process-error: " + str(exc)[:512]
    finally:
        # Ignore a second cancellation until the owned group has been reaped.
        previous_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    error = error or "process-did-not-exit-after-kill"
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
            if selector is not None:
                selector.close()
        finally:
            signal.signal(signal.SIGINT, previous_int)
            signal.signal(signal.SIGTERM, previous_term)
    stderr = output["stderr"].decode("utf-8", errors="replace")
    if error:
        stderr += "\ntruth-runner: " + error + "\n"
    return {"argv": argv, "exit": process.returncode if process is not None and not error else None,
            "stdout": output["stdout"].decode("utf-8", errors="replace"), "stderr": stderr,
            "error": error, "stdout_truncated": truncated["stdout"], "stderr_truncated": truncated["stderr"]}


def create_workspace(path: Path) -> Path:
    # lexists catches dangling symlinks as well as real pre-existing trees.
    if os.path.lexists(path):
        raise ValueError(f"workspace already exists (nothing changed): {path}")
    path.mkdir(mode=0o700)  # no parents=True: a typo must not create a path chain
    return path.resolve()


def isolated_env(workspace: Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("LEITA_")}
    for key in ("BLOCK_SIZE", "BLOCKSIZE", "DU_BLOCK_SIZE", "POSIXLY_CORRECT"):
        env.pop(key, None)
    home = workspace / "private-home"
    home.mkdir()
    env.update(HOME=str(home), XDG_DATA_HOME=str(home / "data"), XDG_CONFIG_HOME=str(home / "config"),
               XDG_CACHE_HOME=str(home / "cache"), LC_ALL="C", NO_COLOR="1")
    return env


def filesystem(root: Path, env: dict[str, str]) -> dict:
    if sys.platform == "darwin":
        df = command(["df", "-P", str(root)], env)
        lines = df["stdout"].splitlines()
        if df["exit"] == 0 and len(lines) == 2:
            device = lines[1].split()[0]
            probe = command(["/usr/sbin/diskutil", "info", "-plist", device], env)
            try:
                info = plistlib.loads(probe["stdout"].encode())
                name = info.get("FilesystemType")
                if probe["exit"] == 0 and name:
                    return {"name": name.lower(), "evidence": [df, probe]}
            except (ValueError, plistlib.InvalidFileException):
                pass
            return {"name": None, "evidence": [df, probe]}
        return {"name": None, "evidence": [df]}
    if sys.platform.startswith("linux"):
        probe = command(["stat", "-f", "-c", "%T", str(root)], env)
        name = probe["stdout"].strip() if probe["exit"] == 0 else None
        return {"name": name, "evidence": [probe]}
    return {"name": None, "evidence": [], "reason": "filesystem-type probe unavailable on this platform"}


def write_file(path: Path, size: int, rng: random.Random) -> None:
    with path.open("xb") as f:
        # Incompressible seeded bytes avoid quietly creating a compression test.
        left = size
        while left:
            chunk = rng.randbytes(min(left, 65536))
            f.write(chunk)
            left -= len(chunk)
        f.flush()
        os.fsync(f.fileno())


def materialize(root: Path, kind: str, rng: random.Random) -> dict:
    root.mkdir()
    features: dict = {}
    if kind == "dense":
        for size in (0, 1, 511, 512, 4095, 4096, 4097, 65537, 1048576):
            write_file(root / f"size-{size}", size, rng)
    elif kind == "sparse":
        for name, offsets in (("hole-only", ()), ("data-and-holes", (0, 100000, 300001, 1048575))):
            with (root / name).open("xb") as f:
                f.truncate(1048576)
                for offset in offsets:
                    f.seek(offset)
                    f.write(rng.randbytes(1))
                f.flush()
                os.fsync(f.fileno())
        features["sparse_files"] = {
            p.name: {"apparent_bytes": p.stat().st_size, "allocated_bytes": p.stat().st_blocks * 512,
                     "holes_observed": p.stat().st_blocks * 512 < p.stat().st_size}
            for p in root.iterdir()
        }
    elif kind == "hard-links":
        (root / "a").mkdir()
        (root / "b").mkdir()
        write_file(root / "a" / "payer", 100000, rng)
        os.link(root / "a" / "payer", root / "b" / "alias")
        os.link(root / "a" / "payer", root / "third-name")
        write_file(root / "independent", 100000, rng)
    elif kind == "odd-names":
        for i, name in enumerate(("line\nbreak", "tab\tname", "-leading-dash", "héllo", "日本語", "😀 space", "bidirectional-\u202e-name")):
            write_file(root / name, (i + 1) * 1001, rng)
    elif kind == "symlinks":
        write_file(root / "target", 70000, rng)
        os.symlink("target", root / "file-link")
        os.symlink(".", root / "loop")
        os.symlink("missing", root / "dangling")
        outside = root.parent / "outside-symlink-target"
        outside.mkdir()
        write_file(outside / "must-not-follow", 65536, rng)
        os.symlink(str(outside), root / "outside")
    elif kind == "unread":
        write_file(root / "visible", 12345, rng)
        sealed = root / "sealed"
        sealed.mkdir()
        write_file(sealed / "hidden", 65536, rng)
        sealed.chmod(0)
        try:
            with os.scandir(sealed) as entries:
                list(entries)
        except PermissionError:
            features["permission_denial_observed"] = True
        else:
            features["permission_denial_observed"] = False
    else:
        raise ValueError(f"unknown fixture: {kind}")
    return features


def snapshot(root: Path) -> dict:
    entries: list[dict] = []
    unread: list[str] = []
    seen: set[tuple[int, int]] = set()
    allocation = apparent = dir_blocks = link_blocks = symlinks = directories = aliases = 0
    identities_known = True
    blocks_known = True
    other: list[str] = []

    def visit(path: Path) -> None:
        nonlocal allocation, apparent, dir_blocks, link_blocks, symlinks, directories, aliases, identities_known, blocks_known
        st = path.lstat()  # never follow a symlink, including a directory link
        relative = "." if path == root else str(path.relative_to(root))
        blocks = getattr(st, "st_blocks", None)
        blocks_known &= blocks is not None
        row = {"path": relative, "device": st.st_dev, "inode": st.st_ino, "mode": st.st_mode,
               "links": st.st_nlink, "size": st.st_size, "blocks_512": blocks,
               "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns}
        entries.append(row)
        held = blocks * 512 if blocks is not None else 0
        if stat.S_ISDIR(st.st_mode):
            directories += path != root
            dir_blocks += held
            try:
                with os.scandir(path) as children:
                    names = sorted(child.name for child in children)
            except PermissionError:
                unread.append(relative)
                return
            for name in names:
                visit(path / name)
        elif stat.S_ISLNK(st.st_mode):
            symlinks += 1
            link_blocks += held
            row["target"] = os.readlink(path)
        elif stat.S_ISREG(st.st_mode):
            identity = (st.st_dev, st.st_ino)
            identities_known &= st.st_ino > 0
            if identity in seen:
                aliases += 1
            else:
                seen.add(identity)
                apparent += st.st_size
                allocation += held
                row["sha256"] = sha256(path)
        else:
            other.append(relative)
    visit(root)
    return {"entries": entries, "unread_paths": unread, "unique_regular_files": len(seen),
            "symlinks": symlinks, "directories": directories, "hard_link_aliases": aliases,
            "apparent_regular_bytes": apparent, "stat_regular_allocated_bytes": allocation if blocks_known else None,
            "directory_allocated_bytes": dir_blocks if blocks_known else None,
            "symlink_allocated_bytes": link_blocks if blocks_known else None,
            "identities_known": identities_known, "blocks_known": blocks_known, "other_entries": other}


def compare(report: dict, oracle: dict, fs_name: str | None, stable: bool) -> list[dict]:
    """Apply only established, stated accounting relationships, never tolerances."""
    checks = []
    if not stable:
        return [{"name": "scan-comparability", "verdict": "unknown", "reason": "fixture changed during measurement"}]
    if not isinstance(report, dict) or report.get("schema") != "leita.report/1" or not isinstance(report.get("totals"), dict):
        return [{"name": "report-schema", "verdict": "fail", "reason": "missing or unsupported report schema/totals"}]
    totals = report["totals"]
    expected = {"files": oracle["unique_regular_files"] + oracle["symlinks"],
                "directories": oracle["directories"], "unread": len(oracle["unread_paths"])}
    if oracle["identities_known"] and not oracle["other_entries"]:
        for key, value in expected.items():
            actual = totals.get(key)
            checks.append({"name": key, "expected": value, "actual": actual,
                           "verdict": "pass" if type(actual) is int and actual == value else "fail"})
    else:
        checks.append({"name": "entry-counts", "verdict": "unknown", "reason": "unknown identities or unsupported entry kinds"})
    accounting = report.get("accounting")
    qualified = isinstance(accounting, dict) and accounting.get("logical") is False and accounting.get("scan_order") is False
    if fs_name not in PLAIN_FILESYSTEMS or not oracle["blocks_known"] or not oracle["identities_known"] or not qualified:
        checks.append({"name": "allocated-bytes", "verdict": "unknown",
                       "reason": "filesystem/allocation identity or non-estimated report accounting not established"})
    else:
        actual = totals.get("bytes")
        expected_bytes = oracle["stat_regular_allocated_bytes"]
        checks.append({"name": "allocated-bytes", "expected": expected_bytes, "actual": actual,
                       "verdict": "pass" if type(actual) is int and actual == expected_bytes else "fail"})
    return checks


def compare_du(result: dict, oracle: dict, stable: bool, fs_name: str | None) -> dict:
    if result["exit"] != 0 or not stable or oracle["unread_paths"] or not oracle["blocks_known"] or not oracle["identities_known"] or fs_name not in PLAIN_FILESYSTEMS:
        return {"name": "du-allocation", "verdict": "unknown", "reason": "du unavailable/partial, unstable fixture, or unestablished filesystem accounting"}
    token = re.match(r"^\s*(\d+)\s", result["stdout"])
    if not token:
        return {"name": "du-allocation", "verdict": "fail", "reason": "successful du returned no KiB total"}
    # One operand: GNU/BSD du hard-link deduplication cannot cross case roots.
    # -k fixes units on both; each rounds the total up to a whole KiB.
    held = oracle["stat_regular_allocated_bytes"] + oracle["directory_allocated_bytes"] + oracle["symlink_allocated_bytes"]
    expected = (held + 1023) // 1024
    actual = int(token.group(1))
    return {"name": "du-allocation", "expected_kib": expected, "actual_kib": actual,
            "verdict": "pass" if actual == expected else "fail"}


def verdict(checks: list[dict]) -> str:
    if any(c["verdict"] == "fail" for c in checks):
        return "fail"
    if any(c["verdict"] == "unknown" for c in checks):
        return "unknown"
    return "pass"


def run_case(root: Path, kind: str, binary: Path, env: dict[str, str], fs_name: str | None, rng: random.Random) -> dict:
    try:
        features = materialize(root, kind, rng)
        if kind == "unread" and not features["permission_denial_observed"]:
            return {"case": kind, "verdict": "skip", "reason": "this process can list chmod(000) directory; permission refusal not proved", "features": features}
        before = snapshot(root)
        process = command([str(binary), str(root), "--whole", "--no-history", "--color", "never", "--report", "-", "--format", "json"], env)
        du = command(["du", "-sk", str(root)], env)
        after = snapshot(root)
        stable = before == after
        try:
            report = json.loads(process["stdout"])
        except (ValueError, TypeError):
            report = {}
        if not isinstance(report, dict):
            report = {}
        checks = compare(report, before, fs_name, stable)
        checks.append({"name": "leita-exit", "expected": 0, "actual": process["exit"], "verdict": "pass" if process["exit"] == 0 else "fail"})
        checks.append(compare_du(du, before, stable, fs_name))
        totals = report.get("totals")
        valid_totals = isinstance(totals, dict)
        partial = bool(before["unread_paths"]) or (bool(totals.get("unread")) if valid_totals else False)
        completed = process["exit"] == 0 and report.get("schema") == "leita.report/1" and valid_totals
        coverage = "mutated" if not stable else "not-completed" if not completed else "partial" if partial else "complete"
        return {"case": kind, "verdict": verdict(checks), "coverage": coverage,
                "features": features, "oracle_before": before, "oracle_after": after, "fixture_stable": stable,
                "checks": checks, "leita": process, "report": report, "du": du,
                "unique_physical_bytes": None, "deletion_savings_bytes": None}
    except OSError as e:
        unavailable = kind in {"hard-links", "symlinks", "unread"} and e.errno in {
            errno.ENOTSUP, errno.EPERM, errno.EACCES, errno.EXDEV, errno.ENOSYS
        }
        return {"case": kind, "verdict": "skip" if unavailable else "fail", "coverage": "not-run", "reason": str(e)}
    except ValueError as e:
        return {"case": kind, "verdict": "fail", "coverage": "not-run", "reason": str(e)}
    finally:
        sealed = root / "sealed"
        if kind == "unread" and sealed.is_dir() and not sealed.is_symlink():
            sealed.chmod(0o700)  # restore access only to a directory this run owns


def markdown(results: dict) -> str:
    lines = ["| Fixture | Coverage | Apparent regular bytes | stat allocation | Leita charged bytes | Verdict |",
             "| --- | --- | ---: | ---: | ---: | --- |"]
    for case in results["cases"]:
        oracle = case.get("oracle_before", {})
        totals = case.get("report", {}).get("totals")
        charged = totals.get("bytes") if isinstance(totals, dict) else None
        values = [case["case"], case.get("coverage", "not-run"), oracle.get("apparent_regular_bytes"),
                  oracle.get("stat_regular_allocated_bytes"), charged, case["verdict"]]
        lines.append("| " + " | ".join("unknown" if x is None else str(x) for x in values) + " |")
    lines.extend(["", "stat allocation counts unique regular-file identities. Leita excludes directory and symlink allocations; du includes them.",
                  "Unknown and skipped rows are not passing proof. No unique physical-use, deletion-savings, speed or published-release claim is made.", ""])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--leita", type=Path, required=True, help="built CLI binary to measure")
    parser.add_argument("--workspace", type=Path, required=True, help="fresh non-existing directory; parent must exist; retained after run")
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--source-revision", help="operator-declared binary source revision, not inferred or cryptographically proved")
    args = parser.parse_args(argv)
    binary = args.leita.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--leita must name an executable regular file")
    if os.name != "posix" or not hasattr(os.stat(binary), "st_blocks"):
        parser.error("this runner requires POSIX lstat allocated-block metadata; Windows native proof is separate")
    try:
        workspace = create_workspace(args.workspace.absolute())
    except (ValueError, OSError) as e:
        parser.error(str(e))
    env = isolated_env(workspace)
    fs = filesystem(workspace, env)
    binary_hash_before = sha256(binary)
    rng = random.Random(args.seed)
    cases = [run_case(workspace / name, name, binary, env, fs["name"], rng)
             for name in ("dense", "sparse", "hard-links", "odd-names", "symlinks", "unread")]
    cases.extend({"case": name, "verdict": "skip", "coverage": "not-run", "reason": reason}
                 for name, reason in (("mount-boundaries", "no host mounts created; native disposable-volume fixture is separate"),
                                      ("reflinks/compression", "shared/compressed extents not established; st_blocks is not a unique-physical oracle")))
    binary_hash_after = sha256(binary)
    if binary_hash_after != binary_hash_before:
        cases.append({"case": "binary-provenance", "verdict": "fail", "coverage": "mutated", "reason": "executable changed during run"})
    du_path = shutil.which("du")
    result = {"schema": SCHEMA, "generated": datetime.now(timezone.utc).isoformat(), "seed": args.seed,
              "workspace": str(workspace), "platform": platform.platform(), "python": sys.version, "effective_uid": os.geteuid(),
              "runner_sha256": sha256(Path(__file__)), "filesystem": fs,
              "binary": {"path": str(binary), "sha256": binary_hash_before, "sha256_after": binary_hash_after, "version": command([str(binary), "--version"], env),
                         "source_revision": args.source_revision, "source_qualification": "operator declaration only; identify the exact executable with sha256"},
              "du_identity": {"path": du_path, "sha256": sha256(Path(du_path)) if du_path else None,
                              "version_probe": command(["du", "--version"], env), "qualification": "BSD du may not expose a version; OS and executable hash retained"},
              "accounting": {"stat_unit_bytes": 512, "hard_links": "unique (st_dev, st_ino) regular-file identities within each case",
                             "leita_files": "unique regular files plus non-followed symlink entries",
                             "du": "one operand per process, -sk, ceil((regular + directory + symlink allocated bytes)/1024)",
                             "unique_physical_bytes": None, "deletion_savings_bytes": None},
              "cases": cases}
    result["summary"] = {v: sum(c["verdict"] == v for c in cases) for v in ("pass", "fail", "unknown", "skip")}
    (workspace / "results.json").write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    (workspace / "table.md").write_text(markdown(result))
    # stdout is one JSON document. Human-readable table and raw stderr are files.
    print(json.dumps(result, ensure_ascii=True))
    return 1 if result["summary"]["fail"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
