#!/usr/bin/env python3
"""Run real health checkers against isolated pre-retirement installations."""

from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


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


@contextmanager
def fixture(runtime):
    with tempfile.TemporaryDirectory(prefix="retired-skill-test-") as temp:
        base = Path(temp)
        repo, home = base / "dotfiles", base / "home"
        repo.mkdir()
        home.mkdir()
        for name in [f"check-{runtime}.sh", "lib-checks.sh", "lib-symlinks.sh"]:
            shutil.copy2(REPO / name, repo / name)
        helper = Path("claude/scripts/retired-skill-links.sh")
        if (REPO / helper).exists():
            (repo / helper).parent.mkdir(parents=True)
            shutil.copy2(REPO / helper, repo / helper)
        if runtime == "claude":
            (repo / "claude").mkdir(exist_ok=True)
            (repo / "claude/nolink.txt").write_text("nolink.txt\n")
            (home / ".claude").mkdir()
            if (repo / helper).exists():
                link_to(home / ".claude/scripts/retired-skill-links.sh", repo / helper)
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


class RetirementTests(unittest.TestCase):
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
