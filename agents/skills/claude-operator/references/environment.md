# Locating Claude and the maintained sources

Everything here is resolved from the home directory, never from a fixed path.
`~` is the Linux (or WSL) home of the user whose Claude you operate.

## The native executable

The native installer places Claude at `~/.local/bin/claude`. Verify it with
`--version`. On WSL, a bare `claude` on `PATH` can resolve through Windows
interop to an npm launcher on the Windows side, which is a different
installation with different configuration and auth. The runner therefore
never searches `PATH`: it uses `~/.local/bin/claude`, or the explicit
`--claude-bin` you pass, and records which in `run.json`.

Authentication is the user's existing Claude login. `claude auth status`
reports it; report only the login state. Do not read or copy credential files,
and do not switch the user to API-key billing merely to automate the CLI.

## The dotfiles checkout

`setup.sh` writes the dev directory to `~/.claude/dev-dir` (default `~/dev`).
The checkout is `<dev-dir>/dotfiles`, and the installed copy of this skill is
the symlink `~/.agents/skills/claude-operator` pointing into it, so
`~/.agents/skills/claude-operator/scripts/claude_run.py` is a stable runner
path on any machine that ran setup.

| Purpose | Live source |
| --- | --- |
| Global Claude rules | `~/.claude/CLAUDE.md` |
| Private preferences and standing orders | `<dev-dir>/claude-memory/CLAUDE.md` (optional private repo) |
| Conduct and communication contract | `<dev-dir>/dotfiles/claude/FABLE.md` |
| Daily workflow and command reference | `<dev-dir>/dotfiles/CLAUDE-GUIDE.md` |
| Interactive launchers (`cc`, `cct`, `cx`) | `<dev-dir>/dotfiles/.bash_aliases` |
| Claude workflow skills | `~/.claude/skills/<skill>/SKILL.md` |
| Shared skills and their coverage contract | `<dev-dir>/dotfiles/agents/skills/`, `agents/skill-coverage.tsv` |
| Session handoffs | `~/.claude/handoffs/` (read only this project's notes) |
| Windows-side launchers | `<dev-dir>/dotfiles/docs/WINDOWS.md` |

The global instruction files (`claude/CLAUDE.md`, `codex/AGENTS.md`,
`antigravity/GEMINI.md`) are generated from `agents/canon/`. To change a shared
rule, edit the canon or fragment and regenerate with the repository's script;
never hand-edit the generated files.

Read the interactive launchers to learn what they do; do not run them to
explore. They also sync repositories and private memory.

## Shell startup and the working directory

The runner starts Claude through an interactive Bash so the user's `PATH`,
version managers, and aliases apply, with the startup files' stdout diverted
to the run's `stderr.log` and their stdin detached (`/dev/null`), so a
startup `read` cannot consume part of the prompt. Only after those files load
does it attach the prompt, `cd` to the requested project (so a `~/.bashrc`
that changes directory cannot move Claude elsewhere), and exec Claude.
Preserve that order in any alternative launcher.

The runner itself is Linux/WSL only: it reads `/proc` to know which members
of the owned process group are still running, and it keeps the exited Claude
process unreaped until the last stop signal has been sent so the group id
cannot be reused by an unrelated process while it is still a target.

## Operating from Windows

Run the runner inside WSL with `wsl.exe -d <distro> --exec python3 …`. A
Windows path under `C:\` is `/mnt/c/…` inside WSL; pass file paths as
arguments and keep prompt text in files, never in the command line. The
Windows Codex configuration root (`%USERPROFILE%\.codex`,
`%USERPROFILE%\.agents`) is separate from the WSL one that `setup.sh` manages;
see the dotfiles `docs/WINDOWS.md` for installing this skill there.

## Official mechanics

Programmatic Claude usage is documented at
<https://code.claude.com/docs/en/headless>. Prefer the installed CLI's
`--help` when it differs from older documentation. Normal print mode loads
the user's Claude configuration; `--bare` would skip that workflow and change
authentication, so the runner never uses it. `--safe-mode` (all
customizations disabled) is for configuration troubleshooting only and is not
a test of the user's real workflow.
