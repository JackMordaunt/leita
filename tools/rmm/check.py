#!/usr/bin/env python3
"""Run one scan and emit a bounded operational result, without parsing prose."""

from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

REPORT_LIMIT = 1024 * 1024
STDERR_LIMIT = 64 * 1024
FORWARDED_STDERR = 4096
VERDICTS = {"ok": 0, "warn": 2, "fail": 3}


class InvalidReport(ValueError):
    pass


class Arguments(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse's default 2 would be indistinguishable from a scan warning.
        self.print_usage(sys.stderr)
        self.exit(1, "leita-rmm: " + message + "\n")


def integer(value: object, name: str) -> int:
    if type(value) is not int or not 0 <= value <= 2**64 - 1:
        raise InvalidReport(f"{name} must be a nonnegative byte/count integer")
    return value


def object_value(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise InvalidReport(f"{name} must be an object")
    return value


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidReport("report contains a duplicate JSON member")
        result[key] = value
    return result


def canonical(path: str) -> str:
    return os.path.normcase(os.path.realpath(path))


def validate(raw: bytes, args: argparse.Namespace, code: int) -> dict:
    try:
        report = object_value(json.loads(raw, object_pairs_hook=unique_object), "report")
        if report.get("schema") != "leita.report/1":
            raise InvalidReport("missing or unsupported report schema")
        generator = object_value(report["generator"], "generator")
        if generator.get("name") != "leita" or not isinstance(generator.get("version"), str):
            raise InvalidReport("missing Leita generator identity")
        target = object_value(report["target"], "target")
        path = target.get("path")
        if not isinstance(path, str) or not os.path.isabs(path) or canonical(path) != canonical(args.target):
            raise InvalidReport("report target does not match the requested target")
        if "path_base64" in target:
            raise InvalidReport("a non-UTF-8 report target needs a separate byte-path adapter")
        if target.get("engine") not in {"walk", "mft"}:
            raise InvalidReport("report has no real filesystem scan engine")
        # A normal report is produced after the CLI's scan has finished. It has
        # no general completeness bit: unread is the available coverage signal.
        scan = object_value(report["scan"], "scan")
        datetime.datetime.strptime(scan["started"], "%Y-%m-%dT%H:%M:%SZ")
        datetime.datetime.strptime(report["generated"], "%Y-%m-%dT%H:%M:%SZ")
        if not isinstance(scan["duration"], str) or not re.fullmatch(r"PT\d+(?:\.\d+)?S", scan["duration"]):
            raise InvalidReport("missing scan duration")
        totals = object_value(report["totals"], "totals")
        for key in ("bytes", "files", "directories", "unread"):
            integer(totals[key], "totals." + key)
        space = object_value(report["space"], "space")
        total, free = integer(space["total"], "space.total"), integer(space["free"], "space.free")
        if total == 0 or free > total:
            raise InvalidReport("volume capacity is unknown or inconsistent")
        thresholds = object_value(report["thresholds"], "thresholds")
        for key, wanted in (("warn_used", args.warn_used), ("fail_used", args.fail_used), ("min_free", args.min_free_bytes)):
            found = thresholds[key]
            if found is not None:
                integer(found, "thresholds." + key)
            if found != (wanted or None):
                raise InvalidReport("report thresholds do not match the requested limits")
        used = thresholds["used_percent"]
        # Match report.threshold_of's floating-point operation order.
        actual_used = 100.0 * float(total - free) / float(total)
        if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100:
            raise InvalidReport("missing or invalid used_percent")
        if abs(used - actual_used) > 0.00001:
            raise InvalidReport("used_percent disagrees with volume capacity")
        verdict = "ok"
        if args.warn_used and actual_used >= args.warn_used:
            verdict = "warn"
        if (args.fail_used and actual_used >= args.fail_used) or free < args.min_free_bytes:
            verdict = "fail"
        if thresholds["verdict"] != verdict or VERDICTS[verdict] != code:
            raise InvalidReport("scan exit code and threshold verdict disagree")
        reasons = thresholds["reasons"]
        if not isinstance(reasons, list) or len(reasons) > 3 or any(not isinstance(x, str) for x in reasons):
            raise InvalidReport("invalid threshold reasons")
        return {"charged_bytes": totals["bytes"], "unread_directories": totals["unread"],
                "volume_total_bytes": total, "volume_free_bytes": free,
                "used_percent": used, "outcome": verdict}
    except (KeyError, TypeError, ValueError, UnicodeError, OverflowError, RecursionError) as exc:
        if isinstance(exc, InvalidReport):
            raise
        raise InvalidReport("missing or malformed operational report fields") from exc


class Capture:
    """Drain one pipe without accumulating unbounded process output."""

    def __init__(self, stream, limit: int, overflow: threading.Event):
        self.stream, self.limit, self.overflow = stream, limit, overflow
        self.data = bytearray()
        self.thread = threading.Thread(target=self.read, daemon=True)

    def read(self) -> None:
        try:
            with self.stream:
                while chunk := self.stream.read(8192):
                    self.data.extend(chunk[: self.limit + 1 - len(self.data)])
                    if len(self.data) > self.limit:
                        self.overflow.set()
                        return
        except OSError:
            self.overflow.set()


def stop(process: subprocess.Popen) -> None:
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


@contextlib.contextmanager
def cleanup_signals():
    # A second scheduler cancellation must not interrupt reaping the owned
    # scanner or replace an already established timeout/overflow result.
    saved = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            saved[sig] = signal.signal(sig, signal.SIG_IGN)
    try:
        yield
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)


def scan(args: argparse.Namespace) -> tuple[int | None, bytes, bytes, str]:
    command = [args.leita, args.target, "--whole", "--no-history", "--report", "-",
               "--format", "json", "--top", "1", "--color", "never"]
    for flag, value in (("--warn-used", args.warn_used), ("--fail-used", args.fail_used),
                        ("--min-free", args.min_free_bytes)):
        if value:
            command += [flag, str(value)]
    environment = dict(os.environ)
    environment.pop("LEITA_SYNTHETIC", None)
    process = None
    captures = []
    overflow = threading.Event()
    reason = ""
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment, start_new_session=os.name == "posix")
        for stream, limit in ((process.stdout, REPORT_LIMIT), (process.stderr, STDERR_LIMIT)):
            capture = Capture(stream, limit, overflow)
            # Retain ownership before starting the reader: cancellation can
            # happen inside thread.start as well as during Capture construction.
            captures.append(capture)
            capture.thread.start()
        deadline = time.monotonic() + args.timeout_seconds
        while process.poll() is None:
            if overflow.is_set():
                reason = "scan output exceeded the report or diagnostic limit"
                break
            if time.monotonic() >= deadline:
                reason = "scan timed out"
                break
            time.sleep(0.02)
        if not reason:
            for capture in captures:
                capture.thread.join(timeout=1)
            if any(c.thread.is_alive() for c in captures):
                reason = "scan output remained open after the scanner exited"
    except KeyboardInterrupt:
        reason = reason or "scan cancelled"
    except (OSError, ValueError, RuntimeError) as exc:
        action = "cannot start Leita" if process is None else "cannot capture Leita output"
        reason = reason or f"{action}: {getattr(exc, 'strerror', None) or type(exc).__name__}"
    finally:
        if process is not None:
            with cleanup_signals():
                if reason:
                    stop(process)
                for capture in captures:
                    if capture.thread.ident is not None:
                        capture.thread.join(timeout=1)
                # Readers close the pipes they own. A cancellation before a
                # reader starts leaves its pipe for this cleanup to close.
                for stream in (process.stdout, process.stderr):
                    if not any(c.stream is stream and c.thread.is_alive() for c in captures):
                        stream.close()
    if overflow.is_set():
        reason = reason or "scan output exceeded the report or diagnostic limit"
    output = bytes(captures[0].data) if captures else b""
    errors = bytes(captures[1].data) if len(captures) > 1 else b""
    return process.returncode if process is not None else None, output, errors, reason


