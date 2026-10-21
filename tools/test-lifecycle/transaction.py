"""Native cases for one update locking and replacing the executable.

The harness imports this after it has finished loading. These cases launch
the built command line; they do not mock the lock or the rename.
"""

import os
import stat
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import fixture
import harness


def cases(results, old, new_bytes, seed, asset):
    harness.guard(results, "update_peer_blocked", lambda: peer_blocked(old, new_bytes, seed, asset))
    harness.guard(
        results,
        "update_lock_released_on_exit",
        lambda: lock_released_on_exit(old, new_bytes, seed, asset),
    )
    harness.guard(
        results,
        "update_commit_killed_keeps_old",
        lambda: commit_killed_keeps_old(old, new_bytes, seed, asset),
    )
    harness.guard(
        results,
        "update_commit_completes",
        lambda: commit_completes(old, new_bytes, seed, asset),
    )
    harness.guard(
        results,
        "update_symlink_protected_refused",
        lambda: symlink_protected_refused(old, new_bytes, seed, asset),
    )


def peer_blocked(old, new_bytes, seed, asset):
    work = Path(tempfile.mkdtemp(prefix="peer-"))
    proc = None
    release = threading.Event()
    try:
        directory = harness.release_dir(work, asset, new_bytes, harness.NEW_VERSION, seed)
        binary = harness.place(old, work / "bin" / harness.exe_name())
        before = binary.read_bytes()
        env, _folder = harness.child_env(work)
        with fixture.ReleaseServer(directory, stall={asset}, stall_seconds=60, release=release) as server:
            env["LEITA_RELEASE_BASE"] = server.url
            proc = subprocess.Popen(
                [str(binary), "update"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if not _wait_until(20, lambda: _saw(server, asset) and _scratch_ready(binary)):
                return False, "the first update did not reach the download under the lock"
            names = _scratch(binary)
            snap = {name: _ident(path) for name, path in names.items() if path.exists()}
            for name, path in names.items():
                if name not in snap and path.exists():
                    snap[name] = _ident(path)
            alias = _alias(binary)
            code, out, err = harness.invoke(alias, ["update"], dict(env), timeout=20)
            text = f"{out}\n{err}"
            if code == 0 or "another update" not in text:
                return False, f"the second update was not refused (exit {code}): {text.strip()}"
            if binary.read_bytes() != before:
                return False, "the second update changed the executable"
            for name, path in names.items():
                if name not in snap:
                    if path.exists():
                        return False, f"the second update created {path.name}"
                    continue
                if not path.exists() or _ident(path) != snap[name]:
                    return False, f"the second update changed {path.name}"
            release.set()
            code_a, out_a, err_a = _finish(proc, env, binary)
            proc = None
            if code_a != 0 or harness.NEW_VERSION not in out_a:
                return False, f"the first update did not finish (exit {code_a}): {err_a or out_a}"
            return True, "a second update was refused, then the first one installed"
    finally:
        release.set()
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        _rmtree(work)


def lock_released_on_exit(old, new_bytes, seed, asset):
    work = Path(tempfile.mkdtemp(prefix="unlock-"))
    proc = None
    try:
        directory = harness.release_dir(work, asset, new_bytes, harness.NEW_VERSION, seed)
        binary = harness.place(old, work / "bin" / harness.exe_name())
        env, _folder = harness.child_env(work)
        with fixture.ReleaseServer(directory, stall={asset}, stall_seconds=8) as server:
            env["LEITA_RELEASE_BASE"] = server.url
            proc = subprocess.Popen(
                [str(binary), "update"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if not _wait_until(12, lambda: _saw(server, asset) or (Path(str(binary) + ".update.lock")).exists()):
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=10)
                proc = None
                return False, "the updater never took the lock"
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=10)
            proc = None
        env["LEITA_RELEASE_BASE"] = str(directory)
        code, out, err = harness.invoke(binary, ["update"], env)
        ver, vout, verr = harness.invoke(binary, ["--version"], env)
        if code != 0 or ver != 0 or harness.NEW_VERSION not in vout:
            return False, f"exit {code}: {err or out} version {vout} {verr}".strip()
        return True, "a killed updater released the lock and the next update installed"
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        _rmtree(work)


def commit_killed_keeps_old(old, new_bytes, seed, asset):
    return _commit_gate(old, new_bytes, seed, asset, kill=True)


def commit_completes(old, new_bytes, seed, asset):
    return _commit_gate(old, new_bytes, seed, asset, kill=False)


def _commit_gate(old, new_bytes, seed, asset, kill):
    work = Path(tempfile.mkdtemp(prefix="hold-"))
    proc = None
    gate_hold = None
    try:
        directory = harness.release_dir(work, asset, new_bytes, harness.NEW_VERSION, seed)
        binary = harness.place(old, work / "bin" / harness.exe_name())
        before = binary.read_bytes()
        if os.name != "nt":
            os.chmod(binary, 0o750)
        env, _folder = harness.child_env(work)
        marker = work / "user-marker.txt"
        marker.write_text("keep-me", encoding="utf-8")
        gate = work / "hold"
        gate.write_bytes(b"\0")
        gate_hold = _lock_gate(gate)
        env["LEITA_RELEASE_BASE"] = str(directory)
        env["LEITA_UPDATE_HOLD_COMMIT"] = str(gate)
        proc = subprocess.Popen(
            [str(binary), "update"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        ready = Path(str(gate) + ".ready")
        if not _wait_until(25, lambda: ready.exists() or proc.poll() is not None):
            return False, "the update did not reach the commit gate"
        if not ready.exists():
            out, err = _drain(proc)
            return False, f"the update exited before the commit gate: {err or out}"
        if kill:
            proc.kill()
            proc.wait(timeout=10)
            proc = None
            _unlock_gate(gate_hold)
            gate_hold = None
            run_env = dict(env)
            run_env.pop("LEITA_UPDATE_HOLD_COMMIT", None)
            code, out, err = harness.invoke(binary, ["--version"], run_env)
            if binary.read_bytes() != before:
                return False, "killing at the commit replaced the executable"
            if code != 0 or harness.OLD_VERSION not in out:
                return False, f"the old program did not launch (exit {code}): {out} {err}".strip()
            if marker.read_text(encoding="utf-8") != "keep-me":
                return False, "user data changed"
            if os.name != "nt" and stat.S_IMODE(binary.stat().st_mode) != 0o750:
                return False, f"mode is {oct(stat.S_IMODE(binary.stat().st_mode))}"
            return True, "killing at the commit left the old executable launching"
        _unlock_gate(gate_hold)
        gate_hold = None
        code_a, out_a, err_a = _finish(proc, env, binary)
        proc = None
        old_path = Path(str(binary) + ".old")
        if code_a != 0 or harness.NEW_VERSION not in out_a:
            return False, f"the commit did not finish (exit {code_a}): {err_a or out_a}"
        if not old_path.is_file() or old_path.read_bytes() != before:
            return False, "the backup is not the previous executable"
        if binary.read_bytes() != new_bytes:
            return False, "the executable is not the new build"
        if marker.read_text(encoding="utf-8") != "keep-me":
            return False, "user data changed"
        if os.name != "nt" and stat.S_IMODE(binary.stat().st_mode) != 0o750:
            return False, f"mode is {oct(stat.S_IMODE(binary.stat().st_mode))}"
        return True, "the commit installed the new executable and kept the old bytes"
    finally:
        if gate_hold is not None:
            _unlock_gate(gate_hold)
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        _rmtree(work)


def symlink_protected_refused(old, new_bytes, seed, asset):
    work = Path(tempfile.mkdtemp(prefix="plink-"))
    try:
        directory = harness.release_dir(work, asset, new_bytes, harness.NEW_VERSION, seed)
        binary = harness.place(old, work / "Program Files" / "Leita" / harness.exe_name())
        before = binary.read_bytes()
        link = work / "launch" / ("leita-link" + (".exe" if os.name == "nt" else ""))
        link.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.symlink(binary, link)
        except OSError as err:
            return False, f"could not create a symlink: {err}"
        env, _folder = harness.child_env(work)
        env["LEITA_RELEASE_BASE"] = str(directory)
        code, out, err = harness.invoke(link, ["update"], env)
        text = f"{out}\n{err}"
        if binary.read_bytes() != before or code == 0 or "Program Files" not in text:
            return False, f"exit {code}: {text.strip()}"
        return True, "a symlink to Program Files was refused and the file was unchanged"
    finally:
        _rmtree(work)


def _scratch(binary):
    base = str(binary)
    return {
        "new": Path(base + ".new"),
        "dl": Path(base + ".dl"),
        "old": Path(base + ".old"),
        "try": Path(base + ".try"),
        "part": Path(base + ".old.part"),
        "lock": Path(base + ".update.lock"),
    }


def _scratch_ready(binary):
    return Path(str(binary) + ".new").exists() and Path(str(binary) + ".update.lock").exists()


def _saw(server, asset):
    return any(item["path"] == asset for item in server.requests)


def _ident(path):
    st = path.stat()
    return (st.st_dev, st.st_ino, st.st_size)


def _alias(binary):
    if os.name == "nt":
        flipped = binary.name[:1].swapcase() + binary.name[1:]
        if flipped == binary.name:
            flipped = binary.name.swapcase()
        return binary.with_name(flipped)
    link = binary.parent / ("alias-" + binary.name)
    if link.is_symlink() or link.exists():
        link.unlink()
    os.symlink(binary, link)
    return link


def _wait_until(seconds, pred):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def _finish(proc, env, binary):
    # Read both pipes. wait returns while they still hold the child's output.
    try:
        out_b, err_b = proc.communicate(timeout=40)
    except subprocess.TimeoutExpired:
        proc.kill()
        out_b, err_b = _drain_after_kill(proc)
        err_text = _decode(err_b).strip()
        detail = f"timed out\n{err_text}" if err_text else "timed out"
        return 1, _decode(out_b), detail
    if proc.returncode != 0:
        return proc.returncode, _decode(out_b), _decode(err_b)
    run_env = dict(env)
    run_env.pop("LEITA_UPDATE_HOLD_COMMIT", None)
    run_env.pop("LEITA_RELEASE_BASE", None)
    code, out, err = harness.invoke(binary, ["--version"], run_env)
    return code, out, err


def _drain_after_kill(proc):
    try:
        return proc.communicate(timeout=10)
    except subprocess.TimeoutExpired as err:
        return err.stdout or b"", err.stderr or b""


def _decode(data):
    if not data:
        return ""
    return data.decode("utf-8", "replace")


def _drain(proc):
    try:
        out, err = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate(timeout=10)
    return out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def _lock_gate(gate):
    if os.name == "nt":
        import msvcrt
        fh = open(gate, "r+b")
        fh.seek(0)
        msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        return ("win", fh)
    import fcntl
    fd = os.open(gate, os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return ("unix", fd)


def _unlock_gate(held):
    if held is None:
        return
    kind, value = held
    if kind == "win":
        import msvcrt
        value.seek(0)
        msvcrt.locking(value.fileno(), msvcrt.LK_UNLCK, 1)
        value.close()
        return
    import fcntl
    fcntl.flock(value, fcntl.LOCK_UN)
    os.close(value)


def _rmtree(work):
    import shutil
    shutil.rmtree(work, ignore_errors=True)
