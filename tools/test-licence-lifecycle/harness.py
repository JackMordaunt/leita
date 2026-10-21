# Native licence evidence for one operating system.
#
# Writes evidence-licence.json. The update harness writes the other required
# licence ids; emitting those here would make a disagreeing merge fail.
# This process mints throwaway keys and never calls mordaunt.dev or GitHub.

import argparse
import json
import os
import subprocess
import sys
import traceback
from pathlib import Path

import fixture
import host
import scenarios
from suite import ROOT

OWNED = [
    "activation_http",
    "receipt_recovery",
    "host_activation_invalid",
    "host_activation_tampered",
    "host_activation_http_error",
    "host_activation_timeout",
    "host_activation_unreachable",
    "host_pro_persisted_offline",
    "host_pro_later_ineligible",
    "host_update_explicit_only",
    "host_update_opt_in",
    "host_update_check_available",
    "host_update_apply",
    "host_update_offline",
    "host_update_ineligible",
    "cli_add_offline",
    "cli_tamper_keeps_file",
    "cli_unknown_key_refused",
    "cli_env_does_not_rewrite",
    "cli_remove",
    "cli_pro_at_paid_through",
    "cli_free_after_paid_through",
]

# Ids the update harness already writes. Do not emit them.
FORBIDDEN = {
    "licence_persisted",
    "licence_offline",
    "licence_tampered",
    "licence_rotation_retained_key",
    "licence_rotation_dropped_key",
    "licence_pro_before_cutoff",
    "licence_pro_after_cutoff",
    "cli_key_not_activated",
    "cli_tampered_no_recovery",
    "startup_has_no_update_request",
    "automatic_startup_check",
    "automatic_daily_check",
    "update_check_newer",
    "update_user_agent",
    "update_check_single",
    "update_apply_relaunch",
    "update_preserves_data",
    "update_preserves_pro",
    "update_bad_hash",
    "update_unreachable",
    "update_permissions",
    "update_interrupted",
    "update_keeps_old",
    "update_current_noop",
    "update_dev_refused",
    "update_bundle_refused",
    "update_installer_path_refused",
    "update_package_refused",
    "update_journal_path_not_replaced",
    "update_symlink_loose_follows_real",
    "linux_journal_alive_across_update",
    "linux_journal_stop",
    "linux_journal_restart",
    "signing_required",
    "update_ineligible_needs_consent",
    "fixture_not_production",
    "packaged_archive",
    "packaged_deb_payload",
    "packaged_rpm_payload",
    "packaged_appimage",
    "packaged_app",
    "packaged_dmg",
    "packaged_installer",
}


def git_sha():
    got = os.environ.get("LIFECYCLE_SHA", "").strip()
    if got:
        return got
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def evidence_dir():
    raw = os.environ.get("LIFECYCLE_DIR", "build/lifecycle")
    path = Path(raw)
    if not path.is_absolute():
        path = ROOT / path
    path.mkdir(parents=True, exist_ok=True)
    return path


def squash(text):
    text = " ".join(str(text).split())
    if len(text) > 500:
        return text[:500]
    return text


def run_case(results, case_id, fn):
    print(f"CASE {case_id}", flush=True)
    try:
        ok, detail = fn()
    except Exception as err:
        ok = False
        detail = f"{type(err).__name__}: {err}"
        traceback.print_exc()
    results[case_id] = {"id": case_id, "status": "pass" if ok else "fail", "detail": squash(detail)}
    print(f"RESULT {case_id} {results[case_id]['status']} {results[case_id]['detail']}", flush=True)


def emit(directory, sha, system, results):
    overlap = FORBIDDEN.intersection(results)
    if overlap:
        raise RuntimeError(f"refusing to emit update-harness ids: {sorted(overlap)}")
    cases = []
    for case_id in OWNED:
        got = results.get(case_id)
        if got is None:
            cases.append({"id": case_id, "status": "fail", "detail": "the harness did not run this case"})
        else:
            cases.append(got)
    document = {
        "schema": 1,
        "producer": "licence",
        "sha": sha,
        "os": system,
        "production_signature": False,
        "fixture": "throwaway-ed25519",
        "cases": cases,
    }
    path = directory / "evidence-licence.json"
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return path


