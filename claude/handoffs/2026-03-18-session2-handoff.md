## Handoff — 2026-03-18 (session 2)

### What we did
- Evaluated whether the dotfiles repo is redundant with built-in Claude Code features
- Removed AgentPackJCK.md (old project-specific agent pack for shitmyspousesays.com)
- Removed stale `.claude/` directory from dotfiles repo (old flat-format skills, empty handoffs)
- Cleaned up 9+ stale `.backup` files across `~/.claude/`
- Created `check-claude.sh` — health check script that verifies symlinks, detects orphaned links, finds stale backups, supports `--fix` flag
- Made AgentPack.md on-demand (no longer symlinked into `~/.claude/`, loaded when needed for reviews)
- Trimmed CLAUDE.md from 119 to 89 lines — removed redundant skill/agent listings
- Made setup.sh auto-discover top-level files with NOLINK exclusion list
- Created private `claude-memory` repo (github.com/jckeen/claude-memory) for persistent memory files
- Wired memory into setup.sh (auto-symlinks) and check-claude.sh (verifies link health)
- Added `sync-memory` to `.bash_aliases` — auto-commits/pushes memory changes on session start
- Added `cc` auto-starts `--remote-control` for phone/web access
- Fixed hardcoded `~/dev/dotfiles` paths to use `_dev_dir()` function
- Fixed agent count from 12/15 to 16 across all docs
- Updated CLAUDE-GUIDE.md to list `cc` as recommended start command
- Updated sync-claude.sh to respect NOLINK list
- Added scripts/ and handoffs/ to README repo structure tree
- Fixed CLAUDE.md changelog rule from "end of session" to "after every 1-2 commits"
- Documented memory setup in README for others forking the repo
- Full doc audit with subagent — found and fixed 8 of 10 issues

### Where we left off
- Repo is clean, all pushed, docs are consistent
- All 10 commits from this session are on main

### Key decisions made
- **Custom skills are all keepers** — none truly redundant with official plugins (different scope/guardrails)
- **Custom agent MD files kept** — the 5 "low value" ones (content-reviewer, ux-reviewer, product-strategist, growth-strategist, trust-safety) were kept for now despite being thin
- **AgentPack.md is on-demand** — saves context tokens by not loading every session; CLAUDE.md tells Claude where to find it when reviews are needed
- **Memory lives in a separate private repo** — keeps dotfiles public while memory stays private and survives machine rebuilds
- **Changelog is continuous** — updated after every 1-2 commits, not batched to end of session
- **`cc` always starts remote control** — every session accessible from phone/web
- **`full-review.sh` needs testing** — may not reliably spawn 12+ subagents in headless mode; left as-is pending real-world test

### Open issues
- `full-review.sh` untested in practice — subagent spawning in headless `-p` mode may degrade
- The 5 thin agent files could still be removed (built-in subagent_type produces equivalent results)
- `sync-claude.sh` is mostly obsolete but kept as fallback for non-symlink environments — could be removed if nobody uses it
- `.gitconfig` safe.directory for claude-memory was added to global git config but NOT committed to dotfiles (machine-specific) — setup.sh should handle this

### Next steps
- Test `full-review.sh` on a real repo to see if multi-agent headless mode works
- Consider removing the 5 thin agent files if built-in types prove sufficient
- Consider whether `sync-claude.sh` should be removed entirely
- Add safe.directory setup for claude-memory to setup.sh's WSL section

### Context for next session
- The dotfiles repo is public at github.com/jckeen/dotfiles
- Memory repo is private at github.com/jckeen/claude-memory
- `~/.claude/CLAUDE.md` is symlinked to `dotfiles/claude/CLAUDE.md`
- AgentPack.md is NOT symlinked — lives at `dotfiles/claude/AgentPack.md` and is read on-demand
- The `cc` command flow: pull-all → sync-memory → check-claude → claude --remote-control
- The NOLINK pattern in setup.sh and check-claude.sh controls which files stay in dotfiles but don't get deployed
