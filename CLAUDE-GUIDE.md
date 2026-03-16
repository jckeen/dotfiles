# Working with Claude Code — Starter Guide

A reference for how to use Claude Code effectively. Read this when setting up a new machine or when you need a refresher.

---

## First-time setup

1. **Install WSL** (PowerShell as admin): `wsl --install`
2. **Open Ubuntu**, clone this repo, and run the setup script:
   ```bash
   cd /mnt/c/Users/jckee/dev
   git clone https://github.com/jckeen/dotfiles.git
   cd dotfiles && chmod +x setup.sh && ./setup.sh
   ```
3. **Authenticate GitHub**: `gh auth login` (choose HTTPS + browser)
4. **Authenticate Claude**: run `claude` and follow the login prompt

That's it. Your git config, Claude settings, skills, and agent pack are all deployed.

---

## Starting a session

Just open your terminal and run `claude` from your project directory. Claude will automatically:
- Check git status and recent commits
- Read the project's `CLAUDE.md` and `CHANGELOG.md`
- Ask what you want to work on

**Remote access** (connect from anywhere — phone, browser, another machine):

Remote control is enabled by default in your settings. Every session is automatically available at `claude.ai/code` and via the Claude mobile app.

```bash
claude                  # start normally — remote control is always on
claude-rc               # same thing, explicit remote control flag
claude-server           # spawn an isolated worktree + remote control
```

To work remotely: start `claude` on your home machine, then open `claude.ai/code` from anywhere to connect to that session.

---

## Slash commands you have

These are your custom skills. Type them directly in Claude Code.

| Command | When to use it |
|---------|---------------|
| `/kickoff` | Starting a brand new project — scaffolds folder structure, CLAUDE.md, changelog, git |
| `/changelog` | End of a session — logs what you did into CHANGELOG.md |
| `/log-error` | Hit a wall you can't solve — documents the error for next time |
| `/review` | Before shipping — reviews recent changes for bugs, security, quality |

---

## The core workflow

```
1. DEFINE   → Tell Claude what you want. Be specific: include the goal,
               the tech, and what "done" looks like.

2. PLAN     → For anything non-trivial, Claude will outline an approach
               before coding. Review it. Course-correct early.

3. BUILD    → Claude writes code. It auto-commits after each meaningful
               change with conventional commit messages.

4. TEST     → Claude runs the project's build/test command before committing.
               If something breaks, it fixes before moving on.

5. LOG      → Run /changelog at the end. It captures what happened so
               future-you (or future-Claude) can pick up where you left off.
```

---

## How to talk to Claude effectively

**Be specific, not vague:**
- Bad: "add auth"
- Good: "add email/password login using NextAuth with a Postgres database, redirect to /dashboard after login"

**Include context when it matters:**
- What framework/language you're using
- What the expected behavior should be
- Sample input/output if relevant

**When debugging, give the full error:**
- Copy-paste the entire error message, not a summary
- Include what you were doing when it happened

**When Claude gets stuck (same error 3+ times):**
- Don't let it keep retrying the same fix
- Say: "stop — explain why this is failing" or "try a completely different approach"
- Or start a fresh conversation with just the key context

---

## Context hygiene

Claude's quality degrades in very long conversations (~50k+ tokens). Signs:
- Responses get repetitive or generic
- It forgets things you said earlier
- It starts making mistakes it wouldn't normally make

**Fix:** Start a new conversation. Bring over only what matters:
- The goal
- The current error or blocker
- Any key decisions made

The project's `CLAUDE.md` and `CHANGELOG.md` carry context between sessions automatically — that's why they exist.

---

## Project structure Claude expects

When you `/kickoff` a new project, it creates:

```
project-name/
├── CLAUDE.md       ← project-specific instructions Claude reads every session
├── CHANGELOG.md    ← session log, updated with /changelog
├── .gitignore      ← language-appropriate ignores
├── README.md       ← project description
└── src/            ← source code
```

The `CLAUDE.md` per project is where you put:
- Build/run/test commands
- Architecture decisions
- Conventions to follow
- Anything Claude needs to know about YOUR project

---

## Key keyboard shortcuts

| Shortcut | What it does |
|----------|-------------|
| `Ctrl+B` | Send current task to background (keep working on something else) |
| `Ctrl+C` | Interrupt Claude mid-response |
| `/plan` | Enter plan mode — Claude explores and proposes before building |
| `/compact` | Compress conversation to free up context |
| `/clear` | Start fresh conversation |

---

## Files that matter

| File | Location | Purpose |
|------|----------|---------|
| `~/.claude/CLAUDE.md` | Global | Instructions Claude follows in ALL projects |
| `~/.claude/settings.json` | Global | Permissions, allowed commands, preferences |
| `~/.claude/AgentPackJCK.md` | Global | Multi-agent review framework |
| `~/.claude/skills/*.md` | Global | Your slash commands |
| `<project>/CLAUDE.md` | Per-project | Project-specific instructions and context |
| `<project>/CHANGELOG.md` | Per-project | Session-by-session log of changes |

---

## Things to remember

- **Claude auto-commits.** You don't need to ask. It commits after each meaningful change.
- **Claude auto-pushes.** Every 2-3 commits or at end of task.
- **CLAUDE.md is your most powerful tool.** The better your project instructions, the better Claude performs.
- **Start fresh when sessions get long.** Context is finite. Don't fight it.
- **You're the architect, Claude is the builder.** Describe what you want, review what it produces, course-correct.
