#!/usr/bin/env python3
"""Exercise capability contracts without starting runtimes or touching live config."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / 'claude/scripts/check-capability-parity.py'
CAPABILITIES = ('review', 'simplify', 'commit-pr', 'github', 'browser-runtime',
                'handoff-injection', 'formatting', 'secret-scanning',
                'notifications', 'docs-lookup', 'private-memory')
RUNTIMES = ('claude', 'codex', 'antigravity')


class CapabilityParityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'agents').mkdir()
        (self.root / 'provider.txt').write_text('Required workflow\n')
        self.home = self.root / 'home'
        self.home.mkdir()
        (self.home / 'installed.txt').write_text('Required workflow\n')
        row = dict(kind='skill', scope='required', owner='public',
                   status='advisory', provider='provider.txt',
                   compatibility_floor='Runtime can read a Markdown skill.',
                   reason='Instructions are advisory; existence does not prove execution.',
                   probe=[dict(kind='text', path='provider.txt', contains='Required workflow')],
                   live_probe=[dict(kind='text', path='installed.txt', contains='Required workflow')])
        self.manifest = dict(version=1, capabilities={
            cap: {runtime: copy.deepcopy(row) for runtime in RUNTIMES}
            for cap in CAPABILITIES})

    def run_check(self, *args):
        (self.root / 'agents/capabilities.json').write_text(json.dumps(self.manifest))
        return subprocess.run([sys.executable, str(CHECKER), '--repo', str(self.root), *args],
                              capture_output=True, text=True, timeout=10)

    def reject(self, fragment):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(fragment, result.stdout + result.stderr)

    def test_complete_public_contract_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_required_capability_cannot_disappear(self):
        del self.manifest['capabilities']['review']
        self.reject('review')

    def test_runtime_disposition_cannot_disappear(self):
        del self.manifest['capabilities']['review']['codex']
        self.reject('review/codex')

    def test_public_provider_cannot_disappear(self):
        (self.root / 'provider.txt').unlink()
        self.reject('review/claude')

    def test_public_probe_cannot_disappear(self):
        del self.manifest['capabilities']['review']['claude']['probe']
        self.reject('review/claude')

    def test_probe_catches_removed_provider_behavior(self):
        (self.root / 'provider.txt').write_text('Retired workflow\n')
        self.reject('review/claude')

    def test_empty_probe_cannot_pass(self):
        self.manifest['capabilities']['review']['claude']['probe'] = []
        self.reject('review/claude')

    def test_executable_probe_is_not_run(self):
        executable = self.root / 'bad-probe'
        marker = self.root / 'executed'
        executable.write_text('#!/bin/sh\ntouch ' + str(marker) + '\n')
        executable.chmod(0o755)
        self.manifest['capabilities']['review']['claude']['live_probe'] = [
            dict(kind='executable', name=str(executable))]
        result = self.run_check('--live-home', str(self.home))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(marker.exists())

    def test_private_optional_provider_is_not_required_in_public_ci(self):
        row = self.manifest['capabilities']['private-memory']['codex']
        row.update(owner='private', scope='optional', provider='missing-private.md',
                   probe=[dict(kind='file', path='missing-private.md')])
        self.assertEqual(self.run_check().returncode, 0)

    def test_unsupported_needs_reason_and_cannot_be_required(self):
        row = self.manifest['capabilities']['notifications']['codex']
        row.update(kind='unsupported', status='unsupported', provider=None, probe=[], live_probe=[])
        self.reject('notifications/codex')
        row.update(scope='optional', reason='No public adapter is installed.')
        self.assertEqual(self.run_check().returncode, 0)
        row['reason'] = ''
        self.reject('notifications/codex')

    def test_live_drift_and_local_additions_are_reported_without_failure(self):
        (self.home / 'installed.txt').unlink()
        skill = self.home / '.agents/skills/local-extra/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('Do local work.')
        result = self.run_check('--live-home', str(self.home))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['live'][0]['status'], 'drift')
        self.assertIn('.agents/skills/local-extra', report['local_additions'])

    def test_source_probe_cannot_escape_repository(self):
        self.manifest['capabilities']['review']['claude']['probe'][0]['path'] = '../outside'
        self.reject('review/claude')

    def test_other_bundled_skills_are_not_local_additions(self):
        source = self.root / 'agents/skills/bundled/SKILL.md'
        source.parent.mkdir(parents=True)
        source.write_text('Bundled workflow outside the capability shortlist.')
        target = self.home / '.agents/skills/bundled'
        target.parent.mkdir(parents=True)
        target.symlink_to(source.parent, target_is_directory=True)
        result = self.run_check('--live-home', str(self.home))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('.agents/skills/bundled', json.loads(result.stdout)['local_additions'])

    def test_source_symlink_cannot_escape_repository(self):
        (self.root / 'provider.txt').unlink()
        (self.root / 'provider.txt').symlink_to('/etc/passwd')
        self.reject('review/claude')

    def test_command_probe_is_rejected(self):
        self.manifest['capabilities']['review']['claude']['probe'] = [dict(kind='command', command='true')]
        self.reject('review/claude')

    def test_mcp_probe_detects_removed_server(self):
        (self.root / 'mcp.json').write_text('{"mcpServers":{}}')
        self.manifest['capabilities']['github']['antigravity']['probe'] = [
            dict(kind='json-key', path='mcp.json', key=['mcpServers', 'github'])]
        self.reject('github/antigravity')

    def test_malformed_manifest_reports_contract_error(self):
        self.manifest['capabilities']['review']['codex']['probe'] = False
        self.reject('review/codex')

    def test_invalid_enum_types_report_named_disposition(self):
        row = self.manifest['capabilities']['review']['codex']
        for field in ('kind', 'scope', 'owner', 'status'):
            with self.subTest(field=field):
                original = row[field]
                row[field] = []
                try:
                    self.reject('review/codex')
                finally:
                    row[field] = original


if __name__ == '__main__':
    unittest.main()
