<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/hero-dark.svg">
    <img src="branding/hero-light.svg" alt="leita" width="538">
  </picture>
</p>

<p align="center"><b>leita</b> <i>(Old Norse, verb)</i> — “to search, to seek.”</p>

<h3 align="center">Instant disk search, with reports.</h3>

<p align="center">See what is filling any drive the moment you open it, then hand the answer on as a report.</p>

<p align="center"><b>Free for personal use</b> · source published · no telemetry · Linux, Windows and macOS</p>

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

## See what changed

leita remembers every scan. Scan the same place again and it shows what grew
and what shrank since last time, so the folder that filled up overnight
stands out on its own.

## Free up space, safely

Reclaim finds the space you can get back without losing anything: build
output, downloaded packages, application caches and the Trash. Each item
shows how much it frees and why it is safe to delete. leita only lists
something when it can prove what it is, and never touches system folders.

Every deletion is logged with what was removed, how big it was and when.
When someone asks what was cleared off the file server last week, you have
the answer.

## Private by design

- **No telemetry.** leita never sends anything anywhere. The source is
  published, so you can check.
- **Nothing to set up.** One small app, no account, no runtime to install.
- **Your data stays with you.** Scans and the deletion log stay on your
  machine.

## Get started

Open **Leita** and pick a drive or folder. To scan a whole drive, run it as
an administrator.

Prefer the terminal? The `leita` command does the same, and writes reports
too:

```sh
leita D: --report usage.pdf
```

`leita -h` lists every option.

## Licensing

**Personal use is free, with every feature included.** That covers your own
computer, your own studies, and unpaid hobby or open-source work.

**Organisations need a commercial licence.** This applies to businesses,
sole traders, schools, charities and government. You can evaluate leita for
30 days before you buy. The full terms are in [LICENSE.md](LICENSE.md).

## Build from source

leita is written in [Odin](https://odin-lang.org) and builds with
[just](https://just.systems).

```sh
just release       # build/release/leita
just gui-release   # build/release/app/Leita
just test
```

`just` alone lists every recipe.
