#!/usr/bin/env python3
"""Isolated regressions for launcher reload, Git diagnostics, and tmux handoff."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class LauncherRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
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

    def test_same_second_edit_reloads(self):
        self.shell('touch -d @1234567890 "$ALIASES"; source "$ALIASES"; '
                   'printf "\\ntriage_marker() { :; }\\n" >> "$ALIASES"; '
                   'touch -d @1234567890.500000000 "$ALIASES"; '
                   '_launcher_reloaded && declare -F triage_marker >/dev/null')

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

    def test_cct_arguments_do_not_enter_interactive_history(self):
        result = self.shell(r'''
source "$ALIASES"
export SHELL=/bin/bash
_dev_dir() { printf '%s\n' "$FIXTURE"; }
# Record tmux's argument vector without starting a server or invoking a real CLI.
tmux() {
  case "$1" in
    has-session) return 1 ;;
    send-keys) printf '%s\n' "$4" > "$FIXTURE/typed" ;;
    new-session) printf '%s\0' "$@" > "$FIXTURE/new-session" ;;
  esac
}
cct --append-system-prompt $'PRIVATE_SENTINEL\nquoted " argument' ''
python3 - <<'INNER'
import os, pathlib, subprocess
root=pathlib.Path(os.environ['FIXTURE'])
if (root/'typed').exists():
    command=(root/'typed').read_text()
    env=dict(os.environ,HISTFILE=str(root/'history'))
    subprocess.run(['bash','--noprofile','--norc','-i'],input=command+'\nexit\n',text=True,
                   env=env,capture_output=True)
    assert 'PRIVATE_SENTINEL' not in (root/'history').read_text(), 'private argument entered shell history'
else:
    args=(root/'new-session').read_bytes().split(b'\0')[:-1]
    shell_at=args.index(b'/bin/bash')
    command=[os.fsdecode(arg) for arg in args[shell_at:]]
    assert command[-3:] == ['--append-system-prompt','PRIVATE_SENTINEL\nquoted " argument','']
    # Startup files are replaced by harmless functions; login startup itself is
    # covered by setup's existing contract, so this probe avoids system profiles.
    (root/'.bashrc').write_text('cc() { printf "%s\\0" "$@" > "$HOME/received"; }; HISTFILE="$HOME/history"\n')
    script=command[2].replace('exec "$0" -l', 'exit')
    command=[command[0], '--noprofile', '--rcfile', str(root/'.bashrc'), '-ic', script, *command[3:]]
    subprocess.run(command,env=os.environ,input='exit\n',text=True,capture_output=True,timeout=5,check=True)
    assert (root/'received').read_bytes().split(b'\0')[:-1] == [b'--append-system-prompt',b'PRIVATE_SENTINEL\nquoted " argument',b'']
    if (root/'history').exists():
        assert 'PRIVATE_SENTINEL' not in (root/'history').read_text()
INNER
''')
        self.assertNotIn("PRIVATE_SENTINEL", result.stdout)

    def test_tmux_link_is_audited_and_repaired(self):
        result = subprocess.run(['bash', str(REPO/'setup.sh'), '--check'],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertIn('.tmux.conf', result.stdout)
        for target in (None, self.root/'missing', self.aliases):
            destination=self.root/'.tmux.conf'
            if destination.is_symlink():
                destination.unlink()
            if target is not None:
                destination.symlink_to(target)
            subprocess.run(['bash',str(REPO/'setup.sh'),'--repair'],env=self.env,
                           capture_output=True,text=True,timeout=30)
            self.assertTrue(destination.is_symlink())
            self.assertEqual(destination.resolve(), REPO/'.tmux.conf')


if __name__ == '__main__':
    unittest.main()
