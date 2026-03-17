# Dotfiles — Claude Code Power User Setup

Dev environment config with Claude Code workflows, skills, and safety guards. Works on **macOS**, **WSL (Ubuntu)**, and **native Linux**.

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
| **Agent Pack** | `AgentPackJCK.md` | 10-agent review framework for product/code analysis |
| **Status line** | `statusline.sh` | Shows model, context %, git branch, lines changed, session cost |
| **Safety hooks** | `hooks/block-dangerous.sh` | Blocks `rm -rf /`, force push to main, `DROP TABLE`, etc. |
| **Format hook** | `hooks/format-on-edit.sh` | Auto-formats files after edits (prettier, black, rustfmt, gofmt) |
| **Skills** | `skills/*/SKILL.md` | 9 slash commands (see below) |
| **Subagents** | `agents/*.md` | Security reviewer + code simplifier |
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
| `cc` | **Recommended way to start.** Pulls all repos, then launches Claude |
| `claude` | Start Claude directly (no repo sync) |
| `claude-rc` | Start with explicit remote control flag |
| `claude-server` | Spawn an isolated worktree + remote control session |

### Repo management

| Command | What it does |
|---------|-------------|
| `pull-all` | Git pull (fast-forward only) on every repo in your dev directory that has a remote. Skips local-only repos |

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

**Example:** Run a feature and a review in parallel:
```bash
gwa ../myproject-review main    # create a review worktree
za                               # jump to worktree -a
wt-claude auth feature/auth     # or create + launch in one step
```

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

## Subagents

Custom agents that run in their own context window, protecting your main session from bloat.

| Agent | Purpose |
|-------|---------|
| `security-reviewer` | Reviews code for injection, auth flaws, secrets, insecure data handling |
| `code-simplifier` | Finds premature abstractions, dead code, unnecessary complexity |

Invoke them: "use the security-reviewer subagent to review this PR" or just run `/simplify`.

---

## Agent Pack (10-Agent Review Framework)

For comprehensive product and code analysis, the Agent Pack provides 10 specialized perspectives. Invoke by asking Claude to "review this using the agent pack" or "what would the QA lead think?"

| Agent | Focus |
|-------|-------|
| Product strategist | User flow, feature prioritization, MVP scope |
| UX/UI designer | Layout, hierarchy, interaction patterns |
| Frontend architect | Components, state management, performance |
| Backend/data architect | Schema, queries, API design |
| Growth strategist | Sharing, distribution, viral loops |
| Content/tone designer | Microcopy, voice consistency |
| Trust/safety advisor | Moderation, abuse prevention, legal |
| QA lead | Edge cases, error states, mobile testing |
| Performance/accessibility | Speed, WCAG compliance, keyboard nav |
| Launch operator | Deploy, monitoring, smoke tests |

Includes coordination rules for running agents in parallel vs. sequentially.

---

## Safety Hooks

Hooks run automatically — they can't be forgotten like CLAUDE.md rules.

**`block-dangerous.sh`** (PreToolUse) blocks:
- `rm -rf` on `/`, `~`, `$HOME`, or `..`
- `git push --force` to main/master
- `DROP DATABASE` / `DROP TABLE`
- Edits to `.env.prod` / `.env.production`
- `git reset --hard` and `git clean -f`
- Deletion of Windows system paths (WSL)

**`format-on-edit.sh`** (PostToolUse) auto-formats after file edits:
- JS/TS/JSON/CSS → prettier
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
- **Git branch** (cached 5s)
- **Worktree name** (when in a parallel session)
- **Lines added/removed** this session
- **Session cost** in USD

---

## The Core Workflow

```
1. DEFINE   → Tell Claude what you want. Be specific. Include the goal,
               the tech, and what "done" looks like.

2. PLAN     → Shift+Tab twice for Plan Mode. Go back and forth until
               the plan is solid. Press Ctrl+G to edit the plan directly.

3. BUILD    → Switch to Normal Mode. Claude writes code and auto-commits
               after each meaningful change.

4. VERIFY   → Claude runs tests before committing. If something breaks,
               it fixes before moving on.

5. SIMPLIFY → Run /simplify to remove unnecessary complexity.

6. REVIEW   → Run /review for quality/security check.

7. LOG      → Run /changelog to capture what happened.

8. HANDOFF  → Run /handoff if ending the session.
```

---

## Keyboard Shortcuts

