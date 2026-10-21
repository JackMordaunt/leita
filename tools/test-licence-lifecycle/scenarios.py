# Shared licence and update flows for the evidence harness and the capture demos.
# GUI state comes from the capture host. A pre-seeded line, receipt or first-use
# file is the on-disk state that host reads. Nothing here injects a query answer.

import shutil

import fixture
import host

KEY_OK = "FIXTURE-KEY-OK"
KEY_UNKNOWN = "FIXTURE-KEY-UNKNOWN"
KEY_HTTP = "FIXTURE-KEY-HTTP"
KEY_TAMPER = "FIXTURE-KEY-TAMPER"
KEY_STALL = "FIXTURE-KEY-STALL"
KEY_RECOVER = "FIXTURE-KEY-RECOVER"
KEY_RECOVER_MISS = "FIXTURE-KEY-RECOVER-MISS"

DEAD_ACTIVATE = "http://127.0.0.1:9/activate"
DEAD_RELEASE = "http://127.0.0.1:9"
USER_AGENT = "leita/v0.1.0"

VERSION_OK = "v0.2.0"
RELEASED_OK = "2026-12-01T00:00:00Z"
VERSION_LATE = "v0.9.0"
RELEASED_LATE = "2027-06-01T00:00:00Z"
ASSET_OK = b"leita fixture window v0.2.0\n"
ASSET_LATE = b"leita fixture window v0.9.0\n"

AVAILABLE = f"Version {VERSION_OK} of Leita is available."
AVAILABLE_LATE = f"Version {VERSION_LATE} of Leita is available."
APPLIED = "Updated. Restart Leita to use the new version."
INELIGIBLE_MESSAGE = (
    "The update failed: this copy is still Pro through "
    f"{host.PAID_THROUGH}; {VERSION_LATE} was released {RELEASED_LATE}, "
    "which is after that, so it was not installed"
)
FIELD = "Licence to add"
ADD = "Add licence"


def finish(work):
    shutil.rmtree(work, ignore_errors=True)


def licence_file(data):
    return data / "licence"


def receipt_file(data):
    return data / "licence-key"


def uses_fixture_agent(shop):
    bad = [hit.get("user_agent", "") for hit in shop.seen if hit.get("user_agent") != USER_AGENT]
    return not bad


def add_key(key, result_tag):
    return [
        "-await", "Done",
        "-click", "Settings",
        "-click", "Licence",
        "-await", FIELD,
        "-click", FIELD,
        "-type", key,
        "-advance", "2",
        "-click", ADD,
        "-await", result_tag,
    ]


def show_licence():
    return ["-await", "Done", "-click", "Settings", "-click", "Licence", "-await", host.LICENSED]


def open_about():
    return ["-await", "Done", "-click", "Settings", "-click", "About Leita", "-await", host.UPDATE_PRIVACY]


def host_asset():
    return fixture.host_asset("window")


def write_signed_release(directory, version, released, payload, seed):
    fixture.write_release(directory, {host_asset(): payload}, version, released, seed)


def free_dialog(bins, theme="light", png=None):
    """Trial already over, licence dialog open, and the shop was not called."""
    work = host.make_work("leita-free-")
    steps = [
        "-await", "Done",
        "-await", host.TRIAL_OVER,
        "-click", "Settings",
        "-click", "Licence",
        "-await", FIELD,
    ]
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        with fixture.ActivationServer(shop) as server:
            host.run_host(bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme)
            ok = len(shop.seen) == 0
            return ok, f"posts={len(shop.seen)} dialog=licence-to-add"
    finally:
        finish(work)


def activation_http(bins, theme="light", png=None):
    """One POST, then a second process verifies the stored line with no server."""
    work = host.make_work("leita-act-")
    steps = add_key(KEY_OK, host.LICENSED)
    if png:
        steps.append("-png")
        steps.append(str(png))
    try:
        shop = fixture.Shop()
        shop.lines[KEY_OK] = bins.line
        with fixture.ActivationServer(shop) as server:
            host.run_host(
                bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme, timeout=90,
            )
            stored = host.stored_text(licence_file(work / "data"))
            receipt = host.stored_text(receipt_file(work / "data"))
            first = len(shop.seen) == 1 and shop.seen[0]["key"] == KEY_OK and uses_fixture_agent(shop)
            offline_steps = show_licence()
            host.run_host(
                bins.capture_eligible, work, offline_steps, DEAD_ACTIVATE, DEAD_RELEASE,
                theme=theme, timeout=90, fresh=False,
            )
            still = host.stored_text(licence_file(work / "data"))
            ok = first and stored == bins.line and receipt == KEY_OK and still == bins.line and len(shop.seen) == 1
            detail = f"posts={len(shop.seen)} stored={stored == bins.line} receipt={receipt == KEY_OK} offline={still == bins.line}"
            return ok, detail
    finally:
        finish(work)


