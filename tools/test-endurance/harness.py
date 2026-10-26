#!/usr/bin/env python3
"""Real monitor/recorder endurance in a disposable, CI-only systemd container."""
import argparse
from contextlib import closing
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

# Same pinned Ubuntu image and container/getty isolation as test-install/linux.
IMAGE = "ubuntu@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac"
ROOT = Path(__file__).resolve().parent.parent.parent
BOUNDS = dict(rss_bytes=256 * 1024**2, fds=128, threads=32,
              rss_growth_bytes=64 * 1024**2, fd_growth=16, thread_growth=4,
              log_base_bytes=8 * 1024**2, log_bytes_per_second=4096,
              cadence_slack_seconds=5, monitor_seconds=10)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(argv, **kwargs):
    try:
        return subprocess.run([str(v) for v in argv], check=True, text=True,
                              stdin=subprocess.DEVNULL, **kwargs)
    except subprocess.CalledProcessError as error:
        # Preserve native prerequisite/service failures verbatim in the CI log.
        if error.stdout:
            print(error.stdout, file=sys.stderr, end="")
        if error.stderr:
            print(error.stderr, file=sys.stderr, end="")
        raise


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def resources(pid):
    """Linux process resources; a vanished child is not a zero-valued sample."""
    proc = Path(f"/proc/{pid}")
    try:
        fields = dict(line.split(":", 1) for line in (proc / "status").read_text().splitlines())
        return dict(rss_bytes=int(fields.get("VmRSS", "0 kB").split()[0]) * 1024,
                    fds=len(list((proc / "fd").iterdir())), threads=int(fields["Threads"]))
    except (FileNotFoundError, ProcessLookupError):
        return None


