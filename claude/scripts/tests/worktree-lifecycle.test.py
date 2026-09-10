#!/usr/bin/env python3
"""Exercise lifecycle decisions on real disposable Git worktrees."""
from contextlib import contextmanager, nullcontext
import json
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
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

    def process_fixture(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('lifecycle_visibility', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        entry = self.proc / '123'
        entry.mkdir()
        (entry / 'status').write_text('Name:\tfixture\nState:\tS (sleeping)\n')
        (entry / 'cwd').symlink_to(self.root)
        (entry / 'root').symlink_to('/')
        (entry / 'exe').symlink_to(sys.executable)
        (entry / 'fd').mkdir()
        (entry / 'fd/3').symlink_to(self.root / 'unrelated')
        (entry / 'maps').write_text('1000-2000 rw-p 00000000 00:00 0 [heap]\n')
        (entry / 'task').mkdir()
        (entry / 'task/123').symlink_to(entry, target_is_directory=True)
        return module, entry

    def hidden_staged_work(self):
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        alternate = self.root / 'alternate-index'
        shutil.copyfile(admin / 'index', alternate)
        (self.worktree / 'file').write_bytes(b'UNIQUE STAGED OPERATOR DATA\n')
        self.run_git(self.worktree, 'add', 'file')
        staged = self.run_git(self.worktree, 'rev-parse', ':file').strip()
        (self.worktree / 'file').write_bytes(b'feature\n')
        self.assertEqual(self.run_git(self.worktree, 'status', '--porcelain'), 'MM file\n')
        return admin, alternate, staged

    def test_alternate_index_cannot_hide_staged_work_from_release(self):
        admin, alternate, staged = self.hidden_staged_work()
        before = (admin / 'index').read_bytes()
        self.env['GIT_INDEX_FILE'] = str(alternate)
        result = self.release()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('GIT_INDEX_FILE', result.stderr)
        self.assertFalse((admin / 'worktree-release.json').exists())
        self.assertEqual((admin / 'index').read_bytes(), before)
        self.assertEqual(self.run_git(self.worktree, 'rev-parse', ':file').strip(), staged)

    def test_alternate_index_cannot_hide_staged_work_from_retirement(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin, alternate, staged = self.hidden_staged_work()
        before = (admin / 'index').read_bytes()
        self.env['GIT_INDEX_FILE'] = str(alternate)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('GIT_INDEX_FILE', result.stderr)
        self.assertTrue(self.worktree.is_dir())
        self.assertFalse((self.root / 'archive').exists())
        self.assertEqual((admin / 'index').read_bytes(), before)
        self.assertEqual(self.run_git(self.worktree, 'rev-parse', ':file').strip(), staged)

    def test_git_evidence_overrides_refuse_direct_api_before_writes(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        record = admin / 'worktree-release.json'
        overrides = {
            'GIT_DIR': str(admin), 'GIT_COMMON_DIR': str(self.repo / '.git'),
            'GIT_WORK_TREE': str(self.worktree), 'GIT_IMPLICIT_WORK_TREE': '1',
            'GIT_INDEX_FILE': str(admin / 'index'),
            'GIT_OBJECT_DIRECTORY': str(self.repo / '.git/objects'),
            'GIT_ALTERNATE_OBJECT_DIRECTORIES': str(self.repo / '.git/objects'),
            'GIT_NAMESPACE': 'fixture', 'GIT_PREFIX': 'fixture/',
            'GIT_GRAFT_FILE': str(self.root / 'grafts'),
            'GIT_SHALLOW_FILE': str(self.root / 'shallow'),
            'GIT_REPLACE_REF_BASE': 'refs/fixture/', 'GIT_ATTR_SOURCE': 'HEAD',
            'GIT_CONFIG': str(self.root / 'config'),
            'GIT_CONFIG_GLOBAL': str(self.root / 'config'),
            'GIT_CONFIG_SYSTEM': str(self.root / 'config'),
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_COUNT': '0',
            'GIT_CONFIG_KEY_0': 'core.worktree',
            'GIT_CONFIG_VALUE_0': 'PRIVATE CONFIG VALUE',
            'GIT_CONFIG_PARAMETERS': "'core.worktree=PRIVATE CONFIG VALUE'",
        }
        for action in ('release', 'retire'):
            if action == 'retire':
                self.assertEqual(self.release().returncode, 0)
            before = record.read_bytes() if record.exists() else None
            for name, value in overrides.items():
                with self.subTest(action=action, variable=name), patch.dict(os.environ, self.env | {name: value}):
                    with self.assertRaisesRegex(ValueError, 'Git environment overrides.*' + name) as raised:
                        if action == 'release':
                            lifecycle.release(self.repo, self.worktree, self.head, 'fixture-session', 7, 'fixture/repo')
                        else:
                            lifecycle.retire(self.repo, self.worktree, True, self.root / 'archive')
                    self.assertNotIn('PRIVATE CONFIG VALUE', str(raised.exception))
                    self.assertEqual(record.read_bytes() if record.exists() else None, before)
                    self.assertFalse((self.root / 'archive').exists())
                    self.assertTrue(self.worktree.is_dir())

    def test_git_transport_and_forced_defensive_environment_remain_supported(self):
        from unittest.mock import patch

        self.merged()
        transport = {'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes', 'GIT_SSH': '/fixture/ssh',
                     'GIT_ASKPASS': '/fixture/askpass', 'SSH_AUTH_SOCK': '/fixture/agent.sock'}
        self.env.update(transport, GIT_OPTIONAL_LOCKS='1', GIT_NO_REPLACE_OBJECTS='0', GIT_TERMINAL_PROMPT='1')
        lifecycle, _ = self.process_fixture()
        names = [*transport, 'GIT_OPTIONAL_LOCKS', 'GIT_NO_REPLACE_OBJECTS', 'GIT_TERMINAL_PROMPT']
        with patch.dict(os.environ, self.env):
            actual = json.loads(lifecycle.run([sys.executable, '-c',
                'import json,os,sys; print(json.dumps({name:os.environ[name] for name in sys.argv[1:]}))', *names]))
        self.assertEqual(actual, transport | {'GIT_OPTIONAL_LOCKS': '0', 'GIT_NO_REPLACE_OBJECTS': '1',
                                             'GIT_TERMINAL_PROMPT': '0'})
        self.assertEqual(self.release().returncode, 0)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)

    @contextmanager
    def threaded_worker(self, topology, kind='fd', target=None):
        compiler = shutil.which('cc')
        if not compiler or not Path('/proc/self/task').is_dir():
            self.skipTest('native thread fixture requires a C compiler and Linux /proc')
        target = target or self.worktree / 'file'
        source = self.root / 'threads.c'
        source.write_text(r'''
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
static char **arguments;
static void *worker(void *unused) {
    int fd = -1;
    if (!strcmp(arguments[2], "cwd")) {
        if (chdir(arguments[3])) _exit(2);
    } else {
        fd = open(arguments[3], O_RDONLY);
        if (fd < 0) _exit(3);
        if (!strcmp(arguments[2], "mapping")) {
            struct stat info;
            if (fstat(fd, &info)) _exit(4);
            if (mmap(NULL, info.st_size, PROT_READ, MAP_PRIVATE, fd, 0) == MAP_FAILED) _exit(5);
            close(fd);
            fd = -1;
        }
    }
    printf("%ld %d\n", syscall(SYS_gettid), fd);
    fflush(stdout);
    char byte;
    if (read(STDIN_FILENO, &byte, 1) < 0) _exit(6);
    return NULL;
}
static int private_worker(void *unused) { worker(unused); return 0; }
int main(int argc, char **argv) {
    arguments = argv;
    if (!strcmp(argv[1], "private")) {
        // Share the thread group and memory, but give the worker its own
        // descriptor table and filesystem context from creation onward.
        char *stack = malloc(1024 * 1024);
        if (!stack || clone(private_worker, stack + 1024 * 1024,
                CLONE_VM | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM, NULL) < 0) return 7;
    } else {
        pthread_t thread;
        if (pthread_create(&thread, NULL, worker, NULL)) return 8;
        if (!strcmp(argv[1], "leader-exit")) pthread_exit(NULL);
    }
    for (;;) pause();
}
''')
        executable = self.root / 'threads'
        subprocess.run([compiler, '-pthread', str(source), '-o', str(executable)],
                       check=True, capture_output=True, timeout=15)
        child = subprocess.Popen([str(executable), topology, kind,
            str(target.parent if kind == 'cwd' else target)], cwd=self.root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        entry = self.proc / str(child.pid)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'thread readiness timeout')
            tid, descriptor = map(int, child.stdout.readline().split())
            entry.symlink_to(Path('/proc') / str(child.pid), target_is_directory=True)
            thread = entry / 'task' / str(tid)
            if topology == 'leader-exit':
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if b'State:\tZ' in (entry / 'status').read_bytes(): break
                    time.sleep(0.01)
                self.assertIn(b'State:\tZ', (entry / 'status').read_bytes())
            if kind == 'fd':
                self.assertEqual(os.readlink(thread / 'fd' / str(descriptor)), str(target))
            if topology == 'private':
                self.assertEqual(Path(os.readlink(entry / 'cwd')), self.root.resolve())
                self.assertNotIn(str(target), [os.readlink(fd) for fd in (entry / 'fd').iterdir()])
            if kind == 'mapping':
                self.assertNotIn(str(target), [os.readlink(fd) for fd in (thread / 'fd').iterdir()])
                self.assertIn(str(target), (thread / 'maps').read_text())
            yield child, thread
        finally:
            child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr): stream.close()
            entry.unlink(missing_ok=True)

    def assert_thread_reference_retained(self, topology, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.threaded_worker(topology, kind) as (child, thread):
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive')) if after_release else self.release()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('active process', result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertNotIn(b'State:\tZ', (thread / 'status').read_bytes())
            self.assertFalse((self.root / 'archive').exists())

    def test_exited_leader_cannot_hide_live_thread_references_from_release(self):
        for kind in ('fd', 'mapping', 'cwd'):
            with self.subTest(surface=kind):
                with self.threaded_worker('leader-exit', kind):
                    result = self.release()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('active process', result.stderr)

    def test_exited_leader_thread_descriptor_refuses_retirement(self):
        self.assert_thread_reference_retained('leader-exit', 'fd', True)

    def test_exited_leader_thread_mapping_refuses_retirement(self):
        self.assert_thread_reference_retained('leader-exit', 'mapping', True)

    def test_exited_leader_thread_cwd_refuses_retirement(self):
        self.assert_thread_reference_retained('leader-exit', 'cwd', True)

    def test_private_thread_filesystem_and_descriptors_refuse_release(self):
        for kind in ('fd', 'cwd'):
            with self.subTest(surface=kind):
                with self.threaded_worker('private', kind):
                    result = self.release()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('active process', result.stderr)
                    self.assertTrue(self.worktree.exists())

    def test_private_thread_descriptors_refuse_retirement(self):
        self.assert_thread_reference_retained('private', 'fd', True)

    def test_private_thread_cwd_refuses_retirement(self):
        self.assert_thread_reference_retained('private', 'cwd', True)

    def test_readable_unrelated_multithreaded_process_is_safe(self):
        self.merged()
        unrelated = self.root / 'unrelated'
        unrelated.write_text('outside the task\n')
        with self.threaded_worker('shared', target=unrelated) as (child, thread):
            self.assertGreaterEqual(len(list(thread.parent.iterdir())), 2)
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(unrelated.read_text(), 'outside the task\n')

    @contextmanager
    def worker(self, kind, target=None):
        target = target or self.worktree / 'file'
        program = r'''
import ctypes, mmap, os, socket, sys
kind, path = sys.argv[1:]
if kind == 'cwd':
    os.chdir(os.path.dirname(path))
elif kind == 'socket':
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen()
else:
    descriptor = os.open(path, os.O_RDWR | os.O_APPEND if kind == 'writer' else os.O_RDONLY)
    if kind == 'mapping':
        libc = ctypes.CDLL(None, use_errno=True)
        libc.mmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                             ctypes.c_int, ctypes.c_int, ctypes.c_long)
        libc.mmap.restype = ctypes.c_void_p
        address = libc.mmap(None, os.fstat(descriptor).st_size, mmap.PROT_READ,
                            mmap.MAP_PRIVATE, descriptor, 0)
        if address == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), 'mmap failed')
        os.close(descriptor)
print('ready', flush=True)
sys.stdin.buffer.read(1)
if kind == 'writer':
    os.write(descriptor, b'after liveness scan\n')
    os.fsync(descriptor)
    print('updated', flush=True)
    sys.stdin.buffer.read(1)
'''
        child = subprocess.Popen([sys.executable, '-B', '-c', program, kind, str(target)],
            cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        entry = self.proc / str(child.pid)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'worker readiness timeout')
            self.assertEqual(child.stdout.readline(), b'ready\n')
            entry.symlink_to(Path('/proc') / str(child.pid), target_is_directory=True)
            if kind != 'cwd':
                self.assertEqual(Path(os.readlink(entry / 'cwd')), self.root.resolve())
            if kind == 'mapping':
                targets = [os.readlink(fd) for fd in (entry / 'fd').iterdir()]
                self.assertNotIn(str(target), targets, 'mapping fixture retained a backing descriptor')
            yield child
        finally:
            child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr): stream.close()
            entry.unlink(missing_ok=True)

    def assert_process_reference_retained(self, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.worker(kind) as child:
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive')) if after_release else self.release()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('active process', result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertFalse((self.root / 'archive').exists())

    def test_open_descriptor_refuses_release(self):
        self.assert_process_reference_retained('fd', False)

    def test_open_descriptor_refuses_retirement(self):
        self.assert_process_reference_retained('fd', True)

    def test_closed_descriptor_mapping_refuses_release(self):
        self.assert_process_reference_retained('mapping', False)

    def test_closed_descriptor_mapping_refuses_retirement(self):
        self.assert_process_reference_retained('mapping', True)

    def test_cwd_refuses_release(self):
        self.assert_process_reference_retained('cwd', False)

    def test_mapping_in_newline_worktree_path_refuses_release(self):
        moved = self.root / 'task\nwith space'
        self.run_git(self.repo, 'worktree', 'move', str(self.worktree), str(moved))
        self.worktree = moved
        self.assert_process_reference_retained('mapping', False)

    def test_unrelated_worker_does_not_block_retirement(self):
        self.merged()
        unrelated = self.root / 'unrelated'
        unrelated.write_text('outside the task\n')
        with self.worker('fd', unrelated) as child:
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(unrelated.read_text(), 'outside the task\n')

    def assert_private_admin_writer_retained(self, after_release):
        self.merged()
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        evidence = admin / 'owned-runtime-evidence.log'
        evidence.write_text('before liveness scan\n')
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.worker('writer', evidence) as child:
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive')) if after_release else self.release()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('active process', result.stderr)
            child.stdin.write(b'x')
            child.stdin.flush()
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'writer response timeout')
            self.assertEqual(child.stdout.readline(), b'updated\n')
            self.assertEqual(evidence.read_text(), 'before liveness scan\nafter liveness scan\n')
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertFalse((self.root / 'archive').exists())

    def test_private_admin_writer_refuses_release(self):
        self.assert_private_admin_writer_retained(False)

    def test_private_admin_writer_refuses_retirement(self):
        self.assert_private_admin_writer_retained(True)

    def test_common_git_metadata_reference_does_not_block_retirement(self):
        self.merged()
        common = Path(self.run_git(self.worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip())
        evidence = common / 'shared-runtime-evidence.log'
        evidence.write_text('shared repository evidence\n')
        with self.worker('fd', evidence) as child:
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(evidence.read_text(), 'shared repository evidence\n')

    def assert_private_admin_special_file_retained(self, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        endpoint = admin / 'runtime/endpoint'
        endpoint.parent.mkdir()
        if kind == 'fifo': os.mkfifo(endpoint)
        with self.worker('socket', endpoint) if kind == 'socket' else nullcontext() as child:
            result = self.retire('--apply', '--archive-dir', str(self.root / 'archive')) if after_release else self.release()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('special Git metadata', result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertTrue(endpoint.exists())
            self.assertFalse((self.root / 'archive').exists())
            if child is not None:
                self.assertIsNone(child.poll())
                with socket.socket(socket.AF_UNIX) as client: client.connect(str(endpoint))

    def test_private_admin_socket_refuses_release(self):
        self.assert_private_admin_special_file_retained('socket', False)

    def test_private_admin_socket_refuses_retirement(self):
        self.assert_private_admin_special_file_retained('socket', True)

    def test_private_admin_fifo_refuses_release(self):
        self.assert_private_admin_special_file_retained('fifo', False)

    def test_private_admin_fifo_refuses_retirement(self):
        self.assert_private_admin_special_file_retained('fifo', True)

    def test_regular_private_metadata_is_archived_without_following_symlinks(self):
        self.merged()
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        (admin / 'evidence/empty').mkdir(parents=True)
        (admin / 'evidence/notes').write_bytes(b'private regular metadata\x00\n')
        os.link(admin / 'evidence/notes', admin / 'evidence/linked-notes')
        outside = self.root / 'outside-metadata'
        outside.mkdir()
        os.mkfifo(outside / 'live-fifo')
        (admin / 'external').symlink_to(outside, target_is_directory=True)
        broken_target = os.fsdecode(b'missing-target-\xff')
        (admin / 'broken').symlink_to(broken_target)
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.retire('--apply', '--archive-dir', str(self.root / 'archive'))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)['archive'])
        with tarfile.open(archive / 'worktree-metadata.tar') as stream:
            self.assertEqual(stream.extractfile('worktree-metadata/evidence/notes').read(), b'private regular metadata\x00\n')
            self.assertEqual(stream.extractfile('worktree-metadata/evidence/linked-notes').read(), b'private regular metadata\x00\n')
            self.assertTrue(any(stream.getmember('worktree-metadata/evidence/' + name).islnk()
                                for name in ('notes', 'linked-notes')))
            self.assertTrue(stream.getmember('worktree-metadata/evidence/empty').isdir())
            for name in ('external', 'broken'):
                self.assertTrue(stream.getmember('worktree-metadata/' + name).issym())
            self.assertEqual(stream.getmember('worktree-metadata/external').linkname, str(outside))
            self.assertEqual(os.fsencode(stream.getmember('worktree-metadata/broken').linkname), os.fsencode(broken_target))
            self.assertNotIn('worktree-metadata/external/live-fifo', stream.getnames())
        self.assertTrue((outside / 'live-fifo').exists())

    def assert_completed_metadata_change_retained(self, mutation):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        evidence = admin / 'evidence.txt'
        evidence.write_bytes(b'original metadata\n')
        evidence.chmod(0o600)
        (admin / 'empty').mkdir(mode=0o700)
        (admin / 'pointer').symlink_to('missing-target')
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        # Keep the actual scanner, including a live native process, while the
        # writer closes its descriptor and exits before the final assessment.
        (self.proc / str(os.getpid())).symlink_to(Path('/proc') / str(os.getpid()), target_is_directory=True)
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original_assess = lifecycle.assess
        assessments = []

        def assess_after_completed_writer(repo, path):
            assessments.append(path)
            if len(assessments) == 2:
                subprocess.run([sys.executable, '-c',
                    'import os,pathlib,sys; admin=pathlib.Path(sys.argv[1]); '
                    'evidence=admin/"evidence.txt"; ' + mutation,
                    str(admin)], check=True, timeout=5)
            return original_assess(repo, path)

        with patch.dict(os.environ, self.env), patch.object(lifecycle, 'assess', assess_after_completed_writer):
            with self.assertRaisesRegex(ValueError, 'metadata changed.*retained.*archive:'):
                lifecycle.retire(self.repo, self.worktree, True, self.root / 'archive')
        self.assertEqual(len(assessments), 2)
        self.assertTrue(self.worktree.is_dir())
        archive, = (self.root / 'archive').iterdir()
        with tarfile.open(archive / 'worktree-metadata.tar') as stream:
            self.assertEqual(stream.extractfile('worktree-metadata/evidence.txt').read(), b'original metadata\n')
        self.assertTrue((archive / 'repository.bundle').is_file())
        self.assertTrue((archive / 'recovery.json').is_file())
        return admin

    def test_completed_metadata_writer_after_archive_retains_worktree(self):
        admin = self.assert_completed_metadata_change_retained('evidence.write_bytes(b"NEW PRIVATE EVIDENCE\\n")')
        self.assertEqual((admin / 'evidence.txt').read_bytes(), b'NEW PRIVATE EVIDENCE\n')

    def test_metadata_same_size_write_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            'before=evidence.stat(); evidence.write_bytes(b"changed! metadata\\n"); '
            'os.utime(evidence, ns=(before.st_atime_ns, before.st_mtime_ns))')

    def test_metadata_file_created_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"new-evidence").write_bytes(b"new evidence")')

    def test_metadata_file_deleted_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('evidence.unlink()')

    def test_metadata_mode_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('evidence.chmod(0o700)')

    def test_metadata_directory_mode_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"empty").chmod(0o500)')

    def test_metadata_directory_created_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"new-empty").mkdir()')

    def test_metadata_directory_deleted_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"empty").rmdir()')

    def test_metadata_symlink_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            '(admin/"pointer").unlink(); (admin/"pointer").symlink_to("other-missing-target")')

    def test_metadata_type_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            'empty=admin/"empty"; empty.rmdir(); empty.write_bytes(b""); empty.chmod(0o700)')

    def test_scanner_itself_has_complete_descriptor_evidence(self):
        module, _ = self.process_fixture()
        (self.proc / str(os.getpid())).symlink_to(Path('/proc') / str(os.getpid()), target_is_directory=True)
        module.active_processes(self.worktree, self.proc)

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

    def root_inventory(self, root=None):
        result = subprocess.run(['python3', str(SCRIPT), 'inventory', '--root', str(root or self.root)],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def separate_git_directory(self):
        # Only the disposable fixture is removed; its committed topic survives.
        self.run_git(self.repo, 'worktree', 'remove', '--force', str(self.worktree))
        metadata = self.root / 'metadata.git'
        self.run_git(self.repo, 'init', '-q', '--separate-git-dir', str(metadata))
        self.run_git(self.repo, 'worktree', 'add', '-q', str(self.worktree), 'topic')
        self.assertTrue((self.repo / '.git').is_file())
        return metadata

    def test_inventory_root_finds_primary_with_separate_git_directory(self):
        self.separate_git_directory()
        direct = self.cli('inventory')
        self.assertEqual(direct.returncode, 0, direct.stderr)
        expected = json.loads(direct.stdout)['worktrees']
        self.assertEqual(len(expected), 2)
        actual = self.root_inventory()
        self.assertEqual(actual['errors'], [])
        self.assertEqual(actual['worktrees'], expected)

    def test_inventory_root_deduplicates_common_directory_and_skips_linked_children(self):
        metadata = self.separate_git_directory()
        alias = self.root / 'aaa-primary-alias'
        alias.mkdir()
        # A second Git-file spelling of the same common directory must not
        # duplicate its inventory, even when encountered before the checkout.
        (alias / '.git').write_text('gitdir: ../metadata.git\n')
        self.assertEqual(Path(self.run_git(alias, 'rev-parse', '--absolute-git-dir').strip()).resolve(), metadata)
        data = self.root_inventory()
        self.assertEqual(data['errors'], [])
        self.assertEqual(len(data['worktrees']), 2)
        self.assertEqual(len({item['path'] for item in data['worktrees']}), 2)
        linked_only = self.root / 'linked-only'
        linked_only.mkdir()
        self.run_git(self.repo, 'worktree', 'move', str(self.worktree), str(linked_only / 'task'))
        self.assertEqual(self.root_inventory(linked_only)['worktrees'], [])

    def test_inventory_root_skips_symlinked_children_and_does_not_recurse(self):
        (self.root / 'aaa-symlink').symlink_to(self.repo, target_is_directory=True)
        nested = self.root / 'nested'
        nested.mkdir()
        self.run_git(nested, 'init', '-q', str(nested / 'unrelated'))
        data = self.root_inventory()
        self.assertEqual(data['errors'], [])
        self.assertEqual(len(data['worktrees']), 2)

    def test_inventory_root_reports_malformed_or_dangling_git_files(self):
        invalid = self.root / 'invalid'
        invalid.mkdir()
        for content in ('not a gitdir pointer\n', 'gitdir: ../missing-metadata\n'):
            with self.subTest(content=content):
                (invalid / '.git').write_text(content)
                data = self.root_inventory()
                self.assertEqual(len(data['worktrees']), 2)
                self.assertEqual([error['repo'] for error in data['errors']], [str(invalid)])
                self.assertTrue(data['errors'][0]['reason'])

    @unittest.skipIf(os.geteuid() == 0, 'root can read mode-zero Git files')
    def test_inventory_root_reports_unreadable_git_file(self):
        self.separate_git_directory()
        pointer = self.repo / '.git'
        mode = pointer.stat().st_mode & 0o777
        pointer.chmod(0)
        try:
            data = self.root_inventory()
            self.assertEqual([error['repo'] for error in data['errors']], [str(self.repo)])
            self.assertEqual(data['worktrees'], [])
        finally:
            pointer.chmod(mode)

    def test_inventory_retains_release_after_same_head_branch_change(self):
        self.assertEqual(self.release().returncode, 0)
        self.run_git(self.worktree, 'switch', '-qc', 'different-topic')
        self.assertEqual(self.run_git(self.worktree, 'rev-parse', 'HEAD').strip(), self.head)
        result = self.cli('inventory')
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(item for item in json.loads(result.stdout)['worktrees'] if item['path'] == str(self.worktree))
        self.assertEqual(task['disposition'], 'retained')
        self.assertIn('branch changed since release', task['reason'])

    def test_inventory_retains_release_after_same_head_move(self):
        self.assertEqual(self.release().returncode, 0)
        moved = self.root / 'moved'
        self.run_git(self.repo, 'worktree', 'move', str(self.worktree), str(moved))
        self.assertEqual(self.run_git(moved, 'rev-parse', 'HEAD').strip(), self.head)
        result = self.cli('inventory')
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(item for item in json.loads(result.stdout)['worktrees'] if item['path'] == str(moved))
        self.assertEqual(task['disposition'], 'retained')
        self.assertIn('path or branch changed since release', task['reason'])

    def test_inventory_checks_current_release_without_remote_calls(self):
        self.assertEqual(self.release().returncode, 0)
        called = self.root / 'remote-called'
        (self.bin / 'gh').write_text('#!/usr/bin/env python3\nfrom pathlib import Path\n'
            f'Path({str(called)!r}).touch()\nraise SystemExit(1)\n')
        result = self.cli('inventory')
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(item for item in json.loads(result.stdout)['worktrees'] if item['path'] == str(self.worktree))
        self.assertEqual(task['disposition'], 'released')
        self.assertFalse(called.exists())

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

    def test_archive_rejects_actual_primary_with_separate_git_directory(self):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        destination = self.repo / 'private-recovery'
        result = self.retire('--apply', '--archive-dir', str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conventional primary checkout', result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_rejects_symlink_into_conventional_primary(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / 'primary-alias'
        alias.symlink_to(self.repo, target_is_directory=True)
        destination = alias / 'private-recovery'
        result = self.retire('--apply', '--archive-dir', str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('archive must be outside', result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_separate_metadata_allows_preview_but_retains_applied_retirement(self):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        inventory = self.cli('inventory')
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        task = next(item for item in json.loads(inventory.stdout)['worktrees']
                    if item['path'] == str(self.worktree))
        self.assertEqual(task['disposition'], 'released')
        preview = self.retire()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)['disposition'], 'ready')
        destination = self.root / 'private-recovery'
        result = self.retire('--apply', '--archive-dir', str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conventional primary checkout', result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_gitfile_alias_cannot_archive_inside_unlisted_external_primary(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / 'alias'
        alias.mkdir()
        (alias / '.git').write_text('gitdir: ../metadata.git\n')
        self.assertEqual(Path(self.run_git(alias, 'rev-parse', '--absolute-git-dir').strip()).resolve(), common)
        self.assertEqual(Path(self.run_git(alias, 'rev-parse', '--show-toplevel').strip()).resolve(), alias)
        destination = self.repo / 'private-recovery'
        result = subprocess.run(['python3', str(self.runner), 'retire', '--repo', str(alias),
            '--worktree', str(self.worktree), '--apply', '--archive-dir', str(destination)],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conventional primary checkout', result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_primary_git_directory_symlink_cannot_enable_applied_retirement(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / '.git').unlink()
        (self.repo / '.git').symlink_to(common, target_is_directory=True)
        destination = self.root / 'private-recovery'
        result = self.retire('--apply', '--archive-dir', str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conventional primary checkout', result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_rejects_gitfile_alias_of_conventional_primary(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / 'alias'
        alias.mkdir()
        (alias / '.git').write_text('gitdir: ../repo/.git\n')
        destination = alias / 'missing-parent/private-recovery'
        result = self.retire('--apply', '--archive-dir', str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('archive must be outside', result.stderr)
        self.assertFalse((alias / 'missing-parent').exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_with_unresolvable_git_ancestry_is_retained_before_creation(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        private = self.root / 'private'
        private.mkdir()
        git_marker = private / '.git'
        for kind in ('malformed', 'dangling', 'empty-directory'):
            with self.subTest(marker=kind):
                if kind == 'malformed':
                    git_marker.write_text('not a Git directory pointer\n')
                elif kind == 'dangling':
                    git_marker.symlink_to(self.root / 'missing.git', target_is_directory=True)
                else:
                    git_marker.mkdir()
                try:
                    result = self.retire('--apply', '--archive-dir', str(private / 'recovery'))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((private / 'recovery').exists())
                    self.assertTrue(self.worktree.exists())
                finally:
                    if git_marker.is_dir() and not git_marker.is_symlink():
                        git_marker.rmdir()
                    else:
                        git_marker.unlink()

    def test_archive_inside_different_private_repository_remains_supported(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        private = self.root / 'private'
        self.run_git(self.root, 'init', '-q', '-b', 'main', str(private))
        result = self.retire('--apply', '--archive-dir', str(private / 'recovery'))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)['archive'])
        self.assertTrue((archive / 'repository.bundle').is_file())
        self.assertTrue((archive / 'worktree-metadata.tar').is_file())
        self.assertFalse(self.worktree.exists())

    def test_archive_rejects_worktrees_and_git_metadata(self):
        common = self.repo / '.git'
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, 'rev-parse', '--absolute-git-dir').strip())
        for root in (self.repo, self.worktree, common, admin):
            with self.subTest(root=root):
                destination = root / 'private-recovery'
                result = self.retire('--apply', '--archive-dir', str(destination))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('archive must be outside', result.stderr)
                self.assertFalse(destination.exists())
                self.assertTrue(self.worktree.exists())

    def test_archive_linked_repo_requires_primary_before_creating_inside_or_outside_destination(self):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for destination in (self.repo / 'private-recovery', self.root / 'private-recovery'):
            with self.subTest(destination=destination):
                result = subprocess.run(['python3', str(self.runner), 'retire', '--repo', str(self.worktree),
                    '--worktree', str(self.worktree), '--apply', '--archive-dir', str(destination)],
                    cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('primary checkout', result.stderr)
                self.assertFalse(destination.exists())
                self.assertTrue(self.worktree.exists())

    def test_archive_metadata_only_repo_cannot_establish_actual_primary(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        destination = self.root / 'private-recovery'
        result = subprocess.run(['python3', str(self.runner), 'retire', '--repo', str(common),
            '--worktree', str(self.worktree), '--apply', '--archive-dir', str(destination)],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

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
        from unittest.mock import patch
        module, entry = self.process_fixture()
        thread = entry / 'task/456'
        shutil.copytree(entry, thread, symlinks=True, ignore=shutil.ignore_patterns('task'))
        with self.assertRaisesRegex(ValueError, 'process inspection'):
            module.active_processes(self.worktree, self.root / 'no-proc')
        for error in (PermissionError, FileNotFoundError):
            for name in ('cwd', 'root', 'exe', 'fd/3', 'fd', 'maps', 'status'):
                with self.subTest(error=error.__name__, surface=name):
                    target = thread / name
                    attribute = 'readlink' if name in ('cwd', 'root', 'exe', 'fd/3') else (
                        'scandir' if name == 'fd' else 'open')
                    owner = module.os if attribute in ('readlink', 'scandir') else module.Path
                    original = getattr(owner, attribute)

                    def unavailable(candidate, *args, **kwargs):
                        if Path(candidate) == target:
                            raise error('fixture evidence unavailable')
                        return original(candidate, *args, **kwargs)

                    with patch.object(owner, attribute, new=unavailable):
                        with self.assertRaisesRegex(ValueError, 'cannot inspect'):
                            module.active_processes(self.worktree, self.proc)

    def test_missing_and_changing_thread_enumeration_retains_even_with_dead_leader(self):
        from unittest.mock import patch
        module, entry = self.process_fixture()
        tasks = entry / 'task'
        original = module.Path.iterdir
        for state in ('S', 'Z'):
            (entry / 'status').write_text(f'State:\t{state}\n')
            for error in (PermissionError, FileNotFoundError):
                with self.subTest(state=state, error=error.__name__):
                    def unavailable(candidate):
                        if candidate == tasks: raise error('task enumeration unavailable')
                        return original(candidate)
                    with patch.object(module.Path, 'iterdir', new=unavailable):
                        with self.assertRaisesRegex(ValueError, 'cannot inspect'):
                            module.active_processes(self.worktree, self.proc)
            for change in ('empty', 'added', 'removed'):
                with self.subTest(state=state, change=change):
                    observations = 0
                    def changing(candidate):
                        nonlocal observations
                        if candidate != tasks: return original(candidate)
                        observations += 1
                        if change == 'empty' or (change == 'removed' and observations > 1):
                            return iter(())
                        names = [tasks / '123']
                        if change == 'added' and observations > 1: names.append(tasks / '456')
                        return iter(names)
                    with patch.object(module.Path, 'iterdir', new=changing):
                        with self.assertRaisesRegex(ValueError, 'cannot inspect'):
                            module.active_processes(self.worktree, self.proc)

    def test_executable_root_and_deleted_mapping_references_are_active(self):
        module, entry = self.process_fixture()
        for name in ('root', 'exe'):
            with self.subTest(surface=name):
                link = entry / name
                target = os.readlink(link)
                link.unlink()
                link.symlink_to(self.worktree if name == 'root' else self.worktree / 'file')
                with self.assertRaisesRegex(ValueError, 'active process.*' + name):
                    module.active_processes(self.worktree, self.proc)
                link.unlink()
                link.symlink_to(target)
        (entry / 'maps').write_text(f'1000-2000 r--p 00000000 00:01 1 {self.worktree}/file (deleted)\n')
        with self.assertRaisesRegex(ValueError, 'active process.*memory mapping'):
            module.active_processes(self.worktree, self.proc)

    def test_non_filesystem_descriptors_and_confirmed_exit_are_safe(self):
        module, entry = self.process_fixture()
        for number, target in enumerate(('pipe:[123]', 'socket:[456]', 'anon_inode:[eventpoll]'), 4):
            (entry / 'fd' / str(number)).symlink_to(target)
        module.active_processes(self.worktree, self.proc)
        (entry / 'cwd').unlink()
        with self.assertRaisesRegex(ValueError, 'cannot inspect'):
            module.active_processes(self.worktree, self.proc)
        (entry / 'status').write_text('State:\tZ (zombie)\n')
        module.active_processes(self.worktree, self.proc)
        # A process that vanished after enumeration is also definitively gone.
        (self.proc / '456').symlink_to(self.root / 'vanished-process')
        module.active_processes(self.worktree, self.proc)

    def test_empty_or_malformed_live_mapping_evidence_is_retained(self):
        module, entry = self.process_fixture()
        for data in ('', 'incomplete mapping\n'):
            with self.subTest(maps=data):
                (entry / 'maps').write_text(data)
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