def receipt_recovery(bins, theme="light"):
    """Rotation succeeds once, and a 404 does not retry or replace the line."""
    ok_new, detail_new = _recover_success(bins, theme)
    ok_miss, detail_miss = _recover_miss(bins, theme)
    return ok_new and ok_miss, f"rotation: {detail_new}; miss: {detail_miss}"


def _recover_success(bins, theme):
    work = host.make_work("leita-rot-")
    try:
        shop = fixture.Shop()
        shop.lines[KEY_RECOVER] = bins.line
        with fixture.ActivationServer(shop) as server:
            host.run_host(
                bins.capture_eligible, work, show_licence(), server.url, DEAD_RELEASE,
                theme=theme, timeout=90, line=bins.old_line, receipt=KEY_RECOVER,
            )
            stored = host.stored_text(licence_file(work / "data"))
            once = len(shop.seen) == 1 and shop.seen[0]["key"] == KEY_RECOVER
            host.run_host(
                bins.capture_eligible, work, show_licence(), DEAD_ACTIVATE, DEAD_RELEASE,
                theme=theme, timeout=90, fresh=False,
            )
            still = host.stored_text(licence_file(work / "data"))
            ok = once and stored == bins.line and still == bins.line and len(shop.seen) == 1
            return ok, f"posts={len(shop.seen)} replaced={stored == bins.line} second_offline={still == bins.line}"
    finally:
        finish(work)


def _recover_miss(bins, theme):
    work = host.make_work("leita-miss-")
    before = bins.old_line
    try:
        shop = fixture.Shop()
        with fixture.ActivationServer(shop) as server:
            steps = [
                "-await", host.UNKNOWN_KEY,
                "-await", "Done",
                "-advance", "40",
                "-await", host.UNKNOWN_KEY,
            ]
            host.run_host(
                bins.capture_eligible, work, steps, server.url, DEAD_RELEASE,
                theme=theme, timeout=90, line=before, receipt=KEY_RECOVER_MISS,
            )
            stored = host.stored_text(licence_file(work / "data"))
            ok = len(shop.seen) == 1 and shop.seen[0]["key"] == KEY_RECOVER_MISS and stored == before
            return ok, f"posts={len(shop.seen)} unchanged={stored == before}"
    finally:
        finish(work)


def activation_invalid(bins, theme="light", png=None):
    work = host.make_work("leita-bad-")
    steps = add_key(KEY_UNKNOWN, host.UNKNOWN_KEY)
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        shop.lines[KEY_OK] = bins.line
        with fixture.ActivationServer(shop) as server:
            host.run_host(bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme)
            stored = host.stored_text(licence_file(work / "data"))
            ok = len(shop.seen) == 1 and stored == ""
            return ok, f"posts={len(shop.seen)} no_line={stored == ''}"
    finally:
        finish(work)


def activation_tampered(bins, theme="light", png=None):
    work = host.make_work("leita-tamp-")
    steps = add_key(KEY_TAMPER, host.NOT_SIGNED)
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        shop.lines[KEY_TAMPER] = fixture.tamper_line(bins.line)
        with fixture.ActivationServer(shop) as server:
            host.run_host(bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme)
            stored = host.stored_text(licence_file(work / "data"))
            ok = len(shop.seen) == 1 and stored == ""
            return ok, f"posts={len(shop.seen)} rejected={stored == ''}"
    finally:
        finish(work)


