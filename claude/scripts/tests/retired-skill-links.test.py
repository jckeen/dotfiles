#!/usr/bin/env python3
"""Run real health checkers against isolated pre-retirement installations."""

from contextlib import contextmanager, redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[3]
LINKS = {
    "claude": [(".claude/skills/fable-mode/SKILL.md", "claude/skills/fable-mode/SKILL.md")],
    "codex": [
        (".codex/skills/fable-mode/SKILL.md", "agents/skills/fable-mode/SKILL.md"),
        (".codex/skills/fable-mode/agents/openai.yaml", "agents/skills/fable-mode/agents/openai.yaml"),
        (".agents/skills/fable-mode", "agents/skills/fable-mode"),
    ],
    "antigravity": [(".gemini/config/skills/fable-mode", "agents/skills/fable-mode")],
}


def link_to(destination, source):
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(source)


def snapshot(root):
    result = {}
    for parent, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(parent) / name
            relative = str(path.relative_to(root))
            result[relative] = ("link", os.readlink(path)) if path.is_symlink() else (
                ("dir",) if path.is_dir() else ("file", path.read_bytes())
            )
    return result


def load_retirement_helper(repo):
    spec = importlib.util.spec_from_file_location("retirement", repo / "claude/scripts/retired-skill-links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def fixture(runtime):
    with tempfile.TemporaryDirectory(prefix="retired-skill-test-") as temp:
        # macOS temporary roots can traverse /var -> /private/var. Use the real
        # path so incidental platform links do not trigger the ancestry guard.
        base = Path(temp).resolve()
        repo, home = base / "dotfiles", base / "home"
        repo.mkdir()
        home.mkdir()
        for name in [f"check-{runtime}.sh", "lib-checks.sh", "lib-symlinks.sh"]:
            shutil.copy2(REPO / name, repo / name)
        helpers = [Path("claude/scripts") / name for name in ("retired-skill-links.sh", "retired-skill-links.py")]
        for helper in helpers:
            if (REPO / helper).exists():
                (repo / helper).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO / helper, repo / helper)
        if runtime == "claude":
            (repo / "claude").mkdir(exist_ok=True)
            (repo / "claude/nolink.txt").write_text("nolink.txt\n")
            (home / ".claude").mkdir()
            for helper in helpers:
                if (repo / helper).exists():
                    link_to(home / ".claude/scripts" / helper.name, repo / helper)
        else:
            (repo / runtime).mkdir()
            names = ["AGENTS.md"] if runtime == "codex" else ["GEMINI.md", "hooks.json"]
            destination = home / (".codex" if runtime == "codex" else ".gemini/config")
            destination.mkdir(parents=True)
            for name in names:
                (repo / runtime / name).write_text("{}\n")
                link_to(destination / name, repo / runtime / name)
            if runtime == "antigravity":
                (destination / "mcp_config.json").write_text('{"mcpServers":{}}\n')
        for dest, source in LINKS[runtime]:
            link_to(home / dest, repo / source)

        def run(*args):
            return subprocess.run(
                ["bash", str(repo / f"check-{runtime}.sh"), *args],
                env={**os.environ, "HOME": str(home), "CODEX_MEMORY_REPO": str(base / "no-memory"),
                     "AGY_MEMORY_REPO": str(base / "no-memory")},
                text=True, capture_output=True, timeout=15,
            )

        yield repo, home, run


@contextmanager
def document_fixture():
    with fixture("claude") as (repo, home, run):
        for dest, _ in LINKS["claude"]:
            (home / dest).unlink()
        link_to(home / ".claude/FABLE.md", repo / "claude/FABLE.md")
        yield repo, home, run


