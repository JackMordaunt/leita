# Drive the real headless app.Host. State comes from files, commands and HTTP.
# Nothing here injects a licence or update answer into the view.

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# The capture suite already names the repository root.
_capture = Path(__file__).resolve().parents[1] / "capture"
if str(_capture) not in sys.path:
    sys.path.insert(0, str(_capture))
from suite import ROOT

PAID_THROUGH = "2027-01-01T00:00:00Z"
ISSUED = "2026-10-19T12:00:00Z"
ELIGIBLE_RELEASED = "2027-01-01T00:00:00Z"
LATER_RELEASED = "2027-01-01T00:00:01Z"
EMAIL = "ada@example.com"
ORDER = "ord_fixture"
SCOPE = "personal"

LICENSED = f"Licensed to {EMAIL}"
NOT_SIGNED = "The licence is not one Librium signed, or has been changed."
UNKNOWN_KEY = "This licence key is not one the shop sold."
UNREACHABLE = "Leita could not reach the licence server. Check the connection, or open the licence file from your receipt instead."
SERVER_BUSY = "The licence server could not answer just now; try again later."
SERVER_SLOW = "The licence server did not answer in time; try again."
REPORTS_LOCKED = "PDF and HTML reports need a licence now the 30-day Pro evaluation has ended. A CSV or JSON of this scan is still free."
TRIAL_OVER = "Your 30-day Pro evaluation has ended"
CHECKING = "Checking for updates…"
UPDATE_PRIVACY = "Only when you click, Leita asks GitHub for the latest release. Nothing about you or your disks is sent."
UPDATE_UNREACHABLE = "Leita could not reach the release page. Check the connection."


def system_name():
    plat = sys.platform
    if plat.startswith("linux"):
        return "linux"
    if plat == "darwin":
        return "darwin"
    if plat.startswith("win"):
        return "windows"
    raise RuntimeError(f"unsupported os {plat}")


def jm_path():
    return os.environ.get("JM") or str(ROOT / "jm")


def trial_over_stamp():
    return int(time.time()) - 40 * 24 * 60 * 60


def prepare_data(path, line="", receipt=""):
    """An isolated data directory whose trial is already over."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    (path / "first-use").write_text(f"{trial_over_stamp()}\n", encoding="ascii")
    if line:
        text = line if line.endswith("\n") else line + "\n"
        licence = path / "licence"
        licence.write_text(text, encoding="ascii")
        os.chmod(licence, 0o600)
    if receipt:
        key = path / "licence-key"
        key.write_text(receipt if receipt.endswith("\n") else receipt + "\n", encoding="ascii")
        os.chmod(key, 0o600)
    return path


def make_target(path):
    """A few generated files so the scan has something real to draw. Not a home directory."""
    path = Path(path)
    (path / "src").mkdir(parents=True, exist_ok=True)
    (path / "README.txt").write_text("Example project for a headless capture.\n", encoding="ascii")
    (path / "src" / "main.c").write_text("int main(void) { return 0; }\n", encoding="ascii")
    return path


def base_env(data_home):
    """A process environment that cannot see this machine's own Leita data."""
    env = os.environ.copy()
    for name in (
        "LEITA_LICENCE",
        "LEITA_ACTIVATE_URL",
        "LEITA_RELEASE_BASE",
        "LEITA_UPDATE_SEED",
        "LEITA_BUY_URL",
        "LEITA_COLOR",
        "APPIMAGE",
    ):
        env.pop(name, None)
    home = str(data_home)
    env["XDG_DATA_HOME"] = home
    env["XDG_CONFIG_HOME"] = home
    env["LOCALAPPDATA"] = home
    if system_name() == "darwin":
        env["HOME"] = home
    env["LEITA_COLOR"] = "never"
    return env


