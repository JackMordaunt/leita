# Decide whether a release may publish from native lifecycle evidence.
#
# The evidence is what tools/test-lifecycle/harness.py writes after it runs
# packaged command lines. A throwaway signature in that run is not a
# production package signature: production_signature must be false.

import json
import sys
from pathlib import Path

ALL = ("linux", "darwin", "windows")
LINUX = ("linux",)

# status must be pass where the case applies, and na only on the other systems.
# blocked, fail, and a missing id stop the lifecycle job and publishing.
# activation_http and receipt_recovery are written by tools/test-licence-lifecycle.
# automatic_startup_check and automatic_daily_check are written by the scheduler harness.
# A symlink to a loose file is followed (update_symlink_loose_follows_real).
# A symlink to Program Files is refused (update_symlink_protected_refused).
REQUIRED = {
    "licence_persisted": ALL,
    "licence_offline": ALL,
    "licence_tampered": ALL,
    "licence_rotation_retained_key": ALL,
    "licence_rotation_dropped_key": ALL,
    "licence_pro_before_cutoff": ALL,
    "licence_pro_after_cutoff": ALL,
    "cli_key_not_activated": ALL,
    "cli_tampered_no_recovery": ALL,
    "startup_has_no_update_request": ALL,
    "activation_http": ALL,
    "receipt_recovery": ALL,
    "automatic_startup_check": ALL,
    "automatic_daily_check": ALL,
    "update_check_newer": ALL,
    "update_user_agent": ALL,
    "update_check_single": ALL,
    "update_apply_relaunch": ALL,
    "update_preserves_data": ALL,
    "update_preserves_pro": ALL,
    "update_bad_hash": ALL,
    "update_unreachable": ALL,
    "update_permissions": ALL,
    "update_interrupted": ALL,
    "update_keeps_old": ALL,
    "update_current_noop": ALL,
    "update_dev_refused": ALL,
    "update_bundle_refused": ALL,
    "update_installer_path_refused": ALL,
    "update_package_refused": LINUX,
    "update_journal_path_not_replaced": LINUX,
    "update_symlink_loose_follows_real": ALL,
    "update_peer_blocked": ALL,
    "update_lock_released_on_exit": ALL,
    "update_commit_killed_keeps_old": ALL,
    "update_commit_completes": ALL,
    "update_symlink_protected_refused": ALL,
    "linux_journal_alive_across_update": LINUX,
    "linux_journal_stop": LINUX,
    "linux_journal_restart": LINUX,
    "signing_required": ALL,
    "update_ineligible_needs_consent": ALL,
    "fixture_not_production": ALL,
    "packaged_archive": ALL,
    "packaged_deb_payload": LINUX,
    "packaged_rpm_payload": LINUX,
    "packaged_appimage": LINUX,
    "packaged_app": ("darwin",),
    "packaged_dmg": ("darwin",),
    "packaged_installer": ("windows",),
}

# evidence-*.json in one directory, excluding the merged evidence.json.
PRODUCER_GLOB = "evidence-*.json"


def select(runs, sha):
    """Newest lifecycle run for sha: (ready|waiting|failed, run or None)."""
    own = [r for r in runs if r.get("headSha") == sha]
    if not own:
        return "waiting", None
    own.sort(key=lambda r: int(r.get("databaseId") or 0), reverse=True)
    newest = own[0]
    if newest.get("status") != "completed":
        return "waiting", newest
    if newest.get("conclusion") != "success":
        return "failed", newest
    return "ready", newest


def case_map(doc):
    found = {}
    for case in doc.get("cases") or []:
        found[case.get("id")] = case.get("status")
    return found