def build(bindir):
    """Throwaway keys and the four binaries. Seeds stay in this process."""
    print("BUILD keys and binaries", flush=True)
    host.ensure_sqlite()

    # Passed through as a single-quoted -define. Do not reshape the hex.
    current = fixture.keygen()
    previous = fixture.keygen()
    update = fixture.keygen()
    line = fixture.mint_licence(
        current.seed, host.ORDER, host.EMAIL, host.SCOPE, "pro", host.PAID_THROUGH, host.ISSUED,
    )
    old_line = fixture.mint_licence(
        previous.seed, host.ORDER, host.EMAIL, host.SCOPE, "pro", host.PAID_THROUGH, host.ISSUED,
    )
    other = fixture.mint_licence(
        current.seed, "ord_other", host.EMAIL, host.SCOPE, "pro", host.PAID_THROUGH, host.ISSUED,
    )
    head, _, sig = line.rpartition(".")
    import base64
    if not fixture.verify_bytes(current.public_hex, head.encode("ascii"), base64.b64decode(sig)):
        raise RuntimeError("the minted line did not verify under its throwaway key")
    bins = type("Bins", (), {})()
    bins.current = current
    bins.old = previous
    bins.update = update
    bins.line = line
    bins.old_line = old_line
    bins.other_line = other
    eligible = bindir / ("capture-eligible.exe" if os.name == "nt" else "capture-eligible")
    later = bindir / ("capture-later.exe" if os.name == "nt" else "capture-later")
    cli_eligible = bindir / ("leita-eligible.exe" if os.name == "nt" else "leita-eligible")
    cli_later = bindir / ("leita-later.exe" if os.name == "nt" else "leita-later")
    print("BUILD capture eligible", flush=True)
    host.build_capture(eligible, current.public_hex, update.public_hex, host.ELIGIBLE_RELEASED)
    print("BUILD capture later", flush=True)
    host.build_capture(later, current.public_hex, update.public_hex, host.LATER_RELEASED)
    print("BUILD cli", flush=True)
    host.build_cli(cli_eligible, current.public_hex, host.ELIGIBLE_RELEASED)
    host.build_cli(cli_later, current.public_hex, host.LATER_RELEASED)
    bins.capture_eligible = eligible
    bins.capture_later = later
    bins.cli_eligible = cli_eligible
    bins.cli_later = cli_later
    return bins


def cases(bins):
    return [
        ("cli_add_offline", lambda: scenarios.cli_add_offline(bins)),
        ("cli_tamper_keeps_file", lambda: scenarios.cli_tamper_keeps_file(bins)),
        ("cli_unknown_key_refused", lambda: scenarios.cli_unknown_key_refused(bins)),
        ("cli_env_does_not_rewrite", lambda: scenarios.cli_env_does_not_rewrite(bins)),
        ("cli_remove", lambda: scenarios.cli_remove(bins)),
        ("cli_pro_at_paid_through", lambda: scenarios.cli_pro_at_paid_through(bins)),
        ("cli_free_after_paid_through", lambda: scenarios.cli_free_after_paid_through(bins)),
        ("activation_http", lambda: scenarios.activation_http(bins)),
        ("receipt_recovery", lambda: scenarios.receipt_recovery(bins)),
        ("host_activation_invalid", lambda: scenarios.activation_invalid(bins)),
        ("host_activation_tampered", lambda: scenarios.activation_tampered(bins)),
        ("host_activation_http_error", lambda: scenarios.activation_http_error(bins)),
        ("host_activation_unreachable", lambda: scenarios.activation_unreachable(bins)),
        ("host_pro_persisted_offline", lambda: scenarios.pro_persisted(bins, export=True)),
        ("host_pro_later_ineligible", lambda: scenarios.pro_later_ineligible(bins)),
        ("host_update_explicit_only", lambda: scenarios.update_explicit_only(bins)),
        ("host_update_opt_in", lambda: scenarios.update_opt_in(bins)),
        ("host_update_check_available", lambda: scenarios.update_check_available(bins)),
        ("host_update_apply", lambda: scenarios.update_apply(bins)),
        ("host_update_offline", lambda: scenarios.update_offline(bins)),
        ("host_update_ineligible", lambda: scenarios.update_ineligible(bins)),
        ("host_activation_timeout", lambda: scenarios.activation_timeout(bins)),
    ]


def main():
    parser = argparse.ArgumentParser(description="Record licence activation evidence.")
    parser.add_argument("--demos", default="", help="Also render PNG and MP4 demos into this directory.")
    args = parser.parse_args()
    directory = evidence_dir()
    sha = git_sha()
    system = host.system_name()
    results = {case_id: {"id": case_id, "status": "fail", "detail": "not run"} for case_id in OWNED}
    demo_failed = False
    try:
        bindir = directory / "bin"
        bindir.mkdir(parents=True, exist_ok=True)
        bins = build(bindir)
        for case_id, fn in cases(bins):
            run_case(results, case_id, fn)
        if args.demos:
            capture = ROOT / "tools" / "capture"
            sys.path.insert(0, str(capture))
            import lifecycle
            print(f"DEMOS {args.demos}", flush=True)
            demo_ok, demo_detail = lifecycle.render(Path(args.demos), bins)
            print(f"DEMOS {'pass' if demo_ok else 'fail'} {demo_detail}", flush=True)
            demo_failed = not demo_ok
    except Exception as err:
        traceback.print_exc()
        for case_id in OWNED:
            if results[case_id]["detail"] == "not run":
                results[case_id]["detail"] = squash(f"stopped: {type(err).__name__}: {err}")
    path = emit(directory, sha, system, results)
    print(f"WROTE {path}", flush=True)
    failed = [case["id"] for case in results.values() if case["status"] != "pass"]
    if failed or demo_failed:
        print(f"FAILED {', '.join(failed)}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
