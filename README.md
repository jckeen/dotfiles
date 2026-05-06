# Dotfiles — A Jumpstart for Claude Code + Codex

A one-command setup that gets you from a blank machine to a full Claude Code + Codex working environment with sane defaults, safety hooks, multi-session tooling, and a 16-agent code-review orchestra. Built for **macOS** and **Windows (via WSL2 + Ubuntu)**, with Linux supported as a side effect.

This is opinionated — it's how *I* (and now hopefully you) run Claude Code and Codex day-to-day. Clone it, run `./setup.sh`, and skip months of trial-and-error.

Best practices sourced from [Boris Cherny](https://howborisusesclaudecode.com) (creator of Claude Code), the [official Claude Code docs](https://code.claude.com/docs/en/best-practices), and hard-won experience across thousands of agent sessions.

---

## What you get (and why it matters)

After setup, you don't have to remember much. Open a terminal and:

- **`cc`** — one alias that pulls every repo in your `~/dev/` directory (fast-forward only), syncs your memory repo, runs a health check, then launches Claude Code. **`cx`** does the same for Codex. No more "is my repo up to date?" or "did I forget to pull?" — that's automatic now.
- **A live status line** — model name, context-bar (green/yellow/red), git branch, lines added/removed, session cost in USD. You always know how warm your context is, what branch you're on, and what the session has cost — without asking.
- **11 slash commands** that cover the whole loop — `/kickoff` (new project), `/review` (quality + security), `/simplify` (de-engineer), `/fix-issue` (GitHub issue end-to-end), `/handoff` (clean session transition), `/changelog`, `/log-error`, `/commit-push-pr`, `/claude-server`, `/decompose`, `/max`. Type the verb, get the workflow.
- **A 16-agent review orchestra** — `qa-lead`, `security-reviewer`, `frontend-architect`, `backend-architect`, `ux-reviewer`, `growth-strategist`, `trust-safety`, `perf-accessibility`, and 8 more. Each runs in its own isolated context and reports back without polluting your main session. Three-phase orchestration (Product → Architecture → Launch) for serious reviews.
- **Safety hooks that can't be forgotten** — auto-format on edit (prettier, black, rustfmt, gofmt), conventional-commit enforcement, push notifications when Claude is waiting on you, and a `StripProjectPermissions` hook that prevents per-project permission creep from overriding your global allowlist.
- **Multi-session tooling** — open 3, 5, or 8 Claude sessions across different projects in a single Windows Terminal window via `cc-pane`/`cc-tab`/`cc-multi` (bash) or `ccgrid`/`cctab`/`ccpane` (PowerShell). Each session gets the full `cc` treatment — repo sync, tab colors, health check.
- **Agent-neutral helpers** — `wsl6` opens a 3×2 grid of plain WSL shells (no Claude/Codex coupling) for ad-hoc multi-shell work.
- **Auto-hygiene** — a daily systemd timer cleans stale branches across every repo in `~/dev/`, surfaces drift at every Claude/Codex session start, and bootstraps the canonical 8 GitHub auto-merge settings on every newly-created or cloned repo.
- **Public-safe Codex parity** — same skill set as Claude (review, simplify, fix-issue, commit-push-pr, handoff, changelog, repo-health, branch-hygiene), wired so `cx` mirrors `cc`. Codex auth, sessions, sqlite state, and live `config.toml` stay local; only public-safe guidance and skills are shared.
- **Cross-platform symlink hygiene** — `setup.sh` is idempotent and runs the same on macOS and WSL. Edit `~/.claude/agents/foo.md` and the change is in your repo automatically (it's a symlink). `dotfiles-update` keeps everything in sync with one command.

> **Why this exists:** Claude Code and Codex are powerful but the defaults aren't tuned for serious daily work — context bloats, sessions vanish without handoffs, branches pile up, agent reviews are ad-hoc, and you re-discover the same gotchas every project. This repo encodes the "second-day knowledge" that makes the tools actually compound. If you're going to spend hundreds of hours in these CLIs, spend the first 10 minutes setting up properly.

---

## Quick Start

Pick your platform. Each path leaves you with the same end state: Claude Code + Codex installed, hooks wired, slash commands available, status line showing, multi-session helpers ready.

### Windows (use WSL2 — strongly recommended)

Claude Code runs *much* better in WSL2 than directly on Windows: native Linux filesystem (~10x faster I/O than `/mnt/c/`), full POSIX tooling, and our PowerShell helpers (`wsl6`, `ccgrid`, etc.) bridge nicely between Windows Terminal and WSL.

**Prerequisites** — install these once, in PowerShell as Administrator (skip any you already have):

```powershell
# 1. WSL2 + Ubuntu (reboot if it's a fresh WSL install)
wsl --install -d Ubuntu

# 2. PowerShell 7 (preferred — Windows ships with PS 5.1, but PS 7 is faster
#    and is what you should be using day-to-day)
winget install --id Microsoft.PowerShell --source winget

# 3. Windows Terminal (preinstalled on Windows 11; install on 10)
winget install --id Microsoft.WindowsTerminal --source winget
```

> **Why PowerShell 7?** PS 5.1 is end-of-life maintenance only and uses `Documents\WindowsPowerShell\` for its profile. PS 7 is the modern, cross-platform Core build, uses `Documents\PowerShell\`, and is faster on every workload. `setup.sh` wires our helpers into **both** profiles so you're covered either way, but you should default to PS 7.

**Inside WSL** (open Ubuntu from the Start menu, or `wsl` from any terminal):

```bash
# Clone this repo into the Linux filesystem (NOT /mnt/c/ — that's ~10x slower)
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# Run setup — auto-detects WSL, installs everything, prompts where it matters
./setup.sh

# Authenticate (do these once)
gh auth login          # GitHub CLI — choose HTTPS + browser
claude                 # Sign in to Claude (or 'claude auth login' if it doesn't prompt)
codex login            # Optional: sign in for Codex CLI
```

You're done. Open a new PowerShell 7 window and try `wsl6`, or run `cc` inside WSL.

### macOS

**Prerequisites** — install these once if you don't have them:

```bash
# 1. Xcode Command Line Tools (gives you git, clang, etc.)
xcode-select --install

# 2. Homebrew (everything else installs through this)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Then:**

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# Run setup — auto-detects macOS, installs Node/bun/gh/jq via brew if missing
./setup.sh

# Authenticate
gh auth login
claude
codex login            # Optional
```

> **Why macOS?** Native Unix toolchain, no VM overhead, excellent terminal options (Terminal.app, iTerm2, Ghostty, Warp — pick your favorite). The setup script handles macOS-specific things (osxkeychain credential helper, brew package install, zsh `.bash_aliases` sourcing) automatically.

### Linux (native, not WSL)

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles
./setup.sh
gh auth login
claude
codex login            # Optional
```

### Setup-script flags (all platforms)

```bash
./setup.sh             # default: prompts "Are you using PAI? [Y/n]"
./setup.sh --no-pai    # skip the prompt — Claude Code + hooks only
./setup.sh --pai       # skip the prompt — assume PAI (needs claude-memory repo)
./setup.sh --check     # read-only audit of all symlinks; exits non-zero if broken
./setup.sh --repair    # audit + recreate any broken/missing symlinks
```

> **Public repo safety:** this dotfiles repo is public. Don't commit Codex/Claude auth tokens, generated sessions, sqlite state, logs, caches, private memory, account IDs, private MCP endpoints, personal identity notes, or client/project details. Private state lives in `claude-memory` and `codex-memory` (separate private repos — see below).

> **PAI mode:** Default-on. Wires in [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure) — install PAI first (`danielmiessler/Personal_AI_Infrastructure/Releases/v4.0.3` → `bash ~/.claude/install.sh`) and clone your private `claude-memory` repo under `~/dev/` before running `setup.sh`. **`--no-pai`** skips the claude-memory integration entirely and leaves you with hooks, skills, agents, and dotfiles only.

> **WSL filesystem rule:** Always clone repos under `~/dev` (Linux filesystem), **not** `/mnt/c/` (Windows mount). File I/O on the native Linux filesystem is ~10x faster. The setup script auto-configures your shell to `cd ~/dev` on startup.

---

### Try it now

After setup, run these to see what you've got:

```bash
cc                    # pulls all your repos, then launches Claude
cx                    # pulls all your repos, then launches Codex
dotfiles-update       # pull latest dotfiles + re-run setup (idempotent — safe anytime)
projects              # list everything under ~/dev/
sessions              # show active Claude sessions and their cwds
```

Once inside Claude:
- Type `/review` to run a code quality check on your last few commits
- Type `/simplify` after writing code to remove unnecessary complexity
- Ask "Run the qa-lead agent on this project" to spawn an isolated review
- Watch the status line — it shows context %, git branch, cost, and lines changed

**Windows (PowerShell 7) users — open a fresh PowerShell 7 window and try:**

| Command | What it does |
|---------|-------------|
| `wsl6` | Opens a Windows Terminal tab with a 3×2 grid of plain WSL shells (agent-neutral) |
| `ccprojects` | Lists projects available under your WSL `~/dev/` |
| `ccgrid dotfiles atlas stringer` | One new tab, three split panes, each running `cc <project>` inside WSL |
| `cctab dotfiles atlas` | One tab per project, each running `cc <project>` inside WSL |
| `ccpane dotfiles` | Splits the current Windows Terminal window with `cc dotfiles` |

These are auto-installed by `setup.sh` on WSL (it asks "Install into your PowerShell profile(s)? [Y/n]" — answer Y). The installer wires both PS 5.1 and PS 7 profiles, so the helpers work in whichever you prefer. **If you missed the prompt or installed before this fix, just run `dotfiles-update` from WSL.**

---

## What Gets Installed

| Tool | Purpose | Install method |
|------|---------|---------------|
| `gh` | GitHub CLI | Homebrew (macOS) / apt (Linux) |
| `git` | Version control | Homebrew / apt |
| `node` | Node.js LTS | Homebrew / NodeSource |
| `jq` | JSON processing (used by hooks) | Homebrew / apt |
| `claude` | Claude Code CLI | npm |
| `codex` | OpenAI Codex CLI | npm |
| `bun` | Runtime for `*.hook.ts` hooks | Homebrew / npm |

WSL also gets: `pulseaudio-utils`, `libasound2-plugins`, `alsa-utils` (for `/voice` support).

## What Gets Configured

Public Claude config pieces are **symlinked** from this repo to `~/.claude/`, so edits in either location stay in sync. Private/PAI-owned Claude instructions and settings come from `claude-memory`. Codex is stricter: only public-safe guidance and skills are symlinked into `~/.codex/`; live `~/.codex/config.toml` stays local because Codex stores machine-specific project trust there.

| What | Files | Purpose |
|------|-------|---------|
| **Claude instructions** | `~/dev/claude-memory/pai-config/CLAUDE.md` | Private global rules Claude follows in every session |
| **Settings** | `~/dev/claude-memory/pai-config/settings.json` | Private permissions, hooks, preferred model, remote control |
| **Agent Pack** | `AgentPack.md` | 16-agent review orchestra (loaded on-demand, not symlinked) |
| **Status line** | `statusline.sh` | Shows model, context %, git branch, lines changed, session cost |
| **Commit hook** | `hooks/conventional-commit.sh` | Enforces `type: description` commit message format |
| **Format hook** | `hooks/format-on-edit.sh` | Auto-formats files after edits (prettier, black, rustfmt, gofmt) |
| **Notification hook** | `hooks/ntfy-awaiting-input.sh` | Sends push notification when Claude needs input |
| **Permission guard** | `hooks/StripProjectPermissions.hook.ts` | Strips project-level permission overrides on SessionStart |
| **Skills** | `skills/*/SKILL.md` | Claude slash commands (see below) |
| **Subagents** | `agents/*.md` | 16 specialized review agents |
| **Shell aliases** | `.bash_aliases` | `cc`, `pull-all`, worktree shortcuts |
| **Codex guidance** | `codex/AGENTS.md` | Public-safe global Codex working rules |
| **Codex skills** | `codex/skills/*/SKILL.md` | Public-safe Codex workflows for review, issue fixes, PRs, handoffs |
| **Codex config example** | `codex/config.toml.example` | Template only; live `~/.codex/config.toml` stays local |
| **Git config** | `.gitconfig` + `.gitconfig.local` | Identity, editor, credential helper (per-platform) |
| **Audio** | `.asoundrc` (WSL only) | ALSA → PulseAudio routing for voice mode |

## Platform-specific behavior

| Feature | macOS | WSL | Linux |
|---------|-------|-----|-------|
| Package manager | Homebrew | apt | apt |
| Shell config | `.zshrc` | `.bashrc` | `.bashrc` |
| Credential helper | osxkeychain | Git Credential Manager (Windows) | git-credential-store |
| Audio (for /voice) | Built-in | ALSA → PulseAudio | N/A |
| Git safe.directory | Not needed | Auto-configured for `/mnt/c/` | Not needed |

---

## Shell Commands & Aliases

These are available after setup (sourced from `.bash_aliases`).

### Starting Claude

| Command | What it does |
|---------|-------------|
| `cc` | **Recommended way to start.** Pulls repos, syncs memory, runs health check, launches Claude |
| `claude` | Start Claude directly (no repo sync) |
| `claude-rc` | Start with explicit remote control flag |
| `claude-server` | Spawn an isolated worktree + remote control session |

### Starting Codex

| Command | What it does |
|---------|-------------|
| `cx` | Pulls repos, runs `check-codex`, then launches Codex |
| `cx <project>` | Start Codex in `~/dev/<project>` |
| `codex` | Start Codex directly (no repo sync) |
| `codex resume` | Resume a previous Codex session |
| `codex review --uncommitted` | Review staged, unstaged, and untracked changes |

### Repo management

| Command | What it does |
|---------|-------------|
| `pull-all` | Git pull (fast-forward only) on every repo in your dev directory that has a remote. Skips local-only repos |
| `sync-memory` | Commit and push any pending memory changes (runs automatically as part of `cc`) |
| `check-claude` | Verify all Claude config symlinks, memory, and hooks are healthy |
| `check-codex` | Verify public-safe Codex symlinks and warn about private/generated state |
| `dotfiles-update` | Pull latest dotfiles and re-run setup.sh |
| `codex-update` | Run `codex update` |

### Git worktree shortcuts

Run multiple Claude sessions in parallel on the same project using worktrees.

| Command | What it does |
|---------|-------------|
| `za` through `ze` | Jump to worktree `-a` through `-e` (e.g., `../myproject-a`) |
| `z0` | Jump back to the main worktree (repo root) |
| `gwl` | `git worktree list` |
| `gwa` | `git worktree add` |
| `gwr` | `git worktree remove` |
| `wt-claude <name> [branch]` | Create a worktree and launch Claude in it |

### Multi-session (WSL + Windows Terminal)

Run Claude across multiple projects simultaneously without leaving your terminal. Each session gets full `cc` treatment (repo sync, tab colors, health check).

| Command | What it does |
|---------|-------------|
| `cc-pane <project>` | Open project in a new **split pane** (vertical by default) |
| `cc-pane <project> -H` | Open project in a **horizontal** split pane |
| `cc-tab <project>` | Open project in a new **tab** |
| `cc-multi <p1> <p2> ...` | Open multiple projects, each in its own **tab** |
| `projects` | List available projects in your dev directory |
| `sessions` | Show active Claude sessions and their working directories |

**Quick start — your old workflow vs. new:**

```bash
# OLD: open PowerShell → wsl → cd ~/dev/myproject → cc
# ×3 for three projects

# NEW: from any existing terminal (or from inside Claude with ! prefix)
cc-multi dotfiles pai stringer     # 3 tabs, each synced and running

# Or split your current view
cc-pane pai                        # vertical split
cc-pane stringer -H                # horizontal split
```

> **Tip:** From inside an active Claude session, use `! cc-pane <project>` to open another project alongside without leaving Claude.

#### From PowerShell (Windows-side)

**Use PowerShell 7** (`pwsh.exe`) if at all possible — it's the modern, cross-platform PowerShell and what these helpers are designed for. Windows ships with PowerShell 5.1 (`powershell.exe`) which still works (we wire both profiles), but PS 7 is faster and is what you should default to. Install PS 7 with `winget install --id Microsoft.PowerShell` if you don't have it.

The dotfiles ship two PowerShell helper files:

| File | Scope | Functions |
|------|-------|-----------|
| `windows/wsl-helpers.ps1` | **Agent-neutral** — no Claude/Codex required | `wsl6` |
| `windows/cc-functions.ps1` | **Claude-specific** — wraps `cc <project>` inside WSL | `ccgrid`, `cctab`, `ccpane`, `ccprojects`, `ccupdate` |

`setup.sh` installs **both** files into **both PowerShell hosts** (5.1 and 7) automatically on WSL — they have different `$PROFILE` paths (`Documents\WindowsPowerShell\` vs `Documents\PowerShell\`), so wiring only one would leave the other broken. If you want only the agent-neutral piece on a machine that doesn't run Claude, you can copy just `wsl-helpers.ps1` and skip `cc-functions.ps1`.

| Command | File | What it does |
|---------|------|-------------|
| `wsl6` | wsl-helpers | New tab with a **3×2 grid of plain WSL shells** (no agent) |
| `ccgrid <p1> <p2> ...` | cc-functions | One new tab, each project in its own **split pane** (auto-tiled grid) |
| `ccpane <project> [-Horizontal]` | cc-functions | Split the current WT window with one project |
| `cctab <p1> <p2> ...` | cc-functions | One **tab** per project |
| `ccprojects` | cc-functions | List available projects (from WSL) |
| `ccupdate` | cc-functions | Refresh the local copy from the WSL source |

**Install — `setup.sh` does this for you on WSL.** Section 7b of `setup.sh` detects WSL, calls **both** `powershell.exe` (PS 5.1) and `pwsh.exe` (PS 7) when present, copies both helper files to `$env:USERPROFILE\.<name>.ps1`, and dot-sources each from each host's `$PROFILE` — idempotent, so re-running setup just refreshes the local copies. Open a new PowerShell window (5.1 or 7 — both work) and `wsl6` / `ccgrid` are ready.

> **Missed the prompt or installed before this split?** Just run `dotfiles-update` from WSL — it pulls the latest and re-runs setup. The PowerShell prompt fires again and both files are installed/refreshed in both PS profiles.

**Manual install** (if you skipped the setup.sh prompt or are on a machine that didn't run setup) — run these in PowerShell, replacing `<you>` with your WSL username:

```powershell
# 1. Allow local scripts (one time, per-user)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 2. Copy both helper files from the WSL dotfiles checkout to LOCAL Windows paths.
#    (RemoteSigned blocks scripts loaded directly from \\wsl.localhost\... with a
#    "not digitally signed" error, so dot-sourcing local copies is required.)
$base = '\\wsl.localhost\Ubuntu\home\<you>\dev\dotfiles\windows'
foreach ($f in @('wsl-helpers.ps1', 'cc-functions.ps1')) {
  Copy-Item "$base\$f" "$env:USERPROFILE\.$f" -Force
}

# 3. Wire both into your PowerShell profile
if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force }
foreach ($f in @('wsl-helpers.ps1', 'cc-functions.ps1')) {
  Add-Content $PROFILE ('. "' + "$env:USERPROFILE\.$f" + '"')
}

# 4. Reload
. $PROFILE
```

**Running from bash/WSL?** Bridge into PowerShell with this one-liner — it auto-resolves your WSL username and distro via env vars, so paste it verbatim. **`WSLENV` is required**: WSL→Windows interop does *not* propagate env vars to `powershell.exe` by default.

```bash
WSL_USER="$(whoami)" WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}" \
WSLENV="WSL_USER:WSL_DISTRO" \
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
  if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force | Out-Null }
  $base = "\\wsl.localhost\$env:WSL_DISTRO\home\$env:WSL_USER\dev\dotfiles\windows"
  foreach ($f in @("wsl-helpers.ps1", "cc-functions.ps1")) {
    Copy-Item "$base\$f" "$env:USERPROFILE\.$f" -Force
    $pattern = [regex]::Escape($f)
    if (-not (Select-String -Path $PROFILE -Pattern $pattern -Quiet)) {
      Add-Content $PROFILE (". `"$env:USERPROFILE\.$f`"")
    }
  }
'
```

Then open a new PowerShell window and `wsl6` / `ccgrid` / `cctab` / etc. will be defined.

After dotfiles updates, run `ccupdate` in PowerShell to refresh the local copy of `cc-functions.ps1` (then `. $PROFILE` to reload). For `wsl-helpers.ps1`, re-run `setup.sh` (or `dotfiles-update` from WSL).

Override the WSL distro or dev dir in your profile **before** the dot-source line if yours differ:

```powershell
$env:CC_WSL_DISTRO = 'Ubuntu-22.04'   # default: Ubuntu
$env:CC_DEV_DIR    = '~/code'         # default: ~/dev
. "$env:USERPROFILE\.cc-functions.ps1"
```

**Example — five repos in a split-pane grid, one command:**

```powershell
ccgrid dotfiles atlas stringer beacon pai
```

That opens a new Windows Terminal tab with five panes (alternating vertical/horizontal splits), each running `cc <project>` inside WSL.

---

## Skills (Slash Commands)

Type these directly in Claude Code.

| Command | When to use it |
|---------|---------------|
| `/kickoff` | Starting a new project — scaffolds structure, CLAUDE.md, changelog, git |
| `/changelog` | End of session — logs what happened to CHANGELOG.md |
| `/log-error` | Hit a wall — documents the error with classification and root cause |
| `/review` | Before shipping — reviews last 3 commits for bugs, security, quality |
| `/handoff` | Session transition — captures full state for the next session |
| `/fix-issue 123` | Pick up a GitHub issue end-to-end: investigate → plan → test → implement → PR |
| `/simplify` | After building — delegates to code-simplifier subagent, removes over-engineering |
| `/commit-push-pr` | Commit, push, and create PR in one shot |
| `/claude-server` | Spawn isolated worktree + remote control session |

---

## Agent Pack (16-Agent Review Orchestra)

A team of 16 specialized subagents, each running in **its own isolated context**. They investigate independently and report back without polluting each other's context or your main session.

| Agent | Focus |
|-------|-------|
| `product-strategist` | User flow, feature scope, stickiness |
| `ux-reviewer` | Layout, hierarchy, mobile, interactions |
| `frontend-architect` | Components, state management, rendering |
| `backend-architect` | Schema, APIs, queries, data integrity |
| `growth-strategist` | Sharing, SEO, viral loops, engagement |
| `content-reviewer` | Microcopy, tone, empty states, error messages |
| `trust-safety` | Abuse prevention, moderation, legal compliance |
| `qa-lead` | Edge cases, bad input, error states, mobile |
| `perf-accessibility` | Performance, WCAG, keyboard nav |
| `launch-operator` | Deploy readiness, monitoring, smoke tests |
| `security-reviewer` | Injection, auth, secrets, insecure data |
| `code-simplifier` | Over-engineering, dead code, premature abstractions |
| `repo-scout` | Fast codebase orientation and status briefing |
| `dependency-doctor` | Dep audits, CVEs, outdated packages, upgrade paths |
| `test-writer` | Bug reproduction, feature coverage, edge case tests |
| `schema-reviewer` | DB schema, migrations, data integrity, query patterns |

**How to invoke:**
- Single: "Use the qa-lead agent to review this feature"
- Multiple: "Run product-strategist, ux-reviewer, and growth-strategist on this project"
- Full review: "Run a full agent pack review" or "Run Phase 1 review"
- Via skill: `/simplify` and `/review` use agents automatically

**Orchestration** (see `AgentPack.md` for full details):
- **Phase 1 — Product:** product-strategist + ux-reviewer + growth-strategist + trust-safety (parallel)
- **Phase 2 — Architecture:** frontend-architect + backend-architect + content-reviewer + security-reviewer (parallel)
- **Phase 3 — Launch:** qa-lead + perf-accessibility + launch-operator + code-simplifier (parallel)

---

## Safety Hooks

Hooks run automatically — they can't be forgotten like CLAUDE.md rules.

**`conventional-commit.sh`** (PreToolUse) enforces:
- Commit messages must start with `type: description`
- Valid types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`
- Handles both heredoc and inline `-m` styles; skips `--amend`

**`format-on-edit.sh`** (PostToolUse) auto-formats after file edits:
- JS/TS/JSON/CSS → prettier (finds project root automatically)
- Python → black or ruff
- Rust → rustfmt
- Go → gofmt

**`ntfy-awaiting-input.sh`** (PreToolUse on AskUserQuestion) sends:
- Push notification via ntfy when Claude is waiting for user input

**`StripProjectPermissions.hook.ts`** (SessionStart) prevents:
- Project-level `settings.local.json` from accumulating `permissions` blocks that override global blanket permissions
- Reads the current project's settings.local.json, removes only the `permissions` key, preserves everything else

> **Note:** Security blocking (dangerous commands, secret detection) is handled by the PAI SecurityValidator hook in `~/.claude/hooks/SecurityValidator.hook.ts`, configured via `patterns.yaml`. The old `block-dangerous.sh` and `block-secrets.sh` hooks have been replaced.

---

## Status Line

The custom status line shows at-a-glance session health:

```
opus · [████████░░] 42% · main · +127 -34 · $0.82
```

- **Model name** (dimmed)
- **Context bar** — green (<50%), yellow (50-80%), red (>80%) with warning banner at 80%+
- **Git branch** (cached 5s, works on both macOS and Linux)
- **Worktree name** (when in a parallel session)
- **Lines added/removed** this session
- **Session cost** in USD

---

## The Core Workflow

```
1. DEFINE   → Tell Claude what you want. Be specific.
2. PLAN     → Shift+Tab twice for Plan Mode. Iterate until solid.
3. BUILD    → Normal Mode. Claude writes code and auto-commits.
4. VERIFY   → Tests run before committing. Failures get fixed.
5. SIMPLIFY → /simplify to remove unnecessary complexity.
6. REVIEW   → /review for quality/security check.
7. LOG      → /changelog to capture what happened.
8. HANDOFF  → /handoff if ending the session.
```

---

## Keyboard Shortcuts

| Shortcut | What it does |
|----------|-------------|
| `Shift+Tab` (x2) | Toggle Plan Mode |
| `Ctrl+G` | Open plan in text editor |
| `Ctrl+B` | Send current task to background |
| `Esc` | Stop Claude mid-response |
| `Esc+Esc` | Rewind menu |
| `/compact` | Compress conversation |
| `/clear` | Reset context |
| `/btw` | Side question (no context cost) |

---

## Session Management

```bash
cc                       # Pull all repos + start Claude (recommended)
cc dotfiles              # Start Claude in a specific project
claude                   # Start new session directly
claude --continue        # Resume most recent session
claude --resume          # Pick from recent sessions
claude -p "prompt"       # Non-interactive mode (for scripts/CI)
claude-server            # Spawn isolated worktree + remote control
cx                       # Pull all repos + start Codex
cx dotfiles              # Start Codex in a specific project
codex                    # Start Codex directly
codex resume             # Resume a Codex session
codex review --uncommitted

# Multi-session (WSL + Windows Terminal)
cc-pane pai              # Split pane with Claude in ~/dev/pai
cc-tab stringer          # New tab with Claude in ~/dev/stringer
cc-multi dotfiles pai    # Multiple tabs at once
sessions                 # See what's running
```

**Remote access** is always on. Connect from `claude.ai/code` or the Claude mobile app.

---

## The `claude-memory` private repo

This setup pairs the public dotfiles repo with a **separate private repo** called `claude-memory`, which holds three things that don't belong in a public repo:

1. Your **persistent Claude memory** (`dev/memory/`) — per-machine memory files Claude Code writes to `~/.claude/projects/`. Without this repo they only exist locally and vanish on machine rebuild.
2. Your **PAI config** (`pai-config/`, `pai-user/`) — the `CLAUDE.md`, `settings.json`, identity, steering rules, and DA personality that layer on top of the upstream [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) install. **Only needed in PAI mode.**
3. The `bootstrap.sh` script that links it all together and (re)installs the systemd voice server.

**Skip this section entirely if you run `setup.sh --no-pai`** — the non-PAI mode doesn't touch `claude-memory` at all. It's optional even for memory persistence; you'll just lose auto-memory between machines.

### Minimum structure (PAI mode)

```
~/dev/claude-memory/
├── bootstrap.sh                   # idempotent; runs at end of setup.sh
├── dev/
│   └── memory/                    # Claude auto-memory (symlinked into ~/.claude/projects/)
├── pai-config/
│   ├── CLAUDE.md                  # copied to ~/.claude/CLAUDE.md
│   └── settings.json              # copied to ~/.claude/settings.json
└── pai-user/
    ├── ABOUTME.md                 # who you are
    ├── AISTEERINGRULES.md         # overrides PAI system rules
    ├── DAIDENTITY.md              # your Digital Assistant's personality
    ├── PROJECTS/PROJECTS.md       # project catalog (optional)
    └── TELOS/                     # goals, frames, challenges (optional)
```

`setup.sh` copies (not symlinks) `pai-config/*` into `~/.claude/` and `pai-user/*.md` into `~/.claude/PAI/USER/`. `bootstrap.sh` is expected to:

- symlink `dev/memory` → `~/.claude/projects/-<dev-dir-encoded>/memory`
- symlink `pai-user/*` → `~/.claude/PAI/USER/*` (so edits in either place flow back)
- verify `~/.env` contains `ELEVENLABS_API_KEY`
- run `~/dev/dotfiles/claude/systemd/install.sh` to install the voice server

### Creating your own

This is a deliberately hand-crafted repo — there's no generator. Start minimal and add as you go:

```bash
# Create the skeleton
mkdir -p ~/dev/claude-memory/{pai-config,pai-user,dev/memory}
cd ~/dev/claude-memory

# Minimum files to pass setup.sh's PAI prereq checks
touch pai-config/CLAUDE.md pai-config/settings.json
touch pai-user/ABOUTME.md pai-user/AISTEERINGRULES.md pai-user/DAIDENTITY.md

# You'll need your own bootstrap.sh — see
# https://github.com/jckeen/dotfiles/blob/main/README.md for the contract above

# Publish it private
git init && git add -A && git commit -m "init: claude memory"
gh repo create claude-memory --private --source=. --push
```

Populate `pai-config/CLAUDE.md` with your personal Claude Code system instructions, `pai-user/AISTEERINGRULES.md` with user-level overrides (these take precedence over PAI's system rules), and `pai-user/ABOUTME.md` with whatever identity info you want Claude to always have.

**Or just use `--no-pai`** and skip the whole thing. The public dotfiles repo (`setup.sh --no-pai`) gives you: hooks, skills, agents, the `cc` alias scaffolding, the status line, git config, plugin auto-install, and credential wiring — no PAI runtime dependency.

`check-claude.sh` verifies the memory symlink is healthy alongside everything else.

---

## The `codex-memory` private repo

This public repo only tracks reusable Codex guidance, skills, and examples. Anything personal or generated belongs outside it.

Use an optional private repo at `~/dev/codex-memory` for portable Codex memory and private instructions. Keep this separate from `claude-memory`; the tools have different runtime state and different config formats.

Minimum structure:

```
~/dev/codex-memory/
├── AGENTS.local.md              # private Codex preferences
├── MEMORY.md                    # durable private notes
├── README.md
└── .gitignore
```

Never commit these from `~/.codex/`:

- `auth.json`
- `history.jsonl`
- `logs_*.sqlite*` or `state_*.sqlite*`
- `log/`, `sessions/`, `shell_snapshots/`, `cache/`, `.tmp/`, `tmp/`
- live `config.toml` project trust entries
- private MCP endpoints, token env values, account IDs, client names, or private project details

`setup.sh` links public `codex/AGENTS.md` and `codex/skills/*/SKILL.md` into `~/.codex/`. It also links `AGENTS.local.md` and `MEMORY.md` into `~/.codex/` when the private repo exists. It does not migrate live `~/.codex` state. `check-codex.sh` warns when private/generated Codex files exist so you remember they are local-only.

---

## Customizing

This repo is designed to be forked and adapted. Here's what to edit vs. leave alone:

**Edit these only with public-safe content:**
- `claude/AgentPack.md` — add, remove, or modify review agents
- `codex/AGENTS.md` — reusable Codex working rules
- `codex/skills/*/SKILL.md` — reusable Codex workflows
- `codex/config.toml.example` — example Codex config only
- `.bash_aliases` — your shell shortcuts

**Keep private:**
- `~/dev/claude-memory` — personal Claude/PAI memory, identity, and config
- `~/dev/claude-memory/pai-config/CLAUDE.md` — private Claude instructions and PAI steering
- `~/dev/claude-memory/pai-config/settings.json` — private Claude permissions and settings
- `~/dev/codex-memory` — personal Codex memory and private instructions
- live `~/.codex/config.toml` — machine-specific project trust and local settings

**Leave these (the framework):**
- `claude/hooks/*.sh` and `*.ts` — hooks (add new ones, but keep the defaults)
- `claude/skills/*/SKILL.md` — slash commands (add new ones as needed)
- `claude/agents/*.md` — subagent definitions
- `setup.sh` — cross-platform installer
- `claude/statusline.sh` — status line display

---

## Best Practices

<details>
<summary><strong>Click to expand the full best practices guide</strong></summary>

### Context Is Everything

Claude's context window is finite, and **performance degrades as it fills**.

- Run `/clear` between unrelated tasks
- Use subagents for investigation — they report back summaries, not raw files
- Watch the context % in your status line — `/handoff` → fresh session when it's high

### Plan First, Then Execute

Most sessions should start in **Plan Mode** (Shift+Tab twice). Iterate until solid, then execute. Often 1-shots the whole thing.

### Always Give Claude a Way to Verify

Provide tests, screenshots, or expected outputs. **The pattern:** failing test first → implement fix → verify test passes.

### Prompt Like a Senior Engineer

- Be specific: "add email/password login using NextAuth with Postgres" not "add auth"
- Point to patterns: "Follow the same pattern as HotDogWidget.php"
- Power prompts: "Grill me on these changes", "Scrap this and implement the elegant solution"

### CLAUDE.md Compounds Over Time

Keep it under 400 lines. When Claude makes a mistake, have it update CLAUDE.md to prevent recurrence.

### Hooks > CLAUDE.md for Enforcement

CLAUDE.md is advisory. Hooks are enforced. Convert frequently-violated rules into hooks.

</details>

---

## Repo Structure

```
dotfiles/
├── setup.sh                    # Cross-platform bootstrap script
├── check-claude.sh             # Health check — verifies symlinks, memory, detects orphans
├── .bash_aliases               # Shell aliases, functions, worktree shortcuts
├── .gitconfig                  # Base git config (includes .gitconfig.local)
├── .gitignore                  # Ignores generated files
├── .gitattributes              # Line ending normalization (LF for scripts)
├── .asoundrc                   # WSL audio routing
├── LICENSE                     # MIT
├── README.md                   # This file
├── CLAUDE-GUIDE.md             # Quick reference cheat sheet
├── CHANGELOG.md                # Change log
├── codex/
│   ├── AGENTS.md               # Public-safe Codex global guidance
│   ├── config.toml.example     # Public-safe Codex config example
│   └── skills/                 # Public-safe Codex workflows
│       ├── review/
│       ├── simplify/
│       ├── fix-issue/
│       ├── commit-push-pr/
│       ├── handoff/
│       ├── changelog/
│       └── repo-health/
└── claude/
    ├── AgentPack.md            # 16-agent review orchestra
    ├── statusline.sh           # Context bar, git branch, cost display
    ├── hooks/
    │   ├── conventional-commit.sh          # PreToolUse commit message validator
    │   ├── format-on-edit.sh               # PostToolUse auto-formatter
    │   ├── ntfy-awaiting-input.sh          # PreToolUse push notification
    │   └── StripProjectPermissions.hook.ts # SessionStart permission guard
    ├── skills/
    │   ├── kickoff/            # /kickoff — new project bootstrap
    │   ├── changelog/          # /changelog — session logging
    │   ├── log-error/          # /log-error — error documentation
    │   ├── review/             # /review — code quality check
    │   ├── handoff/            # /handoff — session transitions
    │   ├── fix-issue/          # /fix-issue — GitHub issue workflow
    │   ├── simplify/           # /simplify — complexity removal
    │   ├── commit-push-pr/     # /commit-push-pr — one-shot shipping
    │   ├── claude-server/      # /claude-server — remote worktree
    │   ├── decompose/          # /decompose — deep task decomposition
    │   └── max/                # /max — maximum effort parallel execution
    ├── handoffs/               # Session handoff notes (gitignored — ephemeral)
    ├── scripts/                # Headless automation scripts
    │   ├── common.sh           # Shared safety tiers + runner
    │   ├── health-check.sh     # Read-only repo health audit
    │   ├── full-review.sh      # 3-phase agent pack review
    │   ├── test-coverage.sh    # Write tests for uncovered code
    │   ├── fix-issues.sh       # Auto-pick and fix GitHub issues
    │   ├── overnight.sh        # Orchestrate all scripts across repos
    │   └── review-and-push.sh  # Morning review of overnight changes
    └── agents/                 # 16 specialized review subagents
        ├── product-strategist.md
        ├── ux-reviewer.md
        ├── frontend-architect.md
        ├── backend-architect.md
        ├── growth-strategist.md
        ├── content-reviewer.md
        ├── trust-safety.md
        ├── qa-lead.md
        ├── perf-accessibility.md
        ├── launch-operator.md
        ├── security-reviewer.md
        ├── code-simplifier.md
        ├── repo-scout.md
        ├── dependency-doctor.md
        ├── test-writer.md
        └── schema-reviewer.md
└── windows/
    ├── wsl-helpers.ps1         # Agent-neutral PowerShell helpers (wsl6 — 3×2 WSL grid)
    └── cc-functions.ps1        # Claude-specific launchers (ccgrid/cctab/ccpane/ccprojects/ccupdate)
```

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference

Want to understand the reasoning behind these choices? Read the [CHANGELOG](CHANGELOG.md).
