#!/usr/bin/env python3
"""Exercise lifecycle decisions on real disposable Git worktrees."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'worktree-lifecycle.py'


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.worktree = self.root / 'task'
        self.remote = self.root / 'origin.git'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.run_git(self.root, 'init', '--bare', '-q', str(self.remote))
        self.run_git(self.root, 'init', '-q', '-b', 'main', str(self.repo))
        self.run_git(self.repo, 'config', 'user.name', 'Fixture')
        self.run_git(self.repo, 'config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'file').write_text('base\n')
        self.run_git(self.repo, 'add', 'file')
        self.run_git(self.repo, 'commit', '-qm', 'initial')
        self.run_git(self.repo, 'remote', 'add', 'origin', str(self.remote))
        self.run_git(self.repo, 'push', '-qu', 'origin', 'main')
        self.run_git(self.repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        self.run_git(self.repo, 'worktree', 'add', '-qb', 'topic', str(self.worktree))
        (self.worktree / 'file').write_text('feature\n')
        self.run_git(self.worktree, 'commit', '-qam', 'feature')
        self.head = self.run_git(self.worktree, 'rev-parse', 'HEAD').strip()
        self.metadata = self.root / 'pr.json'
        self.metadata.write_text(json.dumps({'state': 'OPEN', 'headRefOid': self.head,
            'baseRefName': 'main', 'mergeCommit': None, 'isCrossRepository': False}))
        (self.bin / 'gh').write_text('#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n'
            'if "api" in sys.argv: print("main")\n'
            'elif "pr" in sys.argv: print(Path(os.environ["FIXTURE_PR"]).read_text())\n'
            'elif "repo" in sys.argv: print("fixture/repo")\n'
            'else: sys.exit(2)\n')
        (self.bin / 'gh').chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_PR=str(self.metadata))
        # Scope process evidence to processes owned by this disposable fixture.
        # The real scanner still runs; unrelated protected host services cannot
        # turn every Git decision test into the same process-visibility refusal.
        self.proc = self.root / 'proc'
        self.proc.mkdir()
        self.runner = self.root / 'run-lifecycle.py'
        self.runner.write_text(
            'import importlib.util,functools,sys\nfrom pathlib import Path\n'
            f'spec=importlib.util.spec_from_file_location("lifecycle", {str(SCRIPT)!r})\n'
            'module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n'
            f'module.active_processes=functools.partial(module.active_processes, proc_root=Path({str(self.proc)!r}))\n'
            'sys.exit(module.main())\n')

    def tearDown(self):
        self.temp.cleanup()

    def run_git(self, cwd, *args):
        return subprocess.check_output(['git', '-C', str(cwd), *args], stderr=subprocess.PIPE, text=True)

    def cli(self, action, *args):
        return subprocess.run(['python3', str(self.runner), action, '--repo', str(self.repo), *args],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)

    def release(self):
        return self.cli('release', '--worktree', str(self.worktree), '--head', self.head,
                        '--owner', 'fixture-session', '--pr', '7', '--github-repo', 'fixture/repo')

    def merged(self):
        self.run_git(self.repo, 'merge', '--squash', 'topic')
        self.run_git(self.repo, 'commit', '-qm', 'integrate feature')
        self.run_git(self.repo, 'push', '-q', 'origin', 'main')
        merge = self.run_git(self.repo, 'rev-parse', 'HEAD').strip()
        self.metadata.write_text(json.dumps({'state': 'MERGED', 'headRefOid': self.head,
            'baseRefName': 'main', 'mergeCommit': {'oid': merge}, 'isCrossRepository': False}))

    def retire(self, *args):
        return self.cli('retire', '--worktree', str(self.worktree), *args)

    def test_inventory_distinguishes_unreleased_work_from_settings_drift(self):
        result = self.cli('inventory')
        self.assertEqual(result.returncode, 0, result.stderr)
        items = json.loads(result.stdout)['worktrees']
        task = next(item for item in items if item['path'] == str(self.worktree))
        self.assertEqual(task['disposition'], 'retained')
        self.assertIn('unreleased', task['reason'])
        self.assertTrue(self.worktree.exists())

    def test_inventory_root_includes_nested_worktrees_without_marking_primary_obsolete(self):
        result = subprocess.run(['python3', str(SCRIPT), 'inventory', '--root', str(self.root)],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['retained'], 1)
        self.assertEqual(data['released'], 0)
        self.assertEqual(len(data['worktrees']), 2)

    def test_hygiene_status_reports_worktrees_separately(self):
        home = self.root / 'home'
        folder = home / '.local/state/hygiene'
        folder.mkdir(parents=True)
        record = {'worktrees': [], 'retained': 2, 'released': 1}
        (folder / 'worktrees.json').write_text(json.dumps(record))
        result = subprocess.run(['bash', str(SCRIPT.parents[2] / 'hygiene-status.sh'), '--worktrees'],
            env=dict(self.env, HOME=str(home)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), record)

    def test_unreleased_and_pending_worktrees_are_preserved(self):
        self.assertNotEqual(self.retire('--apply', '--archive-dir', str(self.root / 'archive')).returncode, 0)
        self.assertEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('merged', result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_merged_worktree_requires_apply_and_archives_evidence(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        receipts = admin / 'review-receipts'
        receipts.mkdir()
        (receipts / 'evidence.json').write_text('{"review":"fixture"}\n')
        preview = self.retire()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertTrue(self.worktree.exists())
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.worktree.exists())
        archive = Path(json.loads(result.stdout)['archive'])
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertTrue((archive / 'repository.bundle').exists())
        self.assertTrue((archive / 'worktree-metadata.tar').exists())
        self.assertEqual(json.loads((archive / 'recovery.json').read_text())['head'], self.head)
        self.assertEqual(self.run_git(self.repo, 'rev-parse', 'topic').strip(), self.head)

    def test_changed_head_unique_merge_and_remote_ambiguity_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        self.run_git(self.worktree, 'merge', '--no-ff', '-qm', 'unique merge', 'main')
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HEAD', result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_dirty_ignored_untracked_and_locked_worktrees_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for kind in ('dirty', 'untracked', 'ignored', 'locked'):
            with self.subTest(kind=kind):
                if kind == 'dirty': (self.worktree / 'file').write_text('private changes')
                if kind == 'untracked':
                    self.run_git(self.repo, 'config', 'status.showUntrackedFiles', 'no')
                    (self.worktree / 'private').write_text('private')
                if kind == 'ignored':
                    (self.repo / '.git/info/exclude').write_text('private\n')
                    (self.worktree / 'private').write_text('private')
                if kind == 'locked': self.run_git(self.repo, 'worktree', 'lock', str(self.worktree))
                self.assertNotEqual(self.retire().returncode, 0)
                self.assertTrue(self.worktree.exists())
                if kind == 'dirty': self.run_git(self.worktree, 'restore', 'file')
                if kind in ('untracked', 'ignored'): (self.worktree / 'private').unlink()
                if kind == 'locked': self.run_git(self.repo, 'worktree', 'unlock', str(self.worktree))

    def test_active_process_and_unavailable_remote_evidence_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        child = subprocess.Popen(['sleep', '30'], cwd=self.worktree)
        (self.proc / str(child.pid)).symlink_to(Path('/proc') / str(child.pid), target_is_directory=True)
        try:
            result = self.retire()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('active', result.stderr)
        finally:
            child.terminate(); child.wait()
            (self.proc / str(child.pid)).unlink()
        self.run_git(self.repo, 'remote', 'set-url', 'origin', str(self.root / 'missing.git'))
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.worktree.exists())

    def test_filtered_local_bytes_are_retained_even_when_git_reports_clean(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / '.git/info/attributes').write_text('file filter=local\n')
        self.run_git(self.repo, 'config', 'filter.local.clean', "sed '/^PRIVATE_LOCAL=/d'")
        private = b'feature\nPRIVATE_LOCAL=unique\n'
        (self.worktree / 'file').write_bytes(private)
        self.run_git(self.worktree, 'add', 'file')
        self.assertEqual(self.run_git(self.worktree, 'status', '--porcelain'), '')
        self.assertNotEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.worktree / 'file').read_bytes(), private)
        self.assertFalse((self.root / 'archive').exists())

    def test_fifo_socket_and_empty_directory_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        endpoint = self.worktree / 'operator-state'
        for kind in ('fifo', 'socket', 'empty-directory'):
            with self.subTest(kind=kind):
                server = None
                if kind == 'fifo': os.mkfifo(endpoint)
                elif kind == 'socket':
                    server = socket.socket(socket.AF_UNIX)
                    server.bind(str(endpoint)); server.listen()
                else: endpoint.mkdir()
                try:
                    self.assertEqual(self.run_git(self.worktree, 'status', '--porcelain'), '')
                    self.assertNotEqual(self.release().returncode, 0)
                    result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertTrue(endpoint.exists())
                    if server is not None:
                        with socket.socket(socket.AF_UNIX) as client: client.connect(str(endpoint))
                finally:
                    if server is not None: server.close()
                    if endpoint.is_dir(): endpoint.rmdir()
                    elif endpoint.exists(): endpoint.unlink()

    def test_active_filters_are_retained_without_executing_them(self):
        marker = self.root / 'filter-executed'
        driver = self.root / 'filter.py'
        driver.write_text('import sys\nfrom pathlib import Path\n'
                         f'Path({str(marker)!r}).touch()\n'
                         'sys.stdout.buffer.write(sys.stdin.buffer.read())\n')
        (self.repo / '.git/info/attributes').write_text('file filter=local\n')
        self.run_git(self.repo, 'config', 'filter.local.clean', 'python3 ' + str(driver))
        modified = (self.worktree / 'file').stat().st_mtime_ns + 2_000_000_000
        os.utime(self.worktree / 'file', ns=(modified, modified))
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(marker.exists(), 'release executed a configured content filter')

    def test_tracked_symlinks_remain_recoverable_without_following_them(self):
        private = self.root / 'private-outside'
        private.write_text('operator content')
        (self.worktree / 'link').symlink_to('../private-outside')
        self.run_git(self.worktree, 'add', 'link')
        self.run_git(self.worktree, 'commit', '-qm', 'track a link')
        self.head = self.run_git(self.worktree, 'rev-parse', 'HEAD').strip()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(private.read_text(), 'operator content')

    def test_wrong_repository_and_stale_remote_snapshot_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / 'file').write_text('later main\n')
        self.run_git(self.repo, 'commit', '-qam', 'later main')
        self.run_git(self.repo, 'push', '-q', 'origin', 'main')
        old = json.loads(self.metadata.read_text())['mergeCommit']['oid']
        self.run_git(self.repo, 'update-ref', 'refs/remotes/origin/main', old)
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stale', result.stderr)
        self.run_git(self.repo, 'fetch', '-q', 'origin')
        (self.bin / 'gh').write_text((self.bin / 'gh').read_text().replace('print("fixture/repo")', 'print("unrelated/repo")'))
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('repository', result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_index_flags_cannot_hide_operator_changes(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for flag in ('assume-unchanged', 'skip-worktree'):
            with self.subTest(flag=flag):
                self.run_git(self.worktree, 'update-index', '--' + flag, 'file')
                (self.worktree / 'file').write_text('unique operator changes\n')
                result = self.retire()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.worktree / 'file').read_text(), 'unique operator changes\n')
                self.run_git(self.worktree, 'update-index', '--no-' + flag, 'file')
                self.run_git(self.worktree, 'restore', 'file')

    def test_detached_reflog_work_is_recoverable_from_archive(self):
        self.merged()
        self.run_git(self.worktree, 'checkout', '-q', '--detach')
        (self.worktree / 'file').write_text('unique reflog work\n')
        self.run_git(self.worktree, 'commit', '-qam', 'detached work')
        lost = self.run_git(self.worktree, 'rev-parse', 'HEAD').strip()
        self.run_git(self.worktree, 'reset', '--hard', self.head)
        self.assertEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)['archive'])
        restored = self.root / 'restored'
        self.run_git(self.root, 'clone', '-q', str(archive / 'repository.bundle'), str(restored))
        exists = subprocess.run(['git', '-C', str(restored), 'cat-file', '-e', lost], capture_output=True)
        self.assertEqual(exists.returncode, 0, 'detached reflog commit absent from recovery bundle')

    def test_http_preview_preserves_cookie_jar_and_source_config(self):
        import importlib.util
        from http.server import HTTPServer, SimpleHTTPRequestHandler
        import threading
        from unittest.mock import patch

        self.merged()
        self.run_git(self.remote, 'update-server-info')
        requests = []
        require_cookie = [False]
        root = self.root

        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(root), **kwargs)

            def do_GET(self):
                cookie = self.headers.get('Cookie', '')
                requests.append(cookie)
                if require_cookie[0] and 'fixture_auth=present' not in cookie:
                    self.send_error(403, 'fixture cookie required')
                    return
                super().do_GET()

            def end_headers(self):
                self.send_header('Set-Cookie', 'preview_cookie=received; Path=/')
                super().end_headers()

            def log_message(self, *args):
                pass

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://127.0.0.1:{server.server_port}/origin.git'
            self.run_git(self.repo, 'remote', 'set-url', 'origin', url)
            spec = importlib.util.spec_from_file_location('lifecycle_cookie_test', SCRIPT)
            lifecycle = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(lifecycle)
            # This fixture isolates real HTTP transport from process visibility;
            # the active-process refusal has its own real-process regression.
            with patch.dict(os.environ, self.env), patch.object(lifecycle, 'active_processes'):
                lifecycle.release(self.repo, self.worktree, self.head, 'fixture-session', 7, 'fixture/repo')
                for scope in ('http', f'http.{url}'):
                    for existing in (True, False):
                        with self.subTest(scope=scope, existing=existing):
                            jar = self.repo / '.git/preview-cookies'
                            original = (b'# Netscape HTTP Cookie File\n'
                                b'127.0.0.1\tFALSE\t/\tFALSE\t0\tfixture_auth\tpresent\n') if existing else None
                            jar.unlink(missing_ok=True)
                            if original is not None:
                                jar.write_bytes(original)
                            require_cookie[0] = existing
                            requests.clear()
                            self.run_git(self.repo, 'config', scope + '.cookieFile', str(jar))
                            self.run_git(self.repo, 'config', '--add', scope + '.saveCookies', 'false')
                            self.run_git(self.repo, 'config', '--add', scope + '.saveCookies', 'true')
                            config = (self.repo / '.git/config').read_bytes()
                            try:
                                result = lifecycle.retire(self.repo, self.worktree, False, None)
                                self.assertEqual(result['disposition'], 'ready')
                                self.assertTrue(self.worktree.exists())
                                self.assertTrue(requests, 'preview never contacted the HTTP origin')
                                if existing:
                                    self.assertTrue(all('fixture_auth=present' in request for request in requests))
                                self.assertEqual(jar.read_bytes() if jar.exists() else None, original)
                                self.assertEqual((self.repo / '.git/config').read_bytes(), config)
                            finally:
                                self.run_git(self.repo, 'config', '--unset-all', scope + '.cookieFile')
                                self.run_git(self.repo, 'config', '--unset-all', scope + '.saveCookies')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_unknown_process_visibility_refuses_retirement(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('lifecycle_visibility', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with self.assertRaisesRegex(ValueError, 'process inspection'):
            module.active_processes(self.worktree, self.root / 'no-proc')
        entry = self.proc / '123'
        entry.mkdir()
        (entry / 'cwd').symlink_to(self.root)
        with patch.object(module.os, 'readlink', side_effect=PermissionError('fixture denied')):
            with self.assertRaisesRegex(ValueError, 'cannot inspect'):
                module.active_processes(self.worktree, self.proc)

    def test_stashes_survive_retirement(self):
        (self.repo / 'file').write_text('private stash\n')
        self.run_git(self.repo, 'stash', 'push', '-qm', 'preserve')
        stash = self.run_git(self.repo, 'rev-parse', 'refs/stash').strip()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_git(self.repo, 'rev-parse', 'refs/stash').strip(), stash)


if __name__ == '__main__':
    unittest.main()
