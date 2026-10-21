# Namespace cases must not write the host, and must not run outside a private mount namespace.

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import harness


class NamespaceCommandTest(unittest.TestCase):
    def test_fixture_env_keeps_paths_and_drops_secrets(self):
        kept = harness.namespace_env({
            "PATH": "/usr/bin",
            "HOME": "/tmp/fixture home",
            "LEITA_BIN": "/tmp/leita; rm -rf /",
            "LEITA_RELEASE_BASE": "/tmp/release",
            "LEITA_UPDATE_SEED": "seed-secret",
            "LEITA_LICENCE_KEY": "licence-secret",
            "LEITA_UPDATE_KEY": "update-secret",
            "GITHUB_TOKEN": "ghp-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "HOST_MNT_NS": "mnt:[caller]",
        })
        self.assertEqual(kept["HOME"], "/tmp/fixture home")
        self.assertEqual(kept["LEITA_BIN"], "/tmp/leita; rm -rf /")
        self.assertNotIn("LEITA_UPDATE_SEED", kept)
        self.assertNotIn("LEITA_LICENCE_KEY", kept)
        self.assertNotIn("LEITA_UPDATE_KEY", kept)
        self.assertNotIn("GITHUB_TOKEN", kept)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", kept)
        self.assertNotIn("HOST_MNT_NS", kept)

    def test_child_env_survives_the_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            env, _folder = harness.child_env(work, {
                "LEITA_BIN": str(work / "leita"),
                "LEITA_RELEASE_BASE": str(work / "release"),
                "TARGET": "/usr/share",
                "LOOSE": str(work / "loose"),
            })
            self.assertTrue(env.get("HOME"))
            self.assertTrue(env.get("PATH"))
            env = dict(env)
            env["LEITA_UPDATE_SEED"] = "seed-secret"
            env["GITHUB_TOKEN"] = "ghp-secret"
            kept = harness.namespace_env(env)
            self.assertEqual(kept["HOME"], env["HOME"])
            self.assertEqual(kept["PATH"], env["PATH"])
            self.assertEqual(kept["XDG_DATA_HOME"], env["XDG_DATA_HOME"])
            self.assertEqual(kept["LEITA_COLOR"], "never")
            self.assertEqual(kept["LEITA_BIN"], str(work / "leita"))
            self.assertEqual(kept["LEITA_RELEASE_BASE"], str(work / "release"))
            self.assertEqual(kept["TARGET"], "/usr/share")
            self.assertEqual(kept["LOOSE"], str(work / "loose"))
            self.assertNotIn("LEITA_UPDATE_SEED", kept)
            self.assertNotIn("GITHUB_TOKEN", kept)
            self.assertNotIn("seed-secret", list(kept.values()))
            self.assertNotEqual(kept, env)

    def test_root_argv_is_sudo_n_and_does_not_interpolate(self):
        env = harness.namespace_env({
            "PATH": "/usr/bin",
            "HOME": "/tmp/fixture home",
            "LEITA_BIN": "/tmp/leita; rm -rf /",
            "LEITA_UPDATE_SEED": "seed-secret",
        })
        env["HOST_MNT_NS"] = "mnt:[2]"
        argv = harness.namespace_argv('cp "$LEITA_BIN" /usr/local/libexec/leita/leita', env, "root")
        self.assertEqual(argv[:6], ["sudo", "-n", "--", "unshare", "--mount", "--propagation"])
        self.assertEqual(argv[6], "private")
        self.assertNotIn("-S", argv)
        self.assertNotIn("-A", argv)
        self.assertEqual(argv[argv.index("env") + 1], "-i")
        self.assertIn("LEITA_BIN=/tmp/leita; rm -rf /", argv)
        self.assertIn("HOME=/tmp/fixture home", argv)
        script = argv[-1]
        self.assertNotIn("leita; rm", script)
        self.assertNotIn("seed-secret", "\n".join(argv))
        self.assertNotIn("fixture home", script)

    def test_user_namespace_is_preferred_and_carries_the_guard(self):
        seen = []

        def fake_run(argv, **kwargs):
            self.assertIs(kwargs.get("stdin"), subprocess.DEVNULL)
            if argv[:1] == ["unshare"] and argv[-1] == "true":
                return subprocess.CompletedProcess(argv, 0, "", "")
            raise AssertionError(argv)

        def fake_exec(argv, timeout):
            seen.extend(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        with patch.object(harness.shutil, "which", side_effect=lambda name: "/fixture/" + name), \
             patch.object(harness.subprocess, "run", side_effect=fake_run), \
             patch.object(harness, "_run_namespace", side_effect=fake_exec), \
             patch.object(harness.os, "readlink", return_value="mnt:[1]"):
            harness.namespaced("echo payload-marker", {
                "PATH": "/usr/bin",
                "HOME": "/tmp/fixture",
                "LEITA_UPDATE_SEED": "nope",
            })
        self.assertEqual(seen[0], "unshare")
        self.assertNotIn("sudo", seen)
        self.assertIn("--map-root-user", seen)
        self.assertEqual(seen[seen.index("--propagation") + 1], "private")
        self.assertEqual(seen[seen.index("env") + 1], "-i")
        self.assertIn("HOME=/tmp/fixture", seen)
        self.assertIn("HOST_MNT_NS=mnt:[1]", seen)
        self.assertNotIn("LEITA_UPDATE_SEED=nope", seen)
        script = seen[-1]
        self.assertLess(script.index("not a new mount namespace"), script.index("payload-marker"))
        self.assertLess(script.index("root mount is not private"), script.index("payload-marker"))

    def test_root_fallback_uses_sudo_n_without_running_the_payload(self):
        seen = []

        def fake_run(argv, **kwargs):
            self.assertIs(kwargs.get("stdin"), subprocess.DEVNULL)
            if argv[:1] == ["unshare"] and argv[-1] == "true":
                return subprocess.CompletedProcess(argv, 1, "", "unshare: write failed /proc/self/uid_map: Operation not permitted\n")
            if argv == ["sudo", "-n", "true"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            raise AssertionError(argv)

        def fake_exec(argv, timeout):
            seen.extend(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        with patch.object(harness.shutil, "which", side_effect=lambda name: "/fixture/" + name), \
             patch.object(harness.subprocess, "run", side_effect=fake_run), \
             patch.object(harness, "_run_namespace", side_effect=fake_exec), \
             patch.object(harness.os, "readlink", return_value="mnt:[9]"):
            proc = harness.namespaced("echo payload-marker", {"PATH": "/usr/bin"})
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(seen[:4], ["sudo", "-n", "--", "unshare"])
        self.assertNotIn("--user", seen)
        self.assertEqual(seen[seen.index("--propagation") + 1], "private")
        self.assertIn("payload-marker", seen[-1])

    def test_unavailable_namespace_does_not_execute_the_script(self):
        def fake_run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "unshare: write failed /proc/self/uid_map: Operation not permitted\n")

        with patch.object(harness.shutil, "which", side_effect=lambda name: "/fixture/" + name), \
             patch.object(harness.subprocess, "run", side_effect=fake_run), \
             patch.object(harness.subprocess, "Popen", side_effect=AssertionError("payload executed")):
            proc = harness.namespaced("echo HOST_SIDE_MUTATION", {"PATH": "/usr/bin", "LEITA_UPDATE_SEED": "seed-secret"})
        self.assertEqual(proc.returncode, 127)
        self.assertIn("uid_map", proc.stderr)
        self.assertIn("sudo -n", proc.stderr)
        self.assertNotIn("HOST_SIDE_MUTATION", proc.stdout + proc.stderr)
        self.assertNotIn("seed-secret", proc.stderr)

    def test_missing_tools_do_not_probe_or_execute_the_script(self):
        with patch.object(harness.shutil, "which", return_value=None), \
             patch.object(harness.subprocess, "run", side_effect=AssertionError("probe executed")), \
             patch.object(harness.subprocess, "Popen", side_effect=AssertionError("payload executed")):
            proc = harness.namespaced("echo HOST_SIDE_MUTATION", {"PATH": "/missing"})
        self.assertEqual(proc.returncode, 127)
        self.assertIn("unshare is not installed", proc.stderr)
        self.assertNotIn("HOST_SIDE_MUTATION", proc.stdout + proc.stderr)

    def test_run_namespace_closes_stdin_and_starts_a_new_session(self):
        with patch.object(harness.subprocess, "Popen") as popen:
            popen.return_value.communicate.return_value = ("", "")
            popen.return_value.returncode = 0
            harness._run_namespace(["true"], 5)
        self.assertIs(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_overlays_mount_existing_parents_before_creating_children(self):
        pairs = (
            (harness.JOURNAL_PATH_SCRIPT, "mount -t tmpfs tmpfs /usr/local\n", "mkdir -p /usr/local/libexec/leita\n"),
            (harness.JOURNAL_RUN_SCRIPT, "mount -t tmpfs tmpfs /var/lib\n", "mkdir -p /var/lib/leita/journal\n"),
        )
        for script, mount, child in pairs:
            self.assertLess(script.index(mount), script.index(child))
            self.assertNotIn("mkdir -p /usr/local\n", script)
            self.assertNotIn("mkdir -p /var/lib\n", script)
        self.assertNotIn("mount -t tmpfs tmpfs /usr/local/libexec", harness.JOURNAL_PATH_SCRIPT)
        self.assertNotIn("mount -t tmpfs tmpfs /var/lib/leita\n", harness.JOURNAL_RUN_SCRIPT)
        self.assertLess(
            harness.PACKAGE_SCRIPT.index('mount -t tmpfs tmpfs "$TARGET"\n'),
            harness.PACKAGE_SCRIPT.index('mkdir -p "$TARGET/leita-lifecycle-ci"\n'),
        )

    def test_journal_cases_do_not_create_host_state(self):
        results = {}
        seen = {}
        calls = []
        real_run = harness.subprocess.run

        def spy(argv, *args, **kwargs):
            calls.append(list(argv))
            return real_run(argv, *args, **kwargs)

        def fake_namespaced(script, env, timeout=60):
            seen["script"] = script
            seen["env"] = dict(env)
            digest = hashlib.sha256(Path(env["LEITA_BIN"]).read_bytes()).hexdigest()
            out = (
                f"copied={digest}\njournal_alive\njournal_survived\n"
                "journal_stopped\njournal_restarted\n"
            )
            return subprocess.CompletedProcess(["namespaced"], 0, out, "")

        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / "leita"
            old.write_bytes(b"real-executable")
            with patch.object(harness, "system_name", return_value="linux"), \
                 patch.object(harness, "namespaced", side_effect=fake_namespaced), \
                 patch.object(harness, "release_dir", return_value=Path(directory)), \
                 patch.object(harness, "host_hold", return_value={"id": {}, "prefix": {}}), \
                 patch.object(harness, "host_changed", return_value=""), \
                 patch.object(harness.subprocess, "run", side_effect=spy):
                harness.linux_journal_cases(results, old, b"new-bytes", "seed-secret", "leita-linux-amd64")
        for case_id in harness.JOURNAL_CASES:
            self.assertEqual(results[case_id]["status"], "pass", results[case_id])
        script = seen["script"]
        self.assertLess(script.index("mount -t tmpfs tmpfs /var/lib\n"), script.index("mkdir -p /var/lib/leita/journal\n"))
        self.assertNotIn("sudo", script)
        self.assertNotIn("seed-secret", list(seen["env"].values()))
        self.assertNotIn("LEITA_UPDATE_SEED", seen["env"])
        self.assertNotIn("LEITA_LICENCE_KEY", seen["env"])
        for argv in calls:
            self.assertNotIn("mkdir", argv)
            self.assertNotIn("rmdir", argv)


class NamespaceHostTest(unittest.TestCase):
    def test_guard_does_not_run_the_payload_in_the_host_namespace(self):
        if not Path("/proc/self/ns/mnt").exists():
            self.skipTest("no mount namespace")
        host = os.readlink("/proc/self/ns/mnt")
        script = harness.NAMESPACE_GUARD + "echo HOST_SIDE_MUTATION\n"
        proc = subprocess.run(
            ["env", "-i", f"HOST_MNT_NS={host}", "PATH=" + os.environ.get("PATH", ""), "bash", "-c", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("HOST_SIDE_MUTATION", proc.stdout)
        self.assertIn("not a new mount namespace", proc.stderr)

    def test_private_namespace_does_not_write_the_host(self):
        if harness.system_name() != "linux":
            self.skipTest("linux mount namespace")
        before = harness.host_hold()
        usr = sorted(os.listdir("/usr/local"))
        script = r"""
if [ ! -d /usr/local ] || [ ! -d /var/lib ]; then
  echo "namespace: parent directory does not exist" >&2
  exit 99
fi
mount -t tmpfs tmpfs /usr/local
mount -t tmpfs tmpfs /var/lib
mkdir -p /usr/local/libexec/leita /var/lib/leita/journal
echo canary > /usr/local/libexec/leita/lifecycle-canary
echo canary > /var/lib/leita/journal/lifecycle-canary
echo mounted
"""
        proc = harness.namespaced(script, {"PATH": os.environ.get("PATH", "")})
        self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)
        self.assertIn("mounted", proc.stdout)
        self.assertFalse(Path("/usr/local/libexec/leita/lifecycle-canary").exists())
        self.assertFalse(Path("/var/lib/leita/journal/lifecycle-canary").exists())
        self.assertEqual(sorted(os.listdir("/usr/local")), usr)
        self.assertEqual(harness.host_changed(before), "")

    def test_host_changed_reports_a_missing_file(self):
        missing = "/tmp/leita-lifecycle-absent-dir/leita"
        before = {"id": {}, "prefix": {missing: (1, "abc", True)}}
        with patch.object(harness, "HOST_RECORDER", Path(missing)), \
             patch.object(harness, "HOST_STATE", Path("/tmp/leita-lifecycle-absent-state")):
            problem = harness.host_changed(before)
        self.assertIn(missing, problem)
        self.assertIn("no longer that file", problem)