def problems_for(doc, sha):
    """Problems in one operating system's merged evidence."""
    problems = []
    if doc.get("schema") != 1:
        problems.append(f"schema {doc.get('schema')} is not 1")
    if doc.get("production_signature") is not False:
        problems.append("production_signature is not false; a fixture is not a production signature")
    if doc.get("fixture") != "throwaway-ed25519":
        problems.append("fixture is not throwaway-ed25519")
    if doc.get("sha") != sha:
        problems.append(f"evidence sha {doc.get('sha')} is not {sha}")
    system = doc.get("os")
    if system not in ALL:
        problems.append(f"evidence os {system} is not one of linux, darwin, windows")
        return problems
    got = case_map(doc)
    for case_id, platforms in REQUIRED.items():
        status = got.get(case_id)
        if system in platforms:
            if status != "pass":
                problems.append(f"{system} {case_id} is {status}")
        elif status != "na":
            problems.append(f"{system} {case_id} should be na, not {status}")
    return problems


def judge(documents, sha):
    """Problems that stop publishing. One merged document per OS."""
    problems = []
    seen = {}
    for doc in documents:
        system = doc.get("os")
        if system in seen:
            problems.append(f"two evidence files for {system}")
        seen[system] = doc
        problems.extend(problems_for(doc, sha))
    for system in ALL:
        if system not in seen:
            problems.append(f"no evidence for {system}")
    return problems


def merge_documents(parts):
    """Union producer documents for one OS. Disagreeing statuses become fail.

    A producer that claims a production signature, another fixture, or another
    schema keeps that claim in the merge, so the gate rejects it.
    """
    if not parts:
        raise ValueError("no evidence to merge")
    system = parts[0].get("os")
    sha = parts[0].get("sha")
    cases = {}
    producers = []
    schema = 1
    production = False
    fixture = "throwaway-ed25519"
    for part in parts:
        if part.get("os") != system or part.get("sha") != sha:
            raise ValueError("evidence files disagree on os or sha")
        producers.append(part.get("producer") or "")
        if part.get("schema") != 1:
            schema = part.get("schema")
        if part.get("production_signature") is True:
            production = True
        if part.get("fixture") != "throwaway-ed25519":
            fixture = part.get("fixture")
        for case in part.get("cases") or []:
            case_id = case.get("id")
            previous = cases.get(case_id)
            if previous is not None and previous.get("status") != case.get("status"):
                cases[case_id] = {
                    "id": case_id,
                    "status": "fail",
                    "detail": "producers disagree on this case",
                }
            else:
                cases[case_id] = {
                    "id": case_id,
                    "status": case.get("status"),
                    "detail": case.get("detail") or "",
                }
    return {
        "schema": schema,
        "producer": "merged",
        "producers": producers,
        "sha": sha,
        "os": system,
        "production_signature": production,
        "fixture": fixture,
        "cases": [cases[k] for k in cases],
    }


def merge_directory(directory):
    directory = Path(directory)
    paths = sorted(directory.glob(PRODUCER_GLOB))
    parts = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
    if not parts:
        raise ValueError(f"no {PRODUCER_GLOB} in {directory}")
    merged = merge_documents(parts)
    out = directory / "evidence.json"
    out.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    return merged


def main(argv):
    if len(argv) < 2:
        print(
            "usage: gate.py select RUNS.json SHA | gate.py judge --sha SHA FILE..."
            " | gate.py local DIR SHA",
            file=sys.stderr,
        )
        return 2
    if argv[1] == "local":
        if len(argv) != 4:
            print("usage: gate.py local DIR SHA", file=sys.stderr)
            return 2
        try:
            merged = merge_directory(argv[2])
        except (ValueError, OSError, json.JSONDecodeError) as err:
            print(err, file=sys.stderr)
            return 1
        problems = problems_for(merged, argv[3])
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1 if problems else 0
    if argv[1] == "select":
        runs = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
        state, run = select(runs, argv[3])
        if state == "ready":
            print(f"ready {run['databaseId']}")
        elif state == "failed":
            print(f"failed {run.get('url', '')}")
        else:
            print("waiting")
        return 0
    if argv[1] == "judge":
        if argv[2] != "--sha":
            print("judge needs --sha SHA", file=sys.stderr)
            return 2
        sha = argv[3]
        docs = [json.loads(Path(p).read_text(encoding="utf-8")) for p in argv[4:]]
        problems = judge(docs, sha)
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1 if problems else 0
    print(f"unknown command {argv[1]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
