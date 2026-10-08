# Standard recipes: build (debug), release, clean, test, install.
#
#   just build      debug build with AddressSanitizer   -> build/debug/sonar
#   just release    optimised build                     -> build/release/sonar
#   just test       run every imported package's tests under ASan -> build/test/
#   just check      type-check both modes without producing a binary
#   just clean      remove build/
#   just deps       fetch the jm submodule and the native libraries the window links
#   just gui [dir]  open the window on a directory, the home directory by default
#   just gui-test   run the window's tests, the host's on a real directory
#
# The debug allocator, flow, stream and ui come from the jm collection, pinned as
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
bin   := "sonar"
gui   := "sonar-gui"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Debug build with AddressSanitizer -> build/debug/sonar
build:
    mkdir -p build/debug
    {{odin}} build . -debug {{san}} {{flags}} -out:build/debug/{{bin}}{{exe}}

# Optimised build -> build/release/sonar
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
# readers. Each is built or fetched by jm's own recipe, once.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    cd "{{jm}}"
    ls ui/blend2d/lib/*blend2d* >/dev/null 2>&1 || just blend2d
    ls ui/kb/lib/kb_text_shape.* >/dev/null 2>&1 || just kb
    ls ui/accesskit/lib/*accesskit* >/dev/null 2>&1 || just accesskit
    just sdl3

# Build the window and open it on a directory, the home directory by default
gui *args: gui-build
    build/debug/{{gui}}{{exe}} {{args}}

# Debug build of the window -> build/debug/sonar-gui
gui-build: deps
    mkdir -p build/debug
    {{odin}} build gui -debug {{san}} {{flags}} -out:build/debug/{{gui}}{{exe}}

# Optimised build of the window -> build/release/sonar-gui
gui-release: deps
    mkdir -p build/release
    {{odin}} build gui -o:speed {{flags}} -out:build/release/{{gui}}{{exe}}

# Run the window's suites under ASan: the view in a probe over the host on a real
# directory, the view's own, and the platform package. Not -all-packages, which would run every
# jm:ui suite the window imports too.
gui-test: deps
    mkdir -p build/test
    {{odin}} test gui/app -debug {{san}} {{flags}} -out:build/test/{{gui}}{{exe}}
    {{odin}} test gui/files -debug {{san}} {{flags}} -out:build/test/{{gui}}-files{{exe}}
    {{odin}} test gui/view -debug {{san}} {{flags}} -out:build/test/{{gui}}-view{{exe}}

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