| Shortcut | What it does |
|----------|-------------|
| `Shift+Tab` (x2) | Toggle Plan Mode |
| `Ctrl+G` | Open plan in text editor for direct editing |
| `Ctrl+B` | Send current task to background |
| `Esc` | Stop Claude mid-response (context preserved) |
| `Esc+Esc` | Open rewind menu — restore conversation, code, or both |
| `/compact` | Compress conversation to free up context |
| `/clear` | Reset context completely |
| `/btw` | Side question — answer appears in overlay, never enters context |
| `/rewind` | Checkpoint menu — restore to any previous state |
| `/rename` | Name your session for easy resuming later |

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

**Name your sessions:** Run `/rename oauth-migration` so you can find them later with `--resume`.

**Treat sessions like branches:** Different workstreams get separate, persistent contexts.

---

## Best Practices

<details>
<summary><strong>Click to expand the full best practices guide</strong></summary>

### Context Is Everything — Manage It Aggressively

Claude's context window is finite, and **performance degrades as it fills**. Every file read, every command output, every message consumes tokens.

- Run `/clear` between unrelated tasks
- Use subagents for investigation — they report back summaries, not raw files
- Keep sessions focused on one task
- Watch the context % in your status line — `/handoff` → fresh session when it's high
- Use `/compact` to compress if you need to stay in the same session

### Plan First, Then Execute

Most sessions should start in **Plan Mode** (Shift+Tab twice). Go back and forth until solid, then switch to Normal Mode and let Claude execute. Often 1-shots the whole thing.

**Skip planning for:** single-file fixes, typos, one-sentence diffs.
**Always plan for:** multi-file changes, unfamiliar code, architecture decisions.

### Always Give Claude a Way to Verify

The single highest-leverage habit. Provide tests, screenshots, or expected outputs.

**The pattern:** failing test first → implement fix → verify test passes.

### Prompt Like a Senior Engineer

- Be specific: "add email/password login using NextAuth with Postgres" not "add auth"
- Point to patterns: "Follow the same pattern as HotDogWidget.php"
- Paste full error messages, not summaries
- Power prompts: "Grill me on these changes", "Scrap this and implement the elegant solution"

### Parallelize with Worktrees

Run 3-5 sessions in parallel using git worktrees. Use `wt-claude`, `claude-server`, or the `za`-`ze` aliases.

**Writer/Reviewer pattern:** Session A writes code, Session B reviews it (fresh context = better review).

### CLAUDE.md Compounds Over Time

- Keep it under 200 lines — if it's too long, Claude ignores half
- Only include things Claude can't figure out by reading code
- When Claude makes a mistake, have it update CLAUDE.md to prevent recurrence

### Hooks > CLAUDE.md for Enforcement

CLAUDE.md is advisory. Hooks are enforced. Convert frequently-violated rules into hooks.

### Let Claude Handle Git

Use `/commit-push-pr` instead of manual git. Claude reads the diff and writes better commit messages than most humans.

</details>

---

## Common Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| Kitchen sink session (mixing unrelated tasks) | `/clear` between tasks |
| Correction spiral (same fix 3+ times) | `/clear` and write a better prompt |
| Bloated CLAUDE.md (too many rules) | Prune ruthlessly, convert to hooks |
| No verification (trusting plausible-looking code) | Always provide tests |
| Infinite exploration (reading hundreds of files) | Use subagents |
| Skipping Plan Mode on multi-file changes | Plan Mode first |

---

## Repo Structure

```
dotfiles/
├── setup.sh                    # Cross-platform bootstrap script
├── sync-claude.sh              # One-way sync (dotfiles → ~/.claude/)
├── .bash_aliases               # Shell aliases, functions, worktree shortcuts
├── .gitconfig                  # Base git config (includes .gitconfig.local)
├── .gitignore                  # Ignores generated files
├── .asoundrc                   # WSL audio routing
├── README.md                   # This file
├── CLAUDE-GUIDE.md             # Quick reference cheat sheet
├── CHANGELOG.md                # Session-by-session change log
└── claude/
    ├── CLAUDE.md               # Global Claude instructions
    ├── AgentPackJCK.md         # 10-agent review framework
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
    └── agents/
        ├── security-reviewer.md
        └── code-simplifier.md
```

---

## Adding New Config

1. Add the file to this repo under `claude/`
2. Add a symlink step in `setup.sh`
3. Run `./setup.sh` to deploy (or `./sync-claude.sh` for Claude-only changes)
4. Commit and push

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference
