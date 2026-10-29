# Standard recipes: build, run, clean, test, install.
#
#   just build [mode]         the command line and the window -> build/<mode>/
#   just cli [mode]           the command line alone -> build/<mode>/leita
#   just gui [mode]           the window alone -> build/<mode>/app/Leita
#   just bundle [window cli]  Leita.app from the release window and command line,
#                             macOS only -> build/release/Leita.app
#   just run [mode] [dir]     build the window, then open it on a directory, the
#                             home directory by default
#   just hot [mode] [dir]     the window, its view rebuilt on every edit
#   just publish              the release build, then this OS's packages
#   just test                 run every imported package's tests under ASan -> build/test/
#   just fuzz [suite] [seed] [duration] [flags]
#                             leita-fuzz under ASan, here and in CI; its tree suite builds
#                             filesystems with mounts and scans them
#   just soak thread|address [duration] [seed] [rounds] [gui]
#                             the suite and every fuzz suite under TSan, or the fuzz
#                             suites under ASan and the debug allocator, for long
#   just btrfs-test [--sudo]  the btrfs and walk tests on a throw-away btrfs image,
#                             as root too with --sudo where sudo asks no password
#   just mount-test [--sudo]  the delete test that mounts, in a namespace of its own
#   just durability [--sudo]  kill each durable write part way; full and read-only volumes
#   just fsbench-ci [--update] the walk on a seeded tmpfs, against the baseline
#   just install              put the release command line on PATH as leita and le
#   just check                type-check both modes without producing a binary
#   just check-licence [key licence]
#                             test that a build with key takes a licence its private
#                             half signed; the test key and its licence by default
#   just clean                remove build/
#   just deps                 fetch the jm submodule and the native libraries the window links
#   just sqlite               fetch the jm submodule and build SQLite, all the command line links
#   just gui-test             run the window's tests, the host's on a real directory
#   just package              Linux: the release as an AppImage, a .deb and an .rpm
#                             -> build/package/. publish runs this on Linux
#   just journeys             the built command line driven end to end on the made-up disk
#                             (LEITA_SYNTHETIC), as a person would: scan, limits, reports,
#                             history, monitoring, licence, then the window's user
#                             stories in each scenario -> build/test/journeys,
#                             build/journeys/artifacts
#   just lifecycle            native lifecycle evidence, then the release gate
#
# The debug allocator, flow, sqlite3, stream and ui come from the jm collection, pinned as
# the jm submodule (https://mordaunt.dev/code/jm); JM=<path> builds against another
# checkout instead.
#
# The mode is minimal, speed, asan, tsan or release. build, run and hot default
# to minimal. The flags are minimal_opt and the variables beside it. minimal,
# speed, asan and tsan pass -debug. release does not.
#
#   minimal   -o:minimal, no sanitizer. The daily build. Frame median 17ms.
#   speed     -o:speed, no sanitizer. The same build, for a slow path. The view
#             rebuilds in about 15s and the frame median was 8ms, against 28ms
#             with no -o (measured 2026-10-16, scanning ~/Source).
#   asan      -o:none -sanitize:address. Reads past the end and after free trap
#             at the faulting instruction. Backtraces stay on.
#   tsan      -o:none -sanitize:thread. Its own binary: address and thread
#             sanitizers cannot be combined.
#   release   -o:speed, the licence key and the update key, and on Windows a
#             GUI program, so starting it opens no console. The candidate.
#             publish accepts only this mode.
#
# minimal, speed, asan and tsan take no licence and carry no release stamp, so
# a line does not grant Pro. release checks licences against LEITA_LICENCE_KEY,
# one or more comma-separated 64-hex keys, and refuses an empty or malformed
# set, since a release without one takes no licence. A line holds when any key
# in the set verifies it. The same build takes LEITA_UPDATE_KEY, one 64-hex
# Ed25519 public key, and refuses a release without it. The private half is
# LEITA_UPDATE_SEED, used only to sign a release, never as a compile flag and
# never by the lifecycle fixture.
#
# just hot adds -define:DEBUG_ALLOC_BACKTRACES=false on the four development
# modes. The scan's workers allocate enough that the chains keep a scan in
# 2.6s instead of 1.6s. The report still names the file, line and proc. A leak
# hunt is just run asan. A frame in the view costs about 5.5x release under
# AddressSanitizer and 2.3x without it (the same measurement).
#
# Test, fuzz and soak still honour SAN, whose default is -sanitize:address.
# SAN= does not change build, run, hot or publish. Odin does not create output
# directories, hence the mkdir.

