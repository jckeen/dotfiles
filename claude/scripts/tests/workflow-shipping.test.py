#!/usr/bin/env python3
"""Exercise shipping boundaries with local Git and stubbed review services."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
REAL_GIT = shutil.which("git")
ZERO = "0" * 40


class ShippingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.source = self.root / "source"
        self.scripts = self.source / "claude/scripts"
        self.scripts.mkdir(parents=True)
        (self.source / "githooks").mkdir()
        for name in ("review-and-push.sh", "common.sh"):
            shutil.copy2(ROOT / "claude/scripts" / name, self.scripts / name)
        self.hook = self.source / "githooks/pre-push"
        shutil.copy2(ROOT / "githooks/pre-push", self.hook)
        self.calls = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", CALLS=str(self.calls),
                        CODEX_GATE_BIN=str(self.bin / "codex"),
                        REAL_GIT=REAL_GIT, LOG_DIR=str(self.root / "logs"))
        for key in list(self.env):
            if key.startswith("BASH_FUNC_") or key.startswith("GIT_") or key in ("GITLEAKS_SKIP", "REVIEW_RECEIPT_BASE", "CODEX_GATE_TIMEOUT"):
                del self.env[key]
        self.command("git", ["init", "-qb", "main"])
        self.command("git", ["config", "user.email", "test@example.test"])
        self.command("git", ["config", "user.name", "test"])
        (self.repo / "code.txt").write_text("base\n")
        self.command("git", ["add", "code.txt"])
        self.command("git", ["commit", "-qm", "base"])
        self.base = self.command("git", ["rev-parse", "HEAD"]).stdout.strip()
        self.remote = self.root / "remote"
        self.command("git", ["init", "--bare", "-qb", "main", str(self.remote)])
        self.command("git", ["push", str(self.remote), "main"])
        self.command("git", ["update-ref", "refs/remotes/origin/main", self.base])
        self.command("git", ["config", "remote.origin.url", str(self.root / "remote")])
        self.command("git", ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        self.command("git", ["switch", "-qc", "feature"])
        self.command("git", ["branch", "--set-upstream-to", "origin/main"])
        (self.repo / "code.txt").write_text("changed\n")
        self.command("git", ["commit", "-qam", "change"])
        self.head = self.command("git", ["rev-parse", "HEAD"]).stdout.strip()
        self.env["VALID_HEAD"] = self.head
        self.write(self.scripts / "review-receipt.py", '''import json, os, sys
with open(os.environ["CALLS"], "a") as f: f.write(json.dumps(["receipt", *sys.argv[1:]]) + "\\n")
head = sys.argv[sys.argv.index("--head") + 1]
sys.exit(0 if head == os.environ["VALID_HEAD"] and os.environ.get("RECEIPT_FAIL") != "1" else 2)
''')
        self.write(self.scripts / "codex-review-gate.sh", '''#!/bin/bash
printf 'gate\\n' >> "$CALLS"
if [ "${SWITCH_BRANCH:-0}" = 1 ]; then git switch -qc another-feature; fi
if [ "${DIRTY_DURING_REVIEW:-0}" = 1 ]; then echo changed-during-review >> code.txt; fi
exit "${GATE_RC:-0}"
''')
        self.write(self.bin / "git", '''#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = status ] && [ "${STATUS_FAIL:-0}" = 1 ]; then exit 128; fi
done
if [ "${1:-}" = push ]; then
  printf 'push\\n' >> "$CALLS"
  printf '%s\\n' "$@" > "$CALLS.push-args"
  exit "${PUSH_RC:-0}"
fi
exec "$REAL_GIT" "$@"
''')
        self.write(self.bin / "claude", '''#!/bin/bash
echo 'VERDICT: SAFE TO PUSH'
''')
        self.write(self.bin / "gitleaks", '''#!/bin/bash
printf 'scan\\n' >> "$CALLS"
exit "${SCAN_RC:-0}"
''')

    def write(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def command(self, exe, args, stdin=None):
        return subprocess.run([exe, *args], cwd=self.repo, env=self.env, input=stdin,
                              text=True, capture_output=True, timeout=15)

    def events(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def ref(self, sha=None, name="feature"):
        return f"refs/heads/{name} {sha or self.head} refs/heads/{name} {self.base}\n"

    def run_hook(self, refs=None):
        return self.command("bash", [str(self.hook)], self.ref() if refs is None else refs)

    def record_real_review(self, base="main"):
        shutil.copy2(ROOT / "claude/scripts/review-receipt.py", self.scripts / "review-receipt.py")
        helper = str(self.scripts / "review-receipt.py")
        begun = self.command("python3", [helper, "begin", "--repo", str(self.repo),
                             "--base", base, "--scope", "committed", "--reviewer", "codex"])
        self.assertEqual(begun.returncode, 0, begun.stderr)
        output = self.root / "review.json"
        output.write_text('{"verdict":"approve","findings":[]}')
        completed = self.command("python3", [helper, "complete", "--snapshot",
                                 str(Path(begun.stdout.strip()) / "snapshot.json"),
                                 "--outcome", "passed", "--output", str(output)])
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_annotated_tag_requires_a_reviewed_current_commit(self):
        self.record_real_review()
        self.command("git", ["tag", "-a", "reviewed", "-m", "release", self.head])
        tag = self.command("git", ["rev-parse", "refs/tags/reviewed"]).stdout.strip()
        result = self.run_hook(f"refs/tags/reviewed {tag} refs/tags/reviewed {ZERO}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.command("git", ["tag", "-a", "unreviewed", "-m", "older release", self.base])
        tag = self.command("git", ["rev-parse", "refs/tags/unreviewed"]).stdout.strip()
        self.assertNotEqual(self.run_hook(f"refs/tags/unreviewed {tag} refs/tags/unreviewed {ZERO}\n").returncode, 0)
        reviewed_tag = self.command("git", ["rev-parse", "refs/tags/reviewed"]).stdout.strip()
        replaced = self.command("git", ["replace", tag, reviewed_tag])
        self.assertEqual(replaced.returncode, 0, replaced.stderr)
        self.assertNotEqual(self.run_hook(f"refs/tags/unreviewed {tag} refs/tags/unreviewed {ZERO}\n").returncode, 0)
        blob = self.command("git", ["rev-parse", "HEAD:code.txt"]).stdout.strip()
        self.command("git", ["tag", "-a", "blob", "-m", "non-commit", blob])
        tag = self.command("git", ["rev-parse", "refs/tags/blob"]).stdout.strip()
        self.assertNotEqual(self.run_hook(f"refs/tags/blob {tag} refs/tags/blob {ZERO}\n").returncode, 0)

    def test_hook_checks_receipt_before_scan(self):
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.events()[0])[0], "receipt")
        self.assertIn(self.head, json.loads(self.events()[0]))
        self.assertIn("scan", self.events())

    def test_hook_checks_each_outgoing_ref(self):
        result = self.run_hook(self.ref() + self.ref(self.base, "other"))
        self.assertNotEqual(result.returncode, 0)
        receipts = [json.loads(line) for line in self.events() if line.startswith("[")]
        self.assertEqual(len(receipts), 2)
        self.assertIn(self.base, receipts[1])

    def test_hook_accepts_only_the_explicitly_selected_review_base(self):
        tree = self.command("git", ["rev-parse", "main^{tree}"]).stdout.strip()
        release = self.command("git", ["commit-tree", tree, "-p", self.base], "release\n").stdout.strip()
        self.command("git", ["update-ref", "refs/heads/release", release])
        self.record_real_review("release")
        self.assertNotEqual(self.run_hook().returncode, 0)
        self.env["REVIEW_RECEIPT_BASE"] = "release"
        accepted = self.run_hook()
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.env["REVIEW_RECEIPT_BASE"] = "main"
        self.assertNotEqual(self.run_hook().returncode, 0)
        self.env["REVIEW_RECEIPT_BASE"] = "missing-base"
        self.assertNotEqual(self.run_hook().returncode, 0)
        self.env["REVIEW_RECEIPT_BASE"] = "release"
        (self.repo / "code.txt").write_text("unreviewed edit\n")
        self.assertNotEqual(self.run_hook().returncode, 0)

    def test_skip_scanner_cannot_skip_receipt(self):
        self.env.update(GITLEAKS_SKIP="1", RECEIPT_FAIL="1")
        self.assertNotEqual(self.run_hook().returncode, 0)
        self.assertTrue(any("receipt" in line for line in self.events()))

    def test_missing_scanner_cannot_skip_receipt(self):
        (self.bin / "gitleaks").unlink()
        self.env["RECEIPT_FAIL"] = "1"
        self.assertNotEqual(self.run_hook().returncode, 0)

    def test_missing_helper_blocks(self):
        (self.scripts / "review-receipt.py").unlink()
        self.assertNotEqual(self.run_hook().returncode, 0)

    def test_deletion_does_not_require_review(self):
        (self.scripts / "review-receipt.py").unlink()
        self.assertEqual(self.run_hook(self.ref(ZERO)).returncode, 0)
        self.assertEqual(self.events(), [])

    def test_hook_resolves_installed_symlink(self):
        installed = self.repo / ".git/hooks/pre-push"
        installed.symlink_to(self.hook)
        result = self.command("bash", [str(installed)], self.ref())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("receipt" in line for line in self.events()))

    def test_scanner_failure_still_blocks(self):
        self.env["SCAN_RC"] = "1"
        self.assertNotEqual(self.run_hook().returncode, 0)

    def run_wrapper(self, auto=True, stdin=None):
        return self.command("bash", [str(self.scripts / "review-and-push.sh"),
                            str(self.repo), *(["--auto-push"] if auto else [])], stdin)

    def test_common_parser_preserves_repository_path_and_other_options(self):
        for suffix in (" ", "\n"):
            with self.subTest(suffix=suffix):
                repo = self.root / ("repo" + suffix)
                repo.mkdir()
                logs = self.root / ("logs" + suffix)
                result = self.command("bash", ["-c", '''source "$1"
shift
parse_args "$@"
printf '%s\\0' "$REPO_DIR" "$LOG_DIR" "$MAX_TURNS" "$FULL_AUTO"
''', "parser-fixture", str(self.scripts / "common.sh"), "--log-dir", str(logs),
                    "--max-turns", "7", str(repo), "--full-auto"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.split("\0"), [str(repo), str(logs), "7", "true", ""])

    def test_common_parser_reports_resolution_failure_in_a_conditional(self):
        result = self.command("bash", ["-c", '''source "$1"
if parse_args "$2"; then exit 0; else exit 7; fi
''', "parser-fixture", str(self.scripts / "common.sh"), str(self.root / "missing")])
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_wrapper_checks_receipt_immediately_before_push(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("gate", self.events())
        self.assertEqual(self.events()[-1], "push")
        self.assertEqual(json.loads(self.events()[-2])[0], "receipt")

    def enable_test_runner(self):
        (self.repo / "package.json").write_text('{"scripts":{"test":"fixture"}}\n')
        self.command("git", ["add", "package.json"])
        self.command("git", ["commit", "-qm", "test fixture"])
        self.head = self.command("git", ["rev-parse", "HEAD"]).stdout.strip()
        self.env["VALID_HEAD"] = self.head
        self.write(self.bin / "npm", '''#!/bin/bash
printf 'tests\\n' >> "$CALLS"
if [ "${DIRTY_DURING_TESTS:-0}" = 1 ]; then echo changed-during-tests >> code.txt; fi
''')

    def test_wrapper_refuses_uncommitted_input_before_tests(self):
        self.enable_test_runner()
        # User config must not hide untracked inputs from the preflight.
        self.command("git", ["config", "status.showUntrackedFiles", "no"])
        for state in ("unstaged", "staged", "untracked"):
            with self.subTest(state=state):
                self.command("git", ["reset", "--hard", "HEAD"])
                (self.repo / "extra.txt").unlink(missing_ok=True)
                self.calls.unlink(missing_ok=True)
                path = self.repo / ("extra.txt" if state == "untracked" else "code.txt")
                path.write_text("local fix absent from the pushed commit\n")
                if state == "staged":
                    self.command("git", ["add", "code.txt"])
                result = self.run_wrapper()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("uncommitted changes", result.stdout + result.stderr)
                self.assertEqual(self.events(), [])

    def test_wrapper_blocks_files_changed_by_tests(self):
        self.enable_test_runner()
        self.env["DIRTY_DURING_TESTS"] = "1"
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.events(), ["tests"])
        self.assertIn("uncommitted changes", result.stdout + result.stderr)

    def test_wrapper_blocks_files_changed_by_review(self):
        self.env["DIRTY_DURING_REVIEW"] = "1"
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.events(), ["gate"])
        self.assertIn("uncommitted changes", result.stdout + result.stderr)

    def test_wrapper_cannot_treat_failed_status_as_clean(self):
        self.env["STATUS_FAIL"] = "1"
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.events(), [])

    def test_wrapper_pins_the_reviewed_commit_and_destination(self):
        self.assertEqual(self.run_wrapper().returncode, 0)
        args = Path(str(self.calls) + ".push-args").read_text().splitlines()
        self.assertIn(f"{self.head}:refs/heads/feature", args)
        self.assertIn(str(self.remote), args)
        self.assertIn("--no-follow-tags", args)

    def test_wrapper_handles_tag_named_after_branch(self):
        self.command("git", ["tag", "feature", self.base])
        self.assertEqual(self.run_wrapper().returncode, 0)
        args = Path(str(self.calls) + ".push-args").read_text().splitlines()
        self.assertIn(f"{self.head}:refs/heads/feature", args)

    def test_wrapper_refuses_default_branch(self):
        self.command("git", ["switch", "main"])
        self.env["VALID_HEAD"] = self.base
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_refuses_unfetched_default_branch(self):
        self.command("git", ["switch", "-qc", "trunk"])
        self.command("git", ["--git-dir", str(self.remote), "update-ref", "refs/heads/trunk", self.base])
        self.command("git", ["--git-dir", str(self.remote), "symbolic-ref", "HEAD", "refs/heads/trunk"])
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_ignores_stale_remote_tracking_default(self):
        self.command("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"])
        self.command("git", ["switch", "main"])
        self.env["VALID_HEAD"] = self.base
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_blocks_unknown_remote_default(self):
        self.command("git", ["config", "remote.origin.url", str(self.root / "missing")])
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_blocks_branch_switch_during_review(self):
        self.env["SWITCH_BRANCH"] = "1"
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_validates_pushurl_default(self):
        push_remote = self.root / "push-remote"
        self.command("git", ["clone", "--bare", str(self.remote), str(push_remote)])
        self.command("git", ["--git-dir", str(push_remote), "update-ref", "refs/heads/feature", self.base])
        self.command("git", ["--git-dir", str(push_remote), "symbolic-ref", "HEAD", "refs/heads/feature"])
        self.command("git", ["config", "remote.origin.pushurl", str(push_remote)])
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_wrapper_refuses_multiple_push_destinations(self):
        self.command("git", ["config", "--add", "remote.origin.pushurl", str(self.remote)])
        self.command("git", ["config", "--add", "remote.origin.pushurl", str(self.root / "other")])
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_interactive_confirmation_cannot_use_stale_review(self):
        self.env["RECEIPT_FAIL"] = "1"
        self.assertNotEqual(self.run_wrapper(auto=False, stdin="y\n").returncode, 0)
        self.assertNotIn("push", self.events())

    def test_failed_gate_never_pushes(self):
        self.env["GATE_RC"] = "3"
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertNotIn("push", self.events())

    def test_push_failure_is_reported(self):
        self.env["PUSH_RC"] = "1"
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Pushed.", result.stdout)


if __name__ == "__main__":
    unittest.main()