class DocumentRetirementTests(unittest.TestCase):
    def test_plain_audit_reports_document_without_changes(self):
        with document_fixture() as (_, home, run):
            before = snapshot(home)
            result = run()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("ORPHAN  FABLE.md", result.stdout)
            self.assertEqual(snapshot(home), before)

    def test_normal_heal_removes_only_retired_document_and_is_idempotent(self):
        with document_fixture() as (_, home, run):
            before = snapshot(home)
            result = run("--heal")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("RETIRED  .claude/FABLE.md", result.stdout)
            del before[".claude/FABLE.md"]
            self.assertEqual(snapshot(home), before)
            result = run("--heal")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(snapshot(home), before)

    def test_document_replacements_and_other_orphans_are_preserved(self):
        for kind in ("file", "directory", "custom-link", "near-match", "newline-target"):
            with self.subTest(kind=kind), document_fixture() as (repo, home, run):
                destination = home / ".claude/FABLE.md"
                destination.unlink()
                if kind == "file":
                    destination.write_text("operator-owned document\n")
                elif kind == "directory":
                    destination.mkdir()
                    (destination / "private.txt").write_text("operator-owned directory\n")
                else:
                    target = {"custom-link": "custom/FABLE.md", "near-match": "claude/FABLE.md.old",
                              "newline-target": "claude/FABLE.md\n"}[kind]
                    destination.symlink_to(repo / target)
                link_to(home / ".claude/other-retired.md", repo / "claude/other-retired.md")
                before = snapshot(home)
                result = run("--heal")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("ORPHAN  other-retired.md", result.stdout)
                self.assertEqual(snapshot(home), before)

    def test_restored_document_sources_are_preserved(self):
        for kind in ("file", "directory", "symlink", "dangling-symlink"):
            with self.subTest(kind=kind), document_fixture() as (repo, home, run):
                source = repo / "claude/FABLE.md"
                if kind == "file":
                    source.write_text("restored document\n")
                elif kind == "directory":
                    source.mkdir()
                else:
                    target = repo / "restored-document"
                    if kind == "symlink":
                        target.write_text("restored document target\n")
                    source.symlink_to(target)
                before = snapshot(home)
                run("--heal")
                self.assertEqual(snapshot(home), before)

    def test_symlinked_document_ancestors_are_not_traversed(self):
        for boundary in ("destination", "source"):
            with self.subTest(boundary=boundary), document_fixture() as (repo, home, run):
                directory = home / ".claude" if boundary == "destination" else repo / "claude"
                external = home.parent / "external"
                directory.rename(external)
                directory.symlink_to(external)
                before_home, before_external = snapshot(home), snapshot(external)
                run("--heal")
                self.assertEqual(snapshot(home), before_home)
                self.assertEqual(snapshot(external), before_external)

    def test_document_restored_during_capture_keeps_the_link(self):
        with document_fixture() as (repo, home, _):
            helper = load_retirement_helper(repo)
            destination, source = home / ".claude/FABLE.md", repo / "claude/FABLE.md"
            rename = os.rename

            def capture_then_restore_document(*args, **kwargs):
                rename(*args, **kwargs)
                source.write_text("restored document\n")

            with patch.object(helper.os, "rename", side_effect=capture_then_restore_document):
                result = helper.retire(str(destination), str(source), str(source))
            self.assertEqual(result, 1)
            self.assertEqual(os.readlink(destination), str(source))
            self.assertEqual(destination.read_text(), "restored document\n")
            self.assertEqual(list(destination.parent.glob(".retired-skill-*")), [])


