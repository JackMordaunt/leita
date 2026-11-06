Leita scheduled-scan metrics

This optional Pro workflow writes a Prometheus textfile after monitor runs. It
opens no port, starts no process and makes no network request. Basic manual
scanning and current-scan CSV/JSON exports are unchanged.

Choose a directory already collected by your node_exporter textfile collector.
Arrange permissions so the user running Leita can create and replace files there
and node_exporter can read them. For example, after configuring that directory:

  leita monitor metrics /var/lib/node_exporter/textfile/leita.prom
  leita monitor metrics
  leita monitor run

The first command saves an absolute destination ending in .prom. It does not
create output. The next enabled, unlocked monitor run writes the file after its
scans. Existing monitor on/off and schedule controls still apply. A run with no
due places republishes retained measurements with their original scan times.

  leita monitor metrics off

Inspection and disabling work after the evaluation ends. Disabling also clears
the bounded retained metrics samples; existing scans and history are preserved.
Changing the destination also clears those samples. Until a fresh due scan,
recorded outcome/times can be shown but detailed quantities stay unknown. Disabling metrics,
turning monitoring off, and a licence-locked run leave the previous file in
place. Remove that file yourself if it should no longer be scraped. A file that
still exists is not evidence that monitoring is running or that its licence is
unlocked. Check scan timestamps and the scheduler's exit/log record.

Privacy and path identity

Enabling the local textfile explicitly includes watched-place and selected
folder paths. Anyone who can read the file or scrape your exporter can read
those labels. It includes no webhook secret, licence key or file contents.
Percent signs, invalid UTF-8 bytes and controls other than newline are encoded
as %HH using uppercase hexadecimal. A literal percent sign becomes %25, so
encoding never conflates an invalid byte with a literal escape spelling.
Valid Unicode is retained. Quotes, backslashes and newlines then receive the
Prometheus text-format escaping. Labels are never truncated.

Bounds

At most 64 watched places are exported, in the watch list's stable added/place
order. Places whose encoded label exceeds 1024 bytes are omitted. Normal
monitoring still scans every due watch; this is an output bound only.
leita_metrics_watches_omitted reports the number excluded.

For each exported place, at most 10 nonempty directories at depth one or two
below the target are selected by charged bytes, largest first; equal sizes use
path order. The target itself and deeper directories are not separate series.
A folder label over 1024 encoded bytes is omitted, never truncated into another
folder's identity. leita_monitor_directories_omitted counts eligible nonempty
folders omitted by ranking or label bounds. Parents and children overlap; do not
sum their totals. Directories with zero charged allocation are not ranked.

The retained state and rendered text each have a 2 MiB limit. State is bounded
and versioned in settings.db; removed watches are pruned on the next enabled
run. If the cache is corrupt/newer, or encoding/output exceeds a bound, ordinary
monitoring still runs, the error is printed and exit status is 1. The previous
output remains. Do not edit cache contents or treat a newer format as empty.

Meaning and freshness

All quantities are gauges. leita_monitor_scan_charged_bytes uses the same
report accounting as Leita's other exports: summed charged allocation, not a
promise of unique physical space or bytes deleting the place will return.
scan_accounting_known indicates whether accounting flags were captured.
scan_logical = 1 means logical fallback instead of native allocation;
scan_order = 1 means scan-order estimates. These are separate from whether
any directories were unread. The sample dashboard excludes either estimate.
Volume total/free are filesystem capacity counters and may repeat for several
places on the same volume. They must not be summed across those places.

leita_monitor_last_attempt_timestamp_seconds is the start time of the last
recorded attempt. leita_monitor_last_success_timestamp_seconds is the start of
the last successful scan and history save. Zero means no such time is known.
Neither is advanced when a not-due place is republished.

scan_success = 1 means scanning and saving history succeeded. It can still be a
partial scan: scan_complete is 0 and scan_unread_directories names the number
of unread directories. scan_complete = 1 means no directories were reported
unread; it does not assert that all filesystem accounting features are known.

scan_measurement_known = 0 means no detailed quantities were captured for that
attempt. This occurs before the first metrics-enabled scan, after a failed
attempt, or when the most recent run was made without metrics enabled. A failed
attempt emits success/completeness/known = 0 and its attempt time, retains the
last successful timestamp, and omits quantities from the previous success.
It never gives old bytes the failed attempt's timestamp.

volume_capacity_known = 0 omits volume_total_bytes and volume_free_bytes; unknown
capacity is not zero. A zero total or free greater than total is also unknown.
scan_synthetic = 1 identifies the demonstration filesystem, not a real scan.
leita_metrics_generated_timestamp_seconds is when this textfile was generated;
it must never be used as the measurement timestamp.

Atomic output

Leita writes a fresh exclusive sibling in the destination directory, completes
and syncs it, closes it, then renames it over the destination. A failed create,
write, sync or replacement leaves the previous output unchanged and reports
exit 1. Ordinary scanning/history still complete. A hard kill can leave a
.partial-* sibling; its name does not end in .prom and is not a textfile sample.

Dashboard

Import grafana-dashboard.json and select your Prometheus data source. Its default
maximum age is 691200 seconds (8 days), allowing the existing weekly schedule.
Use a tighter value for hourly/daily places, or separate dashboards for mixed
cadences. It filters byte charts to recent successful complete real scans and
excludes future-dated attempts. The last-attempt age and outcome panels show
recorded state, not live process health. Add your own freshness/exit alerts.
Do not infer valid current measurements merely because the exporter is up.

The dashboard is a sample artifact; importing it or installing/configuring
node_exporter is an operator action. No host configuration is changed by Leita.

Format reference: https://prometheus.io/docs/instrumenting/exposition_formats/
The output uses grouped HELP/TYPE/sample families, UTF-8 and a trailing newline.
No explicit sample timestamps are emitted; scan times are separate gauges.
