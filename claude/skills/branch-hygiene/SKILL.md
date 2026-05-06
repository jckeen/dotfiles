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
   `gh-bootstrap.sh --check --all ~/dev` and writes drift state to
   `~/.local/state/hygiene/status.json`. On Sundays it also runs
   `git-hygiene.sh clean ~/dev --yes` to delete locally-merged branches.
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
3. To clean stale local branches now (instead of waiting for Sunday):
   `~/dev/dotfiles/git-hygiene.sh clean ~/dev --yes`.
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
3. `gh pr list --state all --head <branch>` returns MERGED

A branch is deleted only when at least one signal confirms merge. Dirty
working trees, current branch, and worktree-checked-out branches are always
skipped.

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
