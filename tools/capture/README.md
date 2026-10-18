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

The real fixture starts with a CMake project and 3 files. In the same running
app, the script exports the initial scan, adds an 8 MiB build object and a CMake
marker, grows a source asset from 2 to 3 MiB, invokes Rescan, selects Change and
Reclaim, then exports JSON and HTML through the actual UI save dialog. It checks
allocated byte totals, snapshot comparison, file counts, unread count, the new
build-output classification, and the source asset's exact 1 MiB growth. A
failure stops the suite. `fixture/{light,dark}/validation.json` holds the checked numbers.
Each theme also records a 14 s workflow: initial scan, baseline, external build
addition, Rescan, Change, Reclaim, export dialog and saved-report notice. JSON and
HTML exports are copied into `fixture/{light,dark}/`; their original destinations
are generic paths alongside the generated fixture, so video notices show no
personal output directory. The fixture is generated example data, although the report accurately identifies
it as a real filesystem scan, not Leita's synthetic engine.

Light and dark imagery each uses the synthetic disk at day 0 as the baseline
and day 7 as the scan. Both run the same five scenes: Sunburst, Treemap, Icicle,
Treemap by Change, and Reclaim. `--frames 60` (default) records 60 frames of each
scene at 30 fps, making two 10 s H.264 videos. The scene transitions are clicks;
the captured scenes begin after 30 animation-settling frames. A scan is complete
before recording, so host scheduling does not change the scene order or video
length. This is a view tour, not a recording of elapsed scan time. Use each
`sunburst.png` as its theme's poster. `--frames 0` skips frames and video;
`--fixture-only` runs only the validated filesystem scenario.

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
- `-frames PREFIX COUNT`: consecutive 30 fps PNGs named `PREFIX00000.png`, etc.

All input dispatch and host responses are real. Theme selection is the only
view-state override. The caller owns the step list and must use generated
fixtures: ordinary app actions can write or delete files when explicitly clicked.
