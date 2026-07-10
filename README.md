# Dotfiles — A Jumpstart for Claude Code + Codex

[![Docs site](https://img.shields.io/badge/docs-jckeen.github.io%2Fdotfiles-blue)](https://jckeen.github.io/dotfiles/)

**📖 Browsable docs:** everything in this repo is also published as a searchable site at **[jckeen.github.io/dotfiles](https://jckeen.github.io/dotfiles/)** — rebuilt on every push to `main`.

A one-command setup that gets you from a blank machine to a full Claude Code + Codex working environment with sane defaults, safety hooks, multi-session tooling, and a 17-agent code-review orchestra. Built for **macOS** and **Windows (via WSL2 + Ubuntu)**, with Linux supported as a side effect.

This is opinionated — it's how *I* (and now hopefully you) run Claude Code and Codex day-to-day. Clone it, run `./setup.sh`, and skip months of trial-and-error.

**Get started:**
```bash
git clone https://github.com/jckeen/dotfiles.git && cd dotfiles && ./setup.sh
```

Best practices sourced from [Boris Cherny](https://howborisusesclaudecode.com) (creator of Claude Code), the [official Claude Code docs](https://code.claude.com/docs/en/best-practices), and hard-won experience across thousands of agent sessions.

---

## What you get (and why it matters)

After setup, you don't have to remember much. Open a terminal and:

- **`cc`** — one alias that pulls every repo in your `~/dev/` directory (fast-forward only), syncs your memory repo, runs a health check, then launches Claude Code. **`cx`** does the same for Codex. No more "is my repo up to date?" or "did I forget to pull?" — that's automatic now.
- **A live status line** — model name, context-bar (green/yellow/red), git branch, lines added/removed, session cost in USD. You always know how warm your context is, what branch you're on, and what the session has cost — without asking.
- **17 slash commands** that cover the whole loop — `/kickoff` (new project), `/review` (quality + security), `/simplify` (de-engineer), `/fix-issue` (GitHub issue end-to-end), `/handoff` (clean session transition), `/changelog`, `/log-error`, `/commit-push-pr`, `/claude-server`, `/decompose`, `/orchestrate` (full-lifecycle max-effort mode), `/branch-hygiene`, `/jj` (jujutsu driver), `/session-retro` (improve your own skills), `/drift-sweep` (doc-contract bootstrap + drift audit), `/fable-mode` (recalibrate to the conduct layer), `/antigravity-review` (Gemini second-opinion review gate). Type the verb, get the workflow.
- **A 17-agent review orchestra** — `qa-lead`, `security-reviewer`, `frontend-architect`, `backend-architect`, `ux-reviewer`, `growth-strategist`, `trust-safety`, `perf-accessibility`, and 9 more. Each runs in its own isolated context and reports back without polluting your main session. Three-phase orchestration (Product → Architecture → Launch) for serious reviews.
- **Safety hooks that can't be forgotten** — auto-format on edit (prettier, black, rustfmt, gofmt), conventional-commit enforcement, push notifications when Claude is waiting on you, and a `StripProjectPermissions` hook that prevents per-project permission creep from overriding your global allowlist.
- **Multi-session tooling** — open 3, 5, or 8 Claude sessions across different projects in a single Windows Terminal window via `cc-pane`/`cc-tab`/`cc-multi` (bash) or `ccgrid`/`cctab`/`ccpane` (PowerShell). Each session gets the full `cc` treatment — repo sync, tab colors, health check.
- **Agent-neutral helpers** — `wsl6` opens a 3×2 grid of plain WSL shells (no Claude/Codex coupling) for ad-hoc multi-shell work.
- **Auto-hygiene** — a daily systemd timer cleans stale branches across every repo in `~/dev/`, surfaces drift at every Claude/Codex session start, and bootstraps the canonical 8 GitHub auto-merge settings on every newly-created or cloned repo.
- **Public-safe Codex parity** — the public-safe skill subset (review, simplify, fix-issue, commit-push-pr, handoff, changelog, branch-hygiene) is wired so `cx` mirrors `cc` on those shared workflows, plus a Codex-only `repo-health` skill (its Claude-side analogue is the `repo-scout` agent, not a skill). The same skill set is dir-symlinked into Antigravity's global config (`~/.gemini/config/skills/`), so `agy` shares the workflow too. Codex auth, sessions, sqlite state, and live `config.toml` stay local; only public-safe guidance and skills are shared.
- **Cross-platform symlink hygiene** — `setup.sh` is idempotent and runs the same on macOS and WSL. Edit `~/.claude/agents/foo.md` and the change is in your repo automatically (it's a symlink). `dotfiles-update` keeps everything in sync with one command.

> **Why this exists:** Claude Code and Codex are powerful but the defaults aren't tuned for serious daily work — context bloats, sessions vanish without handoffs, branches pile up, agent reviews are ad-hoc, and you re-discover the same gotchas every project. This repo encodes the "second-day knowledge" that makes the tools actually compound. If you're going to spend hundreds of hours in these CLIs, spend the first 10 minutes setting up properly.

---

## Quick Start

Pick your platform. Each path leaves you with the same end state: Claude Code + Codex installed, hooks wired, slash commands available, status line showing, multi-session helpers ready.

<details>
<summary><strong>🪟 Windows (WSL2 — recommended)</strong></summary>

<br>

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

</details>

<details>
<summary><strong>🍎 macOS</strong></summary>

<br>

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

</details>

<details>
<summary><strong>🐧 Linux (native, not WSL)</strong></summary>

<br>

```bash
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles
./setup.sh
gh auth login
claude
codex login            # Optional
```

> **Node.js first:** unlike macOS, `setup.sh` does not auto-install Node on
> Linux — if `node` is missing it prints install options and exits. Install it
> before running setup, e.g.
> `curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs`.

</details>

### Setup-script flags (all platforms)

```bash
./setup.sh             # default: install everything, prompting only where it matters
./setup.sh --check     # read-only audit of all symlinks; exits non-zero if broken
./setup.sh --repair    # audit + recreate any broken/missing symlinks
./setup.sh --dry-run   # show what would change without writing anything
./setup.sh --help      # usage and flag reference
```

> **Public repo safety:** this dotfiles repo is public. Don't commit Codex/Claude auth tokens, generated sessions, sqlite state, logs, caches, private memory, account IDs, private MCP endpoints, personal identity notes, or client/project details. Private state lives in `claude-memory` and `codex-memory` (separate private repos — see below). CI runs a **gitleaks** `secret-scan` job (token/key/credential shapes, full-history) and a `no-personal-data` leak check (machine-specific home paths) on every PR; branch protection requires the `shellcheck`, `tsc`, and `doc-truth` checks to pass before merge (see [docs/BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md)).

> **Private memory (optional):** if you keep a private `claude-memory` repo under `~/dev/`, `setup.sh` calls its `bootstrap.sh` to symlink your Claude Code `settings.json` (MCP servers, permissions, plugins) into `~/.claude/`. Without it you still get hooks, skills, agents, status line, and dotfiles — the global `claude/CLAUDE.md` is symlinked either way.

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

These are auto-installed by `setup.sh` on WSL (it asks "Install into your PowerShell profile(s)? [Y/n]" — answer Y). The installer wires both PS 5.1 and PS 7 profiles, so the helpers work in whichever you prefer. **If you missed the prompt or installed before this fix, just run `dotfiles-update` from WSL.** Manual install, distro/dev-dir overrides, and more: [docs/WINDOWS.md](docs/WINDOWS.md).

---

## What this installs and configures

`setup.sh` installs CLI tools, symlinks Claude/Codex config into `~/.claude/` and `~/.codex/`, and wires platform-specific bits (audio on WSL, credential helpers per OS, etc.). Expand below for the full inventory.

<details>
<summary><strong>📦 Tools installed</strong> (gh, git, node, jq, claude, codex, bun)</summary>

<br>

| Tool | Purpose | Install method |
|------|---------|---------------|
| `gh` | GitHub CLI | Homebrew (macOS) / apt (Linux) |
| `git` | Version control | Homebrew / apt |
| `node` | Node.js LTS | Homebrew / NodeSource |
| `jq` | JSON processing (used by hooks) | Homebrew / apt |
| `claude` | Claude Code CLI | npm |
| `codex` | OpenAI Codex CLI | npm |
| `bun` | Runtime for `*.hook.ts` hooks | Pinned GitHub release (`BUN_VERSION` in `setup.sh`), SHA-256-verified against the release's `SHASUMS256.txt` |

WSL also gets: `pulseaudio-utils`, `libasound2-plugins`, `alsa-utils` (for audio routing).

</details>

<details>
<summary><strong>⚙️ Files & symlinks configured</strong> (CLAUDE.md, hooks, skills, agents, aliases…)</summary>

<br>

Public Claude config pieces are **symlinked** from this repo to `~/.claude/`, so edits in either location stay in sync. The global instructions live in this repo and are symlinked into `~/.claude/`; private settings (MCP servers, permissions, plugins) come from `claude-memory`. Codex is stricter: only public-safe guidance and skills are symlinked into `~/.codex/`; live `~/.codex/config.toml` stays local because Codex stores machine-specific project trust there.

| What | Files | Purpose |
|------|-------|----------|
| **Claude instructions** | `claude/CLAUDE.md` | Global rules Claude follows in every session (symlinked into `~/.claude/CLAUDE.md`) |
| **Settings** | `~/dev/claude-memory/settings.json` | Private permissions, MCP servers, plugins (symlinked into `~/.claude/` by claude-memory's `bootstrap.sh`) |
| **Agent Pack** | `AgentPack.md` | 17-agent review orchestra (loaded on-demand, not symlinked) |
| **Status line** | `statusline.sh` | Shows model, context %, git branch, lines changed, session cost |
| **Commit hook** | `hooks/conventional-commit.sh` | Enforces `type: description` commit message format |
| **Format hook** | `hooks/format-on-edit.sh` | Auto-formats files after edits (prettier, black, rustfmt, gofmt) |
| **Notification hook** | `hooks/ntfy-awaiting-input.sh` | Sends push notification when Claude needs input |
| **Permission guard** | `hooks/StripProjectPermissions.hook.ts` | Strips project-level permission overrides on SessionStart |
| **Other hooks** | `hooks/*` | Worktree guard, symlink repair, plugin/hygiene drift, stale-SHA warning, handoff reminder, pre-merge Codex harvest — full wired-state table in [CLAUDE-GUIDE → Hooks](CLAUDE-GUIDE.md#hooks) |
| **Plugin manifest** | `claude/plugins.txt` | Read by `setup.sh` (§3b) and `sync-plugins.sh` to auto-install plugins (`plugin@marketplace`, one per line); deliberately not symlinked (listed in `claude/nolink.txt`) |
| **Skills** | `skills/*/SKILL.md` | Claude slash commands (see below) |
| **Subagents** | `agents/*.md` | 17 specialized review agents |
| **Shell aliases** | `.bash_aliases` | `cc`, `pull-all`, worktree shortcuts |
| **Codex guidance** | `codex/AGENTS.md` | Public-safe global Codex working rules |
| **Shared agent skills** | `agents/skills/*/SKILL.md` | Agent-neutral workflows (review, issue fixes, PRs, handoffs), per-file-linked into `~/.codex/skills/` |
| **Codex config example** | `codex/config.toml.example` | Template only; live `~/.codex/config.toml` stays local |
| **Antigravity guidance** | `antigravity/GEMINI.md` | Public-safe global Antigravity (agy) rules (symlinked into `~/.gemini/config/GEMINI.md`) |
| **Antigravity skills** | `agents/skills/*/` (shared) | The same agent-neutral workflow set, dir-symlinked into `~/.gemini/config/skills/` |
| **Git config** | `.gitconfig` + `.gitconfig.local` | Identity, editor, credential helper (per-platform) |
| **Audio** | `.asoundrc` (WSL only) | ALSA → PulseAudio routing |

</details>

<details>
<summary><strong>🖥️ Platform-specific behavior</strong> (what differs across macOS / WSL / Linux)</summary>

<br>

| Feature | macOS | WSL | Linux |
|---------|-------|-----|-------|
| Package manager | Homebrew | apt | apt |
| Shell config | `.zshrc` | `.bashrc` | `.bashrc` |
| Credential helper | osxkeychain | Git Credential Manager (Windows) | git-credential-store |
| Audio | Built-in | ALSA → PulseAudio | N/A |
| Git safe.directory | Not needed | Auto-configured for `/mnt/c/` | Not needed |

</details>

---

## Daily use

The day-to-day reference is **[CLAUDE-GUIDE.md](CLAUDE-GUIDE.md)** — the cheat
sheet for slash commands, hooks (with their wired-state), keyboard shortcuts,
shell commands, worktree/multi-session helpers, autonomous scripts, stop-hook
templates, and the golden rules. What follows is the short version.

### The commands you'll actually type

| Command | What it does |
|---------|-------------|
| `cc [project]` | Sync repos + memory, health check, heal plugin drift, launch Claude |
| `cx [project]` | Same ergonomics for Codex |
| `cc-multi <p1> <p2> …` | Multiple projects, one Windows Terminal tab each, fully synced |
| `dotfiles-update` | Pull latest dotfiles + re-run setup (idempotent — safe anytime) |
| `/handoff` | Capture session state before `/clear` or stopping |
| `/orchestrate` | Full-lifecycle max-effort mode — worktrees, parallel agents |
| `/fix-issue N` | GitHub issue end-to-end: investigate → test → fix → PR |

Most other slash commands **auto-invoke** when their triggers match — you
rarely type them. Full table: [CLAUDE-GUIDE](CLAUDE-GUIDE.md#slash-commands).

### The loop

```
Plan → Build → Verify → Simplify → Review → Log → Handoff
```

Each step is a mode or slash command — see
[CLAUDE-GUIDE → The Workflow](CLAUDE-GUIDE.md#the-workflow), including the
push-time Codex review gate that blocks on critical findings.

### Going wider

- **Worktrees & multi-session** — `za`–`ze`/`z0` jump between worktrees,
  `wt-claude <name>` spawns Claude in a fresh one, `cc-pane`/`cc-tab`/`cc-multi`
  fan out across Windows Terminal (from inside Claude: `! cc-pane <project>`).
  Tables in [CLAUDE-GUIDE](CLAUDE-GUIDE.md#worktrees--multi-session); the
  PowerShell side (`wsl6`, `ccgrid`, `cctab`, `ccpane`, manual install, distro
  overrides) lives in [docs/WINDOWS.md](docs/WINDOWS.md).
- **The 17-agent review orchestra** — spawn by name ("Use the qa-lead agent on
  this feature"), in groups, or as a three-phase full review (Product →
  Architecture → Launch). `/review` and `/simplify` use them automatically.
  Roster and orchestration: [`claude/AgentPack.md`](claude/AgentPack.md).
- **Safety hooks** — run automatically, can't be forgotten like CLAUDE.md
  rules: conventional-commit enforcement, project-gated format-on-edit,
  session-start symlink repair, permission-creep stripping, plugin drift
  detection. The canonical wired-state table is in
  [CLAUDE-GUIDE → Hooks](CLAUDE-GUIDE.md#hooks); files in
  [`claude/hooks/`](claude/hooks/).
- **Status line** — model, context bar (green/yellow/red), branch, lines
  changed, session cost. If the bar runs red: `/handoff`, then `/clear`.

---

## The private memory repos

This public dotfiles repo pairs with up to three **separate private repos** — `claude-memory`, plus optional `codex-memory` and `agy-memory` — that hold things that don't belong in public: Claude Code settings, auto-memory, archived personal context, and Codex/Antigravity preferences. All are optional; without them you still get hooks, skills, agents, status line, git config, and `cc`/`cx` scaffolding.

<details>
<summary><strong>📁 The <code>claude-memory</code> private repo</strong> — structure, contract, how to create your own</summary>

<br>

`claude-memory` holds:

1. Your **Claude Code settings** (`settings.json`) — private permissions, MCP servers, and enabled plugins.
2. Your **persistent Claude memory** (`dev/memory/`) — auto-memory files (`MEMORY.md` + `feedback_*.md`) Claude Code writes to `~/.claude/projects/`. Without this repo they only exist locally and vanish on machine rebuild.
3. **Archived personal context** (`identity/`) — identity and steering notes kept for reference. These are no longer live-linked into Claude; they're retained as an archive.
4. **Project notes** (`stringer/`, `trnn/`) — durable per-project context.
5. Your **personal identity & preferences** (`CLAUDE.md`) — imported by the public `claude/CLAUDE.md` via `@~/dev/claude-memory/CLAUDE.md`, so identity loads globally while staying out of the public repo.
6. The `bootstrap.sh` script that symlinks `settings.json` into `~/.claude/`.

**Minimum structure:**

```
~/dev/claude-memory/
├── bootstrap.sh                   # idempotent; runs at end of setup.sh — links settings.json
├── settings.json                  # symlinked into ~/.claude/settings.json
├── CLAUDE.md                      # personal identity, imported by public claude/CLAUDE.md
├── dev/
│   └── memory/                    # Claude auto-memory (MEMORY.md + feedback_*.md)
├── identity/                      # ARCHIVED personal identity/steering notes (not live-linked)
├── stringer/                      # project notes
└── trnn/                          # project notes
```

`bootstrap.sh` symlinks `settings.json` into `~/.claude/` (no voice server, no `.env` checks). `setup.sh` calls it automatically when the repo is present.

**Creating your own** — deliberately hand-crafted, no generator:

```bash
# Create the skeleton
mkdir -p ~/dev/claude-memory/dev/memory
cd ~/dev/claude-memory

# Your Claude Code settings (permissions, MCP servers, plugins)
touch settings.json

# A minimal bootstrap.sh that symlinks settings.json into ~/.claude/
# (idempotent; re-run safe)

# Publish it private
git init && git add -A && git commit -m "init: claude memory"
gh repo create claude-memory --private --source=. --push
```

`check-claude.sh` verifies the memory symlink is healthy alongside everything else.

</details>

<details>
<summary><strong>📁 The <code>codex-memory</code> private repo</strong> — structure, what never to commit</summary>

<br>

This public dotfiles repo only tracks reusable Codex guidance, skills, and examples. Anything personal or generated belongs in an optional private repo at `~/dev/codex-memory` for portable Codex memory and private instructions. Keep this separate from `claude-memory`; the tools have different runtime state and different config formats.

**Minimum structure:**

```
~/dev/codex-memory/
├── AGENTS.local.md              # private Codex preferences
├── MEMORY.md                    # durable private notes
├── README.md
└── .gitignore
```

**Never commit these from `~/.codex/`:**

- `auth.json`
- `history.jsonl`
- `logs_*.sqlite*` or `state_*.sqlite*`
- `log/`, `sessions/`, `shell_snapshots/`, `cache/`, `.tmp/`, `tmp/`
- live `config.toml` project trust entries
- private MCP endpoints, token env values, account IDs, client names, or private project details

`setup.sh` links public `codex/AGENTS.md` and the shared `agents/skills/*/SKILL.md` into `~/.codex/`. It also links `AGENTS.local.md` and `MEMORY.md` into `~/.codex/` when the private repo exists. It does not migrate live `~/.codex` state. `check-codex.sh` warns when private/generated Codex files exist so you remember they are local-only.

</details>

<details>
<summary><strong>📁 The <code>agy-memory</code> private repo</strong> — structure, what never to commit</summary>

<br>

Same pattern for Antigravity (`agy`): the public repo tracks only `antigravity/GEMINI.md` (global rules); anything personal belongs in an optional private repo at `~/dev/agy-memory`.

**Minimum structure:**

```
~/dev/agy-memory/
├── GEMINI.local.md              # private Antigravity preferences
├── MEMORY.md                    # durable private notes
├── README.md
└── .gitignore
```

**Never commit these from `~/.gemini/antigravity-cli/`:**

- `antigravity-oauth-token`
- `conversations/`, `conversation_summaries.db*`, `history.jsonl`
- `brain/`, `knowledge/`, `implicit/`, `scratch/`, `log/`, `cache/`, `crashes/`

`setup.sh` links public `antigravity/GEMINI.md` into `~/.gemini/config/GEMINI.md`, dir-symlinks the shared workflow skills (`agents/skills/*`, the agent-neutral set) plus the Antigravity-only skills (`antigravity/skills/*`, e.g. `browser-verify`) into `~/.gemini/config/skills/`, links `antigravity/hooks.json` (session-start handoff injection), seeds a local `mcp_config.json` from `antigravity/mcp_config.json.example` (Playwright + GitHub MCP; the GitHub token resolves at launch via `gh auth token`, never stored), and links `GEMINI.local.md` and `MEMORY.md` from the private repo when it exists. `check-antigravity.sh` verifies all of it and warns about local-only runtime state.

</details>

---

## Customizing (forking this repo)

<details>
<summary><strong>What to edit, keep private, and leave alone</strong></summary>

<br>

This repo is designed to be forked and adapted. Here's what to edit vs. leave alone:

**Edit these only with public-safe content:**
- `claude/AgentPack.md` — add, remove, or modify review agents
- `codex/AGENTS.md` — reusable Codex working rules
- `agents/skills/*/SKILL.md` — reusable agent-neutral workflows (Codex + Antigravity)
- `codex/config.toml.example` — example Codex config only
- `antigravity/GEMINI.md` — reusable Antigravity working rules
- `.bash_aliases` — your shell shortcuts

**Keep private:**
- `~/dev/claude-memory` — personal Claude memory, settings, and archived context
- `~/dev/claude-memory/settings.json` — private Claude permissions, MCP servers, and plugins
- `~/dev/codex-memory` — personal Codex memory and private instructions
- live `~/.codex/config.toml` — machine-specific project trust and local settings

**Leave these (the framework):**
- `claude/hooks/*.sh` and `*.ts` — hooks (add new ones, but keep the defaults)
- `claude/skills/*/SKILL.md` — slash commands (add new ones as needed)
- `claude/agents/*.md` — subagent definitions
- `setup.sh` — cross-platform installer
- `claude/statusline.sh` — status line display

</details>

---

## Architecture decisions

The *why* behind structural changes lives in [`docs/adr/`](docs/adr/) as
Architecture Decision Records, and the current backlog lives in
[`ROADMAP.md`](ROADMAP.md) + GitHub Issues. This repo uses a four-layer record
model — Issues track what's next, CI-gated PRs are the unit of change, ADRs
capture the reasoning, and the [CHANGELOG](CHANGELOG.md) records what shipped.
ADRs are numbered `NNNN-kebab-title.md` and append-only: a decision that no
longer holds is superseded by a new record rather than edited away. Start with
[ADR-0001](docs/adr/0001-record-architecture-decisions.md), or copy
[`0000-template.md`](docs/adr/0000-template.md) to write a new one.

---

## Repo Structure

Deliberately coarse — visible top-level entries only, with one-line purposes,
so a rename inside a directory can't silently rot this diagram. Hidden root
files are omitted as policy, not oversight: `.github/` holds the CI gates,
`.doc-contract` declares the doc tiers (ADR 0005), and the rest are shell,
git, and audio config wired by `setup.sh`. Run `ls -A` (or browse the
[docs site](https://jckeen.github.io/dotfiles/)) for the real inventory.

```
dotfiles/
├── setup.sh                # Cross-platform bootstrap — installs tools, wires every symlink
├── check-claude.sh         # Health checks (also check-codex.sh, check-antigravity.sh)
├── git-hygiene.sh          # Repo/branch hygiene (also gh-bootstrap.sh, hygiene-status.sh, lib-symlinks.sh)
├── README.md               # This file (also CLAUDE-GUIDE.md, CHANGELOG.md, ROADMAP.md, LICENSE)
├── mkdocs.yml              # Docs-site config for the published Pages site
├── docs/                   # ADRs, Windows deep-dive, branch-protection notes
├── claude/                 # Claude Code layer — CLAUDE.md, hooks, skills, agents, scripts, statusline
├── codex/                  # Public-safe Codex layer — AGENTS.md, config example, Codex-only skills
├── antigravity/            # Public-safe Antigravity (agy) layer — GEMINI.md, hooks, agy-only skills
├── agents/                 # Agent-neutral shared skills, consumed by Codex + Antigravity
└── windows/                # PowerShell helpers — wsl6, ccgrid/cctab/ccpane
```

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference
- [Autonomy Kit](https://skills.amditis.tech/autonomy) by Joe Amditis (MIT) — the quality-bar / coach-pass / effort-matched-review discipline distilled into our review + orchestrate skills

Want to understand the reasoning behind these choices? Read the [CHANGELOG](CHANGELOG.md).
