#!/usr/bin/env python3
"""Guard workflow semantics while allowing runtime-specific prose and tools."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / 'claude/scripts/check-workflow-invariants.py'


class WorkflowInvariantTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'agents').mkdir()
        (self.root / 'agents/skill-coverage.tsv').write_text('simplify\tshared\n')
        self.contract = dict(version=1, workflows={'simplify': {
            'preserve-behavior': dict(description='Simplification preserves behavior.',
                claude=[r'preserve observable behavior'], agents=[r'keep behavior unchanged']),
            'verification-required': dict(description='Run the relevant verification after edits.',
                claude=[r'run the project tests'], agents=[r'run focused checks'])}})
        self.write_skill('claude', 'Use the native edit tool; preserve observable behavior.\nRun the project tests.\n')
        self.write_skill('agents', 'Use available tools and keep behavior unchanged.\nRun focused checks.\nExtra runtime guidance is allowed.\n')

    def write_skill(self, side, text):
        path = self.root / side / 'skills/simplify/SKILL.md'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_check(self):
        (self.root / 'agents/workflow-invariants.json').write_text(json.dumps(self.contract))
        return subprocess.run([sys.executable, str(CHECKER), '--repo', str(self.root)],
                              text=True, capture_output=True, timeout=10)

    def assert_failure(self, fragment):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(fragment, result.stdout + result.stderr)

    def test_different_runtime_text_and_extra_behavior_pass(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_removal_names_workflow_runtime_and_invariant(self):
        for side, runtime in [('claude', 'claude'), ('agents', 'codex')]:
            with self.subTest(runtime=runtime):
                path = self.root / side / 'skills/simplify/SKILL.md'
                original = path.read_text()
                path.write_text('\n'.join(original.splitlines()[1:]))
                self.assert_failure('simplify/' + runtime + ': missing invariant preserve-behavior')
                path.write_text(original)

    def test_one_removed_verification_requirement_fails(self):
        self.write_skill('claude', 'Preserve observable behavior.\n')
        self.assert_failure('simplify/claude: missing invariant verification-required')

    def test_frontmatter_or_comments_do_not_replace_body_instruction(self):
        self.write_skill('claude', '---\ndescription: Preserve observable behavior.\n---\n'
                         '<!-- Preserve observable behavior. -->\nRun the project tests.\n')
        self.assert_failure('simplify/claude: missing invariant preserve-behavior')

    def test_runtime_override_is_checked(self):
        self.write_skill('antigravity', 'Run focused checks.\n')
        self.assert_failure('simplify/antigravity: missing invariant preserve-behavior')

    def test_present_override_bundle_cannot_fall_back_after_entrypoint_removal(self):
        for runtime in ('codex', 'antigravity'):
            with self.subTest(runtime=runtime):
                override = self.write_skill(runtime, 'No shared invariants here.\n')
                self.assert_failure('simplify/' + runtime + ': missing invariant preserve-behavior')
                (override.parent / 'reference.md').write_text('Runtime-specific support material.\n')
                override.unlink()
                self.assert_failure('simplify/' + runtime + ': skill body missing or unreadable')

    def test_empty_override_bundle_is_not_absent(self):
        bundle = self.root / 'antigravity/skills/simplify'
        bundle.mkdir(parents=True)
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')

    def test_dangling_override_bundle_is_not_absent(self):
        bundle = self.root / 'antigravity/skills/simplify'
        bundle.parent.mkdir(parents=True)
        bundle.symlink_to(self.root / 'missing-bundle', target_is_directory=True)
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')

    def test_override_bundle_cannot_be_a_regular_file(self):
        bundle = self.root / 'antigravity/skills/simplify'
        bundle.parent.mkdir(parents=True)
        bundle.write_text('This path is not a skill bundle.\n')
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')

    def test_dangling_override_entrypoint_is_rejected(self):
        entrypoint = self.write_skill('antigravity', 'Unused.\n')
        entrypoint.unlink()
        entrypoint.symlink_to(entrypoint.parent / 'missing.md')
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')

    @unittest.skipIf(os.geteuid() == 0, 'root can read mode-zero skill bundles')
    def test_unreadable_override_bundle_or_entrypoint_is_rejected(self):
        entrypoint = self.write_skill('antigravity', 'Keep behavior unchanged. Run focused checks.\n')
        for path in (entrypoint.parent, entrypoint):
            with self.subTest(path=path.name):
                mode = path.stat().st_mode & 0o777
                path.chmod(0)
                try:
                    self.assert_failure('simplify/antigravity: skill body missing or unreadable')
                finally:
                    path.chmod(mode)

    def test_invalid_override_entrypoint_is_rejected(self):
        entrypoint = self.write_skill('antigravity', 'Unused.\n')
        entrypoint.write_bytes(b'\xff')
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')
        entrypoint.unlink()
        entrypoint.mkdir()
        self.assert_failure('simplify/antigravity: skill body missing or unreadable')

    def test_unclosed_comment_cannot_supply_instruction(self):
        self.write_skill('claude', 'Run the project tests.\n<!-- Preserve observable behavior.\n')
        self.assert_failure('simplify/claude: missing invariant preserve-behavior')

    def test_new_shared_workflow_requires_contract(self):
        with (self.root / 'agents/skill-coverage.tsv').open('a') as out:
            out.write('review\tshared\n')
        self.assert_failure('review: invariant contract missing')

    def test_deleted_or_empty_workflow_contract_fails(self):
        self.contract['workflows']['simplify'] = {}
        self.assert_failure('simplify: invariant set must be nonempty')

    def test_runtime_patterns_cannot_disappear(self):
        del self.contract['workflows']['simplify']['preserve-behavior']['claude']
        self.assert_failure('simplify: preserve-behavior: claude patterns missing')

    def test_malformed_pattern_is_named(self):
        self.contract['workflows']['simplify']['preserve-behavior']['claude'] = ['[']
        self.assert_failure('simplify: preserve-behavior: invalid claude pattern')

    def test_empty_patterns_cannot_satisfy_invariant(self):
        self.contract['workflows']['simplify']['preserve-behavior']['claude'] = ['']
        self.assert_failure('simplify: preserve-behavior: claude patterns missing')

    def test_stale_workflow_contract_fails(self):
        self.contract['workflows']['retired'] = copy.deepcopy(self.contract['workflows']['simplify'])
        self.assert_failure('retired: no shared workflow in coverage contract')


if __name__ == '__main__':
    unittest.main()
