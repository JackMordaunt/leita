# The publish decision, without building leita. A passing judge result is not
# a claim that a production package was signed.

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import gate

SIBLING = (
    "activation_http",
    "receipt_recovery",
    "automatic_startup_check",
    "automatic_daily_check",
)


def document(system, sha="abc", status="pass"):
    cases = []
    for case_id, platforms in gate.REQUIRED.items():
        applied = "pass" if system in platforms else "na"
        if status != "pass" and system in platforms:
            applied = status
        cases.append({"id": case_id, "status": applied, "detail": ""})
    return {
        "schema": 1,
        "producer": "test",
        "sha": sha,
        "os": system,
        "production_signature": False,
        "fixture": "throwaway-ed25519",
        "cases": cases,
    }


class SelectTest(unittest.TestCase):
    def test_newest_failure_beats_an_older_success(self):
        runs = [
            {"databaseId": 1, "headSha": "abc", "status": "completed", "conclusion": "success"},
            {"databaseId": 2, "headSha": "abc", "status": "completed", "conclusion": "failure", "url": "http://example/fail"},
        ]
        state, run = gate.select(runs, "abc")
        self.assertEqual(state, "failed")
        self.assertEqual(run["databaseId"], 2)

    def test_in_progress_waits(self):
        runs = [{"databaseId": 3, "headSha": "abc", "status": "in_progress", "conclusion": ""}]
        state, run = gate.select(runs, "abc")
        self.assertEqual(state, "waiting")
        self.assertEqual(run["databaseId"], 3)

    def test_other_sha_waits(self):
        runs = [{"databaseId": 4, "headSha": "other", "status": "completed", "conclusion": "success"}]
        state, _ = gate.select(runs, "abc")
        self.assertEqual(state, "waiting")

    def test_select_command_prints_ready(self):
        runs = [{"databaseId": 9, "headSha": "abc", "status": "completed", "conclusion": "success"}]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "runs.json"
            path.write_text(json.dumps(runs), encoding="utf-8")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = gate.main(["gate.py", "select", str(path), "abc"])
            self.assertEqual(code, 0)
            self.assertEqual(buf.getvalue().strip(), "ready 9")


class JudgeTest(unittest.TestCase):
    def test_three_passing_os_publish(self):
        docs = [document(s) for s in gate.ALL]
        self.assertEqual(gate.judge(docs, "abc"), [])
        docs[0]["sha"] = "other"
        problems = gate.judge(docs, "abc")
        self.assertIn("evidence sha other is not abc", problems)

    def test_blocked_required_case_stops_publishing(self):
        docs = [document(s) for s in gate.ALL]
        for case in docs[0]["cases"]:
            if case["id"] == "signing_required":
                case["status"] = "blocked"
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("signing_required" in p for p in problems))

    def test_missing_os_stops_publishing(self):
        docs = [document("linux"), document("darwin")]
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("windows" in p for p in problems))

    def test_wrong_sha_stops_publishing(self):
        docs = [document(s, sha="nope") for s in gate.ALL]
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("sha" in p for p in problems))

    def test_production_signature_flag_stops_publishing(self):
        docs = [document(s) for s in gate.ALL]
        docs[1]["production_signature"] = True
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("production_signature" in p for p in problems))

    def test_missing_activation_stops_publishing(self):
        docs = [document(s) for s in gate.ALL]
        for doc in docs:
            doc["cases"] = [c for c in doc["cases"] if c["id"] != "activation_http"]
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("activation_http" in p for p in problems))

    def test_missing_schedule_stops_publishing(self):
        docs = [document(s) for s in gate.ALL]
        for doc in docs:
            doc["cases"] = [c for c in doc["cases"] if c["id"] not in ("automatic_startup_check", "automatic_daily_check")]
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("automatic_startup_check" in p for p in problems))
        self.assertTrue(any("automatic_daily_check" in p for p in problems))

    def test_linux_only_is_na_elsewhere(self):
        docs = [document(s) for s in gate.ALL]
        for case in docs[1]["cases"]:
            if case["id"] == "linux_journal_stop":
                case["status"] = "pass"
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("darwin linux_journal_stop" in p for p in problems))

    def test_packaged_app_is_na_off_darwin(self):
        docs = [document(s) for s in gate.ALL]
        for case in docs[0]["cases"]:
            if case["id"] == "packaged_app":
                case["status"] = "pass"
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("linux packaged_app" in p for p in problems))

    def test_schema_must_be_one(self):
        docs = [document(s) for s in gate.ALL]
        docs[0]["schema"] = 2
        problems = gate.judge(docs, "abc")
        self.assertTrue(any("schema" in p for p in problems))

    def test_symlink_case_is_required_on_every_os(self):
        self.assertEqual(gate.REQUIRED["update_symlink_loose_follows_real"], gate.ALL)


class MergeTest(unittest.TestCase):
    def test_disagreement_becomes_fail(self):
        a = document("linux")
        b = document("linux")
        b["producer"] = "licence"
        for case in b["cases"]:
            if case["id"] == "licence_persisted":
                case["status"] = "fail"
        merged = gate.merge_documents([a, b])
        got = gate.case_map(merged)
        self.assertEqual(got["licence_persisted"], "fail")
        self.assertEqual(got["licence_offline"], "pass")

    def test_production_claim_survives_the_merge(self):
        a = document("linux")
        b = document("linux")
        b["production_signature"] = True
        merged = gate.merge_documents([a, b])
        self.assertIs(merged["production_signature"], True)
        problems = gate.problems_for(merged, "abc")
        self.assertIn(
            "production_signature is not false; a fixture is not a production signature",
            problems,
        )

    def test_local_fails_when_a_sibling_case_is_missing(self):
        owned = document("linux")
        owned["producer"] = "update"
        owned["cases"] = [c for c in owned["cases"] if c["id"] not in SIBLING]
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "evidence-update.json").write_text(json.dumps(owned), encoding="utf-8")
            code = gate.main(["gate.py", "local", d, "abc"])
        self.assertEqual(code, 1)

    def test_local_fails_when_a_required_case_is_blocked(self):
        doc = document("linux")
        for case in doc["cases"]:
            if case["id"] == "receipt_recovery":
                case["status"] = "blocked"
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "evidence-licence.json").write_text(json.dumps(doc), encoding="utf-8")
            code = gate.main(["gate.py", "local", d, "abc"])
        self.assertEqual(code, 1)

    def test_local_passes_a_complete_document(self):
        doc = document("linux")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "evidence-update.json").write_text(json.dumps(doc), encoding="utf-8")
            code = gate.main(["gate.py", "local", d, "abc"])
            merged = json.loads((Path(d) / "evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(merged["producer"], "merged")
        got = {case["id"]: case["status"] for case in merged["cases"]}
        self.assertEqual(got["activation_http"], "pass")
        self.assertEqual(got["packaged_app"], "na")


if __name__ == "__main__":
    unittest.main()
