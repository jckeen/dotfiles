---
name: handoff
description: Generate a concise session handoff for resuming work later, including current state, decisions, open issues, and next steps.
---

# Handoff

Use when the user asks for a handoff, context note, session summary, or resume
brief.

## Workflow

1. Inspect the current repo state with `git status --short`.
2. Review relevant recent commits or diffs if needed.
3. Summarize only durable context that would help the next session.
4. File USER ACTION items as `operator-action` issues in the repo they
   concern — see "Operator-action queue" below for the format and rules.
5. Session-end hygiene (before saving the note):
   - `git worktree list` — record every task worktree as removed, or retained
     with its owner, reason, PR, and concrete follow-up command. Follow the
     shared lifecycle procedure in `claude/scripts/README.md`. Stop owned
     processes first and archive recovery/review evidence. Remove explicitly
     released worktrees only after verified integration and applicable user or
     standing cleanup authorization. Preserve active/locked worktrees, unique
     work, dirty/untracked/ignored content, stashes and unknown ownership.
     Pending PRs retain their worktrees; release the exact completed artifact
     when appropriate so a later session can assess it after merge.
   - Inventory local branches fully merged into the default branch
     (`git branch --merged "$(git rev-parse --abbrev-ref origin/HEAD)"` —
     don't assume it's named `main`). Delete them only when the user or an
     applicable standing order explicitly authorizes branch deletion.
   - Push or PR every branch that has work on it — never leave work
     stranded local-only.
   - `gh pr list` — note each open PR's review + CI state in the
     handoff's "Open issues" section.
6. Save the note to `~/.claude/handoffs/YYYY-MM-DD-<project>-handoff.md` —
   the same directory the Claude `/handoff` skill uses, so either tool can
   resume the other's session. Create the directory if needed. Never save it
   inside the public repo.

## Output

Use the same section names as the Claude `/handoff` skill so notes are
interchangeable across tools:

```markdown
## Handoff — YYYY-MM-DD

### What we did
- ...

### Where we left off
- ...

### Key decisions made
- ...

### Open issues
- ...

### Next steps
- ...

### Context for next session
- ...

### Session continuity
- (optional) Resumable agent sessions: my Codex session id (`codex resume <id>`),
  or an agy conversation id (`agy --conversation <id>`). Omit if none.
```

Keep it concise. Do not include secrets, private project details, tokens, or
machine-specific paths unless the user explicitly asks and the destination is
private.

### Operator-action queue

Anything only the operator can do (rotate a token, click an approval, decide
on a purchase) becomes an open GitHub issue labelled `operator-action` —
handoff prose gets buried by the next handoff; an issue does not. **File it in
the repo it concerns** when that repo is private
(`gh repo view --json visibility` says `PRIVATE`), sits on the same GitHub
host as the home repo, and its owner is one the SessionStart reminder
searches (`$OPERATOR_QUEUE_OWNERS`, default
`jckeen Keen-Media therealnewsnetwork`; an issue anywhere else never shows
up). Anything else — a public repo, another owner or host, work spanning
several repos — goes to the private home repo (`$OPERATOR_QUEUE_REPO`,
default `jckeen/claude-memory`) instead — items name credentials, providers and
pending decisions, so never file one in a public repo. Create the `operator-action` label first if the repo lacks it. One item
per issue: the title is the slug, the body holds the fields:

```markdown
- added: YYYY-MM-DD
- project: <source project>
- deadline: YYYY-MM-DD
- verified: YYYY-MM-DD
- action: <one line: what the operator must do>
```

The slug is stable (same action = same slug across sessions); `deadline` and
`verified` are optional — omit the line if none. **File only if absent** —
check the reminder's own list first: its footer (`Full queue: …`) prints
the exact `gh api graphql` search it runs, with its host, owners and filters.
Run that command and look for the slug among the titles; never file a
duplicate. A match whose body or title someone else last edited is hidden by
the reminder, so it doesn't count: file a fresh issue and link the old one. **Close the issue only when the action is actually
done** (`--reason completed`), not when it's merely mentioned again.
`~/.claude/operator-queue.md` is retired: never append to it. While that
file exists without the `> **Historical**` banner in its first lines, the
reminder reads it instead of the issues — so on a machine where it is still
live, move its items into issues and add the banner before filing new ones.

`verified` records the last time the item was checked against live state
(the PR, the env var, the dashboard — not the previous handoff). **When a
session touches an item's subject, re-check it against live state and
comment `verified: YYYY-MM-DD — <what was checked>` on the issue (or edit the
body's `verified:` line); close it only when done.** The SessionStart
reminder treats the newest of `verified`/`added`/newest comment as the item's
freshness and marks anything older than 30 days `[stale — re-verify]`, so an
unbumped item announces its own rot instead of being repeated as fact.