def activation_http_error(bins, theme="light", png=None):
    work = host.make_work("leita-500-")
    steps = add_key(KEY_HTTP, host.SERVER_BUSY)
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        shop.replies[KEY_HTTP] = (500, {"message": "busy"})
        with fixture.ActivationServer(shop) as server:
            host.run_host(bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme)
            ok = len(shop.seen) == 1 and host.stored_text(licence_file(work / "data")) == ""
            return ok, f"posts={len(shop.seen)} status=500"
    finally:
        finish(work)


def activation_timeout(bins, theme="light", png=None):
    """The client's real 30s timeout. The fixture stalls longer and is woken on close."""
    work = host.make_work("leita-slow-")
    steps = add_key(KEY_STALL, host.SERVER_SLOW)
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        shop.stall.add(KEY_STALL)
        shop.stall_seconds = 45
        with fixture.ActivationServer(shop) as server:
            host.run_host(
                bins.capture_eligible, work, steps, server.url, DEAD_RELEASE, theme=theme, timeout=160,
            )
            ok = len(shop.seen) == 1 and host.stored_text(licence_file(work / "data")) == ""
            return ok, f"posts={len(shop.seen)} client_timeout=30s"
    finally:
        finish(work)


def activation_unreachable(bins, theme="light", png=None):
    work = host.make_work("leita-down-")
    steps = add_key(KEY_OK, host.UNREACHABLE)
    if png:
        steps += ["-png", str(png)]
    try:
        host.run_host(bins.capture_eligible, work, steps, DEAD_ACTIVATE, DEAD_RELEASE, theme=theme)
        ok = host.stored_text(licence_file(work / "data")) == ""
        return ok, f"refused_port no_line={ok}"
    finally:
        finish(work)


def pro_persisted(bins, theme="light", png=None, export=False):
    """Eligible line, server would 404, zero posts, PDF export writes a file."""
    work = host.make_work("leita-pro-")
    try:
        shop = fixture.Shop()
        with fixture.ActivationServer(shop) as server:
            steps = show_licence()
            if png:
                steps += ["-png", str(png)]
            host.run_host(
                bins.capture_eligible, work, steps, server.url, DEAD_RELEASE,
                theme=theme, line=bins.line,
            )
            shown = len(shop.seen) == 0
            exported = True
            if export:
                pdf = work / "scan.pdf"
                export_steps = [
                    "-await", "Done",
                    "-click", "Settings",
                    "-click", "Export",
                    "-click", "PDF",
                    "-click", "Export",
                    "-pick", str(pdf),
                    "-await", f"Saved report to {pdf}",
                ]
                host.run_host(
                    bins.capture_eligible, work, export_steps, server.url, DEAD_RELEASE,
                    theme=theme, fresh=False,
                )
                exported = pdf.is_file() and pdf.read_bytes()[:5] == b"%PDF-"
            ok = shown and exported and len(shop.seen) == 0
            return ok, f"posts={len(shop.seen)} licensed_dialog pdf={exported}"
    finally:
        finish(work)


def pro_later_ineligible(bins, theme="light", png=None):
    work = host.make_work("leita-later-")
    steps = [
        "-await", "Done",
        "-click", "Settings",
        "-click", "Export",
        "-click", "PDF",
        "-click", "Export",
        "-await", host.REPORTS_LOCKED,
        "-await", host.LICENSED,
    ]
    if png:
        steps += ["-png", str(png)]
    try:
        shop = fixture.Shop()
        with fixture.ActivationServer(shop) as server:
            host.run_host(
                bins.capture_later, work, steps, server.url, DEAD_RELEASE,
                theme=theme, line=bins.line,
            )
            ok = len(shop.seen) == 0 and host.stored_text(licence_file(work / "data")) == bins.line
            return ok, f"posts={len(shop.seen)} line_kept={ok}"
    finally:
        finish(work)


def update_explicit_only(bins, theme="light", png=None):
    work = host.make_work("leita-idle-")
    steps = open_about() + ["-absent", host.CHECKING, "-advance", "20", "-absent", host.CHECKING]
    if png:
        steps += ["-png", str(png)]
    try:
        directory = work / "release"
        write_signed_release(directory, VERSION_OK, RELEASED_OK, ASSET_OK, bins.update.seed)
        with fixture.ReleaseServer(directory) as server:
            host.run_host(bins.capture_eligible, work, steps, DEAD_ACTIVATE, server.url, theme=theme)
            ok = server.requests == []
            return ok, f"release_gets={len(server.requests)} no_preference_switch"
    finally:
        finish(work)


