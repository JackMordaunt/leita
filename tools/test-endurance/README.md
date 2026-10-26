# Monitor and recorder endurance

`python3 tools/test-endurance/harness.py` runs the real CLI and `leita-journal.service` for 7200 s on a
GitHub Actions Linux VM. `soak.yml` runs it nightly at 02:23 UTC, or manually
with mode `endurance`. It first runs a 60 s real-service smoke. Build the CLI with `SAN='' just cli` first. The existing
sanitizer jobs keep their separate default mode.

The harness reuses `test-install/linux`'s pinned Ubuntu image, privileged
systemd container, private cgroup namespace and masked gettys. It refuses a
desktop before starting Docker. Nothing installs a service on the runner or
the person's host. Linux fanotify (kernel >= 5.9), root capabilities, loop
mounts and Docker are required; missing prerequisites fail with their command
output rather than passing a mock or silently skipping the recorder.

The root controller starts the recorder and mounts the workload. A disposable
non-root user runs the monitor through its own systemd user manager and bus.
Its writable data and measurements live under `user/` in the evidence folder;
host metadata and container logs stay in the parent folder. Startup retains
observed UID/home/bus/data in `person.json` and both original and configured
units before starting the timer, including its cadence override.

The container mounts a disposable 256 MiB ext4 image. Its watched directory
contains 512 directories and 2048 files. Every second the workload overwrites
a fixed file, creates another, renames it and unlinks it. It stops changing the
files before the final scheduled scan. No limits or webhooks are configured;
no notifications or external app endpoints are used. The Pro evaluation in
the container's fresh data directory authorizes monitoring.

`leita monitor on` installs the production systemd user service and timer. Their
original hourly units are retained. Explicit test drop-ins run that same timer
every 15 s with `monitor run --all`, wrapped by the resource sampler. This
stresses real scheduled oneshot runs and does not claim to verify the original
hourly calendar or suspend/reboot behavior. Suspend/reboot behavior requires laptop evidence.

`recorder.jsonl` samples the continuous service's RSS, open file descriptors and
threads every second. `runs.jsonl` samples each real monitor subprocess every
1 ms, retaining its peaks and `getrusage`'s child peak RSS. Because each monitor
process exits, growth across runs compares its peaks, not a nonexistent
persistent monitor process. Startup samples are excluded from growth checks.

The explicit budgets in `harness.py` allow each process at most 256 MiB RSS,
128 descriptors and 32 threads. First/last-quarter median growth must stay
within 64 MiB, 16 descriptors and 4 threads. Journal plus monitor logs may
use 8 MiB plus 4096 B/s; the journal intentionally retains up to 30 days, so
zero growth would be an incorrect assertion. Monitor runs must finish within
10 s and keep a 15 s cadence within 5 s, including first/last-run checks.
Per-gap and first/last coverage bound run density while allowing relative-timer
jitter to accumulate. At the deadline the timer stops and any in-flight oneshot gets a bounded 12 s drain
while the recorder stays alive; cleanup cancels a run that remains stuck.

Each scheduled invocation must commit a new run and matching history snapshot,
so retention cannot hide an earlier skipped scan. The final gate checks SQLite integrity, foreign keys, bounded 50-run/30-snapshot
retention, successful incremental scans, agreement between the latest monitor
run and history snapshot, and agreement with a fresh `--whole --no-history`
scan. Journal logs must contain whole records and actual Changed events.
Self-tests deliberately violate every resource/growth bound, cadence, sampling,
log allowance and journal completeness so those checks cannot silently pass.

Every run retains configuration, source SHA, raw samples, stores, production and
test units, full-scan report, recorder state, and systemd/container logs under
`build/endurance*`. A successful run also writes `summary.json` with duration,
counts and maxima; a failure writes `failure.json`. Actions uploads these on
success or failure for 14 days. A 60 s smoke is not hours-long evidence; the
nightly/default manual duration is 7200 s.
