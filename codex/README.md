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
