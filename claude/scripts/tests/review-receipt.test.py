#!/usr/bin/env python3
"""Receipt fixtures exercise real Git objects without invoking a reviewer."""
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'review-receipt.py'


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        (self.repo / 'code.txt').write_text('base\n')
        self.git('add', 'code.txt')
        self.git('commit', '-qm', 'base')
        self.git('checkout', '-qb', 'feature')
        (self.repo / 'code.txt').write_text('changed\n')
        self.git('commit', '-qam', 'work')
        self.result = Path(self.tmp.name) / 'result.json'
        self.result.write_text('{"verdict":"approve","findings":[]}')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE).decode().strip()

    def run_helper(self, *args, ok=True):
        p = subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True)
        self.assertEqual(p.returncode == 0, ok, p.stdout + p.stderr)
        return p.stdout.strip()

    def begin(self, scope='committed', base='main', tier1_max_lines=None):
        policy = ('--tier1-max-lines=' + tier1_max_lines,) if tier1_max_lines is not None else ()
        return Path(self.run_helper('begin', '--repo', str(self.repo), '--base', base, '--scope', scope, '--reviewer', 'codex', *policy)) / 'snapshot.json'

    def complete(self, snapshot, outcome='passed', ok=True):
        return self.run_helper('complete', '--snapshot', str(snapshot), '--outcome', outcome, '--output', str(self.result), ok=ok)

    def check(self, ok=True, *args):
        return self.run_helper('check', '--repo', str(self.repo), '--head', self.git('rev-parse', 'HEAD'), *args, ok=ok)

    def test_symlinked_parent_cannot_export_outside_content(self):
        nested = self.repo / 'nested'
        nested.mkdir()
        (nested / 'data.txt').write_text('tracked content\n')
        self.git('add', 'nested/data.txt')
        self.git('commit', '-qm', 'nested file')
        (nested / 'data.txt').unlink()
        nested.rmdir()
        outside = Path(self.tmp.name) / 'private'
        outside.mkdir()
        (outside / 'data.txt').write_text('OUTSIDE_PRIVATE_MARKER\n')
        nested.symlink_to(outside, target_is_directory=True)
        result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', 'main', '--scope', 'uncommitted', '--reviewer', 'codex'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('symlink ancestor', result.stderr)
        self.assertNotIn('OUTSIDE_PRIVATE_MARKER', result.stdout + result.stderr)
        self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))

    def test_tracked_leaf_symlink_reviews_link_text_only(self):
        outside = Path(self.tmp.name) / 'private'
        outside.mkdir()
        for name in ('before.txt', 'after.txt'):
            (outside / name).write_text('OUTSIDE_PRIVATE_MARKER\n')
        leaf = self.repo / 'link.txt'
        leaf.symlink_to(outside / 'before.txt')
        self.git('add', 'link.txt')
        self.git('commit', '-qm', 'leaf symlink')
        leaf.unlink()
        leaf.symlink_to(outside / 'after.txt')
        snapshot = self.begin('uncommitted')
        patch = (snapshot.parent / 'diff.patch').read_text()
        self.assertIn('old mode 120000', patch)
        self.assertIn('new mode 120000', patch)
        self.assertIn('before.txt', patch)
        self.assertIn('after.txt', patch)
        self.assertNotIn('OUTSIDE_PRIVATE_MARKER', patch)

    def test_instruction_symlinks_fail_closed_in_each_scope(self):
        target = self.repo / 'local-policy.txt'
        target.write_text('local instruction target\n')
        (self.repo / '.git/info/exclude').write_text('local-policy.txt\n')
        for name in ('AGENTS.md', '.codex/config.toml', '.claude/commands/check.md'):
            alias = self.repo / name
            alias.parent.mkdir(parents=True, exist_ok=True)
            alias.symlink_to('local-policy.txt' if name == 'AGENTS.md' else target)
            self.git('add', name)
            self.git('commit', '-qm', 'instruction alias')
            for scope, base in (('committed', 'main'), ('uncommitted', 'main'), ('auto', 'main'), ('auto', 'HEAD')):
                with self.subTest(path=name, scope=scope, base=base):
                    result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', base,
                                             '--scope', scope, '--reviewer', 'codex'], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('instruction symlink targets are unsupported', result.stderr)
                    self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))
            self.git('rm', name)
            self.git('commit', '-qm', 'remove instruction alias')

    def test_deleted_parent_directory_remains_reviewable(self):
        nested = self.repo / 'nested'
        nested.mkdir()
        (nested / 'data.txt').write_text('tracked content\n')
        self.git('add', 'nested/data.txt')
        self.git('commit', '-qm', 'nested file')
        (nested / 'data.txt').unlink()
        nested.rmdir()
        snapshot = self.begin('uncommitted')
        patch = (snapshot.parent / 'diff.patch').read_text()
        self.assertIn('-tracked content', patch)
        self.assertIn('new mode missing', patch)

    def test_directory_to_file_replacement_reviews_deletion_and_addition(self):
        for path in ('nested/code.txt', 'deep/nested/code.txt'):
            child = self.repo / path
            child.parent.mkdir(parents=True)
            child.write_text('tracked child\n')
        self.git('add', 'nested/code.txt', 'deep/nested/code.txt')
        self.git('commit', '-qm', 'nested files')
        for path in ('nested/code.txt', 'deep/nested/code.txt'):
            child = self.repo / path
            child.unlink()
            child.parent.rmdir()
            replacement = self.repo / Path(path).parts[0]
            if replacement.is_dir():
                replacement.rmdir()
            replacement.write_text('replacement file\n')
        snapshot = self.begin('uncommitted')
        patch = (snapshot.parent / 'diff.patch').read_text()
        artifact = json.loads(snapshot.read_text())['artifact']
        self.assertEqual(artifact['changed_paths'], ['deep', 'deep/nested/code.txt', 'nested', 'nested/code.txt'])
        self.assertEqual(patch.count('-tracked child'), 2)
        self.assertEqual(patch.count('+replacement file'), 2)
        self.complete(snapshot)

    def test_file_to_directory_replacement_reviews_deletion_and_children(self):
        replaced = self.repo / 'code.txt'
        replaced.unlink()
        replaced.mkdir()
        (replaced / 'child.txt').write_text('new child\n')
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.git('add', 'code.txt')
                snapshot = self.begin('uncommitted')
                artifact = json.loads(snapshot.read_text())['artifact']
                self.assertEqual(artifact['changed_paths'], ['code.txt', 'code.txt/child.txt'])
                patch = (snapshot.parent / 'diff.patch').read_text()
                self.assertIn('-changed', patch)
                self.assertIn('+new child', patch)
                self.complete(snapshot)

    def test_file_replaced_by_empty_directory_reviews_deletion(self):
        replaced = self.repo / 'code.txt'
        replaced.unlink()
        replaced.mkdir()
        snapshot = self.begin('uncommitted')
        artifact = json.loads(snapshot.read_text())['artifact']
        self.assertEqual(artifact['changed_paths'], ['code.txt'])
        self.assertIn('-changed', (snapshot.parent / 'diff.patch').read_text())

    def test_untracked_nested_repository_is_not_silently_treated_as_missing(self):
        nested = self.repo / 'nested'
        nested.mkdir()
        self.git('init', '-q', str(nested))
        (nested / 'code.txt').write_text('nested implementation\n')
        self.run_helper('begin', '--repo', str(self.repo), '--base', 'main', '--scope', 'uncommitted', '--reviewer', 'codex', ok=False)

    def test_staged_gitlink_replacing_tracked_file_is_rejected(self):
        replaced = self.repo / 'code.txt'
        replaced.unlink()
        replaced.mkdir()
        self.git('init', '-q', str(replaced))
        self.git('-C', str(replaced), 'config', 'user.name', 'fixture')
        self.git('-C', str(replaced), 'config', 'user.email', 'fixture@example.test')
        (replaced / 'nested.py').write_text('nested implementation\n')
        self.git('-C', str(replaced), 'add', 'nested.py')
        self.git('-C', str(replaced), 'commit', '-qm', 'nested implementation')
        self.git('add', 'code.txt')
        self.assertTrue(self.git('ls-files', '--stage', 'code.txt').startswith('160000 '))
        for scope in ('committed', 'uncommitted', 'auto'):
            with self.subTest(scope=scope):
                result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', 'main',
                                         '--scope', scope, '--reviewer', 'codex'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('submodule snapshots are unsupported', result.stderr)
                self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))

    def test_base_only_gitlink_deletion_cannot_receive_committed_review(self):
        self.git('update-index', '--add', '--cacheinfo', '160000', self.git('rev-parse', 'HEAD'), 'vendor')
        self.git('commit', '-qm', 'base gitlink')
        self.git('update-ref', 'refs/heads/main', 'HEAD')
        self.git('update-index', '--force-remove', 'vendor')
        self.git('commit', '-qm', 'delete gitlink')
        for ignore in ('none', 'all'):
            self.git('config', 'diff.ignoreSubmodules', ignore)
            for scope in ('committed', 'auto'):
                with self.subTest(ignore_submodules=ignore, scope=scope):
                    result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', 'main',
                                             '--scope', scope, '--reviewer', 'codex'], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('submodule snapshots are unsupported', result.stderr)
                    self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))
        (self.repo / 'code.txt').write_text('unrelated workspace edit\n')
        snapshot = self.begin('uncommitted')
        self.assertEqual(json.loads(snapshot.read_text())['artifact']['changed_paths'], ['code.txt'])
        self.assertIn('+unrelated workspace edit', (snapshot.parent / 'diff.patch').read_text())
        self.complete(snapshot)

    def test_uncommitted_review_does_not_require_related_base_history(self):
        unrelated = self.git('commit-tree', self.git('rev-parse', 'HEAD^{tree}'), '-m', 'unrelated root')
        self.git('update-ref', 'refs/heads/unrelated', unrelated)
        (self.repo / 'code.txt').write_text('workspace change\n')
        snapshot = self.begin('uncommitted', base='unrelated')
        artifact = json.loads(snapshot.read_text())['artifact']
        self.assertEqual(artifact['base']['commit'], unrelated)
        self.assertIsNone(artifact['base']['merge_base'])
        patch = (snapshot.parent / 'diff.patch').read_text()
        self.assertIn('-changed', patch)
        self.assertIn('+workspace change', patch)
        self.complete(snapshot)

    def test_committed_review_rejects_unrelated_base_history(self):
        unrelated = self.git('commit-tree', self.git('rev-parse', 'HEAD^{tree}'), '-m', 'unrelated root')
        self.git('update-ref', 'refs/heads/unrelated', unrelated)
        self.run_helper('begin', '--repo', str(self.repo), '--base', 'unrelated', '--scope', 'committed', '--reviewer', 'codex', ok=False)

    def test_committed_pass_is_private_and_bound(self):
        snapshot = self.begin()
        self.complete(snapshot)
        self.check()
        receipt_path = self.repo / '.git/review-receipts/codex.json'
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(stat.S_IMODE(receipt_path.stat().st_mode), 0o600)
        self.assertEqual(receipt['artifact']['head'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(receipt['artifact']['base']['commit'], self.git('rev-parse', 'main'))
        self.assertIsNone(receipt['reviewer']['observed_model'])
        self.assertEqual(receipt['completion']['status'], 'completed')
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_missing_malformed_and_uncommitted_receipts_block(self):
        self.check(False)
        snapshot = self.begin('uncommitted')
        self.complete(snapshot)
        self.check(False)
        (self.repo / '.git/review-receipts/codex.json').write_text('{broken')
        self.check(False)

    def test_stale_outgoing_head_and_reviewer_mismatch_block(self):
        self.complete(self.begin())
        self.check(False, '--reviewer', 'antigravity')
        self.run_helper('check', '--repo', str(self.repo), '--head', self.git('rev-parse', 'main'), ok=False)
        self.git('commit', '--allow-empty', '-qm', 'new head')
        self.check(False)

    def test_changes_before_completion_block(self):
        for change in ('head', 'base', 'index', 'worktree', 'untracked'):
            with self.subTest(change=change):
                snapshot = self.begin()
                if change == 'head':
                    self.git('commit', '--allow-empty', '-qm', 'concurrent')
                elif change == 'base':
                    self.git('update-ref', 'refs/heads/main', 'HEAD')
                elif change == 'index':
                    (self.repo / 'code.txt').write_text('staged\n')
                    self.git('add', 'code.txt')
                elif change == 'worktree':
                    (self.repo / 'code.txt').write_text('unstaged\n')
                else:
                    (self.repo / 'new.txt').write_text('untracked\n')
                self.complete(snapshot, ok=False)

    def test_change_after_completion_blocks(self):
        self.complete(self.begin())
        (self.repo / 'code.txt').write_text('later\n')
        self.check(False)

    def test_changed_diff_and_result_cannot_be_reused(self):
        snapshot = self.begin()
        (snapshot.parent / 'diff.patch').write_text('different target')
        self.complete(snapshot, ok=False)
        snapshot = self.begin()
        self.result.write_text('')
        self.complete(snapshot, ok=False)

    def test_ignored_application_hooks_allow_committed_review(self):
        (self.repo / '.git/info/exclude').write_text('node_modules/\ndist/\nsrc/\n')
        for name in ('node_modules/example/hooks/useThing.js', 'node_modules/example/webhooks/client.js',
                     'dist/hooks/useThing.js', 'src/hooks/useThing.js'):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('export function useThing() {}\n')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.complete(self.begin())
        self.check()

    def test_dirty_ignored_instruction_blocks_committed_capture(self):
        for name in ('AGENTS.md', '.codex/config.toml', '.claude/settings.json', '.gemini/settings.json',
                     'claude/hooks/pre-push.sh', 'githooks/pre-push', '.githooks/pre-push',
                     'node_modules/example/.codex/config.toml', 'node_modules/example/AGENTS.md'):
            with self.subTest(path=name):
                (self.repo / '.git/info/exclude').write_text(name + '\n')
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('local instruction fixture\n')
                self.run_helper('begin', '--repo', str(self.repo), '--base', 'main', '--scope', 'committed', '--reviewer', 'codex', ok=False)
                path.unlink()

    def test_ignored_instructions_are_in_uncommitted_review_and_auto_fallback(self):
        self.git('checkout', '-B', 'feature', 'main')
        (self.repo / '.git/info/exclude').write_text('AGENTS.md\n.codex/\n')
        (self.repo / 'AGENTS.md').write_text('AGENT_INSTRUCTION_MARKER\n')
        (self.repo / '.codex').mkdir()
        (self.repo / '.codex/config.toml').write_text('CODEX_CONFIG_MARKER\n')
        for scope in ('uncommitted', 'auto'):
            with self.subTest(scope=scope):
                snapshot = self.begin(scope)
                artifact = json.loads(snapshot.read_text())['artifact']
                self.assertEqual(artifact['scope'], 'uncommitted')
                self.assertEqual(artifact['changed_paths'], ['.codex/config.toml', 'AGENTS.md'])
                patch = (snapshot.parent / 'diff.patch').read_text()
                self.assertIn('+AGENT_INSTRUCTION_MARKER', patch)
                self.assertIn('+CODEX_CONFIG_MARKER', patch)
                self.complete(snapshot, 'no-diff', ok=False)
                self.complete(snapshot)

    def test_ignored_agent_credentials_and_state_are_not_review_inputs(self):
        private_paths = ('.codex/auth.json', '.codex/.credentials.json', '.codex/state_5.sqlite-wal',
                         '.codex/sessions/run.jsonl', '.claude/.credentials.json', '.claude/projects/run.jsonl',
                         '.gemini/oauth_creds.json', '.gemini/antigravity-cli/brain/transcript.jsonl',
                         '.agents/codex/auth.json', '.antigravity/.credentials.json', 'codex/auth.json', 'antigravity/auth.json')
        (self.repo / '.git/info/exclude').write_text('\n'.join(private_paths) + '\n')
        for name in private_paths:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('SYNTHETIC_PRIVATE_STATE_MARKER\n')
        for scope in ('committed', 'uncommitted', 'auto'):
            with self.subTest(scope=scope):
                snapshot = self.begin(scope)
                self.assertNotIn('SYNTHETIC_PRIVATE_STATE_MARKER', (snapshot.parent / 'diff.patch').read_text())
                self.assertFalse(set(private_paths) & set(json.loads(snapshot.read_text())['artifact']['changed_paths']))
                self.complete(snapshot)

    def test_runtime_cache_keeps_named_instructions_visible(self):
        (self.repo / '.git/info/exclude').write_text('.codex/cache/\n')
        cache = self.repo / '.codex/cache'
        cache.mkdir(parents=True)
        (cache / 'state.json').write_text('SYNTHETIC_PRIVATE_CACHE_MARKER\n')
        (cache / 'AGENTS.md').write_text('CACHE_INSTRUCTION_MARKER\n')
        snapshot = self.begin('uncommitted')
        patch = (snapshot.parent / 'diff.patch').read_text()
        self.assertIn('+CACHE_INSTRUCTION_MARKER', patch)
        self.assertNotIn('SYNTHETIC_PRIVATE_CACHE_MARKER', patch)
        self.assertEqual(json.loads(snapshot.read_text())['artifact']['changed_paths'], ['.codex/cache/AGENTS.md'])

    def test_explicit_agent_credentials_block_before_patch_generation(self):
        for name in ('.codex/auth.json', '.claude/.credentials.json', '.gemini/oauth_creds.json',
                     '.agents/codex/auth.json', '.antigravity/.credentials.json', 'codex/auth.json', 'antigravity/auth.json'):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('SYNTHETIC_CREDENTIAL_MARKER\n')
            for staged in (False, True):
                if staged:
                    self.git('add', name)
                for scope in ('committed', 'uncommitted', 'auto'):
                    with self.subTest(path=name, staged=staged, scope=scope):
                        result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', 'main',
                                                 '--scope', scope, '--reviewer', 'codex'], capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn('private agent runtime data', result.stderr)
                        self.assertNotIn('SYNTHETIC_CREDENTIAL_MARKER', result.stdout + result.stderr)
                        self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))
            self.git('rm', '--cached', name)
            path.unlink()

    def test_committed_credential_deletions_and_renames_block_before_old_blob_read(self):
        credential = self.repo / '.codex/auth.json'
        credential.parent.mkdir()
        credential.write_text('SYNTHETIC_OLD_CREDENTIAL_MARKER\n')
        self.git('add', '.codex/auth.json')
        self.git('commit', '-qm', 'old credential fixture')
        self.git('update-ref', 'refs/heads/main', 'HEAD')
        for operation in ('delete', 'rename'):
            with self.subTest(operation=operation):
                self.git('checkout', '-B', 'feature', 'main')
                if operation == 'delete':
                    self.git('rm', '.codex/auth.json')
                else:
                    self.git('mv', '.codex/auth.json', 'notes.txt')
                self.git('commit', '-qm', operation)
                result = subprocess.run([sys.executable, str(HELPER), 'begin', '--repo', str(self.repo), '--base', 'main',
                                         '--scope', 'committed', '--reviewer', 'codex'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('private agent runtime data', result.stderr)
                self.assertNotIn('SYNTHETIC_OLD_CREDENTIAL_MARKER', result.stdout + result.stderr)
                self.assertFalse(list((self.repo / '.git/review-receipts').glob('run-*/diff.patch')))

    def test_external_diff_textconv_and_clean_filters_never_run(self):
        marker = Path(self.tmp.name) / 'EXECUTED'
        command = f'touch {marker}'
        (self.repo / '.gitattributes').write_text('*.txt diff=evil filter=evil\n')
        self.git('config', 'diff.evil.command', command)
        self.git('config', 'diff.evil.textconv', command)
        self.git('config', 'filter.evil.clean', command)
        self.git('config', 'filter.evil.required', 'true')
        fsmonitor = Path(self.tmp.name) / 'fsmonitor'
        fsmonitor.write_text(f'#!/bin/sh\ntouch "{marker}"\nprintf "clock\\0"\n')
        fsmonitor.chmod(0o755)
        self.git('config', 'core.fsmonitor', str(fsmonitor))
        snapshot = self.begin()
        self.complete(snapshot)
        self.check()
        self.assertFalse(marker.exists())
        self.assertIn('+changed', (snapshot.parent / 'diff.patch').read_text())
        snapshot = self.begin('uncommitted')
        self.assertFalse(marker.exists())
        self.assertIn('.gitattributes', (snapshot.parent / 'diff.patch').read_text())

    def test_unknown_completion_and_false_exemptions_block(self):
        snapshot = self.begin()
        self.complete(snapshot, 'degraded', ok=False)
        self.complete(snapshot, 'no-diff', ok=False)
        self.complete(snapshot, 'tier-1', ok=False)

    def test_completed_receipt_malformed_nested_fields_block(self):
        self.complete(self.begin())
        path = self.repo / '.git/review-receipts/codex.json'
        original = json.loads(path.read_text())
        for key in ('artifact', 'reviewer', 'completion'):
            for invalid in (None, {}, 'wrong'):
                bad = dict(original)
                bad[key] = invalid
                path.write_text(json.dumps(bad))
                self.check(False)

    def test_no_newline_worktree_patch_keeps_both_lines(self):
        (self.repo / 'code.txt').write_text('old')
        self.git('commit', '-qam', 'no newline')
        (self.repo / 'code.txt').write_text('new')
        snapshot = self.begin('uncommitted')
        patch = (snapshot.parent / 'diff.patch').read_text()
        self.assertIn('-old\n\\ No newline at end of file\n+new', patch)

    def test_staged_instruction_deletion_blocks(self):
        (self.repo / 'AGENTS.md').write_text('instructions\n')
        self.git('add', 'AGENTS.md')
        self.git('commit', '-qm', 'instructions')
        self.git('rm', '--cached', 'AGENTS.md')
        (self.repo / '.git/info/exclude').write_text('AGENTS.md\n')
        self.run_helper('begin', '--repo', str(self.repo), '--base', 'main', '--scope', 'committed', '--reviewer', 'codex', ok=False)

    def test_missing_completion_timestamp_is_malformed(self):
        self.complete(self.begin())
        path = self.repo / '.git/review-receipts/codex.json'
        record = json.loads(path.read_text())
        del record['completion']['completed_at']
        path.write_text(json.dumps(record))
        self.check(False)

    def test_real_docs_and_filtered_exemptions_can_ship(self):
        self.git('checkout', '-B', 'feature', 'main')
        for filename, outcome in (('README.md', 'tier-1'), ('image.png', 'no-diff')):
            with self.subTest(filename=filename):
                self.git('checkout', '-B', 'feature', 'main')
                (self.repo / filename).write_text('fixture\n')
                self.git('add', filename)
                self.git('commit', '-qm', 'exempt artifact')
                self.complete(self.begin(), outcome)
                self.check()

    def test_tier1_receipt_uses_captured_configured_limit(self):
        self.git('checkout', '-B', 'feature', 'main')
        (self.repo / 'notes.md').write_text('documentation\n' * 250)
        self.git('add', 'notes.md')
        self.git('commit', '-qm', 'larger documentation change')
        self.complete(self.begin(), 'tier-1', ok=False)
        snapshot = self.begin(tier1_max_lines='0500')
        self.assertEqual(json.loads(snapshot.read_text())['policy']['tier1_max_lines'], '0500')
        self.assertEqual(json.loads(self.run_helper('classify', '--snapshot', str(snapshot)))['tier'], 1)
        self.complete(snapshot, 'tier-1')
        self.check()
        receipt_path = self.repo / '.git/review-receipts/codex.json'
        record = json.loads(receipt_path.read_text())
        for limit in ('200', 'invalid', None, [], 500):
            with self.subTest(limit=limit):
                record['policy']['tier1_max_lines'] = limit
                receipt_path.write_text(json.dumps(record))
                self.check(False)

    def test_invalid_tier1_limit_requires_full_review(self):
        self.git('checkout', '-B', 'feature', 'main')
        (self.repo / 'notes.md').write_text('documentation\n')
        self.git('add', 'notes.md')
        self.git('commit', '-qm', 'documentation change')
        snapshot = self.begin(tier1_max_lines='invalid')
        self.assertEqual(json.loads(self.run_helper('classify', '--snapshot', str(snapshot)))['tier'], 2)
        self.complete(snapshot, 'tier-1', ok=False)
        self.complete(snapshot)
        self.check()

    def test_classification_and_exemption_share_instruction_policy(self):
        for name in ('.claude/commands/check.md', '.gemini/agents/check.md', 'nested/.agents/check.md'):
            with self.subTest(path=name):
                self.git('checkout', '-B', 'feature', 'main')
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('instruction fixture\n')
                self.git('add', name)
                self.git('commit', '-qm', 'instruction change')
                snapshot = self.begin()
                classification = json.loads(self.run_helper('classify', '--snapshot', str(snapshot)))
                self.assertEqual(classification['tier'], 2)
                self.assertIsInstance(classification['reason'], str)
                self.complete(snapshot, 'tier-1', ok=False)
                self.complete(snapshot)
                self.check()

    def test_arbitrary_head_base_cannot_launder_shipping(self):
        snapshot = Path(self.run_helper('begin', '--repo', str(self.repo), '--base', 'HEAD', '--scope', 'committed', '--reviewer', 'codex')) / 'snapshot.json'
        self.complete(snapshot, 'no-diff')
        self.check(False)
        self.check(True, '--base', 'HEAD')

    def test_superseded_concurrent_run_cannot_restore_approval(self):
        first = self.begin()
        second = self.begin()
        self.complete(first, ok=False)
        self.complete(second)
        self.check()
        self.run_helper('invalidate', '--repo', str(self.repo), '--reviewer', 'codex')
        self.complete(second, ok=False)

    def test_failed_new_run_invalidates_prior_lane_receipt(self):
        self.complete(self.begin())
        self.check()
        self.begin()
        self.check(False)


if __name__ == '__main__':
    unittest.main()
