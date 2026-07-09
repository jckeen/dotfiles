# Codex Dotfiles

This is how I run Codex day-to-day — the reusable, public-safe pieces. Codex
keeps its own auth, history, sqlite state, and per-project trust local; what
lives here is everything I'm happy to share across machines (and with you, if
you fork this repo): the global `AGENTS.md` rules and example config. The
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

## Public Skills

Public, reusable workflow skills live under `agents/skills/` (the
agent-neutral set shared with Antigravity — see `agents/README.md`) and are
symlinked into `~/.codex/skills/` by `setup.sh`. Until 2026-07 they lived at
`codex/skills/`; the directory moved when Antigravity started consuming the
same set (issue #166).

Keep these skills generic and public-safe. Put personal preferences, private
project context, and machine-specific instructions in `~/dev/codex-memory`
instead.
