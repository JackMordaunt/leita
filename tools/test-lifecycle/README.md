# Lifecycle evidence

`just lifecycle` builds release command lines, runs them from the layouts a
release actually ships, and writes `build/lifecycle/evidence-update.json`.
`gate.py local` merges every `evidence-*.json` in that directory and fails
unless each required case passed on this operating system. A case that does
not apply here is `na`. `blocked` and `fail` fail the job. A missing id fails
the job.

The release workflow waits for the lifecycle run of the same commit and
judges the merged evidence again before it publishes. A dry run does not
publish. Publishing fails closed when `LEITA_UPDATE_KEY` or
`LEITA_UPDATE_SEED` is missing. The lifecycle fixture generates its own
throwaway Ed25519 key and does not read those secrets. `production_signature`
stays false: a fixture signature is not a production package signature.

## Evidence

Schema 1. One producer file per tool, named `evidence-<producer>.json`:

```json
{
  "schema": 1,
  "producer": "update",
  "sha": "<git sha of this checkout>",
  "os": "linux",
  "production_signature": false,
  "fixture": "throwaway-ed25519",
  "cases": [{ "id": "update_check_newer", "status": "pass", "detail": "" }]
}
```

`os` is `linux`, `darwin` or `windows`. `status` is `pass`, `fail`, `na` or
`blocked`. Producers that disagree on a status merge to `fail`.

Set `LIFECYCLE_DIR` (default `build/lifecycle`) and `LIFECYCLE_SHA` (default
`git rev-parse HEAD`) before a producer runs. This workflow runs
`tools/test-licence-lifecycle/harness.py` and
`tools/test-schedule-lifecycle/harness.py` when those files exist. They own
`activation_http`, `receipt_recovery`, `automatic_startup_check` and
`automatic_daily_check`. This harness does not write those ids.

## Reuse

Capture can import this directory and drive the same fixture. Nothing here
starts a window or writes a screenshot.

```python
import sys
sys.path.insert(0, "tools/test-lifecycle")
import fixture

key = fixture.keygen()
name = fixture.host_asset("command")
fixture.write_release(
    "build/lifecycle/fixture-release",
    {name: open("build/lifecycle/bin/new-leita", "rb").read()},
    version="v0.0.2",
    released="2026-10-21T00:00:00Z",
    seed=key.seed,
)
with fixture.ReleaseServer("build/lifecycle/fixture-release") as server:
    base = server.url
```

`write_release` writes `version.txt` and `released.txt`, then
`sha256sums.txt`, then `sha256sums.txt.sig`. The signature is not listed in
the sums. `ReleaseServer.requests` records `{path, user_agent}`. `stall` is
a set of file names whose body never finishes.

`fixture.py keygen`, `public --seed-hex`, `sign --seed-hex --in --out` and
`verify --public-hex --in --sig` are the command-line forms the release
workflow uses. The seed from `keygen` is throwaway. Do not store it, and do
not pass `LEITA_UPDATE_SEED` into a fixture run.

A copied executable is evidence that the command line updates. It is not
packaged-installation evidence. The packaged cases run a binary taken out of
an assembled archive, and where the host can build them, a deb payload, an
rpm payload, an AppImage, `Leita.app`, a disk image, or the Windows
installer directed at a temp directory.
