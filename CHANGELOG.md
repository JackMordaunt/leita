# Changelog

All notable changes are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Each release is one section.

## [Unreleased]

**Added**

- The window and the `leita` command, also installed as `le`, scan a drive or a folder and draw it as a sunburst, a treemap or an icicle while the scan is still running.
- A finished scan can be saved as a PDF, HTML, CSV or JSON report, and the text of a PDF can be searched.
- A licence is checked on the machine, and the only network use is sending a key once to fetch it.
- Reclaim lists build output, downloaded packages, application caches and the Trash that can be removed and made again, including the usual caches on a Mac, and logs each deletion; History in the window's settings menu and `leita history` list that log, newest first.
- Every finished scan is kept, and scanning the same place again marks what grew and what shrank and reads only what changed.
- On macOS and Windows a second scan uses the system's change journal, and on Linux it uses each folder's modification time.
- On Linux, `leita journal on` (or Record changes in Monitoring) installs the root service leita-journal, which for 30 days logs a hash of each changed folder and when it changed, never the name, does not cover btrfs subvolumes yet, and is removed by `leita journal off`.
- Places can be scanned every hour, day or week by the system's own scheduler, with one alert when a disk is too full, short of free space, forecast to fill, or growing much faster than before.
- Search ranks hits the way a path search does, and a file or folder opens the way the system would.
- The window can be set to English, German, Spanish, French, Italian, Japanese, Korean, Brazilian Portuguese, Russian or Simplified Chinese, and it remembers the language and the theme.
- About names the version, the maker and the licences of what the window is built on.
- `--warn-used`, `--fail-used` and `--min-free` make leita exit with a code a script can act on.
- `LEITA_SYNTHETIC` scans a made-up disk, so a demo shows no one's real files.
- On Windows, an elevated scan reads the Master File Table.
- On macOS 11 or later, Leita comes as Leita.app in a disk image, signed and notarised, with the `leita` command inside it.

**Changed**

- Sizes are the space taken on disk, printed in decimal units, and an amount you type may be decimal or binary.
- A Linux scan stays on the filesystem it started on, walks other btrfs subvolumes of the same pool, skips read-only snapshots, and counts each btrfs extent once.
- A scan reads one directory per processor core.
- The window is titled Leita, named after the folder scanned, takes shortcuts on the platform's command key, and scans again on R.
- The chart stays put when the status line updates, when search opens, and while a Monitoring switch waits for an answer.
- The window's commands live in a settings menu.
- A scheduled scan is registered under the path leita was started by, and Monitoring shows that path.
- The window runs on macOS 11 or newer without Homebrew, and a Windows build carries the libraries the window needs so it starts.
- Animation in the window runs at 60 frames a second.
- Search treats an accented Latin letter as the letter without the accent.
- Thumbnails unused for 30 days are removed, and the thumbnail folder is kept within 256 MiB.
- A saved tree that no scan has rewritten in 30 days is deleted, and on Linux a place last read in full more than 7 days ago is read in full the next time.
- A saved tree is replaced only after the new copy has been written, and stopping a watch keeps the tree.
- Passing any flag to the window runs the command line.
- An elevated scan of a folder on NTFS reads that folder's part of the Master File Table, and finding the folder's record does not need elevation.

**Fixed**

- A scan says how many folders it could not read.
- The largest files in a report stay inside the folder that was scanned.
- A copied file keeps its size when it cannot be measured again, including when the change journal is in use.
- When replaying changes would take too long, the scan reads the place whole and says why, and a change too new for one update is read by the next.
- A second scan of a Windows drive letter, such as `C:`, follows that volume.
- Reclaim, run with sudo, uses the home of the person who invoked it.
- On Windows, a link to a directory is refused as a tree to delete.
- Opening a file or folder works on a desktop where it used to hang.
- A scan no longer takes the keyboard focus while it runs.
- The Linux recorder still covers a suspend it slept through, and looks at a filesystem again after it is unmounted or mounted.
- Export waits until the change replay has named what changed before it scans again.
- A scan that runs long enough to draw no longer loses the path of its saved tree.
- A scheduled scan no longer skips a run because of a program it has just started.
- A failure to save scan history names the problem.
