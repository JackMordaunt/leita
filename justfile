# Standard recipes: build, run, clean, test, install.
#
#   just build [release]      the command line and the window, debug with ASan by
#                             default, release optimised
#   just cli [release]        the command line alone -> build/<mode>/leita
#   just gui [release]        the window alone -> build/<mode>/app/Leita
#   just bundle [window cli]  Leita.app from the release window and command line,
#                             macOS only -> build/release/Leita.app
#   just run [release] [dir]  build the window, then open it on a directory, the
#                             home directory by default
#   just test                 run every imported package's tests under ASan -> build/test/
#   just fuzz [args]          leita-fuzz, fixed seed and case budget, under ASan
#   just fuzz-isolate [args]  the same, one child process per case
#   just btrfs-test [--sudo]  the btrfs and walk tests on a throw-away btrfs image,
#                             as root too with --sudo where sudo asks no password
#   just mount-test [--sudo]  the delete test that mounts, in a namespace of its own
#   just fsbench-ci [--update] the walk on a seeded tmpfs, against the baseline
#   just install              put the release command line on PATH as leita and le
#   just check                type-check both modes without producing a binary
#   just check-licence [key licence]
#                             test that a build with key takes a licence its private
#                             half signed; the test key and its licence by default
#   just clean                remove build/
#   just deps                 fetch the jm submodule and the native libraries the window links
#   just sqlite               fetch the jm submodule and build SQLite, all the command line links
#   just hot [dir]            run's debug window without the sanitizer, the view reloaded
#                             in place on every edit
#   just gui-test             run the window's tests, the host's on a real directory
#   just package              Linux: the release as an AppImage, a .deb and an .rpm
#                             -> build/package/
#
# The debug allocator, flow, sqlite3, stream and ui come from the jm collection, pinned as
# the jm submodule (https://mordaunt.dev/code/jm); JM=<path> builds against another
# checkout instead.
#
# A release checks licences against the public key in LEITA_LICENCE_KEY, 64 hex
# characters, which only the release build is given: just cli release and just
# gui release refuse to build without it, since a release without a key takes no
# licence. Debug and test builds take none.
#
# Debug and test builds carry -sanitize:address. The debug allocator poisons its
# guard bytes and freed blocks, so instrumented reads past the end or after free
# trap at the faulting instruction. Pass SAN= to build without it:
# `SAN= just build`. The hot-reload window alone builds without it, hot_opt
# below. Odin does not create output directories, hence the mkdir.