# Shebangs are `/bin/bash`. On Windows just maps that through cygpath to Git's
# bash.exe. `bash` on PATH is the WSL launcher. That bash is not a login
# shell, so System32 stays ahead of Git's coreutils and `sort` is Windows
# sort.exe. Prepend Git's usr\bin. The branch is lazy, so a non-Windows
# parse never runs cygpath.
export PATH := if os() == "windows" { `cygpath -w /usr/bin` + ";" + env("PATH", "") } else { env("PATH", "") }
odin  := env("ODIN", "odin")
# Forward slashes throughout: justfile_directory() on Windows returns
# backslashes, and passing those mixed with the "/" below straight to a
# native exe (odin.exe is not an MSYS program) through Git Bash corrupts
# the path, as jm's own justfile already normalises root for the same
# reason.
root  := replace(justfile_directory(), "\\", "/")
# LEITA_GLIBC_FLOOR, a glibc version such as 2.35, builds the Linux window and
# everything it links against that glibc's symbols with zig (tools/linux/zigcc),
# so the binary runs on that glibc and newer, not only on the system that built
# it. LEITA_FLOOR_ARCH (x86_64 or aarch64) builds for the other architecture,
# which needs its arm64 AccessKit (see deps). The libraries are built into a
# checkout of jm of their own, build/floor-<version>-<arch>/jm, so none of the host's
# own is linked by mistake.
floor      := env("LEITA_GLIBC_FLOOR", "")
floor_arch := env("LEITA_FLOOR_ARCH", arch())
floor_dir  := root / "build/floor-" + floor + "-" + floor_arch
floor_env  := ". \"" + root + "/tools/linux/floor-env\" \"" + root + "\" \"" + floor + "\" \"" + floor_arch + "\""
odin_target := if floor == "" { "" } else if floor_arch == arch() { "" } else if floor_arch == "aarch64" { "-target:linux_arm64" } else { "-target:linux_amd64" }
jm    := env("JM", if floor == "" { root / "jm" } else { floor_dir / "jm" })
# Which leita a build is, the one place either binary learns it: a v* release
# tag, or a bare commit as git describe names one, g and its hash, so Odin
# never reads it as a number; dev without git. A retired/* tag is not a
# release, so it is not a version. LEITA_VERSION=<v> sets it instead.
version := env("LEITA_VERSION", `git describe --tags --match 'v*' --dirty 2>/dev/null || { h=$(git describe --always --match 'v*' --dirty 2>/dev/null) && echo "g$h"; } || echo dev`)
# The year of this build, for the copyright line. LEITA_YEAR=<n> sets it.
year := env("LEITA_YEAR", `date +%Y`)
# This build's authenticated release instant, YYYY-MM-DDTHH:MM:SSZ, the same
# text the release writes to released.txt. Empty on a development build, which
# a licence line does not entitle. LEITA_RELEASED=<instant> sets it.
released := env("LEITA_RELEASED", "")
released_define := if released == "" { "" } else { " -define:LEITA_RELEASED=" + released }
# check_flags is what odin check takes. flags adds what only build, run and
# test accept: the macOS minimum, and on Windows the shell icon.
check_flags := "-vet -strict-style -collection:jm=" + jm + " -define:LEITA_VERSION=" + version + " -define:LEITA_SHORT=" + short + " -define:LEITA_YEAR=" + year + released_define
flags := check_flags + minos + resource
# macOS 11.0 is the oldest Odin targets, and jm builds its native libraries
# for it. Without the flag a binary carries the building Mac's own version as
# its minimum, and an older Mac refuses to start it.
minos := if os() == "macos" { " -minimum-os-version:11.0" } else { "" }
# The Windows compiler is the only one that registers -resource (it is inside
# GB_SYSTEM_WINDOWS). Passing it on macOS or Linux is an unknown flag and the
# build stops, so those hosts get nothing. The file is the compiled resource,
# tools/windows/leita.res, made from leita.rc: a .rc would be compiled again
# by every link onto that one path, and just build links both binaries at once.
resource := if os() == "windows" { " -resource:" + root + "/tools/windows/leita.res" } else { "" }
san   := env("SAN", "-sanitize:address")
# Linux opens libcurl when a licence key is first sent or an update asked for,
# not at start-up (jm:http/libcurl): Ubuntu's desktop may carry only the GnuTLS
# build, or none, and the window and the command line must start either way; a
# system without it is told so by the one request that needs it. macOS links
# its own; Windows ships libcurl inside vendor:curl. Both binaries import
# jm:http, the window for the licence and both for leita update.
curl_open := if os() == "linux" { " -define:JM_HTTP_DLOPEN=true" } else { "" }
# Compiler flags for each mode. mode_arms is the shell that sets opt from the
# mode, shared by cli, gui and hot. release adds the keys itself, and on
# Windows the window adds -subsystem:windows.
minimal_opt := "-debug -o:minimal"
speed_opt := "-debug -o:speed"
asan_opt := "-debug -o:none -sanitize:address"
tsan_opt := "-debug -o:none -sanitize:thread"
mode_arms := "minimal) opt='" + minimal_opt + "' ;; " + "speed) opt='" + speed_opt + "' ;; " + "asan) opt='" + asan_opt + "' ;; " + "tsan) opt='" + tsan_opt + "' ;;"
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
test_licence_key := "88c75c5976728b7e57a6fe3a5a0bd898abfc79bfce9257ea9ce32c41d6acc20f"
test_licence     := "leita.eyJ2IjoxLCJpZCI6InRlc3QiLCJlbWFpbCI6InRlc3RAbGVpdGEuZXhhbXBsZSIsInNjb3BlIjoicGVyc29uYWwiLCJmZWF0dXJlcyI6InBybyIsInBhaWRUaHJvdWdoIjoiOTk5OS0xMi0zMVQyMzo1OTo1OVoiLCJpc3N1ZWQiOiIyMDI2LTEwLTE3VDAwOjAwOjAwWiJ9.QdzfxSW5ivSRjgF7+MwQj1nE0EZjeeBX2Eb+Mo9UxT6UND4ZacO/rwNJQZ9eZugVq/Ycm+C7m84V8Uk/GjtZBg=="

# Public half of a throwaway update key, for tests and for a release build
# that is not published. No seed is stored. A publishing run refuses this
# value. It is not a production signature and it is not the licence test key.
test_update_key := "31bb08cd168ed6d55390ee4380eacb18f5d83961c54403a538649f7aedfd1ff8"

# The public half of the seed the journeys sign their own releases with (journeys/update_test.odin);
# the seed is in the open, so nothing it signs is a release.
journey_update_key := "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Build the command line and the window: just build [mode]
build mode="minimal": (cli mode) (gui mode)

# The command line, in one of the modes above.
#
# Build the command line -> build/<mode>/leita: just cli [mode]
cli mode="minimal": sqlite
    #!/bin/bash
    set -euo pipefail
    if [ -n "{{floor}}" ]; then {{floor_env}}; fi
    case "{{mode}}" in
    {{mode_arms}}
    release) opt="-o:speed -define:LEITA_LICENCE_KEY='$(just --justfile "{{justfile()}}" release-key)' -define:LEITA_UPDATE_KEY='$(just --justfile "{{justfile()}}" update-key)'" ;;
    *) echo "cli: the mode is minimal, speed, asan, tsan or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}
    {{odin}} build cmd/cli $opt {{odin_target}} {{flags}} {{curl_open}} -out:build/{{mode}}/{{bin}}{{exe}}

