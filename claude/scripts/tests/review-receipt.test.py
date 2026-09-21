#!/usr/bin/env python3
"""Receipt fixtures exercise real Git objects without invoking a reviewer."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "review-receipt.py"


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.test")
        (self.repo / "code.txt").write_text("base\n")
        self.git("add", "code.txt")
        self.git("commit", "-qm", "base")
        self.git("checkout", "-qb", "feature")
        (self.repo / "code.txt").write_text("changed\n")
        self.git("commit", "-qam", "work")
        self.result = Path(self.tmp.name) / "result.json"
        self.result.write_text('{"verdict":"approve","findings":[]}')

    def git(self, *args):
        return (
            subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE)
            .decode()
            .strip()
        )

    def run_helper(self, *args, ok=True):
        p = subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True)
        self.assertEqual(p.returncode == 0, ok, p.stdout + p.stderr)
        return p.stdout.strip()

    def begin(self, scope="committed", base="main", tier1_max_lines=None, reviewer="codex"):
        policy = ("--tier1-max-lines=" + tier1_max_lines,) if tier1_max_lines is not None else ()
        return (
            Path(
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    base,
                    "--scope",
                    scope,
                    "--reviewer",
                    reviewer,
                    *policy,
                )
            )
            / "snapshot.json"
        )

    def complete(self, snapshot, outcome="passed", ok=True):
        return self.run_helper(
            "complete",
            "--snapshot",
            str(snapshot),
            "--outcome",
            outcome,
            "--output",
            str(self.result),
            ok=ok,
        )

    def check(self, ok=True, *args):
        return self.run_helper(
            "check", "--repo", str(self.repo), "--head", self.git("rev-parse", "HEAD"), *args, ok=ok
        )

    def test_staged_executable_modes_survive_disabled_filesystem_tracking(self):
        for name in ("image.png", "README.md"):
            for change_content in (False, True):
                with self.subTest(path=name, content=change_content):
                    self.git("reset", "--hard", "main")
                    path = self.repo / name
                    path.write_text("before\n")
                    path.chmod(0o644)
                    self.git("add", name)
                    self.git("commit", "-qm", "regular file")
                    self.git("config", "core.filemode", "false")
                    self.git("update-index", "--chmod=+x", name)
                    if change_content:
                        path.write_text("STAGED_EXECUTABLE_MARKER\n")
                        self.git("add", name)
                    self.assertIn("100755", self.git("ls-files", "--stage", "--", name))
                    self.assertFalse(path.stat().st_mode & 0o111)
                    snapshot = self.begin("uncommitted")
                    patch = (snapshot.parent / "diff.patch").read_text()
                    self.assertIn("100755", patch)
                    if change_content:
                        self.assertIn("STAGED_EXECUTABLE_MARKER", patch)
                    self.assertEqual(
                        json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))[
                            "tier"
                        ],
                        2,
                    )
                    self.complete(snapshot, "no-diff", ok=False)
                    self.complete(snapshot, "tier-1", ok=False)
                    self.complete(snapshot)
                    self.git("config", "core.filemode", "true")

    def test_clean_crlf_instructions_remain_bound_to_raw_bytes(self):
        for normalization in ("autocrlf", "eol-attribute"):
            with self.subTest(normalization=normalization):
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                self.git("config", "core.autocrlf", "false")
                path = self.repo / "AGENTS.md"
                path.write_bytes(b"Known instructions.\n")
                if normalization == "eol-attribute":
                    (self.repo / ".gitattributes").write_text("AGENTS.md text eol=crlf\n")
                    self.git("add", ".gitattributes")
                self.git("add", "AGENTS.md")
                self.git("commit", "-qm", "instruction fixture")
                if normalization == "autocrlf":
                    self.git("config", "core.autocrlf", "true")
                path.unlink()
                self.git("checkout", "--", "AGENTS.md")
                self.assertEqual(path.read_bytes(), b"Known instructions.\r\n")
                self.assertEqual(self.git("status", "--porcelain"), "")
                marker = Path(self.tmp.name) / "CRLF_FILTER_EXECUTED"
                self.git("config", "filter.unsafe.clean", f"touch {marker}")
                (self.repo / ".git/info/attributes").write_text("AGENTS.md filter=unsafe\n")
                snapshot = self.begin()
                self.complete(snapshot)
                self.check()
                clean = self.begin("uncommitted")
                self.assertNotIn(
                    "AGENTS.md", json.loads(clean.read_text())["artifact"]["changed_paths"]
                )
                path.write_bytes(b"Known instructions.\n")
                self.complete(clean, ok=False)
                path.write_bytes(b"Known instructions.\r\nDIRTY_CRLF_MARKER\r\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                dirty = self.begin("uncommitted")
                self.assertIn("DIRTY_CRLF_MARKER", (dirty.parent / "diff.patch").read_text())
                self.complete(dirty)
                self.assertFalse(marker.exists())
                (self.repo / ".git/info/attributes").unlink()

    def test_crlf_automatic_conversion_uses_native_text_classification(self):
        base = self.git("rev-parse", "main")
        policies = (
            "text=auto",
            "text=auto eol=lf",
            "text=auto eol=crlf",
            "autocrlf=true",
            "autocrlf=input",
            "text",
            "eol=lf",
            "eol=crlf",
        )
        for policy in policies:
            for binary in (True, False):
                with self.subTest(policy=policy, binary=binary):
                    self.git("config", "core.autocrlf", "false")
                    self.git("reset", "--hard", base)
                    self.git("clean", "-fd")
                    path = self.repo / "AGENTS.md"
                    before = (b"\v" * 20 if binary else b"") + b"Known instructions.\n"
                    path.write_bytes(before)
                    if not policy.startswith("autocrlf="):
                        (self.repo / ".gitattributes").write_text("AGENTS.md " + policy + "\n")
                    self.git("add", ".")
                    self.git("commit", "-qm", "native text classification")
                    self.git("branch", "-f", "main", "HEAD")
                    if policy.startswith("autocrlf="):
                        self.git("config", "core.autocrlf", policy.partition("=")[2])
                    self.complete(self.begin(), "no-diff")
                    self.check()
                    after = before.replace(b"\n", b"\r\n")
                    path.write_bytes(after)
                    eol = self.git("ls-files", "--eol", "--", "AGENTS.md")
                    self.assertIn("i/-text w/-text" if binary else "i/lf    w/crlf", eol)
                    automatic = policy.startswith(("text=auto", "autocrlf="))
                    dirty = binary and automatic
                    # This native conversion oracle runs only in the fixture,
                    # which has no configured filters; the helper must not run it.
                    self.assertEqual(
                        self.git("hash-object", "--path=AGENTS.md", "AGENTS.md")
                        != self.git("rev-parse", "HEAD:AGENTS.md"),
                        dirty,
                    )
                    self.check(False)  # Raw bytes always stale the old receipt.
                    snapshot = self.begin("uncommitted")
                    self.assertEqual(
                        "AGENTS.md"
                        in json.loads(snapshot.read_text())["artifact"]["changed_paths"],
                        dirty,
                    )
                    if dirty:
                        patch = (snapshot.parent / "diff.patch").read_bytes()
                        self.assertIn(b"+" + after, patch)
                        self.complete(snapshot, "no-diff", ok=False)
                        self.complete(snapshot, "tier-1", ok=False)
                        self.complete(snapshot)
                        self.run_helper(
                            "begin",
                            "--repo",
                            str(self.repo),
                            "--base",
                            "main",
                            "--scope",
                            "committed",
                            "--reviewer",
                            "codex",
                            ok=False,
                        )
                    else:
                        self.complete(snapshot, "no-diff")
                        self.complete(self.begin(), "no-diff")
                        self.check()

    def test_crlf_uses_current_index_and_workspace_classification(self):
        for staged_binary in (True, False):
            with self.subTest(staged_binary=staged_binary):
                self.git("config", "core.autocrlf", "false")
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                path = self.repo / "code.txt"
                before = (b"" if staged_binary else b"\v" * 20) + b"before\n"
                staged = (b"\v" * 20 if staged_binary else b"") + b"after\nlast\n"
                (self.repo / ".gitattributes").write_text("code.txt text=auto\n")
                path.write_bytes(before)
                self.git("add", ".")
                self.git("commit", "-qm", "index classification base")
                path.write_bytes(staged)
                self.git("add", "code.txt")
                after = staged.replace(b"\n", b"\r\n", 1)
                path.write_bytes(after)
                self.assertIn(
                    "i/-text w/-text" if staged_binary else "i/lf    w/mixed",
                    self.git("ls-files", "--eol", "--", "code.txt"),
                )
                self.assertEqual(
                    bool(self.git("diff", "--name-only", "--", "code.txt")), staged_binary
                )
                snapshot = self.begin("uncommitted")
                patch = (snapshot.parent / "diff.patch").read_bytes()
                self.assertIn(b"review state staged\n", patch)
                self.assertEqual(b"review state worktree\n" in patch, staged_binary)
                if staged_binary:
                    self.assertIn(b"+" + after.split(b"\n", 1)[0] + b"\n", patch)
                self.complete(snapshot)
                path.write_bytes(staged)
                self.complete(snapshot, ok=False)

    def test_binary_classified_executable_crlf_change_requires_review(self):
        path = self.repo / "check.sh"
        before = b"#!/bin/sh\nprintf '%s\\n' '" + b"\v" * 20 + b"'\n"
        path.write_bytes(before)
        path.chmod(0o755)
        (self.repo / ".gitattributes").write_text("check.sh text=auto\n")
        self.git("add", "check.sh", ".gitattributes")
        self.git("commit", "-qm", "binary-classified executable")
        self.assertEqual(subprocess.run([str(path)], capture_output=True).returncode, 0)
        after = before.replace(b"\n", b"\r\n")
        path.write_bytes(after)
        with self.assertRaises(FileNotFoundError):
            subprocess.run([str(path)], capture_output=True)
        snapshot = self.begin("uncommitted")
        self.assertIn(b"+#!/bin/sh\r\n", (snapshot.parent / "diff.patch").read_bytes())
        self.complete(snapshot, "no-diff", ok=False)
        self.complete(snapshot, "tier-1", ok=False)
        self.complete(snapshot)

    def test_index_and_raw_workspace_modes_and_bytes_are_both_reviewed(self):
        path = self.repo / "image.png"
        path.write_text("base\n")
        self.git("add", "image.png")
        self.git("commit", "-qm", "regular base")
        self.git("config", "core.filemode", "false")
        path.write_text("STAGED_ONLY_MARKER\n")
        self.git("add", "image.png")
        self.git("update-index", "--chmod=+x", "image.png")
        path.write_text("RAW_WORKSPACE_MARKER\n")
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("STAGED_ONLY_MARKER", patch)
        self.assertIn("RAW_WORKSPACE_MARKER", patch)
        self.complete(snapshot)
        self.git("commit", "-qm", "staged executable")
        self.git("update-index", "--chmod=-x", "image.png")
        snapshot = self.begin("uncommitted")
        self.assertIn("100755", (snapshot.parent / "diff.patch").read_text())
        self.complete(snapshot, "no-diff", ok=False)
        self.git("rm", "--cached", "image.png")
        snapshot = self.begin("uncommitted")
        self.assertIn("STAGED_ONLY_MARKER", (snapshot.parent / "diff.patch").read_text())
        self.complete(snapshot, "no-diff", ok=False)
        self.git("reset", "--hard", "main")
        path.write_text("RAW_EXECUTABLE_MARKER\n")
        path.chmod(0o755)
        snapshot = self.begin("uncommitted")
        self.assertIn("RAW_EXECUTABLE_MARKER", (snapshot.parent / "diff.patch").read_text())
        self.complete(snapshot, "no-diff", ok=False)

    def test_unmanaged_crlf_and_filters_cannot_hide_instruction_changes(self):
        path = self.repo / "AGENTS.md"
        path.write_bytes(b"Known instructions.\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "instruction fixture")
        marker = Path(self.tmp.name) / "FILTER_EXECUTED"
        self.git("config", "filter.unsafe.clean", f"touch {marker}")
        for attribute, autocrlf in (("-text", "true"), ("filter=unsafe", "false")):
            with self.subTest(attribute=attribute):
                self.git("config", "core.autocrlf", autocrlf)
                (self.repo / ".gitattributes").write_text("AGENTS.md " + attribute + "\n")
                path.write_bytes(b"Known instructions.\r\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                self.assertFalse(marker.exists())

    def test_sparse_omissions_are_virtual_but_present_instructions_are_checked(self):
        original = self.git("rev-parse", "HEAD")
        for sparse_index in (False, True):
            with self.subTest(sparse_index=sparse_index):
                self.git("sparse-checkout", "disable")
                self.git("reset", "--hard", original)
                self.git("clean", "-fd")
                for name in ("src/app.py", "src/AGENTS.md", "docs/AGENTS.md", "docs/notes.md"):
                    path = self.repo / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("sparse fixture\n")
                self.git("add", "src", "docs")
                self.git("commit", "-qm", "sparse fixture")
                self.git(
                    "sparse-checkout",
                    "init",
                    "--cone",
                    *(("--sparse-index",) if sparse_index else ()),
                )
                self.git("sparse-checkout", "set", "src")
                self.assertFalse((self.repo / "docs/AGENTS.md").exists())
                self.assertEqual(self.git("status", "--porcelain"), "")
                snapshot = self.begin()
                self.complete(snapshot)
                self.check()
                snapshot = self.begin("uncommitted")
                self.assertEqual(json.loads(snapshot.read_text())["artifact"]["changed_paths"], [])
                self.complete(snapshot, "no-diff")
                original_instruction = self.git("rev-parse", "HEAD:docs/AGENTS.md")
                (self.repo / "src/app.py").write_text("STAGED_SPARSE_POLICY_MARKER\n")
                staged_instruction = self.git("hash-object", "-w", "src/app.py")
                self.git("checkout", "--", "src/app.py")
                self.git(
                    "update-index", "--cacheinfo", "100644", staged_instruction, "docs/AGENTS.md"
                )
                self.git("update-index", "--skip-worktree", "docs/AGENTS.md")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                snapshot = self.begin("uncommitted")
                self.assertIn(
                    "STAGED_SPARSE_POLICY_MARKER", (snapshot.parent / "diff.patch").read_text()
                )
                self.git(
                    "update-index", "--cacheinfo", "100644", original_instruction, "docs/AGENTS.md"
                )
                self.git("update-index", "--skip-worktree", "docs/AGENTS.md")
                included = self.repo / "src/AGENTS.md"
                included.unlink()
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                self.git("checkout", "--", "src/AGENTS.md")
                present = self.repo / "docs/AGENTS.md"
                present.parent.mkdir(parents=True, exist_ok=True)
                ignored = present.parent / "AGENTS.local.md"
                (self.repo / ".git/info/exclude").write_text("docs/AGENTS.local.md\n")
                ignored.write_text("IGNORED_SPARSE_POLICY_MARKER\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                snapshot = self.begin("uncommitted")
                self.assertIn(
                    "IGNORED_SPARSE_POLICY_MARKER", (snapshot.parent / "diff.patch").read_text()
                )
                ignored.unlink()
                present.write_text("SPARSE_DIRTY_INSTRUCTION_MARKER\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                snapshot = self.begin("uncommitted")
                self.assertIn(
                    "SPARSE_DIRTY_INSTRUCTION_MARKER", (snapshot.parent / "diff.patch").read_text()
                )
                present.unlink()

    def test_instruction_symlinks_in_sparse_head_or_index_stay_unsupported(self):
        for sparse in (False, True):
            with self.subTest(sparse=sparse):
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                path = self.repo / "docs/AGENTS.md"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original instructions\n")
                self.git("add", "docs/AGENTS.md")
                self.git("commit", "-qm", "instructions")
                path.unlink()
                path.symlink_to("ignored-policy.txt")
                self.git("add", "docs/AGENTS.md")
                if sparse:
                    self.git("commit", "-qm", "instruction alias")
                    self.git("sparse-checkout", "init", "--cone", "--sparse-index")
                    self.git("sparse-checkout", "set", "src")
                    self.assertFalse(path.is_symlink())
                else:
                    path.unlink()
                    path.write_text("original instructions\n")
                for scope in ("committed", "uncommitted"):
                    self.run_helper(
                        "begin",
                        "--repo",
                        str(self.repo),
                        "--base",
                        "main",
                        "--scope",
                        scope,
                        "--reviewer",
                        "codex",
                        ok=False,
                    )

    def test_skip_flag_without_sparse_checkout_cannot_hide_instruction_deletion(self):
        path = self.repo / "AGENTS.md"
        path.write_text("instructions\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "instructions")
        self.git("update-index", "--skip-worktree", "AGENTS.md")
        path.unlink()
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )
        snapshot = self.begin("uncommitted")
        self.assertIn("-instructions", (snapshot.parent / "diff.patch").read_text())

    def test_symlinked_parent_cannot_export_outside_content(self):
        nested = self.repo / "nested"
        nested.mkdir()
        (nested / "data.txt").write_text("tracked content\n")
        self.git("add", "nested/data.txt")
        self.git("commit", "-qm", "nested file")
        (nested / "data.txt").unlink()
        nested.rmdir()
        outside = Path(self.tmp.name) / "private"
        outside.mkdir()
        (outside / "data.txt").write_text("OUTSIDE_PRIVATE_MARKER\n")
        nested.symlink_to(outside, target_is_directory=True)
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "begin",
                "--repo",
                str(self.repo),
                "--base",
                "main",
                "--scope",
                "uncommitted",
                "--reviewer",
                "codex",
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("symlink ancestor", result.stderr)
        self.assertNotIn("OUTSIDE_PRIVATE_MARKER", result.stdout + result.stderr)
        self.assertFalse(list((self.repo / ".git/review-receipts").glob("run-*/diff.patch")))

    def test_tracked_leaf_symlink_reviews_link_text_only(self):
        outside = Path(self.tmp.name) / "private"
        outside.mkdir()
        for name in ("before.txt", "after.txt"):
            (outside / name).write_text("OUTSIDE_PRIVATE_MARKER\n")
        leaf = self.repo / "link.txt"
        leaf.symlink_to(outside / "before.txt")
        self.git("add", "link.txt")
        self.git("commit", "-qm", "leaf symlink")
        leaf.unlink()
        leaf.symlink_to(outside / "after.txt")
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("old mode 120000", patch)
        self.assertIn("new mode 120000", patch)
        self.assertIn("before.txt", patch)
        self.assertIn("after.txt", patch)
        self.assertNotIn("OUTSIDE_PRIVATE_MARKER", patch)

    def test_symlink_target_bytes_do_not_receive_regular_file_eol_normalization(self):
        for normalization in ("text-attribute", "autocrlf"):
            for staged in (False, True):
                with self.subTest(normalization=normalization, staged=staged):
                    self.git("reset", "--hard", "main")
                    self.git("clean", "-fd")
                    self.git("config", "core.autocrlf", "false")
                    link = self.repo / "link.txt"
                    link.symlink_to("SYMLINK_TARGET\nname")
                    if normalization == "text-attribute":
                        (self.repo / ".gitattributes").write_text("link.txt text\n")
                        self.git("add", ".gitattributes")
                    self.git("add", "link.txt")
                    self.git("commit", "-qm", "symlink fixture")
                    if normalization == "autocrlf":
                        self.git("config", "core.autocrlf", "true")
                    link.unlink()
                    link.symlink_to("SYMLINK_TARGET\r\nname")
                    if staged:
                        self.git("add", "link.txt")
                    snapshot = self.begin("uncommitted")
                    self.assertEqual(
                        json.loads(snapshot.read_text())["artifact"]["changed_paths"], ["link.txt"]
                    )
                    patch = (snapshot.parent / "diff.patch").read_bytes()
                    self.assertIn(b"-SYMLINK_TARGET\n", patch)
                    self.assertIn(b"+SYMLINK_TARGET\r\n", patch)
                    self.assertEqual(
                        json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))[
                            "tier"
                        ],
                        2,
                    )
                    self.complete(snapshot, "no-diff", ok=False)
                    self.complete(snapshot, "tier-1", ok=False)
                    self.complete(snapshot)

    def test_instruction_symlinks_fail_closed_in_each_scope(self):
        target = self.repo / "local-policy.txt"
        target.write_text("local instruction target\n")
        (self.repo / ".git/info/exclude").write_text("local-policy.txt\n")
        for name in ("AGENTS.md", ".codex/config.toml", ".claude/commands/check.md"):
            alias = self.repo / name
            alias.parent.mkdir(parents=True, exist_ok=True)
            alias.symlink_to("local-policy.txt" if name == "AGENTS.md" else target)
            self.git("add", name)
            self.git("commit", "-qm", "instruction alias")
            self.git("branch", "-f", "main", "HEAD")
            for scope, base in (
                ("committed", "main"),
                ("uncommitted", "main"),
                ("auto", "main"),
                ("auto", "HEAD"),
            ):
                with self.subTest(path=name, scope=scope, base=base):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(HELPER),
                            "begin",
                            "--repo",
                            str(self.repo),
                            "--base",
                            base,
                            "--scope",
                            scope,
                            "--reviewer",
                            "codex",
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("instruction symlink", result.stderr)
                    self.assertFalse(
                        list((self.repo / ".git/review-receipts").glob("run-*/diff.patch"))
                    )
            self.git("rm", name)
            self.git("commit", "-qm", "remove instruction alias")

    def instruction_link_fixture(self, link="AGENTS.md", target="CLAUDE.md", link_text=None):
        alias, policy = self.repo / link, self.repo / target
        alias.parent.mkdir(parents=True, exist_ok=True)
        policy.parent.mkdir(parents=True, exist_ok=True)
        policy.write_text("Canonical instructions.\n")
        alias.symlink_to(link_text or os.path.relpath(policy, alias.parent))
        self.git("add", link, target)
        self.git("commit", "-qm", "canonical instruction link")
        self.git("branch", "-f", "main", "HEAD")
        (self.repo / "code.txt").write_text("unrelated feature change\n")
        self.git("commit", "-qam", "feature after instructions")
        return alias, policy

    def test_unchanged_canonical_instruction_link_gets_bound_receipts(self):
        original = self.git("rev-parse", "HEAD")
        for link, target in (
            ("AGENTS.md", "CLAUDE.md"),
            ("nested/AGENTS.md", "CLAUDE.md"),
            ("AGENTS.md", "docs/CLAUDE policy.md"),
        ):
            with self.subTest(link=link, target=target):
                self.git("reset", "--hard", original)
                self.git("clean", "-fd")
                alias, policy = self.instruction_link_fixture(link, target)
                for lane in ("codex", "antigravity"):
                    snapshot = self.begin(reviewer=lane)
                    artifact = json.loads(snapshot.read_text())["artifact"]
                    self.assertEqual(artifact["changed_paths"], ["code.txt"])
                    binding = artifact["instruction_links"][link]
                    self.assertEqual(binding["target"], target)
                    self.assertEqual(binding["link_object"], self.git("rev-parse", "HEAD:" + link))
                    self.assertEqual(
                        binding["target_object"], self.git("rev-parse", "HEAD:" + target)
                    )
                    self.complete(snapshot)
                    self.check(True, "--reviewer", lane)
                    clean = self.begin("uncommitted", reviewer=lane)
                    self.assertEqual(json.loads(clean.read_text())["artifact"]["changed_paths"], [])
                    self.complete(clean, "no-diff")
                    policy.write_text("Mutated canonical instructions.\n")
                    self.complete(clean, ok=False)
                    policy.write_text("Canonical instructions.\n")

    def test_committed_canonical_link_changes_need_separate_instruction_review(self):
        alias, policy = self.instruction_link_fixture()
        head = self.git("rev-parse", "HEAD")
        for change in ("link", "target"):
            with self.subTest(change=change):
                self.git("reset", "--hard", head)
                if change == "link":
                    alias.unlink()
                    alias.symlink_to("./CLAUDE.md")
                else:
                    policy.write_text("Changed canonical instructions.\n")
                self.git("add", "AGENTS.md", "CLAUDE.md")
                self.git("commit", "-qm", "changed canonical instructions")
                for lane in ("codex", "antigravity"):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(HELPER),
                            "begin",
                            "--repo",
                            str(self.repo),
                            "--base",
                            "main",
                            "--scope",
                            "committed",
                            "--reviewer",
                            lane,
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("separate instruction review", result.stderr)

    def test_canonical_link_keeps_native_crlf_target_normalization(self):
        alias, policy = self.instruction_link_fixture()
        self.git("config", "core.autocrlf", "true")
        policy.unlink()
        self.git("checkout", "--", "CLAUDE.md")
        self.assertEqual(policy.read_bytes(), b"Canonical instructions.\r\n")
        snapshot = self.begin()
        self.complete(snapshot)
        self.check()
        policy.write_bytes(b"Canonical instructions.\n")
        self.check(False)
        self.complete(snapshot, ok=False)
        self.complete(self.begin())
        self.check()

    def test_sparse_canonical_link_requires_present_link_and_target(self):
        for omitted_path in ("docs/AGENTS.md", "docs/CLAUDE.md"):
            with self.subTest(omitted=omitted_path):
                self.git("sparse-checkout", "disable")
                self.git("reset", "--hard", self.git("rev-list", "--max-parents=0", "HEAD"))
                self.git("clean", "-fd")
                self.instruction_link_fixture("docs/AGENTS.md", "docs/CLAUDE.md")
                self.git("config", "core.sparseCheckout", "true")
                self.git("update-index", "--skip-worktree", omitted_path)
                (self.repo / omitted_path).unlink()
                for scope in ("committed", "uncommitted"):
                    self.run_helper(
                        "begin",
                        "--repo",
                        str(self.repo),
                        "--base",
                        "main",
                        "--scope",
                        scope,
                        "--reviewer",
                        "codex",
                        ok=False,
                    )

    def test_link_and_target_mutations_stale_each_lane_receipt(self):
        alias, policy = self.instruction_link_fixture()
        original_target = self.git("rev-parse", "HEAD:CLAUDE.md")
        for lane in ("codex", "antigravity"):
            for mutation in (
                "target-worktree",
                "target-index",
                "target-mode",
                "target-commit",
                "link-worktree",
                "link-index",
                "link-mode",
                "link-commit",
            ):
                with self.subTest(lane=lane, mutation=mutation):
                    self.git("reset", "--hard", "HEAD")
                    snapshot = self.begin(reviewer=lane)
                    self.complete(snapshot)
                    self.check(True, "--reviewer", lane)
                    if mutation.startswith("target"):
                        policy.write_text("Changed target bytes.\n")
                        if mutation == "target-mode":
                            policy.write_text("Canonical instructions.\n")
                            policy.chmod(0o755)
                        elif mutation in ("target-index", "target-commit"):
                            self.git("add", "CLAUDE.md")
                            if mutation == "target-index":
                                policy.write_text("Canonical instructions.\n")
                            else:
                                self.git("commit", "-qm", "changed canonical policy")
                    else:
                        alias.unlink()
                        if mutation == "link-mode":
                            alias.write_text("CLAUDE.md")
                        else:
                            alias.symlink_to("./CLAUDE.md")
                        if mutation in ("link-index", "link-commit"):
                            self.git("add", "AGENTS.md")
                            if mutation == "link-index":
                                alias.unlink()
                                alias.symlink_to("CLAUDE.md")
                            else:
                                self.git("commit", "-qm", "changed canonical link")
                    self.check(False, "--reviewer", lane)
                    self.complete(snapshot, ok=False)
                    self.git(
                        "reset", "--hard", json.loads(snapshot.read_text())["artifact"]["head"]
                    )
                    self.assertEqual(self.git("rev-parse", "HEAD:CLAUDE.md"), original_target)

    def test_instruction_link_mismatches_fail_in_every_scope(self):
        alias, policy = self.instruction_link_fixture()
        for mutation in (
            "target-worktree",
            "target-index",
            "target-mode",
            "target-delete",
            "link-worktree",
            "link-index",
            "link-mode",
            "link-delete",
        ):
            with self.subTest(mutation=mutation):
                self.git("reset", "--hard", "HEAD")
                changed = policy if mutation.startswith("target") else alias
                if mutation.endswith("mode"):
                    if changed == policy:
                        changed.chmod(0o755)
                    else:
                        changed.unlink()
                        changed.write_text("CLAUDE.md")
                elif mutation.endswith("delete"):
                    changed.unlink()
                elif changed == policy:
                    changed.write_text("Unreviewed instruction change.\n")
                else:
                    changed.unlink()
                    changed.symlink_to("./CLAUDE.md")
                if mutation.endswith("index"):
                    self.git("add", changed.name)
                    if changed == policy:
                        changed.write_text("Canonical instructions.\n")
                    else:
                        changed.unlink()
                        changed.symlink_to("CLAUDE.md")
                for scope in ("committed", "uncommitted", "auto"):
                    self.run_helper(
                        "begin",
                        "--repo",
                        str(self.repo),
                        "--base",
                        "main",
                        "--scope",
                        scope,
                        "--reviewer",
                        "codex",
                        ok=False,
                    )

    def test_unsupported_instruction_link_targets_fail_without_export(self):
        original = self.git("rev-parse", "HEAD")
        outside = Path(self.tmp.name) / "CLAUDE.md"
        outside.write_text("OUTSIDE_PRIVATE_INSTRUCTION_MARKER\n")
        for unsafe in (
            "external",
            "absolute-internal",
            "escape-reentry",
            "dangling",
            "cycle",
            "chain",
            "untracked",
            "ignored",
            "unnamed",
            "directory",
            "root-directory",
            "symlink-parent",
            "missing-parent",
            "trailing-slash",
            "trailing-dot",
        ):
            with self.subTest(target=unsafe):
                self.git("reset", "--hard", original)
                self.git("clean", "-fdx")
                (self.repo / ".git/info/exclude").write_text("")
                policy = self.repo / "CLAUDE.md"
                policy.write_text("Canonical instructions.\n")
                self.git("add", "CLAUDE.md")
                text = "CLAUDE.md"
                if unsafe == "external":
                    text = "../CLAUDE.md"
                elif unsafe == "absolute-internal":
                    text = str(policy)
                elif unsafe == "escape-reentry":
                    text = "../repo/CLAUDE.md"
                elif unsafe == "dangling":
                    text = "MISSING-CLAUDE.md"
                elif unsafe in ("cycle", "chain"):
                    policy.unlink()
                    policy.symlink_to("AGENTS.md" if unsafe == "cycle" else "GEMINI.md")
                    (self.repo / "GEMINI.md").write_text("Chained instructions.\n")
                    self.git("add", "CLAUDE.md", "GEMINI.md")
                elif unsafe in ("untracked", "ignored"):
                    self.git("rm", "--cached", "CLAUDE.md")
                    if unsafe == "ignored":
                        (self.repo / ".git/info/exclude").write_text("CLAUDE.md\n")
                elif unsafe == "unnamed":
                    text = "policy.lock"
                    (self.repo / text).write_text("Unclassified instruction target.\n")
                    self.git("add", text)
                elif unsafe == "directory":
                    text = "docs"
                    (self.repo / "docs").mkdir()
                elif unsafe == "root-directory":
                    text = "."
                elif unsafe == "symlink-parent":
                    (self.repo / "alias").symlink_to(".", target_is_directory=True)
                    text = "alias/CLAUDE.md"
                    self.git("add", "alias")
                elif unsafe == "missing-parent":
                    text = "missing/../CLAUDE.md"
                elif unsafe == "trailing-slash":
                    text = "CLAUDE.md/"
                elif unsafe == "trailing-dot":
                    text = "CLAUDE.md/."
                (self.repo / "AGENTS.md").symlink_to(text)
                self.git("add", "AGENTS.md")
                self.git("commit", "-qm", "unsupported instruction target")
                self.git("branch", "-f", "main", "HEAD")
                for scope in ("committed", "uncommitted", "auto"):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(HELPER),
                            "begin",
                            "--repo",
                            str(self.repo),
                            "--base",
                            "main",
                            "--scope",
                            scope,
                            "--reviewer",
                            "codex",
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertNotIn(
                        "OUTSIDE_PRIVATE_INSTRUCTION_MARKER", result.stdout + result.stderr
                    )

    def test_deleted_parent_directory_remains_reviewable(self):
        nested = self.repo / "nested"
        nested.mkdir()
        (nested / "data.txt").write_text("tracked content\n")
        self.git("add", "nested/data.txt")
        self.git("commit", "-qm", "nested file")
        (nested / "data.txt").unlink()
        nested.rmdir()
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("-tracked content", patch)
        self.assertIn("new mode missing", patch)

    def test_directory_to_file_replacement_reviews_deletion_and_addition(self):
        for path in ("nested/code.txt", "deep/nested/code.txt"):
            child = self.repo / path
            child.parent.mkdir(parents=True)
            child.write_text("tracked child\n")
        self.git("add", "nested/code.txt", "deep/nested/code.txt")
        self.git("commit", "-qm", "nested files")
        for path in ("nested/code.txt", "deep/nested/code.txt"):
            child = self.repo / path
            child.unlink()
            child.parent.rmdir()
            replacement = self.repo / Path(path).parts[0]
            if replacement.is_dir():
                replacement.rmdir()
            replacement.write_text("replacement file\n")
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(
            artifact["changed_paths"], ["deep", "deep/nested/code.txt", "nested", "nested/code.txt"]
        )
        self.assertEqual(patch.count("-tracked child"), 2)
        self.assertEqual(patch.count("+replacement file"), 2)
        self.complete(snapshot)

    def test_file_to_directory_replacement_reviews_deletion_and_children(self):
        replaced = self.repo / "code.txt"
        replaced.unlink()
        replaced.mkdir()
        (replaced / "child.txt").write_text("new child\n")
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.git("add", "code.txt")
                snapshot = self.begin("uncommitted")
                artifact = json.loads(snapshot.read_text())["artifact"]
                self.assertEqual(artifact["changed_paths"], ["code.txt", "code.txt/child.txt"])
                patch = (snapshot.parent / "diff.patch").read_text()
                self.assertIn("-changed", patch)
                self.assertIn("+new child", patch)
                self.complete(snapshot)

    def test_file_replaced_by_empty_directory_reviews_deletion(self):
        replaced = self.repo / "code.txt"
        replaced.unlink()
        replaced.mkdir()
        snapshot = self.begin("uncommitted")
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(artifact["changed_paths"], ["code.txt"])
        self.assertIn("-changed", (snapshot.parent / "diff.patch").read_text())

    def test_untracked_nested_repository_is_not_silently_treated_as_missing(self):
        nested = self.repo / "nested"
        nested.mkdir()
        self.git("init", "-q", str(nested))
        (nested / "code.txt").write_text("nested implementation\n")
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "uncommitted",
            "--reviewer",
            "codex",
            ok=False,
        )

    def test_staged_gitlink_replacing_tracked_file_is_rejected(self):
        replaced = self.repo / "code.txt"
        replaced.unlink()
        replaced.mkdir()
        self.git("init", "-q", str(replaced))
        self.git("-C", str(replaced), "config", "user.name", "fixture")
        self.git("-C", str(replaced), "config", "user.email", "fixture@example.test")
        (replaced / "nested.py").write_text("nested implementation\n")
        self.git("-C", str(replaced), "add", "nested.py")
        self.git("-C", str(replaced), "commit", "-qm", "nested implementation")
        self.git("add", "code.txt")
        self.assertTrue(self.git("ls-files", "--stage", "code.txt").startswith("160000 "))
        for scope in ("committed", "uncommitted", "auto"):
            with self.subTest(scope=scope):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(HELPER),
                        "begin",
                        "--repo",
                        str(self.repo),
                        "--base",
                        "main",
                        "--scope",
                        scope,
                        "--reviewer",
                        "codex",
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("submodule snapshots are unsupported", result.stderr)
                self.assertFalse(
                    list((self.repo / ".git/review-receipts").glob("run-*/diff.patch"))
                )

    def test_base_only_gitlink_deletion_cannot_receive_committed_review(self):
        self.git(
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            self.git("rev-parse", "HEAD"),
            "vendor",
        )
        self.git("commit", "-qm", "base gitlink")
        self.git("update-ref", "refs/heads/main", "HEAD")
        self.git("update-index", "--force-remove", "vendor")
        self.git("commit", "-qm", "delete gitlink")
        for ignore in ("none", "all"):
            self.git("config", "diff.ignoreSubmodules", ignore)
            for scope in ("committed", "auto"):
                with self.subTest(ignore_submodules=ignore, scope=scope):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(HELPER),
                            "begin",
                            "--repo",
                            str(self.repo),
                            "--base",
                            "main",
                            "--scope",
                            scope,
                            "--reviewer",
                            "codex",
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("submodule snapshots are unsupported", result.stderr)
                    self.assertFalse(
                        list((self.repo / ".git/review-receipts").glob("run-*/diff.patch"))
                    )
        (self.repo / "code.txt").write_text("unrelated workspace edit\n")
        snapshot = self.begin("uncommitted")
        self.assertEqual(
            json.loads(snapshot.read_text())["artifact"]["changed_paths"], ["code.txt"]
        )
        self.assertIn("+unrelated workspace edit", (snapshot.parent / "diff.patch").read_text())
        self.complete(snapshot)

    def test_uncommitted_review_does_not_require_related_base_history(self):
        unrelated = self.git(
            "commit-tree", self.git("rev-parse", "HEAD^{tree}"), "-m", "unrelated root"
        )
        self.git("update-ref", "refs/heads/unrelated", unrelated)
        (self.repo / "code.txt").write_text("workspace change\n")
        snapshot = self.begin("uncommitted", base="unrelated")
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(artifact["base"]["commit"], unrelated)
        self.assertIsNone(artifact["base"]["merge_base"])
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("-changed", patch)
        self.assertIn("+workspace change", patch)
        self.complete(snapshot)

    def test_committed_review_rejects_unrelated_base_history(self):
        unrelated = self.git(
            "commit-tree", self.git("rev-parse", "HEAD^{tree}"), "-m", "unrelated root"
        )
        self.git("update-ref", "refs/heads/unrelated", unrelated)
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "unrelated",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )

    def test_committed_pass_is_private_and_bound(self):
        snapshot = self.begin()
        self.complete(snapshot)
        self.check()
        receipt_path = self.repo / ".git/review-receipts/codex.json"
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(stat.S_IMODE(receipt_path.stat().st_mode), 0o600)
        self.assertEqual(receipt["artifact"]["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(receipt["artifact"]["base"]["commit"], self.git("rev-parse", "main"))
        self.assertIsNone(receipt["reviewer"]["observed_model"])
        self.assertEqual(receipt["completion"]["status"], "completed")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_whitespace_twin_repository_cannot_reuse_sibling_receipt(self):
        self.complete(self.begin())
        original = self.repo
        head = self.git("rev-parse", "HEAD")
        for suffix in (" ", "\t", "\n"):
            with self.subTest(suffix=repr(suffix)):
                twin = Path(str(original) + suffix)
                shutil.copytree(original, twin)
                (twin / "AGENTS.md").write_text("TWIN_DIRTY_INSTRUCTION_MARKER\n")
                self.run_helper("check", "--repo", str(twin), "--head", head, ok=False)
                self.run_helper(
                    "begin",
                    "--repo",
                    str(twin),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                # Rejection in the requested repository must not invalidate its sibling.
                self.check()

    def test_whitespace_repository_and_linked_worktree_paths_stay_exact(self):
        original = self.repo
        for linked in (False, True):
            for suffix in (" ", "\t", "\n"):
                with self.subTest(linked=linked, suffix=repr(suffix)):
                    twin = Path(str(original) + ("-linked" if linked else "") + suffix)
                    if linked:
                        self.git("worktree", "add", "--detach", str(twin), "HEAD")
                    else:
                        shutil.copytree(original, twin)
                    self.repo = twin
                    try:
                        directory = os.fsdecode(
                            subprocess.check_output(
                                ["git", "-C", str(twin), "rev-parse", "--absolute-git-dir"]
                            ).removesuffix(b"\n")
                        )
                        snapshot = self.begin()
                        record = json.loads(snapshot.read_text())
                        self.assertEqual(record["repository"], str(twin))
                        self.assertEqual(record["git_directory"], directory)
                        self.complete(snapshot)
                        self.check()
                        (twin / "code.txt").write_text("EXACT_WORKTREE_MARKER\n")
                        snapshot = self.begin("uncommitted")
                        self.assertIn(
                            "EXACT_WORKTREE_MARKER", (snapshot.parent / "diff.patch").read_text()
                        )
                        self.complete(snapshot)
                    finally:
                        self.repo = original

    def test_separate_git_directory_whitespace_is_preserved(self):
        directory = Path(self.tmp.name) / "metadata \t"
        self.git("init", "--separate-git-dir", str(directory))
        snapshot = self.begin()
        self.assertEqual(json.loads(snapshot.read_text())["git_directory"], str(directory))
        self.assertEqual(snapshot.parent.parent, directory / "review-receipts")
        self.complete(snapshot)
        self.check()

    def test_native_unsupported_git_directory_path_fails_closed(self):
        directory = Path(self.tmp.name) / "metadata\n"
        self.git("init", "--separate-git-dir", str(directory))
        # Git's gitdir-file parser cannot reopen a metadata path ending in LF.
        result = subprocess.run(
            ["git", "-C", str(self.repo), "rev-parse", "--absolute-git-dir"], capture_output=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )
        self.assertFalse((directory / "review-receipts").exists())

    def test_inherited_pathspec_settings_cannot_hide_review_content(self):
        settings = (
            {"GIT_LITERAL_PATHSPECS": "1"},
            {"GIT_GLOB_PATHSPECS": "1"},
            {"GIT_NOGLOB_PATHSPECS": "1"},
            {"GIT_ICASE_PATHSPECS": "1"},
            {"GIT_GLOB_PATHSPECS": "1", "GIT_NOGLOB_PATHSPECS": "1"},
            {
                "GIT_LITERAL_PATHSPECS": "1",
                "GIT_GLOB_PATHSPECS": "1",
                "GIT_NOGLOB_PATHSPECS": "1",
                "GIT_ICASE_PATHSPECS": "1",
            },
        )
        (self.repo / ".codex").mkdir()
        (self.repo / ".codex/config.toml").write_text("PATHSPEC_INSTRUCTION_MARKER\n")
        (self.repo / "active[1].lock").write_text("PATHSPEC_LITERAL_MARKER\n")
        (self.repo / "active[1].lock").chmod(0o755)
        (self.repo / "active1.lock").write_text("PATHSPEC_PASSIVE_MARKER\n")
        (self.repo / "ACTIVE[1].lock").write_text("PATHSPEC_CASE_PASSIVE_MARKER\n")
        self.git("add", ".codex/config.toml", "active[1].lock", "active1.lock", "ACTIVE[1].lock")
        self.git("commit", "-qm", "pathspec fixture")
        head = self.git("rev-parse", "HEAD")
        for setting in settings:
            with self.subTest(setting=setting), mock.patch.dict(os.environ, setting):
                snapshot = self.begin()
                patch = (snapshot.parent / "diff.patch").read_text()
                self.assertIn("PATHSPEC_INSTRUCTION_MARKER", patch)
                self.assertIn("PATHSPEC_LITERAL_MARKER", patch)
                self.assertNotIn("PATHSPEC_PASSIVE_MARKER", patch)
                self.assertNotIn("PATHSPEC_CASE_PASSIVE_MARKER", patch)
                self.complete(snapshot, "no-diff", ok=False)
                self.complete(snapshot)
                self.run_helper("check", "--repo", str(self.repo), "--head", head)

    def test_empty_extraction_cannot_exempt_reviewable_changed_paths(self):
        shim = Path(self.tmp.name) / "bin"
        shim.mkdir()
        real_git = shutil.which("git")
        wrapper = shim / "git"
        wrapper.write_text(
            f"#!{sys.executable}\nimport os, sys\n"
            'if "diff" in sys.argv and "--text" in sys.argv: sys.exit(0)\n'
            f"os.execv({real_git!r}, [{real_git!r}, *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": str(shim) + os.pathsep + os.environ["PATH"]}):
            snapshot = self.begin()
            self.assertEqual((snapshot.parent / "diff.patch").read_bytes(), b"")
            self.assertEqual(
                json.loads(snapshot.read_text())["artifact"]["changed_paths"], ["code.txt"]
            )
            self.complete(snapshot, "no-diff", ok=False)
            self.complete(snapshot)
            receipt = self.repo / ".git/review-receipts/codex.json"
            record = json.loads(receipt.read_text())
            record["completion"]["outcome"] = "no-diff"
            receipt.write_text(json.dumps(record))
            self.check(False)

    def test_missing_malformed_and_uncommitted_receipts_block(self):
        self.check(False)
        snapshot = self.begin("uncommitted")
        self.complete(snapshot)
        self.check(False)
        (self.repo / ".git/review-receipts/codex.json").write_text("{broken")
        self.check(False)

    def test_stale_outgoing_head_and_reviewer_mismatch_block(self):
        self.complete(self.begin())
        self.check(False, "--reviewer", "antigravity")
        self.run_helper(
            "check", "--repo", str(self.repo), "--head", self.git("rev-parse", "main"), ok=False
        )
        self.git("commit", "--allow-empty", "-qm", "new head")
        self.check(False)

    def test_changes_before_completion_block(self):
        for change in ("head", "base", "index", "worktree", "untracked"):
            with self.subTest(change=change):
                snapshot = self.begin()
                if change == "head":
                    self.git("commit", "--allow-empty", "-qm", "concurrent")
                elif change == "base":
                    self.git("update-ref", "refs/heads/main", "HEAD")
                elif change == "index":
                    (self.repo / "code.txt").write_text("staged\n")
                    self.git("add", "code.txt")
                elif change == "worktree":
                    (self.repo / "code.txt").write_text("unstaged\n")
                else:
                    (self.repo / "new.txt").write_text("untracked\n")
                self.complete(snapshot, ok=False)

    def test_change_after_completion_blocks(self):
        self.complete(self.begin())
        (self.repo / "code.txt").write_text("later\n")
        self.check(False)

    def test_changed_diff_and_result_cannot_be_reused(self):
        snapshot = self.begin()
        (snapshot.parent / "diff.patch").write_text("different target")
        self.complete(snapshot, ok=False)
        snapshot = self.begin()
        self.result.write_text("")
        self.complete(snapshot, ok=False)

    def test_ignored_application_hooks_allow_committed_review(self):
        (self.repo / ".git/info/exclude").write_text("node_modules/\ndist/\nsrc/\n")
        for name in (
            "node_modules/example/hooks/useThing.js",
            "node_modules/example/webhooks/client.js",
            "dist/hooks/useThing.js",
            "src/hooks/useThing.js",
        ):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("export function useThing() {}\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.complete(self.begin())
        self.check()

    def test_ignored_hook_dependencies_and_manifests_are_excluded_from_review(self):
        (self.repo / ".git/info/exclude").write_text(
            "claude/hooks/node_modules/\nclaude/hooks/bun.lock\nclaude/hooks/package.json\n"
            ".claude/hooks/node_modules/\n.codex/hooks/node_modules/\n"
        )
        for name in (
            "claude/hooks/node_modules/x/index.d.ts",
            "claude/hooks/bun.lock",
            "claude/hooks/package.json",
            # A dependency's own instruction-shaped files are not this repo's
            # instruction surface either: bun-types ships a CLAUDE.md (#439).
            "claude/hooks/node_modules/bun-types/CLAUDE.md",
            "claude/hooks/node_modules/some-pkg/AGENTS.md",
            "claude/hooks/node_modules/some-pkg/skills/x/SKILL.md",
            # The installed hook trees vendor the same dependencies.
            ".claude/hooks/node_modules/bun-types/CLAUDE.md",
            ".codex/hooks/node_modules/some-pkg/AGENTS.md",
        ):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("dummy content\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        snapshot = self.begin("uncommitted")
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(artifact["changed_paths"], [])
        self.assertEqual((snapshot.parent / "diff.patch").read_text(), "")
        self.complete(snapshot, "no-diff")
        committed_snapshot = self.begin("committed")
        committed_artifact = json.loads(committed_snapshot.read_text())["artifact"]
        self.assertEqual(committed_artifact["changed_paths"], ["code.txt"])
        self.complete(committed_snapshot)

    def test_own_worktree_directory_is_not_snapshotted(self):
        (self.repo / ".git/info/exclude").write_text(".claude/worktrees/\n")
        baseline = json.loads(self.begin("committed").read_text())["artifact"]
        # The last one holds a newline: git prints worktree paths raw, so a plain
        # line-by-line parse of `worktree list --porcelain` would truncate it.
        for name, branch in (
            (".claude/worktrees/agent-x", "agent-x"),
            ("visible/agent-y", "agent-y"),
            (".claude/worktrees/od\nd", "odd"),
        ):
            with self.subTest(worktree=name):
                self.git("worktree", "add", "-q", name, "-b", branch)
                (self.repo / name / "AGENTS.md").write_text("instructions over there\n")
                # Git reports a worktree as a single directory entry with a trailing
                # slash and never reads through the boundary (#474). An ignored one
                # is listed as ignored, a visible one as untracked.
                listing = set()
                for ignored in (("--ignored",), ()):
                    entries = self.git("ls-files", "--others", "--exclude-standard", "-z", *ignored)
                    listing |= {entry for entry in entries.split("\0") if entry}
                self.assertIn(name + "/", listing)
                snapshot = self.begin("committed")
                artifact = json.loads(snapshot.read_text())["artifact"]
                self.assertEqual(artifact["untracked_sha256"], baseline["untracked_sha256"])
                self.assertEqual(artifact["worktree_sha256"], baseline["worktree_sha256"])
                self.assertEqual(artifact["changed_paths"], ["code.txt"])
                self.complete(snapshot)
                uncommitted = json.loads(self.begin("uncommitted").read_text())["artifact"]
                self.assertEqual(uncommitted["changed_paths"], [])

    def test_fabricated_repository_boundary_fails_closed(self):
        # A directory only has to look like a repository for git to stop at it, so
        # a `.git` that no worktree owns must not silently drop a dirty instruction
        # file from the snapshot (#474).
        # The ignored case reaches the snapshot as an instruction surface, the
        # visible one as untracked; both must refuse rather than drop the entry.
        (self.repo / ".git/info/exclude").write_text(".claude/\n")
        for name in (".claude/skills/evil", "vendor/nested"):
            with self.subTest(boundary=name):
                boundary = self.repo / name
                (boundary / ".git/objects").mkdir(parents=True)
                (boundary / ".git/refs").mkdir()
                (boundary / ".git/HEAD").write_text("ref: refs/heads/main\n")
                (boundary / "SKILL.md").write_text("instructions of no repo at all\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                shutil.rmtree(boundary)

    def test_stale_worktree_registration_is_not_allowlisted(self):
        # Git keeps printing a `worktree` line for a registration whose directory
        # was removed, and stops calling it prunable once anything occupies the
        # path again, so path equality alone would hand the allowlist to a decoy
        # planted over the stale registration. Neither shape of decoy owns the
        # path: a fabricated `.git` directory, or a foreign repository whose `.git`
        # file points outside this repo's worktree store (#474).
        (self.repo / ".git/info/exclude").write_text(".claude/\n")
        for decoy in ("fabricated", "separate-git-dir"):
            with self.subTest(decoy=decoy):
                evil = self.repo / ".claude/skills/evil"
                self.git("worktree", "add", "-q", str(evil), "-b", "wt-" + decoy)
                shutil.rmtree(evil)
                if decoy == "fabricated":
                    (evil / ".git/objects").mkdir(parents=True)
                    (evil / ".git/refs").mkdir()
                    (evil / ".git/HEAD").write_text("ref: refs/heads/main\n")
                else:
                    foreign = Path(self.tmp.name) / ("foreign-" + decoy)
                    subprocess.check_output(
                        ["git", "init", "-q", "--separate-git-dir", str(foreign), str(evil)],
                        stderr=subprocess.PIPE,
                    )
                    self.assertTrue((evil / ".git").is_file())
                (evil / "SKILL.md").write_text("instructions of no worktree at all\n")
                self.assertIn(str(evil), self.git("worktree", "list", "--porcelain"))
                self.expect_begin_refused()
                shutil.rmtree(evil)
                self.git("worktree", "prune")

    def expect_begin_refused(self):
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )

    def test_exec_bit_drift_ignored_when_core_filemode_false(self):
        self.git("config", "core.filemode", "false")
        path = self.repo / "code.txt"
        path.chmod(0o755)
        self.assertEqual(self.git("status", "--porcelain"), "")
        snapshot = self.begin("uncommitted")
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(artifact["changed_paths"], [])
        self.assertEqual((snapshot.parent / "diff.patch").read_text(), "")
        self.complete(snapshot, "no-diff")
        agents = self.repo / "AGENTS.md"
        agents.write_text("instruction\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "agents")
        agents.chmod(0o755)
        committed_snapshot = self.begin("committed")
        self.complete(committed_snapshot)
        # Verify instruction symlink target mode drift does not fail instruction_links
        self.git("reset", "--hard", "main")
        target = self.repo / "CLAUDE.md"
        target.write_text("claude instructions\n")
        symlink = self.repo / "AGENTS.md"
        symlink.symlink_to("CLAUDE.md")
        self.git("add", "CLAUDE.md", "AGENTS.md")
        self.git("commit", "-qm", "base with link")
        self.git("checkout", "-qb", "feature-link")
        (self.repo / "code.txt").write_text("changed\n")
        self.git("commit", "-qam", "work on feature")
        self.git("config", "core.filemode", "false")
        target.chmod(0o755)
        symlink_snapshot = self.begin("committed", base="HEAD~1")
        self.complete(symlink_snapshot)

    def test_dirty_ignored_instruction_blocks_committed_capture(self):
        for name in (
            "AGENTS.md",
            ".codex/config.toml",
            ".claude/settings.json",
            ".gemini/settings.json",
            "claude/hooks/pre-push.sh",
            "githooks/pre-push",
            ".githooks/pre-push",
            "node_modules/example/.codex/config.toml",
            "node_modules/example/AGENTS.md",
            # A vendored githooks/ directory must not hide the dependency's own
            # AGENTS.md: the vendored test only fires below the hook marker (#439).
            "node_modules/example/githooks/AGENTS.md",
            "claude/skills/x/SKILL.md",
        ):
            with self.subTest(path=name):
                (self.repo / ".git/info/exclude").write_text(name + "\n")
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("local instruction fixture\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                path.unlink()

    def test_ignored_instructions_are_in_uncommitted_review_and_auto_fallback(self):
        self.git("checkout", "-B", "feature", "main")
        (self.repo / ".git/info/exclude").write_text("AGENTS.md\n.codex/\n")
        (self.repo / "AGENTS.md").write_text("AGENT_INSTRUCTION_MARKER\n")
        (self.repo / ".codex").mkdir()
        (self.repo / ".codex/config.toml").write_text("CODEX_CONFIG_MARKER\n")
        for scope in ("uncommitted", "auto"):
            with self.subTest(scope=scope):
                snapshot = self.begin(scope)
                artifact = json.loads(snapshot.read_text())["artifact"]
                self.assertEqual(artifact["scope"], "uncommitted")
                self.assertEqual(artifact["changed_paths"], [".codex/config.toml", "AGENTS.md"])
                patch = (snapshot.parent / "diff.patch").read_text()
                self.assertIn("+AGENT_INSTRUCTION_MARKER", patch)
                self.assertIn("+CODEX_CONFIG_MARKER", patch)
                self.complete(snapshot, "no-diff", ok=False)
                self.complete(snapshot)

    def test_ignored_agent_credentials_and_state_are_not_review_inputs(self):
        private_paths = (
            ".codex/auth.json",
            ".codex/.credentials.json",
            ".codex/state_5.sqlite-wal",
            ".codex/sessions/run.jsonl",
            ".claude/.credentials.json",
            ".claude/projects/run.jsonl",
            ".gemini/oauth_creds.json",
            ".gemini/antigravity-cli/brain/transcript.jsonl",
            ".agents/codex/auth.json",
            ".antigravity/.credentials.json",
            "codex/auth.json",
            "antigravity/auth.json",
        )
        (self.repo / ".git/info/exclude").write_text("\n".join(private_paths) + "\n")
        for name in private_paths:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("SYNTHETIC_PRIVATE_STATE_MARKER\n")
        for scope in ("committed", "uncommitted", "auto"):
            with self.subTest(scope=scope):
                snapshot = self.begin(scope)
                self.assertNotIn(
                    "SYNTHETIC_PRIVATE_STATE_MARKER", (snapshot.parent / "diff.patch").read_text()
                )
                self.assertFalse(
                    set(private_paths)
                    & set(json.loads(snapshot.read_text())["artifact"]["changed_paths"])
                )
                self.complete(snapshot)

    def test_runtime_cache_keeps_named_instructions_visible(self):
        (self.repo / ".git/info/exclude").write_text(".codex/cache/\n")
        cache = self.repo / ".codex/cache"
        cache.mkdir(parents=True)
        (cache / "state.json").write_text("SYNTHETIC_PRIVATE_CACHE_MARKER\n")
        (cache / "AGENTS.md").write_text("CACHE_INSTRUCTION_MARKER\n")
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("+CACHE_INSTRUCTION_MARKER", patch)
        self.assertNotIn("SYNTHETIC_PRIVATE_CACHE_MARKER", patch)
        self.assertEqual(
            json.loads(snapshot.read_text())["artifact"]["changed_paths"],
            [".codex/cache/AGENTS.md"],
        )

    def test_explicit_agent_credentials_block_before_patch_generation(self):
        for name in (
            ".codex/auth.json",
            ".claude/.credentials.json",
            ".gemini/oauth_creds.json",
            ".agents/codex/auth.json",
            ".antigravity/.credentials.json",
            "codex/auth.json",
            "antigravity/auth.json",
        ):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("SYNTHETIC_CREDENTIAL_MARKER\n")
            for staged in (False, True):
                if staged:
                    self.git("add", name)
                for scope in ("committed", "uncommitted", "auto"):
                    with self.subTest(path=name, staged=staged, scope=scope):
                        result = subprocess.run(
                            [
                                sys.executable,
                                str(HELPER),
                                "begin",
                                "--repo",
                                str(self.repo),
                                "--base",
                                "main",
                                "--scope",
                                scope,
                                "--reviewer",
                                "codex",
                            ],
                            capture_output=True,
                            text=True,
                        )
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("private agent runtime data", result.stderr)
                        self.assertNotIn(
                            "SYNTHETIC_CREDENTIAL_MARKER", result.stdout + result.stderr
                        )
                        self.assertFalse(
                            list((self.repo / ".git/review-receipts").glob("run-*/diff.patch"))
                        )
            self.git("rm", "--cached", name)
            path.unlink()

    def test_committed_credential_deletions_and_renames_block_before_old_blob_read(self):
        credential = self.repo / ".codex/auth.json"
        credential.parent.mkdir()
        credential.write_text("SYNTHETIC_OLD_CREDENTIAL_MARKER\n")
        self.git("add", ".codex/auth.json")
        self.git("commit", "-qm", "old credential fixture")
        self.git("update-ref", "refs/heads/main", "HEAD")
        for operation in ("delete", "rename"):
            with self.subTest(operation=operation):
                self.git("checkout", "-B", "feature", "main")
                if operation == "delete":
                    self.git("rm", ".codex/auth.json")
                else:
                    self.git("mv", ".codex/auth.json", "notes.txt")
                self.git("commit", "-qm", operation)
                result = subprocess.run(
                    [
                        sys.executable,
                        str(HELPER),
                        "begin",
                        "--repo",
                        str(self.repo),
                        "--base",
                        "main",
                        "--scope",
                        "committed",
                        "--reviewer",
                        "codex",
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("private agent runtime data", result.stderr)
                self.assertNotIn("SYNTHETIC_OLD_CREDENTIAL_MARKER", result.stdout + result.stderr)
                self.assertFalse(
                    list((self.repo / ".git/review-receipts").glob("run-*/diff.patch"))
                )

    def test_external_diff_textconv_and_clean_filters_never_run(self):
        marker = Path(self.tmp.name) / "EXECUTED"
        command = f"touch {marker}"
        (self.repo / ".gitattributes").write_text("*.txt diff=evil filter=evil\n")
        self.git("config", "diff.evil.command", command)
        self.git("config", "diff.evil.textconv", command)
        self.git("config", "filter.evil.clean", command)
        self.git("config", "filter.evil.required", "true")
        fsmonitor = Path(self.tmp.name) / "fsmonitor"
        fsmonitor.write_text(f'#!/bin/sh\ntouch "{marker}"\nprintf "clock\\0"\n')
        fsmonitor.chmod(0o755)
        self.git("config", "core.fsmonitor", str(fsmonitor))
        snapshot = self.begin()
        self.complete(snapshot)
        self.check()
        self.assertFalse(marker.exists())
        self.assertIn("+changed", (snapshot.parent / "diff.patch").read_text())
        snapshot = self.begin("uncommitted")
        self.assertFalse(marker.exists())
        self.assertIn(".gitattributes", (snapshot.parent / "diff.patch").read_text())

    def test_unknown_completion_and_false_exemptions_block(self):
        snapshot = self.begin()
        self.complete(snapshot, "degraded", ok=False)
        self.complete(snapshot, "no-diff", ok=False)
        self.complete(snapshot, "tier-1", ok=False)

    def test_completed_receipt_malformed_nested_fields_block(self):
        self.complete(self.begin())
        path = self.repo / ".git/review-receipts/codex.json"
        original = json.loads(path.read_text())
        for key in ("artifact", "reviewer", "completion"):
            for invalid in (None, {}, "wrong"):
                bad = dict(original)
                bad[key] = invalid
                path.write_text(json.dumps(bad))
                self.check(False)

    def test_no_newline_worktree_patch_keeps_both_lines(self):
        (self.repo / "code.txt").write_text("old")
        self.git("commit", "-qam", "no newline")
        (self.repo / "code.txt").write_text("new")
        snapshot = self.begin("uncommitted")
        patch = (snapshot.parent / "diff.patch").read_text()
        self.assertIn("-old\n\\ No newline at end of file\n+new", patch)

    def assert_patch_round_trip(self, path, before, after, patch):
        # Remove only the review annotations; Git consumes the actual headers
        # and hunks without repairing their line structure or path quoting.
        applicable = b"\n".join(
            line
            for line in patch.split(b"\n")
            if not line.startswith((b"review state ", b"old mode ", b"new mode "))
        )
        path.write_bytes(before)
        for options in (("--check",), ()):
            result = subprocess.run(
                ["git", "-C", str(self.repo), "apply", "--whitespace=nowarn", *options, "-"],
                input=applicable,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, repr(result.stderr) + "\n" + repr(applicable))
        self.assertEqual(path.read_bytes(), after)

    def test_patch_round_trip_preserves_non_lf_separators_and_eof(self):
        self.git("config", "core.autocrlf", "false")
        cases = [
            (
                repr(separator),
                ('value="one' + separator + 'before"\n').encode(),
                ('value="one' + separator + 'after"\n').encode(),
            )
            for separator in ("\v", "\f", "\r", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029")
        ]
        cases += [
            ("lf", b"first\nbefore\nlast\n", b"first\nafter\nlast\n"),
            ("crlf", b"first\r\nbefore\r\n", b"first\r\nafter\r\n"),
            ("no-eof-lf", b"one\vbefore", b"one\vafter"),
            ("add-eof-lf", b"one\vbefore", b"one\vafter\n"),
            ("remove-eof-lf", b"one\vbefore\n", b"one\vafter"),
            ("empty", b"", b"\n"),
            ("to-empty", b"before\n", b""),
            ("blank-lines", b"\n\nbefore\n\n", b"\n\nafter\n\n"),
        ]
        path = self.repo / "code.txt"
        for state in ("staged", "worktree"):
            for label, before, after in cases:
                with self.subTest(state=state, case=label):
                    self.git("reset", "--hard", "main")
                    path.write_bytes(before)
                    self.git("commit", "-qam", "physical line fixture")
                    path.write_bytes(after)
                    if state == "staged":
                        self.git("add", "code.txt")
                    snapshot = self.begin("uncommitted")
                    patch = (snapshot.parent / "diff.patch").read_bytes()
                    self.assert_patch_round_trip(path, before, after, patch)
                    if (not before or before.endswith(b"\n")) and (
                        not after or after.endswith(b"\n")
                    ):
                        self.assertNotIn(b"\\ No newline at end of file", patch)

    def test_patch_round_trip_quotes_filename_bytes_for_git(self):
        names = (
            "two\nlines.txt",
            "two\tcolumns.txt",
            'a"quote.txt',
            "a\\backslash.txt",
            "a\rreturn.txt",
            "a\vvertical.txt",
            "a\fform.txt",
            "a\aalert.txt",
            "a\bbackspace.txt",
            "a\x1bescape.txt",
            "a\x7fdelete.txt",
            "caf\u00e9-\u2028-\U0001f9ea.txt",
            " spaces .txt",
        )
        for state in ("staged", "worktree"):
            for name in names:
                with self.subTest(state=state, path=repr(name)):
                    self.git("reset", "--hard", "main")
                    self.git("clean", "-fd")
                    path = self.repo / name
                    path.write_bytes(b"before\n")
                    self.git("add", "--", name)
                    self.git("commit", "-qm", "filename fixture")
                    path.write_bytes(b"after\n")
                    if state == "staged":
                        self.git("add", "--", name)
                    snapshot = self.begin("uncommitted")
                    patch = (snapshot.parent / "diff.patch").read_bytes()
                    self.assert_patch_round_trip(path, b"before\n", b"after\n", patch)

    def test_tier1_cap_counts_lf_physical_lines(self):
        self.git("reset", "--hard", "main")
        path = self.repo / "README.md"
        path.write_bytes(b"one\rbefore\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "documentation base")
        self.git("branch", "-f", "main", "HEAD")
        for scope in ("uncommitted", "committed"):
            with self.subTest(scope=scope):
                path.write_bytes(b"one\rafter\n")
                if scope == "committed":
                    self.git("commit", "-qam", "documentation update")
                snapshot = self.begin(scope)
                patch = (snapshot.parent / "diff.patch").read_bytes()
                count = int(subprocess.check_output(["wc", "-l"], input=patch))
                snapshot = self.begin(scope, tier1_max_lines=str(count))
                self.assertEqual(
                    json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 1
                )
                self.complete(snapshot, "tier-1")
                snapshot = self.begin(scope, tier1_max_lines=str(count - 1))
                self.assertEqual(
                    json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 2
                )
                self.complete(snapshot, "tier-1", ok=False)

    def test_staged_instruction_deletion_blocks(self):
        (self.repo / "AGENTS.md").write_text("instructions\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "instructions")
        self.git("rm", "--cached", "AGENTS.md")
        (self.repo / ".git/info/exclude").write_text("AGENTS.md\n")
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )

    def test_backward_wall_clock_preserves_validity_and_stale_checks(self):
        def at_time(timestamp, *args):
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    """
import runpy, sys
from datetime import datetime
from unittest.mock import patch
fixed = datetime.fromisoformat(sys.argv.pop(1))
sys.argv = sys.argv[1:]
with patch('datetime.datetime', wraps=datetime) as clock:
    clock.now.return_value = fixed
    runpy.run_path(sys.argv[0], run_name='__main__')
