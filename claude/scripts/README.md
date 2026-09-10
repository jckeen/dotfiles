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
| `review-and-push.sh` | Reviews committed changes with the required Codex gate, validates the receipt, and pushes the current branch | Artifact review + push | Only pushes after validation |
| `sync-plugins.sh` | Installs plugins listed in `$DOTFILES_DIR/claude/plugins.txt` that are not yet installed; idempotent. Installs both manifest sections — `[global]` and `[per-project]` (issue #214); enablement scoping lives in settings.json `enabledPlugins` and is checked by `PluginDriftCheck.hook.ts`. Auto-run by `cc` at launch (pre-exec, so installs apply to the session being started); fast-path exits silently when there's no drift | Install (calls `claude plugin install`) | No file edits — updates plugin state |
| `check-doc-truth.sh` | Portable doc-contract checker (ADR 0005); asserts every tracked `*.md` is declared in a tier, HISTORICAL docs carry a point-in-time marker, relative links in LIVING/GENERATED docs resolve, and BANNED patterns are absent from their scoped tiers. Vendored into other repos by `/drift-sweep`. Tests: `tests/doc-truth.test.sh` | Read-only | No |
| `gen-instruction-files.sh` | Builds the three global instruction files (`claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md`) from the canonical sources in `agents/canon/` (ADR 0007) — shared rule blocks in `CANON.md`, per-tool voice in `fragments/`. `--check` verifies the committed artifacts are byte-current (run in CI via `check-agent-parity.sh`). Tests: `tests/agent-parity.test.sh` | Build (writes the three generated files) | Yes — regenerates committed artifacts |
| `gen-agentpack.sh` | Generates `claude/AGENTPACK.yaml` (the AgentPack manifest) from the live frontmatter of `claude/skills/*/SKILL.md` and `claude/agents/*.md` plus the hand-maintained fragment `claude/agentpack-meta.json`, so the manifest can't drift from the source (issue #207). `--check` (run in CI) exits 1 if the committed manifest is stale | Generate | Yes — rewrites `claude/AGENTPACK.yaml` |

## The Morning Workflow

After an overnight run, you don't read every diff. You run:

```bash
# Review and push one repo (prompts before pushing)
./review-and-push.sh ~/dev/atlas

# Review and push all repos
for repo in ~/dev/atlas ~/dev/stringer ~/dev/smss; do
  ./review-and-push.sh "$repo"
done

# Auto-push after tests, the required review gate, and receipt validation
./review-and-push.sh ~/dev/atlas --auto-push
```

What `review-and-push.sh` does:

1. Inspects the non-default branch and working tree, then pins the current commit.
2. Runs the detected test suite and stops on failure.
3. Runs the Codex review gate with `--require --committed` on the committed artifact.
4. Prompts for confirmation, unless `--auto-push` was selected.
5. Validates the Codex receipt after confirmation, immediately before push.
6. Pushes the reviewed commit to the current branch with an explicit refspec.

Blocking findings, failed reviewer execution, and missing or stale receipts
prevent pushing. Gate exit 0 alone does not prove a review completed: explicit
tier/no-diff exemptions are reported separately from successful reviews.
Changing the artifact invalidates approval and requires affected verification
and review again. The wrapper requires the pinned commit to remain current
through tests, review, and confirmation. `--auto-push` removes the prompt, not the checks. The pre-push
hook validates each pushed ref's commit receipt independently of whether the
secret scanner runs. For a PR explicitly targeting a nondefault base, run the
gate and receipt check with `--base <ref>`, then use
`REVIEW_RECEIPT_BASE=<ref> git push ...` for that push. The hook otherwise
requires the repository's default base. The setting selects the expected
base; it does not bypass artifact validation.
The selected remote must have exactly one nonempty configured push URL, or
one nonempty configured fetch URL when no push URL is set. Empty or multiple
values are rejected even when Git normalizes them to a single destination.
The wrapper rejects resolved destinations that name another remote or would
be transformed by another URL rewrite; use a direct destination in that case.
It requires Git protocol v2 with server-option support to inspect branch aliases
and rejects advertised symbolic destination refs. An unadvertised destination
must have no resolved object when the push occurs, so it cannot overwrite an
existing branch. Git cannot distinguish an absent ref from a hidden dangling
alias: such an alias may create its missing nondefault target. These checks
cannot guard server-side ref changes after validation.
It selects the branch's `pushRemote`, then `remote.pushDefault`, then the
branch's fetch remote, falling back to `origin` when none is configured.
Committed scope keeps unrelated working changes out of the push review even
when the fetch upstream is current and the selected push fork is behind.
Dirty instruction surfaces still block committed review. An explicit
`--uncommitted` review includes ignored instruction files in its review target.
It covers both staged changes and later workspace edits.
Text diffs preserve physical lines, including embedded control characters,
and quote filenames in their headers.
Instruction coverage includes shared skill bundles and canonical sources under
`agents/skills/` and `agents/canon/`, Claude skill and agent sources under
`claude/skills/` and `claude/agents/`, and the Claude AgentPack manifest,
metadata, and policy files. Ignored references inside these bundles remain
bound to the receipt; ordinary documentation outside them keeps its usual policy.
Instruction checks recognize Git-managed CRLF text conversion for regular files
and sparse checkout omissions while retaining raw workspace hashes.
Automatic text conversion respects Git's binary classification; explicitly
forced text conversion retains Git's configured behavior.
Known ignored agent runtime credentials and state are excluded from instruction
discovery. Named instruction files inside runtime directories remain covered.
Recognized runtime artifacts explicitly included in the review target block
review before their contents can reach a reviewer. These filename and directory
rules are not a general secret scanner.

Receipts live in the worktree's Git metadata, outside tracked files. They are
local evidence, not signatures against the filesystem owner. The checker
uses artifact identity and attempt tokens for freshness; clock adjustments
do not invalidate a completed review. It requires the outgoing commit to be
that worktree's current HEAD and rejects submodules and non-UTF-8 review content.
An unchanged canonical instruction link such as `AGENTS.md -> CLAUDE.md` is
supported when it takes one relative hop to a tracked regular instruction file
inside the repository. Link and target must match the review base, HEAD, index
and working tree; the receipt binds both identities and contents. Absolute,
external, chained, dangling, sparse or untracked targets are unsupported.
Changing a canonical link or target requires separate instruction review until
the gate can follow aliases in its self-review policy. Installed global links
outside the repository are unaffected. Ordinary leaf symlinks remain
reviewable as link text. Review another branch in its own worktree; resolve
unsupported content explicitly before shipping.
Reviewer dispatch information and observed identity are recorded separately.
The configured docs-only size limit is captured with the review policy and
checked again when its exemption is completed or used for shipping.
Classification and exemption validation use the same policy implementation.
Passive filename filters retain instruction files, executable files, and
symlinks, including staged executable modes when `core.filemode` is disabled.
Documentation exemptions require nonexecutable regular files with
recognized documentation names.
No-diff exemptions also validate the changed paths; an empty patch cannot
exempt an active path. Review path selection uses a fixed literal policy,
and repository and worktree paths retain their exact whitespace.

## Safety Tiers

### Codex review runtime

The Codex gate honors `CODEX_GATE_BIN` when explicitly set. Otherwise it prefers
the managed standalone installation under `~/.codex` and falls back to `PATH`. Set `CODEX_GATE_BIN=codex` to deliberately select the
executable on `PATH`. The receipt records the executable used by that run.

The gate runs Codex in the foreground and validates its exit status, structured
result, and artifact receipt. Native Codex handles terminal cancellation and
its tool processes. Send cancellation to the foreground job; a signal sent
only to the Bash wrapper may wait until the current command returns. Observed
cancellation invalidates approval, including during receipt creation.

The gate provides no hard execution deadline or detached-process containment.
Unattended jobs that require those guarantees must obtain them from their
execution host. An explicitly set `CODEX_GATE_TIMEOUT` is rejected so it cannot
silently imply a deadline. Offline fixtures run in required Linux CI and the
[native macOS portability workflow](../../.github/workflows/smoke-install.yml).
Failures report a diagnostic hint and a private temporary log path without
printing raw reviewer stderr, which may contain reviewed content. Inspect that
log when needed and keep it out of repositories.

### Claude script tiers

Each script uses scoped `--allowedTools` to limit what Claude can do:

| Tier | Can do | Can't do |
|------|--------|----------|
| **TIER_READONLY** | Read files, search, git status/log/diff | Edit, write, run arbitrary commands |
| **TIER_FIX** | Above + edit + write files + run tests | Commit, push |
| **TIER_COMMIT** | Above + git add/commit/branch/checkout | Push, run arbitrary commands |

`review-and-push.sh` uses the required Codex gate and its artifact receipt, then
performs `git push` from bash after the confirmation and evidence checks. The
tiers above describe scripts that invoke Claude through `common.sh`.

## Full Auto Mode

If you trust a script to run completely unattended:

```bash
# Per-script
./test-coverage.sh ~/dev/atlas --full-auto

# Overnight run with full auto
./overnight.sh --deep --full-auto
```

This adds `--dangerously-skip-permissions` and removes tool restrictions. A warning banner prints when active. **Use only when you've already run the script in scoped mode and trust it.** `FULL_AUTO=true` in the environment is intentionally ignored; the bypass must be passed explicitly as a CLI flag.

## Scheduling with Cron

Schedule scripts whenever makes sense for your workflow.

```bash
# Edit your crontab
crontab -e

# Nightly health check at 11pm PT (safe, read-only)
0 23 * * * /path/to/dotfiles/claude/scripts/overnight.sh >> ~/.claude/logs/overnight.log 2>&1

# Weekend deep run at 2am PT Saturday
0 2 * * 6 /path/to/dotfiles/claude/scripts/overnight.sh --deep >> ~/.claude/logs/overnight.log 2>&1
```

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
| `--auto-push` | Push without prompting after tests, the required review gate, and current receipt validation | `review-and-push.sh` only |
| `--deep` | Enable test coverage + issue fixing phases | `overnight.sh` only |

Environment variables:

| Variable | Effect |
|----------|--------|
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

This works on macOS (`~/dev`), Linux (`~/dev`), and WSL (`~/dev`). Keep repos on the Linux filesystem for ~10x faster I/O — avoid `/mnt/c/`.

```bash
# WSL: repos should live under ~/dev (Linux filesystem), NOT /mnt/c/
# setup.sh writes ~/.claude/dev-dir automatically — no manual config needed
```

## For Dotfiles Users

Getting started:

1. **Install prerequisites**: Claude Code, `gh` CLI, Bash 4+
2. **Make scripts executable**: `chmod +x ~/dotfiles/claude/scripts/*.sh`
3. **Configure your dev directory** (pick one):
   - Do nothing if your repos are in `~/dev` (default on all platforms including WSL)
   - `export CLAUDE_DEV_DIR="/path/to/dev"` in your shell profile (if non-standard)
4. **Test with a safe read-only run**: `./health-check.sh /path/to/your/repo`
5. **Try overnight**: `./overnight.sh` (read-only health checks across all repos)
6. **Go deeper when comfortable**: `./overnight.sh --deep` (writes tests + fixes issues)
7. **Morning review**: `./review-and-push.sh /path/to/repo` (AI reviews changes, prompts before push)
8. **Schedule with cron** when you trust the workflow (see Scheduling section above)

## Worktree lifecycle

`worktree-lifecycle.py inventory --repo /path/to/repo` reports task worktrees
separately from GitHub repository-settings drift. Use `--root /path/to/dev`
to inventory primary repositories under a shared directory. The daily hygiene
timer saves this read-only inventory to `~/.local/state/hygiene/worktrees.json`.
Read it with `hygiene-status.sh --worktrees`; `--status` describes repository
settings only.
Unreleased worktrees have unknown or active ownership and remain retained.

The task owner stops its processes, leaves the target directory, and releases
the completed artifact with its PR and session identifier:

```sh
python3 claude/scripts/worktree-lifecycle.py release --repo /path/to/repo \
  --worktree /path/to/task --head COMMITTED_HEAD --owner SESSION_ID \
  --pr PR_NUMBER --github-repo OWNER/REPO
```

A pending PR remains retained with that owner. After it merges, an authorized
session refreshes repository refs and previews the specific retirement:

```sh
git -C /path/to/repo fetch origin
python3 claude/scripts/worktree-lifecycle.py retire --repo /path/to/repo \
  --worktree /path/to/task
```

Add `--apply --archive-dir /path/to/private/archive` only when cleanup is
already authorized. The collector requires the exact released HEAD on a merged
same-repository PR, its merge commit reachable from the verified current remote
default, and a clean, unlocked worktree without active processes. Squash merges
use the actual PR head and merge identities. A changed HEAD, unknown evidence,
ignored or special files, empty directories, special index flags or submodules
means retain for separate inspection. Raw file bytes and modes must match the
committed blobs; transformed checkout contents and active content filters also
require separate retirement. Inspection does not execute those filters.
Process inspection requires Linux `/proc` and checks same-user processes'
working directories, roots, executables, open descriptors and file-backed
memory mappings. Missing or unreadable evidence retains the worktree. Other
hosts require an explicit platform-appropriate review.

Before non-force removal, the collector verifies a recovery Git bundle
including reflog-reachable commits,
archives worktree metadata including review receipts, and records identities
and file hashes in a private recovery record. Stashes and branch refs stay in
the source repository. The timer never releases or deletes worktrees; the next
session owns follow-up for pending releases. User authorization and release
ownership remain prerequisites for mutation, including when a standing order
covers cleanup. This is not a lock against a filesystem owner starting new work
after releasing a task.