# The staged jm of cli-baseline and baseline-test, its SQLite and zstd built with zig cc.
[private]
[linux]
_baseline-stage arch floor:
    #!/bin/bash
    set -euo pipefail
    command -v "${ZIG:-zig}" >/dev/null || { echo "baseline: zig is missing; install it or set ZIG=<path>" >&2; exit 1; }
    stage=build/baseline/{{arch}}
    zcc="{{root}}/tools/linux-baseline/zcc"
    export LEITA_BASELINE_ARCH={{arch}} LEITA_GLIBC_FLOOR={{floor}}
    # The archives record the floor they were compiled for; another floor starts over.
    [ "$(cat "$stage/floor" 2>/dev/null)" = "{{floor}}" ] || rm -rf "$stage"
    if [ ! -d "$stage/jm" ]; then
        if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
        mkdir -p "$stage/jm"
        git -C "{{jm}}" ls-files -z | (cd "{{jm}}" && xargs -0 cp --parents --reflink=auto -t "{{root}}/$stage/jm")
        # jm's recipes ask git whether this is a worktree; a repository of its own says no.
        git -C "$stage/jm" init -q
    fi
    (cd "$stage/jm" && CC="$zcc" just sqlite && CC="$zcc" just zstd)
    echo "{{floor}}" > "$stage/floor"

# The command line for any Linux, release optimised, linked against an old glibc
# on plain x86-64 or ARMv8-A -> build/baseline/<arch>/leita: just cli-baseline
# [amd64|arm64] [floor]. The ordinary build binds to the building host's glibc,
# which is why a release built on Ubuntu 24.04 asks for GLIBC_2.38 (fmod) and
# does not start on 22.04, and Odin's default amd64 target is x86-64-v2, which a
# CPU without SSE4.2 or POPCNT faults on. This build compiles jm's SQLite and
# zstd, and links the program, with tools/linux-baseline/zcc, zig cc pinned to
# the floor (2.26 unless given) and to the baseline instruction set; it needs zig
# (0.17.0 was used, ZIG=<path> names another) and takes both arches from an amd64
# host. The libraries are built in a copy of jm under build/baseline/<arch>, so
# neither the host's nor the other arch's archives are touched. The command line
# alone: the window's AccessKit, SDL3 and Blend2D are a higher floor (just gui).
# tools/linux-baseline/check reads the result back.
#
# Build the command line at a glibc floor: just cli-baseline [arch] [floor]
[linux]
cli-baseline arch="amd64" floor="2.26": (_baseline-stage arch floor)
    #!/bin/bash
    set -euo pipefail
    case "{{arch}}" in
    amd64) target=linux_amd64; march="-microarch:x86-64" ;;
    arm64) target=linux_arm64; march="" ;;
    *) echo "cli-baseline: the arch is amd64 or arm64, not {{arch}}" >&2; exit 1 ;;
    esac
    stage=build/baseline/{{arch}}
    export LEITA_BASELINE_ARCH={{arch}} LEITA_GLIBC_FLOOR={{floor}} ODIN_CLANG_PATH="{{root}}/tools/linux-baseline/zcc"
    {{odin}} build cmd/cli -target:$target $march -o:speed \
        -define:LEITA_LICENCE_KEY="$(just --justfile "{{justfile()}}" release-key)" \
        -define:LEITA_UPDATE_KEY="$(just --justfile "{{justfile()}}" update-key)" \
        $(echo "{{flags}}" | sed "s|-collection:jm={{jm}}|-collection:jm={{root}}/$stage/jm|") {{curl_open}} -out:"$stage/{{bin}}"

# The walk's tests built the way cli-baseline builds the command line, to run on an
# old glibc: hard links, the mount boundary, cancellation. Without ASan, which
# zig cc does not carry -> build/baseline/<arch>/walk-test: just baseline-test
# [amd64|arm64] [floor]. The mount tests run with LEITA_MOUNT_TEST=1 where the
# process may mount; tools/linux-baseline/probe runs this and the command line.
[linux]
baseline-test arch="amd64" floor="2.26": (_baseline-stage arch floor)
    #!/bin/bash
    set -euo pipefail
    case "{{arch}}" in
    amd64) target=linux_amd64; march="-microarch:x86-64" ;;
    arm64) target=linux_arm64; march="" ;;
    *) echo "baseline-test: the arch is amd64 or arm64, not {{arch}}" >&2; exit 1 ;;
    esac
    stage=build/baseline/{{arch}}
    export LEITA_BASELINE_ARCH={{arch}} LEITA_GLIBC_FLOOR={{floor}} ODIN_CLANG_PATH="{{root}}/tools/linux-baseline/zcc"
    {{odin}} build walk -build-mode:test -target:$target $march -o:none \
        $(echo "{{flags}}" | sed "s|-collection:jm={{jm}}|-collection:jm={{root}}/$stage/jm|") -out:"$stage/walk-test"