def main(argv: list[str] | None = None) -> int:
    parser = Arguments(description=__doc__)
    parser.add_argument("--leita", required=True, help="absolute path to the installed CLI executable")
    parser.add_argument("--target", required=True, help="absolute filesystem directory/drive path")
    parser.add_argument("--warn-used", type=int, default=80)
    parser.add_argument("--fail-used", type=int, default=95)
    parser.add_argument("--min-free-bytes", type=int, default=0)
    parser.add_argument("--timeout-seconds", type=float, default=300)
    args = parser.parse_args(argv)
    result = {"schema": "leita.rmm/1", "outcome": "error", "coverage": "unknown",
              "leita_exit": None, "requested_target": args.target[:512],
              "target_truncated": len(args.target) > 512, "error": None}
    reason = ""
    if not os.path.isabs(args.leita) or not os.path.isabs(args.target):
        reason = "--leita and --target must be absolute paths"
    elif not 0 <= args.warn_used <= 100 or not 0 <= args.fail_used <= 100:
        reason = "percent limits must be between 0 (disabled) and 100"
    elif args.warn_used and args.fail_used and args.warn_used > args.fail_used:
        reason = "warn-used must not exceed fail-used"
    elif not 0 <= args.min_free_bytes <= 2**53:
        reason = "min-free-bytes must be between 0 and 2^53"
    elif not (args.warn_used or args.fail_used or args.min_free_bytes):
        reason = "at least one threshold must be enabled"
    elif not math.isfinite(args.timeout_seconds) or not 0 < args.timeout_seconds <= 86400:
        reason = "timeout-seconds must be greater than 0 and at most 86400"
    code = 1
    if not reason:
        leita_code, raw, errors, reason = scan(args)
        result["leita_exit"] = leita_code
        if errors:
            sys.stderr.write(errors[:FORWARDED_STDERR].decode("utf-8", errors="replace"))
            if not errors[:FORWARDED_STDERR].endswith(b"\n"):
                sys.stderr.write("\n")
            if len(errors) > FORWARDED_STDERR:
                sys.stderr.write("leita-rmm: further scanner diagnostics omitted\n")
        if not reason and leita_code not in VERDICTS.values():
            reason = f"scanner exited with error code {leita_code}"
        if not reason:
            try:
                facts = validate(raw, args, leita_code)
                result.update(facts)
                if facts["unread_directories"]:
                    result["coverage"] = "partial"
                    reason = "scan reports unread directories; file totals are incomplete"
                else:
                    result["coverage"] = "no_unread_directories"
                    code = leita_code
            except InvalidReport as exc:
                reason = str(exc)
    if reason:
        result["outcome"] = "error"
        result["error"] = reason[:256]
        sys.stderr.write("leita-rmm: " + reason[:256] + "\n")
    print(json.dumps(result, ensure_ascii=True, allow_nan=False, separators=(",", ":")))
    return code


if __name__ == "__main__":
    # Bash execs this process, so a scheduler's SIGTERM must stop its scanner.
    def cancelled(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, cancelled)
    sys.exit(main())
