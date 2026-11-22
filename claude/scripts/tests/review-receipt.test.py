#!/usr/bin/env python3
"""Receipt fixtures exercise real Git objects without invoking a reviewer."""

import argparse
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
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

    @staticmethod
    def _is_clean_worktree_cmd(args):
        return bool((args and args[0] == "materialize") or "--receipt-repo" in args)

    @staticmethod
    def _env_without_ceiling(**overrides):
        env = dict(os.environ)
        env.pop("GIT_CEILING_DIRECTORIES", None)
        env.update(overrides)
        return env

    def run_helper(self, *args, ok=True):
        p = subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True,
            text=True,
            env=self._env_without_ceiling() if self._is_clean_worktree_cmd(args) else None,
        )
        self.assertEqual(p.returncode == 0, ok, p.stdout + p.stderr)
        return p.stdout.strip()

    def begin(
        self,
        scope="committed",
        base="main",
        tier1_max_lines=None,
        reviewer="codex",
        tier1_max_bytes=None,
    ):
        policy = ("--tier1-max-lines=" + tier1_max_lines,) if tier1_max_lines is not None else ()
        if tier1_max_bytes is not None:
            policy += ("--tier1-max-bytes=" + tier1_max_bytes,)
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

    def capture(self, reviewer="codex", scope="committed", base="main", ok=True):
        """`capture` alone: opens this lane's attempt and touches no other lane (#499)."""
        out = self.run_helper(
            "capture",
            "--repo",
            str(self.repo),
            "--base",
            base,
            "--scope",
            scope,
            "--reviewer",
            reviewer,
            ok=ok,
        )
        return Path(out) / "snapshot.json" if ok else None

    def claim(self, snapshot, ok=True):
        return self.run_helper("claim", "--snapshot", str(snapshot), ok=ok)

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
                if change == "base":
                    # The base is pinned at capture (#680): completing still
                    # works, and the push check refuses the absorbed branch.
                    self.complete(snapshot)
                    self.check(False)
                    continue
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

    def test_ignored_fabricated_boundary_cannot_hide_an_instruction_file(self):
        """#496: an IGNORED boundary was dropped whenever its own path was innocent.

        `vendor/nested/` is not an instruction path, so the entry never reached the
        fail-closed snapshot at all and `vendor/nested/CLAUDE.md` was never seen —
        the receipt then claimed a clean instruction surface that it had not
        checked. A fabricated `.git` (HEAD, objects, refs; no `git init`) is all it
        takes for git to stop there.
        """
        (self.repo / ".git/info/exclude").write_text("vendor/\n")
        boundary = self.repo / "vendor/nested"

        def fabricate():
            (boundary / ".git/objects").mkdir(parents=True)
            (boundary / ".git/refs").mkdir()
            (boundary / ".git/HEAD").write_text("ref: refs/heads/main\n")

        for hidden in ("CLAUDE.md", "AGENTS.md", "SKILL.md", "docs/CLAUDE.md"):
            with self.subTest(hidden=hidden):
                fabricate()
                target = boundary / hidden
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("EVIL\n")
                self.assertEqual(
                    self.git("ls-files", "--others", "--ignored", "--exclude-standard"),
                    "vendor/nested/",
                )
                self.expect_begin_refused()
                shutil.rmtree(boundary)
        # The boundary's own .gitignore must not decide what this repo's sweep can
        # see, or hiding the file from the inspection would take one line.
        fabricate()
        (boundary / ".gitignore").write_text("CLAUDE.md\n")
        (boundary / "CLAUDE.md").write_text("EVIL\n")
        self.expect_begin_refused()
        shutil.rmtree(boundary)
        # One level only: a boundary behind a boundary is refused, never descended.
        fabricate()
        (boundary / "inner/.git/objects").mkdir(parents=True)
        (boundary / "inner/.git/refs").mkdir()
        (boundary / "inner/.git/HEAD").write_text("ref: refs/heads/main\n")
        (boundary / "inner/CLAUDE.md").write_text("EVIL\n")
        self.expect_begin_refused()
        shutil.rmtree(boundary)
        # A directory git stopped at that is not a usable repository at all cannot
        # be inspected, so it is refused rather than assumed empty.
        boundary.mkdir(parents=True)
        (boundary / ".git").write_text("gitdir: /nonexistent/elsewhere\n")
        (boundary / "CLAUDE.md").write_text("EVIL\n")
        self.expect_begin_refused()
        shutil.rmtree(boundary)
        # Benign vendoring still works: a real repository with no instruction file
        # behind it is inspected and allowed, ignored or not.
        for ignored in (True, False):
            with self.subTest(vendored_repo_ignored=ignored):
                (self.repo / ".git/info/exclude").write_text("vendor/\n" if ignored else "\n")
                boundary.mkdir(parents=True)
                subprocess.check_output(
                    ["git", "init", "-q", "-b", "main", str(boundary)], stderr=subprocess.PIPE
                )
                (boundary / "index.js").write_text("library code\n")
                if ignored:
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
                    )
                else:
                    # A visible boundary is untracked, and untracked boundaries have
                    # always failed closed in file_bytes() — unchanged here.
                    self.expect_begin_refused()
                (boundary / "CLAUDE.md").write_text("EVIL\n")
                self.expect_begin_refused()
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

    def test_gitlink_behind_a_boundary_cannot_hide_an_instruction_file(self):
        """A submodule inside a foreign ignored repository hides its whole tree.

        `ls-files` prints a populated tracked submodule as ONE bare path — no
        trailing slash — and never enumerates what is inside it, so inspecting a
        boundary by its listing alone accepted `vendor/nested/dependency` (not an
        instruction name, not a nested boundary) while `dependency/CLAUDE.md` sat
        underneath, unchecked. Found by the Codex gate on the #496 change.

        The gitlink is planted with `update-index --cacheinfo` rather than
        `submodule add`: same index entry and same working tree, with no transport
        and no `protocol.file.allow` dance.
        """

        def git_in(directory, *args):
            return (
                subprocess.check_output(
                    ["git", "-C", str(directory), *args], stderr=subprocess.PIPE
                )
                .decode()
                .strip()
            )

        (self.repo / ".git/info/exclude").write_text("vendor/\n")
        boundary = self.repo / "vendor/nested"
        for hidden, populated in (("CLAUDE.md", True), ("SKILL.md", True), ("CLAUDE.md", False)):
            with self.subTest(hidden=hidden, populated=populated):
                boundary.mkdir(parents=True)
                git_in(boundary, "init", "-q", "-b", "main")
                git_in(boundary, "config", "user.name", "fixture")
                git_in(boundary, "config", "user.email", "fixture@example.test")
                (boundary / "index.js").write_text("library code\n")
                git_in(boundary, "add", "index.js")
                git_in(boundary, "commit", "-qm", "base")
                head = git_in(boundary, "rev-parse", "HEAD")
                submodule = boundary / "dependency"
                submodule.mkdir()
                if populated:
                    (submodule / hidden).write_text("EVIL\n")
                git_in(
                    boundary,
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "160000," + head + ",dependency",
                )
                # The listing the inspection reads: one bare path, mode 160000,
                # and nothing at all about what the directory holds.
                self.assertIn(
                    "160000 " + head + " 0\tdependency", git_in(boundary, "ls-files", "-s")
                )
                self.assertIn("dependency", git_in(boundary, "ls-files", "--cached", "--others"))
                self.assertNotIn(hidden, git_in(boundary, "ls-files", "--cached", "--others"))
                # A gitlink is unenumerable either way, so an empty one is refused
                # too: the boundary is only accepted when every path behind it was
                # actually inspected.
                for command in ("begin", "lane"):
                    args = ["--repo", str(self.repo), "--base", "main", "--scope", "committed"]
                    if command == "begin":
                        args += ["--reviewer", "codex"]
                    refusal = subprocess.run(
                        [sys.executable, str(HELPER), command, *args],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(refusal.returncode, 2, refusal.stdout + refusal.stderr)
                    self.assertIn("boundary", refusal.stderr)
                shutil.rmtree(boundary)

    def test_a_listed_boundary_path_that_is_a_directory_is_refused(self):
        """The index says blob, the disk says directory: refuse either way.

        Here git itself descends and lists `payload/CLAUDE.md`, so the instruction
        check already refuses; the disk-directory backstop in the inspection covers
        the same shape from the other side, for any listing that disagrees with the
        working tree. This pins the OUTCOME — such a boundary never passes — rather
        than which of the two checks caught it.
        """

        def git_in(directory, *args):
            return (
                subprocess.check_output(
                    ["git", "-C", str(directory), *args], stderr=subprocess.PIPE
                )
                .decode()
                .strip()
            )

        (self.repo / ".git/info/exclude").write_text("vendor/\n")
        boundary = self.repo / "vendor/nested"
        boundary.mkdir(parents=True)
        git_in(boundary, "init", "-q", "-b", "main")
        git_in(boundary, "config", "user.name", "fixture")
        git_in(boundary, "config", "user.email", "fixture@example.test")
        (boundary / "payload").write_text("a blob, as far as the index knows\n")
        git_in(boundary, "add", "payload")
        git_in(boundary, "commit", "-qm", "base")
        (boundary / "payload").unlink()
        (boundary / "payload").mkdir()
        (boundary / "payload/CLAUDE.md").write_text("EVIL\n")
        listing = git_in(boundary, "ls-files", "--cached", "--others")
        self.assertIn("payload", listing)
        self.expect_begin_refused()

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

    def test_tier1_byte_ceiling_escalates_a_byte_huge_docs_diff(self):
        """#494: the tier-1 size ceiling is policy here, not one gate's prompt cap.

        A docs-only diff of a single 200,000-byte line clears the line ceiling,
        so before the byte ceiling existed it took the exemption in whichever
        lane was asked while the Antigravity gate refused to dispatch it at all.
        It now classifies tier 2 in both lanes and is escalated to an ordinary
        review rather than refused.
        """
        self.git("checkout", "-B", "feature", "main")
        (self.repo / "notes.md").write_text("x" * 200000 + "\n")
        self.git("add", "notes.md")
        self.git("commit", "-qm", "one very long documentation line")
        snapshot = self.begin()
        self.assertEqual(json.loads(snapshot.read_text())["policy"]["tier1_max_bytes"], "65536")
        classification = json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))
        self.assertEqual(classification["tier"], 2)
        self.assertIn("bytes", classification["reason"])
        # Escalated to a real review, not refused: an ordinary docs path needs
        # only the Antigravity lane.
        self.assertEqual(classification["required_lane"], "antigravity")
        self.complete(snapshot, "tier-1", ok=False)
        self.complete(snapshot)
        self.check()
        # The ceiling is captured policy like the line ceiling, so raising it
        # restores the exemption for the same artifact.
        snapshot = self.begin(tier1_max_bytes="300000")
        self.assertEqual(
            json.loads(self.run_helper("classify", "--snapshot", str(snapshot)))["tier"], 1
        )
        self.complete(snapshot, "tier-1")
        self.check()

    def test_tier1_byte_policy_is_validated_fail_closed(self):
        """A receipt whose byte ceiling is absent or unusable cannot ship tier 1.

        A receipt minted before this policy field existed carries no ceiling at
        all, which must read as "unclassifiable" (tier 2, Codex) rather than as
        "no limit".
        """
        self.git("checkout", "-B", "feature", "main")
        (self.repo / "notes.md").write_text("documentation\n")
        self.git("add", "notes.md")
        self.git("commit", "-qm", "documentation change")
        self.complete(self.begin(), "tier-1")
        self.check()
        receipt_path = self.repo / ".git/review-receipts/codex.json"
        record = json.loads(receipt_path.read_text())
        for limit in ("invalid", "-1", "", None, [], 65536, "MISSING"):
            with self.subTest(limit=limit):
                mutated = json.loads(json.dumps(record))
                if limit == "MISSING":
                    del mutated["policy"]["tier1_max_bytes"]
                else:
                    mutated["policy"]["tier1_max_bytes"] = limit
                receipt_path.write_text(json.dumps(mutated))
                self.check(False)
        for limit in ("invalid", "-1", ""):
            with self.subTest(begin_limit=limit):
                snapshot = self.begin(tier1_max_bytes=limit)
                classification = json.loads(
                    self.run_helper("classify", "--snapshot", str(snapshot))
                )
                self.assertEqual(classification["tier"], 2)
                self.assertEqual(classification["required_lane"], "codex")
                self.complete(snapshot, "tier-1", ok=False)

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

    def test_failed_new_run_invalidates_a_competing_lane_receipt(self):
        """A review beginning in one lane retires the other lane's approval too.

        Both gates exit 2 on blocking findings WITHOUT recording a receipt, so
        the only trace of a blocked review is the attempt its `begin` opened.
        githooks/pre-push calls `check` with no `--reviewer`, so a surviving
        competing approval would ship the diff the newest verdict rejected.
        """
        for approved, blocked in (("antigravity", "codex"), ("codex", "antigravity")):
            with self.subTest(approved=approved, blocked=blocked):
                self.complete(self.begin(reviewer=approved))
                self.check()
                snapshot = self.begin(reviewer=blocked)
                self.check(False)
                self.check(False, "--reviewer", approved)
                # This closes a bypass, not the lane: the re-run that approves ships.
                self.complete(snapshot)
                self.check()
                self.check(True, "--reviewer", blocked)

    def test_competing_in_flight_review_cannot_record_after_a_newer_begin(self):
        first = self.begin(reviewer="antigravity")
        second = self.begin(reviewer="codex")
        self.complete(first, ok=False)
        self.check(False)
        self.complete(second)
        self.check()

    def hold_attempt_lock(self):
        """Hold the receipt directory's exclusive lock, as a gate mid-transition does.

        Registers the release as cleanup so a failing assertion inside the held
        window cannot wedge the rest of the suite.
        """
        descriptor = os.open(
            self.receipts_dir() / ".lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600
        )
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor

    def test_begin_waits_for_a_concurrent_attempt_transition(self):
        """`begin` must not walk into the middle of another run's transition.

        Retiring the competing lane and opening this lane's attempt are several
        file operations. Two gates beginning at once could interleave them so that
        each retired the other's lane before either wrote its own token, leaving
        BOTH tokens live — and a blocking verdict in one lane bypassable by the
        other's approval all over again. The held lock stands in for the other gate
        being mid-transition, with no pause hook in the shipping code.
        """
        self.complete(self.begin(reviewer="antigravity"))
        descriptor = self.hold_attempt_lock()
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess.run(
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
                timeout=5,
            )
        # Blocked before the transition, so it retired nothing on the way in.
        self.assertTrue((self.receipts_dir() / "antigravity.json").is_file())
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        # After the release: `check` takes the lock for its deciding assertion (#533).
        self.check()
        self.begin(reviewer="codex")
        self.check(False)

    def test_complete_waits_for_a_concurrent_attempt_transition(self):
        """The deciding attempt check and the receipt write are one transition."""
        snapshot = self.begin(reviewer="codex")
        descriptor = self.hold_attempt_lock()
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "complete",
                    "--snapshot",
                    str(snapshot),
                    "--outcome",
                    "passed",
                    "--output",
                    str(self.result),
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )
        self.assertFalse((self.receipts_dir() / "codex.json").exists())
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        self.complete(snapshot)
        self.check()

    def test_interleaved_begins_never_leave_two_live_attempts(self):
        """Two gates beginning at once leave at most one live attempt, never two.

        Both runs are queued behind a held lock so they contend for real rather
        than by luck of scheduling. `begin` is capture then claim (#499), so the
        run whose claim lands second either supersedes the first (it captured
        after the first claimed) or finds its attempt already superseded, refuses,
        and fails closed by retiring the first as well. No loser can record, and
        the approval the two of them retired cannot ship in its place.
        """
        self.complete(self.begin(reviewer="antigravity"))
        receipts = self.receipts_dir()
        descriptor = self.hold_attempt_lock()
        lanes = ("antigravity", "codex")
        running = [
            subprocess.Popen(
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
                    lane_name,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for lane_name in lanes
        ]
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        snapshots = {}
        for lane_name, process in zip(lanes, running):
            out, err = process.communicate(timeout=60)
            if process.returncode == 0:
                snapshots[lane_name] = Path(out.strip()) / "snapshot.json"
            else:
                self.assertIn("superseded", err)
        self.assertTrue(snapshots)
        live = [
            lane_name
            for lane_name in snapshots
            if json.loads((receipts / (lane_name + ".attempt.json")).read_bytes())["attempt"]
            == json.loads(snapshots[lane_name].read_bytes())["attempt"]
        ]
        self.assertLessEqual(len(live), 1, live)
        self.assertFalse((receipts / "antigravity.json").exists())
        for loser in (lane_name for lane_name in snapshots if lane_name not in live):
            self.complete(snapshots[loser], ok=False)
        self.check(False)
        self.complete(snapshots[live[0]] if live else self.begin(reviewer="codex"))
        self.check()

    # ─── #499: capture touches only its own lane; claim retires the rest ───

    def test_capture_leaves_the_other_lane_approval_until_claim(self):
        """A lane that captures and then degrades (exit 3) is not a verdict.

        Capture opens only this lane's attempt; the other lane's approval stays
        valid until this lane claims the artifact, which a gate does only once it
        can reach a verdict. The claim retires it exactly as `begin` used to.
        """
        for approved, other in (("antigravity", "codex"), ("codex", "antigravity")):
            with self.subTest(approved=approved, other=other):
                self.complete(self.begin(reviewer=approved))
                snapshot = self.capture(reviewer=other)
                # Degraded after capture: nothing claimed, the approval ships.
                self.check()
                self.check(True, "--reviewer", approved)
                # Reached a verdict and blocked: the claim is the retirement.
                self.claim(snapshot)
                self.check(False)
                self.check(False, "--reviewer", approved)
                self.complete(snapshot)
                self.check(True, "--reviewer", other)

    def test_capture_still_retires_its_own_lane(self):
        self.complete(self.begin(reviewer="codex"))
        self.capture(reviewer="codex")
        self.check(False)

    def test_complete_refuses_an_unclaimed_capture(self):
        """A gate that skipped `claim` cannot record a receipt beside another lane's."""
        snapshot = self.capture()
        self.complete(snapshot, ok=False)
        self.assertFalse((self.receipts_dir() / "codex.json").exists())
        self.claim(snapshot)
        self.claim(snapshot)  # idempotent: a gate may claim before recording
        self.complete(snapshot)
        self.check()

    def test_claim_refuses_a_superseded_capture(self):
        first = self.capture(reviewer="codex")
        second = self.capture(reviewer="codex")
        self.claim(first, ok=False)
        # The refused claim retired its own lane too (fail closed): rerun.
        self.claim(second, ok=False)
        second = self.capture(reviewer="codex")
        self.claim(second)
        # Another lane's claim supersedes an unclaimed capture here too.
        mine = self.capture(reviewer="antigravity")
        theirs = self.capture(reviewer="codex")
        self.claim(theirs)
        self.claim(mine, ok=False)
        self.complete(mine, ok=False)
        # The refused claim still retired the lane that superseded it (fail closed).
        self.complete(theirs, ok=False)
        self.check(False)

    def test_superseded_blocking_verdict_retires_the_competing_approval(self):
        """Both lanes capture; the first claims and approves; the second blocks.

        The second claim finds itself superseded, but its verdict still has to
        retire the approval, or the pre-push check ships what it rejected.
        """
        for first, second in (("codex", "antigravity"), ("antigravity", "codex")):
            with self.subTest(first=first, second=second):
                approving = self.capture(reviewer=first)
                blocking = self.capture(reviewer=second)
                self.claim(approving)
                self.complete(approving)
                self.check()
                self.claim(blocking, ok=False)
                self.check(False)
                self.check(False, "--reviewer", first)

    def test_superseded_blocking_verdict_retires_a_newer_same_lane_approval(self):
        """Two runs in ONE lane: the newer approves, then the older one blocks."""
        for lane in ("codex", "antigravity"):
            with self.subTest(lane=lane):
                older = self.capture(reviewer=lane)
                newer = self.capture(reviewer=lane)
                self.claim(newer)
                self.complete(newer)
                self.check()
                self.claim(older, ok=False)
                self.check(False)
                self.check(False, "--reviewer", lane)

    def test_claim_waits_for_a_concurrent_attempt_transition(self):
        self.complete(self.begin(reviewer="antigravity"))
        snapshot = self.capture(reviewer="codex")
        descriptor = self.hold_attempt_lock()
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess.run(
                [sys.executable, str(HELPER), "claim", "--snapshot", str(snapshot)],
                capture_output=True,
                text=True,
                timeout=5,
            )
        self.assertTrue((self.receipts_dir() / "antigravity.json").is_file())
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        self.claim(snapshot)
        self.check(False)

    def test_interleaved_claims_admit_exactly_one(self):
        """Two captured lanes claiming at once: the later claim is superseded and retires both."""
        self.complete(self.begin(reviewer="antigravity"))
        snapshots = {lane: self.capture(reviewer=lane) for lane in ("antigravity", "codex")}
        descriptor = self.hold_attempt_lock()
        running = {
            lane: subprocess.Popen(
                [sys.executable, str(HELPER), "claim", "--snapshot", str(snapshot)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for lane, snapshot in snapshots.items()
        }
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        winners = []
        for lane, process in running.items():
            process.communicate(timeout=60)
            if process.returncode == 0:
                winners.append(lane)
        self.assertEqual(len(winners), 1, winners)
        loser = next(lane for lane in snapshots if lane not in winners)
        self.complete(snapshots[loser], ok=False)
        self.check(False)
        # The loser's refused claim retired the winner too (fail closed): a rerun ships.
        self.complete(snapshots[winners[0]], ok=False)
        self.check(False)
        rerun = self.begin(reviewer=winners[0])
        self.complete(rerun)
        self.check()

    # ─── #533: check's deciding validation is synchronized with claim ───

    def test_check_refuses_when_a_claim_lands_after_its_validation(self):
        """A claim landing between check's validation and its return must refuse.

        In-process, so the seam can run a real `claim` (a separate process, under
        the real lock) after the lock-free validation and before the decision.
        """
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.complete(self.begin(reviewer="codex"))
        rival = self.capture(reviewer="antigravity")
        real = module.classify_tier
        calls = []

        def classify_then_claim(*args, **kwargs):
            result = real(*args, **kwargs)
            if not calls:
                calls.append(True)
                self.claim(rival)
            return result

        args = argparse.Namespace(
            repo=str(self.repo), head=self.git("rev-parse", "HEAD"), base="main", reviewer=None
        )
        printed = io.StringIO()
        with mock.patch.object(module, "classify_tier", classify_then_claim):
            with self.assertRaises(ValueError) as refused, contextlib.redirect_stdout(printed):
                module.check(args)
        self.assertTrue(calls)
        self.assertIn("superseded", str(refused.exception))
        self.assertNotIn("Valid", printed.getvalue())

    # ─── #573: a blocking verdict is a durable per-artifact marker ───

    def block(self, snapshot, ok=True):
        return self.run_helper("block", "--snapshot", str(snapshot), ok=ok)

    def block_markers(self):
        return sorted((self.receipts_dir() / "blocks").glob("*.json"))

    def test_block_refuses_an_approval_captured_before_it(self):
        """Any lane's blocking verdict retires every receipt captured before it."""
        for approved, blocking in (("codex", "antigravity"), ("antigravity", "codex")):
            with self.subTest(approved=approved, blocking=blocking):
                self.complete(self.begin(reviewer=approved))
                self.check()
                # Captured but never claimed: the marker needs no claim.
                self.block(self.capture(reviewer=blocking))
                self.check(False)
                self.check(False, "--reviewer", approved)
                # A review captured after the verdict ships as before.
                self.complete(self.begin(reviewer=approved))
                self.check()

    def test_block_needs_no_live_attempt(self):
        """A superseded attempt's blocking verdict still records the marker."""
        self.complete(self.begin(reviewer="codex"))
        self.check()
        stale = self.capture(reviewer="antigravity")
        self.capture(reviewer="antigravity")  # supersedes `stale` in its own lane
        self.block(stale)
        self.check(False)

    def test_block_refuses_an_in_flight_approval_that_completes_after_it(self):
        """A review captured before the verdict cannot record a receipt after it."""
        approving = self.begin(reviewer="codex")
        self.block(self.capture(reviewer="antigravity"))
        self.complete(approving, ok=False)
        self.assertFalse((self.receipts_dir() / "codex.json").exists())
        self.check(False)

    def test_block_is_per_artifact(self):
        """A marker binds base, head, scope and patch; another artifact ships."""
        self.block(self.capture(reviewer="codex"))
        (self.repo / "code.txt").write_text("fixed\n")
        self.git("commit", "-qam", "fix")
        self.complete(self.begin(reviewer="codex"))
        self.check()
        # The same head reviewed in another scope blocks nothing committed.
        (self.repo / "code.txt").write_text("fixed, dirty\n")
        self.block(self.capture(reviewer="codex", scope="uncommitted"))
        self.git("checkout", "--", "code.txt")
        self.complete(self.begin(reviewer="codex"))
        self.check()
        self.assertEqual(len(self.block_markers()), 2)

    def test_block_marker_is_stamped_with_the_verdict(self):
        snapshot = self.capture(reviewer="antigravity")
        self.block(snapshot)
        (marker,) = self.block_markers()
        record = json.loads(marker.read_text())
        artifact = json.loads(snapshot.read_text())["artifact"]
        self.assertEqual(
            record["artifact"],
            {
                "merge_base": artifact["base"]["merge_base"],
                "head": artifact["head"],
                "scope": "committed",
                "patch_sha256": artifact["review_diff_sha256"],
            },
        )
        self.assertEqual(record["reviewer"], "antigravity")
        self.assertIsInstance(record["sequence"], int)
        self.assertIn("+00:00", record["blocked_at"])
        self.assertEqual(stat.S_IMODE(marker.parent.stat().st_mode), 0o700)

    def test_ordering_does_not_trust_the_wall_clock(self):
        """A clock stepped backward cannot make a pre-verdict capture look newer."""
        approving = self.begin(reviewer="codex")
        self.complete(approving)
        self.block(self.capture(reviewer="antigravity"))
        (marker,) = self.block_markers()
        record = json.loads(marker.read_text())
        record["blocked_at"] = "1970-01-01T00:00:00+00:00"
        marker.write_text(json.dumps(record))
        self.check(False)

    def test_a_lost_counter_resumes_above_existing_evidence(self):
        """Deleting sequence.json must not let a verdict sort before older captures."""
        for _ in range(4):
            self.capture(reviewer="codex")
        self.complete(self.begin(reviewer="codex"))
        (self.receipts_dir() / "sequence.json").unlink()
        self.block(self.capture(reviewer="antigravity"))
        self.check(False)

    def test_a_lost_counter_still_orders_a_verdict_after_its_own_capture(self):
        """Recovery counts in-flight snapshots too (Codex round 2)."""
        for _ in range(4):
            self.capture(reviewer="codex")
        approval = self.begin(reviewer="codex")
        self.complete(approval)
        receipt = (self.receipts_dir() / "codex.json").read_bytes()
        attempt = (self.receipts_dir() / "codex.attempt.json").read_bytes()
        blocking = self.capture(reviewer="antigravity")
        # Both lanes invalidated: no receipt or attempt carries a sequence now.
        self.run_helper("invalidate", "--repo", str(self.repo), "--reviewer", "codex")
        self.run_helper("invalidate", "--repo", str(self.repo), "--reviewer", "antigravity")
        (self.receipts_dir() / "sequence.json").unlink()
        self.block(blocking)
        (self.receipts_dir() / "codex.json").write_bytes(receipt)
        (self.receipts_dir() / "codex.attempt.json").write_bytes(attempt)
        self.check(False)

    def test_a_corrupt_or_rolled_back_counter_cannot_reorder_a_verdict(self):
        for corrupt in ('{"sequence":"broken"}', '{"sequence":1}', "not json"):
            with self.subTest(corrupt=corrupt):
                for _ in range(3):
                    self.capture(reviewer="codex")
                self.complete(self.begin(reviewer="codex"))
                blocking = self.capture(reviewer="antigravity")
                (self.receipts_dir() / "sequence.json").write_text(corrupt)
                self.block(blocking)
                self.check(False)
                shutil.rmtree(self.receipts_dir() / "blocks")

    def test_a_marker_with_a_non_positive_sequence_fails_closed(self):
        self.complete(self.begin(reviewer="codex"))
        self.block(self.capture(reviewer="antigravity"))
        self.complete(self.begin(reviewer="codex"))
        self.check()
        (marker,) = self.block_markers()
        record = json.loads(marker.read_text())
        for value in (-1, 0, True):
            with self.subTest(value=value):
                record["sequence"] = value
                marker.write_text(json.dumps(record))
                self.check(False)

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_an_unsearchable_marker_store_fails_closed(self):
        """A marker that cannot be looked up is not an absent marker (Codex round 3)."""
        approving = self.begin(reviewer="codex")
        self.block(self.capture(reviewer="antigravity"))
        blocks = self.receipts_dir() / "blocks"
        blocks.chmod(0o600)
        self.addCleanup(blocks.chmod, 0o700)
        self.complete(approving, ok=False)
        self.assertFalse((self.receipts_dir() / "codex.json").exists())

    def test_a_non_directory_marker_store_fails_closed(self):
        self.complete(self.begin(reviewer="codex"))
        (self.receipts_dir() / "blocks").write_text("not a directory\n")
        self.check(False)

    def test_an_edited_capture_sequence_is_refused(self):
        """The sequence is bound to the live attempt: raising it cannot outrank a marker."""
        self.complete(self.begin(reviewer="codex"))
        receipt = self.receipts_dir() / "codex.json"
        record = json.loads(receipt.read_text())
        record["captured_sequence"] += 1000
        receipt.write_text(json.dumps(record))
        self.check(False)

    def test_malformed_block_marker_fails_closed(self):
        self.complete(self.begin(reviewer="codex"))
        self.block(self.capture(reviewer="antigravity"))
        (marker,) = self.block_markers()
        for content in ("not json", '{"sequence": "9"}', "[]"):
            with self.subTest(content=content):
                marker.write_text(content)
                self.check(False)
        marker.unlink()
        marker.symlink_to(self.result)
        self.check(False)

    def test_receipt_without_a_capture_sequence_is_refused_under_a_marker(self):
        """A receipt from before #573 carries no sequence; a marker outranks it."""
        snapshot = self.begin(reviewer="codex")
        self.complete(snapshot)
        receipt = self.receipts_dir() / "codex.json"
        record = json.loads(receipt.read_text())
        del record["captured_sequence"]
        receipt.write_text(json.dumps(record))
        attempt = self.receipts_dir() / "codex.attempt.json"
        marker = json.loads(attempt.read_text())
        del marker["sequence"]
        attempt.write_text(json.dumps(marker))
        # With no marker, such a receipt still ships as before.
        self.check()
        self.block(self.capture(reviewer="antigravity"))
        self.check(False)

    def test_block_refuses_a_symlinked_marker_directory(self):
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        snapshot = self.capture(reviewer="codex")
        (self.receipts_dir() / "blocks").symlink_to(elsewhere)
        self.block(snapshot, ok=False)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def retain(self, snapshot, output, ok=True):
        return self.run_helper(
            "retain", "--snapshot", str(snapshot), "--output", str(output), ok=ok
        )

    def test_retain_keeps_the_output_bytes(self):
        """The record is the reviewer's output exactly, bytes no text decoder accepts included (#788)."""
        output = Path(self.tmp.name) / "review.json"
        output.write_bytes(b'{"note":"a\x00b\xff"}\n\n')
        snapshot = self.capture(reviewer="codex")
        kept = Path(self.retain(snapshot, output))
        self.assertEqual(kept.parent, self.receipts_dir() / "reviews")
        self.assertEqual(kept.read_bytes(), output.read_bytes())
        self.assertEqual(kept.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.retain(snapshot, output), str(kept))
        self.assertEqual(len(list(kept.parent.glob("*.json"))), 1)

    def test_retain_is_bounded_and_keeps_the_newest(self):
        output = Path(self.tmp.name) / "review.json"
        snapshot = self.capture(reviewer="codex")
        paths = []
        for number in range(33):
            output.write_text(f"review {number}")
            paths.append(Path(self.retain(snapshot, output)))
            os.utime(paths[-1], ns=(number * 10**9, number * 10**9))
        kept = set((self.receipts_dir() / "reviews").glob("*.json"))
        self.assertEqual(len(kept), 30)
        self.assertIn(paths[-1], kept)
        self.assertNotIn(paths[0], kept)

    def test_retain_is_evidence_only(self):
        """A retained review neither approves nor blocks anything."""
        output = Path(self.tmp.name) / "review.json"
        output.write_text('{"verdict":"approve","findings":[]}')
        self.retain(self.capture(reviewer="codex"), output)
        self.check(False)
        snapshot = self.begin(reviewer="codex")
        self.retain(snapshot, output)
        self.complete(snapshot)
        self.check()

    def test_retain_refuses_an_empty_output_and_a_symlinked_store(self):
        output = Path(self.tmp.name) / "review.json"
        output.write_text("")
        snapshot = self.capture(reviewer="codex")
        self.retain(snapshot, output, ok=False)
        output.write_text("review")
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        (self.receipts_dir() / "reviews").symlink_to(elsewhere)
        self.retain(snapshot, output, ok=False)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_check_refuses_when_a_block_lands_after_its_validation(self):
        """The marker is read under the lock, in check's deciding assertion."""
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.complete(self.begin(reviewer="codex"))
        blocking = self.capture(reviewer="antigravity")
        real = module.classify_tier
        calls = []

        def classify_then_block(*args, **kwargs):
            result = real(*args, **kwargs)
            if not calls:
                calls.append(True)
                self.block(blocking)
            return result

        args = argparse.Namespace(
            repo=str(self.repo), head=self.git("rev-parse", "HEAD"), base="main", reviewer=None
        )
        printed = io.StringIO()
        with mock.patch.object(module, "classify_tier", classify_then_block):
            with self.assertRaises(ValueError) as refused, contextlib.redirect_stdout(printed):
                module.check(args)
        self.assertTrue(calls)
        self.assertIn("blocking verdict", str(refused.exception))
        self.assertNotIn("Valid", printed.getvalue())

    # ─── #541 / #540: own-worktree boundaries in unusual layouts ───

    def test_common_git_directory_trailing_whitespace_keeps_worktrees_owned(self):
        """Only Git's terminating newline is stripped from the common directory (#541)."""
        store = Path(self.tmp.name) / "store "
        self.git("init", "-q", "--separate-git-dir", str(store))
        self.git("worktree", "add", "-q", "visible/agent-y", "-b", "agent-y")
        (self.repo / "visible/agent-y/AGENTS.md").write_text("instructions over there\n")
        snapshot = self.begin("committed")
        self.assertEqual(
            json.loads(snapshot.read_text())["artifact"]["changed_paths"], ["code.txt"]
        )
        self.complete(snapshot)
        self.check()

    def test_primary_checkout_nested_under_a_linked_worktree_is_owned(self):
        """A registered primary checkout has a `.git` directory, not a pointer (#540)."""
        linked = Path(self.tmp.name) / "linked"
        self.git("worktree", "add", "-q", str(linked), "-b", "linked")
        (linked / "code.txt").write_text("linked work\n")
        subprocess.check_call(["git", "-C", str(linked), "commit", "-qam", "linked work"])
        primary = linked / "main"
        self.repo.rename(primary)
        # repair reports the pointer it fixes on stderr; keep the suite quiet.
        subprocess.check_output(
            ["git", "-C", str(primary), "worktree", "repair"], stderr=subprocess.STDOUT
        )
        (primary / "AGENTS.md").write_text("instructions over there\n")
        self.repo = linked
        for ignored in (False, True):
            with self.subTest(ignored=ignored):
                if ignored:
                    (primary / ".git/info/exclude").write_text("main/\n")
                snapshot = self.begin("committed")
                self.assertEqual(
                    json.loads(snapshot.read_text())["artifact"]["changed_paths"], ["code.txt"]
                )
                self.complete(snapshot)
                self.check()

    def test_a_foreign_repository_with_a_git_directory_is_still_refused(self):
        """The #540 allowance is the registered primary only, not any `.git` directory."""
        foreign = self.repo / "vendor/foreign"
        foreign.mkdir(parents=True)
        subprocess.check_call(["git", "-C", str(foreign), "init", "-q"])
        (foreign / "AGENTS.md").write_text("hidden\n")
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

    # ─── #680: the review base is pinned once; a sibling moving it is not a change ───

    def advance_main(self):
        """A sibling merges to the base: main gains a commit the branch lacks."""
        self.git("checkout", "-q", "main")
        (self.repo / "sibling.txt").write_text("merged elsewhere\n")
        self.git("add", "sibling.txt")
        self.git("commit", "-qm", "sibling merge")
        self.git("checkout", "-q", "feature")

    def test_base_moving_mid_review_does_not_void_the_run(self):
        snapshot = self.begin()
        self.advance_main()
        self.run_helper("verify", "--snapshot", str(snapshot))
        self.complete(snapshot)
        self.check()

    def test_base_moving_after_approval_keeps_the_receipt(self):
        self.complete(self.begin())
        self.advance_main()
        self.check()

    def test_branch_changes_still_void_a_pinned_base_run(self):
        snapshot = self.begin()
        self.advance_main()
        (self.repo / "code.txt").write_text("changed again\n")
        self.git("commit", "-qam", "more work")
        self.run_helper("verify", "--snapshot", str(snapshot), ok=False)
        self.complete(snapshot, ok=False)

    def test_a_receipt_whose_merge_base_no_longer_matches_is_refused(self):
        """Pinning the base is not ignoring it: a rebased-past merge base refuses."""
        self.complete(self.begin())
        head = self.git("rev-parse", "HEAD")
        # main absorbs the branch (fast-forward), so the reviewed diff
        # merge_base..HEAD is no longer what pushing HEAD to main would add.
        self.git("update-ref", "refs/heads/main", head)
        self.check(False)

    def test_a_block_after_the_base_tip_moved_still_retires_the_approval(self):
        """Markers key on the merge base, as `check` does; a moved tip cannot split them."""
        self.complete(self.begin(reviewer="codex"))
        self.check()
        self.advance_main()
        self.block(self.capture(reviewer="antigravity"))
        self.check(False)
        self.check(False, "--reviewer", "codex")

    def test_a_marker_written_under_the_base_tip_key_still_retires_the_approval(self):
        """Markers from before the merge-base key are looked up too, not skipped."""
        self.complete(self.begin(reviewer="codex"))
        self.check()
        snapshot = self.capture(reviewer="antigravity")
        self.block(snapshot)
        (marker,) = self.block_markers()
        record = json.loads(marker.read_text())
        spec = importlib.util.spec_from_file_location("receipt_identity", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        artifact = json.loads(snapshot.read_text())["artifact"]
        legacy, key = module.legacy_artifact_identity(artifact)
        self.assertNotEqual(key, marker.stem)
        record["artifact"] = legacy
        (marker.parent / (key + ".json")).write_text(json.dumps(record))
        marker.unlink()
        self.check(False)
        self.check(False, "--reviewer", "codex")

    def test_a_legacy_marker_at_another_base_tip_still_retires_the_approval(self):
        """An older gate blocked after a sibling moved the tip; its key names that tip."""
        self.complete(self.begin(reviewer="codex"))
        self.check()
        self.advance_main()
        snapshot = self.capture(reviewer="antigravity")
        self.block(snapshot)
        (marker,) = self.block_markers()
        record = json.loads(marker.read_text())
        spec = importlib.util.spec_from_file_location("receipt_identity_tip", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        artifact = json.loads(snapshot.read_text())["artifact"]
        legacy, key = module.legacy_artifact_identity(artifact)
        self.assertNotEqual(legacy["base"], self.git("rev-parse", "main^"))
        record["artifact"] = legacy
        (marker.parent / (key + ".json")).write_text(json.dumps(record))
        marker.unlink()
        self.check(False)
        self.check(False, "--reviewer", "codex")

    def test_snapshot_capture_resolves_the_base_once(self):
        """Both stable_capture passes use one resolved base commit."""
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real = module.oid
        calls = []

        def moving_oid(repo, ref):
            calls.append(ref)
            if ref == "main" and len([c for c in calls if c == "main"]) == 2:
                self.advance_main()
            return real(repo, ref)

        module.oid = moving_oid
        artifact, _ = module.stable_capture(self.repo, "main", "committed")
        self.assertEqual(artifact["base"]["ref"], "main")
        self.assertEqual(calls.count("main"), 1, calls)

    # ─── #641: a foreign boundary's own config must not steer its listing ───

    def foreign_boundary(self):
        (self.repo / ".git/info/exclude").write_text("vendor/\n")
        boundary = self.repo / "vendor/nested"
        boundary.mkdir(parents=True)
        subprocess.check_output(["git", "init", "-q", str(boundary)], stderr=subprocess.PIPE)
        (boundary / "index.js").write_text("library code\n")
        return boundary

    def test_boundary_core_worktree_cannot_list_another_directory(self):
        """`core.worktree` in the boundary's config pointed `ls-files` at a decoy."""
        boundary = self.foreign_boundary()
        decoy = Path(self.tmp.name) / "decoy"
        decoy.mkdir()
        (decoy / "index.js").write_text("innocent\n")
        subprocess.check_call(["git", "-C", str(boundary), "config", "core.worktree", str(decoy)])
        # The redirect alone is benign: the boundary is still inspected and allowed.
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
        )
        (boundary / "CLAUDE.md").write_text("EVIL\n")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("vendor/nested/CLAUDE.md", refused.stderr)

    def test_boundary_ignorecase_cannot_mask_an_instruction_file(self):
        """A tracked `claude.md` masked an untracked `CLAUDE.md` under ignoreCase."""
        boundary = self.foreign_boundary()
        (boundary / "claude.md").write_text("ordinary notes\n")
        subprocess.check_call(["git", "-C", str(boundary), "add", "claude.md"])
        subprocess.check_call(["git", "-C", str(boundary), "config", "core.ignoreCase", "true"])
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
        )
        (boundary / "CLAUDE.md").write_text("EVIL\n")
        if sorted(os.listdir(boundary)) != [".git", "CLAUDE.md", "claude.md", "index.js"]:
            self.skipTest("case-insensitive filesystem")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("vendor/nested/CLAUDE.md", refused.stderr)

    def test_worktree_pointers_are_parsed_as_git_parses_them(self):
        """Only Git's own delimiters are removed from worktree paths (#541's class)."""
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        directory = Path(self.tmp.name) / "pointer"
        directory.mkdir()
        store = Path(self.tmp.name) / "store"
        for content, expected in (
            # read_gitfile: exactly "gitdir: ", then trailing CR/LF only.
            (b"gitdir: " + bytes(store) + b"/wt \n", str(store) + "/wt "),
            (b"gitdir: " + bytes(store) + b"/wt\t\r\n", str(store) + "/wt\t"),
            (b"gitdir: " + bytes(store) + b"/wt", str(store) + "/wt"),
            (b"gitdir:" + bytes(store) + b"/wt\n", None),
            (b"gitdir:  " + bytes(store) + b"/wt\n", " " + str(store) + "/wt"),
            (b"junk\ngitdir: " + bytes(store) + b"/wt\n", None),
        ):
            with self.subTest(content=content):
                (directory / ".git").write_bytes(content)
                got = module.worktree_gitdir(directory)
                want = (
                    None
                    if expected is None
                    else os.path.realpath(os.path.join(directory, expected))
                )
                self.assertEqual(got, want)
        registration = Path(self.tmp.name) / "registration"
        registration.mkdir()
        for content, expected in (
            (b"/repo/wt /.git\n", "/repo/wt /.git"),
            (b" /repo/wt/.git\r\n", " /repo/wt/.git"),
            (b"/repo/wt/.git", "/repo/wt/.git"),
        ):
            with self.subTest(registered=content):
                (registration / "gitdir").write_bytes(content)
                self.assertEqual(module.registered_worktree(registration), expected)
        (registration / "gitdir").unlink()
        self.assertIsNone(module.registered_worktree(registration))

    # ─── #514: vendored dependencies under skills/ and scripts/ ───

    def vendored_fixture(self, ignored=True, lockfiles=True):
        paths = []
        if ignored:
            (self.repo / ".gitignore").write_text("node_modules/\n")
            paths.append(".gitignore")
        if lockfiles:
            for lockfile in ("claude/skills/demo/bun.lock", "claude/scripts/package-lock.json"):
                target = self.repo / lockfile
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("{}\n")
                paths.append(lockfile)
        if paths:
            self.git("add", "--", *paths)
            self.git("commit", "-qm", "vendoring fixture")
        for vendored in (
            "claude/skills/demo/node_modules/dep/SKILL.md",
            "claude/scripts/node_modules/dep/CLAUDE.md",
        ):
            target = self.repo / vendored
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("a dependency's own instructions\n")

    def begin_output(self):
        return subprocess.run(
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

    def test_capture_checks_each_vendored_tree_once(self):
        """A dependency tree's files must not each spawn their own `check-ignore`."""
        self.vendored_fixture()
        for index in range(40):
            target = self.repo / "claude/scripts/node_modules/dep" / f"file{index}.js"
            target.write_text("module.exports = 1\n")
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real = module.git
        calls = []

        def counting_git(repo, *args):
            if args[:1] == ("check-ignore",):
                calls.append(args)
            return real(repo, *args)

        module.git = counting_git
        module.capture(self.repo, "main", "committed")
        # One per qualifying tree (skills/demo and scripts), not one per file.
        self.assertLessEqual(len(calls), 2, calls)

    def test_ignored_locked_node_modules_under_skills_and_scripts_are_vendored(self):
        self.vendored_fixture()
        snapshot = self.begin("committed")
        self.complete(snapshot)
        self.check()

    def test_node_modules_without_a_lockfile_or_not_ignored_still_refuses(self):
        start = self.git("rev-parse", "HEAD")
        for ignored, lockfiles in ((True, False), (False, True), (False, False)):
            with self.subTest(ignored=ignored, lockfiles=lockfiles):
                self.git("reset", "-q", "--hard", start)
                self.git("clean", "-qfdx")
                self.vendored_fixture(ignored=ignored, lockfiles=lockfiles)
                refused = self.begin_output()
                self.assertNotEqual(refused.returncode, 0, refused.stdout)
                self.assertIn("instruction", refused.stderr)

    def test_ignoring_only_the_planted_file_is_not_a_vendored_tree(self):
        """The node_modules directory itself must be ignored, not just the entry."""
        self.vendored_fixture(ignored=False, lockfiles=True)
        (self.repo / ".git/info/exclude").write_text(
            "/claude/skills/demo/node_modules/dep/SKILL.md\n"
            "/claude/scripts/node_modules/dep/CLAUDE.md\n"
        )
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("claude/scripts/node_modules/dep/CLAUDE.md", refused.stderr)

    def test_ignored_contents_with_a_reincluded_child_are_not_a_vendored_tree(self):
        """`node_modules/*` ignores the contents, not the directory (#514)."""
        self.vendored_fixture(ignored=False, lockfiles=True)
        (self.repo / ".git/info/exclude").write_text(
            "/claude/skills/demo/node_modules/*\n"
            "/claude/scripts/node_modules/*\n"
            "!/claude/scripts/node_modules/keep.js\n"
        )
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("claude/scripts/node_modules/dep/CLAUDE.md", refused.stderr)

    def test_vendored_exemption_is_limited_to_skills_and_scripts(self):
        self.vendored_fixture()
        elsewhere = self.repo / "claude/agents/node_modules/dep/AGENTS.md"
        elsewhere.parent.mkdir(parents=True)
        elsewhere.write_text("not exempt\n")
        (self.repo / "claude/agents/bun.lock").write_text("{}\n")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("claude/agents/node_modules/dep/AGENTS.md", refused.stderr)

    # ─── #651: a repo-root node_modules in an ordinary bun/npm project ───

    ROOT_VENDORED = (
        # Real packages ship these: bun-types a CLAUDE.md, playwright-core skills.
        "node_modules/bun-types/CLAUDE.md",
        "node_modules/playwright-core/lib/tools/skills/demo/SKILL.md",
        "node_modules/some-pkg/AGENTS.md",
    )

    def root_vendored_fixture(self, ignore="node_modules/\n", lockfile="bun.lock"):
        paths = []
        if ignore:
            (self.repo / ".gitignore").write_text(ignore)
            paths.append(".gitignore")
        if lockfile:
            (self.repo / lockfile).write_text("{}\n")
            paths.append(lockfile)
        if paths:
            self.git("add", "--", *paths)
            self.git("commit", "-qm", "root vendoring fixture")
        for vendored in self.ROOT_VENDORED:
            target = self.repo / vendored
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("a dependency's own instructions\n")

    def test_ignored_locked_root_node_modules_is_vendored(self):
        start = self.git("rev-parse", "HEAD")
        for lockfile in ("bun.lock", "bun.lockb", "package-lock.json"):
            with self.subTest(lockfile=lockfile):
                self.git("reset", "-q", "--hard", start)
                self.git("clean", "-qfdx")
                self.root_vendored_fixture(lockfile=lockfile)
                snapshot = self.begin("committed")
                self.complete(snapshot)
                self.check()

    def test_root_node_modules_without_a_lockfile_or_not_ignored_still_refuses(self):
        start = self.git("rev-parse", "HEAD")
        for ignore, lockfile in (("node_modules/\n", None), (None, "bun.lock"), (None, None)):
            with self.subTest(ignore=ignore, lockfile=lockfile):
                self.git("reset", "-q", "--hard", start)
                self.git("clean", "-qfdx")
                self.root_vendored_fixture(ignore=ignore, lockfile=lockfile)
                refused = self.begin_output()
                self.assertNotEqual(refused.returncode, 0, refused.stdout)
                self.assertIn("node_modules/bun-types/CLAUDE.md", refused.stderr)

    def test_root_node_modules_fails_closed_like_the_514_trees(self):
        """Every #514 refusal holds at the root: the tree, not the entry, is ignored."""
        cases = {
            # Only the planted files are excluded, not the directory.
            "planted-only": "".join("/" + p + "\n" for p in self.ROOT_VENDORED),
            # `node_modules/*` ignores contents whose children can be re-included.
            "reincluded-child": "/node_modules/*\n!/node_modules/keep.js\n",
        }
        start = self.git("rev-parse", "HEAD")
        for name, exclude in cases.items():
            with self.subTest(case=name):
                self.git("reset", "-q", "--hard", start)
                self.git("clean", "-qfdx")
                self.root_vendored_fixture(ignore=None)
                (self.repo / ".git/info/exclude").write_text(exclude)
                refused = self.begin_output()
                self.assertNotEqual(refused.returncode, 0, refused.stdout)
                self.assertIn("node_modules/", refused.stderr)
        (self.repo / ".git/info/exclude").write_text("")
        # A lockfile that is a symlink is not evidence of an install.
        self.git("reset", "-q", "--hard", start)
        self.git("clean", "-qfdx")
        self.root_vendored_fixture(lockfile=None)
        outside = Path(self.tmp.name) / "outside-lock"
        outside.mkdir()
        (outside / "bun.lock").write_text("{}\n")
        (self.repo / "bun.lock").symlink_to(outside / "bun.lock")
        (self.repo / ".git/info/exclude").write_text("/bun.lock\n")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("node_modules/bun-types/CLAUDE.md", refused.stderr)

    def test_root_node_modules_symlink_is_not_a_vendored_tree(self):
        """Git does not descend a symlink, so check the predicate directly."""
        self.root_vendored_fixture(ignore="node_modules\n")
        outside = Path(self.tmp.name) / "outside-tree"
        shutil.move(str(self.repo / "node_modules"), str(outside))
        (self.repo / "node_modules").symlink_to(outside)
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertFalse(module.vendored_dependency(self.repo, self.ROOT_VENDORED[0]))
        (self.repo / "node_modules").unlink()
        shutil.move(str(outside), str(self.repo / "node_modules"))
        self.assertTrue(module.vendored_dependency(self.repo, self.ROOT_VENDORED[0]))

    def test_root_exemption_is_only_the_repository_root(self):
        """A lockfile at the root does not vendor a nested `node_modules`."""
        self.root_vendored_fixture()
        nested = self.repo / "packages/app/node_modules/dep/AGENTS.md"
        nested.parent.mkdir(parents=True)
        nested.write_text("not exempt\n")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("packages/app/node_modules/dep/AGENTS.md", refused.stderr)

    def test_helper_is_executable(self):
        """The review-gates skill invokes the helper directly, not via python3 (#651)."""
        self.assertTrue(os.access(HELPER, os.X_OK), HELPER)
        mode = subprocess.check_output(
            ["git", "-C", str(HELPER.parent), "ls-files", "--stage", "--", HELPER.name]
        ).split()[0]
        self.assertEqual(mode, b"100755")

    # ─── #581: an ignored bytecode cache is still an instruction surface ───
    # A `.pyc` beside its `.py` can carry code the source does not: Python
    # imports a timestamp-valid cache without reading the source, and nothing
    # short of recompiling proves the two match (recompiled bodies are not even
    # byte-identical across the import and py_compile paths). So the cache is
    # never exempted; run-tests.sh leaves none behind (#633) and gate runs set
    # PYTHONDONTWRITEBYTECODE=1.

    def test_ignored_bytecode_cache_beside_its_source_still_refuses(self):
        module = self.repo / "agents/skills/demo/scripts/tool.py"
        module.parent.mkdir(parents=True)
        module.write_text("VALUE = 1\n")
        (self.repo / ".gitignore").write_text("__pycache__/\n")
        self.git("add", "--", ".gitignore", "agents/skills/demo/scripts/tool.py")
        self.git("commit", "-qm", "bytecode fixture")
        cache = module.parent / "__pycache__"
        cache.mkdir()
        (cache / "tool.cpython-312.pyc").write_bytes(b"\x00bytecode")
        refused = self.begin_output()
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("agents/skills/demo/scripts/__pycache__/tool.cpython-312.pyc", refused.stderr)

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

    # ─── clean-worktree committed reviews ──────────────────────────

    def run_helper_env(self, *args, env=None, ok=True):
        if env is None and self._is_clean_worktree_cmd(args):
            env = self._env_without_ceiling()
        process = subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(process.returncode == 0, ok, process.stdout + process.stderr)
        return process

    def new_detached_worktree(self, name="clean-wt", ref="HEAD"):
        wt = Path(self.tmp.name) / name
        self.git("worktree", "add", "--quiet", "--detach", str(wt), ref)
        return wt

    def dirty_caller_runtime_files(self):
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir(parents=True, exist_ok=True)
        (claude_dir / "settings.json").write_text('{"permissions":{}}\n')
        (self.repo / ".env.local").write_text("SECRET_ENV_MARKER=topsecret\n")

    def capture_clean(
        self, wt, reviewer="codex", base="main", scope="committed", env=None, ok=True
    ):
        process = self.run_helper_env(
            "capture",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--base",
            base,
            "--scope",
            scope,
            "--reviewer",
            reviewer,
            env=env,
            ok=ok,
        )
        return Path(process.stdout.strip()) / "snapshot.json" if ok else process

    def test_clean_worktree_lane_routes_committed_and_refuses_uncommitted(self):
        self.dirty_caller_runtime_files()
        payload = json.loads(
            self.run_helper(
                "lane",
                "--repo",
                str(self.repo),
                "--base",
                "main",
                "--scope",
                "committed",
                "--clean-worktree",
            )
        )
        self.assertEqual(payload["tier"], 2)
        self.assertEqual(payload["required_lane"], "antigravity")
        self.assertFalse(self.receipts_dir().exists())

        refused = self.run_helper_env(
            "lane",
            "--repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "uncommitted",
            "--clean-worktree",
            ok=False,
        )
        self.assertIn("--clean-worktree requires --scope committed", refused.stderr)

    def test_clean_worktree_happy_path_persists_in_caller_after_wt_removal(self):
        self.git("checkout", "-q", "main")
        (self.repo / "package.json").write_text('{"name":"demo"}\n')
        self.git("add", "package.json")
        self.git("commit", "-qm", "package baseline")
        self.git("checkout", "-qb", "clean-feature")
        (self.repo / "code.txt").write_text("clean worktree change\n")
        self.git("commit", "-qam", "feature commit")

        # Caller working tree holds untracked runtime files and dirty tracked state.
        self.dirty_caller_runtime_files()
        (self.repo / "package.json").write_text('{"name":"dirty"}\n')

        wt = self.new_detached_worktree()
        snapshot = self.capture_clean(wt, reviewer="codex", base="main")
        self.assertTrue(snapshot.is_relative_to(self.receipts_dir()))
        snap_data = json.loads(snapshot.read_bytes())
        self.assertTrue(snap_data["clean_worktree"])
        self.assertEqual(snap_data["capture_repository"], str(wt.resolve()))

        self.run_helper("classify", "--snapshot", str(snapshot))
        self.run_helper("verify", "--snapshot", str(snapshot))
        self.claim(snapshot)
        self.complete(snapshot)

        receipt = self.receipts_dir() / "codex.json"
        record = json.loads(receipt.read_bytes())
        self.assertTrue(record["clean_worktree"])
        self.assertNotIn("capture_repository", record)

        # Removing the temporary detached worktree must not break `check`.
        self.git("worktree", "remove", "--force", str(wt))
        self.assertFalse(wt.exists())
        self.check()

        entry = json.loads((self.receipts_dir() / "ledger.jsonl").read_text().splitlines()[-1])
        self.assertEqual(entry["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(entry["outcome"], "passed")

    def test_clean_worktree_refusals(self):
        # Establish an existing valid receipt; failed clean-worktree captures
        # must refuse BEFORE invalidating it when --scope is invalid.
        self.complete(self.begin(reviewer="codex"))
        self.check()
        wt = self.new_detached_worktree()
        for bad_scope in ("uncommitted", "auto"):
            with self.subTest(scope=bad_scope):
                refused = self.capture_clean(wt, scope=bad_scope, ok=False)
                self.assertIn("--receipt-repo requires --scope committed", refused.stderr)
                self.check()

        # Same worktree as --repo and --receipt-repo must fail.
        same = self.run_helper_env(
            "capture",
            "--repo",
            str(self.repo),
            "--receipt-repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )
        self.assertIn("--receipt-repo must name a different worktree", same.stderr)

        # Foreign unrelated repository must fail.
        foreign = Path(self.tmp.name) / "foreign"
        foreign.mkdir()
        subprocess.check_call(["git", "-C", str(foreign), "init", "-q", "-b", "main"])
        subprocess.check_call(["git", "-C", str(foreign), "config", "user.name", "fixture"])
        subprocess.check_call(["git", "-C", str(foreign), "config", "user.email", "f@example.test"])
        (foreign / "f.txt").write_text("hi\n")
        subprocess.check_call(["git", "-C", str(foreign), "add", "f.txt"])
        subprocess.check_call(["git", "-C", str(foreign), "commit", "-qm", "init"])
        rel_foreign = self.run_helper_env(
            "capture",
            "--repo",
            str(foreign),
            "--receipt-repo",
            str(self.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
            ok=False,
        )
        self.assertIn("common directory", rel_foreign.stderr)

        # Mismatched HEAD between worktree and caller fails.
        wt_old = self.new_detached_worktree("wt-old", ref="main")
        mismatch = self.capture_clean(wt_old, ok=False)
        self.assertIn("HEAD does not match", mismatch.stderr)

        # Dirty tracked file, untracked file, or gitignored .env inside wt fails.
        (wt / ".gitignore").write_text(".env*\n")
        subprocess.check_call(["git", "-C", str(wt), "add", ".gitignore"])
        (wt / "code.txt").write_text("dirty inside wt\n")
        dirty_wt = self.capture_clean(wt, ok=False)
        self.assertIn("clean worktree", dirty_wt.stderr)
        subprocess.check_call(["git", "-C", str(wt), "reset", "--hard", "-q", "HEAD"])

        (wt / "untracked.txt").write_text("oops\n")
        untracked_wt = self.capture_clean(wt, ok=False)
        self.assertIn("untracked or ignored", untracked_wt.stderr)
        (wt / "untracked.txt").unlink()

        (wt / ".env").write_text("SECRET=1\n")
        ignored_wt = self.capture_clean(wt, ok=False)
        self.assertIn("untracked or ignored", ignored_wt.stderr)
        (wt / ".env").unlink()

        # Modifying wt or advancing caller HEAD mid-review fails verify/complete.
        snapshot = self.capture_clean(wt)
        self.claim(snapshot)
        (wt / "oops.txt").write_text("late\n")
        self.run_helper("verify", "--snapshot", str(snapshot), ok=False)
        self.complete(snapshot, ok=False)
        (wt / "oops.txt").unlink()

        snapshot2 = self.capture_clean(wt)
        self.claim(snapshot2)
        (self.repo / "extra.txt").write_text("caller moved\n")
        self.git("add", "extra.txt")
        self.git("commit", "-qm", "caller advance")
        self.run_helper("verify", "--snapshot", str(snapshot2), ok=False)
        self.complete(snapshot2, ok=False)

    def test_clean_worktree_live_runtime_guard(self):
        self.git("checkout", "-q", "main")
        codex_dir = self.repo / "codex"
        codex_dir.mkdir()
        (codex_dir / "AGENTS.md").write_text("# Agents\n")
        self.git("add", "codex/AGENTS.md")
        self.git("commit", "-qm", "add live surface")
        self.git("checkout", "-qb", "live-branch")
        (self.repo / "code.txt").write_text("live change\n")
        self.git("commit", "-qam", "change code")

        fake_home = Path(self.tmp.name) / "home"
        (fake_home / ".codex").mkdir(parents=True)
        (fake_home / ".codex" / "AGENTS.md").symlink_to(self.repo / "codex" / "AGENTS.md")
        env = self._env_without_ceiling(HOME=str(fake_home))

        # Untracked .claude/settings.json passes when live AGENTS.md is clean.
        self.dirty_caller_runtime_files()
        wt = self.new_detached_worktree()
        snapshot = self.capture_clean(wt, env=env)
        self.assertTrue(snapshot.exists())

        # Uncommitted edit to symlinked live AGENTS.md fails capture.
        (self.repo / "codex" / "AGENTS.md").write_text("# Edited locally\n")
        refused = self.capture_clean(wt, env=env, ok=False)
        self.assertIn("dirty live reviewer or gate surface", refused.stderr)

    def test_clean_worktree_tamper_checks(self):
        wt = self.new_detached_worktree()
        snapshot = self.capture_clean(wt)
        self.claim(snapshot)
        self.complete(snapshot)
        self.git("worktree", "remove", "--force", str(wt))
        self.check()

        receipt = self.receipts_dir() / "codex.json"
        record = json.loads(receipt.read_bytes())

        # Malformed or false clean_worktree fails.
        for bad_flag in (False, None, "yes"):
            tampered = json.loads(json.dumps(record))
            tampered["clean_worktree"] = bad_flag
            receipt.write_text(json.dumps(tampered))
            self.check(False)

        # Dropping clean_worktree when caller is dirty falls back to normal check and fails.
        self.dirty_caller_runtime_files()
        dropped = json.loads(json.dumps(record))
        dropped.pop("clean_worktree")
        receipt.write_text(json.dumps(dropped))
        self.check(False)
        shutil.rmtree(self.repo / ".claude")
        (self.repo / ".env.local").unlink()

        # Injecting capture_repository fails.
        injected = json.loads(json.dumps(record))
        injected["capture_repository"] = str(self.tmp.name)
        receipt.write_text(json.dumps(injected))
        self.assertIn("capture_repository", self.check_refusal())

        # Altering artifact fields or classification fails.
        mutations = [
            ("head", "0" * 40),
            ("tree", "0" * 40),
            ("diff_sha256", "0" * 64),
            ("review_diff_sha256", "0" * 64),
            ("changed_paths", ["invented.txt"]),
            ("changed_modes", {"invented.txt": ["missing", "100644"]}),
        ]
        for field, value in mutations:
            tampered = json.loads(json.dumps(record))
            tampered["artifact"][field] = value
            receipt.write_text(json.dumps(tampered))
            self.check(False)

        for base_field in ("commit", "merge_base"):
            tampered = json.loads(json.dumps(record))
            tampered["artifact"]["base"][base_field] = "0" * 40
            receipt.write_text(json.dumps(tampered))
            self.check(False)

        for bad_ref in ("", None, 123):
            tampered = json.loads(json.dumps(record))
            tampered["artifact"]["base"]["ref"] = bad_ref
            receipt.write_text(json.dumps(tampered))
            self.check(False)

        tampered = json.loads(json.dumps(record))
        tampered["classification"]["required_lane"] = "any"
        receipt.write_text(json.dumps(tampered))
        self.check(False)

        receipt.write_text(json.dumps(record))
        self.check()

        # Renaming the old base branch must NOT invalidate a pinned receipt when the
        # current shipping base still matches the pinned base commit and merge_base.
        self.git("branch", "-m", "main", "trunk")
        self.check(True, "--base", "trunk")
        self.git("branch", "-m", "trunk", "main")

        # Copying a clean-worktree receipt to a sibling worktree fails.
        sibling = self.new_detached_worktree("sibling-wt")
        sib_receipts = (
            Path(
                subprocess.check_output(
                    ["git", "-C", str(sibling), "rev-parse", "--absolute-git-dir"], text=True
                ).strip()
            )
            / "review-receipts"
        )
        sib_receipts.mkdir(parents=True, exist_ok=True)
        shutil.copy2(receipt, sib_receipts / "codex.json")
        shutil.copy2(
            self.receipts_dir() / "codex.attempt.json", sib_receipts / "codex.attempt.json"
        )
        sib_check = self.run_helper_env(
            "check",
            "--repo",
            str(sibling),
            "--head",
            self.git("rev-parse", "HEAD"),
            ok=False,
        )
        self.assertNotEqual(sib_check.returncode, 0)

        # Forging clean_worktree: true onto a normal receipt fails attempt check.
        self.complete(self.begin(reviewer="codex"))
        normal = json.loads(receipt.read_bytes())
        self.assertNotIn("clean_worktree", normal)
        normal["clean_worktree"] = True
        receipt.write_text(json.dumps(normal))
        self.assertIn("superseded", self.check_refusal())

    def test_clean_worktree_block_and_retain_retire_normal_receipts(self):
        # Prior normal approval must be retired by a clean-worktree block marker.
        self.complete(self.begin(reviewer="antigravity"))
        self.check()

        self.dirty_caller_runtime_files()
        wt = self.new_detached_worktree()
        snap = self.capture_clean(wt, reviewer="codex")

        output = Path(self.tmp.name) / "clean-review.json"
        output.write_text('{"verdict":"block"}\n')
        kept = Path(self.retain(snap, output))
        self.assertTrue(kept.is_relative_to(self.receipts_dir() / "reviews"))
        self.assertTrue(kept.exists())

        self.block(snap)
        self.assertEqual(len(self.block_markers()), 1)
        self.check(False)

        # A subsequent clean-worktree approval after the block passes.
        snap2 = self.capture_clean(wt, reviewer="codex")
        self.claim(snap2)
        self.complete(snap2)
        self.git("worktree", "remove", "--force", str(wt))
        self.check()

    def test_clean_worktree_committed_instruction_links_and_autocrlf(self):
        # Unchanged AGENTS.md -> CLAUDE.md passes complete & check with core.autocrlf=true.
        self.git("checkout", "-q", "main")
        (self.repo / "CLAUDE.md").write_text("# Rules\nline 2\n")
        (self.repo / "AGENTS.md").symlink_to("CLAUDE.md")
        self.git("add", "CLAUDE.md", "AGENTS.md")
        self.git("commit", "-qm", "instruction link")
        self.git("checkout", "-qb", "link-feature")
        (self.repo / "code.txt").write_text("after link\n")
        self.git("commit", "-qam", "feature commit")
        self.git("config", "core.autocrlf", "true")

        wt = self.new_detached_worktree()
        snap = self.capture_clean(wt, base="main")
        self.claim(snap)
        self.complete(snap)
        self.git("worktree", "remove", "--force", str(wt))
        self.check()

        # Unsafe unchanged instruction link targets must fail both capture and lane --clean-worktree.
        bad_targets = (
            ("trailing-slash", "CLAUDE.md/", "target must be relative"),
            ("trailing-dot", "CLAUDE.md/.", "target must resolve"),
            ("missing-dotdot", "missing/../CLAUDE.md", "existing directories"),
        )
        for label, target, expected in bad_targets:
            with self.subTest(label=label):
                base_branch = f"bad-base-{label}"
                self.git("checkout", "-qb", base_branch, "main")
                (self.repo / "AGENTS.md").unlink()
                (self.repo / "AGENTS.md").symlink_to(target)
                self.git("add", "AGENTS.md")
                self.git("commit", "-qm", f"bad link {label}")
                self.git("checkout", "-qb", f"bad-feat-{label}", base_branch)
                (self.repo / "code.txt").write_text(f"work {label}\n")
                self.git("commit", "-qam", f"work {label}")
                lane_bad = self.run_helper_env(
                    "lane",
                    "--repo",
                    str(self.repo),
                    "--base",
                    base_branch,
                    "--scope",
                    "committed",
                    "--clean-worktree",
                    ok=False,
                )
                self.assertIn(expected, lane_bad.stderr)
                wt_bad = self.new_detached_worktree(f"wt-{label}")
                cap_bad = self.capture_clean(wt_bad, base=base_branch, ok=False)
                self.assertIn("unsupported instruction symlink", cap_bad.stderr)
                self.git("worktree", "remove", "--force", str(wt_bad))

        # Symlink ancestor traversal in committed tree fails.
        self.git("checkout", "-qb", "bad-base-anc", "main")
        (self.repo / "realdir").mkdir(exist_ok=True)
        (self.repo / "realdir" / "CLAUDE.md").write_text("# Nested\n")
        (self.repo / "symdir").symlink_to("realdir")
        (self.repo / "AGENTS.md").unlink()
        (self.repo / "AGENTS.md").symlink_to("symdir/CLAUDE.md")
        self.git("add", "realdir/CLAUDE.md", "symdir", "AGENTS.md")
        self.git("commit", "-qm", "symlink ancestor")
        self.git("checkout", "-qb", "bad-feat-anc", "bad-base-anc")
        (self.repo / "code.txt").write_text("work anc\n")
        self.git("commit", "-qam", "work anc")
        lane_anc = self.run_helper_env(
            "lane",
            "--repo",
            str(self.repo),
            "--base",
            "bad-base-anc",
            "--scope",
            "committed",
            "--clean-worktree",
            ok=False,
        )
        self.assertIn("symlink ancestor", lane_anc.stderr)
        wt_anc = self.new_detached_worktree("wt-anc")
        cap_anc = self.capture_clean(wt_anc, base="bad-base-anc", ok=False)
        self.assertIn("unsupported instruction symlink", cap_anc.stderr)
        self.git("worktree", "remove", "--force", str(wt_anc))

    def test_clean_worktree_materialize_avoids_smudge_filters_and_unsafe_trees(self):
        marker = Path(self.tmp.name) / "smudge-marker"
        self.git("checkout", "-q", "main")
        (self.repo / ".gitattributes").write_text("*.txt filter=demo\n")
        (self.repo / "code.txt").write_text("filtered line\n")
        self.git("add", ".gitattributes", "code.txt")
        self.git("commit", "-qm", "attr baseline")
        self.git("checkout", "-qb", "mat-feature")
        (self.repo / "code.txt").write_text("updated raw bytes\n")
        self.git("commit", "-qam", "feature commit")
        self.git("config", "filter.demo.smudge", f"sh -c 'touch \"{marker}\"; cat'")
        self.git("config", "filter.demo.clean", "cat")

        head = self.git("rev-parse", "HEAD")
        wt = Path(self.tmp.name) / "wt-noc"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt), head)
        self.run_helper(
            "materialize",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
        )
        self.assertFalse(marker.exists())
        self.assertEqual((wt / "code.txt").read_text(), "updated raw bytes\n")
        snap = self.capture_clean(wt, base="main")
        self.assertTrue(snap.exists())
        self.git("worktree", "remove", "--force", str(wt))

        # Refuses non-empty directory before materialization.
        wt2 = Path(self.tmp.name) / "wt-dirty"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt2), head)
        (wt2 / "stray.txt").write_text("unexpected\n")
        bad = self.run_helper_env(
            "materialize",
            "--repo",
            str(wt2),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
            ok=False,
        )
        self.assertIn("contain only .git", bad.stderr)
        shutil.rmtree(wt2)
        subprocess.run(["git", "-C", str(self.repo), "worktree", "prune"], check=False)

    def test_clean_worktree_live_runtime_catches_symlink_escape_and_codex_home(self):
        self.git("checkout", "-q", "main")
        (self.repo / "codex").mkdir()
        (self.repo / "codex" / "AGENTS.md").write_text("# Committed\n")
        self.git("add", "codex/AGENTS.md")
        self.git("commit", "-qm", "committed codex dir")
        self.git("checkout", "-qb", "live-sec")
        (self.repo / "code.txt").write_text("sec work\n")
        self.git("commit", "-qam", "work")

        # 1. Replacing REPO/codex with a symlink outside REPO while ~/.codex/AGENTS.md -> REPO/codex/AGENTS.md must refuse.
        external = Path(self.tmp.name) / "external-codex"
        external.mkdir()
        (external / "AGENTS.md").write_text("# External injected\n")
        shutil.rmtree(self.repo / "codex")
        (self.repo / "codex").symlink_to(external)

        fake_home = Path(self.tmp.name) / "escape-home"
        (fake_home / ".codex").mkdir(parents=True)
        (fake_home / ".codex" / "AGENTS.md").symlink_to(self.repo / "codex" / "AGENTS.md")
        wt = self.new_detached_worktree()
        esc = self.capture_clean(wt, env=self._env_without_ceiling(HOME=str(fake_home)), ok=False)
        self.assertIn("receipt repository", esc.stderr)

        # Restore REPO/codex directory so CODEX_HOME checks run cleanly.
        (self.repo / "codex").unlink()
        self.git("checkout", "--", "codex")

        # 2. CODEX_HOME=REPO/.codex with untracked or modified AGENTS.md must refuse even when HOME has no link.
        other_home = Path(self.tmp.name) / "clean-home"
        other_home.mkdir()
        local_codex = self.repo / ".codex"
        local_codex.mkdir()
        (local_codex / "AGENTS.md").write_text("# Shadow CODEX_HOME\n")
        env_codex = self._env_without_ceiling(HOME=str(other_home), CODEX_HOME=str(local_codex))
        ref_untracked = self.capture_clean(wt, env=env_codex, ok=False)
        self.assertIn("dirty live reviewer or gate surface", ref_untracked.stderr)

        self.git("add", ".codex/AGENTS.md")
        self.git("commit", "-qm", "commit dot-codex")
        head_new = self.git("rev-parse", "HEAD")
        wt2 = self.new_detached_worktree("wt-codex-home", ref=head_new)
        (local_codex / "AGENTS.md").write_text("# Edited tracked CODEX_HOME\n")
        ref_modified = self.capture_clean(wt2, env=env_codex, ok=False)
        self.assertIn("dirty live reviewer or gate surface", ref_modified.stderr)

    def test_clean_worktree_ignores_caller_gitattributes_and_supports_relative_base(self):
        self.git("checkout", "-q", "main")
        (self.repo / "code.txt").write_text("base\n")
        self.git("commit", "--allow-empty", "-qm", "upstream anchor")
        self.git("checkout", "-qb", "attr-rel-feature", "main")
        (self.repo / "code.txt").write_text("feature body line\n")
        self.git("commit", "-qam", "feature commit")

        # Untracked/dirty caller .gitattributes with `*.txt -diff` must not alter
        # committed object classification, completion, or `check`.
        (self.repo / ".gitattributes").write_text("*.txt -diff\n")
        lane_out = json.loads(
            self.run_helper(
                "lane",
                "--repo",
                str(self.repo),
                "--base",
                "main",
                "--scope",
                "committed",
                "--clean-worktree",
            )
        )
        self.assertEqual(lane_out["tier"], 2)

        # Configure upstream tracking so @{upstream} exists in caller but not detached wt.
        bare = Path(self.tmp.name) / "bare.git"
        subprocess.check_call(["git", "init", "-q", "--bare", "--initial-branch=main", str(bare)])
        self.git("remote", "add", "origin", str(bare))
        self.git("push", "-q", "origin", "main:main")
        self.git("branch", "--set-upstream-to=origin/main", "attr-rel-feature")

        wt = self.new_detached_worktree()
        snap = self.capture_clean(wt, base="@{upstream}")
        self.claim(snap)
        self.complete(snap)
        self.git("worktree", "remove", "--force", str(wt))
        self.check(True, "--base", "@{upstream}")

    def test_clean_worktree_materialize_rejects_git_routing_and_preserves_caller_index(self):
        self.git("checkout", "-q", "main")
        (self.repo / "code.txt").write_text("base routing\n")
        self.git("commit", "-qam", "base")
        self.git("checkout", "-qb", "index-routing-feature")
        (self.repo / "code.txt").write_text("committed feature\n")
        self.git("commit", "-qam", "feature commit")

        # Keep a staged-only edit in the caller index that is NOT in HEAD.
        (self.repo / "staged-only.txt").write_text("staged work in caller\n")
        self.git("add", "staged-only.txt")
        caller_index = self.repo / ".git/index"
        before_index = caller_index.read_bytes()
        before_stage = self.git("ls-files", "--stage", "staged-only.txt")
        self.assertIn("staged-only.txt", before_stage)

        head = self.git("rev-parse", "HEAD")
        wt = Path(self.tmp.name) / "wt-index-guard"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt), head)

        alt_index = Path(self.tmp.name) / "alt-index"
        for idx_target in (caller_index, alt_index):
            with self.subTest(idx=str(idx_target)):
                res = self.run_helper_env(
                    "materialize",
                    "--repo",
                    str(wt),
                    "--receipt-repo",
                    str(self.repo),
                    "--head",
                    head,
                    env=self._env_without_ceiling(GIT_INDEX_FILE=str(idx_target)),
                    ok=False,
                )
                self.assertIn("GIT_INDEX_FILE", res.stderr)
                self.assertEqual(caller_index.read_bytes(), before_index)
                self.assertFalse(alt_index.exists())

        res_ceiling = self.run_helper_env(
            "materialize",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
            env=self._env_without_ceiling(GIT_CEILING_DIRECTORIES="/tmp"),
            ok=False,
        )
        self.assertIn("GIT_CEILING_DIRECTORIES", res_ceiling.stderr)
        self.assertEqual(caller_index.read_bytes(), before_index)

        # Normal materialization initializes only the temp worktree's index and leaves caller intact.
        self.run_helper(
            "materialize",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
        )
        self.assertEqual(caller_index.read_bytes(), before_index)
        self.assertEqual(self.git("ls-files", "--stage", "staged-only.txt"), before_stage)
        self.assertFalse((wt / "staged-only.txt").exists())

        bad_cap = self.run_helper_env(
            "capture",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--reviewer",
            "codex",
            "--scope",
            "committed",
            "--base",
            "main",
            env=self._env_without_ceiling(GIT_DIR=str(self.repo / ".git")),
            ok=False,
        )
        self.assertIn("GIT_DIR", bad_cap.stderr)
        bad_cap_ceiling = self.run_helper_env(
            "capture",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--reviewer",
            "codex",
            "--scope",
            "committed",
            "--base",
            "main",
            env=self._env_without_ceiling(GIT_CEILING_DIRECTORIES="/tmp"),
            ok=False,
        )
        self.assertIn("GIT_CEILING_DIRECTORIES", bad_cap_ceiling.stderr)
        snap = self.capture_clean(wt, base="main")
        self.assertTrue(snap.exists())
        self.git("worktree", "remove", "--force", str(wt))

    def test_clean_worktree_live_runtime_nested_legacy_skill_link(self):
        self.git("checkout", "-q", "main")
        ref_dir = self.repo / "agents" / "skills" / "demo" / "references"
        ref_dir.mkdir(parents=True)
        skill_md = self.repo / "agents" / "skills" / "demo" / "SKILL.md"
        ref_md = ref_dir / "notes.md"
        skill_md.write_text("# Demo Skill\n")
        ref_md.write_text("# Committed notes\n")
        self.git("add", "agents/skills/demo/SKILL.md", "agents/skills/demo/references/notes.md")
        self.git("commit", "-qm", "legacy skill fixture")
        self.git("checkout", "-qb", "nested-skill-feature")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")

        fake_home = Path(self.tmp.name) / "legacy-home"
        live_ref_dir = fake_home / ".codex" / "skills" / "demo" / "references"
        live_ref_dir.mkdir(parents=True)
        (fake_home / ".codex" / "skills" / "demo" / "SKILL.md").symlink_to(skill_md)
        (live_ref_dir / "notes.md").symlink_to(ref_md)

        wt = self.new_detached_worktree()
        env_home = self._env_without_ceiling(HOME=str(fake_home))

        ref_md.write_text("# Uncommitted dirty notes\n")
        dirty_res = self.capture_clean(wt, env=env_home, ok=False)
        self.assertIn("dirty live reviewer or gate surface", dirty_res.stderr)

        self.git("checkout", "--", "agents/skills/demo/references/notes.md")
        # Symlink loop inside installed skills must not loop infinitely.
        (fake_home / ".codex" / "skills" / "demo" / "loop").symlink_to("../demo")
        snap = self.capture_clean(wt, env=env_home)
        self.assertTrue(snap.exists())

        # Unreadable subdirectory under installed skills fails closed (skipped if running as root).
        if hasattr(os, "geteuid") and os.geteuid() != 0:
            locked = fake_home / ".codex" / "skills" / "locked"
            locked.mkdir()
            os.chmod(locked, 0o000)
            try:
                locked_res = self.capture_clean(wt, env=env_home, ok=False)
                self.assertIn("cannot traverse live reviewer or gate surface", locked_res.stderr)
            finally:
                os.chmod(locked, 0o755)

        self.git("worktree", "remove", "--force", str(wt))

    def test_clean_worktree_live_runtime_symlink_parent_traversal_semantics(self):
        self.git("checkout", "-q", "main")
        (self.repo / "AGENTS.md").write_text("# Committed AGENTS\n")
        (self.repo / ".codex").mkdir(exist_ok=True)
        (self.repo / ".codex" / "AGENTS.md").write_text("# Committed CODEX_HOME AGENTS\n")
        self.git("add", "AGENTS.md", ".codex/AGENTS.md")
        self.git("commit", "-qm", "committed agents")
        self.git("checkout", "-qb", "symlink-dotdot-feature")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")

        repo_real = self.repo.resolve()
        child = repo_real.parent / "live-child"
        child.mkdir(exist_ok=True)
        entry = Path(self.tmp.name) / "entry"
        entry.mkdir()
        (entry / "link").symlink_to(child)

        wt = self.new_detached_worktree()

        # 1. Symlink targeting /entry/link/../<repo>/AGENTS.md where /entry/link -> <repo_parent>/live-child
        # resolves physically to <repo>/AGENTS.md even though lexical abspath points to /entry/<repo>/AGENTS.md.
        fake_home = Path(self.tmp.name) / "dotdot-home"
        (fake_home / ".codex").mkdir(parents=True)
        (fake_home / ".codex" / "AGENTS.md").symlink_to(
            str(entry / "link" / ".." / repo_real.name / "AGENTS.md")
        )
        (self.repo / "AGENTS.md").write_text("# Dirty via symlink/../repo traversal\n")
        res_link = self.capture_clean(
            wt, env=self._env_without_ceiling(HOME=str(fake_home)), ok=False
        )
        self.assertIn("dirty live reviewer or gate surface", res_link.stderr)
        self.git("checkout", "--", "AGENTS.md")

        # 2. Same symlink-then-parent traversal in CODEX_HOME must still catch dirty REPO/.codex/AGENTS.md.
        clean_home = Path(self.tmp.name) / "clean-dotdot-home"
        clean_home.mkdir()
        (self.repo / ".codex" / "AGENTS.md").write_text("# Dirty via CODEX_HOME traversal\n")
        codex_env = self._env_without_ceiling(
            HOME=str(clean_home),
            CODEX_HOME=str(entry / "link" / ".." / repo_real.name / ".codex"),
        )
        res_codex_home = self.capture_clean(wt, env=codex_env, ok=False)
        self.assertIn("dirty live reviewer or gate surface", res_codex_home.stderr)
        self.git("checkout", "--", ".codex/AGENTS.md")

        # 3. Clean targets pass through the same traversal path.
        snap_ok = self.capture_clean(wt, env=codex_env)
        self.assertTrue(snap_ok.exists())

        # 4. Real-directory traversal out of the repo (`<repo>/../outside/.codex`) stays outside and passes.
        outside_codex = repo_real.parent / "outside" / ".codex"
        outside_codex.mkdir(parents=True, exist_ok=True)
        (outside_codex / "AGENTS.md").write_text("# Outside AGENTS\n")
        outside_env = self._env_without_ceiling(
            HOME=str(clean_home),
            CODEX_HOME=str(repo_real / ".." / "outside" / ".codex"),
        )
        snap_out = self.capture_clean(wt, env=outside_env)
        self.assertTrue(snap_out.exists())
        self.git("worktree", "remove", "--force", str(wt))

    def test_clean_worktree_live_runtime_checks_agents_override_and_executable(self):
        self.git("checkout", "-q", "main")
        (self.repo / "AGENTS.override.md").write_text("# Committed override\n")
        (self.repo / "codex").mkdir(exist_ok=True)
        committed_bin = self.repo / "codex" / "committed-codex"
        committed_bin.write_text("#!/bin/sh\nexit 0\n")
        committed_bin.chmod(0o755)
        (self.repo / "bin").mkdir(exist_ok=True)
        path_codex = self.repo / "bin" / "codex"
        path_codex.symlink_to("../codex/committed-codex")
        self.git("add", "AGENTS.override.md", "codex/committed-codex", "bin/codex")
        self.git("commit", "-qm", "committed override, bin, and PATH launcher")
        self.git("checkout", "-qb", "override-exec-feature")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")

        fake_home = Path(self.tmp.name) / "override-home"
        (fake_home / ".codex").mkdir(parents=True)
        (fake_home / ".codex" / "AGENTS.override.md").symlink_to(self.repo / "AGENTS.override.md")

        wt = self.new_detached_worktree()
        base_env = self._env_without_ceiling(HOME=str(fake_home))

        def cap_exec(wt_dir, *extra, env=base_env, ok=True):
            res = self.run_helper_env(
                "capture",
                "--repo",
                str(wt_dir),
                "--receipt-repo",
                str(self.repo),
                "--reviewer",
                "codex",
                "--scope",
                "committed",
                "--base",
                "main",
                *extra,
                env=env,
                ok=ok,
            )
            return Path(res.stdout.strip()) if ok else res

        def comp_exec(snap_dir, ok=True):
            return self.run_helper_env(
                "complete",
                "--snapshot",
                str(snap_dir / "snapshot.json"),
                "--outcome",
                "passed",
                "--output",
                str(self._make_codex_output()),
                env=base_env,
                ok=ok,
            )

        # 1. Dirty AGENTS.override.md refuses at capture and at complete.
        (self.repo / "AGENTS.override.md").write_text("# Dirty override\n")
        res_dirty_override = self.capture_clean(wt, env=base_env, ok=False)
        self.assertIn("dirty live reviewer or gate surface", res_dirty_override.stderr)
        self.git("checkout", "--", "AGENTS.override.md")

        snap_ovr = cap_exec(wt, "--executable", str(committed_bin))
        self.run_helper_env("claim", "--snapshot", str(snap_ovr / "snapshot.json"), env=base_env)
        (self.repo / "AGENTS.override.md").write_text("# Mutated during review\n")
        comp_dirty_ovr = comp_exec(snap_ovr, ok=False)
        self.assertIn("dirty live reviewer or gate surface", comp_dirty_ovr.stderr)
        self.git("checkout", "--", "AGENTS.override.md")

        # 2. Uncommitted caller-local executable via --executable fails capture.
        untracked_bin = self.repo / "codex" / "untracked-codex"
        untracked_bin.write_text("#!/bin/sh\nexit 0\n")
        untracked_bin.chmod(0o755)
        res_untracked_bin = cap_exec(wt, "--executable", str(untracked_bin), ok=False)
        self.assertIn("dirty live reviewer or gate surface", res_untracked_bin.stderr)
        untracked_bin.unlink()

        # 3. Clean committed executable passes capture, then dirtying it fails complete.
        snap_bin = cap_exec(wt, "--executable", str(committed_bin))
        self.run_helper_env("claim", "--snapshot", str(snap_bin / "snapshot.json"), env=base_env)
        committed_bin.write_text("#!/bin/sh\necho tampered\n")
        comp_dirty_bin = comp_exec(snap_bin, ok=False)
        self.assertIn("dirty live reviewer or gate surface", comp_dirty_bin.stderr)
        self.git("checkout", "--", "codex/committed-codex")

        # 4. CODEX_GATE_BIN escaping through a repo symlink is caught even if --executable was resolved.
        ext_bin = Path(self.tmp.name) / "external-codex-bin"
        ext_bin.write_text("#!/bin/sh\nexit 0\n")
        ext_bin.chmod(0o755)
        esc_bin = self.repo / "codex" / "escape-bin"
        esc_bin.symlink_to(ext_bin)
        env_esc_bin = dict(base_env, CODEX_GATE_BIN=str(esc_bin))
        res_esc_bin = cap_exec(wt, "--executable", str(ext_bin), env=env_esc_bin, ok=False)
        self.assertIn("receipt repository", res_esc_bin.stderr)
        esc_bin.unlink()

        # 5. Tracked repo/bin/codex replaced locally with a symlink to ext_bin fails with --launcher even without CODEX_GATE_BIN.
        wt_launcher = self.new_detached_worktree("wt-launcher")
        path_codex.unlink()
        path_codex.symlink_to(ext_bin)
        res_launcher_esc = cap_exec(
            wt_launcher, "--executable", str(ext_bin), "--launcher", str(path_codex), ok=False
        )
        self.assertIn("receipt repository", res_launcher_esc.stderr)

        # Clean committed launcher passes capture, then swapping to external symlink fails complete.
        path_codex.unlink()
        self.git("checkout", "--", "bin/codex")
        snap_launcher = cap_exec(
            wt_launcher, "--executable", str(committed_bin), "--launcher", str(path_codex)
        )
        self.assertIn("capture_launcher", json.loads((snap_launcher / "snapshot.json").read_text()))
        self.run_helper_env(
            "claim", "--snapshot", str(snap_launcher / "snapshot.json"), env=base_env
        )
        path_codex.unlink()
        path_codex.symlink_to(ext_bin)
        comp_launcher_esc = comp_exec(snap_launcher, ok=False)
        self.assertIn("receipt repository", comp_launcher_esc.stderr)

        # Complete cleanly with restored launcher, then verify forged capture_launcher on receipt fails check.
        path_codex.unlink()
        self.git("checkout", "--", "bin/codex")
        snap_launcher_ok = cap_exec(
            wt_launcher, "--executable", str(committed_bin), "--launcher", str(path_codex)
        )
        self.run_helper_env(
            "claim", "--snapshot", str(snap_launcher_ok / "snapshot.json"), env=base_env
        )
        comp_exec(snap_launcher_ok)
        self.git("worktree", "remove", "--force", str(wt_launcher))
        receipt_path = self.receipts_dir() / "codex.json"
        saved_receipt = json.loads(receipt_path.read_text())
        self.assertNotIn("capture_launcher", saved_receipt)
        forged_receipt = json.loads(json.dumps(saved_receipt))
        forged_receipt["capture_launcher"] = str(path_codex)
        receipt_path.write_text(json.dumps(forged_receipt))
        self.assertIn("capture_launcher", self.check_refusal())
        receipt_path.write_text(json.dumps(saved_receipt))
        self.check()
        self.git("worktree", "remove", "--force", str(wt))

    def _make_codex_output(self):
        out = Path(self.tmp.name) / "codex-pass.json"
        out.write_text(
            json.dumps(
                {
                    "verdict": "approve",
                    "summary": "ok",
                    "next_steps": [],
                    "findings": [],
                    "coverage": {"status": "complete", "examined": ["code.txt"], "limitations": []},
                }
            )
        )
        return out

    def test_clean_worktree_rejects_escaping_symlinks_and_allows_internal_links(self):
        self.git("checkout", "-q", "main")
        (self.repo / "docs").mkdir(exist_ok=True)
        (self.repo / "docs" / "ref").symlink_to("../code.txt")
        self.git("add", "docs/ref")
        self.git("commit", "-qm", "internal non-instruction symlink")
        self.git("checkout", "-qb", "internal-link-feature")
        (self.repo / "code.txt").write_text("feature via internal link\n")
        self.git("commit", "-qam", "work")

        head_ok = self.git("rev-parse", "HEAD")
        wt_ok = Path(self.tmp.name) / "wt-internal-link"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt_ok), head_ok)
        self.run_helper(
            "materialize",
            "--repo",
            str(wt_ok),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head_ok,
        )
        snap = self.capture_clean(wt_ok, base="main")
        self.claim(snap)
        self.complete(snap)
        self.git("worktree", "remove", "--force", str(wt_ok))
        self.check()

        bad_cases = (
            ("rel-escape", "esc-rel", "../../.env.local"),
            ("abs-escape", "esc-abs", "/etc/hosts"),
            ("dotgit-target", "esc-dotgit", ".git"),
        )
        for label, link_name, target in bad_cases:
            with self.subTest(case=label):
                self.git("checkout", "-qb", f"bad-{label}", "main")
                (self.repo / link_name).symlink_to(target)
                self.git("add", link_name)
                self.git("commit", "-qm", f"add {label}")
                head_bad = self.git("rev-parse", "HEAD")
                wt_noc = Path(self.tmp.name) / f"wt-noc-{label}"
                self.git(
                    "worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt_noc), head_bad
                )
                mat_bad = self.run_helper_env(
                    "materialize",
                    "--repo",
                    str(wt_noc),
                    "--receipt-repo",
                    str(self.repo),
                    "--head",
                    head_bad,
                    ok=False,
                )
                self.assertIn("clean worktree", mat_bad.stderr)
                self.git("worktree", "remove", "--force", str(wt_noc))
                wt_man = self.new_detached_worktree(f"wt-man-{label}", ref=head_bad)
                cap_bad = self.capture_clean(wt_man, base="main", ok=False)
                self.assertIn("clean worktree", cap_bad.stderr)
                self.git("worktree", "remove", "--force", str(wt_man))

        # Chained escape and symlink loop also fail both materialize and capture.
        self.git("checkout", "-qb", "bad-chain", "main")
        (self.repo / "dotlink").symlink_to(".")
        (self.repo / "chain-esc").symlink_to("dotlink/../outside")
        self.git("add", "dotlink", "chain-esc")
        self.git("commit", "-qm", "chained escape")
        head_chain = self.git("rev-parse", "HEAD")
        wt_chain = Path(self.tmp.name) / "wt-chain"
        self.git(
            "worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt_chain), head_chain
        )
        mat_chain = self.run_helper_env(
            "materialize",
            "--repo",
            str(wt_chain),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head_chain,
            ok=False,
        )
        self.assertIn("escaping symlink", mat_chain.stderr)
        self.git("worktree", "remove", "--force", str(wt_chain))

        self.git("checkout", "-qb", "bad-loop", "main")
        (self.repo / "loop-a").symlink_to("loop-b")
        (self.repo / "loop-b").symlink_to("loop-a")
        self.git("add", "loop-a", "loop-b")
        self.git("commit", "-qm", "symlink loop")
        head_loop = self.git("rev-parse", "HEAD")
        wt_loop = self.new_detached_worktree("wt-loop", ref=head_loop)
        cap_loop = self.capture_clean(wt_loop, base="main", ok=False)
        self.assertIn("symlink loop", cap_loop.stderr)
        self.git("worktree", "remove", "--force", str(wt_loop))

    def test_clean_worktree_supports_separate_git_dir_primary_checkout(self):
        sep_meta = Path(self.tmp.name) / "separate-meta"
        self.git("init", "--separate-git-dir", str(sep_meta))
        self.dirty_caller_runtime_files()

        head = self.git("rev-parse", "HEAD")
        wt = Path(self.tmp.name) / "wt-sep"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt), head)
        self.run_helper(
            "materialize",
            "--repo",
            str(wt),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
        )
        snap = self.capture_clean(wt, base="main")
        self.claim(snap)
        self.complete(snap)
        self.git("worktree", "remove", "--force", str(wt))
        self.check()

        # A linked worktree whose .git file is forged to point directly to sep_meta must fail.
        wt_forged = self.new_detached_worktree("wt-forged", ref=head)
        (wt_forged / ".git").unlink()
        (wt_forged / ".git").write_text(f"gitdir: {sep_meta}\n")
        forged_res = self.capture_clean(wt_forged, base="main", ok=False)
        self.assertIn("not owned by the receipt repository", forged_res.stderr)
        shutil.rmtree(wt_forged)
        self.git("worktree", "prune")

    def test_clean_worktree_materialize_suppresses_post_index_change_hooks(self):
        self.git("checkout", "-q", "main")
        (self.repo / "code.txt").write_text("hook suppression check\n")
        self.git("commit", "-qam", "work")
        head = self.git("rev-parse", "HEAD")

        hook_marker = Path(self.tmp.name) / "post-index-change-ran"
        default_hook = self.repo / ".git" / "hooks" / "post-index-change"
        default_hook.parent.mkdir(parents=True, exist_ok=True)
        default_hook.write_text(f"#!/bin/sh\ntouch '{hook_marker}'\n")
        default_hook.chmod(0o755)

        wt1 = Path(self.tmp.name) / "wt-hook-default"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt1), head)
        self.run_helper(
            "materialize",
            "--repo",
            str(wt1),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
        )
        self.assertFalse(hook_marker.exists())
        self.git("worktree", "remove", "--force", str(wt1))

        custom_hooks = Path(self.tmp.name) / "custom-hooks"
        custom_hooks.mkdir()
        custom_hook = custom_hooks / "post-index-change"
        custom_hook.write_text(f"#!/bin/sh\ntouch '{hook_marker}'\n")
        custom_hook.chmod(0o755)
        self.git("config", "core.hooksPath", str(custom_hooks))

        wt2 = Path(self.tmp.name) / "wt-hook-custom"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt2), head)
        self.run_helper(
            "materialize",
            "--repo",
            str(wt2),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head,
        )
        self.assertFalse(hook_marker.exists())
        self.git("worktree", "remove", "--force", str(wt2))

    def _make_case_insensitive_fs(self):
        base = os.path.realpath(self.tmp.name)

        def _fold(name):
            return unicodedata.normalize("NFC", name).casefold()

        class _Entry:
            def __init__(self, real_entry, parent_str):
                self._real = real_entry
                self.name = real_entry.name
                self.path = os.path.join(parent_str, real_entry.name)

            def stat(self, *, follow_symlinks=True):
                return self._real.stat(follow_symlinks=follow_symlinks)

        class _ScanCtx:
            def __init__(self, entries):
                self._entries = entries

            def __enter__(self):
                return iter(self._entries)

            def __exit__(self, *exc):
                return False

        class _CaseInsensitiveFS:
            def __init__(self, sandbox_base):
                self._base = sandbox_base

            def getcwd(self):
                return os.getcwd()

            def _is_base(self, path_obj):
                return os.path.realpath(path_obj) == self._base

            def _resolve(self, path, follow_final=False):
                raw = os.fspath(path)
                if not os.path.isabs(raw):
                    raw = os.path.join(self.getcwd(), raw)
                queue = [seg for seg in raw.split("/") if seg and seg != "."]
                cur = Path("/")
                logical = []
                in_base = self._is_base(cur)
                hops = 0
                idx = 0
                while idx < len(queue):
                    seg = queue[idx]
                    idx += 1
                    is_last = idx == len(queue)
                    if seg == "..":
                        if logical:
                            logical.pop()
                        if cur.parent != cur:
                            cur = cur.parent
                        in_base = self._is_base(cur) or Path(self._base) in cur.parents
                        continue
                    chosen = seg
                    if in_base:
                        try:
                            with os.scandir(cur) as it:
                                entries = list(it)
                        except OSError:
                            entries = []
                        exact = next((e.name for e in entries if e.name == seg), None)
                        if exact is not None:
                            chosen = exact
                        else:
                            folded = _fold(seg)
                            chosen = next((e.name for e in entries if _fold(e.name) == folded), seg)
                    candidate_real = cur / chosen
                    if (not is_last or follow_final) and os.path.islink(candidate_real):
                        hops += 1
                        if hops > 40:
                            raise OSError("too many symlinks")
                        target = os.readlink(candidate_real)
                        if os.path.isabs(target):
                            cur = Path("/")
                            logical = []
                            in_base = False
                        else:
                            in_base = self._is_base(cur) or Path(self._base) in cur.parents
                        extra = [s for s in target.split("/") if s and s != "."]
                        queue = extra + queue[idx:]
                        idx = 0
                        continue
                    cur = candidate_real
                    logical.append(seg)
                    if not in_base and self._is_base(cur):
                        in_base = True
                return cur, "/" + "/".join(logical)

            def lstat(self, path):
                return os.lstat(self._resolve(path, follow_final=False)[0])

            def stat(self, path):
                return os.stat(self._resolve(path, follow_final=True)[0])

            def readlink(self, path):
                return os.readlink(self._resolve(path, follow_final=False)[0])

            def scandir(self, path):
                parent_str = os.fspath(path)
                real_dir = self._resolve(path, follow_final=True)[0]
                with os.scandir(real_dir) as it:
                    wrapped = [_Entry(entry, parent_str) for entry in it]
                return _ScanCtx(wrapped)

            def realpath(self, path):
                return self._resolve(path, follow_final=True)[1]

            def samefile(self, a, b):
                return os.path.samefile(
                    self._resolve(a, follow_final=True)[0],
                    self._resolve(b, follow_final=True)[0],
                )

        return _CaseInsensitiveFS(base)

    def test_clean_worktree_rejects_case_aliased_symlink_escape(self):
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        # 1. Case-aliased chain `link -> .` + `escape -> LINK/../outside` fails both materialize and capture.
        self.git("checkout", "-qb", "bad-ci-escape", "main")
        (self.repo / "link").symlink_to(".")
        (self.repo / "escape").symlink_to("LINK/../outside")
        self.git("add", "link", "escape")
        self.git("commit", "-qm", "case-aliased escape chain")
        head_alias = self.git("rev-parse", "HEAD")

        wt_noc = Path(self.tmp.name) / "wt-ci-escape"
        self.git("worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt_noc), head_alias)
        mat_alias = self.run_helper_env(
            "materialize",
            "--repo",
            str(wt_noc),
            "--receipt-repo",
            str(self.repo),
            "--head",
            head_alias,
            ok=False,
        )
        self.assertIn("escaping symlink", mat_alias.stderr)
        self.git("worktree", "remove", "--force", str(wt_noc))

        wt_man = self.new_detached_worktree("wt-man-ci-escape", ref=head_alias)
        cap_alias = self.capture_clean(wt_man, base="main", ok=False)
        self.assertIn("escaping symlink", cap_alias.stderr)

        # Pure filesystem-identity verification catches LINK/../outside on a case-insensitive FS.
        ci_fs = self._make_case_insensitive_fs()
        with self.assertRaisesRegex(ValueError, "escaping symlink"):
            module._assert_disk_symlinks_confined(wt_man, ["link", "escape"], fs=ci_fs)
        self.git("worktree", "remove", "--force", str(wt_man))

        # 2. Regular file nested under a case-aliased symlink ancestor (`link -> .`, `LINK/file.txt`) is rejected.
        self.git("checkout", "-qb", "bad-alias-anc", "main")
        (self.repo / "link").symlink_to(".")
        self.git("add", "link")
        self.git("commit", "-qm", "add link")
        if not (self.repo / "LINK").exists():
            # Create tree with `link -> .` and blob `LINK/file.txt` without needing FS collision.
            file_oid = self.git("hash-object", "-w", str(self.repo / "code.txt"))
            base_tree = self.git("rev-parse", "HEAD^{tree}")
            link_tree = (
                subprocess.check_output(
                    ["git", "-C", str(self.repo), "mktree"],
                    input=f"100644 blob {file_oid}\tfile.txt\n".encode(),
                )
                .decode()
                .strip()
            )
            root_lines = subprocess.check_output(
                ["git", "-C", str(self.repo), "ls-tree", base_tree]
            ).decode()
            combined_tree = (
                subprocess.check_output(
                    ["git", "-C", str(self.repo), "mktree"],
                    input=(root_lines + f"040000 tree {link_tree}\tLINK\n").encode(),
                )
                .decode()
                .strip()
            )
            bad_commit = (
                subprocess.check_output(
                    ["git", "-C", str(self.repo), "commit-tree", combined_tree, "-p", "HEAD"],
                    input=b"case-aliased ancestor under symlink\n",
                )
                .decode()
                .strip()
            )
            self.git("update-ref", "refs/heads/bad-alias-anc", bad_commit)
            wt_anc = Path(self.tmp.name) / "wt-ci-anc"
            self.git(
                "worktree", "add", "--no-checkout", "--quiet", "--detach", str(wt_anc), bad_commit
            )
            mat_anc = self.run_helper_env(
                "materialize",
                "--repo",
                str(wt_anc),
                "--receipt-repo",
                str(self.repo),
                "--head",
                bad_commit,
                ok=False,
            )
            self.assertIn("escaping symlink ancestor", mat_anc.stderr)
            self.git("worktree", "remove", "--force", str(wt_anc))

    def test_clean_worktree_live_runtime_validates_case_aliased_repo_paths(self):
        spec = importlib.util.spec_from_file_location("receipt_under_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        self.git("checkout", "-q", "main")
        (self.repo / "rules").mkdir(exist_ok=True)
        agents_lower = self.repo / "rules" / "agents.md"
        agents_lower.write_text("# Clean lower rules\n")
        self.git("add", "rules/agents.md")
        self.git("commit", "-qm", "committed lower rules/agents.md")

        ci_fs = self._make_case_insensitive_fs()
        repo_upper = Path(self.tmp.name) / self.repo.name.upper()
        alias_dir = Path(self.tmp.name) / "ci-live-home" / ".codex"
        alias_dir.mkdir(parents=True)
        alias_link = alias_dir / "AGENTS.md"
        alias_link.symlink_to(repo_upper / "RULES" / "AGENTS.md")

        rels = module._paths_within_repo(alias_link, self.repo, fs=ci_fs)
        self.assertEqual(rels, [Path("rules/agents.md")])

        clean_home = Path(self.tmp.name) / "ci-live-home"
        with mock.patch.dict(
            os.environ,
            {"HOME": str(clean_home), "CODEX_HOME": str(alias_dir)},
            clear=False,
        ):
            # Clean tracked lowercase file passes through case-aliased spelling.
            module.assert_live_runtime_clean(self.repo, fs=ci_fs)

            # Mutated lowercase file accessed via uppercase alias fails closed.
            agents_lower.write_text("# Dirty via uppercase alias\n")
            with self.assertRaisesRegex(ValueError, "dirty live reviewer or gate surface"):
                module.assert_live_runtime_clean(self.repo, fs=ci_fs)

            # Deleted tracked file accessed via uppercase alias also fails closed.
            agents_lower.unlink()
            with self.assertRaisesRegex(ValueError, "dirty live reviewer or gate surface"):
                module.assert_live_runtime_clean(self.repo, fs=ci_fs)

    def test_clean_worktree_rejects_ignorecase_untracked_case_collision(self):
        self.git("checkout", "-q", "main")
        (self.repo / "agents.md").write_text("# Clean tracked lower\n")
        self.git("add", "agents.md")
        self.git("commit", "-qm", "tracked agents.md")
        self.git("checkout", "-qb", "ignorecase-collision")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")
        self.git("config", "core.ignoreCase", "true")

        # Skip only when the host OS filesystem itself forbids case-distinct siblings.
        wt = self.new_detached_worktree("wt-ignorecase")
        (wt / "AGENTS.md").write_text("# Untracked uppercase in wt\n")
        if sorted(p.name for p in wt.iterdir() if p.name.lower() == "agents.md") != [
            "AGENTS.md",
            "agents.md",
        ]:
            self.git("worktree", "remove", "--force", str(wt))
            self.skipTest("case-insensitive filesystem")

        # 1. assert_worktree_clean rejects untracked AGENTS.md despite core.ignoreCase=true.
        cap_wt = self.capture_clean(wt, base="main", ok=False)
        self.assertIn("untracked or ignored files", cap_wt.stderr)
        (wt / "AGENTS.md").unlink()

        # 2. assert_live_runtime_clean rejects untracked AGENTS.md in caller repo via symlink.
        (self.repo / "AGENTS.md").write_text("# Untracked uppercase live surface\n")
        fake_home = Path(self.tmp.name) / "ignorecase-home"
        (fake_home / ".codex").mkdir(parents=True)
        (fake_home / ".codex" / "AGENTS.md").symlink_to(self.repo / "AGENTS.md")
        cap_live = self.capture_clean(
            wt, base="main", env=self._env_without_ceiling(HOME=str(fake_home)), ok=False
        )
        self.assertIn("dirty live reviewer or gate surface", cap_live.stderr)
        self.assertIn("AGENTS.md", cap_live.stderr)
        (self.repo / "AGENTS.md").unlink()
        self.git("worktree", "remove", "--force", str(wt))

    def test_clean_worktree_live_runtime_never_exempts_active_targets_in_node_modules(self):
        self.git("checkout", "-q", "main")
        (self.repo / "package-lock.json").write_text('{"name":"demo","lockfileVersion":3}\n')
        (self.repo / ".gitignore").write_text("node_modules/\n")
        self.git("add", "package-lock.json", ".gitignore")
        self.git("commit", "-qm", "lockfile and ignore node_modules")
        self.git("checkout", "-qb", "nm-active-feature")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")

        nm_bin = self.repo / "node_modules" / ".bin"
        nm_bin.mkdir(parents=True)
        nm_codex = nm_bin / "codex"
        nm_codex.write_text("#!/bin/sh\nexit 0\n")
        nm_codex.chmod(0o755)
        nm_agents = self.repo / "node_modules" / "pkg" / "AGENTS.md"
        nm_agents.parent.mkdir(parents=True)
        nm_agents.write_text("# Ignored instruction\n")
        nm_skills = self.repo / "node_modules" / "evil-skills"
        (nm_skills / "demo").mkdir(parents=True)
        (nm_skills / "demo" / "SKILL.md").write_text("# Evil skill\n")

        clean_home = Path(self.tmp.name) / "nm-clean-home"
        clean_home.mkdir()
        wt = self.new_detached_worktree("wt-nm-active")
        clean_env = self._env_without_ceiling(HOME=str(clean_home))
        clean_env.pop("CODEX_GATE_BIN", None)
        clean_env.pop("CODEX_HOME", None)

        # Incidental ignored node_modules does not block when unselected.
        snap_ok = self.capture_clean(wt, base="main", env=clean_env)
        self.assertTrue(snap_ok.exists())

        # 1. Actively selected CODEX_GATE_BIN under node_modules/.bin/codex fails closed.
        res_env_bin = self.capture_clean(
            wt, base="main", env=dict(clean_env, CODEX_GATE_BIN=str(nm_codex)), ok=False
        )
        self.assertIn("dirty live reviewer or gate surface", res_env_bin.stderr)

        # 2. Bare `codex` resolved from PATH into node_modules/.bin/codex fails closed.
        res_path_bin = self.capture_clean(
            wt,
            base="main",
            env=dict(clean_env, PATH=f"{nm_bin}:{clean_env.get('PATH', '')}"),
            ok=False,
        )
        self.assertIn("dirty live reviewer or gate surface", res_path_bin.stderr)

        # 3. Installed instruction link targeting node_modules/pkg/AGENTS.md fails closed.
        home_file_link = Path(self.tmp.name) / "nm-file-home"
        (home_file_link / ".codex").mkdir(parents=True)
        (home_file_link / ".codex" / "AGENTS.md").symlink_to(nm_agents)
        res_instr_file = self.capture_clean(
            wt, base="main", env=dict(clean_env, HOME=str(home_file_link)), ok=False
        )
        self.assertIn("dirty live reviewer or gate surface", res_instr_file.stderr)

        # 4. Installed skill directory symlink targeting node_modules/evil-skills fails closed.
        home_dir_link = Path(self.tmp.name) / "nm-dir-home"
        (home_dir_link / ".codex").mkdir(parents=True)
        (home_dir_link / ".codex" / "skills").symlink_to(nm_skills)
        res_instr_dir = self.capture_clean(
            wt, base="main", env=dict(clean_env, HOME=str(home_dir_link)), ok=False
        )
        self.assertIn("dirty live reviewer or gate surface", res_instr_dir.stderr)
        self.git("worktree", "remove", "--force", str(wt))

    def test_clean_worktree_follows_sibling_gate_dependencies_outside_standard_roots(self):
        self.git("checkout", "-q", "main")
        (self.repo / "claude" / "scripts").mkdir(parents=True)
        gate_lib = self.repo / "claude" / "scripts" / "gate-lib.sh"
        schema = self.repo / "claude" / "scripts" / "codex-review-schema.json"
        gate_lib.write_text("#!/usr/bin/env bash\nGATE_LIB=clean\n")
        schema.write_text('{"type":"object"}\n')
        (self.repo / "package-lock.json").write_text('{"name":"demo","lockfileVersion":3}\n')
        (self.repo / ".gitignore").write_text("node_modules/\n")
        self.git(
            "add",
            "claude/scripts/gate-lib.sh",
            "claude/scripts/codex-review-schema.json",
            "package-lock.json",
            ".gitignore",
        )
        self.git("commit", "-qm", "committed gate sibling files")
        self.git("checkout", "-qb", "opt-gates-feature")
        (self.repo / "code.txt").write_text("feature work\n")
        self.git("commit", "-qam", "work")

        opt_gates = Path(self.tmp.name) / "opt-gates"
        opt_gates.mkdir()
        opt_helper = opt_gates / "review-receipt.py"
        shutil.copy2(HELPER, opt_helper)
        (opt_gates / "gate-lib.sh").symlink_to(gate_lib)
        (opt_gates / "codex-review-schema.json").symlink_to(schema)

        clean_home = Path(self.tmp.name) / "opt-gates-home"
        clean_home.mkdir()
        env_opt = self._env_without_ceiling(HOME=str(clean_home))
        env_opt.pop("CODEX_HOME", None)
        env_opt.pop("CLAUDE_CONFIG_DIR", None)
        env_opt.pop("CODEX_GATE_BIN", None)

        def run_opt(*cmd_args, ok=True):
            proc = subprocess.run(
                [sys.executable, str(opt_helper), *cmd_args],
                capture_output=True,
                text=True,
                env=env_opt,
            )
            self.assertEqual(proc.returncode == 0, ok, proc.stdout + proc.stderr)
            return proc

        wt = self.new_detached_worktree("wt-opt-gates")

        def cap_opt(ok=True):
            return run_opt(
                "capture",
                "--repo",
                str(wt),
                "--receipt-repo",
                str(self.repo),
                "--reviewer",
                "codex",
                "--scope",
                "committed",
                "--base",
                "main",
                ok=ok,
            )

        run_dir = Path(cap_opt().stdout.strip())
        run_opt("claim", "--snapshot", str(run_dir / "snapshot.json"))

        # Mutate committed sibling gate-lib.sh during review: complete must fail closed.
        gate_lib.write_text("#!/usr/bin/env bash\nGATE_LIB=tampered\n")
        comp_dirty = run_opt(
            "complete",
            "--snapshot",
            str(run_dir / "snapshot.json"),
            "--outcome",
            "passed",
            "--output",
            str(self._make_codex_output()),
            ok=False,
        )
        self.assertIn("dirty live reviewer or gate surface", comp_dirty.stderr)

        # Capture also refuses dirty linked gate-lib.sh and dirty linked schema.
        cap_dirty_lib = cap_opt(ok=False)
        self.assertIn("dirty live reviewer or gate surface", cap_dirty_lib.stderr)
        self.git("checkout", "--", "claude/scripts/gate-lib.sh")

        schema.write_text('{"type":"object","tampered":true}\n')
        cap_dirty_schema = cap_opt(ok=False)
        self.assertIn("dirty live reviewer or gate surface", cap_dirty_schema.stderr)
        self.git("checkout", "--", "claude/scripts/codex-review-schema.json")

        # Sibling symlink pointing into ignored node_modules is never exempted.
        evil_multipart = self.repo / "node_modules" / "evil" / "review-multipart.py"
        evil_multipart.parent.mkdir(parents=True)
        evil_multipart.write_text("print('tampered')\n")
        (opt_gates / "review-multipart.py").symlink_to(evil_multipart)
        cap_nm_sibling = cap_opt(ok=False)
        self.assertIn("dirty live reviewer or gate surface", cap_nm_sibling.stderr)
        self.git("worktree", "remove", "--force", str(wt))


if __name__ == "__main__":
    unittest.main()