""",
                    timestamp,
                    str(HELPER),
                    *args,
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout.strip()

        started = "2026-09-09T12:00:00.500000+00:00"
        completed = "2026-09-09T12:00:00.067000+00:00"
        snapshot = (
            Path(
                at_time(
                    started,
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                )
            )
            / "snapshot.json"
        )
        at_time(
            completed,
            "complete",
            "--snapshot",
            str(snapshot),
            "--outcome",
            "passed",
            "--output",
            str(self.result),
        )
        receipt_path = self.repo / ".git/review-receipts/codex.json"
        original = receipt_path.read_text()
        receipt = json.loads(original)
        self.assertEqual(receipt["started_at"], started)
        self.assertEqual(receipt["completion"]["completed_at"], completed)
        self.check()
        code = self.repo / "code.txt"
        code.write_text("unreviewed work\n")
        self.check(False)
        code.write_text("changed\n")
        self.check()
        self.begin()
        receipt_path.write_text(original)
        self.check(False)

    def test_timestamp_format_and_timezone_remain_required(self):
        self.complete(self.begin())
        path = self.repo / ".git/review-receipts/codex.json"
        original = path.read_text()
        for field in ("started_at", "completed_at"):
            for invalid in ("invalid", "2026-09-09T12:00:00", None, 42):
                with self.subTest(field=field, invalid=invalid):
                    record = json.loads(original)
                    container = record if field == "started_at" else record["completion"]
                    container[field] = invalid
                    path.write_text(json.dumps(record))
                    self.check(False)

    def test_missing_completion_timestamp_is_malformed(self):
        self.complete(self.begin())
        path = self.repo / ".git/review-receipts/codex.json"
        record = json.loads(path.read_text())
        del record["completion"]["completed_at"]
        path.write_text(json.dumps(record))
        self.check(False)

    def test_real_docs_and_filtered_exemptions_can_ship(self):
        self.git("checkout", "-B", "feature", "main")
        for filename, outcome in (
            ("README.md", "tier-1"),
            ("LICENSE", "tier-1"),
            ("LICENSE.txt", "tier-1"),
            ("LICENSE.md", "tier-1"),
            ("image.png", "no-diff"),
            ("package-lock.json", "no-diff"),
        ):
            with self.subTest(filename=filename):
                self.git("checkout", "-B", "feature", "main")
                (self.repo / filename).write_text("fixture\n")
                self.git("add", filename)
                self.git("commit", "-qm", "exempt artifact")
                self.complete(self.begin(), outcome)
                self.check()

    def assert_full_review(self, snapshot, marker, scope, base):
        self.assertIn(marker, (snapshot.parent / "diff.patch").read_text())
        self.assertEqual(
            json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 2
        )
        self.complete(snapshot, "no-diff", ok=False)
        self.complete(snapshot, "tier-1", ok=False)
        self.complete(snapshot)
        if scope == "committed":
            self.check(True, "--base", base)

    def test_risk_paths_precede_passive_filename_exclusions(self):
        for name in (
            ".codex/policy.lock",
            ".claude/hooks/check.lock",
            ".github/workflows/check.map",
            "scripts/check.min.css",
            "schema.lock",
        ):
            for scope in ("committed", "uncommitted"):
                with self.subTest(path=name, scope=scope):
                    self.git("reset", "--hard", "main")
                    self.git("clean", "-fd")
                    path = self.repo / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("RISK_PATH_MARKER\n")
                    if scope == "committed":
                        self.git("add", name)
                        self.git("commit", "-qm", "risk with passive filename")
                    self.assert_full_review(self.begin(scope), "RISK_PATH_MARKER", scope, "main")

    def test_code_named_license_does_not_get_docs_exemption(self):
        for executable in (False, True):
            for scope in ("committed", "uncommitted"):
                with self.subTest(executable=executable, scope=scope):
                    self.git("reset", "--hard", "main")
                    self.git("clean", "-fd")
                    path = self.repo / "LICENSE.py"
                    path.write_text('print("LICENSE_CODE_MARKER")\n')
                    path.chmod(0o755 if executable else 0o644)
                    if scope == "committed":
                        self.git("add", "LICENSE.py")
                        self.git("commit", "-qm", "code with license filename")
                    self.assert_full_review(self.begin(scope), "LICENSE_CODE_MARKER", scope, "main")

    def test_passive_and_docs_exemptions_check_both_file_modes(self):
        transitions = (
            ("missing", "exec"),
            ("plain", "exec"),
            ("exec", "plain"),
            ("exec", "missing"),
            ("missing", "link"),
            ("plain", "link"),
            ("link", "plain"),
            ("link", "missing"),
        )
        for name in ("image.png", "README.md"):
            for before, after in transitions:
                for scope in ("committed", "uncommitted"):
                    with self.subTest(path=name, before=before, after=after, scope=scope):
                        self.git("reset", "--hard", "main")
                        self.git("clean", "-fd")
                        path = self.repo / name

                        def materialize(kind, path=path):
                            path.unlink(missing_ok=True)
                            if kind == "link":
                                path.symlink_to("MODE_REVIEW_MARKER")
                            elif kind != "missing":
                                path.write_text("MODE_REVIEW_MARKER\n")
                                path.chmod(0o755 if kind == "exec" else 0o644)

                        materialize(before)
                        if before != "missing":
                            self.git("add", name)
                            self.git("commit", "-qm", "mode before")
                        base = self.git("rev-parse", "HEAD")
                        materialize(after)
                        if scope == "committed":
                            self.git("add", name)
                            self.git("commit", "-qm", "mode after")
                        snapshot = self.begin(scope, base)
                        # Pure executable-bit changes carry modes without a content hunk.
                        marker = (
                            name
                            if (before, after) in (("plain", "exec"), ("exec", "plain"))
                            else "MODE_REVIEW_MARKER"
                        )
                        self.assert_full_review(snapshot, marker, scope, base)

    def test_filtered_paths_are_literal_even_with_glob_characters(self):
        for scope in ("committed", "uncommitted"):
            with self.subTest(scope=scope):
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                active = self.repo / "active[1].lock"
                active.write_text("ACTIVE_LITERAL_MARKER\n")
                active.chmod(0o755)
                (self.repo / "active1.lock").write_text("PASSIVE_LITERAL_MARKER\n")
                if scope == "committed":
                    self.git("add", "active[1].lock", "active1.lock")
                    self.git("commit", "-qm", "literal filename selection")
                snapshot = self.begin(scope)
                patch = (snapshot.parent / "diff.patch").read_text()
                self.assertIn("ACTIVE_LITERAL_MARKER", patch)
                self.assertNotIn("PASSIVE_LITERAL_MARKER", patch)
                self.complete(snapshot)

    def test_tier1_receipt_uses_captured_configured_limit(self):
        self.git("checkout", "-B", "feature", "main")
        (self.repo / "notes.md").write_text("documentation\n" * 250)
        self.git("add", "notes.md")
        self.git("commit", "-qm", "larger documentation change")
        self.complete(self.begin(), "tier-1", ok=False)
        snapshot = self.begin(tier1_max_lines="0500")
        self.assertEqual(json.loads(snapshot.read_text())["policy"]["tier1_max_lines"], "0500")
        self.assertEqual(
            json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 1
        )
        self.complete(snapshot, "tier-1")
        self.check()
        receipt_path = self.repo / ".git/review-receipts/codex.json"
        record = json.loads(receipt_path.read_text())
        for limit in ("200", "invalid", None, [], 500):
            with self.subTest(limit=limit):
                record["policy"]["tier1_max_lines"] = limit
                receipt_path.write_text(json.dumps(record))
                self.check(False)

    def test_invalid_tier1_limit_requires_full_review(self):
        self.git("checkout", "-B", "feature", "main")
        (self.repo / "notes.md").write_text("documentation\n")
        self.git("add", "notes.md")
        self.git("commit", "-qm", "documentation change")
        snapshot = self.begin(tier1_max_lines="invalid")
        self.assertEqual(
            json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 2
        )
        self.complete(snapshot, "tier-1", ok=False)
        self.complete(snapshot)
        self.check()

    def test_classification_and_exemption_share_instruction_policy(self):
        for name in (
            ".claude/commands/check.md",
            ".gemini/agents/check.md",
            "nested/.agents/check.md",
        ):
            with self.subTest(path=name):
                self.git("checkout", "-B", "feature", "main")
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("instruction fixture\n")
                self.git("add", name)
                self.git("commit", "-qm", "instruction change")
                snapshot = self.begin()
                classification = json.loads(
                    self.run_helper("classify", "--snapshot", str(snapshot))
                )
                self.assertEqual(classification["tier"], 2)
                self.assertIsInstance(classification["reason"], str)
                self.complete(snapshot, "tier-1", ok=False)
                self.complete(snapshot)
                self.check()

    def test_source_instruction_layouts_require_review_and_reject_dirty_inputs(self):
        for name in (
            "agents/skills/orchestrate/references/runtime-contracts.md",
            "agents/canon/fragments/shared.md",
            "claude/skills/example/reference.md",
            "claude/agents/reviewer.md",
            "claude/AgentPack.md",
            "claude/AGENTPACK.yaml",
            "claude/agentpack-meta.json",
            "nested/agents/skills/example/references/policy.lock",
            "agents",
            "claude",
            "claude/scripts",
            "claude/scripts/codex-review-schema.json",
        ):
            with self.subTest(path=name):
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("SOURCE_INSTRUCTION_MARKER\n")
                self.git("add", name)
                self.git("commit", "-qm", "source instruction")
                self.assert_full_review(
                    self.begin(), "SOURCE_INSTRUCTION_MARKER", "committed", "main"
                )
                path.write_text("DIRTY_SOURCE_INSTRUCTION_MARKER\n")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )

    def test_dirty_instruction_ancestor_links_cannot_hide_outside_committed_delta(self):
        for name in ("agents", "claude", "claude/scripts"):
            with self.subTest(path=name):
                self.git("reset", "--hard", "main")
                self.git("clean", "-fd")
                link = self.repo / name
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(Path(self.tmp.name) / "before", target_is_directory=True)
                self.git("add", name)
                self.git("commit", "-qm", "installed source link")
                self.git("branch", "-f", "baseline", "HEAD")
                (self.repo / "code.txt").write_text("benign committed change\n")
                self.git("commit", "-qam", "benign change")
                link.unlink()
                link.symlink_to(Path(self.tmp.name) / "after", target_is_directory=True)
                self.assertEqual(self.git("diff", "--name-only", "baseline", "HEAD"), "code.txt")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "baseline",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                    ok=False,
                )

    def test_ignored_source_skill_reference_changes_invalidate_review(self):
        name = "agents/skills/orchestrate/references/runtime-contracts.md"
        skill = self.repo / "agents/skills/orchestrate/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("Read references/runtime-contracts.md for runtime policy.\n")
        self.git("add", "agents/skills/orchestrate/SKILL.md")
        self.git("commit", "-qm", "existing skill")
        (self.repo / ".git/info/exclude").write_text(name + "\n")
        self.complete(self.begin())
        self.check()
        reference = self.repo / name
        reference.parent.mkdir()
        reference.write_text("IGNORED_SOURCE_REFERENCE_MARKER\n")
        self.check(False)
        self.run_helper(
            "begin",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )
        snapshot = self.begin("uncommitted")
        self.assertIn(
            "IGNORED_SOURCE_REFERENCE_MARKER", (snapshot.parent / "diff.patch").read_text()
        )
        reference.write_text("MUTATED_SOURCE_REFERENCE_MARKER\n")
        self.complete(snapshot, ok=False)
        snapshot = self.begin("uncommitted")
        self.complete(snapshot)
        reference.write_text("MUTATED_AGAIN_MARKER\n")
        self.run_helper("verify", "--snapshot", str(snapshot), ok=False)

    def test_source_instruction_credentials_remain_private(self):
        for name in (
            "agents/skills/example/auth.json",
            "agents/canon/credentials.json",
            "claude/skills/example/.credentials.json",
            "claude/agents/oauth_creds.json",
        ):
            with self.subTest(path=name):
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                (self.repo / ".git/info/exclude").write_text(name + "\n")
                path.write_text("SYNTHETIC_SOURCE_CREDENTIAL_MARKER\n")
                snapshot = self.begin()
                path.write_text("MUTATED_SOURCE_CREDENTIAL_MARKER\n")
                self.complete(snapshot)
                self.check()
                (self.repo / ".git/info/exclude").write_text("")
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "main",
                    "--scope",
                    "uncommitted",
                    "--reviewer",
                    "codex",
                    ok=False,
                )
                for patch in (self.repo / ".git/review-receipts").glob("run-*/diff.patch"):
                    self.assertNotIn(b"SOURCE_CREDENTIAL_MARKER", patch.read_bytes())
                path.unlink()

    def test_unrelated_source_documentation_keeps_docs_exemption(self):
        for name in ("agents/README.md", "claude/chrome/README.md", "docs/agents/skills-guide.md"):
            with self.subTest(path=name):
                self.git("reset", "--hard", "main")
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("ordinary documentation\n")
                self.git("add", name)
                self.git("commit", "-qm", "documentation")
                self.complete(self.begin(), "tier-1")
                self.check()

    def test_arbitrary_head_base_cannot_launder_shipping(self):
        snapshot = (
            Path(
                self.run_helper(
                    "begin",
                    "--repo",
                    str(self.repo),
                    "--base",
                    "HEAD",
                    "--scope",
                    "committed",
                    "--reviewer",
                    "codex",
                )
            )
            / "snapshot.json"
        )
        self.complete(snapshot, "no-diff")
        self.check(False)
        self.check(True, "--base", "HEAD")

    def test_superseded_concurrent_run_cannot_restore_approval(self):
        first = self.begin()
        second = self.begin()
        self.complete(first, ok=False)
        self.complete(second)
        self.check()
        self.run_helper("invalidate", "--repo", str(self.repo), "--reviewer", "codex")
        self.complete(second, ok=False)

    def test_failed_new_run_invalidates_prior_lane_receipt(self):
        self.complete(self.begin())
        self.check()
        self.begin()
        self.check(False)

    # ─── ADR-0008: lane routing ────────────────────────────────────
    # `lane` is the read-only classifier both bash gates and review-and-push.sh
    # consult before choosing a reviewer, and the receipt's stored classification
    # is what makes `check` refuse a lane too weak for the diff.

    def lane(self, scope="committed", base="main", tier1_max_lines=None):
        policy = ("--tier1-max-lines=" + tier1_max_lines,) if tier1_max_lines is not None else ()
        return json.loads(
            self.run_helper(
                "lane", "--repo", str(self.repo), "--base", base, "--scope", scope, *policy
            )
        )

    def check_refusal(self, *args):
        """Run `check` expecting a refusal; return its combined output.

        run_helper returns stdout only, and every refusal reason is written to
        stderr, so a lane or classification rejection has to be read here.
        """
        process = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "check",
                "--repo",
                str(self.repo),
                "--head",
                self.git("rev-parse", "HEAD"),
                *args,
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
        return process.stdout + process.stderr

    def receipts_dir(self):
        return Path(self.git("rev-parse", "--absolute-git-dir")) / "review-receipts"

    def commit_paths(self, *paths, message="lane fixture"):
        for path in paths:
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("lane routing fixture\n")
            self.git("add", "--", path)
        self.git("commit", "-qm", message)

    def test_lane_reports_required_lane_and_mints_nothing(self):
        # code.txt (from setUp) is ordinary work: tier 2, no risk surface.
        self.assertFalse(self.receipts_dir().exists())
        ordinary = self.lane()
        self.assertEqual(ordinary["tier"], 2)
        self.assertEqual(ordinary["required_lane"], "antigravity")
        self.assertEqual(ordinary["risk_paths"], [])
        self.assertIsInstance(ordinary["reason"], str)
        # A read-only classifier must not provision the receipt layout.
        self.assertFalse(self.receipts_dir().exists())

        self.git("reset", "--hard", "main")
        self.commit_paths("notes.md")
        docs = self.lane()
        self.assertEqual(docs["tier"], 1)
        self.assertEqual(docs["required_lane"], "any")

        self.git("reset", "--hard", "main")
        self.commit_paths("token.txt")
        risky = self.lane()
        self.assertEqual(risky["tier"], 2)
        self.assertEqual(risky["required_lane"], "codex")
        self.assertEqual(risky["risk_paths"], ["token.txt"])

        self.git("reset", "--hard", "main")
        self.commit_paths("claude/scripts/tool.sh")
        self.assertEqual(self.lane()["required_lane"], "codex")
        self.assertFalse(self.receipts_dir().exists())

    def test_oversize_ordinary_diff_still_routes_to_antigravity(self):
        # Above the tier-1 cap the diff is tier 2, but size alone is not risk:
        # the point of the lane split is that ordinary bulk goes to Gemini.
        self.git("reset", "--hard", "main")
        (self.repo / "bulk.txt").write_text("".join(f"line {n}\n" for n in range(50)))
        self.git("add", "bulk.txt")
        self.git("commit", "-qm", "bulk")
        classification = self.lane(tier1_max_lines="5")
        self.assertEqual(classification["tier"], 2)
        self.assertEqual(classification["required_lane"], "antigravity")

    def test_antigravity_receipt_cannot_ship_a_codex_required_diff(self):
        self.git("reset", "--hard", "main")
        self.commit_paths("token.txt")
        self.complete(self.begin(reviewer="antigravity"))
        # pre-push calls `check` with no --reviewer; the fail-open this closes is
        # exactly that path accepting the first valid receipt of either lane.
        for args in ((), ("--reviewer", "antigravity")):
            with self.subTest(args=args):
                self.assertIn("receipt lane below required lane", self.check_refusal(*args))
        self.complete(self.begin(reviewer="codex"))
        self.check()
        self.check(True, "--reviewer", "codex")

    def test_antigravity_receipt_ships_an_ordinary_diff(self):
        self.complete(self.begin(reviewer="antigravity"))
        self.assertIn("required lane: antigravity", self.check())
        self.assertIn("required lane: antigravity", self.check(True, "--reviewer", "antigravity"))

    def test_any_lane_ships_a_tier_one_docs_diff(self):
        self.git("reset", "--hard", "main")
        self.commit_paths("notes.md")
        self.complete(self.begin(reviewer="antigravity"), "tier-1")
        self.assertIn("required lane: any", self.check())

    def test_tampered_classification_is_rejected(self):
        self.complete(self.begin(reviewer="antigravity"))
        receipt = self.receipts_dir() / "antigravity.json"
        record = json.loads(receipt.read_bytes())
        for field, value in (
            ("required_lane", "any"),
            ("tier", 1),
            ("risk_paths", ["invented.txt"]),
            ("reason", "rewritten"),
        ):
            with self.subTest(field=field):
                tampered = json.loads(json.dumps(record))
                tampered["classification"][field] = value
                receipt.write_text(json.dumps(tampered))
                self.assertIn("classification", self.check_refusal())
        receipt.write_text(json.dumps(record))
        self.check()

    def test_tampered_classification_cannot_downgrade_a_codex_required_diff(self):
        self.git("reset", "--hard", "main")
        self.commit_paths("token.txt")
        self.complete(self.begin(reviewer="antigravity"))
        receipt = self.receipts_dir() / "antigravity.json"
        record = json.loads(receipt.read_bytes())
        record["classification"]["required_lane"] = "antigravity"
        record["classification"]["risk_paths"] = []
        receipt.write_text(json.dumps(record))
        self.check(False)

    def test_version_one_receipt_is_rejected(self):
        self.complete(self.begin(reviewer="antigravity"))
        receipt = self.receipts_dir() / "antigravity.json"
        record = json.loads(receipt.read_bytes())
        self.assertEqual(record["version"], 2)
        record["version"] = 1
        record.pop("classification")
        receipt.write_text(json.dumps(record))
        self.check(False)

    def test_completions_land_in_an_append_only_ledger(self):
        self.complete(self.begin(reviewer="antigravity"))
        ledger = self.receipts_dir() / "ledger.jsonl"
        self.assertEqual(stat.S_IMODE(ledger.stat().st_mode), 0o600)
        entry = json.loads(ledger.read_text().splitlines()[-1])
        self.assertEqual(entry["lane"], "antigravity")
        self.assertEqual(entry["outcome"], "passed")
        self.assertEqual(entry["tier"], 2)
        self.assertEqual(entry["required_lane"], "antigravity")
        self.assertEqual(entry["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(entry["note"], "")
        # `check` must never consult the ledger: an unreadable one cannot block
        # a push, and a forged one cannot approve it.
        ledger.write_text("not json at all\n")
        self.check()

    def test_ledger_notes_a_degraded_antigravity_fallback_in_stats(self):
        self.git("reset", "--hard", "main")
        self.commit_paths("token.txt")
        self.run_helper(
            "complete",
            "--snapshot",
            str(self.begin(reviewer="codex")),
            "--outcome",
            "passed",
            "--output",
            str(self.result),
            "--note",
            "antigravity-degraded(exit 3): agy CLI not found on PATH",
        )
        self.complete(self.begin(reviewer="antigravity"))
        report = self.run_helper("stats", "--repo", str(self.repo))
        self.assertIn("codex", report)
        self.assertIn("antigravity", report)
        self.assertIn("antigravity degraded → codex: 1", report)
        # A window that excludes today's entries reports none of them.
        self.assertIn(
            "antigravity degraded → codex: 0",
            self.run_helper("stats", "--repo", str(self.repo), "--since-days", "0"),
        )

    def test_stats_survives_a_corrupt_ledger(self):
        self.complete(self.begin(reviewer="antigravity"))
        ledger = self.receipts_dir() / "ledger.jsonl"
        with ledger.open("a") as stream:
            stream.write('{"completed_at":"nonsense"}\n{\n\n')
        report = self.run_helper("stats", "--repo", str(self.repo))
        self.assertIn("unreadable ledger lines: 2", report)


if __name__ == "__main__":
    unittest.main()