odin  := env("ODIN", "odin")
# Forward slashes throughout: justfile_directory() on Windows returns
# backslashes, and passing those mixed with the "/" below straight to a
# native exe (odin.exe is not an MSYS program) through Git Bash corrupts
# the path, as jm's own justfile already normalises root for the same
# reason.
root  := replace(justfile_directory(), "\\", "/")
jm    := env("JM", root / "jm")
# Which leita a build is, the one place either binary learns it: the tag
# described, or a bare commit as git describe names one, g and its hash, so Odin
# never reads it as a number; dev without git. LEITA_VERSION=<v> sets it instead.
version := env("LEITA_VERSION", `git describe --tags --dirty 2>/dev/null || { h=$(git describe --always --dirty 2>/dev/null) && echo "g$h"; } || echo dev`)
# The year of this build, for the copyright line. LEITA_YEAR=<n> sets it.
year := env("LEITA_YEAR", `date +%Y`)
# check_flags is what odin check takes; flags adds the macOS minimum, which
# only build, run and test accept.
check_flags := "-vet -strict-style -collection:jm=" + jm + " -define:LEITA_VERSION=" + version + " -define:LEITA_SHORT=" + short + " -define:LEITA_YEAR=" + year
flags := check_flags + minos
# macOS 11.0 is the oldest Odin targets, and jm builds its native libraries
# for it. Without the flag a binary carries the building Mac's own version as
# its minimum, and an older Mac refuses to start it.
minos := if os() == "macos" { " -minimum-os-version:11.0" } else { "" }
san   := env("SAN", "-sanitize:address")
# Linux opens libcurl when a licence key is first sent or an update asked for,
# not at start-up (jm:http/libcurl): Ubuntu's desktop may carry only the GnuTLS
# build, or none, and the window and the command line must start either way; a
# system without it is told so by the one request that needs it. macOS links
# its own; Windows ships libcurl inside vendor:curl. Both binaries import
# jm:http, the window for the licence and both for leita update.
curl_open := if os() == "linux" { " -define:JM_HTTP_DLOPEN=true" } else { "" }
# What just hot builds the host and the view with, instead of -debug {{san}}:
# the loop is for editing the view, and every edit waits on a child build, so
# the profile buys frame time only where it costs no compile time. No ASan: a
# frame in the view costs 5.5x release with it, 2.3x without (measured
# 2026-10-16, scanning ~/Source); just gui, just test and just gui-test keep
# it. -o:minimal: the frame median goes from 28 ms to 17 ms and the child
# build from 0.97 s to 1.02 s; -o:speed reaches 8 ms but builds in 15 s. No
# allocation backtraces: the debug allocator captures a call chain at every
# allocation, and the scan's workers allocate enough that the scan keeps in
# 1.6 s instead of 2.6 s without them. A leak or issue report still names
# the allocating file, line and proc; it loses the call chain under them,
# so a leak hunt is a job for just gui.
hot_opt := "-debug -o:minimal -define:DEBUG_ALLOC_BACKTRACES=false"
exe   := if os() == "windows" { ".exe" } else { "" }
bin   := "leita"
# The short name install puts beside leita, the same command in two letters, as
# fd and rg are. Debian and Homebrew carry an old editor called le; it is rare
# enough that leita takes the name. The build hands it to version.SHORT, so a
# change here fails just test until -h names the new one.
short := "le"
# The window is Leita and builds into app/ beside the CLI: macOS and Windows
# fold case by default, so leita and Leita in one directory are one file.
gui   := "Leita"
# What links jm:ui/shell on macOS: the static SDL3 jm's sdl3 recipe builds, so
# the window starts on a Mac without Homebrew, and the frameworks a static
# SDL3 needs, the Libs line of the sdl3.pc that build writes. vendor:sdl3 asks
# for -lSDL3, and Odin puts -L/opt/homebrew/lib ahead of any -L given here, so
# ld would take a Homebrew dylib where one is installed: the archive is loaded
# whole by path instead, and the dylib, then unused, dropped. Linux links the
# static SDL3 deps builds into the same directory (sdl3-static), so a stock
# Ubuntu, which packages no SDL3, starts the window: ld takes libSDL3.a from
# the first -L directory holding a libSDL3, before the system's own. Every
# backend SDL3 has on Linux, X11, Wayland and the sound servers among them,
# is opened at run time, so the archive needs nothing more on the line.
# Windows loads the DLL and adds nothing.
sdl3_dir  := jm / "ui/shell/lib"
sdl3_link := if os() == "linux" { "-extra-linker-flags:\"-L" + sdl3_dir + "\"" } else if os() == "macos" { "-extra-linker-flags:\"-L" + sdl3_dir + " -Wl,-force_load," + sdl3_dir + "/libSDL3.a -Wl,-dead_strip_dylibs" + \
    " -framework CoreMedia -framework CoreVideo -framework Cocoa -Wl,-weak_framework,UniformTypeIdentifiers" + \
    " -framework IOKit -framework ForceFeedback -framework Carbon -framework CoreAudio -framework AudioToolbox" + \
    " -framework AVFoundation -framework Foundation -framework GameController -framework Metal -framework QuartzCore" + \
    " -Wl,-weak_framework,CoreHaptics\"" } else { "" }

# A key and a licence it signed, for tests and CI alone. Its private half was
# thrown away once it had signed test_licence, so no one can sign another: a
# build with it takes this licence and no other. Never a release's key.
test_licence_key := "e83dc875975880f373348c2eccbf6b5c719736abf15727e77f3968c0c6644553"
test_licence     := "leita1.eyJsaWNlbnNlZSI6ICJMZWl0YSB0ZXN0IGtleSIsICJ0aWVyIjogInN1cHBvcnRlciIsICJvcmRlciI6ICJ0ZXN0IiwgImlzc3VlZCI6ICIyMDI2LTEwLTE3In0=.LbCdZ5rVE+RbchkATmwkKC0DGIo8Sp6MK+n4KnIM9ACXFZDBF0Q3N1kHeQUW6kIhLSTwFgpP0rC9qL5bh7XiBg=="

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Build the command line and the window: just build [release]
build mode="debug": (cli mode) (gui mode)