def run_capture(binary, target, data, theme, steps, env, timeout):
    """Run the headless host. Non-zero exits raise, with the tags it printed."""
    cmd = [str(binary), str(target), str(data), theme, *steps]
    proc = subprocess.run(
        cmd,
        env=env,
        timeout=timeout,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = "\n".join(part.strip() for part in (proc.stderr, proc.stdout) if part and part.strip())
        raise RuntimeError(detail or f"capture exited {proc.returncode}")
    return proc


def odin_build(package, dest, defines):
    """Build one package the way the capture driver is built: minimal, vetted."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        os.environ.get("ODIN", "odin"),
        "build",
        package,
        "-o:minimal",
        "-vet",
        "-strict-style",
        f"-collection:jm={jm_path()}",
        "-define:LEITA_VERSION=v0.1.0",
        "-define:LEITA_SHORT=le",
        "-define:LEITA_YEAR=2026",
    ]
    system = system_name()
    if system == "linux":
        cmd.append("-define:JM_HTTP_DLOPEN=true")
    if system == "darwin":
        cmd.append("-minimum-os-version:11.0")
    cmd.extend(defines)
    cmd.append(f"-out:{dest}")
    subprocess.run(cmd, cwd=ROOT, check=True)


def build_capture(dest, licence_keys, update_key, released):
    """Build tools/capture with throwaway public keys compiled in."""
    env = os.environ.copy()
    env["JM"] = jm_path()
    env["LEITA_VERSION"] = "v0.1.0"
    env["LEITA_YEAR"] = "2026"
    env["LEITA_LICENCE_KEY"] = licence_keys
    env["LEITA_UPDATE_KEY"] = update_key
    env["LEITA_RELEASED"] = released
    env["CAPTURE_OUT"] = str(dest)
    script = "tools/capture/build"
    command = ["bash", script] if os.name == "nt" else [script]
    subprocess.run(command, cwd=ROOT, env=env, check=True)


def build_cli(dest, licence_keys, released):
    odin_build(
        "cmd/cli",
        dest,
        [
            f"-define:LEITA_LICENCE_KEY={licence_keys}",
            f"-define:LEITA_RELEASED={released}",
        ],
    )


def ensure_sqlite():
    subprocess.run(["just", "sqlite"], cwd=ROOT, env={**os.environ, "JM": jm_path()}, check=True)


def read_text(path):
    return Path(path).read_text(encoding="ascii")


def copy_exe(src, dest):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    dest.chmod(0o755)
    return dest


def exe_name():
    return "leita.exe" if os.name == "nt" else "leita"


def cli_licence_file(data_home):
    """Where `leita licence` keeps the line for this data home."""
    root = Path(data_home)
    if system_name() == "darwin":
        folder = root / "Library" / "Application Support" / "leita"
    else:
        folder = root / "leita"
    return folder / "licence"


def run_host(binary, work, steps, activate, release, theme="light", timeout=90, extra=None, copy=False, line="", receipt="", fresh=True):
    """Run one headless host. fresh rewrites first-use and, when given, the line."""
    work = Path(work)
    data = prepare_data(work / "data", line if fresh else "", receipt if fresh else "")
    if not fresh:
        data.mkdir(parents=True, exist_ok=True)
    target = make_target(work / "target")
    home = work / "home"
    home.mkdir(parents=True, exist_ok=True)
    env = base_env(home)
    env["LEITA_ACTIVATE_URL"] = activate
    env["LEITA_RELEASE_BASE"] = release
    if extra:
        env.update(extra)
    binary_path = copy_exe(binary, work / "copied" / exe_name()) if copy else Path(binary)
    proc = run_capture(binary_path, target, data, theme, list(steps), env, timeout)
    return proc, data, binary_path


def run_cli(binary, args, env, timeout=60):
    return subprocess.run(
        [str(binary), *args],
        env=env,
        timeout=timeout,
        capture_output=True,
        text=True,
    )


def make_work(prefix):
    return Path(tempfile.mkdtemp(prefix=prefix))


def stored_text(path):
    file = Path(path)
    if not file.exists():
        return ""
    return file.read_text(encoding="ascii").strip()
