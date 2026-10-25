# Install, upgrade and uninstall on clean machines

`.github/workflows/install.yml` runs this for a release candidate: a `v*`
tag, a `ci/release-*` branch, or a branch with `install` in its name.
`release.yml` publishes a tag only when that run passed for the tag's commit.

- `build OUT VERSION [REF]` builds this platform's release artefacts the way
  `release.yml` builds them, from this checkout or from a worktree of REF. The
  builds carry the justfile's test licence key and the throwaway update key in
  `INSTALL_UPDATE_KEY`, never a release's keys.
- `release.py DIR VERSION RELEASED BINARY...` writes a signed release folder
  for `leita update` (`LEITA_RELEASE_BASE=DIR`). The folder is signed with
  `INSTALL_UPDATE_SEED`, a seed the workflow makes for each run.
- `story KIND OLD NEW UP DOWN` runs one artefact's life on the machine it is
  run on. It installs the previous build, runs both programs, scans a folder,
  writes reports, adds the test licence, keeps a watched place and starts the
  recorder. It then upgrades and checks that nothing is lost. It downgrades
  and upgrades again, and it uninstalls and checks that nothing is left
  behind. Each check prints a `STORY` line.
- `linux OLD NEW [GUEST...]` runs the story for every Linux artefact. Each
  guest is a stock container image pinned by digest.

`linux` refuses a `:systemd` guest unless `CI=true` or `GITHUB_ACTIONS=true`
is set. Such a guest boots systemd in a privileged container, and that
container sees the host's `/dev`. On a desktop it took the host's terminals
and ended the session, so do not run one there. A plain guest needs only
docker.

## What a hosted runner cannot prove

- **Signing.** No build here is signed with a release identity. The Windows
  zip's `leita.exe` and `Leita.exe` are unsigned, and `Leita.app` is signed
  ad hoc. `release.yml` signs, notarises and staples them only on a real
  release with the secrets present.
- **Gatekeeper and notarisation.** The dmg is attached and `Leita.app` is
  copied with `ditto`, so no quarantine attribute is set and Gatekeeper never
  assesses the app. A notarised, stapled app that a person downloads in a
  browser is not exercised.
- **SmartScreen and Mark of the Web.** The zip is extracted with no
  Zone.Identifier, so SmartScreen never prompts. An unsigned or new-reputation
  binary downloaded by a browser would be stopped at first launch.
- **The universal macOS binary.** The dmg holds the runner's arm64 slice. The
  lipo in `release.yml`'s universal job is not exercised, and nor is Intel.
- **Linux arm64.** Only amd64 artefacts are installed.
- **The previous Windows build's C libraries.** jm's Windows recipes for
  SQLite, zstd, kb_text_shape and Blend2D are PowerShell, which `just` runs
  under sh. The previous build therefore links the libraries the setup action
  built for this checkout's jm. Its Odin code is the old commit's own.
- **The Windows installer.** Only the zip is upgraded here. `release.yml`
  installs and uninstalls `setup.exe` on its runner but does not upgrade it.
- **A desktop session.** The containers have no display, and the window runs
  only as the command line (`Leita --version`, `Leita update`). The desktop
  entry, the icon and AppImage desktop integration are not opened. The
  AppImage runs with `APPIMAGE_EXTRACT_AND_RUN`, because a container has no
  FUSE.
- **The recorder in a VM.** The recorder runs under systemd in a privileged
  container on the runner's kernel, not on a booted distribution kernel.