def update_check_available(bins, theme="light", idle_png=None, checking_png=None, available_png=None):
    work = host.make_work("leita-check-")
    steps = open_about()
    if idle_png:
        steps += ["-png", str(idle_png)]
    steps += ["-click", "Check for updates", "-await", host.CHECKING]
    if checking_png:
        steps += ["-png", str(checking_png)]
    steps += ["-await", AVAILABLE]
    if available_png:
        steps += ["-png", str(available_png)]
    try:
        directory = work / "release"
        write_signed_release(directory, VERSION_OK, RELEASED_OK, ASSET_OK, bins.update.seed)
        with fixture.ReleaseServer(directory, delay=0.8) as server:
            host.run_host(bins.capture_eligible, work, steps, DEAD_ACTIVATE, server.url, theme=theme, timeout=90)
            paths = [item["path"] for item in server.requests]
            agents = {item["user_agent"] for item in server.requests}
            ok = "sha256sums.txt" in paths and host_asset() not in paths and agents == {USER_AGENT}
            return ok, f"gets={paths} agents={sorted(agents)}"
    finally:
        finish(work)


def update_apply(bins, theme="light", png=None):
    work = host.make_work("leita-apply-")
    steps = open_about() + [
        "-click", "Check for updates",
        "-await", AVAILABLE,
        "-click", "Update",
        "-await", APPLIED,
    ]
    if png:
        steps += ["-png", str(png)]
    try:
        directory = work / "release"
        write_signed_release(directory, VERSION_OK, RELEASED_OK, ASSET_OK, bins.update.seed)
        with fixture.ReleaseServer(directory) as server:
            _proc, _data, exe = host.run_host(
                bins.capture_eligible, work, steps, DEAD_ACTIVATE, server.url,
                theme=theme, timeout=90, copy=True, extra={"LEITA_LICENCE": bins.line}, line=bins.line,
            )
            paths = [item["path"] for item in server.requests]
            got = exe.read_bytes()
            ok = got == ASSET_OK and host_asset() in paths
            return ok, f"replaced={got == ASSET_OK} asset_get={host_asset() in paths}"
    finally:
        finish(work)


def update_offline(bins, theme="light", png=None):
    work = host.make_work("leita-uoff-")
    steps = open_about() + ["-click", "Check for updates", "-await", host.UPDATE_UNREACHABLE]
    if png:
        steps += ["-png", str(png)]
    try:
        host.run_host(bins.capture_eligible, work, steps, DEAD_ACTIVATE, DEAD_RELEASE, theme=theme)
        return True, "release port refused"
    finally:
        finish(work)


def update_ineligible(bins, theme="light", png=None):
    work = host.make_work("leita-inelig-")
    steps = open_about() + [
        "-click", "Check for updates",
        "-await", AVAILABLE_LATE,
        "-click", "Update",
        "-await", INELIGIBLE_MESSAGE,
    ]
    if png:
        steps += ["-png", str(png)]
    try:
        directory = work / "release"
        write_signed_release(directory, VERSION_LATE, RELEASED_LATE, ASSET_LATE, bins.update.seed)
        with fixture.ReleaseServer(directory) as server:
            _proc, _data, exe = host.run_host(
                bins.capture_eligible, work, steps, DEAD_ACTIVATE, server.url,
                theme=theme, timeout=90, copy=True, extra={"LEITA_LICENCE": bins.line}, line=bins.line,
            )
            paths = [item["path"] for item in server.requests]
            ok = exe.read_bytes() != ASSET_LATE and host_asset() not in paths
            return ok, f"binary_kept={exe.read_bytes() != ASSET_LATE} asset_absent={host_asset() not in paths}"
    finally:
        finish(work)


def _cli_env(work, activate):
    env = host.base_env(work)
    env["LEITA_ACTIVATE_URL"] = activate
    env["LEITA_RELEASE_BASE"] = DEAD_RELEASE
    return env


