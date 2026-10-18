# Capture the current app

`tools/capture/build` builds `build/capture`, a desktop-free driver of the current
`app.Host`, scan/history/export pipeline and `view.view`. It uses jm's headless
probe and the same fonts as the window. It never substitutes canned view data.
`JM=/path/to/jm tools/capture/build` selects a dependency checkout without moving the
submodule. Build against the revision pinned by the app; record any override.

On Linux, regenerate the suite into a new output directory:

```sh
tools/capture/build
python3 tools/capture/suite.py /path/to/new-capture \
  --fixture-root /tmp/leita-example-new \
  --jm-revision "$(git -C jm rev-parse HEAD)"
```

The fixture parent must be an existing tmpfs outside protected system paths
(`/tmp` is tmpfs on the capture machine). Each output/fixture directory must be
new. The script refuses existing directories and leaves its generated files for
inspection. It never removes files, cleans Reclaim candidates, enables a
recorder, changes a licence, or reads personal history. Each host receives its
own explicit history, reports and thumbnail directory. Dependencies: Odin, jm's
native libraries, Python 3, `stat`, Git, and FFmpeg when frames are enabled.

The real fixture starts with a CMake project and 3 files. A separate isolated
host exports its initial report. The filmed host starts a scan through Settings
→ Rescan, then the script adds an 8 MiB build object and a CMake marker and grows
a source asset from 2 to 3 MiB. A visible cue explains this external addition.
The pointer invokes Rescan, selects Change and Reclaim, then exports HTML through
the actual UI. The save-dialog path is supplied by the headless picker. It never
selects a cleanup candidate. The 40.13 s continuous recording includes deliberate
pointer travel, native control press/release feedback, reading pauses, and the saved notice.

The script checks allocated byte totals, snapshot comparison, file counts,
unread count, the new build-output classification, and the source asset's exact
1 MiB growth. A failure stops the suite. `fixture/{light,dark}/validation.json`
holds the checked numbers. JSON and HTML exports are copied into those folders;
their original destinations are generic paths alongside the generated fixture.
The fixture is generated example data, although its report accurately identifies
it as a real filesystem scan, not Leita's synthetic engine.

The 22 s hero records a running day-7 synthetic scan. Sunburst fills first; the
pointer selects Treemap and then Icicle while the walker continues, followed by
2 s at completion. An optional synthetic directory-boundary clock releases the
same real batches every three video frames in both themes. The host still folds
the tree and sends its own progress/layout answers; the clock changes pacing,
not entries or view data. Its optional elapsed clock also supplies the in-app
synthetic scan counter, so PNG encoding time does not speed that counter up.
Normal scans keep their wall clock. This is a controlled demonstration, not a measurement
of elapsed scan time. Each view must show more than 10 distinct increasing
progress counts while Scanning or capture fails. `storyboard.json` records every
action, exact target, timing and sampled progress. Theme storyboards must match.

All five clean stills (Sunburst, Treemap, Icicle, Change and Reclaim) are taken
separately after the scan finishes, against a day-0 history baseline. They have
no pointer or video cue. Use each `sunburst.png` as its theme's poster.
`--frames 60` remains accepted for compatibility: any positive value enables the
fixed 30 fps choreography; `--frames 0` skips videos. `--fixture-only` runs only
the validated filesystem scenario. Timelines are never stretched to match an
old duration; use the frame count and seconds in the manifest.

The app lays out at 1280×820 with density 2. The driver scales the flattened
vector/glyph draws and clips at rasterisation to write 2560×1640 PNGs. It does
not upscale a 1× image. Reports are exported HTML for a browser to render at
its chosen widths/themes; this driver does not screenshot a browser.
`manifest.json` records checkout, application and capture-tool revisions, dirty
status, capture-source hashes, the declared jm revision, binary hash, geometry, sequence, validation,
and artifact hashes. Dates, scan timings, free disk space and report timestamps
remain the app's real measurements; captures are reproducible in procedure and
geometry, not byte-identical across machines or capture dates.

## Driver steps

```sh
mkdir /tmp/leita-capture-state
build/capture /path/to/generated-fixture /tmp/leita-capture-state light \
  -await Done -advance 30 -png /tmp/window.png \
  -click Treemap -advance 30 -png /tmp/treemap.png
```

The first three arguments are target, explicit isolated state directory, and
`light|dark`. It accepts jm headless steps (`-click`, `-hover`, `-key`, `-scroll`,
`-advance`, `-dump`, etc.) plus:

- `-png PATH`: current frame at 2×.
- `-await TAG`: wait up to 120 s for the real host/view to show a tag.
- `-rescan`: Ctrl+R, then wait for a newer generation to finish (Linux).
- `-pick PATH`: answer the UI's pending save/open dialog.
- `-signal PATH`, `-await-file PATH`: synchronize an external fixture mutation.
- `-frames PREFIX COUNT`: consecutive clean 30 fps PNGs named `PREFIX00000.png`, etc.
- `-movie PREFIX`, `-end-movie`: start/stop continuous frames with a macOS-style black arrow and thin white outline.
- `-tap TAG`: travel 21 frames, hover 6, press 5, then release and settle 18 frames.
- `-glide X Y FRAMES`, `-hold FRAMES`: move with eased endpoints or pause.
- `-cue TEXT`: show an explicit external-action caption; an empty string clears it.
- `-stream`: use the synthetic frame clock (requires `LEITA_SYNTHETIC`).

Inside a movie, use `-tap` instead of instantaneous headless clicks. `-await TAG`
asserts the expected state at that frame; it fails rather than silently hiding
extra scan time. `-png` always omits the pointer and cue, even inside a movie.

All input dispatch and host responses are real. Theme selection is the only
view-state override. The caller owns the step list and must use generated
fixtures: ordinary app actions can write or delete files when explicitly clicked.
