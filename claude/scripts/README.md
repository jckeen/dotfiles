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
| `review-and-push.sh` | AI-reviews overnight changes, pushes if safe | Read-only review + push | Only pushes after validation |

## The Morning Workflow

After an overnight run, you don't read every diff. You run:

```bash
# Review and push one repo (prompts before pushing)
./review-and-push.sh ~/dev/atlas

# Review and push all repos
for repo in ~/dev/atlas ~/dev/stringer ~/dev/smss; do
  ./review-and-push.sh "$repo"
done

# Auto-push if tests pass and review is clean (no prompt)
./review-and-push.sh ~/dev/atlas --auto-push
```

What `review-and-push.sh` does:
1. Checks for unpushed commits and uncommitted changes
2. Runs the test suite — **stops if tests fail**
3. Sends the full diff to a fresh Claude review (read-only, separate context)
4. Extracts a verdict: **SAFE TO PUSH** / **NEEDS REVIEW** / **DO NOT PUSH**
5. Shows you a 20-line summary instead of a 500-line diff
6. Prompts for confirmation (or auto-pushes with `--auto-push` if verdict is SAFE)

The `--auto-push` flag will NOT push if the review flags issues — it only pushes on a clean SAFE verdict.

## Safety Tiers

Each script uses scoped `--allowedTools` to limit what Claude can do:

| Tier | Can do | Can't do |
|------|--------|----------|
| **TIER_READONLY** | Read files, search, git status/log/diff | Edit, write, run arbitrary commands |
| **TIER_LINT** | Above + edit files + run test/lint/build | Commit, push, run other commands |
| **TIER_FIX** | Above + write new files | Commit, push |
| **TIER_COMMIT** | Above + git add/commit/branch/checkout | Push, run arbitrary commands |
| **TIER_PUSH** | Above + git push + gh pr | Run arbitrary commands |

Only `review-and-push.sh` uses TIER_PUSH, and only after tests pass and a review clears it.

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

## Prerequisites

- [Claude Code](https://code.claude.com) installed and authenticated (`claude` on PATH)
- `gh` CLI (for `fix-issues.sh` — GitHub issue lookup and PR creation)
- Bash 4+ (macOS: `brew install bash`; Linux/WSL: included)

## Options

All scripts accept:

| Flag | Effect | Used by |
|------|--------|---------|
| `--full-auto` | Bypass all permission checks (prints warning banner) | All scripts |
| `--max-turns N` | Override max Claude turns (default: 15, full-review: 25) | All scripts |
| `--auto-push` | Push without prompting if verdict is SAFE TO PUSH | `review-and-push.sh` only |
| `--deep` | Enable test coverage + issue fixing phases | `overnight.sh` only |

Environment variables:

| Variable | Effect |
|----------|--------|
| `FULL_AUTO=true` | Same as `--full-auto` flag |
| `MAX_TURNS=N` | Override max turns |
| `LOG_DIR=/path` | Override log directory (default: `~/.claude/logs/`) |
| `MODEL=sonnet` | Override model (default: opus) |
| `CLAUDE_REPOS="~/a ~/b"` | Explicit repo list for `overnight.sh` |
| `CLAUDE_DEV_DIR=/path` | Dev directory for auto-detection (default: `~/dev`) |

## Logs

All output goes to `~/.claude/logs/` with filenames like:

```
TIER_READONLY_atlas_2026-03-18_2300.log
TIER_FIX_stringer_2026-03-18_2300.log
```

## Repo Configuration

`overnight.sh` discovers repos automatically. Three ways to configure, in priority order:

### Option 1: Environment variable (explicit repos)

```bash
export CLAUDE_REPOS="~/dev/atlas ~/dev/stringer ~/dev/smss"
```

### Option 2: Config file (explicit repos)

```bash
# ~/.claude/repos — one path per line, # comments allowed
~/dev/atlas
~/dev/stringer
~/dev/smss
# ~/dev/old-project  # commented out, skipped
```

### Option 3: Auto-detect (zero config)

If neither env var nor config file exists, `overnight.sh` scans your dev directory for git repos. It finds the dev directory by checking:

1. `CLAUDE_DEV_DIR` env var
2. `~/.claude/dev-dir` file (contains one path)
3. Falls back to `~/dev`

This works on macOS (`~/dev`), Linux (`~/dev`), and WSL (`/mnt/c/Users/you/dev` — just set the env var or config file).

```bash
# WSL example
echo "/mnt/c/Users/jckee/dev" > ~/.claude/dev-dir

# Or env var in your .bashrc / .zshrc
export CLAUDE_DEV_DIR="/mnt/c/Users/jckee/dev"
```

## For Dotfiles Users

Getting started:

1. **Install prerequisites**: Claude Code, `gh` CLI, Bash 4+
2. **Make scripts executable**: `chmod +x ~/dotfiles/claude/scripts/*.sh`
3. **Configure your dev directory** (pick one):
   - Do nothing if your repos are in `~/dev` (macOS/Linux default)
   - `echo "/mnt/c/Users/you/dev" > ~/.claude/dev-dir` (WSL)
   - `export CLAUDE_DEV_DIR="/path/to/dev"` in your shell profile
4. **Test with a safe read-only run**: `./health-check.sh /path/to/your/repo`
5. **Try overnight**: `./overnight.sh` (read-only health checks across all repos)
6. **Go deeper when comfortable**: `./overnight.sh --deep` (writes tests + fixes issues)
7. **Morning review**: `./review-and-push.sh /path/to/repo` (AI reviews changes, prompts before push)
8. **Schedule with cron** when you trust the workflow (see Scheduling section above)
