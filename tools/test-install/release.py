# A signed release folder for tools/test-install/story to update from:
#   python3 release.py DIR VERSION RELEASED BINARY...
#
# Lays DIR out as release.yml publishes a release, through the lifecycle
# fixture: each BINARY under its own name (leita-linux-amd64 and the like),
# version.txt, released.txt, sha256sums.txt, and sha256sums.txt.sig signed
# with INSTALL_UPDATE_SEED, the throwaway seed whose public half the builds
# carry. It never reads LEITA_UPDATE_SEED, a release's.

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test-lifecycle"))
import fixture  # noqa: E402


def main(argv):
    if len(argv) < 5:
        print("usage: release.py DIR VERSION RELEASED BINARY...", file=sys.stderr)
        return 2
    seed_hex = os.environ.get("INSTALL_UPDATE_SEED", "")
    if len(seed_hex) != 64:
        print("release.py: INSTALL_UPDATE_SEED must be the throwaway seed, 64 hex", file=sys.stderr)
        return 2
    directory, version, released = argv[1], argv[2], argv[3]
    files = {Path(p).name: Path(p).read_bytes() for p in argv[4:]}
    fixture.write_release(directory, files, version=version, released=released, seed=bytes.fromhex(seed_hex))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