class RetirementTests(unittest.TestCase):
    def test_install_executable_policy_does_not_dirty_helper(self):
        with fixture("claude") as (repo, _, _):
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "core.fileMode", "true"], check=True)
            helper = repo / "claude/scripts/retired-skill-links.sh"
            subprocess.run(["git", "-C", str(repo), "add", str(helper)], check=True)
            enumeration = subprocess.run(
                ["bash", "-c", 'source "$1/lib-symlinks.sh"; symlink_enumerate "$1/claude" "$1/destination"',
                 "mode-test", str(repo)], capture_output=True, text=True, check=True,
            )
            for line in enumeration.stdout.splitlines():
                source, _, _, flags = line.split("\t")
                if flags == "executable":
                    path = Path(source)
                    path.chmod(path.stat().st_mode | 0o111)
            result = subprocess.run(["git", "-C", str(repo), "diff", "--exit-code", "--", str(helper)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_relative_arguments_are_preserved_without_hanging(self):
        for relative in ["destination", "source", "bundle"]:
            with self.subTest(relative=relative), fixture("claude") as (repo, home, _):
                destination = home / LINKS["claude"][0][0]
                source = str(repo / LINKS["claude"][0][1])
                bundle = str(repo / "claude/skills/fable-mode")
                candidate = str(destination)
                if relative == "destination":
                    candidate = os.path.relpath(destination, home.parent)
                elif relative == "source":
                    source = "missing-source"
                    destination.unlink()
                    destination.symlink_to(source)
                else:
                    bundle = "missing-bundle"
                try:
                    result = subprocess.run(
                        ["bash", "-c", 'source "$1"; HEAL=1; FIXED=0; ERRORS=0; '
                         'green() { :; }; red() { :; }; heal_retired_skill_link "$2" "$3" "$4"',
                         "relative-test", str(repo / "claude/scripts/retired-skill-links.sh"),
                         candidate, source, bundle], cwd=home.parent,
                        text=True, capture_output=True, timeout=3,
                    )
                except subprocess.TimeoutExpired:
                    self.fail(f"helper hung with relative {relative}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(destination.is_symlink())

    def test_relative_home_does_not_hang_or_retire_links(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (repo, home, _):
                try:
                    subprocess.run(
                        ["bash", str(repo / f"check-{runtime}.sh"), "--heal", "--strict"],
                        env={**os.environ, "HOME": home.name}, cwd=home.parent,
                        capture_output=True, text=True, timeout=3,
                    )
                except subprocess.TimeoutExpired:
                    self.fail(f"{runtime} checker hung with relative HOME")
                for dest, _ in LINKS[runtime]:
                    self.assertTrue((home / dest).is_symlink())

    def test_healthy_claude_symlink_root_keeps_existing_audit_behavior(self):
        for flags in [("--strict",), ("--heal", "--strict")]:
            with self.subTest(flags=flags), fixture("claude") as (_, home, run):
                for dest, _ in LINKS["claude"]:
                    (home / dest).unlink()
                destination = home / ".claude"
                external = home.parent / "external"
                destination.rename(external)
                destination.symlink_to(external)
                before = snapshot(external)
                result = run(*flags)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(snapshot(external), before)

    def test_claude_missing_links_are_not_healed_through_symlinked_root(self):
        with fixture("claude") as (_, home, run):
            destination = home / ".claude"
            external = home.parent / "external"
            destination.rename(external)
            destination.symlink_to(external)
            (external / "scripts/retired-skill-links.sh").unlink()
            before = snapshot(external)
            run("--heal", "--strict")
            self.assertEqual(snapshot(external), before)

    def test_strict_reports_without_changing_links(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (_, home, run):
                before = snapshot(home)
                result = run("--strict")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("ORPHAN", result.stdout)
                self.assertEqual(snapshot(home), before)

    def test_heal_removes_exact_retired_links_and_is_idempotent(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (_, home, run):
                result = run("--heal", "--strict")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for dest, _ in LINKS[runtime]:
                    self.assertFalse((home / dest).is_symlink(), dest)
                after = snapshot(home)
                result = run("--heal", "--strict")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(snapshot(home), after)

    def test_custom_files_directories_and_unknown_links_survive(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (repo, home, run):
                destination = home / LINKS[runtime][0][0]
                if destination.name == "SKILL.md":
                    destination = destination.parent
                else:
                    destination.unlink()
                    destination.mkdir()
                sentinel = destination / ".ignored-private" / "notes.txt"
                sentinel.parent.mkdir()
                sentinel.write_text("untracked operator content\n")
                unknown = destination / "custom-link"
                unknown.symlink_to(repo / "agents/skills/fable-mode/unknown.md")
                before = snapshot(destination)
                run("--heal", "--strict")
                after = snapshot(destination)
                for name, entry in before.items():
                    if name not in ["SKILL.md", "agents/openai.yaml"]:
                        self.assertEqual(after.get(name), entry, name)

    def test_unexpected_targets_are_preserved(self):
        for runtime in LINKS:
            for target in ["other/skills/fable-mode", "agents/skills/fable-mode-extra", "antigravity/skills/fable-mode"]:
                with self.subTest(runtime=runtime, target=target), fixture(runtime) as (repo, home, run):
                    destination = home / LINKS[runtime][0][0]
                    destination.unlink()
                    destination.symlink_to(repo / target)
                    run("--heal", "--strict")
                    self.assertTrue(destination.is_symlink())
                    self.assertEqual(os.readlink(destination), str(repo / target))

    def test_target_trailing_newlines_are_not_stripped_before_comparison(self):
        for runtime in LINKS:
            for suffix in ["\n", "\n\n"]:
                with self.subTest(runtime=runtime, suffix=suffix), fixture(runtime) as (repo, home, run):
                    for dest, source in LINKS[runtime]:
                        link = home / dest
                        link.unlink()
                        link.symlink_to(str(repo / source) + suffix)
                    before = snapshot(home)
                    result = run("--heal", "--strict")
                    self.assertEqual(snapshot(home), before)
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_failed_readlink_cannot_authorize_retirement(self):
        with fixture("claude") as (repo, home, _):
            link = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; HEAL=1; FIXED=0; ERRORS=0; '
                 'green() { :; }; red() { :; }; '
                 'readlink() { printf "%s\\n" "$READLINK_TEST_TARGET"; return 1; }; '
                 'heal_retired_skill_link "$2" "$3" "$4"',
                 "readlink-failure-test", str(repo / "claude/scripts/retired-skill-links.sh"),
                 str(link), str(source), str(source.parent)],
                env={**os.environ, "READLINK_TEST_TARGET": str(source)},
                text=True, capture_output=True, timeout=3,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(link.is_symlink())

    def test_newline_named_symlink_ancestors_are_not_traversed(self):
        for runtime in LINKS:
            for boundary in ["source", "home"]:
                with self.subTest(runtime=runtime, boundary=boundary), fixture(runtime) as (repo, home, _):
                    command_repo, command_home = repo, home
                    alias = repo.parent / (boundary + "\n")
                    if boundary == "home":
                        alias.symlink_to(home)
                        command_home = alias
                    else:
                        alias.symlink_to(repo.parent)
                        command_repo = alias / repo.name
                        for dest, entry in snapshot(home).items():
                            if entry[0] == "link":
                                path = home / dest
                                path.unlink()
                                path.symlink_to(str(command_repo) + entry[1][len(str(repo)):])
                    before = snapshot(home)
                    subprocess.run(
                        ["bash", str(command_repo / f"check-{runtime}.sh"), "--heal", "--strict"],
                        env={**os.environ, "HOME": str(command_home),
                             "CODEX_MEMORY_REPO": str(repo.parent / "no-memory"),
                             "AGY_MEMORY_REPO": str(repo.parent / "no-memory")},
                        text=True, capture_output=True, timeout=3,
                    )
                    self.assertEqual(snapshot(home), before)

    def test_reintroduced_sources_are_not_retired(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (repo, home, run):
                source = repo / LINKS[runtime][0][1]
                if source.suffix:
                    source.parent.mkdir(parents=True)
                    source.write_text("Restored source\n")
                else:
                    source.mkdir(parents=True)
                run("--heal", "--strict")
                for dest, _ in LINKS[runtime]:
                    self.assertTrue((home / dest).is_symlink())

    def test_real_files_at_historical_destinations_survive(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (_, home, run):
                destination = home / LINKS[runtime][0][0]
                destination.unlink()
                destination.write_text("operator-owned replacement\n")
                run("--heal", "--strict")
                self.assertFalse(destination.is_symlink())
                self.assertEqual(destination.read_text(), "operator-owned replacement\n")

    def test_real_file_replacing_checked_symlink_survives(self):
        with fixture("claude") as (repo, home, _):
            destination = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            replacement = home / "operator-replacement"
            replacement.write_text("operator-owned replacement during readlink\n")
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; HEAL=1; FIXED=0; ERRORS=0; '
                 'green() { printf "%s\\n" "$*"; }; red() { printf "%s\\n" "$*"; }; '
                 'readlink() { command readlink "$1"; mv -- "$REPLACEMENT" "$1"; }; '
                 'heal_retired_skill_link "$2" "$3" "$4"',
                 "replacement-test", str(repo / "claude/scripts/retired-skill-links.sh"),
                 str(destination), str(source), str(source.parent)],
                env={**os.environ, "REPLACEMENT": str(replacement)},
                capture_output=True, text=True, timeout=3,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(destination.is_file(), result.stdout)
            self.assertEqual(destination.read_text(), "operator-owned replacement during readlink\n")
            self.assertNotIn("RETIRED", result.stdout)

    def test_replacement_at_capture_is_restored(self):
        for kind in ("file", "symlink"):
            with self.subTest(kind=kind), fixture("claude") as (repo, home, _):
                helper = load_retirement_helper(repo)
                destination = home / LINKS["claude"][0][0]
                source = repo / LINKS["claude"][0][1]
                replacement = home / "replacement"
                if kind == "file":
                    replacement.write_text("replacement at capture\n")
                else:
                    replacement.symlink_to("operator-selected-target")
                rename = os.rename

                def replace_then_capture(*args, **kwargs):
                    os.replace(replacement, destination)
                    rename(*args, **kwargs)

                with patch.object(helper.os, "rename", side_effect=replace_then_capture):
                    result = helper.retire(str(destination), str(source), str(source.parent))
                self.assertEqual(result, 1)
                if kind == "file":
                    self.assertEqual(destination.read_text(), "replacement at capture\n")
                else:
                    self.assertEqual(os.readlink(destination), "operator-selected-target")
                self.assertEqual(list(destination.parent.glob(".retired-skill-*")), [])

    def test_restore_collision_preserves_both_files_and_reports_recovery(self):
        with fixture("claude") as (repo, home, _):
            helper = load_retirement_helper(repo)
            destination = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            replacement = home / "replacement"
            replacement.write_text("first replacement\n")
            rename = os.rename

            def replace_capture_then_replace_again(*args, **kwargs):
                os.replace(replacement, destination)
                rename(*args, **kwargs)
                destination.write_text("second replacement\n")

            output = io.StringIO()
            with patch.object(helper.os, "rename", side_effect=replace_capture_then_replace_again), redirect_stdout(output):
                result = helper.retire(str(destination), str(source), str(source.parent))
            self.assertEqual(result, 2)
            self.assertEqual(destination.read_text(), "second replacement\n")
            retained = list(destination.parent.glob(".retired-skill-*/entry"))
            self.assertEqual(len(retained), 1)
            self.assertEqual(retained[0].read_text(), "first replacement\n")
            self.assertEqual(retained[0].parent.stat().st_mode & 0o777, 0o700)
            self.assertIn(str(retained[0]), output.getvalue())

    def test_directory_replacing_link_is_retained_with_its_contents(self):
        with fixture("claude") as (repo, home, _):
            helper = load_retirement_helper(repo)
            destination = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            rename = os.rename

            def replace_with_directory_then_capture(*args, **kwargs):
                destination.unlink()
                destination.mkdir()
                (destination / "private.txt").write_text("operator directory content\n")
                rename(*args, **kwargs)

            output = io.StringIO()
            with patch.object(helper.os, "rename", side_effect=replace_with_directory_then_capture), redirect_stdout(output):
                result = helper.retire(str(destination), str(source), str(source.parent))
            self.assertEqual(result, 2)
            retained = list(destination.parent.glob(".retired-skill-*/entry"))
            self.assertEqual(len(retained), 1)
            self.assertEqual((retained[0] / "private.txt").read_text(), "operator directory content\n")
            self.assertIn(str(retained[0]), output.getvalue())

    def test_parent_replacement_cannot_redirect_capture(self):
        with fixture("claude") as (repo, home, _):
            helper = load_retirement_helper(repo)
            destination = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            external = home / "external"
            external.mkdir()
            (external / destination.name).write_text("external operator file\n")
            original = home / "original-parent"
            rename = os.rename

            def replace_parent_then_capture(*args, **kwargs):
                rename(destination.parent, original)
                destination.parent.symlink_to(external)
                rename(*args, **kwargs)

            with patch.object(helper.os, "rename", side_effect=replace_parent_then_capture):
                result = helper.retire(str(destination), str(source), str(source.parent))
            self.assertEqual(result, 0)
            self.assertEqual(destination.read_text(), "external operator file\n")
            self.assertEqual(list(original.iterdir()), [])

    def test_bundle_restored_during_capture_keeps_the_link(self):
        with fixture("claude") as (repo, home, _):
            helper = load_retirement_helper(repo)
            destination = home / LINKS["claude"][0][0]
            source = repo / LINKS["claude"][0][1]
            rename = os.rename

            def capture_then_restore_bundle(*args, **kwargs):
                rename(*args, **kwargs)
                source.parent.mkdir(parents=True)
                source.write_text("restored source\n")

            with patch.object(helper.os, "rename", side_effect=capture_then_restore_bundle):
                result = helper.retire(str(destination), str(source), str(source.parent))
            self.assertEqual(result, 1)
            self.assertEqual(os.readlink(destination), str(source))
            self.assertEqual(destination.read_text(), "restored source\n")
            self.assertEqual(list(destination.parent.glob(".retired-skill-*")), [])

    def test_symlinked_source_roots_never_trigger_retirement(self):
        for runtime in LINKS:
            with self.subTest(runtime=runtime), fixture(runtime) as (repo, home, run):
                source_root = repo / ("claude/skills" if runtime == "claude" else "agents/skills")
                external = repo / "external-skills"
                external.mkdir()
                source_root.parent.mkdir(parents=True, exist_ok=True)
                source_root.symlink_to(external)
                run("--heal", "--strict")
                for dest, _ in LINKS[runtime]:
                    self.assertTrue((home / dest).is_symlink())

    def test_inaccessible_source_ancestors_are_not_treated_as_absent(self):
        for runtime in LINKS:
            for restored in [False, True]:
                with self.subTest(runtime=runtime, restored=restored), fixture(runtime) as (repo, home, run):
                    source_root = repo / ("claude/skills" if runtime == "claude" else "agents/skills")
                    source_root.mkdir(parents=True)
                    if restored:
                        bundle = source_root / "fable-mode"
                        bundle.mkdir()
                        (bundle / "SKILL.md").write_text("restored operator source\n")
                    source_root.chmod(0)
                    try:
                        if os.access(source_root, os.X_OK):
                            self.skipTest("permission-denied fixture requires an unprivileged user")
                        result = run("--heal", "--strict")
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        for dest, _ in LINKS[runtime]:
                            self.assertTrue((home / dest).is_symlink(), dest)
                    finally:
                        source_root.chmod(0o700)
                    if restored:
                        self.assertEqual((bundle / "SKILL.md").read_text(), "restored operator source\n")

    def test_symlinked_ancestors_are_never_traversed_for_healing(self):
        roots = {
            "claude": [".claude", ".claude/skills", ".claude/skills/fable-mode"],
            "codex": [".codex", ".codex/skills", ".codex/skills/fable-mode", ".agents", ".agents/skills"],
            "antigravity": [".gemini", ".gemini/config", ".gemini/config/skills"],
        }
        for runtime, paths in roots.items():
            for path in paths:
                with self.subTest(runtime=runtime, path=path), fixture(runtime) as (_, home, run):
                    destination = home / path
                    external = home.parent / "external"
                    destination.rename(external)
                    destination.symlink_to(external)
                    before = snapshot(external)
                    run("--heal", "--strict")
                    self.assertEqual(snapshot(external), before)
                    self.assertTrue(destination.is_symlink())


if __name__ == "__main__":
    unittest.main()
