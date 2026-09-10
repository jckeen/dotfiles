# Codex Dotfiles

This is how I run Codex day-to-day — the reusable, public-safe pieces. Codex
keeps its own auth, history, sqlite state, and per-project trust local; what
lives here is everything I'm happy to share across machines (and with you, if
you fork this repo): the global `AGENTS.md` rules and example configs. The
workflow skills Codex loads live in the agent-neutral `agents/skills/` (see
below). Live Codex runtime state stays in `~/.codex/`; anything personal
lives in a separate private `~/dev/codex-memory` repo.

## Safe to Track Here

- General, reusable Codex guidance such as `AGENTS.md`
- Documentation about how this setup works
- Example config files with no secrets, private paths, account IDs, or project
  names

## Do Not Track

- `~/.codex/auth.json`
- `~/.codex/history.jsonl`
- `~/.codex/log/`, `logs_*.sqlite*`, `state_*.sqlite*`
- `~/.codex/sessions/`
- `~/.codex/shell_snapshots/`
- `~/.codex/memories/`
- `~/.codex/cache/`, `.tmp/`, `tmp/`
- machine-specific `~/.codex/config.toml` project trust entries
- private MCP endpoints, bearer token env values, or account details

## Private Memory

Use `~/dev/codex-memory` for personal portable memory or private instructions.
That repo should be private and separate from both `dotfiles` and
`claude-memory`.

When present, `setup.sh` links these private files into `~/.codex/`:

- `AGENTS.local.md`
- `MEMORY.md`

It does not import or publish live `~/.codex` runtime state.

## Named Profiles

Codex named profiles use separate files. To install the public-safe read-only
example, copy `readonly.config.toml.example` to
`~/.codex/readonly.config.toml`, review it, then launch with
`codex --profile readonly`. Keep machine-specific trust and integrations in
the normal local `~/.codex/config.toml`.

The `cx` agent launcher applies `--strict-config` to the real Codex invocation
after the private defaults bootstrap, so unknown config keys fail before agent
work starts. Use `codex` directly for CLI management commands.

## Remote Terminal Sessions

When Remote Control is already enabled for the active `CODEX_HOME` (default
`~/.codex`), interactive `cx` launches check the local control socket and reuse
a listening server with `--remote unix://`. Fresh sessions, `resume`, `fork`,
and `agents` then use the same app server. The socket check avoids native
daemon management commands, which can discard live PID records after clock
drift. A mobile relay error does not require restarting the local server.

If the socket is missing, refuses connections, or cannot be verified, `cx`
launches locally. It never starts, stops, restarts, or repairs a daemon during
launch. Even a native start can discard a live PID record if a server becomes
available after the probe. When no shared server is running, start Remote
Control explicitly with `codex remote-control start --json`, then reopen with
`cx`. Repairing stale daemon metadata is an explicit maintenance action after
active work is finished.

Explicit `--remote` and remote authentication options pass through unchanged.
Utility subcommands and help/version requests do not attach the daemon.
Python is required for the socket check; if it is
unavailable, `cx` launches locally. Existing local terminals need to finish active
work and reopen with `cx resume <session-id>` to move onto the shared server.

Recovery accepts managed standalone releases from the Codex home containing
the selected daemon records, or from the default `~/.codex` installation when
only state has moved. Installation paths and executables must belong to the
current user, must not be writable by other users, and must stay inside that
installation. Existing process identities and socket-peer checks still apply.
Daemon recovery remains an explicit maintenance action after active work ends.

The opt-in native regression exercises attached clients and an active turn
against a disposable local server and a mock Responses API:

```bash
python3 codex/tests/test_shared_server_native.py --codex /path/to/codex
```

It requires a native Codex binary and Python's `websockets` package. Runtime
state stays in a temporary directory; the test uses no account credentials or
external model requests. It also simulates a listener appearing after an
absent-socket probe. The regular launcher and socket tests run through
`claude/scripts/tests/cx-remote-control.test.sh` and
`claude/scripts/tests/codex-remote-recovery.test.sh`.

## Public Skills

Public, reusable workflow skills live under `agents/skills/` (the
agent-neutral set shared with Antigravity — see `agents/README.md`) and are
directory-linked into Codex's documented user scope at `~/.agents/skills/` by
`setup.sh`; compatibility links under `~/.codex/skills/` support older clients.
Invoke them through `/skills`, mention them as `$skill-name`, or let Codex match
their descriptions implicitly. Custom Claude-style `/skill-name` commands are
not Codex skill invocations. Until 2026-07 the shared sources lived at
`codex/skills/`; the directory moved when Antigravity started consuming the
same set (issue #166).

Keep these skills generic and public-safe. Put personal preferences, private
project context, and machine-specific instructions in `~/dev/codex-memory`
instead.

## Operating Claude Code From Codex

`agents/skills/claude-operator/` ([SKILL.md](../agents/skills/claude-operator/SKILL.md))
lets Codex drive a native Claude Code install as the implementer: Codex writes
the brief, runs Claude through a small Python runner that records every
streamed event and the exact session ID, verifies the diff and checks itself,
sends follow-ups into the same session, and finishes only the delivery you
authorized. It installs with the rest of the shared set (`setup.sh` links it
into `~/.agents/skills/claude-operator`) but is **opt-in**: nothing here makes
Claude the default implementer. To make it your default, add one line to your
private `~/dev/codex-memory/AGENTS.local.md`, not to this repo.

The runner keeps your configured model, auth, hooks, and permissions, exposes
no bypass mode, and is not a sandbox. Its mock suite runs in CI
(`claude/scripts/tests/claude-operator-runner.test.py`). Windows Codex reads a
separate config root from the WSL one `setup.sh` manages; see
[docs/WINDOWS.md](../docs/WINDOWS.md#codex-on-windows-as-the-claude-operator)
for installing the skill there.

## Long-Running Work

Use Codex Goal mode (`/goal`) when a task explicitly needs persistent,
multi-turn execution. Put the outcome, constraints, acceptance criteria, and
stopping conditions in the goal; keep the normal sandbox and approval policy
in force. Remote Control is the steering and approval surface while the host
stays awake and connected—it is not a substitute for checkpoints.

For continuity, compact the active chat when needed, resume the same session
instead of starting cold, and finish material work with the shared `handoff`
skill so the branch, verification evidence, open risks, and resumable session
ID survive the terminal. If resume history becomes unreliable, run
`codex doctor --summary --ascii --no-color`, archive chats that are genuinely
complete, and never delete `~/.codex` session or database files by hand.
