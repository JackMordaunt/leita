"""Bounded first-run and activation stills of the real host, using local fixtures.

The licence lifecycle producer runs this matrix on each native OS. This module
does not inject view answers, launch a browser, or generate videos.
"""

import argparse
import hashlib
import html
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

LIFECYCLE = Path(__file__).resolve().parents[1] / "test-licence-lifecycle"
sys.path.insert(0, str(LIFECYCLE))

import fixture
import host
import scenarios
from suite import ROOT

TRIAL = "You can try Pro for 30 more days."
MALFORMED = "That is not a licence key: paste the key from your receipt, or a licence beginning leita."
REFUNDED = "This licence key has been refunded."
BUY = "http://127.0.0.1:9/buy"
SIZES = ("1280x820", "480x360")
THEMES = ("light", "dark")
CASES = ("first-run", "trial-over", "activated", "malformed", "unknown-404", "refunded", "offline", "server-500")


def run_one(bins, out, theme, size, name):
    work = host.make_work("leita-activation-ui-")
    shop = fixture.Shop()
    shop.lines[scenarios.KEY_OK] = bins.line
    shop.replies["FIXTURE-REFUNDED"] = (403, {"error": "revoked", "message": REFUNDED})
    shop.replies[scenarios.KEY_HTTP] = (500, {"message": "busy"})
    shop.stall.add(scenarios.KEY_STALL)
    shop.stall_seconds = 45
    dest = out / theme / size
    dest.mkdir(parents=True, exist_ok=True)
    png = dest / f"{name}.png"
    tags = dest / f"{name}.txt"
    try:
        data = work / "data"
        if name == "first-run":
            data.mkdir()
        else:
            host.prepare_data(data)
        target = host.make_target(work / "target")
        isolated_home = work / "home"
        isolated_home.mkdir()
        env = host.base_env(isolated_home)
        env.update({"CAPTURE_SIZE": size, "LEITA_RELEASE_BASE": scenarios.DEAD_RELEASE,
                    "LEITA_BUY_URL": BUY, "LEITA_SYNTHETIC": ""})
        with fixture.ActivationServer(shop) as server:
            env["LEITA_ACTIVATE_URL"] = scenarios.DEAD_ACTIVATE if name == "offline" else server.url
            steps = ["-await", "Done"]
            if name == "trial-over":
                steps += ["-await", host.TRIAL_OVER]
            if name == "first-run":
                steps += ["-absent", host.TRIAL_OVER]
                steps += ["-png", str(dest / "first-scan.png")]
            steps += ["-click", "Settings", "-click", "Licence", "-await", scenarios.FIELD]
            expected_posts = 0
            expected_key = ""
            expected_line = ""
            if name in ("first-run", "trial-over"):
                if name == "first-run":
                    steps += ["-await", TRIAL]
                steps += ["-reveal", "Buy a licence", "-click-top", "Buy a licence", "-expect-url", BUY]
            else:
                key, result = {
                    "activated": (scenarios.KEY_OK, host.LICENSED),
                    "malformed": ("not a key", MALFORMED),
                    "unknown-404": (scenarios.KEY_UNKNOWN, host.UNKNOWN_KEY),
                    "refunded": ("FIXTURE-REFUNDED", REFUNDED),
                    "offline": (scenarios.KEY_OK, host.UNREACHABLE),
                    "server-500": (scenarios.KEY_HTTP, host.SERVER_BUSY),
                    "timeout": (scenarios.KEY_STALL, host.SERVER_SLOW),
                }[name]
                steps += ["-reveal", scenarios.FIELD, "-click", scenarios.FIELD, "-type", key,
                          "-advance", "2", "-click-top", scenarios.ADD]
                if name == "timeout":
                    steps += ["-await", "Adding…", "-png", str(dest / "activation-pending.png")]
                steps += ["-await", result, "-absent", "Adding…"]
                expected_posts = 0 if name in ("offline", "malformed") else 1
                expected_key = key if expected_posts else ""
                expected_line = bins.line if name == "activated" else ""
                # A small window scrolls. Show the identity on success, or
                # the field's refusal below it, without pretending an offscreen
                # tag is a visible result.
                steps += ["-scroll", "Licence", "-20" if name == "activated" else "20", "-advance", "120"]
            steps += ["-png", str(png), "-tags", str(tags), "-click-top", "Close",
                      "-advance", "20", "-absent", scenarios.FIELD]
            started = time.monotonic()
            host.run_capture(bins.capture_eligible, target, data, theme, steps, env, timeout=160)
            elapsed = time.monotonic() - started
            line = host.stored_text(data / "licence")
            receipt = host.stored_text(data / "licence-key")
            expected_receipt = scenarios.KEY_OK if name == "activated" else ""
            ok = (len(shop.seen) == expected_posts and line == expected_line and receipt == expected_receipt)
            if expected_posts:
                ok = ok and shop.seen[0]["key"] == expected_key and scenarios.uses_fixture_agent(shop)
            if name == "first-run":
                stamp = int((data / "first-use").read_text().strip())
                ok = ok and abs(stamp - int(time.time())) < 120
            if name == "timeout":
                ok = ok and 29 <= elapsed < 90
            result = {"case": name, "theme": theme, "size": size, "ok": bool(ok),
                      "posts": len(shop.seen), "stored_line": bool(line), "stored_receipt": bool(receipt),
                      "elapsed_seconds": round(elapsed, 3), "png": png.relative_to(out).as_posix()}
            if name == "first-run":
                result["first_scan_png"] = (dest / "first-scan.png").relative_to(out).as_posix()
            return result
    finally:
        shutil.rmtree(work, ignore_errors=True)


