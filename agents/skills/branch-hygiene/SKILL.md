---
name: branch-hygiene
description: Inspect and clean stale branches across multiple repositories using the dotfiles git-hygiene + gh-bootstrap toolchain. Use when the user asks about branch state, stale local branches, or "no ref was fetched" errors.
---

# Branch Hygiene

The user has a three-layer auto-hygiene system in `~/dev/dotfiles/`:

## What's already automatic

1. **GitHub-side settings** (set via `gh-bootstrap.sh`): every repo has
   `delete_branch_on_merge=true`, `allow_auto_merge=true` (Git Pro),
   `allow_update_branch=true`, and a squash-only merge policy with
   `squash_merge_commit_title=PR_TITLE` / `squash_merge_commit_message=PR_BODY`.
2. **Daily systemd timer** (`git-hygiene.timer`, fires 09:30 local) — runs
   `gh-bootstrap.sh --check --all ~/dev`, writes drift state to
   `~/.local/state/hygiene/status.json`, then runs
   `git-hygiene.sh prune ~/dev --yes --gh` to delete safely-dead local
   branches (class below). Every deletion is logged with its SHA to
   `~/.local/state/hygiene/cron.log` and `deletions.tsv` (recover with
   `git branch <name> <sha>`); an ntfy summary is pushed only when something
   was deleted, and it carries counts plus the log path only — repo and
   branch names never leave the local log (ntfy topics are effectively
   public). `NTFY_SERVER` overrides the default `https://ntfy.sh`.
   `HYGIENE_DELETE=0` in the unit's environment disables the prune.
3. **Shell `gh` wrapper** in `.bash_aliases` — when the user runs
   `gh repo create` or `gh repo clone` from their shell, the wrapper auto-runs
   `gh-bootstrap.sh` on the new repo. Note: this only fires from the user's
   interactive shell, not from agent-spawned shells.

## Workflow

When the user asks about hygiene state:

1. Read `~/.local/state/hygiene/status.json` first — it's the cached daily
   check. Use `~/dev/dotfiles/hygiene-status.sh --status` for a one-liner or
   `--text` for a full readout. This is read-only and instant.
2. If the user wants a fresh check, run
   `~/dev/dotfiles/gh-bootstrap.sh --check --all ~/dev`.
3. To clean stale local branches now: `~/dev/dotfiles/git-hygiene.sh prune
   ~/dev --yes --gh` (what the timer runs; add `--dry-run` to preview — it
   writes nothing: no deletions, no `fetch --prune`, no `remote set-head`), or
   the compatibility command `~/dev/dotfiles/git-hygiene.sh clean ~/dev --yes`,
   which uses the same conservative local proof rules.
4. To bootstrap a new or drifted repo:
   `~/dev/dotfiles/gh-bootstrap.sh <owner/repo>` or `--all <dir>`.

## Important: agent-created repos

If you (the Codex agent) run `gh repo create` or `gh repo clone` yourself,
the shell wrapper does not fire — your `gh` invocation goes directly to the
binary. **Run `~/dev/dotfiles/gh-bootstrap.sh <owner/repo>` immediately
after** any successful create/clone you do, so the new repo doesn't drift.

## What "safely deletable" means here

Both `clean` and `prune` require current remote evidence, known branch activity,
and proof that no unique merges or patches remain. Dirty working trees,
current branch, and worktree-checked-out branches are always skipped.
`HYGIENE_MIN_AGE_HOURS` in `git-hygiene.sh` controls the activity window.

`prune --gh` can also verify a squash-merged PR into the default branch when
its head SHA matches the local tip or a fetched descendant. A name or commit
subject match never authorizes deletion. Failed remote refresh, unknown
activity, unique merge commits and unavailable GitHub evidence preserve work.

For task worktrees, inspect `hygiene-status.sh --worktrees` or run
`python3 ~/dev/dotfiles/claude/scripts/worktree-lifecycle.py inventory --repo /path/to/repo`.
The timer reports ownership/disposition separately from settings drift and
never deletes worktrees. Follow the release and authorized-retirement procedure
in `claude/scripts/README.md`, including private evidence archival. A pending
PR retains its worktree with a named owner and follow-up command.

## Output

If the user just asks "is everything clean?":

```
$ ~/dev/dotfiles/hygiene-status.sh --status
settings clean (checked 4h ago)
```

This reports repository settings only; read `--worktrees` for retained or
released task worktrees. If settings drift exists, the same command emits a summary and the user can run
`gh-bootstrap.sh --all ~/dev` to fix it. Be specific about which repos
drifted — they're listed in `drifted_repos` of the JSON.

## Project state cleanup

After archiving or deleting a repo locally, also purge its Claude Code state
(transcripts, file history, config entries, tasks) — this works from any shell,
not just Claude sessions:

```bash
# Always dry-run first
claude project purge "$REPO_PATH" --dry-run

# When the dry-run looks right
claude project purge "$REPO_PATH" --yes
```

The `--all` flag purges every project not currently on disk in one pass —
useful after a quarterly cleanup. Without it, `~/.claude/projects/` and
`~/.claude/file-history/` accumulate state for dead projects forever.
