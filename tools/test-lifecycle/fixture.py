# Throwaway Ed25519 release fixtures for the lifecycle harness and, later,
# a capture run. This is not a production signature. No production seed is
# read. Checksums are written before the signature, and the signature is not
# a line of the checksum file.

import argparse
import base64
import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

# The 32-byte seed is appended to this PKCS#8 prefix.
# The 32-byte point is appended to this SPKI prefix.
PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

SUMS_NAME = "sha256sums.txt"
SIG_NAME = "sha256sums.txt.sig"
VERSION_NAME = "version.txt"
RELEASED_NAME = "released.txt"

# Names update.asset fetches. darwin is always universal: one release file
# for both Mac architectures.
ASSETS = {
    ("linux", "amd64", "command"): "leita-linux-amd64",
    ("linux", "amd64", "window"): "leita-window-linux-amd64",
    ("linux", "arm64", "command"): "leita-linux-arm64",
    ("linux", "arm64", "window"): "leita-window-linux-arm64",
    ("windows", "amd64", "command"): "leita-windows-amd64.exe",
    ("windows", "amd64", "window"): "leita-window-windows-amd64.exe",
    ("darwin", "universal", "command"): "leita-darwin-universal",
    ("darwin", "universal", "window"): "leita-window-darwin-universal",
}


class Key:
    """A throwaway Ed25519 key. seed is 32 raw bytes. public_hex is 64 hex chars."""

    def __init__(self, seed, public_hex):
        if len(seed) != 32:
            raise ValueError("an Ed25519 seed is 32 bytes")
        if len(public_hex) != 64:
            raise ValueError("an Ed25519 public key is 64 hex characters")
        self.seed = seed
        self.public_hex = public_hex.lower()


def asset_name(system, arch, kind="command"):
    """Release file name for this program. kind is command or window."""
    if system == "darwin":
        arch = "universal"
    name = ASSETS.get((system, arch, kind))
    if name is None:
        raise ValueError(f"no release asset for {system} {arch} {kind}")
    return name


def host_asset(kind="command"):
    """The asset name of the program running on this machine."""
    import platform

    plat = sys.platform
    if plat.startswith("linux"):
        system = "linux"
    elif plat == "darwin":
        system = "darwin"
    elif plat.startswith("win"):
        system = "windows"
    else:
        raise ValueError(f"no release asset for {plat}")
    machine = platform.machine()
    arch = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "AMD64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "ARM64": "arm64",
    }.get(machine)
    if system == "darwin":
        arch = "universal"
    if arch is None:
        raise ValueError(f"no release asset for {system} {machine}")
    return asset_name(system, arch, kind)


def _openssl(args, data=None):
    try:
        return subprocess.run(
            ["openssl", *args],
            input=data,
            check=True,
            capture_output=True,
        )
    except FileNotFoundError as err:
        raise RuntimeError("openssl is required to sign a fixture release") from err
    except subprocess.CalledProcessError as err:
        detail = (err.stderr or b"").decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "openssl failed") from err


def _pkcs8(seed):
    if len(seed) != 32:
        raise ValueError("an Ed25519 seed is 32 bytes")
    return PKCS8_PREFIX + seed


def _spki(public):
    if len(public) != 32:
        raise ValueError("an Ed25519 public key is 32 bytes")
    return SPKI_PREFIX + public


def public_hex(seed):
    """64 lowercase hex characters for a 32-byte seed."""
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "key.der"
        pub = Path(d) / "pub.der"
        key.write_bytes(_pkcs8(seed))
        _openssl(["pkey", "-in", str(key), "-inform", "DER", "-pubout", "-outform", "DER", "-out", str(pub)])
        raw = pub.read_bytes()
    if not raw.endswith(raw[-32:]) or raw[: len(SPKI_PREFIX)] != SPKI_PREFIX or len(raw) != 44:
        raise RuntimeError("openssl returned a public key that is not an Ed25519 SPKI")
    return raw[-32:].hex()


def keygen():
    """A new throwaway key. The caller decides whether to keep the seed."""
    seed = os.urandom(32)
    return Key(seed, public_hex(seed))


def sign_bytes(seed, message):
    """Raw 64-byte Ed25519 signature of message. Pure Ed25519, no prehash."""
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "key.der"
        msg = Path(d) / "msg"
        sig = Path(d) / "sig"
        key.write_bytes(_pkcs8(seed))
        msg.write_bytes(message)
        _openssl(["pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-keyform", "DER", "-in", str(msg), "-out", str(sig)])
        raw = sig.read_bytes()
    if len(raw) != 64:
        raise RuntimeError(f"signature is {len(raw)} bytes, not 64")
    return raw


def verify_bytes(public_hex_text, message, signature):
    """True when signature is the Ed25519 signature of message under the public key."""
    public = bytes.fromhex(public_hex_text)
    with tempfile.TemporaryDirectory() as d:
        pub = Path(d) / "pub.der"
        msg = Path(d) / "msg"
        sig = Path(d) / "sig"
        pub.write_bytes(_spki(public))
        msg.write_bytes(message)
        sig.write_bytes(signature)
        try:
            _openssl([
                "pkeyutl", "-verify", "-rawin", "-pubin",
                "-inkey", str(pub), "-keyform", "DER",
                "-in", str(msg), "-sigfile", str(sig),
            ])
        except RuntimeError:
            return False
    return True


