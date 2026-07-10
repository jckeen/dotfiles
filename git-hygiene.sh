#!/usr/bin/env bash
# git-hygiene — multi-repo branch hygiene audit and cleanup
#
# Usage:
#   git-hygiene audit [DIR]    # report only, no changes (default: ~/dev)
#   git-hygiene clean [DIR]    # safe automatic cleanup
#   git-hygiene clean --yes    # don't prompt before deleting branches
#
# What "safe cleanup" does:
#   1. git fetch --prune        (drops stale remote-tracking refs)
#   2. git remote set-head origin -a  (sets origin/HEAD if missing)
#   3. For each non-default local branch: delete IF
#        a) cherry vs origin/<default> shows all '-' (patch-equivalent), OR
#        b) every commit's subject is found in origin/<default>'s history
#           (catches squash-merged branches that cherry misses), OR
#        c) the branch's PR is MERGED on GitHub (via gh)
#   4. Never touches: dirty working trees, current branch, branches checked
#      out in worktrees, branches with unique unmerged work.
#
# Notes:
#   - Deleted branch SHAs are kept in `git reflog` for ~90 days (recoverable).
#   - Requires: git, gh (optional but recommended for PR-based detection).

set -euo pipefail

MODE=""
ROOT=""
ASSUME_YES=false

usage() { echo "Usage: $(basename "$0") [audit|clean] [DIR] [--yes]"; }

# Duplicate positionals are rejected rather than last-wins: a second mode token
# must not silently escalate audit→clean, and a second DIR must not silently
# replace the first. A dir literally named audit/clean stays reachable as ./audit.
while [[ $# -gt 0 ]]; do
  case "$1" in
    audit|clean)
      [[ -n "$MODE" ]] && { echo "error: mode already set to '$MODE': $1" >&2; usage >&2; exit 1; }
      MODE="$1" ;;
    --yes)       ASSUME_YES=true ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      [[ -n "$ROOT" ]] && { echo "error: DIR already set to '$ROOT': $1" >&2; usage >&2; exit 1; }
      ROOT="$1" ;;
  esac
  shift
done
MODE="${MODE:-audit}"
ROOT="${ROOT:-$HOME/dev}"

# A ROOT that doesn't exist would silently scan zero repos (#196) — fail loudly.
[[ -d "$ROOT" ]] || { echo "error: no such directory: $ROOT" >&2; usage >&2; exit 1; }

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'

ok()    { echo "${c_green}✓${c_reset} $*"; }
warn()  { echo "${c_yellow}⚠${c_reset} $*"; }
fail()  { echo "${c_red}✗${c_reset} $*"; }
info()  { echo "${c_blue}ℹ${c_reset} $*"; }
dim()   { echo "${c_dim}$*${c_reset}"; }