# The command line, debug with AddressSanitizer or release optimised.
#
# Build the command line -> build/<mode>/leita: just cli [release]
cli mode="debug": sqlite
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
    debug) opt="-debug {{san}}" ;;
    release) opt="-o:speed -define:LEITA_LICENCE_KEY=$(just --justfile "{{justfile()}}" release-key)" ;;
    *) echo "cli: the mode is debug or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}
    {{odin}} build . $opt {{flags}} {{curl_open}} -out:build/{{mode}}/{{bin}}{{exe}}

# The window, debug with AddressSanitizer or release optimised.
#
# Build the window -> build/<mode>/app/Leita: just gui [release]
gui mode="debug": deps
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
    debug) opt="-debug {{san}}" ;;
    release) opt="-o:speed -define:LEITA_LICENCE_KEY=$(just --justfile "{{justfile()}}" release-key)" ;;
    *) echo "gui: the mode is debug or release, not {{mode}}" >&2; exit 1 ;;
    esac
    # A release window on Windows is a GUI program, so starting it opens no
    # console behind it; a debug one keeps its console, where printing goes.
    if [ "{{os()}}" = windows ] && [ "{{mode}}" = release ]; then opt="$opt -subsystem:windows"; fi
    mkdir -p build/{{mode}}/app
    {{odin}} build gui $opt {{flags}} {{curl_open}} {{sdl3_link}} -out:build/{{mode}}/app/{{gui}}{{exe}}
    if [ "{{os()}}" = windows ]; then
        # The window does not start without either DLL beside it, so a build
        # that lacks one stops here rather than shipping a window that cannot run.
        for dll in "$({{odin}} root)/vendor/sdl3/SDL3.dll" "{{jm}}/ui/accesskit/lib/accesskit.dll"; do
            [ -f "$dll" ] || { echo "gui: $dll is missing, and the window does not start without it" >&2; exit 1; }
            cp "$dll" build/{{mode}}/app/
        done
    fi

