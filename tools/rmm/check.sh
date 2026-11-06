#!/usr/bin/env bash
# Python 3.10+ is an explicit prerequisite; no installation or PATH changes.
set -euo pipefail
recipe_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python_bin=${LEITA_RMM_PYTHON:-python3}
if ! command -v -- "$python_bin" >/dev/null 2>&1; then
    printf '%s\n' 'leita-rmm: Python 3.10+ is required; set LEITA_RMM_PYTHON to its executable path' >&2
    exit 1
fi
exec "$python_bin" "$recipe_dir/check.py" "$@"
