#!/usr/bin/env python3
"""Isolated regressions for launcher reload, Git diagnostics, and tmux handoff."""
import os
import pty
import select
import signal
import shlex
import time
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]


class LauncherRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.aliases = self.root / "aliases"
        shutil.copyfile(REPO / ".bash_aliases", self.aliases)
        self.env = dict(os.environ, HOME=str(self.root), FIXTURE=str(self.root),
                        REPO=str(REPO), ALIASES=str(self.aliases),
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        self.env.pop("TMUX", None)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, script, shell="bash"):
        result = subprocess.run([shell, "-c", script], cwd=self.root, env=self.env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_zsh_sources_and_uses_actual_alias_path(self):
        if not shutil.which("zsh"):
            self.skipTest("zsh is unavailable")
        result = self.shell('set -u; source "$ALIASES"; '
                            'test "$_BASH_ALIASES_PATH" = "$ALIASES"; '
                            'whence cc cx cct agy >/dev/null', "zsh")
        self.assertEqual(result.stderr, "")

    def test_zsh_resume_words_and_memory_paths(self):
        if not shutil.which("zsh"):
            self.skipTest("zsh is unavailable")
        self.shell('''source "$ALIASES"
mkdir "$FIXTURE/dev"
_dev_dir() { printf '%s\\n' "$FIXTURE/dev"; }
pull-all() { return 99; }
health_probe() { :; }
_agent_preflight '--resume -r --continue -c' health_probe --resume || exit 1
test "$_agent_resuming" = 1 || exit 1
_memory_path_is_publishable project/memory/authors.md || exit 1
! _memory_path_is_publishable project/memory/auth-token.txt
''', "zsh")

    def memory_fixture(self, name):
        home = self.root / name
        repo = home / 'dev/claude-memory'
        remote = home / 'origin.git'
        repo.mkdir(parents=True)
        shim = home / 'bin'
        shim.mkdir()
        scanner = shim / 'gitleaks'
        scanner.write_text('#!/usr/bin/env python3\nimport os,sys\n'
            'from pathlib import Path\n'
            'if sys.argv[1:2] != ["stdin"]: sys.exit(2)\n'
            'payload=sys.stdin.buffer.read()\n'
            'with Path(os.environ["MEMORY_SCAN_LOG"]).open("ab") as log: log.write(b"scanned\\n")\n'
            'sys.exit(1 if b"SYNTHETIC_MEMORY_SECRET" in payload else 0)\n')
        scanner.chmod(0o700)
        env = dict(self.env, HOME=str(home), PATH=str(shim) + os.pathsep + self.env['PATH'],
                   MEMORY_SCAN_LOG=str(home / 'scans'))

        def git(*args, cwd=repo):
            return subprocess.check_output(['git', '-C', str(cwd), *args], env=env,
                                           text=True, stderr=subprocess.STDOUT)

        git('init', '--bare', '-q', '-b', 'main', str(remote))
        git('init', '-q', '-b', 'main')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        note = repo / 'project/memory/note.md'
        note.parent.mkdir(parents=True)
        note.write_text('initial memory\n')
        (repo / 'settings.json').write_text('initial settings\n')
        git('add', 'project/memory/note.md', 'settings.json')
        git('commit', '-qm', 'initial memory')
        git('remote', 'add', 'origin', str(remote))
        git('push', '-qu', 'origin', 'main')
        return repo, remote, note, env, git

    def run_memory_sync(self, launch_shell, env):
        return subprocess.run([launch_shell, '-c', '''source "$ALIASES" || exit 1
memory_original_path="$PATH"
if sync-memory; then memory_sync_rc=0; else memory_sync_rc=$?; fi
[ "$PATH" = "$memory_original_path" ] || exit 91
command -v git >/dev/null || exit 92
command -v mktemp >/dev/null || exit 93
exit "$memory_sync_rc"
'''], cwd=env['HOME'], env=env, text=True, capture_output=True, timeout=30)

    def test_memory_sync_publishes_dirty_and_pending_content_in_native_shells(self):
        for launch_shell in ('bash', 'zsh'):
            if not shutil.which(launch_shell):
                continue
            for state in ('dirty', 'pending'):
                with self.subTest(shell=launch_shell, state=state):
                    repo, remote, note, env, git = self.memory_fixture(f'memory-{launch_shell}-{state}')
                    note.write_text('safe memory update\n')
                    if state == 'pending':
                        git('commit', '-qam', 'pending memory update')
                    before = git('rev-parse', 'HEAD').strip()
                    (repo / 'settings.json').write_text('private operator settings\n')
                    result = self.run_memory_sync(launch_shell, env)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(git('show', 'main:project/memory/note.md', cwd=remote), 'safe memory update\n')
                    self.assertEqual(git('show', 'main:settings.json', cwd=remote), 'initial settings\n')
                    self.assertEqual((repo / 'settings.json').read_text(), 'private operator settings\n')
                    self.assertEqual(git('diff', '--cached', '--name-only'), '')
                    self.assertEqual(git('status', '--porcelain', '--', 'project/memory/note.md'), '')
                    published = git('rev-parse', 'main', cwd=remote).strip()
                    self.assertEqual(published, git('rev-parse', 'HEAD').strip())
                    if state == 'pending':
                        self.assertEqual(published, before, 'retry created an unnecessary commit')
                    self.assertTrue(Path(env['MEMORY_SCAN_LOG']).read_bytes())

    def test_memory_sync_refuses_secret_content_and_sensitive_paths_in_native_shells(self):
        for launch_shell in ('bash', 'zsh'):
            if not shutil.which(launch_shell):
                continue
            for state in ('dirty', 'pending'):
                for kind in ('content', 'path'):
                    with self.subTest(shell=launch_shell, state=state, kind=kind):
                        repo, remote, note, env, git = self.memory_fixture(f'memory-{launch_shell}-{state}-{kind}')
                        remote_before = git('rev-parse', 'main', cwd=remote)
                        target = note if kind == 'content' else repo / 'project/memory/auth/session.json'
                        target.parent.mkdir(parents=True, exist_ok=True)
                        payload = 'SYNTHETIC_MEMORY_SECRET\n' if kind == 'content' else 'private state\n'
                        target.write_text(payload)
                        if state == 'pending':
                            git('add', str(target))
                            git('commit', '-qm', 'pending memory fixture')
                        local_before = git('rev-parse', 'HEAD')
                        result = self.run_memory_sync(launch_shell, env)
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        reason = ('SECRET-LIKE MEMORY' if state == 'dirty' else (
                            'SECRET-LIKE CONTENT' if kind == 'content' else 'includes non-memory paths'))
                        self.assertIn(reason, result.stderr)
                        self.assertNotIn('command not found', result.stderr)
                        self.assertEqual(git('rev-parse', 'main', cwd=remote), remote_before)
                        self.assertEqual(git('rev-parse', 'HEAD'), local_before)
                        self.assertEqual(git('diff', '--cached', '--name-only'), '')
                        self.assertEqual(target.read_text(), payload)

    def test_same_second_edit_reloads(self):
        stamp = 1_234_567_890_000_000_000
        os.utime(self.aliases, ns=(stamp, stamp))
        self.shell(r'''set -e
source "$ALIASES"
printf '\ntriage_marker() { :; }\n' >> "$ALIASES"
python3 -c 'import os; stamp = 1_234_567_890_500_000_000; os.utime(os.environ["ALIASES"], ns=(stamp, stamp))'
_launcher_reloaded
declare -F triage_marker >/dev/null
''')
        self.assertEqual(self.aliases.stat().st_mtime_ns // 1_000_000_000,
                         stamp // 1_000_000_000)

    def test_pull_reload_uses_new_launcher_once(self):
        self.shell(r'''
mkdir -p "$FIXTURE/dev/project" "$FIXTURE/dev/dotfiles/claude/scripts"
printf '#!/bin/sh\nexit 0\n' > "$FIXTURE/dev/dotfiles/claude/scripts/sync-plugins.sh"
chmod +x "$FIXTURE/dev/dotfiles/claude/scripts/sync-plugins.sh"
source "$ALIASES"
_dev_dir() { printf '%s\n' "$FIXTURE/dev"; }
_check_critical_symlinks() { :; }
_check_claude_launch_health() { printf 'stale health\n' >> "$FIXTURE/result"; }
claude() { printf 'stale runtime\n' >> "$FIXTURE/result"; }
pull-all() {
  printf 'pull\n' >> "$FIXTURE/pulls"
  cat >> "$ALIASES" <<'EOF'
cc() {
  _agent_preflight '--resume --resume= -r --continue --continue= -c' _check_claude_launch_health "$@" || return 1
  [ "$_agent_shifted" -eq 1 ] && shift
  printf 'fresh:%s:%s:%s\n' "$PWD" "$1" "$2" >> "$FIXTURE/result"
}
_check_claude_launch_health() { printf 'fresh health\n' >> "$FIXTURE/result"; }
EOF
}
cc project --model 'private argument'
test "$(cat "$FIXTURE/pulls")" = pull
test "$(cat "$FIXTURE/result")" = "fresh health
fresh:$FIXTURE/dev/project:--model:private argument"
''')

    def test_dangling_git_symlink_is_reported_and_preserved(self):
        result = self.shell('mkdir "$FIXTURE/dev"; ln -s absent "$FIXTURE/dev/.git"; '
                            'source "$ALIASES"; _dev_dir_stub_gitdir "$FIXTURE/dev"; '
                            'test -L "$FIXTURE/dev/.git"')
        self.assertIn("is not a repository", result.stderr)

    def test_detached_primary_checkout_warns(self):
        result = self.shell('mkdir -p "$FIXTURE/dev/dotfiles"; '
                            'git -C "$FIXTURE/dev/dotfiles" init -q -b main; '
                            'git -C "$FIXTURE/dev/dotfiles" -c user.name=t -c user.email=t@t '
                            'commit --allow-empty -qm base; '
                            'git -C "$FIXTURE/dev/dotfiles" checkout --detach -q; '
                            'source "$ALIASES"; _dotfiles_branch_check "$FIXTURE/dev"')
        self.assertIn("detached HEAD", result.stderr)

    def test_excluded_remote_branch_is_a_pull_failure(self):
        self.shell(r'''
git init --bare -q -b main "$FIXTURE/origin.git"
git init -q -b main "$FIXTURE/seed"
git -C "$FIXTURE/seed" -c user.name=t -c user.email=t@t commit --allow-empty -qm base
git -C "$FIXTURE/seed" remote add origin "$FIXTURE/origin.git"
git -C "$FIXTURE/seed" push -q origin main
git -C "$FIXTURE/seed" switch -qc feature
git -C "$FIXTURE/seed" push -q origin feature
mkdir "$FIXTURE/dev"
git clone -q -b feature "$FIXTURE/origin.git" "$FIXTURE/dev/clone"
git -C "$FIXTURE/dev/clone" config --add remote.origin.fetch '^refs/heads/feature'
source "$ALIASES"
_dev_dir() { printf '%s\n' "$FIXTURE/dev"; }
if pull-all > "$FIXTURE/output"; then exit 1; fi
! grep -q 'branch deleted' "$FIXTURE/output" || exit 1
git -C "$FIXTURE/dev/clone" config --unset-all remote.origin.fetch '^\^'
git -C "$FIXTURE/seed" push -q origin --delete feature
pull-all > "$FIXTURE/output" || exit 1
grep -q 'branch deleted' "$FIXTURE/output"
''')

    def cct_fixture(self, fixture, project_name="project"):
        project = fixture / "dev" / project_name
        project.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(project)],
                       env=self.env, check=True)
        startup = r'''
source "$ALIASES"
_dev_dir() { printf '%s\n' "$HOME/dev"; }
_check_critical_symlinks() { :; }
_check_claude_launch_health() { :; }
pull-all() { :; }
claude() {
  printf '%s\0' "$@" > "$HOME/received"
  printf '%s\n' "$PWD" > "$HOME/agent-cwd"
}
HISTFILE="$HOME/history"
HISTSIZE=1000
SAVEHIST=1000
PS1='CCT_READY> '
cd "$HOME/dev"
'''
        (fixture / ".bashrc").write_text(startup)
        (fixture / ".bash_profile").write_text('source "$HOME/.bashrc"\n')
        (fixture / ".zshrc").write_text(startup)
        (fixture / ".zprofile").write_text('cd "$HOME/dev"\n')
        return project

    def test_cct_preserves_project_and_private_arguments_in_persistent_shell(self):
        for shell_name, project_arg in (("bash", "project"), ("bash", ""),
                                        ("zsh", "project"), ("zsh", "")):
            launch_shell = shutil.which(shell_name)
            if not launch_shell:
                continue
            with self.subTest(shell=shell_name, project_arg=project_arg):
                fixture = self.root / f"{shell_name}-{'named' if project_arg else 'cwd'}"
                project = self.cct_fixture(fixture)
                env = dict(self.env, HOME=str(fixture), FIXTURE=str(fixture),
                           SHELL=launch_shell, TERM="xterm", ZDOTDIR=str(fixture))
                capture = r'''
source "$ALIASES"
_dev_dir() { printf '%s\n' "$HOME/dev"; }
tmux() {
  case "$1" in
    has-session) return 1 ;;
    send-keys) printf '%s\n' "$4" > "$HOME/typed" ;;
    new-session) printf '%s\0' "$@" > "$HOME/new-session" ;;
  esac
}
cct "$@"
'''
                arguments = ["--append-system-prompt", 'PRIVATE_SENTINEL\nquoted " argument', ""]
                if project_arg:
                    arguments.insert(0, project_arg)
                result = subprocess.run([launch_shell, "-c", capture, shell_name, *arguments],
                                        cwd=fixture if project_arg else project,
                                        env=env, text=True, capture_output=True,
                                        timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = (fixture / "new-session").read_bytes().split(b"\0")[:-1]
                command = [os.fsdecode(arg) for arg in args[args.index(os.fsencode(launch_shell)):]]
                env["CCT_DIR"] = str(project)
                pid, master = pty.fork()
                if pid == 0:
                    os.chdir(fixture)
                    os.execvpe(command[0], command, env)
                output = bytearray()
                exited = False
                probed = False
                try:
                    if (fixture / "typed").exists():
                        typed = (fixture / "typed").read_bytes()
                        self.assertNotIn(b"PRIVATE_SENTINEL", typed)
                        os.write(master, typed)
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if not probed and (fixture / "agent-cwd").exists():
                            os.write(master, b'''printf '%s\\n' "$PWD" > "$HOME/prompt-cwd"; printf '%s\\n' "$#" > "$HOME/prompt-argc"; exit\n''')
                            probed = True
                        ready, _, _ = select.select([master], [], [], 0.05)
                        if ready:
                            try:
                                output.extend(os.read(master, 4096))
                            except OSError:
                                pass
                        if os.waitpid(pid, os.WNOHANG)[0]:
                            exited = True
                            break
                    self.assertTrue(exited, output.decode(errors="replace"))
                finally:
                    if not exited:
                        os.kill(pid, signal.SIGKILL)
                        os.waitpid(pid, 0)
                    os.close(master)
                self.assertEqual((fixture / "agent-cwd").read_text().strip(), str(project))
                self.assertEqual((fixture / "prompt-cwd").read_text().strip(), str(project))
                self.assertEqual((fixture / "prompt-argc").read_text().strip(), "0")
                self.assertEqual((fixture / "received").read_bytes().split(b"\0")[:-1],
                                 [b"--remote-control", b"--chrome", b"--append-system-prompt",
                                  b'PRIVATE_SENTINEL\nquoted " argument', b""])
                self.assertNotIn("PRIVATE_SENTINEL", (fixture / "history").read_text())

    def test_cct_native_tmux_preserves_semicolons_without_running_commands(self):
        tmux_binary = shutil.which("tmux")
        if not tmux_binary:
            self.skipTest("tmux is unavailable")
        for shell_name in ("bash", "zsh"):
            launch_shell = shutil.which(shell_name)
            if not launch_shell:
                continue
            for named in (True, False):
                for case in ("bare", "trailing", "literal"):
                    with self.subTest(shell=shell_name, named=named, case=case):
                        fixture = self.root / f"{shell_name}-{named}-{case}"
                        # Exercise terminal semicolons in -c and CCT_DIR too.
                        project = self.cct_fixture(fixture, "project;" if case == "literal" else "project")
                        marker = fixture / "PRIVATE_SENTINEL"
                        touch_command = "touch " + shlex.quote(str(marker))
                        if case == "bare":
                            payload = [";", "run-shell", touch_command]
                        elif case == "trailing":
                            payload = ["literal;", "run-shell", touch_command]
                        else:
                            payload = ["; " + touch_command, ";;", "\\;", "\\\\;", "\\\\\\;",
                                       "\\", "\\\\", 'PRIVATE_SENTINEL\nquoted " argument', "",
                                       os.fsdecode(bytes(range(1, 256)) + b";")]
                        arguments = ["--append-system-prompt", *payload]
                        if named:
                            arguments.insert(0, project.name)
                        env = dict(self.env, HOME=str(fixture), FIXTURE=str(fixture),
                                   SHELL=launch_shell, TERM="xterm", ZDOTDIR=str(fixture),
                                   TMUX_BINARY=tmux_binary)
                        socket = str(fixture / "tmux.sock")

                        def tmux(*args):
                            return subprocess.run([tmux_binary, "-S", socket, "-f", "/dev/null", *args],
                                                  cwd=fixture, env=env, text=True,
                                                  capture_output=True, timeout=10)

                        def wait_until(predicate):
                            deadline = time.monotonic() + 10
                            while time.monotonic() < deadline:
                                if predicate():
                                    return
                                time.sleep(0.05)
                            self.fail("native tmux fixture did not reach expected state")

                        script = r'''
source "$ALIASES"
_dev_dir() { printf '%s\n' "$HOME/dev"; }
tmux() {
  case "$1" in
    attach-session) return 0 ;;
    send-keys) printf '%s\n' "$4" > "$HOME/typed" ;;
  esac
  "$TMUX_BINARY" -S "$FIXTURE/tmux.sock" -f /dev/null "$@"
}
cct "$@"
'''
                        try:
                            result = subprocess.run([launch_shell, "-c", script, shell_name, *arguments],
                                                    cwd=fixture if named else project, env=env,
                                                    text=True, capture_output=True, timeout=10)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            wait_until(lambda: (fixture / "agent-cwd").exists())
                            target = "=project_:" if case == "literal" else "=project:"
                            result = tmux("show-environment", "-t", target[:-1], "CCT_DIR")
                            self.assertEqual(result.stdout.strip(), "CCT_DIR=" + str(project))
                            probe = r'''printf '%s\n' "$PWD" > "$HOME/prompt-cwd"; printf '%s\n' "$#" > "$HOME/prompt-argc"; exit'''
                            result = tmux("send-keys", "-t", target, probe, "Enter")
                            self.assertEqual(result.returncode, 0, result.stderr)
                            wait_until(lambda: tmux("has-session", "-t", target[:-1]).returncode != 0)
                            self.assertFalse(marker.exists(), "argument executed as a tmux command")
                            self.assertEqual((fixture / "received").read_bytes().split(b"\0")[:-1],
                                             [b"--remote-control", b"--chrome", b"--append-system-prompt",
                                              *map(os.fsencode, payload)])
                            for name in ("agent-cwd", "prompt-cwd"):
                                self.assertEqual((fixture / name).read_text().strip(), str(project))
                            self.assertEqual((fixture / "prompt-argc").read_text().strip(), "0")
                            for name in ("typed", "history"):
                                self.assertNotIn("PRIVATE_SENTINEL", (fixture / name).read_text())
                        finally:
                            tmux("kill-server")

    def copy_setup_repo(self, destination):
        destination.mkdir(parents=True)
        for source in REPO.glob("*.sh"):
            shutil.copy2(source, destination / source.name)
        shutil.copy2(REPO / ".tmux.conf", destination / ".tmux.conf")
        for name in ("claude", "codex", "agents", "antigravity"):
            shutil.copytree(REPO / name, destination / name, symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__"))
        return destination

    def test_setup_audit_never_invokes_source_checkout_private_bootstrap(self):
        source_repo = self.copy_setup_repo(self.root / "source-dev" / "dotfiles")
        private_repo = source_repo.parent / "claude-memory"
        private_repo.mkdir()
        (private_repo / "bootstrap.sh").write_text(
            '#!/bin/sh\nprintf "invoked\\n" >> "$FIXTURE/bootstrap-invoked"\n')
        with mock.patch(__name__ + ".REPO", source_repo):
            self.test_tmux_link_is_audited_and_repaired()
        self.assertFalse((self.root / "bootstrap-invoked").exists(),
                         "setup audit invoked the source checkout's private bootstrap")

    def test_tmux_link_is_audited_and_repaired(self):
        # setup derives private companion paths from its checkout, independently
        # of HOME. Copy its public sources into a dev directory we own as well.
        setup_repo = self.copy_setup_repo(self.root / "isolated-dev" / "dotfiles")
        setup_env = dict(self.env, REPO=str(setup_repo),
                         CODEX_MEMORY_REPO=str(setup_repo.parent / "codex-memory"),
                         AGY_MEMORY_REPO=str(setup_repo.parent / "agy-memory"))
        result = subprocess.run(['bash', str(setup_repo/'setup.sh'), '--check'],
                                cwd=setup_repo, env=setup_env, text=True,
                                capture_output=True, timeout=30)
        self.assertIn('.tmux.conf', result.stdout)
        for target in (None, self.root/'missing', self.aliases):
            destination=self.root/'.tmux.conf'
            if destination.is_symlink():
                destination.unlink()
            if target is not None:
                destination.symlink_to(target)
            subprocess.run(['bash',str(setup_repo/'setup.sh'),'--repair'],
                           cwd=setup_repo,env=setup_env,
                           capture_output=True,text=True,timeout=30)
            self.assertTrue(destination.is_symlink())
            self.assertEqual(destination.resolve(), setup_repo/'.tmux.conf')


if __name__ == '__main__':
    unittest.main()
