# Standard recipes: build (debug), release, clean, test, install.
#
#   just build      debug build with AddressSanitizer   -> build/debug/sonar
#   just release    optimised build                     -> build/release/sonar
#   just test       run the package tests under ASan    -> build/test/
#   just check      type-check both modes without producing a binary
#   just clean      remove build/
#
# The debug allocator and flow come from the jfm collection at ~/Source/Personal/odin
# (override with JFM=<path>); they are resolved by path until sonar ships.
#
# Debug and test builds carry -sanitize:address. The debug allocator poisons its
# guard bytes and freed blocks, so instrumented reads past the end or after free
# trap at the faulting instruction. Pass SAN= to build without it:
# `SAN= just build`. Odin does not create output directories, hence the mkdir.

odin  := env("ODIN", "odin")
jfm   := env("JFM", home_directory() / "Source" / "Personal" / "odin")
flags := "-vet -strict-style -collection:jfm=" + jfm
san   := env("SAN", "-sanitize:address")
exe   := if os() == "windows" { ".exe" } else { "" }
bin   := "sonar"

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

# Run every package's tests under ASan -> build/test/
test:
    mkdir -p build/test
    {{odin}} test ntfs -debug {{san}} {{flags}} -out:build/test/ntfs{{exe}}
    {{odin}} test scan -debug {{san}} {{flags}} -out:build/test/scan{{exe}}
    {{odin}} test walk -debug {{san}} {{flags}} -out:build/test/walk{{exe}}
    {{odin}} test . -debug {{san}} {{flags}} -out:build/test/main{{exe}}

# Type-check both modes without producing a binary.
check:
    {{odin}} check . {{flags}}
    {{odin}} check . -debug {{flags}}

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
