# Claude Autonomous Scripts

Run Claude Code headless on your repos — scheduled or on-demand.

## Quick Start

```bash
# Health check a single repo (read-only, totally safe)
./health-check.sh ~/dev/atlas

# Health check all repos overnight
./overnight.sh

# Deep overnight run (health + tests + issue fixes)
./overnight.sh --deep
```

## Scripts

| Script | What it does | Safety tier | Changes files? |
|--------|-------------|-------------|----------------|
| `health-check.sh` | Repo briefing + dependency audit | Read-only | No |
| `full-review.sh` | Full 3-phase agent pack review | Read-only | No |
| `test-coverage.sh` | Writes tests for uncovered code | Fix (edit + test) | Yes — review with `git diff` |
| `fix-issues.sh` | Picks up GitHub issues, creates fix branches | Commit (edit + commit) | Yes — review branches |
| `overnight.sh` | Orchestrates all of the above across repos | Varies | Depends on flags |

## Safety Tiers

Each script uses scoped `--allowedTools` to limit what Claude can do:

| Tier | Can do | Can't do |
|------|--------|----------|
| **TIER_READONLY** | Read files, search, git status/log/diff | Edit, write, run arbitrary commands |
| **TIER_LINT** | Above + edit files + run test/lint/build | Commit, push, run other commands |
| **TIER_FIX** | Above + write new files | Commit, push |
| **TIER_COMMIT** | Above + git add/commit/branch/checkout | Push, run arbitrary commands |

No tier allows `git push`. You always review before pushing.

## Full Auto Mode

If you trust a script to run completely unattended:

```bash
# Per-script
./test-coverage.sh ~/dev/atlas --full-auto

# Or via environment variable
FULL_AUTO=true ./overnight.sh --deep

# Overnight run with full auto
./overnight.sh --deep --full-auto
```

This adds `--dangerously-skip-permissions` and removes tool restrictions. A warning banner prints when active. **Use only when you've already run the script in scoped mode and trust it.**

## Scheduling with Cron

### Off-peak hours (doubled usage through March 28, 2026)

Off-peak = weekdays outside 5-11am PT, all day weekends.

```bash
# Edit your crontab
crontab -e

# Nightly health check at 11pm PT (safe, read-only)
0 23 * * * /path/to/dotfiles/claude/scripts/overnight.sh >> ~/.claude/logs/overnight.log 2>&1

# Weekend deep run at 2am PT Saturday
0 2 * * 6 /path/to/dotfiles/claude/scripts/overnight.sh --deep >> ~/.claude/logs/overnight.log 2>&1
```

### After the promotion ends

The scripts still work — just without doubled usage. Schedule them whenever makes sense for your workflow.

## Options

All scripts accept:

| Flag | Effect |
|------|--------|
| `--full-auto` | Bypass all permission checks (prints warning banner) |
| `--max-turns N` | Override max Claude turns (default: 15, full-review: 25) |

Environment variables:

| Variable | Effect |
|----------|--------|
| `FULL_AUTO=true` | Same as `--full-auto` flag |
| `MAX_TURNS=N` | Override max turns |
| `LOG_DIR=/path` | Override log directory (default: `~/.claude/logs/`) |
| `CLAUDE_REPOS="~/a ~/b"` | Override repo list for `overnight.sh` |
| `MODEL=sonnet` | Override model (default: opus) |

## Logs

All output goes to `~/.claude/logs/` with filenames like:

```
TIER_READONLY_atlas_2026-03-18_2300.log
TIER_FIX_stringer_2026-03-18_2300.log
```

## For Dotfiles Users

If you're using these dotfiles, the scripts are ready to go:

1. Edit `overnight.sh` and update the `DEFAULT_REPOS` array with your repo paths
2. Run `chmod +x ~/dotfiles/claude/scripts/*.sh`
3. Try `./health-check.sh /path/to/your/repo` first to verify it works
4. Add cron entries when you're comfortable
