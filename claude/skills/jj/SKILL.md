---
name: jj
description: >-
  Drives jujutsu (jj) version control on the user's behalf so they don't have to
  memorize commands. Use for single-agent feature work (the default), whenever the
  user mentions jujutsu/jj, when undo-safety or a clean rewritable history matters,
  or when starting/finishing a change in a jj-managed repo. For MULTI-agent parallel
  work use git worktrees (or jj workspaces) instead — see "jj vs worktrees" below.
---

# jj (jujutsu)

The user adopts the convention: **jj for single-agent work, worktrees for
multi-agent work.** They do NOT want to memorize jj commands — you drive jj
correctly on their behalf. Repos are **colocated** (jj on top of git), so `git`
and `gh` still work and GitHub/PRs are unchanged.

## Preflight (every session in a jj repo)

1. `command -v jj` — if missing, say so and fall back to plain git. Install:
   `cargo install --locked jj-cli` or `brew install jj` (mention, don't auto-run).
2. Detect a repo: `jj root` succeeds inside one. If a git repo isn't yet jj-managed
   and the user wants jj, run `jj git init --colocate` (keeps `.git`, adds jj on
   top; `--colocate` is the default in recent versions but pass it explicitly).

## Mental model (so you operate it correctly)

- **The working copy IS a commit**, addressed as `@`. There's no staging area and
  no "dirty tree" — every edit is auto-committed into `@` on the next `jj` command.
- **Changes are anonymous and rewritable.** A change keeps a stable change-ID even
  as you amend it. You freely edit history; jj records each rewrite (undoable).
- **Bookmarks ≈ git branches** — named pointers you attach to a change to push to
  GitHub. They do NOT auto-advance with `@`; you move/set them when ready to push.
- `@-` means "the parent of the working copy" (i.e. the change you just finished).

## The commands you'll actually use

| Goal | Command |
|------|---------|
| See state | `jj status` (alias `jj st`) |
| See history | `jj log` |
| Start a new change | `jj new` (fresh empty change on top of `@`) |
| Start off main | `jj new main` |
| Set/refine the message | `jj describe -m "feat: ..."` (describes `@`) |
| Finish change + start next | `jj commit -m "..."` (= describe `@` then `jj new`) |
| Move edits into parent | `jj squash` (or `jj squash -i` for hunks) |
| Edit an earlier change | `jj edit <change-id>` then make edits |
| Undo last operation | `jj undo` (or `jj op log` → `jj op restore <id>`) |
| Pull from remote | `jj git fetch` |
| Rebase onto updated main | `jj rebase -d main` (confirm the flag with `jj rebase --help` — destination flag naming has varied by version) |

Typical single-agent flow:
```
jj new main                      # start work
# ...edit files (auto-committed into @)...
jj describe -m "feat: add X"     # give @ a message
# ...keep editing; @ keeps updating...
```

## Pushing to GitHub (colocated repo)

A change needs a **bookmark** before it can be pushed as a branch:
```
jj bookmark create my-feature -r @     # name the current change
jj git push --bookmark my-feature      # push (force-pushes safely if rewritten)
```
Or let jj auto-name and push in one step:
```
jj git push -c @                       # -c/--change generates a bookmark + pushes
```
After pushing, open the PR with the existing tooling: `gh pr create`. To update an
existing branch after more edits, move the bookmark then push:
```
jj bookmark move my-feature --to @
jj git push --bookmark my-feature
```
The user's gh-bootstrap / branch-hygiene system still applies — squash-merge +
delete-on-merge are unchanged because the remote is plain git.

## jj vs worktrees (when to use which)

- **Single agent, one task at a time → jj.** Default. Anonymous changes + `jj undo`
  give cheap experimentation and a clean rewritable history.
- **Multiple agents in parallel → git worktrees** (the user's established habit,
  managed by their existing worktree/branch-hygiene tooling). Keep using those.
- **jj's own equivalent of worktrees is `jj workspace`** — multiple working copies
  backed by one repo, each with its own `@`. Use it when staying inside jj for
  parallel checkouts:
  ```
  jj workspace add ../repo-feature-x          # new working copy at that path
  jj workspace add --name fx ../repo-fx        # explicit name
  jj workspace list
  jj workspace forget <name>                   # then rm -rf the dir
  jj workspace update-stale                     # if another workspace moved a shared change
  ```
  Map of habits: `git worktree add` → `jj workspace add`; `git worktree remove` →
  `jj workspace forget` + delete the directory.

## Gotchas

- **Bookmarks don't follow `@`.** After more commits you must `jj bookmark move
  --to @` before pushing, or the remote branch lags behind.
- **No staging area.** Don't reach for `git add` / `git commit -p`; use `jj squash`
  / `jj squash -i` to shape what goes into a change.
- **Don't mix raw `git commit` with jj in the same repo.** Reading via git is fine;
  let jj own the commits. jj auto-syncs on each command, but manual git commits can
  surprise it (`jj` will import them as a new change).
- **`@` is never empty for long** — running almost any `jj` command snapshots the
  working copy first, so "uncommitted changes" effectively don't exist.
- **`update-stale`**: if a workspace shows a stale working copy, run
  `jj workspace update-stale` rather than fighting it.
- **Conflicts are first-class** — jj records conflicts in a commit instead of
  blocking. Resolve in the working copy, then `jj squash`/continue; nothing aborts.
- **Version drift**: exact flags (`rebase -d`, `--colocate` default) vary by jj
  version. When unsure, `jj <cmd> --help` is authoritative.
