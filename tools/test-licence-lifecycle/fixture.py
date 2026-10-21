# Throwaway Ed25519 keys and a local activation server for licence tests.
# A fixture signature is not a production signature. No production seed is
# read, and this module does not call mordaunt.dev. The release directory
# layout matches the lifecycle contract: version.txt, released.txt, then
# sha256sums.txt, then sha256sums.txt.sig of those exact sum bytes. The
# signature is not a line of the sums.

import base64
import hashlib
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

SUMS_NAME = "sha256sums.txt"
SIG_NAME = "sha256sums.txt.sig"
VERSION_NAME = "version.txt"


def _declared_string(relpath, const):
    """The string an Odin declaration already owns. This file does not restate it."""
    path = Path(__file__).resolve().parents[2] / relpath
    text = path.read_text(encoding="utf-8")
    needle = f'{const} :: "'
    at = text.find(needle)
    if at < 0:
        raise RuntimeError(f"{const} is not a string declaration in {path}")
    start = at + len(needle)
    end = text.find('"', start)
    if end <= start:
        raise RuntimeError(f"{const} has no string value in {path}")
    return text[start:end]


# update/update.odin owns this filename.
RELEASED_NAME = _declared_string("update/update.odin", "RELEASED_FILE")

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

UNKNOWN = {
    "error": "unknown",
    "message": "This licence key is not one the shop sold.",
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


def host_os():
    plat = sys.platform
    if plat.startswith("linux"):
        return "linux"
    if plat == "darwin":
        return "darwin"
    if plat.startswith("win"):
        return "windows"
    raise ValueError(f"no fixture for {plat}")


def host_arch():
    if host_os() == "darwin":
        return "universal"
    if host_os() == "windows":
        machine = os.environ.get("PROCESSOR_ARCHITECTURE", "")
    else:
        machine = os.uname().machine
    arch = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "AMD64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "ARM64": "arm64",
    }.get(machine)
    if arch is None:
        raise ValueError(f"no release asset for {machine}")
    return arch


def host_asset(kind="window"):
    """Release file name for this machine. kind is command or window."""
    name = ASSETS.get((host_os(), host_arch(), kind))
    if name is None:
        raise ValueError(f"no release asset for {host_os()} {kind}")
    return name


def run_openssl(args, data=None):
    try:
        return subprocess.run(
            ["openssl", *args],
            input=data,
            check=True,
            capture_output=True,
        )
    except FileNotFoundError as err:
        raise RuntimeError("openssl is required to sign a fixture") from err
    except subprocess.CalledProcessError as err:
        detail = (err.stderr or b"").decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "openssl failed") from err


def public_hex(seed):
    """64 lowercase hex characters for a 32-byte seed."""
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "key.der"
        pub = Path(d) / "pub.der"
        key.write_bytes(PKCS8_PREFIX + seed)
        run_openssl(["pkey", "-in", str(key), "-inform", "DER", "-pubout", "-outform", "DER", "-out", str(pub)])
        raw = pub.read_bytes()
    if raw[: len(SPKI_PREFIX)] != SPKI_PREFIX or len(raw) != 44:
        raise RuntimeError("openssl returned a public key that is not an Ed25519 SPKI")
    return raw[-32:].hex()


def keygen():
    """A new throwaway key. The caller must not store the seed."""
    seed = os.urandom(32)
    return Key(seed, public_hex(seed))


def verify_bytes(public_hex_text, message, signature):
    """True when signature is the raw Ed25519 signature of message."""
    public = bytes.fromhex(public_hex_text)
    with tempfile.TemporaryDirectory() as d:
        pub = Path(d) / "pub.der"
        msg = Path(d) / "msg"
        sig = Path(d) / "sig"
        pub.write_bytes(SPKI_PREFIX + public)
        msg.write_bytes(message)
        sig.write_bytes(signature)
        try:
            run_openssl([
                "pkeyutl", "-verify", "-rawin", "-pubin",
                "-inkey", str(pub), "-keyform", "DER",
                "-in", str(msg), "-sigfile", str(sig),
            ])
        except RuntimeError:
            return False
    return True


def sign_bytes(seed, message):
    """Raw 64-byte Ed25519 signature. Pure Ed25519, no prehash."""
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "key.der"
        msg = Path(d) / "msg"
        sig = Path(d) / "sig"
        key.write_bytes(PKCS8_PREFIX + seed)
        msg.write_bytes(message)
        run_openssl(["pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-keyform", "DER", "-in", str(msg), "-out", str(sig)])
        raw = sig.read_bytes()
    if len(raw) != 64:
        raise RuntimeError(f"signature is {len(raw)} bytes, not 64")
    return raw