# The window, in one of the modes above.
#
# Build the window -> build/<mode>/app/Leita: just gui [mode]
gui mode="minimal": deps
    #!/bin/bash
    set -euo pipefail
    if [ -n "{{floor}}" ]; then {{floor_env}}; fi
    case "{{mode}}" in
    {{mode_arms}}
    release) opt="-o:speed -define:LEITA_LICENCE_KEY='$(just --justfile "{{justfile()}}" release-key)' -define:LEITA_UPDATE_KEY='$(just --justfile "{{justfile()}}" update-key)'" ;;
    *) echo "gui: the mode is minimal, speed, asan, tsan or release, not {{mode}}" >&2; exit 1 ;;
    esac
    # A release window on Windows is a GUI program, so starting it opens no
    # console behind it. Every other mode keeps its console, where printing goes.
    if [ "{{os()}}" = windows ] && [ "{{mode}}" = release ]; then opt="$opt -subsystem:windows"; fi
    mkdir -p build/{{mode}}/app
    {{odin}} build cmd/gui $opt {{odin_target}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/{{mode}}/app/{{gui}}{{exe}}
    if [ -n "{{floor}}" ]; then
        # The floor is a promise about the binary, so it is read back from it.
        need=$(readelf -V "build/{{mode}}/app/{{gui}}" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n 1)
        echo "gui: needs ${need:-no glibc}, built at the glibc {{floor}} floor"
        if [ -n "$need" ] && [ "$(printf '%s\n%s\n' "$need" "GLIBC_{{floor}}" | sort -V | tail -n 1)" != "GLIBC_{{floor}}" ]; then
            echo "gui: $need is above the {{floor}} floor" >&2; exit 1
        fi
        if readelf -d "build/{{mode}}/app/{{gui}}" | grep -q 'libstdc++'; then
            echo "gui: the window loads libstdc++, which a floor build links statically as libc++" >&2; exit 1
        fi
    fi
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
    #!/bin/bash
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

# The licence public keys a release is built with, from LEITA_LICENCE_KEY:
# one or more 64-hex keys, commas between them. Spaces around a comma are
# removed. It fails, saying why, when the set is empty or any entry is not
# one key, and prints the set with no spaces so the compiler flag stays one
# argument.
[private]
release-key:
    #!/bin/bash
    set -euo pipefail
    key="${LEITA_LICENCE_KEY:-}"
    key="${key//[[:space:]]/}"
    if ! [[ $key =~ ^[0-9a-fA-F]{64}(,[0-9a-fA-F]{64})*$ ]]; then
        echo "release: LEITA_LICENCE_KEY must be one or more licence public keys, 64 hex characters each, separated by commas; a release without a valid set takes no licence" >&2
        exit 1
    fi
    printf '%s' "$key"

# The update public key a release is built with, from LEITA_UPDATE_KEY:
# one 64-hex key, no commas. It fails when the value is empty or not one key.
[private]
update-key:
    #!/bin/bash
    set -euo pipefail
    key="${LEITA_UPDATE_KEY:-}"
    key="${key//[[:space:]]/}"
    if ! [[ $key =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "release: LEITA_UPDATE_KEY must be one update public key, 64 hex characters; a release without one cannot check a signature" >&2
        exit 1
    fi
    printf '%s' "$key"

# The harness writes evidence-update.json. Sibling harnesses may already
# have written evidence-*.json in the same directory. A missing required
# case fails the gate.
#
# Native lifecycle evidence for this OS, then the release gate.
lifecycle:
    #!/bin/bash
    set -euo pipefail
    if command -v python3 >/dev/null 2>&1; then py=python3; else py=python; fi
    dir="${LIFECYCLE_DIR:-build/lifecycle}"
    "$py" tools/test-lifecycle/harness.py
    sha=$(git rev-parse HEAD)
    "$py" tools/test-lifecycle/gate.py local "$dir" "$sha"

# A first argument that names a mode builds that one. Anything else is the
# directory, and the mode is minimal.
#
# Build the window, then open it on a directory: just run [mode] [dir]
[positional-arguments]
run *args:
    #!/bin/bash
    set -euo pipefail
    mode=minimal
    case "${1:-}" in
    minimal|speed|asan|tsan|release) mode=$1; shift ;;
    esac
    just --justfile "{{justfile()}}" gui "$mode"
    exec build/$mode/app/{{gui}}{{exe}} "$@"

# Run the tests of every package the binary imports, pdf among them, under ASan
# -> build/test/. The command line does not import gui/notices, so that test is
# run on its own: it is what keeps THIRD_PARTY.md equal to the window's list.
test: sqlite
    mkdir -p build/test
    {{odin}} test cmd/cli -all-packages -debug {{san}} {{flags}} {{curl_open}} -out:build/test/{{bin}}{{exe}}
    {{odin}} test gui/notices -debug {{san}} {{flags}} -out:build/test/notices{{exe}}
    # Fuzz packages are not imported by the command line, so -all-packages
    # never sees them. These are the short fixed-seed replays; just fuzz is
    # the longer budget. test.yml stays as it is and still runs this recipe.
    {{odin}} test btrfs/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-btrfs{{exe}}
    {{odin}} test history/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-history{{exe}}
    {{odin}} test scan/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-scan{{exe}}
    {{odin}} test ntfs/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-ntfs{{exe}}
    {{odin}} test search/fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-search{{exe}}
    # Kills each durable write part way, in a child of the test binary
    # (durability/child.odin).
    {{odin}} test durability -debug {{san}} {{flags}} -out:build/test/durability{{exe}}
    # walk/fuzz builds trees with mounts, so its replay runs in a namespace where
    # one can be had, and says so where it cannot.
    {{odin}} build walk/fuzz -build-mode:test -debug {{san}} {{flags}} {{curl_open}} -out:build/test/fuzz-walk{{exe}}
    tools/in-namespace build/test/fuzz-walk{{exe}}

# Fuzz suites under ASan, the one entry point for local runs and CI.
#   just fuzz                    every suite, seed 1, 64 cases, 2m each at most
#   just fuzz ntfs 7 30s         one suite, seed 7, as many cases as fit in 30s
#   just fuzz tree 2,3,4,5 0 -iters=128  four seeds in turn, 128 cases each
#   just fuzz tree 1 0 -iters=8  the filesystem suite, 8 cases, no time limit
#   just fuzz scan 0             seed 0 takes the clock; the seed is printed
#   just fuzz btrfs 1 0 -isolate a child process per case, no time limit
# With no duration a suite stops at 64 cases or 2m, the push-time budget; a
# duration given is the budget, and 0 sets no clock, 64 cases. Flags after the
# duration go to leita-fuzz and win. Seeds may be a comma list, run one after
# another; the recipe fails if any seed did. A failure prints the seed, the
# shrunk case saved beside its suite (the regression corpus, replayed first on
# every run), and the just command that runs it again. The tree suite builds
# directories and mounts under the temp directory: on Linux in a user and mount
# namespace this recipe enters where it can, on macOS on APFS disk images that
# hdiutil attaches, on Windows on NTFS volumes of a VHDX; where it cannot, that
# suite runs what needs no mount and says what it left out. The gui suite drives
# the window on the made-up disk, so it needs the libraries the window draws
# with (deps), and takes seconds a case: just fuzz gui 1 0 -iters=4.
fuzz suite="" seed="1" duration="" *extra: deps
    #!/bin/bash
    set -euo pipefail
    mkdir -p build/debug
    {{odin}} build tools/leita-fuzz -debug {{san}} {{flags}} {{curl_open}} -out:build/debug/leita-fuzz{{exe}}
    case '{{duration}}' in
    '') budget=(-for=2m -iters=64) ;;
    0) budget=(-iters=64) ;;
    *) budget=(-for='{{duration}}' -iters=0) ;;
    esac
    # LeakSanitizer reports two allocations the Odin runtime makes at start-up (args,
    # 670 bytes), on some runs and not others, whatever the suite; the debug
    # allocator reports a leak of the suite's own. ASAN_OPTIONS from the caller wins.
    export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
    failed=0
    for seed in $(echo '{{seed}}' | tr , ' '); do
        tools/in-namespace build/debug/leita-fuzz{{exe}} {{suite}} -seed="$seed" "${budget[@]}" {{extra}} || failed=1
    done
    exit "$failed"

