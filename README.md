# Dotfiles — Claude Code + Codex Power Setup

Production-ready Claude Code setup with 4 hooks, 11 slash commands, a 16-agent review orchestra, a custom status line, and a parallel public-safe Codex setup. Clone it, run `setup.sh`, and skip the config trial-and-error.

Works on **macOS**, **WSL (Ubuntu)**, and **native Linux**.

Best practices sourced from [Boris Cherny](https://howborisusesclaudecode.com) (creator of Claude Code), the [official Claude Code docs](https://code.claude.com/docs/en/best-practices), and hard-won experience.

---

## Quick Start

```bash
# Clone this repo
cd ~/dev  # or wherever you keep code
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# Run setup (auto-detects macOS, WSL, or Linux)
chmod +x setup.sh
./setup.sh            # prompts: are you using PAI? [Y/n]
# Or skip the prompt:
# ./setup.sh --no-pai   # Claude Code + hooks only, no PAI
# ./setup.sh --pai      # assume PAI (requires claude-memory repo + ~/.claude/PAI)

# Authenticate
gh auth login          # GitHub CLI (choose HTTPS + browser)
claude                 # Follow the login prompt
codex login            # Optional: sign in for Codex CLI
```

The setup script auto-detects your platform, installs tools, prompts for git identity, symlinks Claude config into `~/.claude/`, and links only public-safe Codex guidance and skills into `~/.codex/`.

> **Public repo safety:** this dotfiles repo is public. Do not commit Codex or Claude auth tokens, generated sessions, sqlite state, logs, caches, private memory, account IDs, private MCP endpoints, personal identity notes, or private client/project context. Use `claude-memory` and `codex-memory` for private portable state.

**PAI mode** (default) wires in [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure) — install PAI first (`danielmiessler/Personal_AI_Infrastructure/Releases/v4.0.3` → `bash ~/.claude/install.sh`) and clone your private `claude-memory` repo under `~/dev/` before running `setup.sh`. **Non-PAI mode** (`--no-pai`) skips the claude-memory integration and leaves you with the Claude Code hooks, skills, agents, and dotfiles.

> **WSL users:** Always clone repos under `~/dev` (Linux filesystem), **not** `/mnt/c/` (Windows mount). File I/O on the native Linux filesystem is ~10x faster. The setup script auto-configures your shell to `cd ~/dev` on startup.

### Try it now

After setup, try these to see what you've got:

```bash
cc                    # pulls all your repos, then launches Claude
cx                    # pulls all your repos, then launches Codex
```

Once inside Claude:
- Type `/review` to run a code quality check on your last few commits
- Ask "Run the qa-lead agent on this project" to spawn an isolated review
- Watch the status line — it shows context %, git branch, cost, and lines changed

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

If you launch Claude from PowerShell rather than from inside WSL, dot-source `windows/cc-functions.ps1` from your PowerShell profile to get equivalent commands. Each pane/tab shells into WSL and runs `cc <project>`, so repo sync + health check still happen.

| Command | What it does |
|---------|-------------|
| `ccgrid <p1> <p2> ...` | One new tab, each project in its own **split pane** (auto-tiled grid) |
| `ccpane <project> [-Horizontal]` | Split the current WT window with one project |
| `cctab <p1> <p2> ...` | One **tab** per project |
| `wsl6` | New tab with a **3×2 grid of plain WSL shells** (3 up, 3 down) |
| `ccprojects` | List available projects (from WSL) |
| `ccupdate` | Refresh the local copy from the WSL source |

**Install — `setup.sh` does this for you on WSL.** Section 7b of `setup.sh` detects WSL, calls `powershell.exe`, copies `cc-functions.ps1` to `$env:USERPROFILE\.cc-functions.ps1`, and dot-sources it from your `$PROFILE` — idempotent, so re-running setup just refreshes the local copy. Open a new PowerShell window after setup and `wsl6` / `ccgrid` are ready.

**Manual install** (if you skipped the setup.sh prompt or are on a machine that didn't run setup) — run these in PowerShell, replacing `<you>` with your WSL username:

```powershell
# 1. Allow local scripts (one time, per-user)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 2. Copy cc-functions.ps1 from the WSL dotfiles checkout to a LOCAL Windows path.
#    (RemoteSigned blocks scripts loaded directly from \\wsl.localhost\... with a
#    "not digitally signed" error, so dot-sourcing a local copy is required.)
$src  = '\\wsl.localhost\Ubuntu\home\<you>\dev\dotfiles\windows\cc-functions.ps1'
$dest = "$env:USERPROFILE\.cc-functions.ps1"
Copy-Item $src $dest -Force

# 3. Wire it into your PowerShell profile
if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force }
Add-Content $PROFILE ('. "' + $dest + '"')

# 4. Reload
. $PROFILE
```

**Running from bash/WSL?** Bridge into PowerShell with this one-liner — it auto-resolves your WSL username and distro via env vars, so paste it verbatim. **`WSLENV` is required**: WSL→Windows interop does *not* propagate env vars to `powershell.exe` by default.

```bash
WSL_USER="$(whoami)" WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}" \
WSLENV="WSL_USER:WSL_DISTRO" \
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
  $src  = "\\wsl.localhost\$env:WSL_DISTRO\home\$env:WSL_USER\dev\dotfiles\windows\cc-functions.ps1"
  $dest = "$env:USERPROFILE\.cc-functions.ps1"
  Copy-Item $src $dest -Force
  if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force | Out-Null }
  if (-not (Select-String -Path $PROFILE -Pattern "\.cc-functions\.ps1" -Quiet)) {
    Add-Content $PROFILE (". `"$dest`"")
  }
'
```

Then open a new PowerShell window and `ccgrid` / `cctab` / etc. will be defined.

After dotfiles updates, run `ccupdate` in PowerShell to refresh the local copy (then `. $PROFILE` to reload).

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
    └── cc-functions.ps1        # PowerShell equivalents of cc-pane/cc-tab/cc-multi (plus ccgrid)
```

---

## ADRs

Architecture Decision Records that apply across jckeen-owned repos live in [`ADR/`](ADR/).

| ADR | Status | Summary |
| --- | ------ | ------- |
| [Auth at the Boundary](ADR/AUTH-AT-THE-BOUNDARY.md) | Accepted (2026-05-03) | Every entry point rejects unauthenticated requests at the boundary. Auth-by-default, not auth-by-config. Optional or "off when unconfigured" auth modes are forbidden. |

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference

Want to understand the reasoning behind these choices? Read the [CHANGELOG](CHANGELOG.md).