def mint_licence(seed, ident, email, scope, features, paid_through, issued):
    """A licence line this seed signs. The payload is the canonical seven keys."""
    if isinstance(seed, str):
        seed = bytes.fromhex(seed)
    payload = (
        "{"
        f'"v":1,"id":"{ident}","email":"{email}","scope":"{scope}",'
        f'"features":"{features}","paidThrough":"{paid_through}","issued":"{issued}"'
        "}"
    ).encode("ascii")
    body = b"leita." + base64.b64encode(payload)
    return (body + b"." + base64.b64encode(sign_bytes(seed, body))).decode("ascii")


def tamper_line(line):
    """A line whose signature bytes no longer match. The text still looks like one."""
    head, _, sig = line.rpartition(".")
    raw = bytearray(base64.b64decode(sig))
    raw[0] ^= 0x01
    return head + "." + base64.b64encode(bytes(raw)).decode("ascii")


def _sha256_line(name, data):
    return f"{hashlib.sha256(data).hexdigest()}  {name}\n"


def write_release(directory, files, version, released, seed):
    """Write a signed release directory. files maps a file name to bytes."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        if not isinstance(data, (bytes, bytearray)):
            raise TypeError(f"{name} must be bytes")
        (directory / name).write_bytes(data)
    version_text = version if version.endswith("\n") else version + "\n"
    released_text = released if str(released).endswith("\n") else released + "\n"
    if len(released_text.encode("ascii")) != 21:
        raise ValueError("released.txt is the 20-character instant and one LF")
    # The sums hash these LF bytes. write_bytes stores them unchanged.
    (directory / VERSION_NAME).write_bytes(version_text.encode("ascii"))
    (directory / RELEASED_NAME).write_bytes(released_text.encode("ascii"))
    listed = dict(files)
    listed[VERSION_NAME] = version_text.encode("ascii")
    listed[RELEASED_NAME] = released_text.encode("ascii")
    sums = "".join(_sha256_line(name, listed[name]) for name in sorted(listed)).encode("ascii")
    (directory / SUMS_NAME).write_bytes(sums)
    (directory / SIG_NAME).write_bytes(sign_bytes(seed, sums))
    return directory


class _QuietHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class _Activation(_QuietHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length)
        key = ""
        try:
            key = json.loads(raw.decode("utf-8")).get("key", "")
        except (UnicodeError, json.JSONDecodeError, AttributeError):
            key = ""
        shop = self.server.shop
        shop.seen.append({
            "key": key,
            "path": self.path,
            "user_agent": self.headers.get("User-Agent", ""),
        })
        if key in shop.stall:
            end = time.time() + shop.stall_seconds
            while time.time() < end and not shop.stop:
                time.sleep(0.2)
            return
        if key in shop.replies:
            status, body = shop.replies[key]
            self._send(status, json.dumps(body))
            return
        if key in shop.lines:
            self._send(200, json.dumps({"licence": shop.lines[key]}))
            return
        self._send(404, json.dumps(shop.unknown))


class Shop:
    """What the local activation server will answer. Not a production ledger."""

    def __init__(self):
        self.lines = {}
        self.replies = {}
        self.stall = set()
        self.stall_seconds = 45
        self.stop = False
        self.unknown = dict(UNKNOWN)
        self.seen = []


class ActivationServer:
    """Loopback HTTP for POST /activate. Use as a context manager."""

    def __init__(self, shop):
        self.shop = shop
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Activation)
        self._httpd.shop = shop
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    @property
    def url(self):
        host, port = self._httpd.server_address
        return f"http://{host}:{port}/activate"

    def __enter__(self):
        self._thread.start()
        _wait_until_listening(self._httpd)
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        # A stalled exchange sleeps in the handler. Wake it before shutdown so
        # a 30s client timeout does not hold this process for the rest of the stall.
        self.shop.stop = True
        self._httpd.shutdown()
        self._httpd.server_close()


class _Release(_QuietHandler):
    def do_GET(self):
        name = self.path.split("?", 1)[0].lstrip("/")
        self.server.seen.append({"path": name, "user_agent": self.headers.get("User-Agent", "")})
        if self.server.delay:
            time.sleep(self.server.delay)
        path = Path(self.server.directory) / name
        if not path.is_file():
            self.send_error(404)
            return
        self._send(200, path.read_bytes(), "application/octet-stream")


class ReleaseServer:
    """Loopback HTTP for one release directory. url has no trailing slash."""

    def __init__(self, directory, delay=0):
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Release)
        self._httpd.directory = str(directory)
        self._httpd.seen = []
        self._httpd.delay = delay
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
        _wait_until_listening(self._httpd)
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        self._httpd.shutdown()
        self._httpd.server_close()


def _wait_until_listening(httpd):
    """Return once a loopback connect reaches the server, or raise."""
    deadline = time.time() + 2
    last = None
    while time.time() < deadline:
        try:
            with socket.create_connection(httpd.server_address, timeout=0.2):
                return
        except OSError as err:
            last = err
            time.sleep(0.02)
    raise RuntimeError(f"fixture server did not listen: {last}")