# Leita.app, the window as a Mac installs it, from the release window and
# command line, built here when neither is given: the window as
# Contents/MacOS/Leita, the command line as Contents/Helpers/leita, beside the
# Info.plist tools/macos/Info.plist.in fills and the icon branding/icon.png
# makes. The command line is not in MacOS/ beside the window, since a Mac folds
# case by default and leita and Leita there would be one file; Helpers/ is
# where a bundle keeps a tool of its own, and a Terminal user links to it.
# Apple takes a version of up to three numbers, so v1.2.0-rc1 is 1.2.0 and a
# bare commit, g and its hash, is 0.0.0. iconutil and sips are Apple's, so
# another host says so and does nothing. Unsigned: release.yml signs it.
#
# Build Leita.app -> build/release/Leita.app: just bundle [window cli]
bundle window="" cli="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{os()}}" != macos ]; then echo "bundle: skipped: Leita.app is built on macOS, with Apple's iconutil and sips"; exit 0; fi
    window='{{window}}'
    cli='{{cli}}'
    if [ -z "$window" ] && [ -z "$cli" ]; then
        just --justfile "{{justfile()}}" build release
        window=build/release/app/{{gui}}
        cli=build/release/{{bin}}
    fi
    if [ -z "$window" ] || [ -z "$cli" ]; then
        echo "bundle: give both the window and the command line, or neither" >&2
        exit 1
    fi
    v='{{version}}'
    v=${v#v}
    number=0.0.0
    if [[ $v =~ ^[0-9]+(\.[0-9]+){0,2} ]]; then number=${BASH_REMATCH[0]}; fi
    app=build/release/{{gui}}.app
    rm -rf "$app" build/release/{{gui}}.iconset
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" build/release/{{gui}}.iconset
    install -m 755 "$window" "$app/Contents/MacOS/{{gui}}"
    install -m 755 "$cli" "$app/Contents/Helpers/{{bin}}"
    sed -e "s/@VERSION@/$number/g" -e 's/@YEAR@/{{year}}/g' tools/macos/Info.plist.in > "$app/Contents/Info.plist"
    plutil -lint "$app/Contents/Info.plist"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    for size in 16 32 128 256 512; do
        sips -z $size $size branding/icon.png --out "build/release/{{gui}}.iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) branding/icon.png --out "build/release/{{gui}}.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns build/release/{{gui}}.iconset -o "$app/Contents/Resources/{{gui}}.icns"
    # The licence and the third-party notices travel with the app, sealed by
    # the signature like the rest of Resources/.
    install -m 644 LICENSE.md THIRD_PARTY.md "$app/Contents/Resources/"
    rm -rf build/release/{{gui}}.iconset
    echo "bundle: $app, version $number"

# The licence public key a release is built with, from LEITA_LICENCE_KEY: it
# fails, saying why, when the key is unset or not 64 hex characters.
[private]
release-key:
    #!/usr/bin/env bash
    set -euo pipefail
    key="${LEITA_LICENCE_KEY:-}"
    if ! [[ $key =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "release: LEITA_LICENCE_KEY must be the licence public key, 64 hex characters; a release without it takes no licence" >&2
        exit 1
    fi
    printf '%s' "$key"

# A first argument of release builds and runs the release build.
#
# Build the window, then open it on a directory: just run [release] [dir]
[positional-arguments]
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    mode=debug
    if [ "${1:-}" = release ] || [ "${1:-}" = debug ]; then mode=$1; shift; fi
    just --justfile "{{justfile()}}" gui "$mode"
    exec build/$mode/app/{{gui}}{{exe}} "$@"

# Run the tests of every package the binary imports, pdf among them, under ASan
# -> build/test/. The command line does not import gui/notices, so that test is
# run on its own: it is what keeps THIRD_PARTY.md equal to the window's list.
test: sqlite
    mkdir -p build/test
    {{odin}} test . -all-packages -debug {{san}} {{flags}} {{curl_open}} -out:build/test/{{bin}}{{exe}}
    {{odin}} test gui/notices -debug {{san}} {{flags}} -out:build/test/notices{{exe}}
    # Fuzz packages are not imported by the command line, so -all-packages
    # never sees them. These are the short fixed-seed replays; just fuzz is
    # the longer budget. test.yml stays as it is and still runs this recipe.
    {{odin}} test btrfs/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-btrfs{{exe}}
    {{odin}} test history/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-history{{exe}}
    {{odin}} test ntfs/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-ntfs{{exe}}
    {{odin}} test search/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-search{{exe}}

# Parser properties under ASan. args replace the budget, they do not add to
# it: just fuzz "-seed=1 -iters=64 -for=2m". The corpus beside each suite is
# replayed first. No device and no root filesystem: the inputs are the
# committed seeds and bytes the suite draws.
fuzz args="-seed=1 -iters=64 -for=2m": sqlite
    mkdir -p build/debug
    {{odin}} build tools/leita-fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/debug/leita-fuzz{{exe}}
    build/debug/leita-fuzz{{exe}} {{args}}

# A child process per case, so a crash or a hang is a report.
fuzz-isolate args="-seed=1 -iters=16 -for=2m": sqlite
    mkdir -p build/debug
    {{odin}} build tools/leita-fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/debug/leita-fuzz{{exe}}
    build/debug/leita-fuzz{{exe}} -isolate {{args}}

# The btrfs and walk tests on a btrfs image made, mounted and filled for them,
# against a total worked out from the image; skipped where nothing can mount one.
# --sudo lets it mount with sudo and test as root too, where sudo asks no password,
# as CI does. See tools/btrfs-fixture: just btrfs-test [--sudo] [--keep]
btrfs-test *args: sqlite
    tools/btrfs-fixture --odin "{{odin}}" --flags "{{san}} {{flags}}" {{args}}

# The licence package's tests built with key, as a release is, and licence, one
# its private half signed, checked against it: the test key and its licence when
# neither is given. Any other key needs a licence it signed.
#
# Test that a build with a key takes what it signed: just check-licence [key licence]
check-licence key=test_licence_key licence="": sqlite
    #!/usr/bin/env bash
    set -euo pipefail
    licence='{{licence}}'
    if [ -z "$licence" ] && [ '{{key}}' = '{{test_licence_key}}' ]; then licence='{{test_licence}}'; fi
    if [ -z "$licence" ]; then
        echo "check-licence: give a licence the key signed: just check-licence KEY LICENCE" >&2
        exit 1
    fi
    mkdir -p build/test
    {{odin}} test licence -debug {{san}} {{flags}} '-define:LEITA_LICENCE_KEY={{key}}' "-define:LEITA_LICENCE_SAMPLE=$licence" -out:build/test/licence{{exe}}

# The tests that mount: a delete with a tmpfs and a bind inside the tree being
# deleted, and walks over binds of a directory above them and beside them. Each
# runs in a user and mount namespace of its own (unshare -rm), which needs no root
# and leaves nothing mounted; --sudo runs them as root instead, where sudo asks no
# password. Skipped where neither can mount. Linux only: just mount-test [--sudo]
mount-test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{os()}}" != linux ]; then echo "mount-test: skipped: the mounts are Linux's"; exit 0; fi
    mkdir -p build/test
    {{odin}} build gui/files -build-mode:test -debug {{san}} {{flags}} \
        -define:ODIN_TEST_NAMES=leita_files.a_delete_never_crosses_a_mount -out:build/test/mount-test
    {{odin}} build walk -build-mode:test -debug {{san}} {{flags}} \
        -define:ODIN_TEST_NAMES=walk.test_a_bind_of_an_ancestor_is_a_mount,walk.test_a_bind_of_a_walked_tree_is_counted_once -out:build/test/walk-mount-test
    tests=(build/test/mount-test build/test/walk-mount-test)
    if [ "{{args}}" = --sudo ]; then
        for test in "${tests[@]}"; do sudo -n env LEITA_MOUNT_TEST=1 "$test"; done
        exit 0
    elif unshare --user --map-root-user --mount true 2>/dev/null; then
        for test in "${tests[@]}"; do LEITA_MOUNT_TEST=1 unshare --user --map-root-user --mount "$test"; done
        exit 0
    fi
    echo "mount-test: skipped: no user namespaces here; give --sudo where sudo asks no password"

# Type-check both modes without producing a binary. gui/notices is separate:
# the command line does not import it, and its test is what renders
# THIRD_PARTY.md.
check:
    {{odin}} check . {{check_flags}}
    {{odin}} check . -debug {{check_flags}}
    {{odin}} check gui/notices -no-entry-point {{check_flags}}

# The jm submodule, when JM does not name another checkout, SQLite, which keeps
# both binaries' scans, and zstd, which decodes the patches leita update applies:
# all the command line links that is not Odin or the system's libcurl. Built by
# jm's own recipes, once.
sqlite:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    cd "{{jm}}"
    ls sqlite3/lib/sqlite3.* >/dev/null 2>&1 || just sqlite
    ls zstd/lib/zstd.* >/dev/null 2>&1 || just zstd

# What sqlite fetches, and the libraries jm:ui links: Blend2D to draw,
# kb_text_shape to shape text, AccessKit for screen readers, and on macOS and
# Linux SDL3 itself. Each is built or fetched by jm's own recipe, once, but
# Linux's SDL3, which sdl3-static builds here.
deps: sqlite
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{jm}}"
    ls ui/blend2d/lib/*blend2d* >/dev/null 2>&1 || just blend2d
    ls ui/kb/lib/kb_text_shape.* >/dev/null 2>&1 || just kb
    ls ui/accesskit/lib/*accesskit* >/dev/null 2>&1 || just accesskit
    just sdl3
    if [ "{{os()}}" = linux ]; then just --justfile "{{justfile()}}" sdl3-static; fi

# jm builds SDL3 static for macOS alone and leaves Linux to a system SDL3,
# which Ubuntu does not package; this is its macOS build, at the same pinned
# commit, for Linux, into the directory sdl3_link names. Position-independent,
# since Odin links a PIE. SDL3 finds X11, Wayland, libdecor, PipeWire,
# PulseAudio and ALSA at configure time and opens them at run time, so the
# machine that builds it needs their headers (CI installs them; see the setup
# action) and the one that runs it needs none of them but its desktop's own.
[private]
[linux]
sdl3-static:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{jm}}"
    [ -f ui/shell/lib/libSDL3.a ] && exit 0
    rev=$(just --evaluate sdl3_rev)
    just fetch build/src/sdl3 https://github.com/libsdl-org/SDL "$rev"
    echo "cmake sdl3 (static) -> ui/shell/lib/libSDL3.a"
    mkdir -p ui/shell/lib build
    cmake --fresh -S build/src/sdl3 -B build/sdl3-static -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON > build/sdl3-static.log 2>&1 \
        || { tail -n 30 build/sdl3-static.log >&2; exit 1; }
    cmake --build build/sdl3-static --parallel >> build/sdl3-static.log 2>&1 \
        || { tail -n 30 build/sdl3-static.log >&2; exit 1; }
    cp build/sdl3-static/libSDL3.a build/sdl3-static/sdl3.pc ui/shell/lib/

# The window with its view hot-reloaded. The host (gui/host) owns the window and
# the scan; the view runs as gui/child in a subprocess, rebuilt here whenever an
# .odin file it is made of changes, into its own timestamped binary under
# build/hot, named in build/hot/view.watch, which the host re-reads and respawns
# from (ui/shell.run_host). The scan keeps running across reloads; a change to
# the scan or the pipeline (gui/app, survey, scan, walk, ntfs) needs the recipe
# run again. A shell loop rather than jm's tools/hot-watch, which passes its own
# checkout as the jm collection. stat is GNU's -c or BSD's -f, whichever runs.
# Both builds take hot_opt, the sanitizer-free profile, not -debug {{san}}.
#
# Open the window, reloading the view on every edit: just hot [dir]
hot *args: deps
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/debug/app build/hot
    {{odin}} build gui/host {{hot_opt}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/debug/app/{{gui}}-host{{exe}}
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
          if {{odin}} build gui/child {{hot_opt}} {{flags}} -out:"$out"; then
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

# Leita's own suite (which arguments open the window and which run leita), the
# view in a probe over the host on a real directory, the view's own suite,
# the messages' (every language has every message), the platform package's, and
# those of the packages only the window imports, search among them. Not -all-packages, which would run every jm:ui
# suite the window imports too.
#
# Run the window's suites under ASan
gui-test: deps
    mkdir -p build/test/app
    {{odin}} test gui -debug {{san}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/test/app/{{gui}}-main{{exe}}
    {{odin}} test gui/app -debug {{san}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/test/app/{{gui}}{{exe}}
    {{odin}} test gui/files -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-files{{exe}}
    {{odin}} test gui/view -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-view{{exe}}
    {{odin}} test gui/msg -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-msg{{exe}}
    {{odin}} test reclaim -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-reclaim{{exe}}
    {{odin}} test history -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-history{{exe}}
    {{odin}} test settings -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-settings{{exe}}
    {{odin}} test licence -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-licence{{exe}}
    {{odin}} test search -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-search{{exe}}

# The tools package fetches into build/tools, each pinned by its SHA-256 for
# both architectures a release builds Linux on: nfpm builds the .deb and the
# .rpm (the sums are those of nfpm's checksums.txt); appimagetool builds the
# AppImage onto the type2 runtime pinned beside it, which it would otherwise
# fetch, unpinned, itself.
nfpm_ver           := "2.47.0"
nfpm_sha_x86_64    := "0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783"
nfpm_sha_aarch64   := "1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c"
appimagetool_ver   := "1.9.1"
appimagetool_sha_x86_64  := "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
appimagetool_sha_aarch64 := "f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
runtime_ver        := "20251108"
runtime_sha_x86_64  := "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
runtime_sha_aarch64 := "00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444"

# The release build as Linux packages, for this machine's architecture, named
# as release.yml publishes them: an AppImage of the window, which runs from the
# one file, and a .deb and an .rpm of both binaries, the desktop entry, the
# icon, the AppStream metadata and the recorder's unit (packaging/linux). The
# packages require the glibc the binaries were linked against, read from them;
# a build on a newer system than the one it is for makes packages that system
# refuses, rather than binaries that fail to start.
#
# Build the AppImage, .deb and .rpm -> build/package/: just package
[linux]
package: (build "release") package-built

# package's work on the release build already there, which release.yml calls
# after its own build, so the packages carry the very binaries it publishes.
[private]
[linux]
package-built:
    #!/usr/bin/env bash
    set -euo pipefail
    m=$(uname -m)
    case "$m" in
    x86_64) arch=amd64 nfpm_sha={{nfpm_sha_x86_64}} tool_sha={{appimagetool_sha_x86_64}} runtime_sha={{runtime_sha_x86_64}} nfpm_m=x86_64 ;;
    aarch64) arch=arm64 nfpm_sha={{nfpm_sha_aarch64}} tool_sha={{appimagetool_sha_aarch64}} runtime_sha={{runtime_sha_aarch64}} nfpm_m=arm64 ;;
    *) echo "package: no tools are pinned for $m" >&2; exit 1 ;;
    esac
    tools=build/tools
    mkdir -p "$tools"
    # fetch URL FILE SHA256: FILE, downloaded unless it is there with that sum.
    fetch() {
        if [ -f "$2" ] && echo "$3  $2" | sha256sum -c --status; then return; fi
        curl -sSfL --max-time 300 -o "$2.part" "$1"
        if ! echo "$3  $2.part" | sha256sum -c --status; then
            echo "package: $1 is not the build pinned at $3" >&2
            rm -f "$2.part"
            exit 1
        fi
        mv "$2.part" "$2"
    }
    fetch "https://github.com/goreleaser/nfpm/releases/download/v{{nfpm_ver}}/nfpm_{{nfpm_ver}}_Linux_$nfpm_m.tar.gz" "$tools/nfpm-{{nfpm_ver}}-$m.tar.gz" "$nfpm_sha"
    fetch "https://github.com/AppImage/appimagetool/releases/download/{{appimagetool_ver}}/appimagetool-$m.AppImage" "$tools/appimagetool-{{appimagetool_ver}}-$m" "$tool_sha"
    fetch "https://github.com/AppImage/type2-runtime/releases/download/{{runtime_ver}}/runtime-$m" "$tools/runtime-{{runtime_ver}}-$m" "$runtime_sha"
    tar -xzf "$tools/nfpm-{{nfpm_ver}}-$m.tar.gz" -C "$tools" nfpm
    chmod +x "$tools/appimagetool-{{appimagetool_ver}}-$m"

    # The version as dpkg and rpm both order it: v1.2.0 is 1.2.0, a
    # pre-release's dash a tilde so v1.2.0-rc1 sorts before 1.2.0, and a
    # build from no tag 0.0.0~ and its name, dots for its dashes.
    v="{{version}}"
    case "$v" in
    v[0-9]*) v=${v#v}; head=${v%%-*}; rest=${v#"$head"}; rest=${rest#-}; pkgver=$head${rest:+~${rest//-/.}} ;;
    *) pkgver="0.0.0~${v//-/.}" ;;
    esac
    glibc=$(objdump -T build/release/leita build/release/app/Leita | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
    out=build/package
    rm -rf "$out"
    mkdir -p "$out"
    name="leita-{{version}}-linux-$arch"
    export LEITA_PKGVER=$pkgver LEITA_ARCH=$arch LEITA_GLIBC=${glibc#GLIBC_}
    SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || date +%s)
    export SOURCE_DATE_EPOCH
    for format in deb rpm; do
        "$tools/nfpm" package --config packaging/linux/nfpm.yaml --packager "$format" --target "$out/$name.$format"
    done

    # The AppImage's tree: the window as AppRun, and the desktop entry and
    # icon at the top, where appimagetool and the desktop's AppImage
    # integration look. APPIMAGE_EXTRACT_AND_RUN runs appimagetool without
    # FUSE, which a CI runner lacks.
    app="$out/AppDir"
    mkdir -p "$app/usr/bin" "$app/usr/share/metainfo" "$app/usr/share/icons/hicolor/scalable/apps"
    install -m 755 build/release/app/{{gui}} "$app/usr/bin/{{gui}}"
    ln -s usr/bin/{{gui}} "$app/AppRun"
    cp packaging/linux/dev.mordaunt.Leita.desktop "$app/"
    cp branding/mark-light.svg "$app/dev.mordaunt.Leita.svg"
    install -d "$app/usr/share/doc/leita"
    install -m 644 LICENSE.md THIRD_PARTY.md "$app/usr/share/doc/leita/"
    cp branding/mark-light.svg "$app/usr/share/icons/hicolor/scalable/apps/dev.mordaunt.Leita.svg"
    cp packaging/linux/dev.mordaunt.Leita.metainfo.xml "$app/usr/share/metainfo/"
    ARCH=$m APPIMAGE_EXTRACT_AND_RUN=1 "$tools/appimagetool-{{appimagetool_ver}}-$m" --no-appstream \
        --runtime-file "$tools/runtime-{{runtime_ver}}-$m" "$app" "$out/$name.AppImage"
    rm -rf "$app"
    ls -l "$out"

# Remove build/.
clean:
    rm -rf build

# Copy the release binary to a directory on PATH, with the short name beside it:
# a symlink to leita on Unix, a second copy on Windows, where a symlink needs
# administrator rights or developer mode. An installed copy is replaced in place;
# otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin, /usr/local/bin, else the first
# writable PATH entry.
install: (cli "release")
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
    if [[ "{{os()}}" == windows ]]; then
        install -m 755 build/release/{{bin}}{{exe}} "$dest/{{short}}"
    else
        ln -sf {{bin}} "$dest/{{short}}"
    fi
    # jm is Apache-2.0, and the other notices ask to travel with the binary.
    # Nothing here used to copy them. A destination named bin is a prefix's
    # bin directory, so the texts go in share/doc/leita beside it; anywhere
    # else they sit next to the binary.
    if [[ $(basename "$dest") == bin ]]; then
        doc="$(dirname "$dest")/share/doc/leita"
        mkdir -p "$doc"
    else
        doc=$dest
    fi
    install -m 644 LICENSE.md THIRD_PARTY.md "$doc/"
    echo "installed $dest/{{bin}} and $dest/{{short}}"
    echo "notices in $doc"

# An NTFS folder read from the MFT against a walk of it, from an elevated prompt
# on Windows, optimised and without the sanitizer: just mft-bench 'C:\Windows'
mft-bench folder: sqlite
    mkdir -p build/test
    LEITA_BENCH_MFT='{{folder}}' {{odin}} test survey -o:speed {{flags}} -define:ODIN_TEST_NAMES=survey.bench_a_folder_from_the_mft_against_a_walk -out:build/test/mft-bench{{exe}}

# leita against fd on one seeded tree: the host filesystem, then throw-away
# ext4 and btrfs images, then tmpfs. Loop images sit on this disk, so they
# are not a raw drive. Warm cache only. "scan ~ under 500 ms warm" is fast
# enough; walk perf cards stop once a warm scan holds that.
# `just fsbench "--files 20000"` shortens the seed. vfat is opt-in
# (`--only vfat`); its desktop mount syncs every created file.
fsbench args="": (cli "release")
    python3 tools/fsbench {{args}}

# The walk on one seeded tmpfs, against tools/fsbench-baseline.json, so a
# slower walk fails CI. A user namespace when the kernel allows it, otherwise
# passwordless sudo; no loop device. The release command line, a warmup, then
# the runs: hyperfine when it is installed, otherwise /usr/bin/time. The median
# is printed in milliseconds. It fails when the median exceeds the baseline
# times (1 + tolerance). The tolerance is 30% because a GitHub runner varies
# against the machine that wrote the medians. `--update` rewrites the median.
#
# A release build needs a licence key. The test key stands in when
# LEITA_LICENCE_KEY is unset; the key does not change the walk.
#
# Check the walk: just fsbench-ci
# Rewrite the baseline: just fsbench-ci --update
fsbench-ci *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${LEITA_LICENCE_KEY:-}" ]; then
        export LEITA_LICENCE_KEY="$(just --justfile "{{justfile()}}" --evaluate test_licence_key)"
    fi
    just --justfile "{{justfile()}}" cli release
    python3 tools/fsbench --ci {{args}}

