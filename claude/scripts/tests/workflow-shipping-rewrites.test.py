#!/usr/bin/env python3
"""Keep real pushes on the endpoint whose default branch was checked."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "shipping", Path(__file__).with_name("workflow-shipping.test.py"))
shipping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shipping)


class RewriteTests(unittest.TestCase):
    def setUp(self):
        self.fixture = shipping.ShippingTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.env.update(GIT_CONFIG_NOSYSTEM="1",
                                GIT_CONFIG_GLOBAL=str(self.fixture.root / "global-config"))

    def git(self, *args):
        result = self.fixture.command("git", list(args))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_wrapper_keeps_the_commit_selected_before_tests(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for name in ("codex-review-gate.sh", "gate-lib.sh", "review-receipt.py",
                     "codex-review-schema.json"):
            shutil.copy2(shipping.ROOT / "claude/scripts" / name, t.scripts / name)
        self.git("config", "core.hooksPath", str(t.source / "githooks"))
        (t.repo / "pyproject.toml").write_text('[project]\nname="fixture"\n')
        self.git("add", "pyproject.toml")
        self.git("commit", "-qm", "test fixture")
        intended = self.git("rev-parse", "HEAD")
        mutate = t.root / "replace-commit"
        t.write(mutate, '''#!/bin/bash
printf 'BROKEN_AFTER_TESTS\\n' > code.txt
git commit -qam 'replacement commit'
''')
        actual_gate = t.scripts / "actual-codex-review-gate.sh"
        shutil.copy2(t.scripts / "codex-review-gate.sh", actual_gate)
        t.env.update(MUTATE_COMMIT=str(mutate), ACTUAL_GATE=str(actual_gate))
        t.write(t.scripts / "codex-review-gate.sh", '''#!/bin/bash
if [[ "$REPLACE_DURING" == review ]]; then "$MUTATE_COMMIT"; fi
exec "$ACTUAL_GATE" "$@"
''')
        t.write(t.bin / "pytest", '''#!/bin/bash
printf 'tested:%s\\n' "$(git rev-parse HEAD)" >> "$CALLS"
if grep -q BROKEN_AFTER_TESTS code.txt; then exit 1; fi
if [[ "$REPLACE_DURING" == tests ]]; then "$MUTATE_COMMIT"; fi
exit 0
''')
        t.write(t.bin / "codex", '''#!/bin/bash
cat >/dev/null
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output=$2; shift; fi
  shift
done
printf '%s\\n' '{"verdict":"approve","summary":"Fixture approval","findings":[],"next_steps":[]}' > "$output"
''')
        for phase in ("tests", "review", "confirmation"):
            with self.subTest(phase=phase):
                self.git("reset", "--hard", intended)
                self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                t.calls.unlink(missing_ok=True)
                t.env["REPLACE_DURING"] = phase
                transcript = t.root / (phase + ".log")
                with transcript.open("w") as output:
                    wrapper = subprocess.Popen(["bash", str(t.scripts / "review-and-push.sh"), str(t.repo)],
                                               cwd=t.repo, env=t.env, stdin=subprocess.PIPE,
                                               stdout=output, stderr=subprocess.STDOUT, text=True)
                    try:
                        if phase == "confirmation":
                            deadline = time.monotonic() + 15
                            while "Codex review passed" not in transcript.read_text():
                                self.assertIsNone(wrapper.poll(), transcript.read_text())
                                self.assertLess(time.monotonic(), deadline, transcript.read_text())
                                time.sleep(0.01)
                            changed = t.command("bash", [str(mutate)])
                            self.assertEqual(changed.returncode, 0, changed.stderr)
                            retry = t.command("bash", [str(actual_gate), "--require", "--committed", "--no-issues"])
                            self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                        wrapper.communicate("y\n", timeout=15)
                        self.assertNotEqual(wrapper.returncode, 0, transcript.read_text())
                    finally:
                        if wrapper.poll() is None:
                            wrapper.kill()
                            wrapper.communicate()
                self.assertIn("Commit changed", transcript.read_text())
                self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)
                self.assertEqual(t.events(), ["tested:" + intended])
                replacement = self.git("rev-parse", "HEAD")
                self.assertNotEqual(replacement, intended)
                if phase != "tests":
                    receipt = json.loads((t.repo / ".git/review-receipts/codex.json").read_text())
                    self.assertEqual(receipt["artifact"]["head"], replacement)
                    checked = t.command("python3", [str(t.scripts / "review-receipt.py"), "check",
                                                    "--repo", str(t.repo), "--head", replacement, "--reviewer", "codex"])
                    self.assertEqual(checked.returncode, 0, checked.stderr)
                self.assertEqual(t.command("pytest", []).returncode, 1)

    def test_failed_codex_retry_cannot_fall_back_to_an_older_alternate_receipt(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for name in ("codex-review-gate.sh", "antigravity-review-gate.sh", "gate-lib.sh",
                     "review-receipt.py", "codex-review-schema.json"):
            shutil.copy2(shipping.ROOT / "claude/scripts" / name, t.scripts / name)
        self.git("config", "core.hooksPath", str(t.source / "githooks"))
        self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
        failure_flag = t.root / "fail-codex"
        t.env.update(ANTIGRAVITY_GATE_MODEL="", FAIL_CODEX=str(failure_flag))
        t.write(t.bin / "agy", "#!/bin/bash\ncat >/dev/null\nprintf 'LGTB\\n'\n")
        t.write(t.bin / "codex", '''#!/bin/bash
cat >/dev/null
if [[ -e "$FAIL_CODEX" ]]; then exit 42; fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output=$2; shift; fi
  shift
done
printf '%s\\n' '{"verdict":"approve","summary":"Fixture approval","findings":[],"next_steps":[]}' > "$output"
''')
        alternate = t.command("bash", [str(t.scripts / "antigravity-review-gate.sh"), "--require", "--committed"])
        self.assertEqual(alternate.returncode, 0, alternate.stdout + alternate.stderr)
        receipts = t.repo / ".git/review-receipts"
        self.assertTrue((receipts / "antigravity.json").is_file())
        transcript = t.root / "wrapper.log"
        with transcript.open("w") as output:
            wrapper = subprocess.Popen(["bash", str(t.scripts / "review-and-push.sh"), str(t.repo)],
                                       cwd=t.repo, env=t.env, stdin=subprocess.PIPE,
                                       stdout=output, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 15
                while "Codex review passed" not in transcript.read_text():
                    self.assertIsNone(wrapper.poll(), transcript.read_text())
                    self.assertLess(time.monotonic(), deadline, transcript.read_text())
                    time.sleep(0.01)
                self.assertTrue((receipts / "codex.json").is_file())
                failure_flag.touch()
                retry = t.command("bash", [str(t.scripts / "codex-review-gate.sh"),
                                           "--require", "--committed", "--no-issues"])
                self.assertEqual(retry.returncode, 3, retry.stdout + retry.stderr)
                self.assertIn("rc=42", retry.stdout + retry.stderr)
                self.assertFalse((receipts / "codex.json").exists())
                alternate_check = t.command("python3", [str(t.scripts / "review-receipt.py"), "check",
                                                        "--repo", str(t.repo), "--head", t.head])
                self.assertEqual(alternate_check.returncode, 0, alternate_check.stderr)
                self.assertIn("Valid antigravity", alternate_check.stdout)
                wrapper.communicate("y\n", timeout=15)
                self.assertNotEqual(wrapper.returncode, 0, transcript.read_text())
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.communicate()
        self.assertIn("no valid committed review receipt", transcript.read_text())
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)
        self.assertNotIn("scan", t.events())
        # The generic hook still accepts an explicitly used alternate receipt.
        self.git("push", str(t.remote), t.head + ":refs/heads/feature")
        self.assertIn("scan", t.events())
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.head)

    def test_symbolic_destination_branches_never_update_their_targets(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for target in ("main", "other"):
            for chained in (False, True):
                for protocol in ("0", "1", "2"):
                    with self.subTest(target=target, chained=chained, protocol=protocol):
                        self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/" + target, t.base)
                        destination = "refs/heads/" + target
                        if chained:
                            self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/alias", destination)
                            destination = "refs/heads/alias"
                        self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/feature", destination)
                        self.git("config", "protocol.version", protocol)
                        result = t.run_wrapper()
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("symbolic destination branch", result.stderr)
                        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/" + target), t.base)
                        self.assertEqual(self.git("--git-dir", str(t.remote), "symbolic-ref", "--no-recurse", "refs/heads/feature"), destination)
                        self.assertNotIn("gate", t.events())

    def test_symbolic_branch_added_during_real_review_blocks_after_confirmation(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for name in ("codex-review-gate.sh", "gate-lib.sh", "review-receipt.py",
                     "codex-review-schema.json"):
            shutil.copy2(shipping.ROOT / "claude/scripts" / name, t.scripts / name)
        self.git("config", "core.hooksPath", str(t.source / "githooks"))
        t.env["DESTINATION_REMOTE"] = str(t.remote)
        t.write(t.bin / "codex", '''#!/bin/bash
printf 'model\\n' >> "$CALLS"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output=$2; shift; fi
  shift
done
cat >/dev/null
git --git-dir "$DESTINATION_REMOTE" symbolic-ref refs/heads/feature refs/heads/main
printf '%s\\n' '{"verdict":"approve","summary":"Fixture approval","findings":[],"next_steps":[]}' > "$output"
''')
        result = t.run_wrapper(auto=False, stdin="y\n")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("symbolic destination branch", result.stderr)
        self.assertIn("model", t.events())
        receipt = json.loads((t.repo / ".git/review-receipts/codex.json").read_text())
        self.assertEqual(receipt["completion"]["outcome"], "passed")
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/main"), t.base)

    def test_hidden_symbolic_destination_cannot_be_treated_as_a_new_branch(self):
        t = self.fixture
        (t.bin / "git").unlink()
        self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/feature", "refs/heads/main")
        self.git("--git-dir", str(t.remote), "config", "uploadpack.hideRefs", "refs/heads/feature")
        self.assertEqual(self.git("ls-remote", "--symref", str(t.remote), "refs/heads/feature"), "")
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/main"), t.base)

    def test_server_without_branch_symref_metadata_is_rejected(self):
        t = self.fixture
        (t.bin / "git").unlink()
        self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/feature", "refs/heads/main")
        t.write(t.bin / "local-ssh", '''#!/bin/bash
unset GIT_PROTOCOL
exec bash -c "${!#}"
''')
        t.env.update(GIT_SSH_COMMAND=str(t.bin / "local-ssh"), GIT_SSH_VARIANT="ssh")
        self.git("config", "remote.origin.url", "ssh://fixture" + str(t.remote))
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("protocol v2", result.stderr)
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/main"), t.base)
        self.assertNotIn("gate", t.events())

    def test_unresolved_symbolic_destination_preserves_the_existing_default(self):
        t = self.fixture
        (t.bin / "git").unlink()
        self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/feature", "refs/heads/unborn")
        self.git("--git-dir", str(t.remote), "config", "uploadpack.hideRefs", "refs/heads/feature")
        self.assertEqual(self.git("ls-remote", "--symref", str(t.remote), "refs/heads/feature"), "")
        result = t.run_wrapper()
        # Git's absent-ref lease cannot distinguish this from a new branch.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/unborn"), t.head)
        self.assertEqual(self.git("--git-dir", str(t.remote), "symbolic-ref", "refs/heads/feature"), "refs/heads/unborn")
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/main"), t.base)

    def test_direct_destination_branches_allow_creation_and_fast_forward_only(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for previous in (None, t.base):
            with self.subTest(previous=previous):
                if previous is None:
                    self.git("--git-dir", str(t.remote), "update-ref", "-d", "refs/heads/feature")
                else:
                    self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", previous)
                result = t.run_wrapper()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.head)
                self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/main"), t.base)
        tree = self.git("rev-parse", "main^{tree}")
        divergent = self.git("commit-tree", tree, "-p", t.base, "-m", "divergent")
        self.git("push", str(t.remote), divergent + ":refs/heads/other")
        self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", divergent)
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), divergent)

    def test_wrapper_pushes_from_the_exact_repository_path(self):
        t = self.fixture
        plain = t.repo
        (t.bin / "git").unlink()
        for label, suffix in (("space", " "), ("newline", "\n")):
            with self.subTest(suffix=suffix):
                twin = t.root / ("repo" + suffix)
                remote = t.root / ("target-remote-" + label)
                self.git("clone", "--bare", str(t.remote), str(remote))
                self.git("clone", "--no-hardlinks", str(plain), str(twin))
                for destination in (t.remote, remote):
                    self.git("--git-dir", str(destination), "update-ref", "refs/heads/feature", t.base)
                t.repo = twin
                try:
                    self.git("config", "remote.origin.url", str(remote))
                    result = t.run_wrapper()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.git("--git-dir", str(remote), "rev-parse", "refs/heads/feature"), t.head)
                    self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)
                finally:
                    t.repo = plain

    def test_actual_push_cannot_use_a_sibling_repository_receipt(self):
        t = self.fixture
        plain = t.repo
        t.record_real_review()
        (t.bin / "git").unlink()
        for suffix in (" ", "\n"):
            with self.subTest(suffix=suffix):
                twin = t.root / ("repo" + suffix)
                self.git("clone", "--no-hardlinks", str(plain), str(twin))
                self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                t.repo = twin
                try:
                    self.git("config", "core.hooksPath", str(t.source / "githooks"))
                    result = t.command("git", ["push", str(t.remote), f"{t.head}:refs/heads/feature"])
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("no current review evidence", result.stderr)
                    self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)
                finally:
                    t.repo = plain

    def test_wrapper_cannot_load_a_sibling_script_directory(self):
        t = self.fixture
        plain = t.scripts
        (t.bin / "git").unlink()
        for suffix in (" ", "\n"):
            with self.subTest(suffix=suffix):
                twin = plain.with_name("scripts" + suffix)
                shutil.copytree(plain, twin)
                t.write(twin / "codex-review-gate.sh", "#!/bin/bash\nexit 2\n")
                self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                t.scripts = twin
                try:
                    result = t.run_wrapper()
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)
                finally:
                    t.scripts = plain

    def test_actual_hook_cannot_load_a_sibling_receipt_checker(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for suffix in (" ", "\n"):
            with self.subTest(suffix=suffix):
                twin = t.source.with_name("source" + suffix)
                shutil.copytree(t.source, twin)
                (twin / "claude/scripts/review-receipt.py").write_text("raise SystemExit(2)\n")
                self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                self.git("config", "core.hooksPath", str(twin / "githooks"))
                result = t.command("git", ["push", str(t.remote), f"{t.head}:refs/heads/feature"])
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("no current review evidence", result.stderr)
                self.assertEqual(self.git("--git-dir", str(t.remote), "rev-parse", "refs/heads/feature"), t.base)

    def test_current_fetch_upstream_does_not_skip_a_behind_push_fork(self):
        t = self.fixture
        fork = t.root / "fork"
        self.git("clone", "--bare", str(t.remote), str(fork))
        self.git("--git-dir", str(fork), "update-ref", "refs/heads/feature", t.base)
        self.git("remote", "add", "fork", str(fork))
        self.git("config", "branch.feature.pushRemote", "fork")
        self.git("update-ref", "refs/remotes/origin/main", t.head)
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("gate", t.events())
        self.assertEqual(self.git("--git-dir", str(fork), "rev-parse", "refs/heads/feature"), t.head)

    def test_real_gate_ships_to_behind_fork_with_unrelated_work_in_progress(self):
        t = self.fixture
        fork = t.root / "fork"
        self.git("clone", "--bare", str(t.remote), str(fork))
        self.git("--git-dir", str(fork), "update-ref", "refs/heads/feature", t.base)
        self.git("remote", "add", "fork", str(fork))
        self.git("config", "branch.feature.pushRemote", "fork")
        self.git("update-ref", "refs/remotes/origin/main", t.head)
        notes = t.repo / "notes.md"
        notes.write_text("Unrelated work in progress.\n")
        status = self.git("status", "--porcelain")
        for name in ("codex-review-gate.sh", "gate-lib.sh", "review-receipt.py",
                     "codex-review-schema.json"):
            shutil.copy2(shipping.ROOT / "claude/scripts" / name, t.scripts / name)
        t.write(t.bin / "codex", '''#!/bin/bash
printf 'model\\n' >> "$CALLS"
exit 99
''')
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(fork), "rev-parse", "refs/heads/feature"), t.head)
        self.assertEqual(notes.read_text(), "Unrelated work in progress.\n")
        self.assertEqual(self.git("status", "--porcelain"), status)
        receipt = json.loads((t.repo / ".git/review-receipts/codex.json").read_text())
        self.assertEqual(receipt["artifact"]["scope"], "committed")
        self.assertEqual(receipt["completion"]["outcome"], "no-diff")
        self.assertNotIn("model", t.events())

    def destinations(self, redirected_name="redirected-remote"):
        t = self.fixture
        reviewed = t.root / "reviewed-remote"
        redirected = t.root / redirected_name
        for remote in (reviewed, redirected):
            self.git("clone", "--bare", str(t.remote), str(remote))
            self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
        self.git("--git-dir", str(redirected), "symbolic-ref", "HEAD", "refs/heads/feature")
        self.git("config", f"url.{reviewed}.pushInsteadOf", str(t.remote))
        return reviewed, redirected

    def assert_rewrite_blocked(self, reviewed, redirected, diagnostic="Git URL rewrite"):
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.git("--git-dir", str(redirected), "rev-parse", "refs/heads/feature"),
                         t.base, "a URL rewrite updated an unchecked default branch")
        self.assertEqual(self.git("--git-dir", str(reviewed), "rev-parse", "refs/heads/feature"),
                         t.base, "the wrapper pushed despite ambiguous URL rewrites")

    def push_remotes(self):
        t = self.fixture
        remotes = {"origin": t.remote}
        for name in ("fetch", "default-push", "branch-push"):
            remote = t.root / name
            self.git("clone", "--bare", str(t.remote), str(remote))
            self.git("remote", "add", name, str(remote))
            remotes[name] = remote
        for remote in remotes.values():
            self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
        (t.bin / "git").unlink()
        return remotes

    def assert_push_tips(self, remotes, selected=None):
        t = self.fixture
        for name, remote in remotes.items():
            self.assertEqual(
                self.git("--git-dir", str(remote), "rev-parse", "refs/heads/feature"),
                t.head if name == selected else t.base, name)

    def test_multiline_destination_values_never_push_to_a_trimmed_path(self):
        t = self.fixture
        remotes = {"plain": t.remote}
        for suffix in ("\n", "\n\n", "\nextra"):
            remote = t.root / ("remote" + suffix)
            self.git("clone", "--bare", str(t.remote), str(remote))
            remotes[suffix] = remote
        (t.bin / "git").unlink()
        for key in ("remote.origin.url", "remote.origin.pushurl"):
            for suffix in ("\n", "\n\n", "\nextra"):
                with self.subTest(key=key, suffix=suffix):
                    for remote in remotes.values():
                        self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
                    self.git("config", key, str(remotes[suffix]))
                    try:
                        result = t.run_wrapper()
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("unambiguous push destination", result.stderr)
                        self.assert_push_tips(remotes)
                    finally:
                        if key == "remote.origin.url":
                            self.git("config", key, str(t.remote))
                        else:
                            self.git("config", "--unset", key)

    def test_multiline_selected_remote_names_are_not_trimmed(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for key in ("branch.feature.pushRemote", "remote.pushDefault", "branch.feature.remote"):
            for value in ("origin\n", "origin\n\n", "ori\ngin"):
                with self.subTest(key=key, value=value):
                    self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                    self.git("config", key, value)
                    try:
                        result = t.run_wrapper()
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assert_push_tips({"origin": t.remote})
                    finally:
                        if key == "branch.feature.remote":
                            self.git("config", key, "origin")
                        else:
                            self.git("config", "--unset", key)

    def test_empty_additional_push_url_is_still_ambiguous(self):
        t = self.fixture
        (t.bin / "git").unlink()
        for values in ((str(t.remote), ""), ("", str(t.remote))):
            with self.subTest(values=values):
                self.git("--git-dir", str(t.remote), "update-ref", "refs/heads/feature", t.base)
                for value in values:
                    self.git("config", "--add", "remote.origin.pushurl", value)
                try:
                    result = t.run_wrapper()
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("unambiguous push destination", result.stderr)
                    self.assert_push_tips({"origin": t.remote})
                finally:
                    self.git("config", "--unset-all", "remote.origin.pushurl")

    def test_push_remote_selection_precedence(self):
        remotes = self.push_remotes()
        self.git("config", "branch.feature.remote", "fetch")
        self.git("config", "remote.pushDefault", "default-push")
        self.git("config", "branch.feature.pushRemote", "branch-push")
        cases = ((None, "branch-push"),
                 ("branch.feature.pushRemote", "default-push"),
                 ("remote.pushDefault", "fetch"),
                 ("branch.feature.remote", "origin"))
        for unset, selected in cases:
            with self.subTest(selected=selected):
                if unset:
                    self.git("config", "--unset", unset)
                for remote in remotes.values():
                    self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature",
                             self.fixture.base)
                result = self.fixture.run_wrapper()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_push_tips(remotes, selected)

    def test_invalid_selected_push_remote_never_falls_back(self):
        remotes = self.push_remotes()
        for key in ("branch.feature.pushRemote", "remote.pushDefault", "branch.feature.remote"):
            for value in ("missing-remote", ""):
                with self.subTest(key=key, value=value):
                    for remote in remotes.values():
                        self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature",
                                 self.fixture.base)
                    self.git("config", key, value)
                    try:
                        result = self.fixture.run_wrapper()
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assert_push_tips(remotes)
                    finally:
                        self.git("config", "--unset", key)

    def test_selected_pushurl_default_branch_is_checked(self):
        remotes = self.push_remotes()
        self.git("config", "branch.feature.pushRemote", "branch-push")
        self.git("config", "remote.branch-push.pushurl", str(remotes["default-push"]))
        self.git("--git-dir", str(remotes["default-push"]), "symbolic-ref", "HEAD",
                 "refs/heads/feature")
        result = self.fixture.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("does not push the default branch", result.stderr)
        self.assert_push_tips(remotes)

    def test_selected_push_remote_still_rejects_further_url_rewrites(self):
        remotes = self.push_remotes()
        self.git("config", "remote.pushDefault", "default-push")
        self.git("config", f"url.{remotes['branch-push']}.pushInsteadOf",
                 str(remotes["default-push"]))
        self.git("config", f"url.{remotes['fetch']}.pushInsteadOf",
                 str(remotes["branch-push"]))
        result = self.fixture.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Git URL rewrite", result.stderr)
        self.assert_push_tips(remotes)

    def test_local_push_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", f"url.{redirected}.pushInsteadOf", str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_global_push_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", "--global", f"url.{redirected}.pushInsteadOf", str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_general_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", f"url.{redirected}.insteadOf", str(reviewed))
        self.assertEqual(self.git("remote", "get-url", "--push", "origin"), str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_rewrites_added_during_review_do_not_change_the_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        t.env.update(REVIEWED_REMOTE=str(reviewed), REDIRECT_REMOTE=str(redirected))
        t.write(t.scripts / "codex-review-gate.sh", '''#!/bin/bash
printf 'gate\\n' >> "$CALLS"
git config --global "url.$REDIRECT_REMOTE.pushInsteadOf" "$REVIEWED_REMOTE"
git config --global "url.$REDIRECT_REMOTE.insteadOf" "$REVIEWED_REMOTE"
''')
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_single_rewrite_still_pushes_to_the_resolved_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(reviewed), "rev-parse", "refs/heads/feature"), t.head)
        self.assertEqual(self.git("--git-dir", str(redirected), "rev-parse", "refs/heads/feature"), t.base)

    def test_newline_in_rewrite_subsection_fails_closed(self):
        reviewed, redirected = self.destinations("redirected-\nremote")
        with (self.fixture.repo / ".git/config").open("a") as config:
            config.write(f'\n[url "{redirected}"]\n\tpushInsteadOf = {reviewed}\n')
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("push", t.events())

    def test_resolved_url_cannot_name_another_remote(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "remote.destination.url", str(reviewed))
        self.git("config", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_resolved_url_cannot_name_a_global_remote(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "--global", "remote.destination.url", str(reviewed))
        self.git("config", "--global", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_remote_alias_added_during_review_cannot_change_the_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        (t.repo / "destination").symlink_to(reviewed, target_is_directory=True)
        self.git("config", "remote.origin.url", "destination")
        t.env.update(REVIEWED_REMOTE=str(reviewed), REDIRECT_REMOTE=str(redirected))
        t.write(t.scripts / "codex-review-gate.sh", '''#!/bin/bash
printf 'gate\\n' >> "$CALLS"
git config --global remote.destination.url "$REVIEWED_REMOTE"
git config --global remote.destination.pushurl "$REDIRECT_REMOTE"
''')
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_remote_alias_with_multiple_push_urls_is_rejected(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "remote.destination.url", str(reviewed))
        self.git("config", "--add", "remote.destination.pushurl", str(reviewed))
        self.git("config", "--add", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")


if __name__ == "__main__":
    unittest.main()