# The soak: a longer, harder run than a push gets, by hand or from soak.yml.
#   just soak thread 20m 1 3     ThreadSanitizer: just test and just gui-test three
#                                times, then every fuzz suite for 20m at seeds 1 to 3
#   just soak address 30m 7 2    AddressSanitizer (SAN, so SAN= turns it off) and the
#                                debug allocator: every fuzz suite for 30m at seeds 7, 8
#   just soak thread 5m 1 1 no   the same without the window's tests, which need deps
# TSan and ASan cannot share a binary, so a run takes one. Under TSan the tests run
# on one thread: on Linux Odin maps arena memory with system calls TSan does not
# see, so two tests that reuse an address on two threads read as a race. A
# test's own threads are still watched. tools/tsan.supp lists the reports that
# are not bugs, each with its reason. Any other report stops the binary at once
# (halt_on_error): on Linux Odin exits with a system call, so TSan's own exit
# status at the end of a run never happens and a race would otherwise pass.
soak sanitizer="address" duration="10m" seed="1" rounds="2" gui="gui": sqlite
    #!/bin/bash
    set -euo pipefail
    j() { just --justfile "{{justfile()}}" "$@"; }
    case "{{sanitizer}}" in
    thread)
        export SAN="-sanitize:thread -define:ODIN_TEST_THREADS=1"
        export TSAN_OPTIONS="suppressions={{root}}/tools/tsan.supp halt_on_error=1 ${TSAN_OPTIONS:-}"
        for round in $(seq 1 {{rounds}}); do
            echo "soak: thread round $round of {{rounds}}"
            j test
            if [ "{{gui}}" = gui ]; then j gui-test; fi
        done
        ;;
    address) ;;
    *) echo "soak: the sanitizer is thread or address, not {{sanitizer}}" >&2; exit 1 ;;
    esac
    for s in $(seq {{seed}} $(( {{seed}} + {{rounds}} - 1 ))); do
        echo "soak: {{sanitizer}} fuzz, seed $s, {{duration}} a suite"
        j fuzz "" "$s" "{{duration}}"
    done

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
    #!/bin/bash
    set -euo pipefail
    licence='{{licence}}'
    if [ -z "$licence" ] && [ '{{key}}' = '{{test_licence_key}}' ]; then licence='{{test_licence}}'; fi
    if [ -z "$licence" ]; then
        echo "check-licence: give a licence the key signed: just check-licence KEY LICENCE" >&2
        exit 1
    fi
    mkdir -p build/test
    {{odin}} test licence -debug {{san}} {{flags}} "-define:LEITA_LICENCE_KEY='{{key}}'" "-define:LEITA_LICENCE_SAMPLE=$licence" -out:build/test/licence{{exe}}

# The tests that mount: a delete with a tmpfs and a bind inside the tree being
# deleted, and walks over binds of a directory above them and beside them, and over a tmpfs in a tmpfs. Each
# runs in a user and mount namespace of its own (unshare -rm), which needs no root
# and leaves nothing mounted; --sudo runs them as root instead, where sudo asks no
# password. Skipped where neither can mount. Linux only: just mount-test [--sudo]
mount-test *args:
    #!/bin/bash
    set -euo pipefail
    if [ "{{os()}}" != linux ]; then echo "mount-test: skipped: the mounts are Linux's"; exit 0; fi
    mkdir -p build/test
    {{odin}} build gui/files -build-mode:test -debug {{san}} {{flags}} \
        -define:ODIN_TEST_NAMES=leita_files.a_delete_never_crosses_a_mount -out:build/test/mount-test
    {{odin}} build walk -build-mode:test -debug {{san}} {{flags}} \
        -define:ODIN_TEST_NAMES=walk.test_a_bind_of_an_ancestor_is_a_mount,walk.test_a_bind_of_a_walked_tree_is_counted_once,walk.test_a_tmpfs_inside_a_tmpfs_is_a_mount -out:build/test/walk-mount-test
    tests=(build/test/mount-test build/test/walk-mount-test)
    if [ "{{args}}" = --sudo ]; then
        for test in "${tests[@]}"; do sudo -n env LEITA_MOUNT_TEST=1 "$test"; done
        exit 0
    elif unshare --user --map-root-user --mount true 2>/dev/null; then
        for test in "${tests[@]}"; do LEITA_MOUNT_TEST=1 unshare --user --map-root-user --mount "$test"; done
        exit 0
    fi
    echo "mount-test: skipped: no user namespaces here; give --sudo where sudo asks no password"

# Kills each durable write part way, and fills and freezes real volumes under
# them (durability/). The kills run everywhere. On Linux a tmpfs of a fixed size
# is mounted in a user and mount namespace where one can be had; with --sudo,
# as root, an ext4 image on a loop device too.
durability *args: sqlite
    #!/bin/bash
    set -euo pipefail
    mkdir -p build/test
    {{odin}} build durability -build-mode:test -debug {{san}} {{flags}} -out:build/test/durability{{exe}}
    if [ "{{os()}}" != linux ]; then exec build/test/durability{{exe}}; fi
    if [ "{{args}}" = --sudo ]; then
        exec sudo -n env LEITA_VOLUME_TEST=1 LEITA_VOLUME_EXT4=1 build/test/durability
    elif unshare --user --map-root-user --mount true 2>/dev/null; then
        exec env LEITA_VOLUME_TEST=1 unshare --user --map-root-user --mount build/test/durability
    fi
    echo "durability: no user namespace here, so no volume is mounted; give --sudo where sudo asks no password" >&2
    exec build/test/durability

# Type-check both modes without producing a binary. gui/notices is separate:
# the command line does not import it, and its test is what renders
# THIRD_PARTY.md.
check:
    {{odin}} check cmd/cli {{check_flags}}
    {{odin}} check cmd/cli -debug {{check_flags}}
    {{odin}} check gui/notices -no-entry-point {{check_flags}}

