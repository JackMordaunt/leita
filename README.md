<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="leita" width="538">
  </picture>
</p>

<p align="center"><b>leita</b> <i>(Old Norse, verb)</i> — “to search, to seek.”</p>

<h3 align="center">Instant disk search, with reports.</h3>

<p align="center">See what is filling any drive the moment you open it, then hand the answer on as a report.</p>

<p align="center"><b>Free to scan and clean up</b> · reports with a licence · source published · no telemetry · Linux, Windows and macOS</p>

<p align="center">
  <a href="branding/demo.mp4"><img src="branding/demo-poster.png" style="border-radius: 12px; box-shadow: 0 22px 70px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba(0, 0, 0, 0.12);" alt="leita scanning a disk: the sunburst, treemap and icicle views fill in as the scan runs, in the light theme and then the dark" width="900"></a>
  <br><a href="branding/demo.mp4">▶ Watch the 38-second demo</a>
</p>

---

## Answers in seconds, not minutes

Point leita at a drive and the picture of it starts filling in at once. You
don't wait for a scan to finish: the chart grows as leita reads the disk,
and you can start exploring while the rest arrives.

- **Three ways to see it:** sunburst, treemap and icicle. Switch at any time.
- **Click to dig in:** open any folder to see what fills it.
- **Any drive or folder:** your laptop, a server, an external disk or a disk image.

## Reports that make the case

Turn any scan into a report from the Export button: **PDF** for the person who signs
off on a new disk, **HTML** to share, **CSV** for a spreadsheet, **JSON** for
your own tools. Each report lists the largest folders and files, how full
the disk is, and what can be cleaned up.

Reports come with a licence. Try them free for the first 30 days.

## See what changed

leita remembers every scan. Scan the same place again and it shows what grew
and what shrank since last time, so the folder that filled up overnight
stands out on its own.

Comparing scans comes with a licence too, with the same 30-day trial. leita
keeps every scan either way, so your history is all there when you add one.

## Scheduled scans

Have leita scan the places you care about every hour, day or week while it is
closed, so change tracking has a steady record. Open **Monitoring** (the pulse
in the toolbar), add a place, and turn on **Scheduled scans**. Each scan runs
gently, at low priority, and is kept like any other.

leita keeps nothing running: it hands one hourly entry to your system's own
scheduler (a systemd user timer on Linux, a Task Scheduler task on Windows, a
launchd agent on macOS), which starts `leita monitor run`, scans whatever is
due and exits. Turning monitoring off removes that entry; nothing runs unless
you turn it on. The same is there from the terminal:

```sh
leita monitor add ~/Projects --every daily
leita monitor on
leita monitor list
leita monitor off
```

Each watched place can raise an alert: when its disk passes a percent used or
falls under a free space you set, when it is forecast to fill within some
days, from the scans kept so far, or when the place grows far faster than it
has been. An alert shows once, as a desktop notification and in Monitoring,
the scan it first appears, and again only after it has cleared:

```sh
leita monitor add D: --warn-used 80 --fail-used 95 --min-free 20GiB --full-within 14 --growth
```

To hear of alerts on your own server, add a webhook in Monitoring, or from the
terminal. Each new alert is posted as JSON, over https, with a summary of the
scan in the report schema ([report/SCHEMA.md](report/SCHEMA.md)); the folder
paths inside a place stay out unless you pass `--paths`. A delivery the server
cannot take waits and is tried again, with backoff, on later runs.

```sh
leita monitor webhook add https://hooks.example.com/leita
leita monitor webhook test
```

Each request carries `X-Leita-Timestamp`, the Unix seconds it was signed at,
and `X-Leita-Signature`: `sha256=` and the hex HMAC-SHA256 of the timestamp, a
full stop and the body, keyed with the secret `webhook add` prints. A server
checks it like this, and refuses a timestamp far from now:

```python
import hmac, hashlib
expected = "sha256=" + hmac.new(secret.encode(), f"{timestamp}.{body}".encode(), hashlib.sha256).hexdigest()
ok = hmac.compare_digest(expected, signature)
```

The body's members are described in [webhook/event.odin](webhook/event.odin).

Scheduled scans, their alerts and webhooks come with a licence, with the same
30-day trial.

## Free up space, safely

Reclaim finds the space you can get back without losing anything: build
output, downloaded packages, application caches and the Trash. Each item
shows how much it frees and why it is safe to delete. leita only lists
something when it can prove what it is, and never touches system folders.

Every deletion is logged with what was removed, how big it was and when.
When someone asks what was cleared off the file server last week, you have
the answer.

## Private by design

- **No telemetry.** leita never sends anything unless you tell it where. It
  sends a licence key once, when you add one, to fetch your licence; and it
  sends alerts to the webhooks you add, and nowhere else. The source is
  published, so you can check.
- **Nothing to set up.** One small app, no account, no runtime to install.
- **Your data stays with you.** Scans and the deletion log stay on your
  machine. A webhook carries the folder paths inside a place only if you
  allow it.

## Get started

Open **Leita** and pick a drive or folder. To scan a whole drive, run it as
an administrator.

Prefer the terminal? The `leita` command does the same, and writes reports
too, under a licence or during the trial:

```sh
leita D: --report usage.pdf
```

`leita -h` lists every option.

## Scripts and monitoring

Alert from your RMM tool the moment a drive passes 90% used, no report and no
licence required. `--warn-used` and `--fail-used` check the percent used,
`--min-free` checks the bytes still free, and leita exits with a code your
script or RMM tool (NinjaOne, Datto, ConnectWise, ...) can act on:

```sh
leita D: --warn-used 80 --fail-used 95 --min-free 20GiB
```

| Exit code | Meaning |
| --- | --- |
| 0 | OK: no limit was crossed |
| 1 | Error: a bad flag, or the drive could not be scanned |
| 2 | Warning: `--warn-used` was crossed |
| 3 | Failed: `--fail-used` or `--min-free` was crossed |

A one-line summary goes to standard error (`warn: 83.4% used, at or past
--warn-used 80%`); nothing is printed for an OK scan beyond the usual summary.
Add `--report - --format json` to also get the full scan on standard output,
with the verdict in its `thresholds` member (`report/SCHEMA.md`).

## Licensing

**Scanning, the charts and Reclaim are free for personal use.** That covers
your own computer, your own studies, and unpaid hobby or open-source work.

**Reports, change tracking and scheduled scans need a licence.** They work
for 30 days from the first time you run leita, so you can try them first. To add a licence,
click the key in the toolbar and paste the licence key from your receipt.

**Organisations need a commercial licence for any use.** This applies to
businesses, sole traders, schools, charities and government. You can
evaluate leita for 30 days before you buy. The full terms are in
[LICENSE.md](LICENSE.md).

## Build from source

leita is written in [Odin](https://odin-lang.org) and builds with
[just](https://just.systems).

```sh
just release       # build/release/leita
just gui-release   # build/release/app/Leita
just test
```

`just` alone lists every recipe.