def mint_licence(seed, ident, email, scope, features, paid_through, issued):
    """A licence line this seed signs. The payload is the canonical seven keys.

    A release build does not trust a key made here. The line is for a fixture
    whose public half was compiled into that one binary.
    """
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    payload = (
        "{"
        f'"v":1,"id":"{ident}","email":"{email}","scope":"{scope}",'
        f'"features":"{features}","paidThrough":"{paid_through}","issued":"{issued}"'
        "}"
    ).encode("ascii")
    body = b"leita." + base64.b64encode(payload)
    sig = sign_bytes(seed, body)
    return (body + b"." + base64.b64encode(sig)).decode("ascii")


def _sha256_line(name, data):
    digest = hashlib.sha256(data).hexdigest()
    return f"{digest}  {name}\n"


def write_release(directory, files, version, released, seed, bad_hash=False, bad_sig=False, omit_sig=False, omit_released=False, tamper_released=False):
    """Write a release directory. files maps a file name to bytes.

    version.txt and released.txt are written before sha256sums.txt. The
    signature is of those exact sum bytes and is not itself listed.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        if not isinstance(data, (bytes, bytearray)):
            raise TypeError(f"{name} must be bytes")
        (directory / name).write_bytes(data)
    version_text = version if version.endswith("\n") else version + "\n"
    (directory / VERSION_NAME).write_text(version_text, encoding="ascii")
    listed = dict(files)
    listed[VERSION_NAME] = version_text.encode("ascii")
    if not omit_released:
        released_text = released if released.endswith("\n") else released + "\n"
        if len(released_text.encode("ascii")) != 21:
            raise ValueError("released.txt is the 20-character instant and one LF")
        (directory / RELEASED_NAME).write_text(released_text, encoding="ascii")
        listed[RELEASED_NAME] = released_text.encode("ascii")
    lines = [_sha256_line(name, listed[name]) for name in sorted(listed)]
    if bad_hash:
        # The sums still name each shipped file, under a hash it does not have.
        # version.txt and released.txt keep the hashes of the bytes just written.
        shipped = set(files)
        rewritten = []
        for line in lines:
            name = line.split("  ", 1)[1].strip()
            if name in shipped:
                rewritten.append(f"{'0' * 64}  {name}\n")
            else:
                rewritten.append(line)
        lines = rewritten
    sums = "".join(lines).encode("ascii")
    (directory / SUMS_NAME).write_bytes(sums)
    if not omit_sig:
        sig = sign_bytes(seed, sums)
        if bad_sig:
            flipped = bytearray(sig)
            flipped[0] ^= 0x01
            sig = bytes(flipped)
        (directory / SIG_NAME).write_bytes(sig)
    if tamper_released and not omit_released:
        path = directory / RELEASED_NAME
        body = bytearray(path.read_bytes())
        body[0] ^= 0x01
        path.write_bytes(body)
    return directory


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split("?", 1)[0].lstrip("/")
        self.server.seen.append({"path": name, "user_agent": self.headers.get("User-Agent", "")})
        path = Path(self.server.directory) / name
        if name in self.server.stall:
            if not path.is_file():
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "100000000")
            self.end_headers()
            try:
                self.wfile.write(path.read_bytes()[:64])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            # The client is killed by the harness. A short wait is enough
            # for it to observe an unfinished body if it is not killed.
            import time
            time.sleep(self.server.stall_seconds)
            return
        if not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


class ReleaseServer:
    """Loopback HTTP for one release directory. Not a production host.

    Use as a context manager. url has no trailing slash. requests lists
    each GET as {path, user_agent}. stall is a set of file names whose body
    is never finished.
    """

    def __init__(self, directory, stall=(), stall_seconds=30):
        self.directory = str(directory)
        self.stall = set(stall)
        self.stall_seconds = stall_seconds
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self._httpd.directory = self.directory
        self._httpd.seen = []
        self._httpd.stall = self.stall
        self._httpd.stall_seconds = stall_seconds
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    @property
    def url(self):
        host, port = self._httpd.server_address
        return f"http://{host}:{port}"

    @property
    def requests(self):
        return list(self._httpd.seen)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        self._httpd.shutdown()
        self._httpd.server_close()


def _hex64(text, name):
    text = text.strip().lower()
    if len(text) != 64 or any(c not in "0123456789abcdef" for c in text):
        raise SystemExit(f"{name} must be 64 hex characters")
    return text


def main(argv):
    parser = argparse.ArgumentParser(description="throwaway Ed25519 release fixture")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("keygen")
    public = sub.add_parser("public")
    public.add_argument("--seed-hex", required=True)
    sign = sub.add_parser("sign")
    sign.add_argument("--seed-hex", required=True)
    sign.add_argument("--in", dest="src", required=True)
    sign.add_argument("--out", dest="dst", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--public-hex", required=True)
    verify.add_argument("--in", dest="src", required=True)
    verify.add_argument("--sig", required=True)
    args = parser.parse_args(argv[1:])
    if args.cmd == "keygen":
        key = keygen()
        json.dump({"seed_hex": key.seed.hex(), "public_hex": key.public_hex}, sys.stdout)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "public":
        sys.stdout.write(public_hex(_hex64(args.seed_hex, "seed")) + "\n")
        return 0
    if args.cmd == "sign":
        seed = _hex64(args.seed_hex, "seed")
        message = Path(args.src).read_bytes()
        Path(args.dst).write_bytes(sign_bytes(seed, message))
        return 0
    if args.cmd == "verify":
        message = Path(args.src).read_bytes()
        signature = Path(args.sig).read_bytes()
        ok = verify_bytes(_hex64(args.public_hex, "public key"), message, signature)
        if not ok:
            print("signature does not verify", file=sys.stderr)
            return 1
        return 0
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (ValueError, RuntimeError, OSError) as err:
        print(err, file=sys.stderr)
        sys.exit(1)