# The jm submodule, when JM does not name another checkout, SQLite, which keeps
# both binaries' scans, and zstd, which decodes the patches leita update applies:
# all the command line links that is not Odin or the system's libcurl. Built by
# jm's own recipes, once.
sqlite: floor-jm
    #!/bin/bash
    set -euo pipefail
    if [ -n "{{floor}}" ]; then {{floor_env}}; fi
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    cd "{{jm}}"
    ls sqlite3/lib/sqlite3.* >/dev/null 2>&1 || just sqlite
    ls zstd/lib/zstd.* >/dev/null 2>&1 || just zstd

# What sqlite fetches, and the libraries jm:ui links: Blend2D to draw,
# kb_text_shape to shape text, AccessKit for screen readers, and on macOS and
# Linux SDL3 itself. Each is built or fetched by jm's own recipe, once, but
# Linux's SDL3, which sdl3-static builds here.
#
# A floor build (LEITA_GLIBC_FLOOR) compiles all of them with zig. AccessKit's
# prebuilt library exists for x86_64 only; where there is none, aarch64, it is
# built from the tag jm pins, as a static library, with the host's own cargo
# and cc: the Rust it holds names no glibc version until the link above.
deps: sqlite
    #!/bin/bash
    set -euo pipefail
    if [ -n "{{floor}}" ]; then {{floor_env}}; fi
    cd "{{jm}}"
    ls ui/blend2d/lib/*blend2d* >/dev/null 2>&1 || just blend2d
    ls ui/kb/lib/kb_text_shape.* >/dev/null 2>&1 || just kb
    if [ -n "{{floor}}" ] && [ "{{floor_arch}}" = aarch64 ]; then
        if [ ! -f ui/accesskit/lib/libaccesskit.a ]; then
            ver=$(just --evaluate accesskit_ver)
            src="{{floor_dir}}/accesskit-c"
            rm -rf "$src"
            git -c advice.detachedHead=false clone -q --depth 1 --branch "$ver" https://github.com/AccessKit/accesskit-c "$src"
            ( PATH=$LEITA_ORIG_PATH; unset CC CXX
              cargo rustc --manifest-path "$src/Cargo.toml" --target aarch64-unknown-linux-gnu --release --locked --lib --crate-type staticlib )
            mkdir -p ui/accesskit/lib
            cp "$src/target/aarch64-unknown-linux-gnu/release/libaccesskit.a" ui/accesskit/lib/
            ( PATH=$LEITA_ORIG_PATH; llvm-strip --strip-debug ui/accesskit/lib/libaccesskit.a || strip --strip-debug ui/accesskit/lib/libaccesskit.a )
        fi
    else
        ls ui/accesskit/lib/*accesskit* >/dev/null 2>&1 || just accesskit
    fi
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
sdl3-static: floor-jm
    #!/bin/bash
    set -euo pipefail
    if [ -n "{{floor}}" ]; then {{floor_env}}; fi
    cd "{{jm}}"
    [ -f ui/shell/lib/libSDL3.a ] && exit 0
    rev=$(just --evaluate sdl3_rev)
    just fetch build/src/sdl3 https://github.com/libsdl-org/SDL "$rev"
    echo "cmake sdl3 (static) -> ui/shell/lib/libSDL3.a"
    mkdir -p ui/shell/lib build
    # CMake finds a Debian system's libraries (/usr/lib/<triplet>) by asking the C
    # compiler for its multiarch triplet, and zig answers none: X11 and OpenGL were
    # then "not found" and SDL was built with no X11 video driver, a window that
    # starts on no X server. The triplet is given.
    arch_flag=""
    if [ -n "{{floor}}" ]; then arch_flag="-DCMAKE_LIBRARY_ARCHITECTURE={{floor_arch}}-linux-gnu"; fi
    cmake --fresh -S build/src/sdl3 -B build/sdl3-static -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON $arch_flag > build/sdl3-static.log 2>&1 \
        || { tail -n 30 build/sdl3-static.log >&2; exit 1; }
    cmake --build build/sdl3-static --parallel >> build/sdl3-static.log 2>&1 \
        || { tail -n 30 build/sdl3-static.log >&2; exit 1; }
    # A window needs a video driver for the display it is shown on: X11 (also
    # Xwayland, Xvfb) and Wayland. Without one it says "No available video device".
    symbols=$(nm build/sdl3-static/libSDL3.a 2>/dev/null)
    for driver in X11 Wayland; do
        if ! grep -q "${driver}_CreateDevice" <<<"$symbols"; then
            echo "sdl3-static: SDL was built without its $driver video driver; see build/sdl3-static.log" >&2
            grep -iE "$driver|Could NOT" build/sdl3-static.log >&2 || true
            exit 1
        fi
    done
    cp build/sdl3-static/libSDL3.a build/sdl3-static/sdl3.pc ui/shell/lib/

# The window with its view hot-reloaded. The host (cmd/gui-host) owns the window and
# the scan; the view runs as cmd/gui-child in a subprocess, rebuilt here whenever an
# .odin file it is made of changes, into its own timestamped binary under
# build/hot/<mode>, named in build/hot/<mode>/view.watch, which the host re-reads
# and respawns from (ui/shell.run_host). The scan keeps running across reloads; a
# change to the scan or the pipeline (gui/app, survey, scan, walk, ntfs) needs the
# recipe run again. A shell loop rather than jm's tools/hot-watch, which passes its
# own checkout as the jm collection. stat is GNU's -c or BSD's -f, whichever runs.
# The host and the view take the mode's flags. The four development modes also
# drop allocation backtraces, as the header says. A release-mode host takes the
# keys; the view does not check licences, so it is only -o:speed. The host keeps
# its console in every mode, so the reload line stays visible. The packaged
# window is cmd/gui, which publish builds.
#
# Open the window, reloading the view on every edit: just hot [mode] [dir]
[positional-arguments]
hot *args: deps
    #!/bin/bash
    set -euo pipefail
    mode=minimal
    case "${1:-}" in
    minimal|speed|asan|tsan|release) mode=$1; shift ;;
    esac
    case "$mode" in
    {{mode_arms}}
    release) opt="-o:speed" ;;
    *) echo "hot: the mode is minimal, speed, asan, tsan or release, not $mode" >&2; exit 1 ;;
    esac
    child_opt=$opt
    if [ "$mode" = release ]; then
        opt="$opt -define:LEITA_LICENCE_KEY='$(just --justfile "{{justfile()}}" release-key)' -define:LEITA_UPDATE_KEY='$(just --justfile "{{justfile()}}" update-key)'"
    else
        opt="$opt -define:DEBUG_ALLOC_BACKTRACES=false"
        child_opt=$opt
    fi
    mkdir -p "build/$mode/app" "build/hot/$mode"
    {{odin}} build cmd/gui-host $opt {{flags}} {{curl_open}} {{sdl3_link}} -out:build/$mode/app/{{gui}}-host{{exe}}
    if [ "{{os()}}" = windows ]; then
        for dll in "$({{odin}} root)/vendor/sdl3/SDL3.dll" "{{jm}}/ui/accesskit/lib/accesskit.dll"; do
            [ -f "$dll" ] || { echo "hot: $dll is missing, and the window does not start without it" >&2; exit 1; }
            cp "$dll" "build/$mode/app/"
        done
    fi
    rm -f "build/hot/$mode/view.watch"
    (
      last=""
      n=0
      while true; do
        srcs=(cmd/gui-child/*.odin gui/view/*.odin gui/query/*.odin gui/command/*.odin human/*.odin)
        mt=$({ stat -c %Y "${srcs[@]}" 2>/dev/null || stat -f %m "${srcs[@]}"; } | sort -n | tail -1)
        if [ "$mt" != "$last" ]; then
          last=$mt
          n=$((n + 1))
          out=build/hot/$mode/view-$(date +%s)-${n}{{exe}}
          if {{odin}} build cmd/gui-child $child_opt {{flags}} -out:"$out"; then
            printf '%s' "$out" > "build/hot/$mode/view.watch"
            echo "hot: view ready $out"
            ls -t build/hot/$mode/view-* | tail -n +3 | xargs -r rm -f
          else
            echo "hot: build failed; the window keeps the last good view"
          fi
        fi
        sleep 0.4
      done
    ) &
    watcher=$!
    trap 'kill $watcher 2>/dev/null' EXIT
    while [ ! -f "build/hot/$mode/view.watch" ]; do sleep 0.2; done
    build/$mode/app/{{gui}}-host{{exe}} "build/hot/$mode/view.watch" "$@"

# Leita's own suite (which arguments open the window and which run leita), the
# view in a probe over the host on a real directory, the view's own suite,
# the messages' (every language has every message), the platform package's, and
# those of the packages only the window imports, search among them. Not -all-packages, which would run every jm:ui
# suite the window imports too.
#
# The opt-in startup and daily check, and no install. The lifecycle
# workflow runs tools/test-schedule-lifecycle/harness.py, which runs this.
schedule-evidence:
    mkdir -p build/test/app
    {{odin}} test gui/app -debug {{san}} {{flags}} {{curl_open}} {{sdl3_link}} -define:ODIN_TEST_NAMES=leita_app.automatic_checks_once_at_startup_and_once_a_day,leita_app.automatic_checks_reach_the_release_through_the_host -out:build/test/app/schedule-evidence{{exe}}

# Run the window's suites under ASan
# The command line as a process, on the made-up disk, in a home of its own per
# journey; journeys/harness_test.odin says how. The binary is build/asan/leita, or
# LEITA_BIN.
#
# The journeys' binary is the debug build with two keys compiled in, so a journey can
# add the test licence and check a release it signed itself: the licence test key
# and journey_update_key, the public half of the seed journeys/update_test.odin
# signs with, and a release stamp for the licence to be measured against. Neither key is a
# release's.
#
# Then the window's journeys (journeys/gui): each core user story walked through
# the view in a probe over the real host, on the made-up disk or a real folder,
# in each of its scenarios, checked on what a screen reader is told. They are
# built with the licence test key and the release stamp, so a story can buy a
# licence from a stand-in shop that answers with the test licence. Each keeps a
# PNG and the accessibility tree of its steps in LEITA_JOURNEY_ARTIFACTS, by
# default build/journeys/artifacts. tools/journeys/run keeps what
# journeys/quarantine holds out of the gate.
journeys: deps
    mkdir -p build/journeys build/test
    {{odin}} build cmd/cli -debug {{san}} {{odin_target}} {{flags}} {{curl_open}} -define:LEITA_LICENCE_KEY={{test_licence_key}} -define:LEITA_UPDATE_KEY={{journey_update_key}} -define:LEITA_RELEASED=2026-10-24T00:00:00Z -out:build/journeys/{{bin}}{{exe}}
    ODIN="{{odin}}" LEITA_BIN="{{justfile_directory()}}/build/journeys/{{bin}}{{exe}}" LEITA_TEST_LICENCE='{{test_licence}}' tools/journeys/run journeys build/test/journeys{{exe}} -debug {{san}} {{flags}}
    ODIN="{{odin}}" LEITA_TEST_LICENCE='{{test_licence}}' LEITA_JOURNEY_ARTIFACTS="${LEITA_JOURNEY_ARTIFACTS:-{{root}}/build/journeys/artifacts}" tools/journeys/run journeys/gui build/test/journeys-gui{{exe}} -debug {{san}} {{flags}} {{curl_open}} -define:LEITA_LICENCE_KEY={{test_licence_key}} -define:LEITA_RELEASED=2026-10-24T00:00:00Z

# The window as the operating system drives it, kept small: tools/journeys/window.py
# starts the address-sanitizer window on the made-up disk, finds it, gives it the keyboard,
# presses the search shortcut and types through the window system (xdotool on an
# Xvfb display on Linux, SendInput on Windows, System Events on macOS) and closes
# it as a person does; journeys/window replays what the window recorded and checks
# the accessibility tree. Evidence -> build/journeys/window.
window-journey: (gui "asan")
    #!/bin/bash
    set -euo pipefail
    out="{{root}}/build/journeys/window"
    py=$(command -v python3 || command -v python)
    run=("$py" tools/journeys/window.py "build/asan/app/{{gui}}{{exe}}" "$out")
    if [ "{{os()}}" = linux ]; then run=(xvfb-run -a -s "-screen 0 1600x1000x24" "${run[@]}"); fi
    "${run[@]}"
    LEITA_WINDOW_RECORDING="$out/session.rec" {{odin}} test journeys/window -debug {{san}} {{flags}} -out:build/test/journeys-window{{exe}}

gui-test: deps
    mkdir -p build/test/app
    {{odin}} test cmd/gui -debug {{san}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/test/app/{{gui}}-main{{exe}}
    {{odin}} test gui/app -debug {{san}} {{flags}} {{curl_open}} {{sdl3_link}} -out:build/test/app/{{gui}}{{exe}}
    {{odin}} test gui/files -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-files{{exe}}
    {{odin}} test gui/view -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-view{{exe}}
    {{odin}} test gui/msg -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-msg{{exe}}
    {{odin}} test reclaim -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-reclaim{{exe}}
    {{odin}} test history -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-history{{exe}}
    {{odin}} test settings -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-settings{{exe}}
    {{odin}} test licence -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-licence{{exe}}
    {{odin}} test search -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-search{{exe}}
    # The window's fuzz suite on a fixed seed, its corpus first; just fuzz gui runs it longer.
    {{odin}} test gui/fuzz -debug {{san}} {{flags}} {{curl_open}} -define:ODIN_TEST_THREADS=1 -out:build/test/app/{{gui}}-fuzz{{exe}}

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
# Linux is package (AppImage, .deb, .rpm). macOS is bundle (Leita.app).
# Windows has no packaging recipe; the binaries stay in build/release.
# Any mode but release is refused: a development build takes no licence.
# Build the release, then package it for this OS: just publish
publish mode="release":
    #!/bin/bash
    set -euo pipefail
    if [ "{{mode}}" != release ]; then
        echo "publish: only release is packaged, not {{mode}}" >&2
        exit 1
    fi
    case "{{os()}}" in
    linux) just --justfile "{{justfile()}}" package ;;
    macos) just --justfile "{{justfile()}}" bundle ;;
    *)
        just --justfile "{{justfile()}}" build release
        echo "publish: {{os()}} has no package. The release is build/release/{{bin}}{{exe}} and build/release/app/{{gui}}{{exe}}"
        ;;
    esac

# Build the AppImage, .deb and .rpm -> build/package/: just package
[linux]
package: (build "release") package-built

# package's work on the release build already there, which release.yml calls
# after its own build, so the packages carry the very binaries it publishes.
[private]
[linux]
package-built:
    #!/bin/bash
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
    # The packages name glibc and nothing else a binary loads, so a binary
    # that loads another system library would be packaged without it.
    for b in build/release/leita build/release/app/{{gui}}; do
        if readelf -d "$b" | grep -q 'libstdc++'; then
            echo "package: $b loads libstdc++, which nfpm.yaml does not require; build at the glibc floor (LEITA_GLIBC_FLOOR)" >&2
            exit 1
        fi
    done
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

# The checkout of jm a floor build compiles the native libraries in, at the
# commit the submodule is on; nothing when no floor is asked for or JM names one.
[private]
floor-jm:
    #!/bin/bash
    set -euo pipefail
    if [ -z "{{floor}}" ] || [ "{{jm}}" != "{{floor_dir}}/jm" ]; then exit 0; fi
    if [ ! -e jm/.git ]; then git submodule update --init jm; fi
    want=$(git -C jm rev-parse HEAD)
    if [ "$(git -C "{{jm}}" rev-parse HEAD 2>/dev/null || true)" != "$want" ]; then
        rm -rf "{{jm}}"
        mkdir -p "{{floor_dir}}"
        git clone -q --no-checkout jm "{{jm}}"
        git -C "{{jm}}" checkout -q "$want"
    fi

# Remove build/.
clean:
    rm -rf build

# Copy the release binary to a directory on PATH, with the short name beside it:
# a symlink to leita on Unix, a second copy on Windows, where a symlink needs
# administrator rights or developer mode. An installed copy is replaced in place;
# otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin, /usr/local/bin, else the first
# writable PATH entry.
install:
    #!/bin/bash
    set -euo pipefail
    # A release build refuses an empty key set, so a local install without the
    # production keys takes the test keys: it accepts only test licences and
    # checks updates against the test key. Never publish such a build.
    if [ -z "${LEITA_LICENCE_KEY:-}" ]; then
        echo "install: LEITA_LICENCE_KEY is unset; building with the TEST licence key, so only test licences are accepted. Set it for a build you will give to anyone." >&2
        export LEITA_LICENCE_KEY="$(just --justfile "{{justfile()}}" --evaluate test_licence_key)"
    fi
    if [ -z "${LEITA_UPDATE_KEY:-}" ]; then
        echo "install: LEITA_UPDATE_KEY is unset; building with the TEST update key, so updates from the real release channel will fail verification." >&2
        export LEITA_UPDATE_KEY="$(just --justfile "{{justfile()}}" --evaluate test_update_key)"
    fi
    just --justfile "{{justfile()}}" cli release
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

# Folders of each entry count made up under the temp directory, each read from
# the MFT and walked, then the whole volume from the MFT, from an elevated
# prompt on Windows: where a walk stops being the faster reader (card 705)
crossover-bench counts="10,1000,100000": sqlite
    mkdir -p build/test
    LEITA_BENCH_CROSSOVER='{{counts}}' {{odin}} test survey -o:speed {{flags}} -define:ODIN_TEST_NAMES=survey.bench_where_a_walk_overtakes_the_mft -out:build/test/crossover-bench{{exe}}

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
# A release build needs a licence key and an update key. The test keys stand
# in when the variables are unset; neither key changes the walk.
#
# Check the walk: just fsbench-ci
# Rewrite the baseline: just fsbench-ci --update
fsbench-ci *args:
    #!/bin/bash
    set -euo pipefail
    if [ -z "${LEITA_LICENCE_KEY:-}" ]; then
        export LEITA_LICENCE_KEY="$(just --justfile "{{justfile()}}" --evaluate test_licence_key)"
    fi
    if [ -z "${LEITA_UPDATE_KEY:-}" ]; then
        export LEITA_UPDATE_KEY="$(just --justfile "{{justfile()}}" --evaluate test_update_key)"
    fi
    just --justfile "{{justfile()}}" cli release
    python3 tools/fsbench --ci {{args}}

