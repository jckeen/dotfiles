#!/usr/bin/env python3
"""Exercise lifecycle decisions on real disposable Git worktrees."""

from contextlib import contextmanager, nullcontext
from datetime import datetime, timedelta, timezone
import errno
import json
import os
from pathlib import Path
import select
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "worktree-lifecycle.py"


def host_git_marker(root):
    """The first `.git` marker at or above a fixture root, if any.

    Applied retirement walks every ancestor of the archive directory for Git
    markers, and the fixture archives under the system temporary directory, so
    a stray marker above it (host state) fails most of this suite with an
    opaque Git exit (#511). Report that once, by path, instead.
    """
    for directory in (root, *root.parents):
        if os.path.lexists(directory / ".git"):
            return directory / ".git"
    return None


def setUpModule():
    with tempfile.TemporaryDirectory() as probe:
        marker = host_git_marker(Path(probe))
    if marker is not None:
        raise RuntimeError(
            f"host state, not the code under test: a Git marker at {marker} sits above the "
            "fixture root, and retirement inspects every archive ancestor; remove it or set "
            "TMPDIR to a directory with no Git marker above it"
        )


class HostStateTests(unittest.TestCase):
    def test_marker_above_a_nested_root_is_named(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            nested = base / "outer" / "inner" / "root"
            nested.mkdir(parents=True)
            self.assertIsNone(host_git_marker(nested))
            (base / "outer" / ".git").mkdir()
            self.assertEqual(host_git_marker(nested), base / "outer" / ".git")
            (base / "outer" / "inner" / ".git").write_text("gitdir: nowhere\n")
            self.assertEqual(host_git_marker(nested), base / "outer" / "inner" / ".git")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.worktree = self.root / "task"
        self.remote = self.root / "origin.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.run_git(self.root, "init", "--bare", "-q", str(self.remote))
        self.run_git(self.root, "init", "-q", "-b", "main", str(self.repo))
        self.run_git(self.repo, "config", "user.name", "Fixture")
        self.run_git(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / "file").write_text("base\n")
        self.run_git(self.repo, "add", "file")
        self.run_git(self.repo, "commit", "-qm", "initial")
        self.run_git(self.repo, "remote", "add", "origin", str(self.remote))
        self.run_git(self.repo, "push", "-qu", "origin", "main")
        self.run_git(
            self.repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"
        )
        self.run_git(self.repo, "worktree", "add", "-qb", "topic", str(self.worktree))
        (self.worktree / "file").write_text("feature\n")
        self.run_git(self.worktree, "commit", "-qam", "feature")
        self.head = self.run_git(self.worktree, "rev-parse", "HEAD").strip()
        self.metadata = self.root / "pr.json"
        self.metadata.write_text(
            json.dumps(
                {
                    "state": "OPEN",
                    "headRefOid": self.head,
                    "baseRefName": "main",
                    "mergeCommit": None,
                    "isCrossRepository": False,
                }
            )
        )
        (self.bin / "gh").write_text(
            "#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
            'if "api" in sys.argv: print("main")\n'
            'elif "pr" in sys.argv: print(Path(os.environ["FIXTURE_PR"]).read_text())\n'
            'elif "repo" in sys.argv: print("fixture/repo")\n'
            "else: sys.exit(2)\n"
        )
        (self.bin / "gh").chmod(0o700)
        # The session manager's identity comes from the system manager, so the
        # fixture answers for it. No session manager by default.
        (self.bin / "systemctl").write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            'if "user@%d.service" % os.getuid() not in sys.argv: sys.exit(2)\n'
            'print(os.environ.get("FIXTURE_SESSION_MANAGER", "0"))\n'
        )
        (self.bin / "systemctl").chmod(0o700)
        self.env = dict(
            os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            FIXTURE_PR=str(self.metadata),
            FIXTURE_SESSION_MANAGER="0",
        )
        # Scope process evidence to processes owned by this disposable fixture.
        # The real scanner still runs; unrelated protected host services cannot
        # turn every Git decision test into the same process-visibility refusal.
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.runner = self.root / "run-lifecycle.py"
        self.runner.write_text(
            "import importlib.util,functools,sys\nfrom pathlib import Path\n"
            f'spec=importlib.util.spec_from_file_location("lifecycle", {str(SCRIPT)!r})\n'
            "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
            f"module.active_processes=functools.partial(module.active_processes, proc_root=Path({str(self.proc)!r}))\n"
            "sys.exit(module.main())\n"
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_git(self, cwd, *args):
        return subprocess.check_output(
            ["git", "-C", str(cwd), *args], stderr=subprocess.PIPE, text=True
        )

    def cli(self, action, *args):
        return subprocess.run(
            ["python3", str(self.runner), action, "--repo", str(self.repo), *args],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def release(self, *args):
        return self.cli(
            "release",
            "--worktree",
            str(self.worktree),
            "--head",
            self.head,
            "--owner",
            "fixture-session",
            "--pr",
            "7",
            "--github-repo",
            "fixture/repo",
            *args,
        )

    def merged(self):
        self.run_git(self.repo, "merge", "--squash", "topic")
        self.run_git(self.repo, "commit", "-qm", "integrate feature")
        self.run_git(self.repo, "push", "-q", "origin", "main")
        merge = self.run_git(self.repo, "rev-parse", "HEAD").strip()
        self.metadata.write_text(
            json.dumps(
                {
                    "state": "MERGED",
                    "headRefOid": self.head,
                    "baseRefName": "main",
                    "mergeCommit": {"oid": merge},
                    "isCrossRepository": False,
                }
            )
        )

    def retire(self, *args):
        return self.cli("retire", "--worktree", str(self.worktree), *args)

    def process_fixture(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("lifecycle_visibility", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        entry = self.proc / "123"
        entry.mkdir()
        (entry / "status").write_text("Name:\tfixture\nState:\tS (sleeping)\n")
        (entry / "cwd").symlink_to(self.root)
        (entry / "root").symlink_to("/")
        (entry / "exe").symlink_to(sys.executable)
        (entry / "fd").mkdir()
        (entry / "fd/3").symlink_to(self.root / "unrelated")
        (entry / "maps").write_text("1000-2000 rw-p 00000000 00:00 0 [heap]\n")
        (entry / "task").mkdir()
        (entry / "task/123").symlink_to(entry, target_is_directory=True)
        return module, entry

    def session_process(self, pid, comm, ppid, uid=None, session=None):
        """A same-user process whose every reference points into the worktree.

        Models a systemd user-session process: identity stays readable while
        the evidence below it can be denied, so only the exemption can let a
        release proceed while such a process is visible. A process gets its
        own session, as every service the manager starts does.
        """
        owner = os.getuid() if uid is None else uid
        session = pid if session is None else session
        status = (
            f"Name:\t{comm}\nState:\tS (sleeping)\nPPid:\t{ppid}\n"
            f"Uid:\t{owner}\t{owner}\t{owner}\t{owner}\n"
        )
        # pid, comm in parentheses, state, ppid, pgrp, session, then the rest.
        stat = f"{pid} ({comm}) S {ppid} {session} {session} 0 -1 4194560 0 0\n"
        entry = self.proc / str(pid)
        thread = entry / "task" / str(pid)
        thread.mkdir(parents=True)
        (entry / "comm").write_text(comm + "\n")
        (entry / "stat").write_text(stat)
        for directory in (entry, thread):
            (directory / "status").write_text(status)
        (thread / "cwd").symlink_to(self.worktree)
        (thread / "root").symlink_to("/")
        (thread / "exe").symlink_to(sys.executable)
        (thread / "fd").mkdir()
        (thread / "fd/3").symlink_to(self.worktree / "file")
        (thread / "maps").write_text(f"1000-2000 r--p 00000000 00:01 1 {self.worktree}/file\n")
        return entry

    def deny_session_evidence(self, entry):
        """Deny a thread's evidence with an actual EACCES, as procfs does."""
        self.addCleanup(self.allow_session_evidence, entry)
        for thread in sorted((entry / "task").iterdir()):
            thread.chmod(0o000)
            try:
                os.readlink(thread / "cwd")
            except PermissionError:
                continue
            self.skipTest("denying process evidence by mode requires a non-root user")

    def allow_session_evidence(self, entry):
        """Undo mode-based denial so removal can descend into the fixture."""
        if not entry.exists():
            return
        for thread in sorted((entry / "task").iterdir()):
            thread.chmod(0o700)

    @contextmanager
    def denied_process_reads(self, module, entry, surfaces, code=errno.EACCES):
        """Refuse exactly these surfaces below a pid, as a protected pid does."""
        from unittest.mock import patch

        # A plain function, not a partial: Path.open must still bind its path.
        def refusing(original):
            def refuse(candidate, *args, **kwargs):
                reference = Path(candidate)
                if entry in reference.parents:
                    name = "descriptors" if reference.parent.name == "fd" else reference.name
                    if name in surfaces:
                        raise PermissionError(code, os.strerror(code))
                return original(candidate, *args, **kwargs)

            return refuse

        with patch.object(module.os, "readlink", new=refusing(os.readlink)):
            with patch.object(module.os, "scandir", new=refusing(os.scandir)):
                with patch.object(module.Path, "open", new=refusing(Path.open)):
                    yield

    def hidden_staged_work(self):
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        alternate = self.root / "alternate-index"
        shutil.copyfile(admin / "index", alternate)
        (self.worktree / "file").write_bytes(b"UNIQUE STAGED OPERATOR DATA\n")
        self.run_git(self.worktree, "add", "file")
        staged = self.run_git(self.worktree, "rev-parse", ":file").strip()
        (self.worktree / "file").write_bytes(b"feature\n")
        self.assertEqual(self.run_git(self.worktree, "status", "--porcelain"), "MM file\n")
        return admin, alternate, staged

    def test_alternate_index_cannot_hide_staged_work_from_release(self):
        admin, alternate, staged = self.hidden_staged_work()
        before = (admin / "index").read_bytes()
        self.env["GIT_INDEX_FILE"] = str(alternate)
        result = self.release()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GIT_INDEX_FILE", result.stderr)
        self.assertFalse((admin / "worktree-release.json").exists())
        self.assertEqual((admin / "index").read_bytes(), before)
        self.assertEqual(self.run_git(self.worktree, "rev-parse", ":file").strip(), staged)

    def test_alternate_index_cannot_hide_staged_work_from_retirement(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin, alternate, staged = self.hidden_staged_work()
        before = (admin / "index").read_bytes()
        self.env["GIT_INDEX_FILE"] = str(alternate)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GIT_INDEX_FILE", result.stderr)
        self.assertTrue(self.worktree.is_dir())
        self.assertFalse((self.root / "archive").exists())
        self.assertEqual((admin / "index").read_bytes(), before)
        self.assertEqual(self.run_git(self.worktree, "rev-parse", ":file").strip(), staged)

    def test_git_evidence_overrides_refuse_direct_api_before_writes(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        record = admin / "worktree-release.json"
        overrides = {
            "GIT_DIR": str(admin),
            "GIT_COMMON_DIR": str(self.repo / ".git"),
            "GIT_WORK_TREE": str(self.worktree),
            "GIT_IMPLICIT_WORK_TREE": "1",
            "GIT_INDEX_FILE": str(admin / "index"),
            "GIT_OBJECT_DIRECTORY": str(self.repo / ".git/objects"),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(self.repo / ".git/objects"),
            "GIT_NAMESPACE": "fixture",
            "GIT_PREFIX": "fixture/",
            "GIT_GRAFT_FILE": str(self.root / "grafts"),
            "GIT_SHALLOW_FILE": str(self.root / "shallow"),
            "GIT_REPLACE_REF_BASE": "refs/fixture/",
            "GIT_ATTR_SOURCE": "HEAD",
            "GIT_CONFIG": str(self.root / "config"),
            "GIT_CONFIG_GLOBAL": str(self.root / "config"),
            "GIT_CONFIG_SYSTEM": str(self.root / "config"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_KEY_0": "core.worktree",
            "GIT_CONFIG_VALUE_0": "PRIVATE CONFIG VALUE",
            "GIT_CONFIG_PARAMETERS": "'core.worktree=PRIVATE CONFIG VALUE'",
        }
        for action in ("release", "retire"):
            if action == "retire":
                self.assertEqual(self.release().returncode, 0)
            before = record.read_bytes() if record.exists() else None
            for name, value in overrides.items():
                with (
                    self.subTest(action=action, variable=name),
                    patch.dict(os.environ, self.env | {name: value}),
                ):
                    with self.assertRaisesRegex(
                        ValueError, "Git environment overrides.*" + name
                    ) as raised:
                        if action == "release":
                            lifecycle.release(
                                self.repo,
                                self.worktree,
                                self.head,
                                "fixture-session",
                                7,
                                "fixture/repo",
                            )
                        else:
                            lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
                    self.assertNotIn("PRIVATE CONFIG VALUE", str(raised.exception))
                    self.assertEqual(record.read_bytes() if record.exists() else None, before)
                    self.assertFalse((self.root / "archive").exists())
                    self.assertTrue(self.worktree.is_dir())

    def test_git_transport_and_forced_defensive_environment_remain_supported(self):
        from unittest.mock import patch

        self.merged()
        transport = {
            "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
            "GIT_SSH": "/fixture/ssh",
            "GIT_ASKPASS": "/fixture/askpass",
            "SSH_AUTH_SOCK": "/fixture/agent.sock",
        }
        self.env.update(
            transport, GIT_OPTIONAL_LOCKS="1", GIT_NO_REPLACE_OBJECTS="0", GIT_TERMINAL_PROMPT="1"
        )
        lifecycle, _ = self.process_fixture()
        names = [*transport, "GIT_OPTIONAL_LOCKS", "GIT_NO_REPLACE_OBJECTS", "GIT_TERMINAL_PROMPT"]
        with patch.dict(os.environ, self.env):
            actual = json.loads(
                lifecycle.run(
                    [
                        sys.executable,
                        "-c",
                        "import json,os,sys; print(json.dumps({name:os.environ[name] for name in sys.argv[1:]}))",
                        *names,
                    ]
                )
            )
        self.assertEqual(
            actual,
            transport
            | {
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_TERMINAL_PROMPT": "0",
            },
        )
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)

    @contextmanager
    def threaded_worker(self, topology, kind="fd", target=None):
        compiler = shutil.which("cc")
        if not compiler or not Path("/proc/self/task").is_dir():
            self.skipTest("native thread fixture requires a C compiler and Linux /proc")
        target = target or self.worktree / "file"
        source = self.root / "threads.c"
        source.write_text(r"""
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
""")
        executable = self.root / "threads"
        subprocess.run(
            [compiler, "-pthread", str(source), "-o", str(executable)],
            check=True,
            capture_output=True,
            timeout=15,
        )
        child = subprocess.Popen(
            [str(executable), topology, kind, str(target.parent if kind == "cwd" else target)],
            cwd=self.root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        entry = self.proc / str(child.pid)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], "thread readiness timeout")
            tid, descriptor = map(int, child.stdout.readline().split())
            entry.symlink_to(Path("/proc") / str(child.pid), target_is_directory=True)
            thread = entry / "task" / str(tid)
            if topology == "leader-exit":
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if b"State:\tZ" in (entry / "status").read_bytes():
                        break
                    time.sleep(0.01)
                self.assertIn(b"State:\tZ", (entry / "status").read_bytes())
            if kind == "fd":
                self.assertEqual(os.readlink(thread / "fd" / str(descriptor)), str(target))
            if topology == "private":
                self.assertEqual(Path(os.readlink(entry / "cwd")), self.root.resolve())
                self.assertNotIn(str(target), [os.readlink(fd) for fd in (entry / "fd").iterdir()])
            if kind == "mapping":
                self.assertNotIn(str(target), [os.readlink(fd) for fd in (thread / "fd").iterdir()])
                self.assertIn(str(target), (thread / "maps").read_text())
            yield child, thread
        finally:
            child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()
            entry.unlink(missing_ok=True)

    def assert_thread_reference_retained(self, topology, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.threaded_worker(topology, kind) as (child, thread):
            result = (
                self.retire("--apply", "--archive-dir", str(self.root / "archive"))
                if after_release
                else self.release()
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("active process", result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertNotIn(b"State:\tZ", (thread / "status").read_bytes())
            self.assertFalse((self.root / "archive").exists())

    def test_exited_leader_cannot_hide_live_thread_references_from_release(self):
        for kind in ("fd", "mapping", "cwd"):
            with self.subTest(surface=kind):
                with self.threaded_worker("leader-exit", kind):
                    result = self.release()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("active process", result.stderr)

    def test_exited_leader_thread_descriptor_refuses_retirement(self):
        self.assert_thread_reference_retained("leader-exit", "fd", True)

    def test_exited_leader_thread_mapping_refuses_retirement(self):
        self.assert_thread_reference_retained("leader-exit", "mapping", True)

    def test_exited_leader_thread_cwd_refuses_retirement(self):
        self.assert_thread_reference_retained("leader-exit", "cwd", True)

    def test_private_thread_filesystem_and_descriptors_refuse_release(self):
        for kind in ("fd", "cwd"):
            with self.subTest(surface=kind):
                with self.threaded_worker("private", kind):
                    result = self.release()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("active process", result.stderr)
                    self.assertTrue(self.worktree.exists())

    def test_private_thread_descriptors_refuse_retirement(self):
        self.assert_thread_reference_retained("private", "fd", True)

    def test_private_thread_cwd_refuses_retirement(self):
        self.assert_thread_reference_retained("private", "cwd", True)

    def test_readable_unrelated_multithreaded_process_is_safe(self):
        self.merged()
        unrelated = self.root / "unrelated"
        unrelated.write_text("outside the task\n")
        with self.threaded_worker("shared", target=unrelated) as (child, thread):
            self.assertGreaterEqual(len(list(thread.parent.iterdir())), 2)
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(unrelated.read_text(), "outside the task\n")

    @contextmanager
    def worker(self, kind, target=None):
        target = target or self.worktree / "file"
        program = r"""
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
"""
        child = subprocess.Popen(
            [sys.executable, "-B", "-c", program, kind, str(target)],
            cwd=self.root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        entry = self.proc / str(child.pid)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], "worker readiness timeout")
            self.assertEqual(child.stdout.readline(), b"ready\n")
            entry.symlink_to(Path("/proc") / str(child.pid), target_is_directory=True)
            if kind != "cwd":
                self.assertEqual(Path(os.readlink(entry / "cwd")), self.root.resolve())
            if kind == "mapping":
                targets = [os.readlink(fd) for fd in (entry / "fd").iterdir()]
                self.assertNotIn(
                    str(target), targets, "mapping fixture retained a backing descriptor"
                )
            yield child
        finally:
            child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()
            entry.unlink(missing_ok=True)

    def assert_process_reference_retained(self, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.worker(kind) as child:
            result = (
                self.retire("--apply", "--archive-dir", str(self.root / "archive"))
                if after_release
                else self.release()
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("active process", result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertFalse((self.root / "archive").exists())

    def test_open_descriptor_refuses_release(self):
        self.assert_process_reference_retained("fd", False)

    def test_open_descriptor_refuses_retirement(self):
        self.assert_process_reference_retained("fd", True)

    def test_closed_descriptor_mapping_refuses_release(self):
        self.assert_process_reference_retained("mapping", False)

    def test_closed_descriptor_mapping_refuses_retirement(self):
        self.assert_process_reference_retained("mapping", True)

    def test_cwd_refuses_release(self):
        self.assert_process_reference_retained("cwd", False)

    def test_mapping_in_newline_worktree_path_refuses_release(self):
        moved = self.root / "task\nwith space"
        self.run_git(self.repo, "worktree", "move", str(self.worktree), str(moved))
        self.worktree = moved
        self.assert_process_reference_retained("mapping", False)

    def test_unrelated_worker_does_not_block_retirement(self):
        self.merged()
        unrelated = self.root / "unrelated"
        unrelated.write_text("outside the task\n")
        with self.worker("fd", unrelated) as child:
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(unrelated.read_text(), "outside the task\n")

    def assert_private_admin_writer_retained(self, after_release):
        self.merged()
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        evidence = admin / "owned-runtime-evidence.log"
        evidence.write_text("before liveness scan\n")
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        with self.worker("writer", evidence) as child:
            result = (
                self.retire("--apply", "--archive-dir", str(self.root / "archive"))
                if after_release
                else self.release()
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("active process", result.stderr)
            child.stdin.write(b"x")
            child.stdin.flush()
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], "writer response timeout")
            self.assertEqual(child.stdout.readline(), b"updated\n")
            self.assertEqual(evidence.read_text(), "before liveness scan\nafter liveness scan\n")
            self.assertTrue(self.worktree.exists())
            self.assertIsNone(child.poll())
            self.assertFalse((self.root / "archive").exists())

    def test_private_admin_writer_refuses_release(self):
        self.assert_private_admin_writer_retained(False)

    def test_private_admin_writer_refuses_retirement(self):
        self.assert_private_admin_writer_retained(True)

    def test_common_git_metadata_reference_does_not_block_retirement(self):
        self.merged()
        common = Path(
            self.run_git(
                self.worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ).strip()
        )
        evidence = common / "shared-runtime-evidence.log"
        evidence.write_text("shared repository evidence\n")
        with self.worker("fd", evidence) as child:
            result = self.release()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(child.poll())
            self.assertEqual(evidence.read_text(), "shared repository evidence\n")

    def assert_private_admin_special_file_retained(self, kind, after_release):
        self.merged()
        if after_release:
            self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        endpoint = admin / "runtime/endpoint"
        endpoint.parent.mkdir()
        if kind == "fifo":
            os.mkfifo(endpoint)
        with self.worker("socket", endpoint) if kind == "socket" else nullcontext() as child:
            result = (
                self.retire("--apply", "--archive-dir", str(self.root / "archive"))
                if after_release
                else self.release()
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("special Git metadata", result.stderr)
            self.assertTrue(self.worktree.exists())
            self.assertTrue(endpoint.exists())
            self.assertFalse((self.root / "archive").exists())
            if child is not None:
                self.assertIsNone(child.poll())
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(str(endpoint))

    def test_private_admin_socket_refuses_release(self):
        self.assert_private_admin_special_file_retained("socket", False)

    def test_private_admin_socket_refuses_retirement(self):
        self.assert_private_admin_special_file_retained("socket", True)

    def test_private_admin_fifo_refuses_release(self):
        self.assert_private_admin_special_file_retained("fifo", False)

    def test_private_admin_fifo_refuses_retirement(self):
        self.assert_private_admin_special_file_retained("fifo", True)

    def test_regular_private_metadata_is_archived_without_following_symlinks(self):
        self.merged()
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        (admin / "evidence/empty").mkdir(parents=True)
        (admin / "evidence/notes").write_bytes(b"private regular metadata\x00\n")
        os.link(admin / "evidence/notes", admin / "evidence/linked-notes")
        outside = self.root / "outside-metadata"
        outside.mkdir()
        os.mkfifo(outside / "live-fifo")
        (admin / "external").symlink_to(outside, target_is_directory=True)
        broken_target = os.fsdecode(b"missing-target-\xff")
        (admin / "broken").symlink_to(broken_target)
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)["archive"])
        with tarfile.open(archive / "worktree-metadata.tar") as stream:
            self.assertEqual(
                stream.extractfile("worktree-metadata/evidence/notes").read(),
                b"private regular metadata\x00\n",
            )
            self.assertEqual(
                stream.extractfile("worktree-metadata/evidence/linked-notes").read(),
                b"private regular metadata\x00\n",
            )
            self.assertTrue(
                any(
                    stream.getmember("worktree-metadata/evidence/" + name).islnk()
                    for name in ("notes", "linked-notes")
                )
            )
            self.assertTrue(stream.getmember("worktree-metadata/evidence/empty").isdir())
            for name in ("external", "broken"):
                self.assertTrue(stream.getmember("worktree-metadata/" + name).issym())
            self.assertEqual(stream.getmember("worktree-metadata/external").linkname, str(outside))
            self.assertEqual(
                os.fsencode(stream.getmember("worktree-metadata/broken").linkname),
                os.fsencode(broken_target),
            )
            self.assertNotIn("worktree-metadata/external/live-fifo", stream.getnames())
        self.assertTrue((outside / "live-fifo").exists())

    def assert_completed_metadata_change_retained(self, mutation):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        evidence = admin / "evidence.txt"
        evidence.write_bytes(b"original metadata\n")
        evidence.chmod(0o600)
        (admin / "empty").mkdir(mode=0o700)
        (admin / "pointer").symlink_to("missing-target")
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        # Keep the actual scanner, including a live native process, while the
        # writer closes its descriptor and exits before the final assessment.
        (self.proc / str(os.getpid())).symlink_to(
            Path("/proc") / str(os.getpid()), target_is_directory=True
        )
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original_assess = lifecycle.assess
        assessments = []

        def assess_after_completed_writer(repo, path, *args):
            assessments.append(path)
            if len(assessments) == 2:
                subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        "import os,pathlib,sys; admin=pathlib.Path(sys.argv[1]); "
                        'evidence=admin/"evidence.txt"; ' + mutation,
                        str(admin),
                    ],
                    check=True,
                    timeout=5,
                )
            return original_assess(repo, path, *args)

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "assess", assess_after_completed_writer),
        ):
            with self.assertRaisesRegex(ValueError, "metadata changed.*retained.*archive:"):
                lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        self.assertEqual(len(assessments), 2)
        self.assertTrue(self.worktree.is_dir())
        (archive,) = (self.root / "archive").iterdir()
        with tarfile.open(archive / "worktree-metadata.tar") as stream:
            self.assertEqual(
                stream.extractfile("worktree-metadata/evidence.txt").read(), b"original metadata\n"
            )
        self.assertTrue((archive / "repository.bundle").is_file())
        self.assertTrue((archive / "recovery.json").is_file())
        return admin

    def test_completed_metadata_writer_after_archive_retains_worktree(self):
        admin = self.assert_completed_metadata_change_retained(
            'evidence.write_bytes(b"NEW PRIVATE EVIDENCE\\n")'
        )
        self.assertEqual((admin / "evidence.txt").read_bytes(), b"NEW PRIVATE EVIDENCE\n")

    def test_metadata_same_size_write_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            'before=evidence.stat(); evidence.write_bytes(b"changed! metadata\\n"); '
            "os.utime(evidence, ns=(before.st_atime_ns, before.st_mtime_ns))"
        )

    def test_metadata_file_created_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            '(admin/"new-evidence").write_bytes(b"new evidence")'
        )

    def test_metadata_file_deleted_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained("evidence.unlink()")

    def test_metadata_mode_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained("evidence.chmod(0o700)")

    def test_metadata_directory_mode_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"empty").chmod(0o500)')

    def test_metadata_directory_created_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"new-empty").mkdir()')

    def test_metadata_directory_deleted_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained('(admin/"empty").rmdir()')

    def test_metadata_symlink_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            '(admin/"pointer").unlink(); (admin/"pointer").symlink_to("other-missing-target")'
        )

    def test_metadata_type_changed_after_archive_retains_worktree(self):
        self.assert_completed_metadata_change_retained(
            'empty=admin/"empty"; empty.rmdir(); empty.write_bytes(b""); empty.chmod(0o700)'
        )

    def test_scanner_itself_has_complete_descriptor_evidence(self):
        module, _ = self.process_fixture()
        (self.proc / str(os.getpid())).symlink_to(
            Path("/proc") / str(os.getpid()), target_is_directory=True
        )
        module.active_processes(self.worktree, self.proc)

    def test_inventory_distinguishes_unreleased_work_from_settings_drift(self):
        result = self.cli("inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        items = json.loads(result.stdout)["worktrees"]
        task = next(item for item in items if item["path"] == str(self.worktree))
        self.assertEqual(task["disposition"], "retained")
        self.assertIn("unreleased", task["reason"])
        self.assertTrue(self.worktree.exists())

    def test_inventory_root_includes_nested_worktrees_without_marking_primary_obsolete(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "inventory", "--root", str(self.root)],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["retained"], 1)
        self.assertEqual(data["released"], 0)
        self.assertEqual(len(data["worktrees"]), 2)

    def root_inventory(self, root=None):
        result = subprocess.run(
            ["python3", str(SCRIPT), "inventory", "--root", str(root or self.root)],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def separate_git_directory(self):
        # Only the disposable fixture is removed; its committed topic survives.
        self.run_git(self.repo, "worktree", "remove", "--force", str(self.worktree))
        metadata = self.root / "metadata.git"
        self.run_git(self.repo, "init", "-q", "--separate-git-dir", str(metadata))
        self.run_git(self.repo, "worktree", "add", "-q", str(self.worktree), "topic")
        self.assertTrue((self.repo / ".git").is_file())
        return metadata

    def test_inventory_root_finds_primary_with_separate_git_directory(self):
        self.separate_git_directory()
        direct = self.cli("inventory")
        self.assertEqual(direct.returncode, 0, direct.stderr)
        expected = json.loads(direct.stdout)["worktrees"]
        self.assertEqual(len(expected), 2)
        actual = self.root_inventory()
        self.assertEqual(actual["errors"], [])
        self.assertEqual(actual["worktrees"], expected)

    def test_inventory_root_deduplicates_common_directory_and_skips_linked_children(self):
        metadata = self.separate_git_directory()
        alias = self.root / "aaa-primary-alias"
        alias.mkdir()
        # A second Git-file spelling of the same common directory must not
        # duplicate its inventory, even when encountered before the checkout.
        (alias / ".git").write_text("gitdir: ../metadata.git\n")
        self.assertEqual(
            Path(self.run_git(alias, "rev-parse", "--absolute-git-dir").strip()).resolve(), metadata
        )
        data = self.root_inventory()
        self.assertEqual(data["errors"], [])
        self.assertEqual(len(data["worktrees"]), 2)
        self.assertEqual(len({item["path"] for item in data["worktrees"]}), 2)
        linked_only = self.root / "linked-only"
        linked_only.mkdir()
        self.run_git(self.repo, "worktree", "move", str(self.worktree), str(linked_only / "task"))
        self.assertEqual(self.root_inventory(linked_only)["worktrees"], [])

    def test_inventory_root_skips_symlinked_children_and_does_not_recurse(self):
        (self.root / "aaa-symlink").symlink_to(self.repo, target_is_directory=True)
        nested = self.root / "nested"
        nested.mkdir()
        self.run_git(nested, "init", "-q", str(nested / "unrelated"))
        data = self.root_inventory()
        self.assertEqual(data["errors"], [])
        self.assertEqual(len(data["worktrees"]), 2)

    def test_inventory_root_reports_malformed_or_dangling_git_files(self):
        invalid = self.root / "invalid"
        invalid.mkdir()
        for content in ("not a gitdir pointer\n", "gitdir: ../missing-metadata\n"):
            with self.subTest(content=content):
                (invalid / ".git").write_text(content)
                data = self.root_inventory()
                self.assertEqual(len(data["worktrees"]), 2)
                self.assertEqual([error["repo"] for error in data["errors"]], [str(invalid)])
                self.assertTrue(data["errors"][0]["reason"])

    @unittest.skipIf(os.geteuid() == 0, "root can read mode-zero Git files")
    def test_inventory_root_reports_unreadable_git_file(self):
        self.separate_git_directory()
        pointer = self.repo / ".git"
        mode = pointer.stat().st_mode & 0o777
        pointer.chmod(0)
        try:
            data = self.root_inventory()
            self.assertEqual([error["repo"] for error in data["errors"]], [str(self.repo)])
            self.assertEqual(data["worktrees"], [])
        finally:
            pointer.chmod(mode)

    def test_inventory_retains_release_after_same_head_branch_change(self):
        self.assertEqual(self.release().returncode, 0)
        self.run_git(self.worktree, "switch", "-qc", "different-topic")
        self.assertEqual(self.run_git(self.worktree, "rev-parse", "HEAD").strip(), self.head)
        result = self.cli("inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(
            item
            for item in json.loads(result.stdout)["worktrees"]
            if item["path"] == str(self.worktree)
        )
        self.assertEqual(task["disposition"], "retained")
        self.assertIn("branch changed since release", task["reason"])

    def test_inventory_retains_release_after_same_head_move(self):
        self.assertEqual(self.release().returncode, 0)
        moved = self.root / "moved"
        self.run_git(self.repo, "worktree", "move", str(self.worktree), str(moved))
        self.assertEqual(self.run_git(moved, "rev-parse", "HEAD").strip(), self.head)
        result = self.cli("inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(
            item for item in json.loads(result.stdout)["worktrees"] if item["path"] == str(moved)
        )
        self.assertEqual(task["disposition"], "retained")
        self.assertIn("path or branch changed since release", task["reason"])

    def test_inventory_checks_current_release_without_remote_calls(self):
        self.assertEqual(self.release().returncode, 0)
        called = self.root / "remote-called"
        (self.bin / "gh").write_text(
            "#!/usr/bin/env python3\nfrom pathlib import Path\n"
            f"Path({str(called)!r}).touch()\nraise SystemExit(1)\n"
        )
        result = self.cli("inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        task = next(
            item
            for item in json.loads(result.stdout)["worktrees"]
            if item["path"] == str(self.worktree)
        )
        self.assertEqual(task["disposition"], "released")
        self.assertFalse(called.exists())

    def test_hygiene_status_reports_worktrees_separately(self):
        home = self.root / "home"
        folder = home / ".local/state/hygiene"
        folder.mkdir(parents=True)
        record = {"worktrees": [], "retained": 2, "released": 1}
        (folder / "worktrees.json").write_text(json.dumps(record))
        result = subprocess.run(
            ["bash", str(SCRIPT.parents[2] / "hygiene-status.sh"), "--worktrees"],
            env=dict(self.env, HOME=str(home)),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), record)

    def test_unreleased_and_pending_worktrees_are_preserved(self):
        self.assertNotEqual(
            self.retire("--apply", "--archive-dir", str(self.root / "archive")).returncode, 0
        )
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("merged", result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_merged_worktree_requires_apply_and_archives_evidence(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        receipts = admin / "review-receipts"
        receipts.mkdir()
        (receipts / "evidence.json").write_text('{"review":"fixture"}\n')
        preview = self.retire()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertTrue(self.worktree.exists())
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.worktree.exists())
        archive = Path(json.loads(result.stdout)["archive"])
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertTrue((archive / "repository.bundle").exists())
        self.assertTrue((archive / "worktree-metadata.tar").exists())
        self.assertEqual(json.loads((archive / "recovery.json").read_text())["head"], self.head)
        self.assertEqual(self.run_git(self.repo, "rev-parse", "topic").strip(), self.head)

    def worktree_block(self, path):
        """The `git worktree list --porcelain` lines describing one checkout."""
        target = Path(path).resolve()
        for block in self.run_git(self.repo, "worktree", "list", "--porcelain").split("\n\n"):
            lines = block.splitlines()
            if lines and Path(lines[0].removeprefix("worktree ")).resolve() == target:
                return lines
        raise AssertionError(f"{path} is not a registered worktree")

    def test_retirement_detaches_head_and_frees_the_branch_ref(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        quarantine = Path(payload["quarantine"])
        block = self.worktree_block(quarantine)
        self.assertIn("detached", block)
        self.assertNotIn("branch refs/heads/topic", block)
        self.assertEqual(self.run_git(quarantine, "rev-parse", "HEAD").strip(), self.head)
        self.assertEqual(payload["branch"], "refs/heads/topic")
        self.assertIs(payload["detached"], True)
        self.assertIs(payload["branch_deleted"], False)
        # The record is written before the detach, so it still names the branch.
        record = json.loads((Path(payload["archive"]) / "recovery.json").read_text())
        self.assertEqual(record["branch"], "refs/heads/topic")
        # Ordinary post-merge cleanup now succeeds instead of failing forever on
        # the quarantined worktree's checkout (#498).
        self.run_git(self.repo, "branch", "-D", "topic")
        self.assertEqual(self.run_git(self.repo, "branch", "--list", "topic").strip(), "")
        self.assertEqual(self.run_git(quarantine, "rev-parse", "HEAD").strip(), self.head)

    def test_retirement_preview_detaches_nothing(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        preview = self.retire("--delete-branch")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        payload = json.loads(preview.stdout)
        self.assertEqual(payload["disposition"], "ready")
        self.assertIs(payload["branch_deleted"], False)
        self.assertIn("--apply", payload["branch_reason"])
        block = self.worktree_block(self.worktree)
        self.assertIn("branch refs/heads/topic", block)
        self.assertNotIn("detached", block)
        self.assertEqual(self.run_git(self.repo, "rev-parse", "topic").strip(), self.head)
        self.assertTrue(self.worktree.exists())

    def test_delete_branch_removes_the_verified_merged_ref(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire(
            "--apply", "--archive-dir", str(self.root / "archive"), "--delete-branch"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIs(payload["branch_deleted"], True)
        self.assertEqual(payload["branch"], "refs/heads/topic")
        self.assertEqual(self.run_git(self.repo, "branch", "--list", "topic").strip(), "")
        # The released commit stays recoverable from the detached quarantine and
        # from the independent bundle after the ref is gone.
        quarantine = Path(payload["quarantine"])
        self.assertEqual(self.run_git(quarantine, "rev-parse", "HEAD").strip(), self.head)
        bundle = str(Path(payload["archive"]) / "repository.bundle")
        self.assertIn(self.head, self.run_git(self.repo, "bundle", "list-heads", bundle))

    def test_delete_branch_leaves_an_unnamed_release_alone(self):
        self.run_git(self.worktree, "checkout", "-q", "--detach")
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire(
            "--apply", "--archive-dir", str(self.root / "archive"), "--delete-branch"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIs(payload["branch_deleted"], False)
        self.assertIn("no branch", payload["branch_reason"])
        self.assertEqual(self.run_git(self.repo, "rev-parse", "topic").strip(), self.head)

    def lifecycle_module(self, name="lifecycle_branch"):
        import importlib.util

        spec = importlib.util.spec_from_file_location(name, SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_delete_branch_refuses_a_ref_a_rebase_or_bisect_still_holds(self):
        module = self.lifecycle_module()
        spare = self.root / "spare"
        self.run_git(self.repo, "worktree", "add", "-q", "-b", "held", str(spare), self.head)
        admin = Path(self.run_git(spare, "rev-parse", "--absolute-git-dir").strip())
        self.run_git(spare, "checkout", "-q", "--detach")
        # An interrupted rebase or bisect reports `detached` in worktree list
        # while Git still refuses to delete the branch it started from. Write
        # exactly the state Git reads, and pin that refusal beside our own.
        states = {
            "rebase-merge": {"head-name": "refs/heads/held\n"},
            "rebase-apply": {"head-name": "refs/heads/held\n"},
            ".": {"BISECT_LOG": "", "BISECT_START": "held\n"},
        }
        for directory, files in states.items():
            with self.subTest(state=directory):
                (admin / directory).mkdir(exist_ok=True)
                for name, content in files.items():
                    (admin / directory / name).write_text(content)
                try:
                    self.assertIn("detached", self.worktree_block(spare))
                    with self.assertRaises(subprocess.CalledProcessError):
                        self.run_git(self.repo, "branch", "-D", "held")
                    deleted, reason = module.delete_released_branch(
                        self.repo, "refs/heads/held", self.head
                    )
                    self.assertFalse(deleted)
                    self.assertIn("still held by", reason)
                finally:
                    for name in files:
                        (admin / directory / name).unlink()
                    if directory != ".":
                        (admin / directory).rmdir()
        self.assertEqual(self.run_git(self.repo, "rev-parse", "held").strip(), self.head)

    def test_delete_branch_refuses_a_moved_missing_symbolic_or_shared_ref(self):
        module = self.lifecycle_module()
        main = self.run_git(self.repo, "rev-parse", "main").strip()
        self.run_git(self.repo, "branch", "moved", main)
        self.run_git(self.repo, "symbolic-ref", "refs/heads/alias", "refs/heads/topic")
        self.run_git(self.repo, "branch", "spare", self.head)
        refusals = {
            "refs/heads/moved": "moved",
            "refs/heads/gone": "no longer resolves",
            "refs/heads/alias": "symbolic",
            "refs/heads/topic": "still held by",
            "refs/tags/v1": "not a local branch",
        }
        for branch, expected in refusals.items():
            with self.subTest(branch=branch):
                deleted, reason = module.delete_released_branch(self.repo, branch, self.head)
                self.assertFalse(deleted)
                self.assertIn(expected, reason)
        self.assertEqual(
            module.delete_released_branch(self.repo, "refs/heads/spare", self.head), (True, None)
        )
        self.assertEqual(self.run_git(self.repo, "branch", "--list", "spare").strip(), "")
        self.assertEqual(self.run_git(self.repo, "rev-parse", "topic").strip(), self.head)
        self.assertEqual(self.run_git(self.repo, "rev-parse", "moved").strip(), main)

    def test_delete_branch_removes_the_branch_configuration_section(self):
        # `update-ref -d` leaves branch.<name>.* behind, so a later branch of
        # the same name would silently inherit its upstream and rebase settings.
        self.run_git(self.repo, "config", "branch.topic.remote", "origin")
        self.run_git(self.repo, "config", "branch.topic.merge", "refs/heads/topic")
        self.run_git(self.repo, "config", "branch.topic.rebase", "true")
        self.run_git(self.repo, "config", "branch.topic.x.remote", "origin")
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire(
            "--apply", "--archive-dir", str(self.root / "archive"), "--delete-branch"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIs(payload["branch_deleted"], True, payload)
        self.assertEqual(self.run_git(self.repo, "branch", "--list", "topic").strip(), "")
        names = self.run_git(self.repo, "config", "--local", "--name-only", "--list").split()
        self.assertEqual([name for name in names if name.rpartition(".")[0] == "branch.topic"], [])
        # A branch whose name merely extends this one keeps its own section.
        self.assertIn("branch.topic.x.remote", names)

    def test_delete_branch_restores_a_ref_a_worktree_attached_during_deletion(self):
        module = self.lifecycle_module()
        self.run_git(self.repo, "branch", "spare", self.head)
        late = self.root / "late"
        original = module.branch_holders
        calls = []

        def attach_after_check(repo, branch):
            holders = original(repo, branch)
            calls.append(holders)
            if len(calls) == 1:
                # Another process attaches the branch between the holder check
                # and the deletion.
                self.run_git(self.repo, "worktree", "add", "-q", str(late), "spare")
            return holders

        module.branch_holders = attach_after_check
        deleted, reason = module.delete_released_branch(self.repo, "refs/heads/spare", self.head)
        self.assertFalse(deleted)
        self.assertIn("restored", reason)
        self.assertIn(str(late), reason)
        self.assertEqual(self.run_git(self.repo, "rev-parse", "spare").strip(), self.head)
        self.assertEqual(self.run_git(late, "rev-parse", "HEAD").strip(), self.head)
        self.assertEqual(self.run_git(late, "symbolic-ref", "HEAD").strip(), "refs/heads/spare")

    def test_final_ignored_write_is_preserved_in_locked_quarantine(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.run_git(self.worktree, "config", "core.excludesFile", str(self.root / "ignore"))
        (self.root / "ignore").write_text("late.secret\n")
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original = lifecycle.archived_metadata_matches

        def late_write(admin, archive):
            matches = original(admin, archive)
            (self.worktree / "late.secret").write_bytes(b"late operator data\n")
            return matches

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "archived_metadata_matches", late_write),
        ):
            result = lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        quarantine = Path(result["archive"]) / "worktree"
        self.assertTrue(
            quarantine.is_dir(),
            "retirement deleted the late ignored file instead of retaining the tree",
        )
        self.assertEqual((quarantine / "late.secret").read_bytes(), b"late operator data\n")
        self.assertEqual(result["disposition"], "quarantined")
        self.assertFalse(self.worktree.exists())
        self.assertEqual(self.run_git(quarantine, "rev-parse", "HEAD").strip(), self.head)
        admin = Path(self.run_git(quarantine, "rev-parse", "--absolute-git-dir").strip())
        self.assertTrue((admin / "locked").is_file())
        self.run_git(self.repo, "worktree", "prune", "--expire", "now")
        self.assertTrue(admin.is_dir())

    def test_worktree_directory_override_requires_separate_retirement(self):
        self.run_git(self.repo, "config", "extensions.worktreeConfig", "true")
        self.run_git(self.worktree, "config", "--worktree", "core.worktree", str(self.worktree))
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        original_config = (admin / "config.worktree").read_bytes()
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("core.worktree", result.stderr)
        self.assertEqual((self.worktree / "file").read_text(), "feature\n")
        self.assertEqual((admin / "config.worktree").read_bytes(), original_config)
        self.assertFalse((self.root / "archive").exists())
        self.assertFalse((admin / "locked").exists())

    def test_other_worktree_configuration_survives_quarantine(self):
        self.run_git(self.repo, "config", "extensions.worktreeConfig", "true")
        self.run_git(self.worktree, "config", "--worktree", "fixture.keep", "operator setting")
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip()
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        quarantine = Path(json.loads(result.stdout)["quarantine"])
        self.assertEqual(
            self.run_git(quarantine, "rev-parse", "--show-toplevel").strip(), str(quarantine)
        )
        self.assertEqual(self.run_git(quarantine, "rev-parse", "--absolute-git-dir").strip(), admin)
        self.assertEqual(
            self.run_git(quarantine, "config", "--worktree", "fixture.keep").strip(),
            "operator setting",
        )

    def test_post_repair_directory_redirect_cannot_report_success(self):
        from functools import partial
        from unittest.mock import patch

        self.run_git(self.repo, "config", "extensions.worktreeConfig", "true")
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        original = lifecycle.git

        def redirect_after_repair(repo, *args):
            result = original(repo, *args)
            if args[:2] == ("worktree", "repair"):
                self.worktree.mkdir()
                (self.worktree / "new-session").write_text("unrelated operator work\n")
                original(Path(args[2]), "config", "--worktree", "core.worktree", str(self.worktree))
            return result

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "git", redirect_after_repair),
        ):
            with self.assertRaisesRegex(ValueError, "retained.*archive:"):
                lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        (archive,) = (self.root / "archive").iterdir()
        self.assertEqual((archive / "worktree/file").read_text(), "feature\n")
        self.assertEqual((self.worktree / "new-session").read_text(), "unrelated operator work\n")
        self.assertTrue((admin / "locked").is_file())

    def test_interrupted_quarantine_preserves_tree_and_git_metadata(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        original = lifecycle.git

        def interrupted_repair(repo, *args):
            if args[:2] == ("worktree", "repair"):
                raise ValueError("interrupted repair")
            return original(repo, *args)

        with patch.dict(os.environ, self.env), patch.object(lifecycle, "git", interrupted_repair):
            with self.assertRaisesRegex(ValueError, "retained.*archive:"):
                lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        (archive,) = (self.root / "archive").iterdir()
        quarantine = archive / "worktree"
        self.assertEqual((quarantine / "file").read_text(), "feature\n")
        self.assertTrue((admin / "locked").is_file())
        self.run_git(self.repo, "worktree", "prune", "--expire", "now")
        self.assertTrue(admin.is_dir(), "interrupted move left metadata vulnerable to prune")
        self.run_git(self.repo, "worktree", "repair", str(quarantine))
        self.assertEqual(self.run_git(quarantine, "rev-parse", "HEAD").strip(), self.head)

    def test_late_descriptor_write_survives_quarantine(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original = lifecycle.archived_metadata_matches
        streams = []

        def late_open(admin, archive):
            matches = original(admin, archive)
            streams.append((self.worktree / "file").open("ab", buffering=0))
            return matches

        try:
            with (
                patch.dict(os.environ, self.env),
                patch.object(lifecycle, "archived_metadata_matches", late_open),
            ):
                result = lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
            streams[0].write(b"after retirement\n")
            quarantine = Path(result["archive"]) / "worktree"
            self.assertTrue(quarantine.is_dir(), "late open descriptor now points at unlinked data")
            self.assertEqual((quarantine / "file").read_bytes(), b"feature\nafter retirement\n")
        finally:
            for stream in streams:
                stream.close()

    def test_failed_quarantine_rename_retains_original_and_lock(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle.os, "rename", side_effect=OSError("rename refused")),
        ):
            with self.assertRaisesRegex(ValueError, "retained.*archive:"):
                lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        self.assertEqual((self.worktree / "file").read_text(), "feature\n")
        self.assertTrue((admin / "locked").is_file())
        (archive,) = (self.root / "archive").iterdir()
        self.assertFalse((archive / "worktree").exists())
        self.assertEqual(
            json.loads((archive / "recovery.json").read_text())["quarantine"],
            str(archive / "worktree"),
        )

    def test_recreated_original_path_survives_quarantine_repair(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original = lifecycle.os.rename

        def recreate_after_move(source, destination):
            original(source, destination)
            source.mkdir()
            (source / "new-session").write_text("new operator work\n")

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle.os, "rename", recreate_after_move),
        ):
            result = lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        self.assertEqual((self.worktree / "new-session").read_text(), "new operator work\n")
        self.assertEqual((Path(result["quarantine"]) / "file").read_text(), "feature\n")

    def test_archive_rejects_actual_primary_with_separate_git_directory(self):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        destination = self.repo / "private-recovery"
        result = self.retire("--apply", "--archive-dir", str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("conventional primary checkout", result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_rejects_symlink_into_conventional_primary(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / "primary-alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        destination = alias / "private-recovery"
        result = self.retire("--apply", "--archive-dir", str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("archive must be outside", result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_separate_metadata_allows_preview_but_retains_applied_retirement(self):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        inventory = self.cli("inventory")
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        task = next(
            item
            for item in json.loads(inventory.stdout)["worktrees"]
            if item["path"] == str(self.worktree)
        )
        self.assertEqual(task["disposition"], "released")
        preview = self.retire()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)["disposition"], "ready")
        destination = self.root / "private-recovery"
        result = self.retire("--apply", "--archive-dir", str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("conventional primary checkout", result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_gitfile_alias_cannot_archive_inside_unlisted_external_primary(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / "alias"
        alias.mkdir()
        (alias / ".git").write_text("gitdir: ../metadata.git\n")
        self.assertEqual(
            Path(self.run_git(alias, "rev-parse", "--absolute-git-dir").strip()).resolve(), common
        )
        self.assertEqual(
            Path(self.run_git(alias, "rev-parse", "--show-toplevel").strip()).resolve(), alias
        )
        destination = self.repo / "private-recovery"
        result = subprocess.run(
            [
                "python3",
                str(self.runner),
                "retire",
                "--repo",
                str(alias),
                "--worktree",
                str(self.worktree),
                "--apply",
                "--archive-dir",
                str(destination),
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("conventional primary checkout", result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_primary_git_directory_symlink_cannot_enable_applied_retirement(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / ".git").unlink()
        (self.repo / ".git").symlink_to(common, target_is_directory=True)
        destination = self.root / "private-recovery"
        result = self.retire("--apply", "--archive-dir", str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("conventional primary checkout", result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_rejects_gitfile_alias_of_conventional_primary(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        alias = self.root / "alias"
        alias.mkdir()
        (alias / ".git").write_text("gitdir: ../repo/.git\n")
        destination = alias / "missing-parent/private-recovery"
        result = self.retire("--apply", "--archive-dir", str(destination))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("archive must be outside", result.stderr)
        self.assertFalse((alias / "missing-parent").exists())
        self.assertTrue(self.worktree.exists())

    def test_archive_with_unresolvable_git_ancestry_is_retained_before_creation(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        private = self.root / "private"
        private.mkdir()
        git_marker = private / ".git"
        for kind in ("malformed", "dangling", "empty-directory"):
            with self.subTest(marker=kind):
                if kind == "malformed":
                    git_marker.write_text("not a Git directory pointer\n")
                elif kind == "dangling":
                    git_marker.symlink_to(self.root / "missing.git", target_is_directory=True)
                else:
                    git_marker.mkdir()
                try:
                    result = self.retire("--apply", "--archive-dir", str(private / "recovery"))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((private / "recovery").exists())
                    self.assertTrue(self.worktree.exists())
                finally:
                    if git_marker.is_dir() and not git_marker.is_symlink():
                        git_marker.rmdir()
                    else:
                        git_marker.unlink()

    def test_archive_inside_different_private_repository_remains_supported(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        private = self.root / "private"
        self.run_git(self.root, "init", "-q", "-b", "main", str(private))
        result = self.retire("--apply", "--archive-dir", str(private / "recovery"))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)["archive"])
        self.assertTrue((archive / "repository.bundle").is_file())
        self.assertTrue((archive / "worktree-metadata.tar").is_file())
        self.assertFalse(self.worktree.exists())

    def test_archive_rejects_worktrees_and_git_metadata(self):
        common = self.repo / ".git"
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        admin = Path(self.run_git(self.worktree, "rev-parse", "--absolute-git-dir").strip())
        for root in (self.repo, self.worktree, common, admin):
            with self.subTest(root=root):
                destination = root / "private-recovery"
                result = self.retire("--apply", "--archive-dir", str(destination))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("archive must be outside", result.stderr)
                self.assertFalse(destination.exists())
                self.assertTrue(self.worktree.exists())

    def test_archive_linked_repo_requires_primary_before_creating_inside_or_outside_destination(
        self,
    ):
        self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for destination in (self.repo / "private-recovery", self.root / "private-recovery"):
            with self.subTest(destination=destination):
                result = subprocess.run(
                    [
                        "python3",
                        str(self.runner),
                        "retire",
                        "--repo",
                        str(self.worktree),
                        "--worktree",
                        str(self.worktree),
                        "--apply",
                        "--archive-dir",
                        str(destination),
                    ],
                    cwd=self.root,
                    env=self.env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("primary checkout", result.stderr)
                self.assertFalse(destination.exists())
                self.assertTrue(self.worktree.exists())

    def test_archive_metadata_only_repo_cannot_establish_actual_primary(self):
        common = self.separate_git_directory()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        destination = self.root / "private-recovery"
        result = subprocess.run(
            [
                "python3",
                str(self.runner),
                "retire",
                "--repo",
                str(common),
                "--worktree",
                str(self.worktree),
                "--apply",
                "--archive-dir",
                str(destination),
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(destination.exists())
        self.assertTrue(self.worktree.exists())

    def test_changed_head_unique_merge_and_remote_ambiguity_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        self.run_git(self.worktree, "merge", "--no-ff", "-qm", "unique merge", "main")
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HEAD", result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_dirty_ignored_untracked_and_locked_worktrees_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for kind in ("dirty", "untracked", "ignored", "locked"):
            with self.subTest(kind=kind):
                if kind == "dirty":
                    (self.worktree / "file").write_text("private changes")
                if kind == "untracked":
                    self.run_git(self.repo, "config", "status.showUntrackedFiles", "no")
                    (self.worktree / "private").write_text("private")
                if kind == "ignored":
                    (self.repo / ".git/info/exclude").write_text("private\n")
                    (self.worktree / "private").write_text("private")
                if kind == "locked":
                    self.run_git(self.repo, "worktree", "lock", str(self.worktree))
                self.assertNotEqual(self.retire().returncode, 0)
                self.assertTrue(self.worktree.exists())
                if kind == "dirty":
                    self.run_git(self.worktree, "restore", "file")
                if kind in ("untracked", "ignored"):
                    (self.worktree / "private").unlink()
                if kind == "locked":
                    self.run_git(self.repo, "worktree", "unlock", str(self.worktree))

    def test_active_process_and_unavailable_remote_evidence_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        child = subprocess.Popen(["sleep", "30"], cwd=self.worktree)
        (self.proc / str(child.pid)).symlink_to(
            Path("/proc") / str(child.pid), target_is_directory=True
        )
        try:
            result = self.retire()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("active", result.stderr)
        finally:
            child.terminate()
            child.wait()
            (self.proc / str(child.pid)).unlink()
        self.run_git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.worktree.exists())

    def test_filtered_local_bytes_are_retained_even_when_git_reports_clean(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / ".git/info/attributes").write_text("file filter=local\n")
        self.run_git(self.repo, "config", "filter.local.clean", "sed '/^PRIVATE_LOCAL=/d'")
        private = b"feature\nPRIVATE_LOCAL=unique\n"
        (self.worktree / "file").write_bytes(private)
        self.run_git(self.worktree, "add", "file")
        self.assertEqual(self.run_git(self.worktree, "status", "--porcelain"), "")
        self.assertNotEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.worktree / "file").read_bytes(), private)
        self.assertFalse((self.root / "archive").exists())

    def test_fifo_socket_and_empty_directory_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        endpoint = self.worktree / "operator-state"
        for kind in ("fifo", "socket", "empty-directory"):
            with self.subTest(kind=kind):
                server = None
                if kind == "fifo":
                    os.mkfifo(endpoint)
                elif kind == "socket":
                    server = socket.socket(socket.AF_UNIX)
                    server.bind(str(endpoint))
                    server.listen()
                else:
                    endpoint.mkdir()
                try:
                    self.assertEqual(self.run_git(self.worktree, "status", "--porcelain"), "")
                    self.assertNotEqual(self.release().returncode, 0)
                    result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertTrue(endpoint.exists())
                    if server is not None:
                        with socket.socket(socket.AF_UNIX) as client:
                            client.connect(str(endpoint))
                finally:
                    if server is not None:
                        server.close()
                    if endpoint.is_dir():
                        endpoint.rmdir()
                    elif endpoint.exists():
                        endpoint.unlink()

    def test_active_filters_are_retained_without_executing_them(self):
        marker = self.root / "filter-executed"
        driver = self.root / "filter.py"
        driver.write_text(
            "import sys\nfrom pathlib import Path\n"
            f"Path({str(marker)!r}).touch()\n"
            "sys.stdout.buffer.write(sys.stdin.buffer.read())\n"
        )
        (self.repo / ".git/info/attributes").write_text("file filter=local\n")
        self.run_git(self.repo, "config", "filter.local.clean", "python3 " + str(driver))
        modified = (self.worktree / "file").stat().st_mtime_ns + 2_000_000_000
        os.utime(self.worktree / "file", ns=(modified, modified))
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(marker.exists(), "release executed a configured content filter")

    def test_tracked_symlinks_remain_recoverable_without_following_them(self):
        private = self.root / "private-outside"
        private.write_text("operator content")
        (self.worktree / "link").symlink_to("../private-outside")
        self.run_git(self.worktree, "add", "link")
        self.run_git(self.worktree, "commit", "-qm", "track a link")
        self.head = self.run_git(self.worktree, "rev-parse", "HEAD").strip()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(private.read_text(), "operator content")

    def test_wrong_repository_and_stale_remote_snapshot_are_retained(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        (self.repo / "file").write_text("later main\n")
        self.run_git(self.repo, "commit", "-qam", "later main")
        self.run_git(self.repo, "push", "-q", "origin", "main")
        old = json.loads(self.metadata.read_text())["mergeCommit"]["oid"]
        self.run_git(self.repo, "update-ref", "refs/remotes/origin/main", old)
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale", result.stderr)
        self.run_git(self.repo, "fetch", "-q", "origin")
        (self.bin / "gh").write_text(
            (self.bin / "gh")
            .read_text()
            .replace('print("fixture/repo")', 'print("unrelated/repo")')
        )
        result = self.retire()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository", result.stderr)
        self.assertTrue(self.worktree.exists())

    def test_index_flags_cannot_hide_operator_changes(self):
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        for flag in ("assume-unchanged", "skip-worktree"):
            with self.subTest(flag=flag):
                self.run_git(self.worktree, "update-index", "--" + flag, "file")
                (self.worktree / "file").write_text("unique operator changes\n")
                result = self.retire()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.worktree / "file").read_text(), "unique operator changes\n")
                self.run_git(self.worktree, "update-index", "--no-" + flag, "file")
                self.run_git(self.worktree, "restore", "file")

    def test_detached_reflog_work_is_recoverable_from_archive(self):
        self.merged()
        self.run_git(self.worktree, "checkout", "-q", "--detach")
        (self.worktree / "file").write_text("unique reflog work\n")
        self.run_git(self.worktree, "commit", "-qam", "detached work")
        lost = self.run_git(self.worktree, "rev-parse", "HEAD").strip()
        self.run_git(self.worktree, "reset", "--hard", self.head)
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)["archive"])
        restored = self.root / "restored"
        self.run_git(self.root, "clone", "-q", str(archive / "repository.bundle"), str(restored))
        exists = subprocess.run(
            ["git", "-C", str(restored), "cat-file", "-e", lost], capture_output=True
        )
        self.assertEqual(exists.returncode, 0, "detached reflog commit absent from recovery bundle")

    def test_http_preview_preserves_cookie_jar_and_source_config(self):
        from http.server import HTTPServer, SimpleHTTPRequestHandler
        import importlib.util
        import threading
        from unittest.mock import patch

        self.merged()
        self.run_git(self.remote, "update-server-info")
        requests = []
        require_cookie = [False]
        root = self.root

        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(root), **kwargs)

            def do_GET(self):
                cookie = self.headers.get("Cookie", "")
                requests.append(cookie)
                if require_cookie[0] and "fixture_auth=present" not in cookie:
                    self.send_error(403, "fixture cookie required")
                    return
                super().do_GET()

            def end_headers(self):
                self.send_header("Set-Cookie", "preview_cookie=received; Path=/")
                super().end_headers()

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/origin.git"
            self.run_git(self.repo, "remote", "set-url", "origin", url)
            spec = importlib.util.spec_from_file_location("lifecycle_cookie_test", SCRIPT)
            lifecycle = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(lifecycle)
            # This fixture isolates real HTTP transport from process visibility;
            # the active-process refusal has its own real-process regression.
            with patch.dict(os.environ, self.env), patch.object(lifecycle, "active_processes"):
                lifecycle.release(
                    self.repo, self.worktree, self.head, "fixture-session", 7, "fixture/repo"
                )
                for scope in ("http", f"http.{url}"):
                    for existing in (True, False):
                        with self.subTest(scope=scope, existing=existing):
                            jar = self.repo / ".git/preview-cookies"
                            original = (
                                (
                                    b"# Netscape HTTP Cookie File\n"
                                    b"127.0.0.1\tFALSE\t/\tFALSE\t0\tfixture_auth\tpresent\n"
                                )
                                if existing
                                else None
                            )
                            jar.unlink(missing_ok=True)
                            if original is not None:
                                jar.write_bytes(original)
                            require_cookie[0] = existing
                            requests.clear()
                            self.run_git(self.repo, "config", scope + ".cookieFile", str(jar))
                            self.run_git(
                                self.repo, "config", "--add", scope + ".saveCookies", "false"
                            )
                            self.run_git(
                                self.repo, "config", "--add", scope + ".saveCookies", "true"
                            )
                            config = (self.repo / ".git/config").read_bytes()
                            try:
                                result = lifecycle.retire(self.repo, self.worktree, False, None)
                                self.assertEqual(result["disposition"], "ready")
                                self.assertTrue(self.worktree.exists())
                                self.assertTrue(requests, "preview never contacted the HTTP origin")
                                if existing:
                                    self.assertTrue(
                                        all(
                                            "fixture_auth=present" in request
                                            for request in requests
                                        )
                                    )
                                self.assertEqual(
                                    jar.read_bytes() if jar.exists() else None, original
                                )
                                self.assertEqual((self.repo / ".git/config").read_bytes(), config)
                            finally:
                                self.run_git(
                                    self.repo, "config", "--unset-all", scope + ".cookieFile"
                                )
                                self.run_git(
                                    self.repo, "config", "--unset-all", scope + ".saveCookies"
                                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_unknown_process_visibility_refuses_retirement(self):
        from unittest.mock import patch

        module, entry = self.process_fixture()
        thread = entry / "task/456"
        shutil.copytree(entry, thread, symlinks=True, ignore=shutil.ignore_patterns("task"))
        with self.assertRaisesRegex(ValueError, "process inspection"):
            module.active_processes(self.worktree, self.root / "no-proc")
        for error in (PermissionError, FileNotFoundError):
            for name in ("cwd", "root", "exe", "fd/3", "fd", "maps", "status"):
                with self.subTest(error=error.__name__, surface=name):
                    target = thread / name
                    attribute = (
                        "readlink"
                        if name in ("cwd", "root", "exe", "fd/3")
                        else ("scandir" if name == "fd" else "open")
                    )
                    owner = module.os if attribute in ("readlink", "scandir") else module.Path
                    original = getattr(owner, attribute)

                    def unavailable(
                        candidate, *args, target=target, error=error, original=original, **kwargs
                    ):
                        if Path(candidate) == target:
                            raise error("fixture evidence unavailable")
                        return original(candidate, *args, **kwargs)

                    with patch.object(owner, attribute, new=unavailable):
                        with self.assertRaisesRegex(ValueError, "cannot inspect"):
                            module.active_processes(self.worktree, self.proc)

    def test_missing_and_changing_thread_enumeration_retains_even_with_dead_leader(self):
        from unittest.mock import patch

        module, entry = self.process_fixture()
        tasks = entry / "task"
        original = module.Path.iterdir
        for state in ("S", "Z"):
            (entry / "status").write_text(f"State:\t{state}\n")
            for error in (PermissionError, FileNotFoundError):
                with self.subTest(state=state, error=error.__name__):

                    def unavailable(candidate, error=error):
                        if candidate == tasks:
                            raise error("task enumeration unavailable")
                        return original(candidate)

                    with patch.object(module.Path, "iterdir", new=unavailable):
                        with self.assertRaisesRegex(ValueError, "cannot inspect"):
                            module.active_processes(self.worktree, self.proc)
            for change in ("empty", "added", "removed"):
                with self.subTest(state=state, change=change):
                    observations = 0

                    def changing(candidate, change=change):
                        nonlocal observations
                        if candidate != tasks:
                            return original(candidate)
                        observations += 1
                        if change == "empty" or (change == "removed" and observations > 1):
                            return iter(())
                        names = [tasks / "123"]
                        if change == "added" and observations > 1:
                            names.append(tasks / "456")
                        return iter(names)

                    with patch.object(module.Path, "iterdir", new=changing):
                        with self.assertRaisesRegex(ValueError, "cannot inspect"):
                            module.active_processes(self.worktree, self.proc)

    def test_executable_root_and_deleted_mapping_references_are_active(self):
        module, entry = self.process_fixture()
        for name in ("root", "exe"):
            with self.subTest(surface=name):
                link = entry / name
                target = os.readlink(link)
                link.unlink()
                link.symlink_to(self.worktree if name == "root" else self.worktree / "file")
                with self.assertRaisesRegex(ValueError, "active process.*" + name):
                    module.active_processes(self.worktree, self.proc)
                link.unlink()
                link.symlink_to(target)
        (entry / "maps").write_text(
            f"1000-2000 r--p 00000000 00:01 1 {self.worktree}/file (deleted)\n"
        )
        with self.assertRaisesRegex(ValueError, "active process.*memory mapping"):
            module.active_processes(self.worktree, self.proc)

    def test_non_filesystem_descriptors_and_confirmed_exit_are_safe(self):
        module, entry = self.process_fixture()
        for number, target in enumerate(
            ("pipe:[123]", "socket:[456]", "anon_inode:[eventpoll]"), 4
        ):
            (entry / "fd" / str(number)).symlink_to(target)
        module.active_processes(self.worktree, self.proc)
        (entry / "cwd").unlink()
        with self.assertRaisesRegex(ValueError, "cannot inspect"):
            module.active_processes(self.worktree, self.proc)
        (entry / "status").write_text("State:\tZ (zombie)\n")
        module.active_processes(self.worktree, self.proc)
        # A process that vanished after enumeration is also definitively gone.
        (self.proc / "456").symlink_to(self.root / "vanished-process")
        module.active_processes(self.worktree, self.proc)

    def test_empty_or_malformed_live_mapping_evidence_is_retained(self):
        module, entry = self.process_fixture()
        for data in ("", "incomplete mapping\n"):
            with self.subTest(maps=data):
                (entry / "maps").write_text(data)
                with self.assertRaisesRegex(ValueError, "cannot inspect"):
                    module.active_processes(self.worktree, self.proc)

    def denied_user_session(self):
        """The pair every systemd user session contributes, unreadable."""
        self.env["FIXTURE_SESSION_MANAGER"] = "356"
        for pid, comm, ppid in ((356, "systemd", 1), (362, "(sd-pam)", 356)):
            # The helper shares the manager's session; a service would not.
            self.deny_session_evidence(self.session_process(pid, comm, ppid, session=356))
        return [
            {"pid": 356, "comm": "systemd", "ppid": 1},
            {"pid": 362, "comm": "(sd-pam)", "ppid": 356},
        ]

    def test_denied_user_session_pair_retains_until_the_operator_asserts_it(self):
        self.denied_user_session()
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("cannot inspect this user's systemd session process", result.stderr)
        self.assertIn("--trust-process-manager", result.stderr)

    def test_asserted_user_session_pair_is_exempted_and_recorded(self):
        exempt = self.denied_user_session()
        self.merged()
        result = self.release("--trust-process-manager")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["exempt_processes"], exempt)
        # Retirement inspects again, so it needs the same explicit assertion.
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("--trust-process-manager", result.stderr)
        result = self.retire(
            "--apply", "--archive-dir", str(self.root / "archive"), "--trust-process-manager"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)["archive"])
        recovery = json.loads((archive / "recovery.json").read_text())
        self.assertEqual(recovery["exempt_processes"], exempt)
        self.assertEqual(recovery["retirement_exempt_processes"], exempt)

    def test_archive_records_the_identities_retirement_itself_exempted(self):
        # The session manager can restart between release and retirement, so
        # the archive must name what the retirement scans actually skipped.
        released = self.denied_user_session()
        self.merged()
        self.assertEqual(self.release("--trust-process-manager").returncode, 0)
        for entry in (self.proc / "356", self.proc / "362"):
            self.allow_session_evidence(entry)
            shutil.rmtree(entry)
        # A restart means a new pid, and the system manager names that one.
        self.env["FIXTURE_SESSION_MANAGER"] = "500"
        for pid, comm, ppid in ((500, "systemd", 1), (501, "(sd-pam)", 500)):
            self.deny_session_evidence(self.session_process(pid, comm, ppid, session=500))
        result = self.retire(
            "--apply", "--archive-dir", str(self.root / "archive"), "--trust-process-manager"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = Path(json.loads(result.stdout)["archive"])
        recovery = json.loads((archive / "recovery.json").read_text())
        self.assertEqual(recovery["exempt_processes"], released)
        self.assertEqual(
            recovery["retirement_exempt_processes"],
            [
                {"pid": 500, "comm": "systemd", "ppid": 1},
                {"pid": 501, "comm": "(sd-pam)", "ppid": 500},
            ],
        )

    def test_retained_archive_records_exemptions_the_second_scan_observed(self):
        from functools import partial
        from unittest.mock import patch

        self.merged()
        self.assertEqual(self.release().returncode, 0)
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original_assess = lifecycle.assess
        late = {"pid": 777, "comm": "systemd", "ppid": 1}
        scans = []

        def second_scan_exempts_more(repo, path, *args):
            item, admin, record = original_assess(repo, path, *args)
            scans.append(path)
            if len(scans) == 2:
                record["retirement_exempt_processes"] = [late]
            return item, admin, record

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "assess", second_scan_exempts_more),
            patch.object(lifecycle, "archived_metadata_matches", return_value=False),
        ):
            with self.assertRaisesRegex(ValueError, "metadata changed.*retained.*archive:"):
                lifecycle.retire(self.repo, self.worktree, True, self.root / "archive")
        self.assertEqual(len(scans), 2)
        self.assertTrue(self.worktree.is_dir())
        (archive,) = (self.root / "archive").iterdir()
        recovery = json.loads((archive / "recovery.json").read_text())
        self.assertIn(late, recovery["retirement_exempt_processes"])

    def test_readable_session_manager_reference_still_refuses_release(self):
        self.session_process(356, "systemd", 1)
        result = self.release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("active process", result.stderr)

    def test_session_exemption_requires_the_whole_process_identity(self):
        # 356 is the only pid the system manager vouches for in this fixture.
        self.env["FIXTURE_SESSION_MANAGER"] = "356"
        cases = {
            "not the pid the system manager names": [(357, "systemd", 1, None, 357)],
            "the named pid renamed": [(356, "bash", 1, None, 356)],
            "the named pid is not a pid-1 child": [(356, "systemd", 2, None, 356)],
            "another user's credentials": [(356, "systemd", 1, os.getuid() + 1, 356)],
            "helper of an unnamed manager": [
                (357, "systemd", 1, None, 357),
                (358, "(sd-pam)", 357, None, 357),
            ],
            "helper in a session of its own": [
                (356, "systemd", 1, None, 356),
                (362, "(sd-pam)", 356, None, 362),
            ],
            "helper with no visible parent": [(404, "(sd-pam)", 999999)],
        }
        for label, specs in cases.items():
            with self.subTest(case=label):
                entries = [self.session_process(*spec) for spec in specs]
                for entry in entries:
                    self.deny_session_evidence(entry)
                result = self.release("--trust-process-manager")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("cannot inspect a same-user process", result.stderr)
                for entry in entries:
                    self.allow_session_evidence(entry)
                    shutil.rmtree(entry)

    def test_listable_descriptor_table_with_denied_targets_is_exempt(self):
        # The actual session manager lists its own descriptor table while
        # every target refuses readlink; (sd-pam) refuses even enumeration.
        from unittest.mock import patch

        module, _ = self.process_fixture()
        entry = self.session_process(356, "systemd", 1)
        self.env["FIXTURE_SESSION_MANAGER"] = "356"
        surfaces = ("cwd", "root", "exe", "descriptors", "maps")
        with patch.dict(os.environ, self.env), self.denied_process_reads(module, entry, surfaces):
            self.assertEqual(
                module.active_processes(self.worktree, self.proc, trust_process_manager=True),
                [{"pid": 356, "comm": "systemd", "ppid": 1}],
            )

    def test_partial_or_differently_denied_evidence_retains_the_worktree(self):
        from unittest.mock import patch

        module, _ = self.process_fixture()
        entry = self.session_process(356, "systemd", 1)
        self.env["FIXTURE_SESSION_MANAGER"] = "356"
        environment = patch.dict(os.environ, self.env)
        environment.start()
        self.addCleanup(environment.stop)
        surfaces = ("cwd", "root", "exe", "descriptors", "maps")
        # Pin the seam: denying every surface does exempt this pid, so each
        # case below fails the predicate rather than never reaching it.
        with self.denied_process_reads(module, entry, surfaces):
            self.assertEqual(
                module.active_processes(self.worktree, self.proc, trust_process_manager=True),
                [{"pid": 356, "comm": "systemd", "ppid": 1}],
            )
        for readable in surfaces:
            with self.subTest(readable=readable):
                denied = tuple(name for name in surfaces if name != readable)
                with self.denied_process_reads(module, entry, denied):
                    with self.assertRaisesRegex(
                        ValueError, "cannot inspect a same-user process|active process"
                    ):
                        module.active_processes(
                            self.worktree, self.proc, trust_process_manager=True
                        )
        with self.subTest(denial="EPERM"):
            with self.denied_process_reads(module, entry, surfaces, code=errno.EPERM):
                with self.assertRaisesRegex(ValueError, "cannot inspect a same-user process"):
                    module.active_processes(self.worktree, self.proc, trust_process_manager=True)

    def test_stashes_survive_retirement(self):
        (self.repo / "file").write_text("private stash\n")
        self.run_git(self.repo, "stash", "push", "-qm", "preserve")
        stash = self.run_git(self.repo, "rev-parse", "refs/stash").strip()
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_git(self.repo, "rev-parse", "refs/stash").strip(), stash)

    # -- expire (#562) -----------------------------------------------------

    def retired(self):
        """Retire the fixture task into the archive and return its entry."""
        self.merged()
        self.assertEqual(self.release().returncode, 0)
        result = self.retire("--apply", "--archive-dir", str(self.root / "archive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(json.loads(result.stdout)["archive"])

    def age(self, archive, days):
        path = archive / "recovery.json"
        record = json.loads(path.read_text())
        record["retired_at"] = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        path.write_text(json.dumps(record, indent=2) + "\n")

    def expire(self, *args, window="30d"):
        result = self.cli(
            "expire", "--archive-dir", str(self.root / "archive"), "--older-than", window, *args
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def entry(self, report, archive):
        matches = [item for item in report["entries"] if item["archive"] == str(archive)]
        self.assertEqual(len(matches), 1, report)
        return matches[0]

    def snapshot(self, *directories):
        """Every path, mode, mtime and byte under the given trees."""
        state = {}
        for directory in directories:
            for folder, dirs, files in os.walk(directory):
                for name in dirs + files:
                    path = Path(folder) / name
                    info = path.lstat()
                    if stat.S_ISLNK(info.st_mode):
                        data = os.readlink(path)
                    elif stat.S_ISREG(info.st_mode):
                        data = path.read_bytes()
                    else:
                        data = None
                    state[str(path)] = (info.st_mode, info.st_mtime_ns, data)
        return state

    def registered(self, path):
        listing = self.run_git(self.repo, "worktree", "list", "--porcelain")
        return f"worktree {path}\n" in listing + "\n"

    def test_expire_report_mode_touches_nothing(self):
        archive = self.retired()
        self.age(archive, 40)
        admin = self.repo / ".git/worktrees/task"
        before = self.snapshot(self.root / "archive", admin)
        listing = self.run_git(self.repo, "worktree", "list", "--porcelain")
        report = self.expire()
        item = self.entry(report, archive)
        self.assertEqual(item["disposition"], "expirable", item)
        self.assertEqual(item["kind"], "quarantine")
        self.assertEqual((report["retired"], report["expirable"], report["expired"]), (1, 1, 0))
        self.assertEqual(report["oldest_days"], 40)
        self.assertIs(report["applied"], False)
        self.assertEqual(self.snapshot(self.root / "archive", admin), before)
        self.assertEqual(self.run_git(self.repo, "worktree", "list", "--porcelain"), listing)

    def test_expire_apply_removes_an_expirable_entry(self):
        archive = self.retired()
        self.age(archive, 40)
        report = self.expire("--apply")
        item = self.entry(report, archive)
        self.assertEqual(item["disposition"], "expired", item)
        self.assertEqual((report["expirable"], report["expired"]), (0, 1))
        self.assertFalse(os.path.lexists(archive))
        self.assertTrue((self.root / "archive").is_dir())
        self.assertFalse(self.registered(archive / "worktree"))
        self.assertFalse((self.repo / ".git/worktrees/task").exists())
        # The merged branch ref is not the archive's to delete.
        self.assertEqual(self.run_git(self.repo, "rev-parse", "topic").strip(), self.head)

    def test_expire_window_boundary(self):
        archive = self.retired()
        for days, expected in ((29.99, "retained"), (30.01, "expirable")):
            with self.subTest(days=days):
                self.age(archive, days)
                item = self.entry(self.expire(), archive)
                self.assertEqual(item["disposition"], expected, item)
                if expected == "retained":
                    self.assertIn("window", item["reason"])
        self.assertTrue((archive / "worktree").is_dir())

    def test_expire_dates_a_legacy_record_by_its_final_write(self):
        archive = self.retired()
        path = archive / "recovery.json"
        record = json.loads(path.read_text())
        self.assertIn("retired_at", record)
        del record["retired_at"]
        path.write_text(json.dumps(record))
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "retained")
        old = time.time() - 40 * 86400
        os.utime(path, (old, old))
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "expirable")

    def test_expire_retains_every_unsafe_entry_with_a_reason(self):
        archive = self.retired()
        self.age(archive, 40)
        quarantine = archive / "worktree"
        admin = self.repo / ".git/worktrees/task"
        recovery = archive / "recovery.json"
        saved = recovery.read_bytes()
        pr = self.metadata.read_text()

        cases = (
            (
                "unmerged",
                lambda: self.metadata.write_text(pr.replace("MERGED", "OPEN")),
                lambda: self.metadata.write_text(pr),
                "merged",
            ),
            (
                "dirty",
                lambda: (quarantine / "file").write_text("private\n"),
                lambda: (quarantine / "file").write_text("feature\n"),
                "raw local content",
            ),
            (
                "ignored",
                lambda: (
                    (self.repo / ".git/info/exclude").write_text("late.secret\n"),
                    (quarantine / "late.secret").write_text("late\n"),
                ),
                lambda: (quarantine / "late.secret").unlink(),
                "ignored",
            ),
            (
                "attached",
                lambda: self.run_git(quarantine, "checkout", "-q", "topic"),
                lambda: self.run_git(quarantine, "checkout", "-q", "--detach"),
                "attached",
            ),
            (
                "operation",
                lambda: (admin / "index.lock").write_text(""),
                lambda: (admin / "index.lock").unlink(),
                "Git operation",
            ),
            (
                "missing record",
                lambda: recovery.unlink(),
                lambda: recovery.write_bytes(saved),
                "recovery.json",
            ),
            (
                "unparseable record",
                lambda: recovery.write_text("{"),
                lambda: recovery.write_bytes(saved),
                "recovery.json",
            ),
            (
                "moved",
                lambda: self.run_git(
                    quarantine,
                    "-c",
                    "user.name=F",
                    "-c",
                    "user.email=f@example.invalid",
                    "commit",
                    "-q",
                    "--allow-empty",
                    "-m",
                    "moved",
                ),
                lambda: self.run_git(quarantine, "reset", "-q", "--hard", self.head),
                "HEAD",
            ),
        )
        for name, mutate, undo, reason in cases:
            with self.subTest(case=name):
                mutate()
                before = self.snapshot(archive)
                item = self.entry(self.expire("--apply"), archive)
                self.assertEqual(item["disposition"], "retained", item)
                self.assertIn(reason, item["reason"])
                self.assertEqual(self.snapshot(archive), before)
                self.assertTrue(self.registered(quarantine))
                undo()
        # The moved commit stays in the worktree reflog after HEAD is reset, so
        # the entry is retained for good; every other obstacle was undone.
        item = self.entry(self.expire(), archive)
        self.assertIn("not contained in the merged head", item["reason"])

    def test_expire_retains_commits_only_the_archive_still_holds(self):
        # A branch the bundle captured and the repository has since deleted:
        # after reflog expiry and gc, the bundle is its only local copy.
        self.run_git(self.repo, "branch", "spare", "main")
        spare = self.root / "spare"
        self.run_git(self.repo, "worktree", "add", "-q", str(spare), "spare")
        self.run_git(spare, "commit", "-q", "--allow-empty", "-m", "only in the bundle")
        self.run_git(self.repo, "worktree", "remove", str(spare))
        archive = self.retired()
        self.age(archive, 40)
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "expirable")
        self.run_git(self.repo, "branch", "-D", "spare")
        item = self.entry(self.expire("--apply"), archive)
        self.assertEqual(item["disposition"], "retained", item)
        self.assertIn("recovery bundle", item["reason"])
        self.assertTrue((archive / "repository.bundle").exists())

    def test_expire_keeps_one_newest_archive_for_a_commit_only_archives_hold(self):
        self.run_git(self.repo, "branch", "spare", "main")
        spare = self.root / "spare"
        self.run_git(self.repo, "worktree", "add", "-q", str(spare), "spare")
        self.run_git(spare, "commit", "-q", "--allow-empty", "-m", "only in the bundles")
        self.run_git(self.repo, "worktree", "remove", str(spare))
        archive = self.retired()
        self.age(archive, 40)
        record = json.loads((archive / "recovery.json").read_text())
        older = self.root / "archive/retired-older"
        older.mkdir(mode=0o700)
        shutil.copy2(archive / "repository.bundle", older)
        shutil.copy2(archive / "worktree-metadata.tar", older)
        (older / "recovery.json").write_text(
            json.dumps({k: v for k, v in record.items() if k not in ("quarantine", "git_metadata")})
        )
        self.age(older, 50)
        self.run_git(self.repo, "branch", "-D", "spare")
        report = self.expire("--apply")
        # The newest holder stays; the older copy is covered by it.
        kept = self.entry(report, archive)
        self.assertEqual(kept["disposition"], "retained", kept)
        self.assertIn("recovery bundle", kept["reason"])
        self.assertEqual(self.entry(report, older)["disposition"], "expired")
        self.assertTrue((archive / "repository.bundle").exists())
        self.assertFalse(os.path.lexists(older))

    def test_expire_retains_unrecognized_git_metadata(self):
        archive = self.retired()
        self.age(archive, 40)
        admin = self.repo / ".git/worktrees/task"
        with self.subTest(where="live metadata"):
            (admin / "notes").write_text("only copy\n")
            item = self.entry(self.expire("--apply"), archive)
            self.assertEqual(item["disposition"], "retained", item)
            self.assertIn("notes", item["reason"])
            (admin / "notes").unlink()
        with self.subTest(where="archived metadata"):
            saved = (archive / "worktree-metadata.tar").read_bytes()
            extra = self.root / "extra"
            extra.write_text("only copy\n")
            with tarfile.open(archive / "worktree-metadata.tar", "a") as stream:
                stream.add(extra, arcname="worktree-metadata/backup")
            item = self.entry(self.expire("--apply"), archive)
            self.assertEqual(item["disposition"], "retained", item)
            self.assertIn("backup", item["reason"])
            (archive / "worktree-metadata.tar").write_bytes(saved)
        # Review receipts and Git's own files are what retirement expects.
        (admin / "review-receipts").mkdir(exist_ok=True)
        (admin / "review-receipts/receipt.json").write_text("{}\n")
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "expirable")

    def test_expire_retains_metadata_pointers_to_otherwise_unkept_commits(self):
        archive = self.retired()
        self.age(archive, 40)
        admin = self.repo / ".git/worktrees/task"
        orphan = self.run_git(
            self.repo,
            "-c",
            "user.name=F",
            "-c",
            "user.email=f@example.invalid",
            "commit-tree",
            "-m",
            "fetched only",
            self.head + "^{tree}",
        ).strip()
        for name, content in (
            ("ORIG_HEAD", orphan + "\n"),
            ("FETCH_HEAD", f"{orphan}\t\tbranch 'x' of elsewhere\n"),
            ("CLAUDE_BASE", orphan + "\n"),
            ("refs/other/stash", orphan + "\n"),
            ("refs/worktree/note", "not an object id\n"),
        ):
            with self.subTest(name=name):
                path = admin / name
                path.parent.mkdir(parents=True, exist_ok=True)
                previous = path.read_bytes() if path.exists() else None
                path.write_text(content)
                item = self.entry(self.expire("--apply"), archive)
                self.assertEqual(item["disposition"], "retained", item)
                if previous is None:
                    path.unlink()
                else:
                    path.write_bytes(previous)
        # A pointer to a commit a ref keeps is ordinary.
        (admin / "ORIG_HEAD").write_text(self.run_git(self.repo, "rev-parse", "main"))
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "expirable")

    def test_expire_rechecks_an_orphan_checkout_is_still_absent(self):
        from functools import partial
        from unittest.mock import patch

        archive = self.retired()
        admin = self.repo / ".git/worktrees/task"
        saved = archive.parent / "saved-entry"
        os.rename(archive, saved)
        old = time.time() - 40 * 86400
        os.utime(admin / "locked", (old, old))
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original = lifecycle.verify_integration

        def restore(*args, **kwargs):
            proof = original(*args, **kwargs)
            os.rename(saved, archive)
            return proof

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "verify_integration", restore),
        ):
            report = lifecycle.expire([self.repo], self.root / "archive", 30, True)
        item = next(e for e in report["entries"] if e["kind"] == "orphan-registration")
        self.assertEqual(item["disposition"], "retained", item)
        self.assertTrue((archive / "worktree/file").exists())
        self.assertTrue(self.registered(archive / "worktree"))

    def test_expire_retains_a_rewritten_ref_outside_the_merged_head(self):
        archive = self.retired()
        self.age(archive, 40)
        quarantine = archive / "worktree"
        orphan = self.run_git(
            quarantine,
            "-c",
            "user.name=F",
            "-c",
            "user.email=f@example.invalid",
            "commit-tree",
            "-m",
            "rewritten",
            "-p",
            self.head,
            self.head + "^{tree}",
        ).strip()
        admin = self.repo / ".git/worktrees/task"
        (admin / "refs/rewritten").mkdir(parents=True)
        (admin / "refs/rewritten/onto").write_text(orphan + "\n")
        item = self.entry(self.expire("--apply"), archive)
        self.assertEqual(item["disposition"], "retained", item)
        self.assertIn(orphan, item["reason"])

    def test_expire_rechecks_head_after_the_remote_proof(self):
        from functools import partial
        from unittest.mock import patch

        archive = self.retired()
        self.age(archive, 40)
        quarantine = archive / "worktree"
        lifecycle, _ = self.process_fixture()
        lifecycle.active_processes = partial(lifecycle.active_processes, proc_root=self.proc)
        original = lifecycle.verify_integration

        def late_commit(*args, **kwargs):
            proof = original(*args, **kwargs)
            self.run_git(
                quarantine,
                "-c",
                "user.name=F",
                "-c",
                "user.email=f@example.invalid",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "late",
            )
            return proof

        with (
            patch.dict(os.environ, self.env),
            patch.object(lifecycle, "verify_integration", late_commit),
        ):
            report = lifecycle.expire([self.repo], self.root / "archive", 30, True)
        item = self.entry(report, archive)
        self.assertEqual(item["disposition"], "retained", item)
        self.assertTrue(self.registered(quarantine))
        self.assertTrue((archive / "repository.bundle").exists())

    def test_expire_prunes_an_orphan_registration(self):
        archive = self.retired()
        admin = self.repo / ".git/worktrees/task"
        shutil.rmtree(archive)
        item = self.entry(self.expire("--apply"), archive)
        self.assertEqual(item["kind"], "orphan-registration")
        self.assertEqual(item["disposition"], "retained", item)
        self.assertIn("window", item["reason"])
        self.assertTrue(self.registered(archive / "worktree"))
        old = time.time() - 40 * 86400
        os.utime(admin / "locked", (old, old))
        self.assertEqual(self.entry(self.expire(), archive)["disposition"], "expirable")
        self.assertTrue(self.registered(archive / "worktree"))
        item = self.entry(self.expire("--apply"), archive)
        self.assertEqual(item["disposition"], "expired", item)
        self.assertFalse(self.registered(archive / "worktree"))
        self.assertFalse(admin.exists())

    def test_expire_orphan_directories(self):
        archive = self.retired()
        self.age(archive, 40)
        record = json.loads((archive / "recovery.json").read_text())
        # A retirement retained after archival leaves the bundle, metadata and
        # a record without a quarantine; a later retry completed the entry above.
        partial = self.root / "archive/retired-partial"
        partial.mkdir(mode=0o700)
        shutil.copy2(archive / "repository.bundle", partial)
        shutil.copy2(archive / "worktree-metadata.tar", partial)
        superseded = {k: v for k, v in record.items() if k not in ("quarantine", "git_metadata")}
        (partial / "recovery.json").write_text(json.dumps(superseded))
        # The same shape for a head no completed retirement recorded.
        lone = self.root / "archive/retired-lone"
        lone.mkdir(mode=0o700)
        (lone / "recovery.json").write_text(json.dumps(dict(superseded, head="0" * 40)))
        # A quarantined checkout Git no longer registers.
        stray = self.root / "archive/retired-stray"
        (stray / "worktree").mkdir(parents=True, mode=0o700)
        (stray / "worktree/notes").write_text("unregistered\n")
        (stray / "recovery.json").write_text(
            json.dumps(dict(record, quarantine=str(stray / "worktree")))
        )
        report = self.expire()
        self.assertEqual(self.entry(report, partial)["kind"], "partial-archive")
        self.assertEqual(self.entry(report, partial)["disposition"], "expirable")
        self.assertEqual(self.entry(report, lone)["disposition"], "retained")
        self.assertIn("superseded", self.entry(report, lone)["reason"])
        self.assertEqual(self.entry(report, stray)["kind"], "orphan-directory")
        self.assertEqual(self.entry(report, stray)["disposition"], "retained")
        self.assertIn("not a registered worktree", self.entry(report, stray)["reason"])
        self.assertEqual(report["retired"], 4)
        report = self.expire("--apply")
        self.assertEqual(self.entry(report, partial)["disposition"], "expired")
        self.assertFalse(os.path.lexists(partial))
        self.assertFalse(os.path.lexists(archive))
        self.assertTrue((lone / "recovery.json").exists())
        self.assertEqual((stray / "worktree/notes").read_text(), "unregistered\n")

    def test_expire_finishes_an_interrupted_expiry_but_not_a_failed_rename(self):
        archive = self.retired()
        self.age(archive, 40)
        record = json.loads((archive / "recovery.json").read_text())
        # A failed quarantine rename also leaves a record naming a quarantine
        # and no `worktree`, but its Git metadata still exists.
        failed = self.root / "archive/retired-failed"
        failed.mkdir(mode=0o700)
        (failed / "recovery.json").write_text(
            json.dumps(dict(record, head="1" * 40, quarantine=str(failed / "worktree")))
        )
        # Expiry removed the registration, then stopped before the archive.
        self.run_git(
            self.repo, "worktree", "remove", "--force", "--force", str(archive / "worktree")
        )
        report = self.expire()
        item = self.entry(report, archive)
        self.assertEqual((item["kind"], item["disposition"]), ("partial-archive", "expirable"))
        self.assertEqual(self.entry(report, failed)["disposition"], "retained")
        self.expire("--apply")
        self.assertFalse(os.path.lexists(archive))
        self.assertTrue((failed / "recovery.json").exists())

    def test_expire_report_never_creates_the_archive(self):
        report = self.expire()
        self.assertEqual((report["retired"], report["expirable"]), (0, 0))
        self.assertIsNone(report["oldest_days"])
        self.assertFalse((self.root / "archive").exists())

    def test_hygiene_status_summarizes_retired_worktrees(self):
        home = self.root / "home"
        folder = home / ".local/state/hygiene"
        folder.mkdir(parents=True)
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (folder / "status.json").write_text(
            json.dumps({"checked_at": now, "drift_count": 0, "drifted_repos": []})
        )

        def status(mode, summary):
            (folder / "retired-worktrees.json").write_text(json.dumps(summary))
            result = subprocess.run(
                ["bash", str(SCRIPT.parents[2] / "hygiene-status.sh"), mode],
                env=dict(self.env, HOME=str(home)),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

        summary = {"retired": 3, "expirable": 1, "oldest_days": 41, "entries": []}
        self.assertIn("retired worktrees: 3 (oldest 41d, 1 expirable)", status("--status", summary))
        self.assertIn("retired worktrees: 3 (oldest 41d, 1 expirable)", status("--text", summary))
        quiet = dict(summary, expirable=0)
        self.assertIn("retired worktrees: 3 (oldest 41d, 0 expirable)", status("--status", quiet))
        self.assertEqual(status("--text", quiet), "")
        empty = {"retired": 0, "expirable": 0, "oldest_days": None, "entries": []}
        self.assertIn("retired worktrees: 0", status("--status", empty))


if __name__ == "__main__":
    unittest.main()