def check_resources(rows, bounds=BOUNDS):
    require(len(rows) >= 2, "resource sampling produced fewer than 2 observations")
    for key in ("rss_bytes", "fds", "threads"):
        require(max(r[key] for r in rows) <= bounds[key], f"{key} exceeded {bounds[key]}")

    # Compare medians of first/last quarters after warmup, rather than one noisy point.
    warm = rows[min(5, len(rows) // 4):]
    width = max(1, len(warm) // 4)
    for key, limit in (("rss_bytes", "rss_growth_bytes"), ("fds", "fd_growth"),
                       ("threads", "thread_growth")):
        first = sorted(r[key] for r in warm[:width])[width // 2]
        last = sorted(r[key] for r in warm[-width:])[width // 2]
        require(last - first <= bounds[limit], f"{key} growth {last-first} exceeded {bounds[limit]}")


def check_cadence(rows, duration, interval, bounds=BOUNDS):
    require(len(rows) >= max(2, int(duration / interval) - 1), "scheduled monitor runs were missed")
    require(all(r["code"] == 0 and r["samples"] > 0 for r in rows), "monitor failed or escaped sampling")
    require(all(r["seconds"] <= bounds["monitor_seconds"] for r in rows), "monitor run exceeded timeout")

    for a, b in zip(rows, rows[1:]):
        gap = b["started"] - a["started"]
        require(interval - 1 <= gap <= interval + bounds["cadence_slack_seconds"],
                f"monitor cadence gap {gap:.3f}s outside [{interval-1}, {interval+bounds['cadence_slack_seconds']}]")

    require(rows[0]["started"] <= bounds["cadence_slack_seconds"], "first scheduled run was late")
    require(duration - rows[-1]["started"] <= interval + bounds["cadence_slack_seconds"], "last scheduled run was missed")


def check_logs(size, elapsed, bounds=BOUNDS):
    limit = bounds["log_base_bytes"] + elapsed * bounds["log_bytes_per_second"]
    require(size <= limit, f"log bytes {size} exceeded {limit}")


def measure(directory, binary):
    """A fresh wrapper per oneshot makes resource.getrusage's child peak attributable."""
    import resource
    started = time.monotonic()
    wall_started = time.time()
    samples = []
    with (directory / "monitor.log").open("a") as log:
        proc = subprocess.Popen([binary, "monitor", "run", "--all"], stdout=log, stderr=log,
                                stdin=subprocess.DEVNULL)

        try:
            while proc.poll() is None:
                row = resources(proc.pid)
                if row and row["rss_bytes"]:
                    samples.append(row)
                require(time.monotonic() - started <= BOUNDS["monitor_seconds"], "monitor run exceeded timeout")
                time.sleep(0.001)
        finally:
            if proc.poll() is None:
                proc.kill()
            code = proc.wait()

    require(samples, "monitor exited without a resource observation")
    check_run(directory, wall_started, time.time())
    row = {key: max(r[key] for r in samples) for key in ("rss_bytes", "fds", "threads")}
    row["rss_bytes"] = max(row["rss_bytes"], resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * 1024)
    row.update(started=started-float((directory / "epoch").read_text()),
               seconds=time.monotonic()-started, wall_started=wall_started, code=code, samples=len(samples))
    with (directory / "runs.jsonl").open("a") as output:
        output.write(json.dumps(row) + "\n")
    require(code == 0, f"monitor exited {code}; see monitor.log")



def check_run(directory, started, finished):
    """Every scheduled invocation must commit its own matching run and snapshot."""
    data = directory / "data" / "leita"
    with closing(sqlite3.connect(data / "settings.db")) as db:
        latest = db.execute("SELECT started, bytes, problem FROM run ORDER BY id DESC LIMIT 1").fetchone()
    require(latest is not None and int(started) <= latest[0] <= int(finished),
            "monitor invocation did not commit a new run")
    require(not latest[2], "monitor invocation committed a failed run")

    with closing(sqlite3.connect(data / "history.db")) as db:
        snapshot = db.execute("SELECT taken, bytes FROM snapshot ORDER BY id DESC LIMIT 1").fetchone()
    require(snapshot is not None and snapshot[1] == latest[1]
            and latest[0] <= snapshot[0] <= int(finished),
            "monitor invocation committed inconsistent history")


def check_database(directory, expected_runs):
    data = directory / "data" / "leita"
    with closing(sqlite3.connect(data / "settings.db")) as db, db:
        require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "settings integrity_check failed")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "settings foreign_key_check failed")
        rows = db.execute("SELECT started, bytes, problem, updated FROM run ORDER BY id").fetchall()
        require(len(rows) == min(50, expected_runs), f"run retention mismatch: {len(rows)}, expected {min(50, expected_runs)}")
        require(all(not r[2] for r in rows), "monitor recorded a scan failure")
        require(any(r[3] for r in rows), "no monitor scan used the recorder/baseline incremental path")
        latest = rows[-1]

    with closing(sqlite3.connect(data / "history.db")) as db, db:
        require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "history integrity_check failed")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "history foreign_key_check failed")
        snapshots = db.execute("SELECT taken, bytes FROM snapshot ORDER BY id").fetchall()
        require(len(snapshots) == min(30, expected_runs), "snapshot retention mismatch")
        require(snapshots[-1][1] == latest[1]
                and latest[0] <= snapshots[-1][0] <= latest[0] + BOUNDS["monitor_seconds"] + 1,
                "last history snapshot disagrees with monitor run")
        require(not db.execute("SELECT 1 FROM entry LEFT JOIN snapshot ON snapshot.id=entry.snapshot WHERE snapshot.id IS NULL").fetchall(), "orphaned history entries")
    return dict(runs=len(rows), snapshots=len(snapshots), latest_bytes=latest[1])


def check_journal(folder, mount="/workload"):
    logs = list(folder.glob("*.log"))
    require(logs, "recorder produced no journal logs")

    changed = 0
    matching = 0
    for path in logs:
        data = path.read_bytes()
        require(data.startswith(b"LEITAJL1"), f"invalid journal header: {path}")
        offset = 10 + int.from_bytes(data[8:10], "little")
        require(len(data) >= offset and (len(data)-offset) % 17 == 0, f"partial journal record: {path}")
        if data[10:offset].decode() != mount:
            continue
        matching += 1
        kinds = [data[i] for i in range(offset, len(data), 17)]
        require(all(kind in (1, 2, 3, 5) for kind in kinds), "workload journal overflow, sleep or invalid record")
        # Kind.Changed = 3; require activity on the actual workload filesystem.
        changed += kinds.count(3)
    require(changed > 0, "recorder captured no directory changes")
    return dict(logs=len(logs), workload_logs=matching, changed=changed)


def systemctl(*args):
    return run(["systemctl", *args], capture_output=True).stdout.strip()


def guest(args):
    directory = args.output
    require(os.geteuid() == 0 and Path("/run/systemd/system").exists(), "guest needs root and systemd PID 1")
    # The host launches this guest only in a disposable privileged CI container.
    require(Path("/.dockerenv").exists(), "guest refuses a host root session")
    env = dict(os.environ, XDG_RUNTIME_DIR="/run/user/0", DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus",
               XDG_DATA_HOME=str(directory / "data"), LEITA_COLOR="never")
    os.environ.update(env)
    systemctl("start", "user@0.service")
    systemctl("--user", "import-environment", "XDG_DATA_HOME", "LEITA_COLOR")
    image = directory / "workload.ext4"
    with image.open("wb") as f:
        f.truncate(256 * 1024**2)
    run(["mkfs.ext4", "-q", "-F", image])
    target = Path("/workload")
    target.mkdir()
    run(["mount", "-o", "loop", image, target])
    place = target / "watched"
    place.mkdir()
    for i in range(512):
        folder = place / str(i)
        folder.mkdir()
        for j in range(4):
            (folder / str(j)).write_bytes(b"x" * 4096)

    run([args.binary, "journal", "on"])
    recorder_pid = int(systemctl("show", "leita-journal.service", "-p", "MainPID", "--value"))
    require(recorder_pid > 0, "recorder did not start")
    # No thresholds and no webhooks: this fixture cannot send alerts.
    run([args.binary, "monitor", "add", place, "--every", "hourly"])
    run([args.binary, "monitor", "on"])
    units = Path("/root/.config/systemd/user")
    shutil.copytree(units, directory / "production-units")
    systemctl("--user", "stop", "leita-monitor.timer")
    # Exercise the real installed timer with a shorter period and --all; preserve
    # its original hourly unit above so this is explicit test configuration.
    drop = units / "leita-monitor.timer.d"
    drop.mkdir()
    (drop / "endurance.conf").write_text(f"[Timer]\nOnCalendar=\nOnBootSec=1s\nOnUnitActiveSec={args.interval}s\nRandomizedDelaySec=0\nAccuracySec=100ms\n")
    drop = units / "leita-monitor.service.d"
    drop.mkdir()
    (drop / "endurance.conf").write_text(f"[Service]\nExecStart=\nExecStart=/usr/bin/python3 /harness/harness.py --measure --output {directory} --binary {args.binary}\n")
    systemctl("--user", "daemon-reload")
    epoch = time.monotonic()
    (directory / "epoch").write_text(str(epoch))
    systemctl("--user", "start", "leita-monitor.timer")
    rows = []
    try:
        while time.monotonic() - epoch < args.duration:
            elapsed = time.monotonic() - epoch
            require(systemctl("is-active", "leita-journal.service") == "active", "recorder stopped")
            row = resources(recorder_pid)
            require(row is not None, "recorder PID disappeared")
            row.update(elapsed=elapsed)
            # Bounded churn: overwrite, rename, create and unlink fixed names.
            folder = place / str(len(rows) % 512)
            if elapsed < args.duration - args.interval - 2:
                mutate(folder, len(rows))
            row["log_bytes"] = sum(p.stat().st_size for p in Path("/var/lib/leita/journal").glob("*"))
            if (directory / "monitor.log").exists():
                row["log_bytes"] += (directory / "monitor.log").stat().st_size
            check_logs(row["log_bytes"], elapsed)
            rows.append(row)
            with (directory / "recorder.jsonl").open("a") as f:
                f.write(json.dumps(row) + "\n")
            time.sleep(min(1, max(0, args.duration - (time.monotonic()-epoch))))

        systemctl("--user", "stop", "leita-monitor.timer")
        # Stop both services before consistency checks.
        systemctl("--user", "stop", "leita-monitor.service")
        systemctl("stop", "leita-journal.service")

        runs = [json.loads(line) for line in (directory / "runs.jsonl").read_text().splitlines()]
        check_resources(rows)
        check_resources(runs)
        check_cadence(runs, args.duration, args.interval)
        history = check_database(directory, len(runs))
        full = json.loads(run([args.binary, place, "--whole", "--no-history", "--report", "-", "--format", "json"], capture_output=True).stdout)
        write_json(directory / "full-scan.json", full)
        require(full["totals"]["unread"] == 0, "full scan had unread directories")
        require(full["totals"]["bytes"] == history["latest_bytes"], "incremental history disagrees with final whole scan")
        journal = check_journal(Path("/var/lib/leita/journal"))
        write_json(directory / "summary.json", dict(status="pass", duration_seconds=time.monotonic()-epoch,
                   interval_seconds=args.interval, bounds=BOUNDS, monitor_runs=len(runs), recorder_samples=len(rows),
                   maxima={kind: {key: max(r[key] for r in series) for key in ("rss_bytes", "fds", "threads")}
                           for kind, series in (("monitor", runs), ("recorder", rows))},
                   history=history, journal=journal))
    finally:
        systemctl("--user", "stop", "leita-monitor.timer")
        systemctl("stop", "leita-journal.service")
        shutil.copytree("/var/lib/leita", directory / "recorder-state", dirs_exist_ok=True)
        (directory / "systemd.log").write_text(run(["journalctl", "--no-pager"], capture_output=True).stdout)
        (directory / "timer.txt").write_text(systemctl("--user", "cat", "leita-monitor.timer", "leita-monitor.service"))
        run(["umount", target])
        image.unlink()


def mutate(folder, turn):
    (folder / "0").write_bytes(b"y" * (4096 + (turn % 4) * 1024))
    (folder / "new").write_bytes(b"z" * 1024)
    (folder / "new").rename(folder / "renamed")
    (folder / "renamed").unlink()


def host(args):
    require(sys.platform == "linux", "unsupported: Linux fanotify, /proc and systemd are required")
    require(os.environ.get("GITHUB_ACTIONS") == "true", "unsupported: privileged systemd containers run only on a disposable GitHub Actions VM")
    require(shutil.which("docker"), "unsupported: docker is missing")
    require(args.binary.is_file(), f"binary does not exist: {args.binary}")
    args.output.mkdir(parents=True, exist_ok=True)
    require(not any(args.output.iterdir()), "output directory must be empty")
    write_json(args.output / "config.json", dict(duration_seconds=args.duration, interval_seconds=args.interval,
               bounds=BOUNDS, image=IMAGE, sha=run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True).stdout.strip()))
    # Reuse test-install/linux's systemd container setup, with no host service installation.
    prepare = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd systemd-sysv libpam-systemd dbus dbus-user-session python3 util-linux e2fsprogs >/dev/null && for u in getty.target console-getty.service getty@.service serial-getty@.service; do ln -sf /dev/null /etc/systemd/system/$u; done && exec /sbin/init"
    container = run(["docker", "run", "-d", "--privileged", "--cgroupns=private", "-e", "container=docker",
                     "--tmpfs", "/run", "--tmpfs", "/run/lock", "-v", f"{args.binary}:/leita:ro",
                     "-v", f"{Path(__file__).parent}:/harness:ro", "-v", f"{args.output}:/evidence", IMAGE,
                     "bash", "-c", prepare], capture_output=True).stdout.strip()
    try:
        deadline = time.monotonic() + 180
        while True:
            proc = subprocess.run(["docker", "exec", container, "systemctl", "is-system-running"], capture_output=True, text=True)
            if proc.stdout.strip() in ("running", "degraded"):
                break
            require(time.monotonic() < deadline, "container systemd did not start within 180s")
            time.sleep(1)

        run(["docker", "exec", container, "python3", "/harness/harness.py", "--guest", "--binary", "/leita",
             "--output", "/evidence", "--duration", args.duration, "--interval", args.interval], timeout=args.duration+120)
    finally:
        logs = run(["docker", "logs", container], capture_output=True)
        (args.output / "container.log").write_text(logs.stdout + logs.stderr)
        # Also retain startup failures before guest() reaches its own finally block.
        subprocess.run(["docker", "exec", container, "bash", "-c",
                        "journalctl --no-pager > /evidence/systemd-final.log; "
                        "if [ -d /var/lib/leita ]; then cp -a /var/lib/leita /evidence/recorder-final; fi"],
                       check=False)
        subprocess.run(["docker", "exec", container, "chown", "-R", f"{os.getuid()}:{os.getgid()}", "/evidence"], check=False)
        run(["docker", "rm", "-f", container], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=7200)
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--output", type=Path, default=ROOT / "build/endurance")
    parser.add_argument("--binary", type=Path, default=ROOT / "build/debug/leita")
    parser.add_argument("--guest", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--measure", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not (60 <= args.duration <= 14400 and 5 <= args.interval <= 300 and args.duration >= 4*args.interval):
        parser.error("duration must be 60..14400 s and at least 4 intervals (5..300 s)")
    args.output = args.output.resolve()
    args.binary = args.binary.resolve()

    try:
        if args.measure:
            measure(args.output, str(args.binary))
        elif args.guest:
            guest(args)
        else:
            host(args)
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        if args.output.is_dir():
            write_json(args.output / "failure.json", dict(status="fail", detail=str(error)))
        print(f"endurance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