def render(out, bins):
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for theme in THEMES:
        for size in SIZES:
            for name in CASES:
                print(f"ACTIVATION {theme}/{size}/{name}", flush=True)
                try:
                    result = run_one(bins, out, theme, size, name)
                except Exception as err:
                    result = {"case": name, "theme": theme, "size": size, "ok": False,
                              "error": " ".join(str(err).split())[-1200:]}
                results.append(result)
                print(f"ACTIVATION {'pass' if result['ok'] else 'fail'} {result}", flush=True)
    # One real 30s timeout proves the request settles. The view regression
    # covers both themes at the small size without another minute of sleeps.
    try:
        results.append(run_one(bins, out, "light", SIZES[0], "timeout"))
    except Exception as err:
        results.append({"case": "timeout", "theme": "light", "size": SIZES[0],
                        "ok": False, "error": " ".join(str(err).split())[-1200:]})
    document = {
        "schema": 1, "fixture": "throwaway-ed25519", "production_signature": False,
        "os": host.system_name(), "machine": platform.machine(), "platform": platform.platform(),
        "source_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        "jm_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=host.jm_path(), text=True).strip(),
        "jm_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=host.jm_path(), text=True).strip()),
        "jm_override": bool(os.environ.get("JM")),
        "capture_sha256": hashlib.sha256(Path(bins.capture_eligible).read_bytes()).hexdigest(),
        "sizes": SIZES, "themes": THEMES, "cases": results,
        "disclosures": ["Native host and view; theme choices do not emulate another operating system.",
                        "Loopback fixture only. Buy is observed through the probe; no browser is launched.",
                        "Each case owns generated files and state; none reads the user's Leita data.",
                        "The timeout uses the real 30 second client deadline. No videos or golden-image comparisons."],
    }
    document["png_sha256"] = {path.relative_to(out).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted(out.glob("*/*/*.png"))}
    (out / "manifest.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    figures = []
    for result in results:
        title = f"{result['theme']} / {result['size']} / {result['case']}: {'pass' if result['ok'] else 'fail'}"
        if "png" in result:
            figures.append(f'<figure><figcaption>{html.escape(title)}</figcaption><img src="{html.escape(result["png"])}" alt="{html.escape(title)}"></figure>')
        if "first_scan_png" in result:
            figures.append(f'<figure><figcaption>{html.escape(result["theme"])} / {html.escape(result["size"])} / first scan</figcaption><img src="{html.escape(result["first_scan_png"])}" alt="The first scan completes while the trial is open"></figure>')
    page = ('<!doctype html><meta charset="utf-8"><title>Leita activation review</title>'
            '<style>body{font:16px sans-serif;margin:24px}img{width:100%;max-width:1000px}figure{margin:24px 0}</style>'
            '<h1>Leita activation review</h1><p>Native ' + html.escape(document['platform']) +
            '. Local throwaway fixtures; no production requests. <a href="manifest.json">Assertions and provenance</a>.</p>' + ''.join(figures))
    (out / "index.html").write_text(page, encoding="utf-8")
    passed = sum(item["ok"] for item in results)
    return passed == len(results), f"{passed}/{len(results)} first-run/activation cases; stills and provenance in {out}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    import harness
    out = Path(args.out).resolve()
    bindir = out / ".bins"
    try:
        bins = harness.build(bindir)
        ok, detail = render(out, bins)
        print(detail, flush=True)
        return 0 if ok else 1
    finally:
        shutil.rmtree(bindir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
