# Codex Dotfiles

This directory contains only public-safe Codex defaults. The dotfiles repository
is public, so live Codex state must stay local or in a separate private repo.

## Safe to Track Here

- General, reusable Codex guidance such as `AGENTS.md`
- General, reusable Codex skills such as `skills/*/SKILL.md`
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

Public, reusable Codex workflows live under `codex/skills/` and are symlinked
into `~/.codex/skills/` by `setup.sh`.

Keep these skills generic and public-safe. Put personal preferences, private
project context, and machine-specific instructions in `~/dev/codex-memory`
instead.
