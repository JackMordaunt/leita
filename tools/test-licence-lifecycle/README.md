# Licence lifecycle

`harness.py` writes `evidence-licence.json` for the native lifecycle gate. CI runs
it when this file is present (`LIFECYCLE_DIR`, default `build/lifecycle`). It
builds throwaway-keyed command lines and headless capture hosts, drives them,
and does not render videos.

The fixture mints Ed25519 keys in process and serves activation and signed
releases on `127.0.0.1`. It does not read a production seed and it does not call
mordaunt.dev or GitHub. `production_signature` is false. The fixture name is
`throwaway-ed25519`.

Required ids from this producer, `pass` on linux, darwin and windows:

- `activation_http` — one real POST, the line and receipt are stored, and a
  second process still shows Pro with the activation server unreachable.
- `receipt_recovery` — a line signed by a key this build does not trust is
  exchanged once from the receipt. A 404 leaves those bytes and does not post
  again in that same process. The next process may try once more; that is the
  product's once-per-open behaviour.

Other ids in the file are extra. They must not repeat an id the update harness
writes. GUI state comes from clicks, typing and the files the host reads. A
pre-seeded licence, receipt or `first-use` file is that on-disk state.

`python3 -m unittest discover -s tools/test-licence-lifecycle -p 'test_*.py'`
checks the fixture without building Leita.

The bounded first-run/activation still matrix (`tools/capture/activation.py`)
also runs as `host_activation_ui_matrix`. Both themes at 1280×820 and 480×360
cover fresh trial, trial over, activation, malformed/unknown/refunded keys,
connection refusal and HTTP 500; one additional case uses the real 30-second
timeout. PNGs, tags and a native-OS manifest are retained in
`build/lifecycle/captures` by CI. They are evidence for inspection, not image
goldens. Buy is observed through the probe without opening a browser.

The larger screenshot and video demos are `tools/capture/lifecycle.py`. They
are not part of this harness unless `--demos DIR` is passed, and are not committed.
Set `JM` to a jm checkout that already contains the native libraries when the
worktree submodule has not built them.
