---
name: handoff
description: Generate a handoff note for clean session transitions — preserves context across /clear or new sessions. Use when ending a session, when context is getting high, or when the user says "hand off", "wrap up the session", or "save state for next time".
---

When the user runs /handoff, do the following:

1. Summarize the current session into a handoff note with this structure:

```markdown
## Handoff — [date]

### What we did
- Bullet points of completed work this session

### Where we left off
- Current state of the work (what's done, what's in progress)
- Any uncommitted changes or pending tasks

### Key decisions made
- Architectural or design choices worth remembering

### Open issues
- Anything broken, blocked, or deferred

### Next steps
- What to pick up in the next session (prioritized)

### Context for next session
- Anything the next session needs to know that isn't in the code or git history

### Session continuity
- (optional) Resumable teammate-agent sessions relevant to this work:
  codex session id (`codex resume <id>`), agy conversation id
  (`agy --conversation <id>`). Omit the section if there are none.
```

2. File USER ACTION items as `operator-action` issues in the repo they
   concern — see "Operator-action queue" below for the format and rules.
3. Save the note to `~/.claude/handoffs/[date]-[project-name]-handoff.md` (the global Claude config directory, NOT inside the project repo). Create the directory if needed. **If the file already exists, Read it first before Writing** — this prevents the overwrite confirmation prompt.
4. Update `CHANGELOG.md` with what happened this session. Create it if it doesn't exist. Keep entries concise — what changed and why, not how.
5. Session-end hygiene (before committing):
   - `git worktree list` — record each task worktree as removed, or retained
     with an owner, reason, PR, and concrete follow-up command. Follow the
     shared lifecycle procedure in `claude/scripts/README.md`. Stop owned
     processes first, archive recovery/review evidence, and remove only
     explicitly released worktrees after verified integration and applicable
     user or standing cleanup authorization. A pending PR keeps its worktree;
     record its release for a later session to assess after merge.
   - Inventory branches fully merged into the default branch, excluding the
     default and current branches. Delete only under applicable user or
     standing cleanup authorization and after proving no unique work remains.
     Preserve dirty/ignored/untracked files, stashes, locks and unknown owners.
   - Push or PR every branch that has work on it — never leave work
     stranded local-only.
   - `gh pr list` — note each open PR's review + CI state in the
     handoff's "Open issues" section.
6. Commit all pending work (do NOT commit the handoff note — it lives outside the repo).
7. Display the handoff note so the user can copy it or reference it when starting a new session.

**Tip:** The user can paste the handoff note at the start of a new session to restore context cleanly.

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
search first with the reminder's own filters, across the target repo's
owner and the home repo's owner (repeated `--owner` flags match either):
`gh search issues "<slug>" --match title --label operator-action --state open
--author @me --visibility private --owner <repo-owner> --owner <home-owner>`,
where `<home-owner>` is the owner part of the home repo. Never file a
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
