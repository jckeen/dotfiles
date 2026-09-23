#!/usr/bin/env python3
"""Fixture tests for resolve-changelog.py (#561).

Each case writes a CHANGELOG into a temp dir (or produces a real conflict with
`git merge` in a throwaway repo) and runs the resolver as a subprocess.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "resolve-changelog.py"

HEAD = "# Changelog\n\n"
OLD = "## 2026-09-20 — fix: an older entry\n\n- Old body.\n"
OURS = "## 2026-09-22 — feat: our branch's entry\n\n- Ours body.\n"
THEIRS = "## 2026-09-22 — fix: the entry that merged first\n\n- Theirs body.\n"
MARKERS = ("<<<<<<<", "=======", ">>>>>>>", "|||||||")


def conflicted(ours=OURS, theirs=THEIRS, base=None, before="", after=OLD):
    """A CHANGELOG as `git merge origin/main` leaves it (ours = HEAD)."""
    mid = f"||||||| base\n{base}" if base is not None else ""
    return (
        f"{HEAD}{before}<<<<<<< HEAD\n{ours}\n{mid}=======\n{theirs}\n>>>>>>> origin/main\n{after}"
    )


def run(path, *args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args, str(path)],
        capture_output=True,
        text=True,
        check=False,
    )


class ResolveChangelog(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.path = self.dir / "CHANGELOG.md"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text):
        self.path.write_text(text)

    def assert_no_markers(self, text):
        for line in text.splitlines():
            self.assertFalse(line.startswith(MARKERS), f"marker left: {line!r}")

    def test_head_conflict_keeps_both_theirs_on_top(self):
        self.write(conflicted())
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        text = self.path.read_text()
        self.assert_no_markers(text)
        self.assertEqual(text, f"{HEAD}{THEIRS}\n{OURS}\n{OLD}")

    def test_blank_separator_added_between_sections(self):
        # A side that ends without a blank line still gets one before the next heading.
        self.write(conflicted().replace("- Theirs body.\n\n", "- Theirs body.\n"))
        self.assertEqual(run(self.path).returncode, 0)
        self.assertIn("- Theirs body.\n\n## 2026-09-22 — feat", self.path.read_text())

    def test_empty_diff3_base_is_accepted(self):
        self.write(conflicted(base=""))
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.path.read_text(), f"{HEAD}{THEIRS}\n{OURS}\n{OLD}")

    def test_refuses_mid_file_conflict(self):
        self.write(conflicted(before=OLD + "\n", after=""))
        original = self.path.read_text()
        r = run(self.path)
        self.assertEqual(r.returncode, 1)
        self.assertIn("refusing", r.stderr)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_second_conflict_block(self):
        second = "<<<<<<< HEAD\n- a\n=======\n- b\n>>>>>>> origin/main\n"
        self.write(conflicted(after=OLD + second))
        original = self.path.read_text()
        self.assertEqual(run(self.path).returncode, 1)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_side_that_edits_existing_text(self):
        # A non-empty diff3 base means a side changed lines both touched.
        self.write(conflicted(base="## 2026-09-21 — shared\n"))
        self.assertEqual(run(self.path).returncode, 1)

    def test_refuses_side_that_is_not_whole_sections(self):
        self.write(conflicted(ours="- a stray bullet\n"))
        self.assertEqual(run(self.path).returncode, 1)

    def test_check_mode_does_not_write(self):
        self.write(conflicted())
        original = self.path.read_text()
        r = run(self.path, "--check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.path.read_text(), original)
        self.write(conflicted(before=OLD + "\n", after=""))
        self.assertEqual(run(self.path, "--check").returncode, 1)

    def test_idempotent(self):
        self.write(conflicted())
        self.assertEqual(run(self.path).returncode, 0)
        once = self.path.read_text()
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no conflict", r.stdout)
        self.assertEqual(self.path.read_text(), once)

    def test_missing_file_is_a_usage_error(self):
        self.assertEqual(run(self.dir / "nope.md").returncode, 2)

    def test_real_git_merge_conflict(self):
        def git(*args):
            subprocess.run(
                ["git", "-C", str(self.dir), *args],
                check=True,
                capture_output=True,
                text=True,
            )

        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@t.test")
        git("config", "user.name", "test")
        self.write(HEAD + OLD)
        git("add", "CHANGELOG.md")
        git("commit", "-qm", "base")
        git("switch", "-qc", "feature")
        self.write(HEAD + OURS + "\n" + OLD)
        git("commit", "-qam", "ours")
        git("switch", "-q", "main")
        self.write(HEAD + THEIRS + "\n" + OLD)
        git("commit", "-qam", "theirs")
        git("switch", "-q", "feature")
        merge = subprocess.run(
            ["git", "-C", str(self.dir), "merge", "-q", "main"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(merge.returncode, 0, "fixture should conflict")
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        text = self.path.read_text()
        self.assert_no_markers(text)
        self.assertEqual(text, f"{HEAD}{THEIRS}\n{OURS}\n{OLD}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