confirm() {
  $ASSUME_YES && return 0
  read -r -p "  $1 [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

# Returns 0 if branch is safe to delete, 1 otherwise. Sets REASON.
is_branch_safely_merged() {
  local repo="$1" br="$2" default="$3"
  REASON=""

  # Cherry: '-' = patch-equivalent on default, '+' = unique
  local cherry_unique
  cherry_unique=$(git -C "$repo" cherry "origin/$default" "$br" 2>/dev/null | grep -c '^+' || true)
  if [[ "$cherry_unique" == "0" ]]; then
    REASON="cherry-equivalent to origin/$default"
    return 0
  fi

  # Subject-search: each unique commit's subject must appear in origin/<default>
  # history. Read the default-branch subjects ONCE — the previous version re-ran
  # `git log origin/<default>` for every unique commit, re-walking the entire
  # default history per commit (O(branch_commits × default_commits)).
  local default_subjects
  default_subjects=$(git -C "$repo" log --format='%s' "origin/$default" 2>/dev/null || true)
  local missing=0 total=0
  while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    total=$((total + 1))
    # Match on the first 40 chars: squash-merge appends " (#NN)", so a prefix
    # match catches the commit even after the PR suffix is added.
    if ! printf '%s\n' "$default_subjects" | grep -qF "$(printf '%s' "$subject" | head -c 40)"; then
      missing=$((missing + 1))
    fi
  done < <(git -C "$repo" log --format='%s' "origin/$default..$br" 2>/dev/null)

  if [[ "$total" -gt 0 && "$missing" -eq 0 ]]; then
    REASON="all $total commit subjects found on origin/$default (squash-merged)"
    return 0
  fi

  # PR check via gh
  if command -v gh >/dev/null 2>&1; then
    local pr_state
    # Extract owner/repo from the origin URL, tolerating both SSH and HTTPS forms
    # with or without a trailing .git (the prior single-stage sed dropped the
    # slug when .git was absent).
    local slug
    slug=$(git -C "$repo" remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')
    pr_state=$(gh -R "$slug" \
               pr list --state all --head "$br" --json state --jq '.[0].state' 2>/dev/null || echo "")
    if [[ "$pr_state" == "MERGED" ]]; then
      REASON="PR is MERGED on GitHub"
      return 0
    fi
  fi

  REASON="$cherry_unique unique patch(es) not found on origin/$default — keep"
  return 1
}

audit_repo() {
  local d="$1"
  local repo
  repo=$(basename "$d")
  # Guard the cd: under set -e a failed cd would abort the entire multi-repo
  # run instead of just skipping this one directory.
  cd "$d" || { dim "  $repo — cannot enter directory"; return; }
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    dim "  $repo — not a git repo"
    return
  fi
  if [[ -z "$(git remote get-url origin 2>/dev/null || true)" ]]; then
    dim "  $repo — no remote 'origin'"
    return
  fi

  local default current dirty extras=0
  default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo "")
  current=$(git branch --show-current 2>/dev/null || echo "(detached)")
  dirty=$(git status --porcelain | wc -l)

  echo "${c_blue}┌── $repo${c_reset}  ${c_dim}(on $current; default: ${default:-?})${c_reset}"

  if [[ -z "$default" ]]; then
    if [[ "$MODE" == "clean" ]]; then
      git remote set-head origin -a >/dev/null 2>&1 && ok "set origin/HEAD"
      default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo "")
    else
      warn "origin/HEAD not set — run \`git remote set-head origin -a\`"
    fi
  fi

  if [[ "$MODE" == "clean" ]]; then
    local pruned
    pruned=$(git fetch --prune origin 2>&1 | grep -c '\[deleted\]' || true)
    [[ "$pruned" -gt 0 ]] && ok "pruned $pruned stale remote-tracking refs"
  fi

  if [[ "$dirty" -gt 0 ]]; then
    warn "$dirty dirty/untracked file(s) — leaving as-is"
  fi

  # Iterate non-default branches
  while IFS= read -r br; do
    [[ "$br" == "$default" || -z "$br" ]] && continue
    extras=$((extras + 1))

    # Skip current branch and worktrees
    if [[ "$br" == "$current" ]]; then
      info "$br (current) — skipped"
      continue
    fi
    if git worktree list --porcelain | grep -q "^branch refs/heads/$br$"; then
      info "$br (in worktree) — skipped"
      continue
    fi

    if [[ -z "$default" ]]; then
      warn "$br — cannot evaluate (no default branch)"
      continue
    fi

    if is_branch_safely_merged "$d" "$br" "$default"; then
      if [[ "$MODE" == "clean" ]]; then
        if confirm "delete $br ($REASON)?"; then
          local sha
          sha=$(git rev-parse --short "$br")
          git branch -D "$br" >/dev/null 2>&1
          ok "deleted $br ${c_dim}(was $sha — $REASON)${c_reset}"
        else
          info "$br — kept by user"
        fi
      else
        ok "$br — safely deletable: $REASON"
      fi
    else
      warn "$br — has unique work: $REASON"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  [[ "$extras" -eq 0 ]] && ok "no extra local branches"
  echo
}

main() {
  local repo_count=0
  echo "${c_blue}━━━ git-hygiene ${MODE} ━━━${c_reset}  ${c_dim}root: $ROOT${c_reset}"
  echo
  for d in "$ROOT"/*/; do
    [[ -d "$d/.git" || -f "$d/.git" ]] || continue
    audit_repo "$d"
    repo_count=$((repo_count + 1))
  done
  echo "${c_blue}━━━ scanned $repo_count repos ━━━${c_reset}"
}

main
