# Headless licence and update demos of the real capture host.
#
# PNGs and MP4s are written to the directory given on the command line, never
# into the repository. Keys are throwaway and minted in process. The fixture
# sleeps on a release GET so "Checking for updates…" is visible; that is not a
# scheduler clock. There is no automatic-update preference in this build.

import argparse
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

LIFECYCLE = Path(__file__).resolve().parents[1] / "test-licence-lifecycle"
sys.path.insert(0, str(LIFECYCLE))

import fixture
import host
import scenarios
from suite import ROOT

DISCLOSURES = [
    "Throwaway Ed25519 keys were minted in this process. production_signature is false. No request was sent to mordaunt.dev or GitHub.",
    "The trial-over state is a real first-use file stamped 40 days before the run, beside the isolated history file. It is not an injected query answer.",
    "Checking for updates is delayed by the local release fixture sleeping on each GET. No scheduler clock was simulated. This build has no automatic-update preference; the idle About panel is the explicit-only state, and there is no on-switch to show.",
    "The licence dialog shows the licensee, tier, order and issued instant. It does not show paidThrough. A later ineligible build keeps the line and locks PDF export. An eligible build refuses a newer release in the update result.",
    "The activation timeout still is the client's real 30 second limit. The fixture accepts the request and does not answer.",
    "Update apply replaces a throwaway copy of the capture binary with fixture bytes and does not relaunch it. Videos use libx264, CRF 18, yuv420p, faststart, preset fast, 30 fps.",
]


def attempt(results, name, fn):
    print(f"DEMO {name}", flush=True)
    try:
        ok, detail = fn()
    except Exception as err:
        ok, detail = False, f"{type(err).__name__}: {err}"
    detail = " ".join(str(detail).split())
    if len(detail) > 600:
        detail = detail[:600]
    results.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"DEMO {name} {'pass' if ok else 'fail'} {detail}", flush=True)
    return ok


