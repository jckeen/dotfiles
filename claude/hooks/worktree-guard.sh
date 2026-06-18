#!/usr/bin/env bash
# PreToolUse(Bash) worktree guard.
#
# Prevents the "two sessions sharing one checkout" collision: when a parallel
# session has worktrees open, creating or switching a branch in the PRIMARY
# checkout switches the shared working tree out from under the other session
# (this is exactly what happened on 2026-06-18 — a `git checkout -b` in the
# shared tree stranded another session's commits).
#
# Policy (smart / contention-gated):
#   - Always allow `git worktree ...` (that's the fix, not the problem).
#   - Only inspect branch CREATE/SWITCH ops (`checkout -b/-B`, any `git switch`).
#   - Allow freely when run from a linked worktree (.../worktrees/<name>).
#   - In the PRIMARY checkout, DENY only when >1 worktree exists (a parallel
#     session is likely active). Solo work (1 worktree) is never blocked.
#
# Fail-open: any error or unexpected state exits 0 (allow), so a broken guard
# never wedges git.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

# `git worktree ...` is always allowed — it's how you comply.
printf '%s' "$CMD" | grep -qE 'git[[:space:]].*worktree' && exit 0

# Only branch create/switch ops are interesting. `git switch` is always a
# branch op; `checkout -b/-B` creates one. Bare legacy `git checkout <branch>`
# is intentionally NOT matched (ambiguous with file checkout — low value,
# high false-positive). Anything else: allow.
printf '%s' "$CMD" | grep -qE 'git[[:space:]].*(checkout[[:space:]]+-[bB]|switch[[:space:]])' || exit 0

# Linked worktree? Its git dir lives under .../worktrees/<name>. Allow.
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$gitdir" in */worktrees/*) exit 0 ;; esac

# Primary checkout. Only guard when another worktree exists (contention).
wt=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "${wt:-1}" -le 1 ] && exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
reason="Worktree guard: you're in the PRIMARY checkout and ${wt} worktrees exist — another session may be active, and creating/switching a branch here can switch it out from under them. Work in an isolated worktree instead:  git worktree add ../$(basename "$root")-<branch> -b <branch>  then cd there. ('git worktree add' is always allowed; branch ops inside any linked worktree are never blocked.)"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