def cli_add_offline(bins):
    work = host.make_work("leita-cli-add-")
    try:
        shop = fixture.Shop()
        with fixture.ActivationServer(shop) as server:
            env = _cli_env(work, server.url)
            added = host.run_cli(bins.cli_eligible, ["licence", "add", bins.line], env)
            shown = host.run_cli(bins.cli_eligible, ["licence"], env)
            text = host.stored_text(host.cli_licence_file(work))
            ok = (
                added.returncode == 0
                and shown.returncode == 0
                and text == bins.line
                and "this release is included" in shown.stdout
                and host.EMAIL in shown.stdout
                and len(shop.seen) == 0
            )
            detail = f"add={added.returncode} show={shown.returncode} posts={len(shop.seen)} text_ok={text == bins.line}"
            if not ok:
                detail += f" stdout={shown.stdout.strip()[:300]!r} stderr={added.stderr.strip()[:200]!r}"
            return ok, detail
    finally:
        finish(work)


def cli_tamper_keeps_file(bins):
    work = host.make_work("leita-cli-tamp-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        added = host.run_cli(bins.cli_eligible, ["licence", "add", bins.line], env)
        path = host.cli_licence_file(work)
        tampered = fixture.tamper_line(bins.line) + "\n"
        path.write_text(tampered, encoding="ascii")
        shown = host.run_cli(bins.cli_eligible, ["licence"], env)
        after = path.read_text(encoding="ascii")
        ok = added.returncode == 0 and shown.returncode != 0 and after == tampered and "does not hold" in shown.stderr
        return ok, f"show={shown.returncode} bytes_kept={after == tampered}"
    finally:
        finish(work)


def cli_unknown_key_refused(bins):
    work = host.make_work("leita-cli-key-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        refused = host.run_cli(bins.cli_eligible, ["licence", "add", "LEITA-SOLD-FIXTURE"], env)
        path = host.cli_licence_file(work)
        ok = refused.returncode != 0 and not path.exists() and "a licence key is exchanged" in refused.stderr
        return ok, f"exit={refused.returncode} no_file={not path.exists()}"
    finally:
        finish(work)


def cli_env_does_not_rewrite(bins):
    work = host.make_work("leita-cli-env-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        added = host.run_cli(bins.cli_eligible, ["licence", "add", bins.line], env)
        path = host.cli_licence_file(work)
        before = path.read_text(encoding="ascii")
        env["LEITA_LICENCE"] = bins.other_line
        shown = host.run_cli(bins.cli_eligible, ["licence"], env)
        after = path.read_text(encoding="ascii")
        ok = (
            added.returncode == 0
            and shown.returncode == 0
            and after == before
            and "ord_other" in shown.stdout
            and "for this run" in shown.stdout
        )
        return ok, f"show={shown.returncode} file_kept={after == before}"
    finally:
        finish(work)


def cli_remove(bins):
    work = host.make_work("leita-cli-rm-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        added = host.run_cli(bins.cli_eligible, ["licence", "add", bins.line], env)
        path = host.cli_licence_file(work)
        receipt = path.parent / "licence-key"
        receipt.write_text("FIXTURE-KEY-OK\n", encoding="ascii")
        removed = host.run_cli(bins.cli_eligible, ["licence", "remove"], env)
        ok = added.returncode == 0 and removed.returncode == 0 and not path.exists() and not receipt.exists()
        return ok, f"remove={removed.returncode} line_gone={not path.exists()} receipt_gone={not receipt.exists()}"
    finally:
        finish(work)


def cli_pro_at_paid_through(bins):
    work = host.make_work("leita-cli-pro-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        added = host.run_cli(bins.cli_eligible, ["licence", "add", bins.line], env)
        shown = host.run_cli(bins.cli_eligible, ["licence"], env)
        ok = added.returncode == 0 and "this release is included" in shown.stdout
        return ok, f"show={shown.returncode}"
    finally:
        finish(work)


def cli_free_after_paid_through(bins):
    work = host.make_work("leita-cli-free-")
    try:
        env = _cli_env(work, DEAD_ACTIVATE)
        added = host.run_cli(bins.cli_later, ["licence", "add", bins.line], env)
        shown = host.run_cli(bins.cli_later, ["licence"], env)
        ok = added.returncode == 0 and "after the paid-through date" in shown.stdout
        return ok, f"show={shown.returncode} stdout_has_cutoff={'after the paid-through date' in shown.stdout}"
    finally:
        finish(work)
