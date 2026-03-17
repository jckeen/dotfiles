# Dotfiles — Claude Code Power User Setup

Personal dev environment config for WSL Ubuntu, optimized for Claude Code mastery. Clone and run `./setup.sh` on a fresh machine.

Best practices sourced from [Boris Cherny](https://howborisusesclaudecode.com) (creator of Claude Code), the [official Claude Code docs](https://code.claude.com/docs/en/best-practices), and hard-won experience.

---

## Quick Start

```bash
# 1. Install WSL (from PowerShell as admin)
wsl --install

# 2. Open Ubuntu and clone this repo
cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# 3. Run setup
chmod +x setup.sh
./setup.sh

# 4. Authenticate
gh auth login          # GitHub CLI (choose HTTPS + browser)
claude                 # Follow the login prompt
```

---

## What Gets Installed & Configured

| Category | What | Why |
|----------|------|-----|
| **CLI Tools** | `gh`, `git`, `node`, `claude` | Core dev toolchain |
| **Claude Config** | `CLAUDE.md`, `settings.json`, hooks, skills, agents | Zero-config Claude Code mastery |
| **Audio** | ALSA → PulseAudio routing | Voice mode in WSL |
| **Git** | Identity, VS Code editor, Windows credential manager | Seamless WSL git |

---

## Best Practices for Claude Code

### 1. Context Is Everything — Manage It Aggressively

This is the #1 thing to understand. Claude's context window is finite, and **performance degrades as it fills**. Every file read, every command output, every message consumes tokens.

**What to do:**
- Run `/clear` between unrelated tasks — never let irrelevant context accumulate
- Use subagents for investigation — they explore in a separate context and report back summaries
- Keep sessions focused on one task. If you're doing two unrelated things, use two sessions
- Watch the context % in your status line. When it gets high, consider `/handoff` → fresh session
- Use `/compact` to compress conversation when you need to stay in the same session

**Signs your context is degraded:**
- Claude gets repetitive or generic
- It forgets things you said earlier
- It makes mistakes it wouldn't normally make
- It stops following your CLAUDE.md rules

**Fix:** Start fresh. Use `/handoff` to capture state, then `/clear` or open a new session.

### 2. Plan First, Then Execute

Most sessions should start in **Plan Mode** (Shift+Tab twice).

```
1. Enter Plan Mode
2. Describe what you want
3. Go back and forth until the plan is solid
4. Switch to Normal Mode (auto-accept edits)
5. Claude executes — often 1-shotting the whole thing
```

**When to skip planning:** Single-file fixes, typos, simple additions where you can describe the exact diff in one sentence.

**When to always plan:** Multi-file changes, unfamiliar code, architectural decisions, anything you'd want a code review on.

### 3. Always Give Claude a Way to Verify

This is the single highest-leverage habit. Always provide tests, screenshots, or expected outputs.

| Bad | Good |
|-----|------|
| "implement email validation" | "write validateEmail. Test cases: user@example.com → true, invalid → false, user@.com → false. Run the tests after implementing" |
| "make the dashboard look better" | "[paste screenshot] implement this design. Take a screenshot and compare to the original" |
| "the build is failing" | "the build fails with [paste error]. Fix it and verify the build succeeds" |

**The pattern:** Write a failing test first, then implement the fix, then verify the test passes.

### 4. Prompt Like a Senior Engineer

**Be specific, not vague:**
- Bad: "add auth"
- Good: "add email/password login using NextAuth with Postgres, redirect to /dashboard after login"

**Point to patterns:**
- "Look at how HotDogWidget.php implements widgets. Follow the same pattern for a CalendarWidget"

**Include context:**
- What framework/language
- Expected behavior and edge cases
- Sample input/output

**When debugging, give the full error:**
- Paste the entire error message, not a summary
- Include what you were doing when it happened

**Power prompts from Boris Cherny:**
- "Grill me on these changes and don't make a PR until I pass your test"
- "Knowing everything you know now, scrap this and implement the elegant solution"
- "Interview me about this feature using the AskUserQuestion tool. Dig into the hard parts I haven't considered"

### 5. Parallelize — The #1 Productivity Unlock

Boris Cherny's top tip: run 3-5 sessions in parallel.

**How:**
- Use git worktrees: each worktree gets its own Claude session
- Run `claude-server` to spawn isolated worktree + remote control
- Access additional sessions at `claude.ai/code`
- Use shell aliases to hop between worktrees instantly

```bash
# Quick worktree setup
git worktree add ../myproject-auth feature/auth
cd ../myproject-auth && claude

# Or use the built-in command
claude-server
```

**Writer/Reviewer pattern:**
- Session A writes the code
- Session B reviews it (fresh context = better review, no bias toward its own code)
- Session A addresses the feedback

### 6. Use CLAUDE.md as Compounding Engineering

Your `CLAUDE.md` is your most powerful tool. It compounds in value over time.

**Rules:**
- Keep it under 200 lines — if it's too long, Claude ignores half of it
- Only include things Claude can't figure out by reading code
- For each line, ask: "Would removing this cause Claude to make mistakes?" If not, cut it
- Check it into git so your team benefits
- Claude is "eerily good at writing rules for itself" — ask it to update CLAUDE.md when it makes a mistake

**What to include:**
- Build/run/test commands Claude can't guess
- Code style rules that differ from defaults
- Architecture decisions specific to your project
- Common gotchas or non-obvious behaviors

**What NOT to include:**
- Standard language conventions Claude already knows
- File-by-file descriptions of the codebase
- Long tutorials or explanations
- Things that change frequently

### 7. Hooks > CLAUDE.md for Enforcement

CLAUDE.md is advisory. Hooks are enforced.

An instruction saying "never use rm -rf" can be forgotten under context pressure. A PreToolUse hook that blocks `rm -rf` fires every single time.

**Your installed hooks:**
- `block-dangerous.sh` — Blocks recursive deletion, force push to main, DROP TABLE, git reset --hard, git clean -f
- `format-on-edit.sh` — Auto-formats files after Claude edits them (prettier, black, rustfmt, gofmt)

**Create your own:** Ask Claude: "Write a hook that runs eslint after every file edit" or "Write a hook that blocks writes to the migrations folder"

### 8. Skills for Repeated Workflows

Every workflow you do more than twice should be a slash command.

**Your installed skills:**

| Command | When to use it |
|---------|---------------|
| `/kickoff` | Starting a new project — scaffolds structure, CLAUDE.md, git |
| `/changelog` | End of session — logs what happened |
| `/log-error` | Hit a wall — documents the error pattern |
| `/review` | Before shipping — reviews for bugs, security, quality |
| `/handoff` | Session transition — captures state for next session |
| `/fix-issue 123` | Pick up a GitHub issue end-to-end |
| `/simplify` | After building — removes unnecessary complexity |
| `/commit-push-pr` | Commit, push, create PR in one shot (Boris's most-used command) |
| `/claude-server` | Spawn isolated worktree + remote control |

### 9. Subagents for Context Protection

Subagents run in their own context window. Use them when you want results without consuming your main context.

**Your installed subagents:**
- `security-reviewer` — Reviews code for vulnerabilities (injection, auth, secrets)
- `code-simplifier` — Finds and removes unnecessary complexity

**When to use subagents:**
- Codebase investigation ("use subagents to investigate how auth works")
- Code review ("use a subagent to review this for edge cases")
- Any task that would read many files

### 10. Use Opus with Thinking

Boris uses Opus for everything. It's bigger and slower than Sonnet, but you steer it less and it's better at tool use — so it's almost always faster in practice. Your config is set to prefer Opus.

### 11. Self-Improvement Loop — Make Claude Fix Itself

Every time Claude makes a mistake:
1. Correct it
2. Say: "Update the project's CLAUDE.md so you don't make that mistake again"
3. Claude writes a rule for itself — and it's eerily good at this

This is how your CLAUDE.md compounds over time. Boris's team does this religiously.

### 12. Use Voice Dictation for Prompts

You speak 3x faster than you type. Use voice dictation (fn key twice on Mac, or Claude's `/voice` command in WSL) to describe what you want. Your WSL audio is already configured for this.

### 13. Let Claude Handle Git

Many Anthropic engineers use Claude for 90%+ of their git interactions. Don't manually commit, push, or create PRs — use `/commit-push-pr` and let Claude do it. It reads the diff and writes better commit messages than most humans.

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
claude                   # Start new session
claude --continue        # Resume most recent session
claude --resume          # Pick from recent sessions
claude -p "prompt"       # Non-interactive mode (for scripts/CI)
claude-rc                # Start with explicit remote control
claude-server            # Spawn isolated worktree + remote
```

**Name your sessions:** Run `/rename oauth-migration` so you can find them later with `--resume`.

**Treat sessions like branches:** Different workstreams get separate, persistent contexts.

---

## Common Anti-Patterns to Avoid

| Anti-Pattern | What Happens | Fix |
|-------------|-------------|-----|
| **Kitchen sink session** | You mix unrelated tasks. Context fills with noise | `/clear` between unrelated tasks |
| **Correction spiral** | Same fix attempted 3+ times. Context polluted with failures | After 2 failed corrections, `/clear` and write a better prompt |
| **Bloated CLAUDE.md** | Too many rules. Claude ignores the important ones | Prune ruthlessly. Convert to hooks |
| **Trust-then-verify gap** | Plausible-looking code that doesn't handle edge cases | Always provide tests or verification |
| **Infinite exploration** | Claude reads hundreds of files investigating | Scope narrowly or use subagents |
| **Skipping Plan Mode** | Jump straight to code on a multi-file change | Plan Mode first, execute after |

---

## Files That Matter

| File | Location | Purpose |
|------|----------|---------|
| `~/.claude/CLAUDE.md` | Global | Instructions Claude follows in ALL projects |
| `~/.claude/settings.json` | Global | Permissions, hooks, preferences |
| `~/.claude/AgentPackJCK.md` | Global | Multi-agent review framework |
| `~/.claude/skills/*/SKILL.md` | Global | Your slash commands |
| `~/.claude/agents/*.md` | Global | Custom subagents |
| `~/.claude/hooks/*.sh` | Global | Automated safety + formatting hooks |
| `<project>/CLAUDE.md` | Per-project | Project-specific instructions |
| `<project>/CHANGELOG.md` | Per-project | Session-by-session change log |

---

## Adding New Config

1. Add the config file to this repo under `claude/`
2. Add a symlink step in `setup.sh`
3. Run `./setup.sh` to deploy
4. Commit and push

---

## WSL-Specific Notes

- Git credentials shared with Windows via Git Credential Manager
- Repos on `/mnt/c/` need `safe.directory` config (setup.sh handles dotfiles; add others manually)
- Windows dev folder: `/mnt/c/Users/jckee/dev`
- Voice mode requires PulseAudio routing (setup.sh handles this)

---

## Sources

- [How Boris Uses Claude Code](https://howborisusesclaudecode.com) — Tips from the creator
- [Official Best Practices](https://code.claude.com/docs/en/best-practices) — Anthropic's documentation
- [Boris Cherny's Threads](https://www.threads.com/@boris_cherny) — Ongoing tips and team insights
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Hook documentation
- [Trail of Bits Config](https://github.com/trailofbits/claude-code-config) — Security-focused config reference
