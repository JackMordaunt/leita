# Native lifecycle evidence for one operating system.
#
# Writes build/lifecycle/evidence-update.json and nothing else. Licence
# activation and the scheduler write their own evidence-*.json beside it;
# gate.py merges them. A missing sibling case fails the gate. This file
# does not mark those cases, and it does not read LEITA_UPDATE_SEED.

import gzip
import io
import lzma
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path

import fixture
import gate

ROOT = Path(__file__).resolve().parents[2]
STAMP = "2026-10-21T00:00:00Z"
OLD_VERSION = "v0.0.1"
NEW_VERSION = "v0.0.2"

# Written by the licence harness and the scheduler harness, not this one.
SIBLING = frozenset({
    "activation_http",
    "receipt_recovery",
    "automatic_startup_check",
    "automatic_daily_check",
})

# A host that already has these is left alone. The namespace cases mount a
# tmpfs over the path instead of writing the host copy.
HOST_RECORDER = Path("/usr/local/libexec/leita/leita")
HOST_STATE = Path("/var/lib/leita")


def system_name():
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("win"):
        return "windows"
    raise RuntimeError(f"lifecycle harness has no operating system name for {sys.platform}")


def exe_name():
    return "leita.exe" if os.name == "nt" else "leita"


def gui_name():
    return "Leita.exe" if os.name == "nt" else "Leita"


def git_sha():
    out = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True)
    return out.strip()


def just_value(name):
    out = subprocess.check_output(["just", "--evaluate", name], cwd=ROOT, text=True)
    return out.strip()


def tail(text, limit=1200):
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[-limit:]


def record(results, case_id, ok, detail):
    results[case_id] = {
        "id": case_id,
        "status": "pass" if ok else "fail",
        "detail": " ".join(detail.split()),
    }


def emit(directory, sha, system, results, unfinished=""):
    cases = []
    for case_id, platforms in gate.REQUIRED.items():
        if case_id in SIBLING:
            continue
        if system not in platforms:
            cases.append({
                "id": case_id,
                "status": "na",
                "detail": "not this operating system",
            })
            continue
        got = results.get(case_id)
        if got is None:
            cases.append({
                "id": case_id,
                "status": "fail",
                "detail": unfinished or "the harness did not run this case",
            })
        else:
            cases.append(got)
    document = {
        "schema": 1,
        "producer": "update",
        "sha": sha,
        "os": system,
        "production_signature": False,
        "fixture": "throwaway-ed25519",
        "cases": cases,
    }
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "evidence-update.json"
    import json
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return path


def build_env(version, licence_key, update_key, released):
    env = os.environ.copy()
    # A fixture build never takes the production update seed, even if a
    # shell exported it.
    env.pop("LEITA_UPDATE_SEED", None)
    env["LEITA_VERSION"] = version
    env["LEITA_LICENCE_KEY"] = licence_key
    env["LEITA_UPDATE_KEY"] = update_key
    if released:
        env["LEITA_RELEASED"] = released
    else:
        env.pop("LEITA_RELEASED", None)
    return env


def build_cli(dest, version, licence_key, update_key, released):
    env = build_env(version, licence_key, update_key, released)
    proc = subprocess.run(
        ["just", "cli", "release"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=900,
    )
    if proc.returncode != 0:
        raise RuntimeError(tail(proc.stdout + "\n" + proc.stderr))
    src = ROOT / "build" / "release" / exe_name()
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    dest.chmod(0o755)
    return dest


def child_env(work, extra=None):
    data = work / "data"
    home = work / "home"
    data.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": str(home),
        "USERPROFILE": str(home),
        "XDG_DATA_HOME": str(data),
        "LOCALAPPDATA": str(data),
        "LEITA_COLOR": "never",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    if os.environ.get("SYSTEMROOT"):
        env["SYSTEMROOT"] = os.environ["SYSTEMROOT"]
    if extra:
        env.update(extra)
    env.pop("LEITA_UPDATE_SEED", None)
    env.pop("LEITA_LICENCE_KEY", None)
    folder = data / "leita"
    if system_name() == "darwin":
        folder = home / "Library" / "Application Support" / "leita"
    return env, folder


def invoke(binary, args, env, timeout=90):
    proc = subprocess.run(
        [str(binary), *args],
        env=env,
        capture_output=True,
        timeout=timeout,
    )
    return (
        proc.returncode,
        proc.stdout.decode("utf-8", "replace"),
        proc.stderr.decode("utf-8", "replace"),
    )


def place(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        dest.unlink()
    shutil.copy2(src, dest)
    dest.chmod(0o755)
    return dest


def release_dir(work, asset, payload, version, seed, **flags):
    directory = work / "release"
    if directory.exists():
        shutil.rmtree(directory)
    fixture.write_release(
        directory,
        {asset: payload},
        version=version,
        released=STAMP,
        seed=seed,
        **flags,
    )
    return directory


def guard(results, case_id, fn):
    try:
        ok, detail = fn()
    except Exception as err:
        ok, detail = False, f"{type(err).__name__}: {err}"
    record(results, case_id, ok, detail)


def licence_cases(results, old, new, test_line, rotation_line, early_line, update_key):
    def persisted_and_offline():
        work = Path(tempfile.mkdtemp(prefix="lic-"))
        try:
            env, folder = child_env(work)
            code, out, err = invoke(old, ["licence", "add", test_line], env)
            if code != 0:
                return False, f"add exited {code}: {err or out}"
            kept = folder / "licence"
            if not kept.is_file() or test_line not in kept.read_text(encoding="utf-8"):
                return False, "the licence file is not beside the history store"
            with fixture.ReleaseServer(work) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                code, out, err = invoke(old, ["licence"], env)
                requested = server.requests
            if code != 0 or "this release is included" not in out:
                return False, f"offline show exited {code}: {out} {err}"
            if requested:
                return False, "showing the kept licence contacted the release"
            record(results, "licence_persisted", True, "leita licence add wrote the line beside the history store")
            record(results, "licence_offline", True, "a second run showed Pro with no release request")
            # Tamper the kept file. Show must fail and must not rewrite it.
            raw = bytearray(kept.read_bytes())
            raw[-2] ^= 0x01
            kept.write_bytes(raw)
            tampered = kept.read_bytes()
            with fixture.ReleaseServer(work) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                code, out, err = invoke(old, ["licence"], env)
                requested = server.requests
            if code == 0 or "the licence kept here does not hold" not in err:
                return False, f"tampered show exited {code}: {err or out}"
            if kept.read_bytes() != tampered:
                return False, "the tampered licence was rewritten"
            if requested:
                return False, "a tampered licence triggered a release or activation request"
            record(results, "licence_tampered", True, "a changed line is refused")
            record(results, "cli_tampered_no_recovery", True, "the command line left the tampered line in place and sent nothing")
            return True, "kept"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    # persisted_and_offline records four cases itself. The wrapper records a
    # failure on the first of them only when the setup itself fails early.
    try:
        ok, detail = persisted_and_offline()
    except Exception as err:
        ok, detail = False, f"{type(err).__name__}: {err}"
    if not ok:
        for case_id in (
            "licence_persisted",
            "licence_offline",
            "licence_tampered",
            "cli_tampered_no_recovery",
        ):
            results.setdefault(case_id, {"id": case_id, "status": "fail", "detail": detail})

    def rotation_kept():
        work = Path(tempfile.mkdtemp(prefix="rot-"))
        try:
            env, _folder = child_env(work)
            code, out, err = invoke(old, ["licence", "add", rotation_line], env)
            if code != 0:
                return False, f"the binary that still has the key rejected it: {err or out}"
            return True, "the previous binary still accepts a line signed by the key it carries"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def rotation_dropped():
        work = Path(tempfile.mkdtemp(prefix="drop-"))
        try:
            env, folder = child_env(work)
            code, _out, err = invoke(new, ["licence", "add", rotation_line], env)
            if code == 0:
                return False, "the new binary accepted a line whose key it no longer has"
            if "it is not a licence Librium signed, or it has been changed" not in err:
                return False, err or "the refusal did not name the signature"
            if (folder / "licence").exists():
                return False, "a rejected line was written"
            return True, "the new binary refuses the line and keeps nothing"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def pro_before():
        work = Path(tempfile.mkdtemp(prefix="pro-"))
        try:
            env, _folder = child_env(work)
            env["LEITA_LICENCE"] = test_line
            code, out, err = invoke(old, ["licence"], env)
            if code != 0 or "this release is included" not in out:
                return False, f"{out} {err}".strip()
            return True, "paid-through 9999 covers this stamp"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def pro_after():
        work = Path(tempfile.mkdtemp(prefix="after-"))
        try:
            env, _folder = child_env(work)
            env["LEITA_LICENCE"] = early_line
            code, out, err = invoke(old, ["licence"], env)
            if code != 0 or "after the paid-through date" not in out:
                return False, f"{out} {err}".strip()
            return True, "a 2020 paid-through date does not cover this stamp"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def not_a_key():
        work = Path(tempfile.mkdtemp(prefix="key-"))
        try:
            env, folder = child_env(work)
            code, _out, err = invoke(old, ["licence", "add", update_key], env)
            if code == 0 or "that is not a licence" not in err:
                return False, err or "a bare key was accepted"
            if (folder / "licence").exists():
                return False, "a bare key was stored"
            return True, "the command line does not activate a key"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    guard(results, "licence_rotation_retained_key", rotation_kept)
    guard(results, "licence_rotation_dropped_key", rotation_dropped)
    guard(results, "licence_pro_before_cutoff", pro_before)
    guard(results, "licence_pro_after_cutoff", pro_after)
    guard(results, "cli_key_not_activated", not_a_key)


def assert_unchanged(binary, before, code, err, needle):
    after = binary.read_bytes()
    if after != before:
        return False, "the executable bytes changed"
    if code == 0:
        return False, "the command exited 0"
    if needle and needle not in err and needle not in (err + " "):
        return False, tail(err) or "the refusal text was not what this install produces"
    return True, tail(err) or "refused"


def update_cases(results, old, new, dev, seed, asset, test_line, update_key):
    new_bytes = new.read_bytes()
    old_bytes = old.read_bytes()

    def check_newer():
        work = Path(tempfile.mkdtemp(prefix="check-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, out, err = invoke(binary, ["update", "--check"], env)
            if binary.read_bytes() != before:
                return False, "check replaced the executable"
            if code != 2 or "a newer leita is out" not in out:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "check reported a newer release and left the file"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def user_agent():
        work = Path(tempfile.mkdtemp(prefix="ua-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            env, _folder = child_env(work)
            with fixture.ReleaseServer(directory) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                code, out, err = invoke(binary, ["update", "--check"], env)
                seen = server.requests
            if not seen:
                return False, tail(err) or "no request was recorded"
            agents = {item["user_agent"] for item in seen}
            if agents != {f"leita/{OLD_VERSION}"}:
                return False, f"user agents were {sorted(agents)}"
            if code != 2:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "each request was GET with User-Agent leita/v0.0.1"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def check_single():
        work = Path(tempfile.mkdtemp(prefix="single-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            with fixture.ReleaseServer(directory) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                code, _out, err = invoke(binary, ["update", "--check"], env)
                seen = [item["path"] for item in server.requests]
            if binary.read_bytes() != before:
                return False, "check replaced the executable"
            if code != 2:
                return False, tail(err) or f"exit {code}"
            if asset in seen:
                return False, "check downloaded the asset"
            if fixture.SUMS_NAME not in seen:
                return False, f"check did not fetch the sums: {seen}"
            return True, "one check fetched the sums and not the asset, and left the executable"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def startup_quiet():
        work = Path(tempfile.mkdtemp(prefix="quiet-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            env, _folder = child_env(work)
            with fixture.ReleaseServer(directory) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                invoke(old, ["--version"], env)
                invoke(old, ["licence"], env)
                seen = server.requests
            if seen:
                return False, "a command other than update contacted the release: " + ", ".join(item["path"] for item in seen)
            return True, "version and licence sent no release request"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def apply_and_keep(case_apply, case_old, case_data, case_pro):
        work = Path(tempfile.mkdtemp(prefix="apply-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, folder = child_env(work)
            folder.mkdir(parents=True, exist_ok=True)
            marker = folder / "marker"
            marker.write_text("keep-me", encoding="ascii")
            (folder / "licence").write_text(test_line + "\n", encoding="ascii")
            licence_before = (folder / "licence").read_bytes()
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, out, err = invoke(binary, ["update"], env)
            if code != 0 or binary.read_bytes() != new_bytes:
                record(results, case_apply, False, f"exit {code}: {out} {err}".strip())
                record(results, case_old, False, "the update did not replace the executable")
                record(results, case_data, False, "there was no successful replace to compare data against")
                record(results, case_pro, False, "there was no successful replace to show the licence after")
                return
            code2, out2, err2 = invoke(binary, ["--version"], env)
            if code2 != 0 or NEW_VERSION not in out2:
                record(results, case_apply, False, f"relaunch said {out2} {err2}".strip())
            else:
                record(results, case_apply, True, "the replaced file runs and names the new version")
            old_path = Path(str(binary) + ".old")
            if not old_path.is_file() or old_path.read_bytes() != before:
                record(results, case_old, False, "the previous bytes are not in the .old file")
            else:
                record(results, case_old, True, "the previous executable is the .old file")
            if marker.read_text(encoding="ascii") != "keep-me" or (folder / "licence").read_bytes() != licence_before:
                record(results, case_data, False, "user data changed during the replace")
            else:
                record(results, case_data, True, "the marker and the licence file were not part of the swap")
            code3, out3, err3 = invoke(binary, ["licence"], env)
            if code3 != 0 or "this release is included" not in out3:
                record(results, case_pro, False, f"{out3} {err3}".strip())
            else:
                record(results, case_pro, True, "the kept licence still covers the replaced build")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def bad_hash():
        work = Path(tempfile.mkdtemp(prefix="hash-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed, bad_hash=True)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, _out, err = invoke(binary, ["update"], env)
            if binary.read_bytes() != before or code == 0:
                return False, f"exit {code}; the executable changed or the command succeeded"
            return True, tail(err) or "a summed hash the file does not have was refused"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def unreachable():
        work = Path(tempfile.mkdtemp(prefix="down-"))
        try:
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = "http://127.0.0.1:9"
            code, _out, err = invoke(binary, ["update", "--check"], env)
            if binary.read_bytes() != before or code == 0:
                return False, "the executable changed or check exited 0"
            if "libcurl is needed" in err:
                return False, "libcurl is missing, so this was not an unreachable host"
            return True, tail(err) or "the closed port was an error and the file stayed"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def permissions():
        work = Path(tempfile.mkdtemp(prefix="perm-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            folder = work / "bin"
            binary = place(old, folder / exe_name())
            before = binary.read_bytes()
            if os.name == "nt":
                user = os.environ.get("USERNAME", "")
                proc = subprocess.run(["icacls", str(folder), "/deny", f"{user}:(W,D)"], capture_output=True, text=True)
                if proc.returncode != 0:
                    return False, tail(proc.stderr) or "icacls could not remove write access"
            else:
                folder.chmod(0o555)
            env, _data = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            try:
                code, _out, err = invoke(binary, ["update"], env)
            finally:
                if os.name != "nt":
                    folder.chmod(0o755)
                else:
                    subprocess.run(["icacls", str(folder), "/remove:d", user], capture_output=True)
            if binary.read_bytes() != before or code == 0:
                return False, "a directory that cannot be written was updated"
            return True, tail(err) or "the unwritable directory was refused"
        finally:
            if os.name != "nt":
                (work / "bin").chmod(0o755)
            shutil.rmtree(work, ignore_errors=True)

    def interrupted():
        work = Path(tempfile.mkdtemp(prefix="stop-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            with fixture.ReleaseServer(directory, stall={asset}, stall_seconds=8) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                proc = subprocess.Popen([str(binary), "update"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                deadline = time.time() + 12
                while time.time() < deadline and proc.poll() is None:
                    if any(item["path"] == asset for item in server.requests):
                        break
                    time.sleep(0.05)
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=10)
                saw_asset = any(item["path"] == asset for item in server.requests)
            if binary.read_bytes() != before:
                return False, "killing the download left a different executable"
            if not saw_asset:
                return False, "the asset download never started, so the interrupt was not exercised"
            return True, "the executable bytes survived a killed download"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def current():
        work = Path(tempfile.mkdtemp(prefix="same-"))
        try:
            directory = release_dir(work, asset, old_bytes, OLD_VERSION, seed)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, out, err = invoke(binary, ["update"], env)
            if binary.read_bytes() != before or code != 0:
                return False, f"exit {code}: {out} {err}".strip()
            if "nothing to do" not in out and "latest" not in out:
                return False, out
            return True, "the same bytes were left in place"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def dev_refused():
        work = Path(tempfile.mkdtemp(prefix="dev-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(dev, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, _out, err = invoke(binary, ["update"], env)
            if binary.read_bytes() != before or code == 0 or "development build" not in err:
                return False, tail(err) or f"exit {code}"
            return True, "a development version refused to replace itself"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def signing():
        present = update_key.lower().encode("ascii") in old.read_bytes().lower()
        work = Path(tempfile.mkdtemp(prefix="sig-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed, bad_sig=True)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, _out, err = invoke(binary, ["update"], env)
            changed = binary.read_bytes() != before
            if not present:
                extra = " the bad signature replaced the executable" if changed or code == 0 else " the executable was unchanged, but the key is not in the binary"
                return False, "LEITA_UPDATE_KEY is not compiled into the binary (update.SIGNING_KEY is still a constant)." + extra
            if changed or code == 0:
                return False, "a bad signature replaced the executable"
            return True, "the compiled key rejected a bad signature"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def ineligible():
        work = Path(tempfile.mkdtemp(prefix="elig-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed, omit_released=True)
            binary = place(old, work / "bin" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_LICENCE"] = test_line
            with fixture.ReleaseServer(directory) as server:
                env["LEITA_RELEASE_BASE"] = server.url
                code, _out, err = invoke(binary, ["update"], env)
                saw_asset = any(item["path"] == asset for item in server.requests)
            if "libcurl is needed" in err:
                return False, "libcurl is missing, so retained-Pro refusal was not reached"
            if binary.read_bytes() != before or code == 0 or saw_asset:
                return False, "retained Pro installed, or downloaded, a release with no authenticated instant: " + tail(err)
            lowered = err.lower()
            # The updater says "still Pro through" and either names the missing
            # instant or the later authenticated instant. It does not say "paid".
            names_hold = "still pro through" in lowered
            names_instant = "no authenticated release instant" in lowered or "was released" in lowered
            if not names_hold or not names_instant:
                return False, "the executable stayed, but the refusal is not the retained-Pro rule: " + tail(err)
            return True, "no asset was downloaded and the executable stayed"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def bundle():
        work = Path(tempfile.mkdtemp(prefix="app-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            if system_name() == "darwin":
                env = build_env(NEW_VERSION, just_value("test_licence_key"), update_key, STAMP)
                proc = subprocess.run(["just", "bundle"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
                app = ROOT / "build" / "release" / "Leita.app" / "Contents" / "Helpers" / "leita"
                if proc.returncode != 0 or not app.is_file():
                    return False, "Leita.app was not built: " + tail(proc.stderr)
                binary = app
            else:
                binary = place(old, work / "Leita.app" / "Contents" / "MacOS" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, _out, err = invoke(binary, ["update"], env)
            return assert_unchanged(binary, before, code, err, "Leita.app")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def installer_path():
        work = Path(tempfile.mkdtemp(prefix="pf-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            binary = place(old, work / "Program Files" / "Leita" / exe_name())
            before = binary.read_bytes()
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, _out, err = invoke(binary, ["update"], env)
            return assert_unchanged(binary, before, code, err, "Program Files")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def symlink_loose():
        work = Path(tempfile.mkdtemp(prefix="link-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            real = place(old, work / "loose" / exe_name())
            link = work / "loose" / ("leita-link" + (".exe" if os.name == "nt" else ""))
            try:
                os.symlink(real, link)
            except OSError as err:
                return False, f"could not create a symlink: {err}"
            env, _folder = child_env(work)
            env["LEITA_RELEASE_BASE"] = str(directory)
            code, out, err = invoke(link, ["update"], env)
            if real.read_bytes() != new_bytes or code != 0:
                return False, f"the real loose file was not replaced (exit {code}): {err or out}"
            return True, "a symlink launch replaced the real loose file and left a package path untouched"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    guard(results, "update_check_newer", check_newer)
    guard(results, "update_user_agent", user_agent)
    guard(results, "update_check_single", check_single)
    guard(results, "startup_has_no_update_request", startup_quiet)
    apply_and_keep(
        "update_apply_relaunch",
        "update_keeps_old",
        "update_preserves_data",
        "update_preserves_pro",
    )
    guard(results, "update_bad_hash", bad_hash)
    guard(results, "update_unreachable", unreachable)
    guard(results, "update_permissions", permissions)
    guard(results, "update_interrupted", interrupted)
    guard(results, "update_current_noop", current)
    guard(results, "update_dev_refused", dev_refused)
    guard(results, "signing_required", signing)
    guard(results, "update_ineligible_needs_consent", ineligible)
    guard(results, "update_bundle_refused", bundle)
    guard(results, "update_installer_path_refused", installer_path)
    guard(results, "update_symlink_loose_follows_real", symlink_loose)


def namespaced(script, env, timeout=60):
    """Run script as root in a private mount namespace. Writes stay on the tmpfs."""
    proc = subprocess.run(
        ["unshare", "--user", "--map-root-user", "--mount", "bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc


def linux_path_cases(results, old, new_bytes, seed, asset):
    if system_name() != "linux":
        return

    def package_refused():
        if not shutil.which("unshare"):
            return False, "unshare is not installed, so a package path was not exercised"
        target = "/usr/libexec" if Path("/usr/libexec").is_dir() else "/usr/share"
        if not Path(target).is_dir():
            return False, "no /usr directory was available to mount a package path over"
        work = Path(tempfile.mkdtemp(prefix="pkg-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            script = r"""
set -eu
mount -t tmpfs tmpfs "$TARGET"
mkdir -p "$TARGET/leita-lifecycle-ci"
cp "$LEITA_BIN" "$TARGET/leita-lifecycle-ci/leita"
chmod 755 "$TARGET/leita-lifecycle-ci/leita"
before=$(sha256sum "$TARGET/leita-lifecycle-ci/leita" | awk '{print $1}')
set +e
"$TARGET/leita-lifecycle-ci/leita" update >"$OUT" 2>"$ERR"
code=$?
set -e
after=$(sha256sum "$TARGET/leita-lifecycle-ci/leita" | awk '{print $1}')
printf 'code=%s\nbefore=%s\nafter=%s\n' "$code" "$before" "$after"
"""
            env, _folder = child_env(work)
            env.update({
                "LEITA_BIN": str(old),
                "LEITA_RELEASE_BASE": str(directory),
                "TARGET": target,
                "OUT": str(work / "out.txt"),
                "ERR": str(work / "err.txt"),
                "LEITA_COLOR": "never",
            })
            proc = namespaced(script, env)
            text = proc.stdout + "\n" + proc.stderr
            err = (work / "err.txt").read_text(encoding="utf-8", errors="replace") if (work / "err.txt").exists() else ""
            if "code=" not in proc.stdout:
                return False, tail(text)
            code_line = [line for line in proc.stdout.splitlines() if line.startswith("code=")][-1]
            before = [line for line in proc.stdout.splitlines() if line.startswith("before=")][-1].split("=", 1)[1]
            after = [line for line in proc.stdout.splitlines() if line.startswith("after=")][-1].split("=", 1)[1]
            code = int(code_line.split("=", 1)[1])
            if before != after or code == 0 or "package manager" not in err:
                return False, tail(err or text)
            return True, "a path under /usr outside /usr/local was left in place"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def journal_path():
        # The host recorder, when it exists, stays on disk. The mount hides
        # that directory inside the namespace, and the writes land on a tmpfs.
        if not shutil.which("unshare"):
            return False, "unshare is not installed, so the journal path was not exercised"
        if not Path("/usr/local/libexec").is_dir():
            return False, "/usr/local/libexec does not exist; creating it would write to this host"
        work = Path(tempfile.mkdtemp(prefix="jpath-"))
        try:
            directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
            script = r"""
set -eu
mount -t tmpfs tmpfs /usr/local/libexec
mkdir -p /usr/local/libexec/leita
cp "$LEITA_BIN" /usr/local/libexec/leita/leita
chmod 755 /usr/local/libexec/leita/leita
before=$(sha256sum /usr/local/libexec/leita/leita | awk '{print $1}')
set +e
/usr/local/libexec/leita/leita update >"$OUT" 2>"$ERR"
code=$?
set -e
after=$(sha256sum /usr/local/libexec/leita/leita | awk '{print $1}')
printf 'code=%s\nbefore=%s\nafter=%s\n' "$code" "$before" "$after"
"""
            env, _folder = child_env(work)
            env.update({
                "LEITA_BIN": str(old),
                "LEITA_RELEASE_BASE": str(directory),
                "OUT": str(work / "out.txt"),
                "ERR": str(work / "err.txt"),
                "LEITA_COLOR": "never",
            })
            proc = namespaced(script, env)
            err = (work / "err.txt").read_text(encoding="utf-8", errors="replace") if (work / "err.txt").exists() else ""
            if "before=" not in proc.stdout:
                return False, tail(proc.stdout + proc.stderr)
            before = [line for line in proc.stdout.splitlines() if line.startswith("before=")][-1].split("=", 1)[1]
            after = [line for line in proc.stdout.splitlines() if line.startswith("after=")][-1].split("=", 1)[1]
            code = int([line for line in proc.stdout.splitlines() if line.startswith("code=")][-1].split("=", 1)[1])
            if before != after or code == 0:
                return False, "the journal recorder path was replaced: " + tail(err)
            if "package manager" in err and "journal" not in err.lower():
                return False, "the path was refused as a package path, not as the journal recorder: " + tail(err)
            # A refusal that only says the directory cannot be written is not
            # the journal rule. The tmpfs is writable by the namespace root,
            # so a replaced file is a miss. An unchanged file whose refusal
            # names the recorder passes.
            if "journal" not in err.lower() and "recorder" not in err.lower():
                return False, "the file was unchanged but the refusal is not the journal recorder: " + tail(err or proc.stderr)
            return True, "the exact recorder path was not replaced"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    guard(results, "update_package_refused", package_refused)
    guard(results, "update_journal_path_not_replaced", journal_path)


def linux_journal_cases(results, old, new_bytes, seed, asset):
    if system_name() != "linux":
        return
    work = Path(tempfile.mkdtemp(prefix="journal-"))
    created_state = False
    try:
        if not shutil.which("unshare"):
            detail = "unshare is not installed, so the recorder was not started"
            for case_id in (
                "linux_journal_alive_across_update",
                "linux_journal_stop",
                "linux_journal_restart",
            ):
                record(results, case_id, False, detail)
            return
        if not HOST_STATE.exists():
            made = subprocess.run(["sudo", "-n", "mkdir", "-p", str(HOST_STATE)], capture_output=True, text=True)
            if made.returncode != 0:
                detail = "passwordless sudo cannot prepare /var/lib/leita, and creating it without sudo would skip the mount"
                for case_id in (
                    "linux_journal_alive_across_update",
                    "linux_journal_stop",
                    "linux_journal_restart",
                ):
                    record(results, case_id, False, detail)
                return
            created_state = True
        directory = release_dir(work, asset, new_bytes, NEW_VERSION, seed)
        loose = place(old, work / "loose" / exe_name())
        script = r"""
set -euo pipefail
mount -t tmpfs tmpfs /var/lib/leita
mkdir -p /var/lib/leita/journal
"$LEITA_BIN" journal run >"$LOG" 2>"$ERR" &
pid=$!
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
  echo journal_exited
  exit 0
fi
echo journal_alive
# A loose copy, not the recorder. The host recorder is not this file.
LEITA_COLOR=never LEITA_RELEASE_BASE="$LEITA_RELEASE_BASE" "$LOOSE" update >"$UPD" 2>"$UPDERR" || true
if kill -0 "$pid" 2>/dev/null; then
  echo journal_survived
else
  echo journal_died
fi
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" || true
if kill -0 "$pid" 2>/dev/null; then
  echo journal_still_running
else
  echo journal_stopped
fi
"$LEITA_BIN" journal run >"$LOG2" 2>"$ERR2" &
pid2=$!
sleep 1
if kill -0 "$pid2" 2>/dev/null; then
  echo journal_restarted
  kill -TERM "$pid2" 2>/dev/null || true
  wait "$pid2" || true
else
  echo journal_restart_failed
fi
"""
        env = os.environ.copy()
        env.pop("LEITA_UPDATE_SEED", None)
        env.update({
            "LEITA_BIN": str(old),
            "LOOSE": str(loose),
            "LEITA_RELEASE_BASE": str(directory),
            "LOG": str(work / "journal.log"),
            "ERR": str(work / "journal.err"),
            "LOG2": str(work / "journal2.log"),
            "ERR2": str(work / "journal2.err"),
            "UPD": str(work / "update.out"),
            "UPDERR": str(work / "update.err"),
            "LEITA_COLOR": "never",
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(work / "home"),
        })
        proc = namespaced(script, env, timeout=40)
        text = proc.stdout
        err = (work / "journal.err").read_text(encoding="utf-8", errors="replace") if (work / "journal.err").exists() else ""
        if "journal_alive" not in text:
            detail = tail(err or proc.stderr or text) or "the recorder exited immediately"
            for case_id in (
                "linux_journal_alive_across_update",
                "linux_journal_stop",
                "linux_journal_restart",
            ):
                record(results, case_id, False, detail)
            return
        record(
            results,
            "linux_journal_alive_across_update",
            "journal_survived" in text,
            "the recorder was still running after a loose update" if "journal_survived" in text else "the recorder exited during the update",
        )
        record(
            results,
            "linux_journal_stop",
            "journal_stopped" in text,
            "SIGTERM stopped the recorder" if "journal_stopped" in text else "the recorder was still running after SIGTERM",
        )
        record(
            results,
            "linux_journal_restart",
            "journal_restarted" in text,
            "the recorder started again" if "journal_restarted" in text else tail((work / "journal2.err").read_text(encoding="utf-8", errors="replace") if (work / "journal2.err").exists() else text),
        )
    except Exception as err:
        detail = f"{type(err).__name__}: {err}"
        for case_id in (
            "linux_journal_alive_across_update",
            "linux_journal_stop",
            "linux_journal_restart",
        ):
            results.setdefault(case_id, {"id": case_id, "status": "fail", "detail": detail})
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if created_state:
            subprocess.run(["sudo", "-n", "rmdir", str(HOST_STATE)], capture_output=True)
        elif not HOST_STATE.exists():
            print("lifecycle: host /var/lib/leita disappeared; that must not happen", file=sys.stderr)


def payload_path(dest, name):
    """A payload member, relative to dest. `..` and an empty name are refused."""
    cleaned = name.replace("\\", "/")
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    cleaned = cleaned.lstrip("/")
    parts = []
    for part in cleaned.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise RuntimeError(f"member escapes the payload: {name}")
        parts.append(part)
    if not parts:
        raise RuntimeError(f"member name is empty: {name}")
    return dest.joinpath(*parts)


def link_stays_inside(dest, link, target):
    landing = os.path.normpath(os.path.join(str(link.parent), target))
    root = os.path.normpath(str(dest))
    if landing != root and not landing.startswith(root + os.sep):
        raise RuntimeError(f"symlink escapes the payload: {link.name} -> {target}")


def place_symlink(dest, name, target):
    """Store a symlink that resolves inside dest.

    An absolute target such as `/usr/bin/leita` is rewritten to a relative
    link under dest. Following the package's absolute link would read or
    write the host.
    """
    link = payload_path(dest, name)
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        link.unlink()
    stored = target.replace("\\", "/")
    if stored.startswith("/") or (len(stored) >= 3 and stored[1] == ":"):
        stored = os.path.relpath(str(payload_path(dest, target)), str(link.parent))
    link_stays_inside(dest, link, stored)
    os.symlink(stored, link)


def place_file(dest, name, data, mode=0o644):
    path = payload_path(dest, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode & 0o777 or 0o644)


def place_dir(dest, name):
    payload_path(dest, name).mkdir(parents=True, exist_ok=True)


def extract_tar_bytes(blob, dest, mode):
    """Extract a tar payload. Absolute links stay inside dest."""
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(blob), mode=mode) as tar:
        for member in tar.getmembers():
            if member.isdir():
                place_dir(dest, member.name)
                continue
            if member.issym():
                place_symlink(dest, member.name, member.linkname)
                continue
            if member.islnk():
                source = payload_path(dest, member.linkname)
                if not source.is_file():
                    raise RuntimeError(f"hard link target is missing: {member.linkname}")
                place_file(dest, member.name, source.read_bytes(), member.mode)
                continue
            if member.isreg():
                extracted = tar.extractfile(member)
                data = extracted.read() if extracted is not None else b""
                place_file(dest, member.name, data, member.mode)
                continue
            raise RuntimeError(f"payload member is not a file: {member.name}")


def extract_deb(path, dest):
    blob = Path(path).read_bytes()
    if not blob.startswith(b"!<arch>\n"):
        raise RuntimeError("deb is not an ar archive")
    off = 8
    members = {}
    while off + 60 <= len(blob):
        header = blob[off:off + 60]
        if header[58:60] != b"`\n":
            raise RuntimeError("deb ar header is truncated")
        name = header[:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii").strip() or "0")
        off += 60
        data = blob[off:off + size]
        off += size + (size % 2)
        members[name] = data
    data_name = next((name for name in members if name.startswith("data.tar")), None)
    if data_name is None:
        raise RuntimeError("deb has no data.tar member")
    payload = members[data_name]
    if data_name.endswith(".zst"):
        if not shutil.which("zstd"):
            raise RuntimeError("zstd is not installed, so the deb payload was not extracted")
        payload = subprocess.check_output(["zstd", "-d", "-c"], input=payload)
        tar_mode = "r:"
    elif data_name.endswith(".xz"):
        tar_mode = "r:xz"
    elif data_name.endswith(".gz"):
        tar_mode = "r:gz"
    else:
        tar_mode = "r:"
    extract_tar_bytes(payload, dest, tar_mode)


def decompress_rpm_payload(blob):
    if blob.startswith(b"\x1f\x8b"):
        with gzip.GzipFile(fileobj=io.BytesIO(blob)) as gz:
            return gz.read()
    if blob.startswith(b"\xfd7zXZ"):
        return lzma.LZMADecompressor().decompress(blob)
    if blob.startswith(b"\x28\xb5\x2f\xfd"):
        if not shutil.which("zstd"):
            raise RuntimeError("zstd is not installed, so the rpm payload was not extracted")
        return subprocess.check_output(["zstd", "-d", "-c"], input=blob)
    raise RuntimeError(f"rpm payload compression is unknown ({blob[:4].hex()})")


def rpm_payload(blob):
    """Bytes of the cpio archive inside an rpm, after the lead and headers."""
    if blob[:4] != b"\xed\xab\xee\xdb":
        raise RuntimeError("rpm lead magic mismatch")
    if len(blob) < 96:
        raise RuntimeError("rpm lead is truncated")

    def skip_header(off, align):
        if blob[off:off + 8] != b"\x8e\xad\xe8\x01\x00\x00\x00\x00":
            raise RuntimeError(f"rpm header magic mismatch at {off}")
        count, size = struct.unpack_from(">II", blob, off + 8)
        end = off + 16 + count * 16 + size
        if end > len(blob):
            raise RuntimeError("rpm header is truncated")
        if align:
            end = (end + 7) & ~7
        return end

    off = skip_header(96, align=True)
    off = skip_header(off, align=False)
    return blob[off:]


def extract_newc(blob, dest):
    """Extract a newc cpio archive. Absolute links stay inside dest."""
    dest.mkdir(parents=True, exist_ok=True)
    off = 0
    while off + 110 <= len(blob):
        magic = blob[off:off + 6]
        if magic not in (b"070701", b"070702"):
            raise RuntimeError(f"cpio magic {magic!r} at {off}")
        fields = [int(blob[off + 6 + i * 8:off + 14 + i * 8], 16) for i in range(13)]
        mode = fields[1]
        filesize = fields[6]
        namesize = fields[11]
        name_at = off + 110
        name_end = name_at + namesize
        if name_end > len(blob):
            raise RuntimeError("cpio name is truncated")
        name = blob[name_at:name_end].split(b"\x00", 1)[0].decode("utf-8", "replace")
        data_at = (name_end + 3) & ~3
        data_end = data_at + filesize
        if data_end > len(blob):
            raise RuntimeError(f"cpio member is truncated: {name}")
        data = blob[data_at:data_end]
        off = (data_end + 3) & ~3
        if name in ("TRAILER!!!", "TRAILER!!"):
            return
        kind = mode & 0o170000
        if kind == 0o040000:
            place_dir(dest, name)
        elif kind == 0o120000:
            target = data.split(b"\x00", 1)[0].decode("utf-8", "replace")
            place_symlink(dest, name, target)
        elif kind == 0o100000:
            place_file(dest, name, data, mode)
        else:
            raise RuntimeError(f"cpio member is not a file: {name}")
    raise RuntimeError("cpio archive has no trailer")


def extract_rpm(path, dest):
    blob = rpm_payload(Path(path).read_bytes())
    extract_newc(decompress_rpm_payload(blob), dest)


def packaging_cases(results, built_cli, update_key, licence_key):
    system = system_name()

    def archive():
        if system != "windows" and not shutil.which("zstd"):
            return False, "zstd is not installed, so the release archive was not built"
        env = build_env(NEW_VERSION, licence_key, update_key, STAMP)
        proc = subprocess.run(["just", "gui", "release"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        if proc.returncode != 0:
            return False, "the window build failed: " + tail(proc.stderr)
        work = Path(tempfile.mkdtemp(prefix="archive-"))
        try:
            stage = work / "stage"
            app = stage / "app"
            app.mkdir(parents=True)
            shutil.copy2(built_cli, stage / exe_name())
            gui = ROOT / "build" / "release" / "app" / gui_name()
            if not gui.is_file():
                return False, "the release window binary is missing"
            shutil.copy2(gui, app / gui_name())
            for extra in (ROOT / "build" / "release" / "app").iterdir():
                if extra.name != gui_name() and extra.is_file():
                    shutil.copy2(extra, app / extra.name)
            for notice in ("LICENSE.md", "THIRD_PARTY.md"):
                shutil.copy2(ROOT / notice, stage / notice)
            packed = work / ("leita.zip" if system == "windows" else "leita.tar.zst")
            if system == "windows":
                with zipfile.ZipFile(packed, "w") as archive_file:
                    for path in stage.rglob("*"):
                        if path.is_file():
                            archive_file.write(path, path.relative_to(stage).as_posix())
                extract = work / "extract"
                with zipfile.ZipFile(packed) as archive_file:
                    archive_file.extractall(extract)
            else:
                buffer = io.BytesIO()
                with tarfile.open(fileobj=buffer, mode="w") as tar:
                    for path in stage.rglob("*"):
                        if path.is_file():
                            tar.add(path, arcname=path.relative_to(stage).as_posix())
                packed.write_bytes(subprocess.check_output(["zstd", "-c"], input=buffer.getvalue()))
                raw = subprocess.check_output(["zstd", "-d", "-c"], input=packed.read_bytes())
                extract = work / "extract"
                extract_tar_bytes(raw, extract, "r:")
            binary = extract / exe_name()
            binary.chmod(0o755)
            env_run, _folder = child_env(work)
            code, out, err = invoke(binary, ["--version"], env_run)
            if code != 0 or NEW_VERSION not in out:
                return False, f"the extracted archive exited {code}: {out} {err}".strip()
            return True, f"ran {exe_name()} from the assembled archive"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    guard(results, "packaged_archive", archive)
    if system != "linux":
        return

    def packages():
        env = build_env(NEW_VERSION, licence_key, update_key, STAMP)
        proc = subprocess.run(["just", "package"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        log = tail(proc.stdout + "\n" + proc.stderr, 1500)
        out = ROOT / "build" / "package"
        debs = list(out.glob("*.deb")) if out.is_dir() else []
        rpms = list(out.glob("*.rpm")) if out.is_dir() else []
        images = list(out.glob("*.AppImage")) if out.is_dir() else []
        if proc.returncode != 0 or not debs:
            record(results, "packaged_deb_payload", False, "package build failed: " + log)
        else:
            guard(results, "packaged_deb_payload", lambda: run_payload_deb(debs[0]))
        if proc.returncode != 0 or not rpms:
            record(results, "packaged_rpm_payload", False, "package build failed: " + log)
        else:
            guard(results, "packaged_rpm_payload", lambda: run_payload_rpm(rpms[0]))
        if proc.returncode != 0 or not images:
            record(results, "packaged_appimage", False, "package build failed: " + log)
        else:
            guard(results, "packaged_appimage", lambda: run_appimage(images[0]))

    def run_payload_deb(deb):
        work = Path(tempfile.mkdtemp(prefix="deb-"))
        try:
            extract_deb(deb, work)
            binary = work / "usr" / "bin" / "leita"
            if not binary.is_file():
                return False, "the deb payload has no usr/bin/leita"
            binary.chmod(0o755)
            env, _folder = child_env(work)
            code, out, err = invoke(binary, ["--version"], env)
            if code != 0 or NEW_VERSION not in out:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "ran usr/bin/leita from the extracted deb, without installing it"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def run_payload_rpm(rpm):
        work = Path(tempfile.mkdtemp(prefix="rpm-"))
        try:
            extract_rpm(rpm, work)
            binary = work / "usr" / "bin" / "leita"
            if not binary.is_file():
                return False, "the rpm payload has no usr/bin/leita"
            binary.chmod(0o755)
            env, _folder = child_env(work)
            code, out, err = invoke(binary, ["--version"], env)
            if code != 0 or NEW_VERSION not in out:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "ran usr/bin/leita from the extracted rpm, without installing it"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def run_appimage(image):
        work = Path(tempfile.mkdtemp(prefix="ai-"))
        try:
            copy = work / image.name
            shutil.copy2(image, copy)
            copy.chmod(0o755)
            env, _folder = child_env(work)
            env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
            code, out, err = invoke(copy, ["--version"], env, timeout=120)
            if code != 0 or NEW_VERSION not in out:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "ran the AppImage with APPIMAGE_EXTRACT_AND_RUN"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    try:
        packages()
    except Exception as err:
        detail = f"{type(err).__name__}: {err}"
        for case_id in ("packaged_deb_payload", "packaged_rpm_payload", "packaged_appimage"):
            results.setdefault(case_id, {"id": case_id, "status": "fail", "detail": detail})


def darwin_packages(results, update_key, licence_key):
    if system_name() != "darwin":
        return

    def app_and_dmg():
        env = build_env(NEW_VERSION, licence_key, update_key, STAMP)
        proc = subprocess.run(["just", "bundle"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        app = ROOT / "build" / "release" / "Leita.app"
        helper = app / "Contents" / "Helpers" / "leita"
        window = app / "Contents" / "MacOS" / "Leita"
        if proc.returncode != 0 or not helper.is_file() or not window.is_file():
            detail = "Leita.app was not built: " + tail(proc.stderr)
            record(results, "packaged_app", False, detail)
            record(results, "packaged_dmg", False, detail)
            return
        run_env, _folder = child_env(Path(tempfile.mkdtemp(prefix="appdata-")))
        code, out, err = invoke(helper, ["--version"], run_env)
        if code != 0 or NEW_VERSION not in out:
            record(results, "packaged_app", False, f"helper exit {code}: {out} {err}".strip())
        else:
            record(results, "packaged_app", True, "ran Contents/Helpers/leita from Leita.app")
        if not shutil.which("hdiutil"):
            record(results, "packaged_dmg", False, "hdiutil is not available")
            return
        work = Path(tempfile.mkdtemp(prefix="dmg-"))
        mount = work / "mount"
        mount.mkdir()
        dmg = work / "Leita.dmg"
        stage = work / "stage"
        stage.mkdir()
        subprocess.run(["ditto", str(app), str(stage / "Leita.app")], check=True)
        try:
            create = subprocess.run(
                ["hdiutil", "create", "-volname", "Leita", "-srcfolder", str(stage), "-fs", "HFS+", "-format", "UDZO", "-ov", str(dmg)],
                capture_output=True, text=True, timeout=180,
            )
            if create.returncode != 0:
                record(results, "packaged_dmg", False, tail(create.stderr))
                return
            attach = subprocess.run(
                ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(dmg)],
                capture_output=True, text=True, timeout=60,
            )
            if attach.returncode != 0:
                record(results, "packaged_dmg", False, tail(attach.stderr))
                return
            code, out, err = invoke(mount / "Leita.app" / "Contents" / "MacOS" / "Leita", ["--version"], run_env)
            if code != 0 or NEW_VERSION not in out:
                record(results, "packaged_dmg", False, f"exit {code}: {out} {err}".strip())
            else:
                record(results, "packaged_dmg", True, "ran the window from the attached disk image")
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True)
            shutil.rmtree(work, ignore_errors=True)

    try:
        app_and_dmg()
    except Exception as err:
        detail = f"{type(err).__name__}: {err}"
        results.setdefault("packaged_app", {"id": "packaged_app", "status": "fail", "detail": detail})
        results.setdefault("packaged_dmg", {"id": "packaged_dmg", "status": "fail", "detail": detail})


def windows_installer(results):
    if system_name() != "windows":
        return

    def install():
        iscc = ""
        for candidate in (
            r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            r"C:\Program Files\Inno Setup 6\ISCC.exe",
        ):
            if Path(candidate).is_file():
                iscc = candidate
                break
        if not iscc:
            return False, "Inno Setup 6 is not installed, so the installer was not built"
        work = Path(tempfile.mkdtemp(prefix="setup-"))
        try:
            pack = ROOT / "build" / "release"
            number = "0.0.2.0"
            env = os.environ.copy()
            env.update({
                "LEITA_PACK": str(pack),
                "LEITA_VERSION": NEW_VERSION,
                "LEITA_NUMBER": number,
                "LEITA_OUT": str(work),
                "LEITA_OUTNAME": "leita-setup",
                "MSYS_NO_PATHCONV": "1",
            })
            proc = subprocess.run([iscc, "/Q", str(ROOT / "tools" / "windows" / "leita.iss")], env=env, capture_output=True, text=True, timeout=300)
            setup = work / "leita-setup.exe"
            if proc.returncode != 0 or not setup.is_file():
                return False, tail(proc.stdout + proc.stderr) or "ISCC wrote no installer"
            dest = work / "installed"
            installed = subprocess.run(
                [str(setup), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/DIR={dest}"],
                capture_output=True, text=True, timeout=180,
            )
            binary = dest / "leita.exe"
            if installed.returncode != 0 or not binary.is_file():
                return False, tail(installed.stdout + installed.stderr) or "the installer did not place leita.exe in the temp directory"
            env_run, _folder = child_env(work)
            code, out, err = invoke(binary, ["--version"], env_run)
            if code != 0 or NEW_VERSION not in out:
                return False, f"exit {code}: {out} {err}".strip()
            return True, "the installer was run into a temp directory, not Program Files, and leita.exe ran"
        finally:
            unins = work / "installed" / "unins000.exe"
            if unins.is_file():
                subprocess.run([str(unins), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"], capture_output=True, timeout=180)
            shutil.rmtree(work, ignore_errors=True)

    guard(results, "packaged_installer", install)


def run(directory, sha, system):
    results = {}
    record(
        results,
        "fixture_not_production",
        True,
        "the harness generated a throwaway Ed25519 key and did not read LEITA_UPDATE_SEED",
    )
    update_key = fixture.keygen()
    rotation = fixture.keygen()
    licence_key = just_value("test_licence_key")
    test_line = just_value("test_licence")
    # Drop the rotation seed's private use after the lines exist. The seed
    # stays in this process only long enough to sign two fixture lines.
    rotation_line = fixture.mint_licence(
        rotation.seed,
        ident="rotate",
        email="rotate@leita.example",
        scope="personal",
        features="pro",
        paid_through="9999-12-31T23:59:59Z",
        issued="2026-10-21T00:00:00Z",
    )
    early_line = fixture.mint_licence(
        rotation.seed,
        ident="early",
        email="early@leita.example",
        scope="personal",
        features="pro",
        paid_through="2020-01-01T00:00:00Z",
        issued="2020-01-01T00:00:00Z",
    )
    asset = fixture.host_asset("command")
    bindir = directory / "bin"
    old = bindir / ("old-" + exe_name())
    new = bindir / ("new-" + exe_name())
    dev = bindir / ("dev-" + exe_name())
    try:
        build_cli(old, OLD_VERSION, f"{licence_key},{rotation.public_hex}", update_key.public_hex, STAMP)
        build_cli(new, NEW_VERSION, licence_key, update_key.public_hex, STAMP)
        build_cli(dev, "dev", licence_key, update_key.public_hex, "")
    except Exception as err:
        detail = f"release build failed: {err}"
        for case_id, platforms in gate.REQUIRED.items():
            if case_id in SIBLING or case_id == "fixture_not_production":
                continue
            if system in platforms:
                results.setdefault(case_id, {"id": case_id, "status": "fail", "detail": detail})
        return results
    licence_cases(results, old, new, test_line, rotation_line, early_line, update_key.public_hex)
    update_cases(results, old, new, dev, update_key.seed, asset, test_line, update_key.public_hex)
    linux_path_cases(results, old, new.read_bytes(), update_key.seed, asset)
    linux_journal_cases(results, old, new.read_bytes(), update_key.seed, asset)
    packaging_cases(results, new, update_key.public_hex, licence_key)
    darwin_packages(results, update_key.public_hex, licence_key)
    windows_installer(results)
    return results


def main(argv):
    directory = Path(os.environ.get("LIFECYCLE_DIR", ROOT / "build" / "lifecycle"))
    if len(argv) >= 2 and argv[1] == "--dir" and len(argv) >= 3:
        directory = Path(argv[2])
    sha = os.environ.get("LIFECYCLE_SHA") or git_sha()
    system = system_name()
    emit(directory, sha, system, {}, unfinished="the harness had not finished")
    results = {}
    try:
        results = run(directory, sha, system)
    except Exception as err:
        print(f"lifecycle: {type(err).__name__}: {err}", file=sys.stderr)
        results.setdefault(
            "fixture_not_production",
            {"id": "fixture_not_production", "status": "fail", "detail": str(err)},
        )
    finally:
        path = emit(directory, sha, system, results)
    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
