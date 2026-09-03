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
   the broader heuristic `~/dev/dotfiles/git-hygiene.sh clean ~/dev --yes`.
4. To bootstrap a new or drifted repo:
   `~/dev/dotfiles/gh-bootstrap.sh <owner/repo>` or `--all <dir>`.

## Important: agent-created repos

If you (the Codex agent) run `gh repo create` or `gh repo clone` yourself,
the shell wrapper does not fire — your `gh` invocation goes directly to the
binary. **Run `~/dev/dotfiles/gh-bootstrap.sh <owner/repo>` immediately
after** any successful create/clone you do, so the new repo doesn't drift.

## What "safely deletable" means here

`git-hygiene.sh` confirms a local branch is merged via three independent
signals before deleting:
1. `git cherry origin/<default> <branch>` — patch-equivalent commits
2. Each commit's subject is found in `origin/<default>` history
   (catches squash collapses that cherry misses)
3. `gh pr list --state all --head <branch> --base <default>` returns MERGED
   (a PR merged into a release/feature branch that never reached the default
   does not count)

A branch is deleted only when at least one signal confirms merge. Dirty
working trees, current branch, and worktree-checked-out branches are always
skipped.

`git-hygiene.sh prune` (the timer's mode) is stricter because it runs
unattended: it deletes a branch only when it is not the default, checked-out,
or worktree branch, was not touched in the last 24 h, and either has no unique
commits vs `origin/<default>` (merged, upstream gone, or cherry-equivalent)
or — with `--gh` and a working `gh auth status` — GitHub shows a PR merged
into the default branch whose head ref is the branch and whose head SHA is
the local tip (or a locally-fetched descendant of it). Subject matching is not used; a
squash-merged branch with no confirming PR is kept, and any `gh` error keeps
the branch.

## Output

If the user just asks "is everything clean?":

```
$ ~/dev/dotfiles/hygiene-status.sh --status
clean (checked 4h ago)
```

If drift exists, the same command emits a summary and the user can run
`gh-bootstrap.sh --all ~/dev` to fix it. Be specific about which repos
drifted — they're listed in `drifted_repos` of the JSON.

## Project state cleanup

After archiving or deleting a repo locally, also purge its Claude Code state (transcripts, file history, config entries, tasks):

```bash
# Always dry-run first
claude project purge "$REPO_PATH" --dry-run

# When the dry-run looks right
claude project purge "$REPO_PATH" --yes
```

The `--all` flag purges every project not currently on disk in one pass — useful after a quarterly cleanup.

This is the v2.1.126 primitive. Without it, `~/.claude/projects/` and `~/.claude/file-history/` accumulate state for dead projects forever.