def encode(frames, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-framerate", "30", "-i", str(Path(frames) / "%05d.png"),
            "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return False, proc.stderr.strip() or f"ffmpeg exited {proc.returncode}"
    return True, f"frames={len(list(Path(frames).glob('*.png')))}"


def movie(bins, theme, dest, steps, activate_shop, release, line="", receipt="", copy=False, extra=None, delay=0):
    """Record a movie, then encode whatever frames were written."""
    work = host.make_work("leita-movie-")
    frames = work / "frames"
    frames.mkdir()
    prefix = str(frames) + os.sep
    scripted = []
    for step in steps:
        scripted.append(prefix if step == "{prefix}" else step)
    error = ""
    try:
        try:
            if activate_shop is None:
                host.run_host(
                    bins.capture_eligible, work, scripted, scenarios.DEAD_ACTIVATE,
                    release if isinstance(release, str) else "", theme=theme, timeout=180,
                    copy=copy, line=line, receipt=receipt, extra=extra,
                )
            else:
                with fixture.ActivationServer(activate_shop) as server:
                    release_url = release.url if hasattr(release, "url") else release
                    host.run_host(
                        bins.capture_eligible, work, scripted, server.url, release_url,
                        theme=theme, timeout=180, copy=copy, line=line, receipt=receipt, extra=extra,
                    )
        except Exception as err:
            error = f"{type(err).__name__}: {err}"
        count = len(list(frames.glob("*.png")))
        encoded, encode_detail = (False, "no frames")
        if count:
            encoded, encode_detail = encode(frames, dest)
        ok = error == "" and encoded and count >= 30
        return ok, f"frames={count} {encode_detail} {error}".strip()
    finally:
        scenarios.finish(work)


def movie_activation(bins, theme, dest):
    shop = fixture.Shop()
    shop.lines[scenarios.KEY_OK] = bins.line
    steps = [
        "-await", "Done",
        "-movie", "{prefix}",
        "-cue", "Free",
        "-hold", "12",
        "-cue", "Open Licence",
        "-tap", "Settings",
        "-tap", "Licence",
        "-tap", scenarios.FIELD,
        "-type", scenarios.KEY_OK,
        "-hold", "12",
        "-cue", "Exchange the key",
        "-tap", scenarios.ADD,
        "-hold", "50",
        "-await", host.LICENSED,
        "-hold", "12",
        "-end-movie",
    ]
    return movie(bins, theme, dest, steps, shop, scenarios.DEAD_RELEASE)


def movie_update(bins, theme, dest):
    work_release = host.make_work("leita-movie-rel-")
    try:
        directory = work_release / "release"
        scenarios.write_signed_release(
            directory, scenarios.VERSION_OK, scenarios.RELEASED_OK, scenarios.ASSET_OK, bins.update.seed,
        )
        with fixture.ReleaseServer(directory, delay=0.25) as server:
            steps = [
                "-await", "Done",
                "-movie", "{prefix}",
                "-cue", "About",
                "-tap", "Settings",
                "-tap", "About Leita",
                "-hold", "8",
                "-cue", "Check for updates",
                "-tap", "Check for updates",
                "-hold", "40",
                "-cue", "Install",
                "-tap", "Update",
                "-hold", "50",
                "-await", scenarios.APPLIED,
                "-hold", "12",
                "-end-movie",
            ]
            return movie(
                bins, theme, dest, steps, None, server.url, line=bins.line, copy=True,
                extra={"LEITA_LICENCE": bins.line},
            )
    finally:
        scenarios.finish(work_release)


def movie_ineligible(bins, theme, dest):
    work_release = host.make_work("leita-movie-late-")
    try:
        directory = work_release / "release"
        scenarios.write_signed_release(
            directory, scenarios.VERSION_LATE, scenarios.RELEASED_LATE, scenarios.ASSET_LATE, bins.update.seed,
        )
        with fixture.ReleaseServer(directory) as server:
            steps = [
                "-await", "Done",
                "-click", "Settings",
                "-click", "About Leita",
                "-await", host.UPDATE_PRIVACY,
                "-click", "Check for updates",
                "-await", scenarios.AVAILABLE_LATE,
                "-movie", "{prefix}",
                "-cue", "This release is after Pro",
                "-tap", "Update",
                "-hold", "30",
                "-await", scenarios.INELIGIBLE_MESSAGE,
                "-hold", "15",
                "-end-movie",
            ]
            return movie(
                bins, theme, dest, steps, None, server.url, line=bins.line, copy=True,
                extra={"LEITA_LICENCE": bins.line},
            )
    finally:
        scenarios.finish(work_release)


def revision(path):
    try:
        return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def contact_sheet(out, pngs):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return False
    if not pngs:
        return False
    thumb_w = 420
    label_h = 36
    thumbs = []
    for path in pngs:
        image = Image.open(path).convert("RGB")
        height = max(1, int(image.height * thumb_w / image.width))
        thumbs.append((path, image.resize((thumb_w, height))))
    columns = 4
    rows = (len(thumbs) + columns - 1) // columns
    cell_h = max(image.height for _, image in thumbs) + label_h
    sheet = Image.new("RGB", (columns * thumb_w, rows * cell_h), "white")
    draw = ImageDraw.Draw(sheet)
    for index, (path, image) in enumerate(thumbs):
        x = (index % columns) * thumb_w
        y = (index // columns) * cell_h
        sheet.paste(image, (x, y + label_h))
        draw.text((x + 8, y + 8), f"{path.parent.name}/{path.name}", fill="black")
    sheet.save(out / "contact-sheet.png")
    return True


def write_index(out, results, captions):
    sections = []
    for theme in ("light", "dark"):
        figures = []
        for name, caption in captions:
            still = out / theme / name
            if not still.exists():
                continue
            figures.append(
                "<figure>"
                f"<img src=\"{html.escape(theme)}/{html.escape(name)}\" alt=\"{html.escape(caption)}\">"
                f"<figcaption>{html.escape(theme)} — {html.escape(caption)}</figcaption>"
                "</figure>"
            )
        movies = []
        for name, caption in (
            ("activate.mp4", "Free, then a licence key is exchanged, then this copy is licensed to ada@example.com."),
            ("update.mp4", "About, check, and install a signed eligible release. The fixture delays each GET."),
            ("ineligible.mp4", "A retained Pro copy refuses a release dated after paidThrough."),
        ):
            path = out / theme / name
            if path.exists():
                movies.append(
                    "<figure>"
                    f"<video controls src=\"{html.escape(theme)}/{html.escape(name)}\"></video>"
                    f"<figcaption>{html.escape(theme)} — {html.escape(caption)}</figcaption>"
                    "</figure>"
                )
        sections.append(f"<h2>{html.escape(theme)}</h2>" + "\n".join(figures + movies))
    rows = "\n".join(
        f"<li>{'pass' if item['ok'] else 'fail'} — {html.escape(item['name'])}: {html.escape(item['detail'])}</li>"
        for item in results
    )
    notes = "\n".join(f"<li>{html.escape(line)}</li>" for line in DISCLOSURES)
    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Leita licence and update captures</title>
<style>
body {{ font: 16px/1.4 sans-serif; margin: 2rem; max-width: 1100px; }}
img, video {{ width: 100%; height: auto; background: #ddd; }}
figure {{ margin: 1.5rem 0; }}
</style>
</head>
<body>
<h1>Leita licence and update captures</h1>
<p>These are frames of the headless app host and view, driven with clicks and typed keys against a local fixture. They are not drawings and they are not screenshots of the test runner.</p>
<ul>{notes}</ul>
<p><a href="contact-sheet.png">Contact sheet</a> · <a href="manifest.json">manifest.json</a></p>
{''.join(sections)}
<h2>Assertions</h2>
<ul>{rows}</ul>
</body>
</html>
"""
    (out / "index.html").write_text(page, encoding="utf-8")


def write_manifest(out, results):
    sha = revision(ROOT)
    jm = revision(os.environ.get("JM") or ROOT / "jm")
    dirty = ""
    try:
        dirty = subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        dirty = ""
    document = {
        "schema": 1,
        "fixture": "throwaway-ed25519",
        "production_signature": False,
        "git_sha": sha,
        "jm_sha": jm,
        "dirty": dirty != "",
        "capture_version": "v0.1.0",
        "eligible_released": host.ELIGIBLE_RELEASED,
        "later_released": host.LATER_RELEASED,
        "paid_through": host.PAID_THROUGH,
        "encode": {"codec": "libx264", "crf": 18, "pix_fmt": "yuv420p", "preset": "fast", "fps": 30},
        "disclosures": DISCLOSURES,
        "scenarios": results,
    }
    (out / "manifest.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


CAPTIONS = [
    ("free.png", "Free after the 30-day evaluation. The licence dialog asks for a key. The shop received no request."),
    ("activated.png", "The key was exchanged over HTTP and the dialog now says Licensed to ada@example.com."),
    ("invalid-key.png", "The shop answered 404 for an unknown key. Nothing was stored."),
    ("network.png", "The activation port refused the connection."),
    ("tampered.png", "The signed reply was altered. The host rejected it and stored nothing."),
    ("persisted-pro.png", "A stored eligible line still verifies. The shop would 404 and received no request."),
    ("ineligible-build.png", "The same line is kept, and PDF export is locked because this build is one second after paidThrough."),
    ("updates-idle.png", "About, before any check. There is no automatic-update switch in this build."),
    ("updates-checking.png", "A check is in flight. The fixture is delaying the release GETs."),
    ("updates-available.png", "Version v0.2.0 is available. The asset was not downloaded yet."),
    ("updates-applied.png", "The throwaway copy was replaced. The dialog says to restart."),
    ("updates-offline.png", "The release port refused the connection."),
    ("updates-ineligible.png", "Retained Pro refused v0.9.0 because that release is after paidThrough."),
    ("activation-timeout.png", "The shop accepted the key and never answered. The client stopped at its real 30 second limit."),
]


def render(out, bins):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for theme in ("light", "dark"):
        dest = out / theme
        dest.mkdir(parents=True, exist_ok=True)
        attempt(results, f"{theme}/free", lambda theme=theme, dest=dest: scenarios.free_dialog(bins, theme, dest / "free.png"))
        attempt(results, f"{theme}/activated", lambda theme=theme, dest=dest: scenarios.activation_http(bins, theme, dest / "activated.png"))
        attempt(results, f"{theme}/invalid", lambda theme=theme, dest=dest: scenarios.activation_invalid(bins, theme, dest / "invalid-key.png"))
        attempt(results, f"{theme}/network", lambda theme=theme, dest=dest: scenarios.activation_unreachable(bins, theme, dest / "network.png"))
        attempt(results, f"{theme}/tampered", lambda theme=theme, dest=dest: scenarios.activation_tampered(bins, theme, dest / "tampered.png"))
        attempt(results, f"{theme}/persisted", lambda theme=theme, dest=dest: scenarios.pro_persisted(bins, theme, dest / "persisted-pro.png", export=True))
        attempt(results, f"{theme}/later", lambda theme=theme, dest=dest: scenarios.pro_later_ineligible(bins, theme, dest / "ineligible-build.png"))
        attempt(results, f"{theme}/idle", lambda theme=theme, dest=dest: scenarios.update_explicit_only(bins, theme, dest / "updates-idle.png"))
        attempt(
            results, f"{theme}/check",
            lambda theme=theme, dest=dest: scenarios.update_check_available(
                bins, theme, checking_png=dest / "updates-checking.png", available_png=dest / "updates-available.png",
            ),
        )
        attempt(results, f"{theme}/applied", lambda theme=theme, dest=dest: scenarios.update_apply(bins, theme, dest / "updates-applied.png"))
        attempt(results, f"{theme}/offline", lambda theme=theme, dest=dest: scenarios.update_offline(bins, theme, dest / "updates-offline.png"))
        attempt(results, f"{theme}/ineligible", lambda theme=theme, dest=dest: scenarios.update_ineligible(bins, theme, dest / "updates-ineligible.png"))
        attempt(results, f"{theme}/movie-activate", lambda theme=theme, dest=dest: movie_activation(bins, theme, dest / "activate.mp4"))
        attempt(results, f"{theme}/movie-update", lambda theme=theme, dest=dest: movie_update(bins, theme, dest / "update.mp4"))
        attempt(results, f"{theme}/movie-ineligible", lambda theme=theme, dest=dest: movie_ineligible(bins, theme, dest / "ineligible.mp4"))
        attempt(results, f"{theme}/timeout", lambda theme=theme, dest=dest: scenarios.activation_timeout(bins, theme, dest / "activation-timeout.png"))
    pngs = sorted(path for path in out.glob("*/*.png"))
    sheet = contact_sheet(out, pngs)
    write_index(out, results, CAPTIONS)
    write_manifest(out, results)
    passed = sum(1 for item in results if item["ok"])
    detail = f"{passed}/{len(results)} demo scenarios passed"
    if not sheet:
        detail += "; contact sheet was not written"
    return passed == len(results) and len(results) > 0 and sheet, detail


def main():
    parser = argparse.ArgumentParser(description="Render licence and update demos.")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    import harness
    bindir = Path(args.out) / ".bins"
    bins = harness.build(bindir)
    try:
        ok, detail = render(Path(args.out), bins)
    finally:
        shutil.rmtree(bindir, ignore_errors=True)
    print(detail, flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
