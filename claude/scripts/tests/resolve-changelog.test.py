#!/usr/bin/env python3
"""Fixture tests for resolve-changelog.py (#561).

Marker cases write a diff3-style CHANGELOG into a temp dir; merge cases build a
real conflict with `git merge` in a throwaway repo, so the resolver reads the
merge base from git's index stages. Either way the resolver runs as a subprocess.
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


def conflicted(ours=OURS, theirs=THEIRS, base="", before="", after=OLD):
    """A CHANGELOG as `git merge origin/main` leaves it (ours = HEAD).

    base="" is an empty diff3 base part; base=None writes plain two-way markers.
    """
    mid = f"||||||| base\n{base}" if base is not None else ""
    return (
        f"{HEAD}{before}<<<<<<< HEAD\n{ours}\n{mid}=======\n{theirs}\n>>>>>>> origin/main\n{after}"
    )


def run(path, *args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args, str(path)],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
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

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.dir), *args],
            check=check,
            capture_output=True,
            text=True,
        )

    def merge_conflict(self, base, ours, theirs):
        """Commit base, then ours on `feature` and theirs on `main`; merge main."""
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@t.test")
        self.git("config", "user.name", "test")
        self.git("config", "merge.conflictStyle", "merge")
        self.write(base)
        self.git("add", "CHANGELOG.md")
        self.git("commit", "-qm", "base")
        self.git("switch", "-qc", "feature")
        self.write(ours)
        self.git("commit", "-qam", "ours")
        self.git("switch", "-q", "main")
        self.write(theirs)
        self.git("commit", "-qam", "theirs")
        self.git("switch", "-q", "feature")
        merge = self.git("merge", "-q", "main", check=False)
        self.assertNotEqual(merge.returncode, 0, "fixture should conflict")

    # ── diff3 markers, no git ──────────────────────────────────────────

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

    def test_refuses_plain_markers_without_a_merge_base(self):
        # Two-way markers outside a merge cannot prove a prepend: fail closed.
        self.write(conflicted(base=None))
        original = self.path.read_text()
        r = run(self.path)
        self.assertEqual(r.returncode, 1)
        self.assertIn("merge base", r.stderr)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_mid_file_conflict(self):
        self.write(conflicted(before=OLD + "\n", after=""))
        original = self.path.read_text()
        r = run(self.path)
        self.assertEqual(r.returncode, 1)
        self.assertIn("refusing", r.stderr)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_second_block_inside_an_existing_section(self):
        second = "<<<<<<< HEAD\n- a\n||||||| base\n- c\n=======\n- b\n>>>>>>> origin/main\n"
        self.write(conflicted(after=OLD + second))
        original = self.path.read_text()
        self.assertEqual(run(self.path).returncode, 1)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_side_that_edits_existing_text(self):
        # A diff3 base that is not the shared history means a side edited it.
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

    # ── real git merges: the base comes from the index stages ─────────

    def test_real_git_merge_conflict(self):
        self.merge_conflict(HEAD + OLD, HEAD + OURS + "\n" + OLD, HEAD + THEIRS + "\n" + OLD)
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        text = self.path.read_text()
        self.assert_no_markers(text)
        self.assertEqual(text, f"{HEAD}{THEIRS}\n{OURS}\n{OLD}")

    def test_relative_path_from_a_subdirectory(self):
        self.merge_conflict(HEAD + OLD, HEAD + OURS + "\n" + OLD, HEAD + THEIRS + "\n" + OLD)
        sub = self.dir / "sub"
        sub.mkdir()
        r = run("../CHANGELOG.md", cwd=sub)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.path.read_text(), f"{HEAD}{THEIRS}\n{OURS}\n{OLD}")

    def test_shared_body_stays_with_both_entries(self):
        # Git can leave only the differing headings inside the block when the
        # two new entries share a body; each entry must keep its own copy.
        body = "\n- Same body.\n\n"
        self.merge_conflict(
            HEAD + OLD,
            f"{HEAD}## 2026-09-22 — ours\n{body}{OLD}",
            f"{HEAD}## 2026-09-22 — theirs\n{body}{OLD}",
        )
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.path.read_text(),
            f"{HEAD}## 2026-09-22 — theirs\n{body}## 2026-09-22 — ours\n{body}{OLD}",
        )

    def test_several_blocks_inside_the_new_entries_are_resolved(self):
        ours = f"{HEAD}## 2026-09-22 — ours\n\n- Same line.\n- ours tail.\n\n{OLD}"
        theirs = f"{HEAD}## 2026-09-22 — theirs\n\n- Same line.\n- theirs tail.\n\n{OLD}"
        self.merge_conflict(HEAD + OLD, ours, theirs)
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            self.path.read_text(),
            f"{HEAD}## 2026-09-22 — theirs\n\n- Same line.\n- theirs tail.\n\n"
            f"## 2026-09-22 — ours\n\n- Same line.\n- ours tail.\n\n{OLD}",
        )

    def test_refuses_edit_to_an_existing_section(self):
        # Ours prepends and also edits OLD's body; theirs only prepends.
        edited = OLD.replace("- Old body.", "- Edited.")
        self.merge_conflict(HEAD + OLD, HEAD + OURS + "\n" + edited, HEAD + THEIRS + "\n" + OLD)
        original = self.path.read_text()
        self.assertEqual(run(self.path).returncode, 1)
        self.assertEqual(self.path.read_text(), original)

    def test_refuses_both_sides_renaming_one_section(self):
        # Disjoint new headings over an identical tail are not proof of a
        # prepend: both sides renamed OLD differently.
        body = "\n- Old body.\n\n"
        tail = "## 2026-09-19 — older still\n\n- x.\n"
        base = f"{HEAD}{OLD}\n{tail}"
        self.merge_conflict(
            base,
            f"{HEAD}## 2026-09-20 — renamed by ours\n{body}{tail}",
            f"{HEAD}## 2026-09-20 — renamed by theirs\n{body}{tail}",
        )
        original = self.path.read_text()
        r = run(self.path)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(self.path.read_text(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
