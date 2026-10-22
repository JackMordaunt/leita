#!/usr/bin/env python3
"""Install leita's Windows installer and exercise it, writing what happened.

    compat_probe.py --setup SETUP.exe --out evidence.json [--dir C:\\leita-probe]

The stages are install, version, scan of a fixture folder, scan of the system
drive (which says whether the MFT reader or the directory walk read it), and
an update check. Each is reported on its own as passed, failed, fallback,
unverified or skipped, with the program's own words. Nothing here disables
the MFT reader or changes a default.

What a run proves depends on the machine it ran on, so the evidence carries
the machine's own account of itself (build number, edition, architecture, the
machine type in the installed .exe's header) and `proves` names which of the
card's systems that account satisfies. A hosted runner is Windows Server 2022
or 2025, or Windows 11 on Arm, never Windows 10 22H2: those runs prove what
`proves` says and no more.

The update stage never passes. `leita update --check` reads the latest
published release; installing one needs a release to exist (card 547), so the
stage reports unverified together with what the command printed.
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

TIMEOUT_INSTALL = 300
TIMEOUT_SCAN = 900


def pe_machine(path):
    """The machine type in a PE file's header: AMD64, ARM64, I386, or hex."""
    with open(path, "rb") as f:
        head = f.read(4096)
    if head[:2] != b"MZ":
        raise ValueError(f"{path}: not a PE file")
    (off,) = struct.unpack_from("<I", head, 0x3C)
    if off + 6 > len(head):
        with open(path, "rb") as f:
            f.seek(off)
            head = f.read(6)
            off = 0
    if head[off : off + 4] != b"PE\0\0":
        raise ValueError(f"{path}: no PE signature")
    (machine,) = struct.unpack_from("<H", head, off + 4)
    return {0x8664: "AMD64", 0xAA64: "ARM64", 0x14C: "I386"}.get(machine, hex(machine))


def proves(build, edition, os_arch, exe_machine):
    """Which of card 600's systems this machine is, from what it reports.

    build is the Windows build number, edition its caption (Server is not a
    desktop), os_arch the OS's architecture as RuntimeInformation names it, and
    exe_machine the installed leita.exe's header. Returns a list of names;
    empty means this machine is none of the card's systems.
    """
    server = "server" in edition.lower()
    arch = os_arch.lower()
    out = []
    if server:
        return out
    if exe_machine != "AMD64":
        return out
    if arch in ("x64", "amd64") and build == 19045:
        out.append("windows-10-22h2-x64")
    if arch in ("x64", "amd64") and build >= 22000:
        out.append("windows-11-x64")
    if arch == "arm64" and build >= 22000:
        out.append("windows-11-arm64-x64-emulation")
    return out


def classify_engine(output):
    """Which reader a scan's own output names: mft, walk or unknown."""
    if re.search(r"^\s*mft\s+\d+ slots", output, re.M):
        return "mft"
    if re.search(r"^\s*walk:\s+\d+ readers", output, re.M):
        return "walk"
    return "unknown"


def stage_status_scan(returncode, output, must_contain):
    """passed when the scan exited 0 and printed each expected name."""
    if returncode != 0:
        return "failed"
    return "passed" if all(s in output for s in must_contain) else "failed"


def stage_status_mft(returncode, output):
    """passed for the MFT reader, fallback for the walk, failed on a bad exit.

    A walk of the system drive means the MFT reader was not used there, which
    is a limitation to record (the walk is the fallback), not a pass.
    """
    if returncode != 0:
        return "failed"
    engine = classify_engine(output)
    return {"mft": "passed", "walk": "fallback"}.get(engine, "failed")


def run(cmd, timeout, **kw):
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, errors="replace", timeout=timeout, **kw
        )
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        return 124, f"timed out after {timeout} s\n{e.stdout or ''}"
    except OSError as e:
        return 126, f"could not start: {e}"


def powershell(script):
    return run(["powershell", "-NoProfile", "-Command", script], 120)[1].strip()


def machine_facts():
    arch = powershell("[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture")
    caption = powershell("(Get-CimInstance Win32_OperatingSystem).Caption")
    build = powershell("[Environment]::OSVersion.Version.Build")
    display = powershell(
        "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').DisplayVersion"
    )
    return {
        "caption": caption,
        "build": int(build) if build.isdigit() else 0,
        "display_version": display,
        "os_architecture": arch,
        "runner_image": os.environ.get("ImageOS", "") + " " + os.environ.get("ImageVersion", ""),
        "probe_python_machine": os.environ.get("PROCESSOR_ARCHITECTURE", ""),
    }


def stage(name, status, detail, **extra):
    return {"stage": name, "status": status, "detail": detail[-4000:], **extra}


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--setup", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--dir", default=r"C:\leita-compat-probe")
    args = ap.parse_args(argv)

    facts = machine_facts()
    stages = []
    exe = os.path.join(args.dir, "leita.exe")

    code, out = run(
        [args.setup, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/DIR={args.dir}"],
        TIMEOUT_INSTALL,
    )
    files = ["leita.exe", r"app\Leita.exe", r"app\SDL3.dll", r"app\accesskit.dll", "unins000.exe"]
    missing = [f for f in files if not os.path.isfile(os.path.join(args.dir, f))]
    ok = code == 0 and not missing
    stages.append(
        stage("install", "passed" if ok else "failed", out or f"exit {code}; missing {missing}")
    )
    machine = ""
    if ok:
        machine = pe_machine(exe)
        facts["installed_exe_machine"] = machine
        facts["x64_under_emulation"] = machine == "AMD64" and facts["os_architecture"].lower() == "arm64"
        facts["proves"] = proves(
            facts["build"], facts["caption"], facts["os_architecture"], machine
        )

        code, out = run([exe, "--version"], 60)
        stages.append(stage("version", "passed" if code == 0 and out.strip() else "failed", out))

        fixture = tempfile.mkdtemp(prefix="leita-fixture-")
        sizes = {"compat-big.bin": 3_000_000, "compat-mid.bin": 1_000_000, "compat-small.bin": 1_000}
        for name, n in sizes.items():
            with open(os.path.join(fixture, name), "wb") as f:
                f.write(b"\0" * n)
        code, out = run(
            [exe, "--color", "never", "--no-history", "--format", "csv", "--report", "-", fixture],
            TIMEOUT_SCAN,
        )
        stages.append(stage("scan", stage_status_scan(code, out, sizes), out))

        drive = os.environ.get("SystemDrive", "C:") + "\\"
        code, out = run([exe, "--color", "never", "--no-history", drive], TIMEOUT_SCAN)
        engine = classify_engine(out)
        stages.append(stage("mft", stage_status_mft(code, out), out, engine=engine, target=drive))

        code, out = run([exe, "--color", "never", "update", "--check"], 120)
        stages.append(
            stage(
                "update",
                "unverified",
                f"exit {code}\n{out}",
                reason="installing an update needs a published release (card 547); --check alone is not an update test",
            )
        )
        run([os.path.join(args.dir, "unins000.exe"), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/REMOVEDATA"], TIMEOUT_INSTALL)
    else:
        for name in ("version", "scan", "mft", "update"):
            stages.append(stage(name, "skipped", "the install did not complete"))

    evidence = {"machine": facts, "stages": stages}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(evidence, f, indent=2)
    for s in stages:
        print(f"{s['stage']:8} {s['status']}")
    print("proves:", facts.get("proves", []))
    return 0 if all(s["status"] in ("passed", "fallback", "unverified") for s in stages) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
