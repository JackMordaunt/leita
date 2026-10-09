# Standard recipes: build (debug), release, clean, test, install.
#
#   just build      debug build with AddressSanitizer   -> build/debug/estoile
#   just release    optimised build                     -> build/release/estoile
#   just test       run every imported package's tests under ASan -> build/test/
#   just check      type-check both modes without producing a binary
#   just clean      remove build/
#   just deps       fetch the jm submodule and the native libraries the window links
#   just gui [dir]  open the window on a directory, the home directory by default
#   just hot [dir]  the same, the view reloaded in place on every edit
#   just gui-test   run the window's tests, the host's on a real directory
#
# The debug allocator, flow, sqlite3, stream and ui come from the jm collection, pinned as
# the jm submodule (https://mordaunt.dev/code/jm); JM=<path> builds against another
# checkout instead.
#
# Debug and test builds carry -sanitize:address. The debug allocator poisons its
# guard bytes and freed blocks, so instrumented reads past the end or after free
# trap at the faulting instruction. Pass SAN= to build without it:
# `SAN= just build`. Odin does not create output directories, hence the mkdir.

odin  := env("ODIN", "odin")
root  := justfile_directory()
jm    := env("JM", root / "jm")
flags := "-vet -strict-style -collection:jm=" + jm
san   := env("SAN", "-sanitize:address")
exe   := if os() == "windows" { ".exe" } else { "" }
bin   := "estoile"
# The window is Estoile and builds into app/ beside the CLI: macOS and Windows
# fold case by default, so estoile and Estoile in one directory are one file.
gui   := "Estoile"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Debug build with AddressSanitizer -> build/debug/estoile
build:
    mkdir -p build/debug
    {{odin}} build . -debug {{san}} {{flags}} -out:build/debug/{{bin}}{{exe}}

# Optimised build -> build/release/estoile
release:
    mkdir -p build/release
    {{odin}} build . -o:speed {{flags}} -out:build/release/{{bin}}{{exe}}

# Run the tests of every package the binary imports under ASan -> build/test/
test:
    mkdir -p build/test
    {{odin}} test . -all-packages -debug {{san}} {{flags}} -out:build/test/{{bin}}{{exe}}

# Type-check both modes without producing a binary.
check:
    {{odin}} check . {{flags}}
    {{odin}} check . -debug {{flags}}

# The jm submodule, when JM does not name another checkout, and the libraries
# jm:ui links: Blend2D to draw, kb_text_shape to shape text, AccessKit for screen
# readers; and SQLite, which keeps the window's scans. Each is built or fetched by
# jm's own recipe, once.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    cd "{{jm}}"
    ls ui/blend2d/lib/*blend2d* >/dev/null 2>&1 || just blend2d
    ls ui/kb/lib/kb_text_shape.* >/dev/null 2>&1 || just kb
    ls ui/accesskit/lib/*accesskit* >/dev/null 2>&1 || just accesskit
    ls sqlite3/lib/sqlite3.* >/dev/null 2>&1 || just sqlite
    just sdl3

# Build the window and open it on a directory, the home directory by default
gui *args: gui-build
    build/debug/app/{{gui}}{{exe}} {{args}}

# Debug build of the window -> build/debug/app/Estoile
gui-build: deps
    mkdir -p build/debug/app
    {{odin}} build gui -debug {{san}} {{flags}} -out:build/debug/app/{{gui}}{{exe}}

# The window with its view hot-reloaded. The host (gui/host) owns the window and
# the scan; the view runs as gui/child in a subprocess, rebuilt here whenever an
# .odin file it is made of changes, into its own timestamped binary under
# build/hot, named in build/hot/view.watch, which the host re-reads and respawns
# from (ui/shell.run_host). The scan keeps running across reloads; a change to
# the scan or the pipeline (gui/app, survey, scan, walk, ntfs) needs the recipe
# run again. A shell loop rather than jm's tools/hot-watch, which passes its own
# checkout as the jm collection. stat is GNU's -c or BSD's -f, whichever runs.
#
# Open the window, reloading the view on every edit: just hot [dir]
hot *args: deps
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/debug/app build/hot
    {{odin}} build gui/host -debug {{san}} {{flags}} -out:build/debug/app/{{gui}}-host{{exe}}
    rm -f build/hot/view.watch
    (
      last=""
      n=0
      while true; do
        srcs=(gui/child/*.odin gui/view/*.odin gui/query/*.odin gui/command/*.odin human/*.odin)
        mt=$({ stat -c %Y "${srcs[@]}" 2>/dev/null || stat -f %m "${srcs[@]}"; } | sort -n | tail -1)
        if [ "$mt" != "$last" ]; then
          last=$mt
          n=$((n + 1))
          out=build/hot/view-$(date +%s)-${n}{{exe}}
          if {{odin}} build gui/child -debug {{san}} {{flags}} -out:"$out"; then
            printf '%s' "$out" > build/hot/view.watch
            echo "hot: view ready $out"
            ls -t build/hot/view-* | tail -n +3 | xargs -r rm -f
          else
            echo "hot: build failed; the window keeps the last good view"
          fi
        fi
        sleep 0.4
      done
    ) &
    watcher=$!
    trap 'kill $watcher 2>/dev/null' EXIT
    while [ ! -f build/hot/view.watch ]; do sleep 0.2; done
    build/debug/app/{{gui}}-host{{exe}} build/hot/view.watch {{args}}

# Optimised build of the window -> build/release/app/Estoile
gui-release: deps
    mkdir -p build/release/app
    {{odin}} build gui -o:speed {{flags}} -out:build/release/app/{{gui}}{{exe}}

# The view in a probe over the host on a real directory, the view's own suite,
# and the platform package's. Not -all-packages, which would run every jm:ui
# suite the window imports too.
#
# Run the window's suites under ASan
gui-test: deps
    mkdir -p build/test/app
    {{odin}} test gui/app -debug {{san}} {{flags}} -out:build/test/app/{{gui}}{{exe}}
    {{odin}} test gui/files -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-files{{exe}}
    {{odin}} test gui/view -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-view{{exe}}
    {{odin}} test reclaim -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-reclaim{{exe}}
    {{odin}} test gui/history -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-history{{exe}}

# Remove build/.
clean:
    rm -rf build

# Copy the release binary to a directory on PATH. An installed copy is replaced in
# place; otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin, /usr/local/bin, else the
# first writable PATH entry.
install: release
    #!/usr/bin/env bash
    set -euo pipefail
    dest=""
    if existing=$(command -v {{bin}} 2>/dev/null) && [[ -w ${existing%/*} ]]; then
        dest=${existing%/*}
    fi
    gopath=$(go env GOPATH 2>/dev/null || true); gobin=$(go env GOBIN 2>/dev/null || true)
    for d in "$HOME/.local/bin" "$HOME/bin" "$gobin" "${gopath:+$gopath/bin}" /usr/local/bin; do
        [[ -z $dest && -n $d && -d $d && -w $d && ":$PATH:" == *":$d:"* ]] && dest=$d
    done
    if [[ -z $dest ]]; then
        IFS=: read -ra dirs <<<"$PATH"
        for d in "${dirs[@]}"; do [[ -d $d && -w $d ]] && { dest=$d; break; }; done
    fi
    [[ -n $dest ]] || { echo "install: no writable directory on PATH" >&2; exit 1; }
    install -m 755 build/release/{{bin}}{{exe}} "$dest/{{bin}}"
    echo "installed $dest/{{bin}}"
