# Dotfiles — Claude Code Power User Setup

Production-ready Claude Code setup with safety hooks, 9 slash commands, a 12-agent review orchestra, and a custom status line. Clone it, run `setup.sh`, and skip the config trial-and-error.

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
./setup.sh

# Authenticate
gh auth login          # GitHub CLI (choose HTTPS + browser)
claude                 # Follow the login prompt
```

The setup script auto-detects your platform, installs tools, prompts for git identity, and symlinks all Claude config into `~/.claude/`.

### Try it now

After setup, try these to see what you've got:

```bash
cc                    # pulls all your repos, then launches Claude
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

WSL also gets: `pulseaudio-utils`, `libasound2-plugins`, `alsa-utils` (for `/voice` support).

## What Gets Configured

Everything is **symlinked** from this repo to `~/.claude/`, so edits in either location stay in sync.

| What | Files | Purpose |
|------|-------|---------|
| **Claude instructions** | `CLAUDE.md` | Global rules Claude follows in every session |
| **Settings** | `settings.json` | Permissions, hooks, preferred model (Opus), remote control |
| **Agent Pack** | `AgentPack.md` | 12-agent review orchestra for product/code analysis |
| **Status line** | `statusline.sh` | Shows model, context %, git branch, lines changed, session cost |
| **Safety hooks** | `hooks/block-dangerous.sh` | Blocks `rm -rf /`, force push to main, `DROP TABLE`, etc. |
| **Format hook** | `hooks/format-on-edit.sh` | Auto-formats files after edits (prettier, black, rustfmt, gofmt) |
| **Skills** | `skills/*/SKILL.md` | 9 slash commands (see below) |
| **Subagents** | `agents/*.md` | 12 specialized review agents |
| **Shell aliases** | `.bash_aliases` | `cc`, `pull-all`, worktree shortcuts |
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

### Repo management

| Command | What it does |
|---------|-------------|
| `pull-all` | Git pull (fast-forward only) on every repo in your dev directory that has a remote. Skips local-only repos |
| `sync-memory` | Commit and push any pending memory changes (runs automatically as part of `cc`) |
| `check-claude` | Verify all Claude config symlinks, memory, and hooks are healthy |

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

## Agent Pack (12-Agent Review Orchestra)

A team of 12 specialized subagents, each running in **its own isolated context**. They investigate independently and report back without polluting each other's context or your main session.

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

**`block-dangerous.sh`** (PreToolUse) blocks:
- `rm -rf` on `/`, `~`, `$HOME`, `..`, `.`, or `*`
- `git push --force` to main/master (any argument order)
- `DROP DATABASE` / `DROP TABLE`
- Edits to `.env.prod` / `.env.production`
- `git reset --hard` and `git clean -f`
- Deletion of Windows system paths (WSL)

**`format-on-edit.sh`** (PostToolUse) auto-formats after file edits:
- JS/TS/JSON/CSS → prettier (finds project root automatically)
- Python → black or ruff
- Rust → rustfmt
- Go → gofmt

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
claude                   # Start new session directly
claude --continue        # Resume most recent session
claude --resume          # Pick from recent sessions
claude -p "prompt"       # Non-interactive mode (for scripts/CI)
claude-server            # Spawn isolated worktree + remote control
```

**Remote access** is always on. Connect from `claude.ai/code` or the Claude mobile app.

---

## Persistent Memory

Claude Code stores memory files (user preferences, project context, feedback) in `~/.claude/projects/`. By default these only exist on your local machine — rebuild your environment and they're gone.

This setup solves that with a **separate private repo**:

1. Create a private repo for your memory:
   ```bash
   mkdir -p ~/dev/claude-memory/dev/memory
   cd ~/dev/claude-memory
   git init && git add -A && git commit -m "init: claude memory"
   gh repo create claude-memory --private --source=. --push
   ```

2. Run `setup.sh` — it auto-detects the `claude-memory` repo and symlinks it into `~/.claude/projects/`

3. That's it. The `cc` command auto-commits and pushes memory changes before each session, so your memory is always backed up.

**Why a separate repo?** Memory files contain personal context (your role, project details, preferences). If your dotfiles repo is public, memory needs to stay private. If your dotfiles are private, you could skip this — but the separation is still cleaner.

**What gets stored:**
- User context (role, expertise, how you like to work)
- Feedback (corrections you've given Claude, validated approaches)
- Project state (what's being built, blockers, deadlines)
- References (where to find things in external systems)

`check-claude.sh` verifies the memory symlink is healthy alongside everything else.

---

## Customizing

This repo is designed to be forked and adapted. Here's what to edit vs. leave alone:

**Edit these (your personal config):**
- `claude/CLAUDE.md` — your workflow rules and preferences
- `claude/settings.json` — your permissions and tool allowlists
- `claude/AgentPack.md` — add, remove, or modify review agents
- `.bash_aliases` — your shell shortcuts

**Leave these (the framework):**
- `claude/hooks/*.sh` — safety guards (add new ones, but keep the defaults)
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

Keep it under 200 lines. When Claude makes a mistake, have it update CLAUDE.md to prevent recurrence.

### Hooks > CLAUDE.md for Enforcement

CLAUDE.md is advisory. Hooks are enforced. Convert frequently-violated rules into hooks.

</details>

---

## Repo Structure

```
dotfiles/
├── setup.sh                    # Cross-platform bootstrap script
├── sync-claude.sh              # Copy-based sync (for environments without symlinks)
├── .bash_aliases               # Shell aliases, functions, worktree shortcuts
├── .gitconfig                  # Base git config (includes .gitconfig.local)
├── .gitignore                  # Ignores generated files
├── .gitattributes              # Line ending normalization (LF for scripts)
├── .asoundrc                   # WSL audio routing
├── LICENSE                     # MIT
├── README.md                   # This file
├── CLAUDE-GUIDE.md             # Quick reference cheat sheet
├── CHANGELOG.md                # Change log
└── claude/
    ├── CLAUDE.md               # Global Claude instructions
    ├── AgentPack.md            # 12-agent review orchestra
    ├── settings.json           # Permissions, hooks, model preferences
    ├── statusline.sh           # Context bar, git branch, cost display
    ├── hooks/
    │   ├── block-dangerous.sh  # PreToolUse safety guard
    │   └── format-on-edit.sh   # PostToolUse auto-formatter
    ├── skills/
    │   ├── kickoff/            # /kickoff — new project bootstrap
    │   ├── changelog/          # /changelog — session logging
    │   ├── log-error/          # /log-error — error documentation
    │   ├── review/             # /review — code quality check
    │   ├── handoff/            # /handoff — session transitions
    │   ├── fix-issue/          # /fix-issue — GitHub issue workflow
    │   ├── simplify/           # /simplify — complexity removal
    │   ├── commit-push-pr/     # /commit-push-pr — one-shot shipping
    │   └── claude-server/      # /claude-server — remote worktree
    └── agents/                 # 12 specialized review subagents
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
        └── code-simplifier.md
```

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference

Want to understand the reasoning behind these choices? Read the [CHANGELOG](CHANGELOG.md).
