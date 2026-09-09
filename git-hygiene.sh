#!/usr/bin/env bash
# git-hygiene — multi-repo branch hygiene audit and cleanup
#
# Usage:
#   git-hygiene audit [DIR]                       # report only (default DIR: ~/dev)
#   git-hygiene clean [DIR] [--yes] [--dry-run]   # heuristic cleanup (below)
#   git-hygiene prune [DIR] [--yes] [--gh] [--dry-run]
#                                                 # strict "safely dead" cleanup —
#                                                 # what the daily timer runs
#
# Flags:
#   --yes       don't prompt before deleting a branch
#   --dry-run   print "would delete" lines; write nothing — no branch deletion,
#               no `fetch --prune`, no `remote set-head` (see Notes)
#   --gh        prune only: also delete a squash-merged branch when GitHub
#               confirms a MERGED PR into the default branch whose head ref is
#               the branch AND whose head SHA is the local tip (or a
#               locally-present descendant of it). Needs `gh auth status` to
#               pass; any gh error keeps the branch (fail closed).
#
# What "clean" does (heuristic — squash-merge detection by commit subject):
#   1. git fetch --prune        (drops stale remote-tracking refs)
#   2. git remote set-head origin -a  (sets origin/HEAD if missing)
#   3. For each non-default local branch: delete IF
#        a) cherry vs origin/<default> shows all '-' (patch-equivalent), OR
#        b) every commit's subject is found in origin/<default>'s history
#           (catches squash-merged branches that cherry misses), OR
#        c) the branch's PR into origin/<default> is MERGED on GitHub (via gh)
#   4. Never touches: dirty working trees, current branch, branches checked
#      out in worktrees, branches with unique unmerged work.
#
# What "prune" deletes — the SAFE class, evaluated per branch after the same
# fetch --prune / set-head steps:
#   never:  the default branch, the checked-out branch, a worktree's branch,
#           or anything touched (commit or ref update) within the last
#           HYGIENE_MIN_AGE_HOURS (default 24).
#   delete: merged into origin/<default>, or no unique merge commits and
#           no unique patches (`git cherry` shows no '+'),
#           reported as "merged into", "upstream gone" or "cherry-equivalent";
#     or, with --gh: upstream gone (or never set) AND a PR merged INTO THE
#           DEFAULT BRANCH on GitHub has this branch as head ref and the local
#           tip as its head SHA (or as an ancestor of a head SHA present
#           locally). A PR merged into a release/feature branch that never
#           reached the default does not count.
#   A squash-merged branch with unique commits and no confirming PR is kept —
#   subject matching is a heuristic, and prune runs unattended.
#
# Env:
#   HYGIENE_MIN_AGE_HOURS   prune's "recently touched" window (default 24)
#   HYGIENE_REPORT=FILE     append "repo<TAB>branch<TAB>sha<TAB>reason" per
#                           deletion (the timer turns this into a summary)
#
# Notes:
#   - Every deletion prints the full SHA and a recovery command; the SHA also
#     lives in `git reflog` for ~90 days.
#   - --dry-run leaves scanned repositories unchanged. Remote evidence is
#     fetched into a temporary shared bare clone, discarded at exit; source
#     branch activity and worktree protections still apply. A failed fetch or
#     unavailable default branch keeps every branch in that repository.
#   - Requires: git, gh (optional; used by clean's check (c) and prune --gh).

set -euo pipefail

MODE=""
ROOT=""
ASSUME_YES=false
DRY_RUN=false
GH_CHECK=false
GH_OK=false
MIN_AGE_HOURS="${HYGIENE_MIN_AGE_HOURS:-24}"
REPORT_FILE="${HYGIENE_REPORT:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [audit|clean|prune] [DIR] [--yes] [--dry-run] [--gh]
  audit   report only (default)
  clean   heuristic cleanup: cherry-equivalent, subject-matched squash merges, merged PRs
  prune   strict cleanup: no unique commits (or --gh: a merged PR carries this tip),
          untouched for HYGIENE_MIN_AGE_HOURS (24); never default/current/worktree branches
  --yes      no prompt
  --dry-run  write nothing: no deletions, no fetch --prune, no remote set-head
  --gh       prune only: also delete when a PR into the default branch merged with this tip
EOF
}

# Duplicate positionals are rejected rather than last-wins: a second mode token
# must not silently escalate audit→clean, and a second DIR must not silently
# replace the first. A dir literally named audit/clean stays reachable as ./audit.
while [[ $# -gt 0 ]]; do
  case "$1" in
    audit|clean|prune)
      [[ -n "$MODE" ]] && { echo "error: mode already set to '$MODE': $1" >&2; usage >&2; exit 1; }
      MODE="$1" ;;
    --yes)       ASSUME_YES=true ;;
    --dry-run)   DRY_RUN=true ;;
    --gh)        GH_CHECK=true ;;
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
ROOT="$(cd "$ROOT" && pwd -P)"
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || { echo "error: HYGIENE_MIN_AGE_HOURS must be an integer: $MIN_AGE_HOURS" >&2; exit 1; }
if $GH_CHECK && [[ "$MODE" != "prune" ]]; then
  echo "error: --gh only applies to prune" >&2; usage >&2; exit 1
fi

# Colors only on a terminal — the timer's log and the tests read plain text.
if [[ -t 1 ]]; then
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
else
  c_red=""; c_green=""; c_yellow=""; c_blue=""; c_dim=""; c_reset=""
fi

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

# The GitHub check is opt-in and gated on a working login; without one it is
# reported once and skipped, never silently attempted.
if $GH_CHECK; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GH_OK=true
  else
    warn "--gh: gh missing or not authenticated — merged-PR check disabled, squash-merged branches are kept"
  fi
fi

origin_slug() {
  # owner/repo from the origin URL, tolerating SSH and HTTPS forms with or
  # without a trailing .git (a single-stage sed dropped the slug when .git was
  # absent).
  git -C "$1" remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#'
}

# Returns 0 if branch is safe to delete, 1 otherwise. Sets REASON.
is_branch_safely_merged() {
  local repo="$1" br="$2" default="$3" evidence="${4:-$1}"
  REASON=""

  # Cherry: '-' = patch-equivalent on default, '+' = unique
  local cherry_unique
  cherry_unique=$(git -C "$evidence" cherry "origin/$default" "$br" 2>/dev/null | grep -c '^+' || true)
  if [[ "$cherry_unique" == "0" ]]; then
    REASON="cherry-equivalent to origin/$default"
    return 0
  fi

  # Subject-search: each unique commit's subject must appear in origin/<default>
  # history. Read the default-branch subjects ONCE — the previous version re-ran
  # `git log origin/<default>` for every unique commit, re-walking the entire
  # default history per commit (O(branch_commits × default_commits)).
  local default_subjects
  default_subjects=$(git -C "$evidence" log --format='%s' "origin/$default" 2>/dev/null || true)
  local missing=0 total=0
  while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    total=$((total + 1))
    # Match on the first 40 chars: squash-merge appends " (#NN)", so a prefix
    # match catches the commit even after the PR suffix is added.
    if ! printf '%s\n' "$default_subjects" | grep -qF "$(printf '%s' "$subject" | head -c 40)"; then
      missing=$((missing + 1))
    fi
  done < <(git -C "$evidence" log --format='%s' "origin/$default..$br" 2>/dev/null)

  if [[ "$total" -gt 0 && "$missing" -eq 0 ]]; then
    REASON="all $total commit subjects found on origin/$default (squash-merged)"
    return 0
  fi

  # PR check via gh
  if command -v gh >/dev/null 2>&1; then
    local pr_state
    pr_state=$(gh -R "$(origin_slug "$repo")" \
               pr list --state all --head "$br" --base "$default" --json state --jq '.[0].state' 2>/dev/null || echo "")
    if [[ "$pr_state" == "MERGED" ]]; then
      REASON="PR into $default is MERGED on GitHub"
      return 0
    fi
  fi

  REASON="$cherry_unique unique patch(es) not found on origin/$default — keep"
  return 1
}

# Epoch of the branch's newest activity: tip committer date or latest reflog
# entry, whichever is later — a fresh `git branch` off an old commit is still
# a fresh branch.
branch_last_touched() {
  local repo="$1" br="$2" commit_t reflog_t
  commit_t=$(git -C "$repo" log -1 --format=%ct "refs/heads/$br" 2>/dev/null) || return 1
  reflog_t=$(git -C "$repo" log -g -1 --date=unix --format=%gd "refs/heads/$br" 2>/dev/null \
             | sed -nE 's/.*@\{([0-9]+)\}$/\1/p') || return 1
  [[ "$commit_t" =~ ^[0-9]+$ && "$reflog_t" =~ ^[0-9]+$ ]] || return 1
  echo $(( commit_t > reflog_t ? commit_t : reflog_t ))
}

# Returns 0 when GitHub confirms a PR merged into the default branch whose head
# is this branch and whose head SHA is this tip — or a descendant of it that is
# present locally (the PR was rebased or extended after this checkout last
# fetched it). A name match alone is not enough: local commits the PR never
# carried must survive. The base filter matters too: a PR merged into a
# release/feature branch has not reached the default, so its work is not yet
# on origin/<default> and the branch must stay. Any gh failure returns 1
# (keep). Sets GH_REASON.
gh_confirms_merged() {
  local repo="$1" br="$2" tip="$3" default="$4" evidence="${5:-$1}" out line num head
  GH_REASON=""
  out=$(gh -R "$(origin_slug "$repo")" pr list --state merged --head "$br" --base "$default" --limit 10 \
          --json number,headRefOid --jq '.[] | "\(.number) \(.headRefOid)"' 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^([0-9]+)\ ([0-9a-f]{40})$ ]] || continue
    num="${BASH_REMATCH[1]}" head="${BASH_REMATCH[2]}"
    if [[ "$head" == "$tip" ]]; then
      GH_REASON="PR #$num merged into $default on GitHub with this exact tip"
      return 0
    fi
    if git -C "$evidence" cat-file -e "$head^{commit}" 2>/dev/null \
       && git -C "$evidence" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
      GH_REASON="PR #$num merged into $default on GitHub; local tip is an ancestor of its head ${head:0:7}"
      return 0
    fi
  done <<< "$out"
  return 1
}

# Returns 0 if the branch is in prune's SAFE class, 1 otherwise. Sets REASON.
is_branch_safely_dead() {
  local repo="$1" br="$2" default="$3" evidence="${4:-$1}"
  REASON=""

  # `git cherry` against a missing ref prints nothing, which would read as
  # "no unique commits" — refuse to evaluate without the remote-tracking ref.
  if ! git -C "$evidence" rev-parse --verify -q "refs/remotes/origin/$default" >/dev/null 2>&1; then
    REASON="origin/$default not fetched — cannot evaluate, keep"
    return 1
  fi

  local now touched age_h
  now=$(date +%s)
  if ! touched=$(branch_last_touched "$repo" "$br"); then
    REASON="activity unavailable — cannot establish branch age, keep"
    return 1
  fi
  age_h=$(( (now - touched) / 3600 ))
  if (( now - touched < MIN_AGE_HOURS * 3600 )); then
    REASON="touched ${age_h}h ago (< ${MIN_AGE_HOURS}h) — keep"
    return 1
  fi

  local upstream
  upstream=$(git -C "$repo" for-each-ref --format='%(upstream)' "refs/heads/$br")
  local gone=false
  if [[ -n "$upstream" ]] && ! git -C "$evidence" show-ref --verify -q "$upstream"; then
    gone=true
  fi

  if git -C "$evidence" merge-base --is-ancestor "$br" "origin/$default" 2>/dev/null; then
    REASON="merged into origin/$default"
    return 0
  fi

  # git cherry omits merges, including unique conflict-resolution changes.
  local merges cherry cherry_unique
  if ! merges=$(git -C "$evidence" rev-list --merges "origin/$default..$br" 2>/dev/null); then
    REASON="merge history unavailable — keep"
    return 1
  fi
  if [[ -n "$merges" ]]; then
    REASON="unique merge commits not on origin/$default — keep"
    return 1
  fi
  if ! cherry=$(git -C "$evidence" cherry "origin/$default" "$br" 2>/dev/null); then
    REASON="patch history unavailable — keep"
    return 1
  fi
  cherry_unique=$(grep -c '^+' <<<"$cherry" || true)
  if [[ "$cherry_unique" == "0" ]]; then
    if $gone; then
      REASON="upstream gone, cherry-equivalent to origin/$default"
    else
      REASON="cherry-equivalent to origin/$default"
    fi
    return 0
  fi

  # Squash-merged shape: unique commits, remote branch deleted (or never
  # pushed with -u). Only GitHub can confirm; a still-present upstream means
  # the branch is alive on the remote and is never a prune candidate.
  if $GH_OK && { $gone || [[ -z "$upstream" ]]; }; then
    local tip
    tip=$(git -C "$repo" rev-parse "refs/heads/$br")
    if gh_confirms_merged "$repo" "$br" "$tip" "$default" "$evidence"; then
      REASON="$GH_REASON"
      return 0
    fi
  fi

  if $gone; then
    REASON="upstream gone but $cherry_unique unique patch(es) — squash-merged? keep"
  else
    REASON="$cherry_unique unique patch(es) not on origin/$default — keep"
  fi
  return 1
}

delete_branch() {
  local d="$1" repo="$2" br="$3"
  local sha
  sha=$(git -C "$d" rev-parse "refs/heads/$br")
  if $DRY_RUN; then
    info "would delete $br ${c_dim}(at $sha — $REASON)${c_reset} [dry-run]"
    return 0
  fi
  if confirm "delete $br ($REASON)?"; then
    if ! git -C "$d" branch -D "$br" >/dev/null 2>&1; then
      fail "$br — git branch -D failed; kept"
      return 0
    fi
    ok "deleted $br ${c_dim}(was $sha — $REASON; recover: git branch $br $sha)${c_reset}"
    if [[ -n "$REPORT_FILE" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$repo" "$br" "$sha" "$REASON" >> "$REPORT_FILE"
    fi
  else
    info "$br — kept by user"
  fi
}

audit_repo() (
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
  dirty=$(git --no-optional-locks status --porcelain --untracked-files=all --ignore-submodules=none | wc -l)

  echo "${c_blue}┌── $repo${c_reset}  ${c_dim}(on $current; default: ${default:-?})${c_reset}"

  if [[ "$dirty" -gt 0 ]]; then
    warn "$dirty dirty/untracked file(s) — leaving as-is"
    return 0
  fi

  local evidence="$d" scratch="" fetched pruned old_default="$default"
  if [[ "$MODE" == "audit" ]]; then
    [[ -n "$default" ]] || warn "origin/HEAD not set — run \`git remote set-head origin -a\`"
  else
    if $DRY_RUN; then
      scratch=$(mktemp -d)
      trap 'rm -rf -- "$scratch"' EXIT
      evidence="$scratch/evidence.git"
      if ! git clone -q --mirror --shared "$d" "$evidence" 2>/dev/null; then
        warn "cannot snapshot repository — branches kept"
        return 0
      fi
      local url refspec
      url=$(git remote get-url origin)
      [[ "$url" == /* || "$url" == *:* ]] || url="$d/$url"
      git -C "$evidence" remote set-url origin "$url"
      git -C "$evidence" config remote.origin.mirror false
      git -C "$evidence" config --unset-all remote.origin.fetch
      while IFS= read -r refspec; do
        git -C "$evidence" config --add remote.origin.fetch "$refspec"
      done < <(git config --get-all remote.origin.fetch)
    fi
    if ! fetched=$(git -C "$evidence" -c remote.origin.followRemoteHEAD=never fetch --prune origin 2>&1); then
      warn "fetch failed — skipping repository; branches kept"
      return 0
    fi
    pruned=$(grep -c '\[deleted\]' <<<"$fetched" || true)
    if [[ "$pruned" -gt 0 ]]; then
      if $DRY_RUN; then
        info "would prune $pruned stale remote-tracking ref(s) [dry-run]"
      else
        ok "pruned $pruned stale remote-tracking refs"
      fi
    fi
    if ! git -C "$evidence" remote set-head origin -a >/dev/null 2>&1; then
      warn "remote default unavailable — skipping repository; branches kept"
      return 0
    fi
    default=$(git -C "$evidence" symbolic-ref --short refs/remotes/origin/HEAD | sed 's|origin/||')
    if [[ "$default" != "$old_default" ]]; then
      if $DRY_RUN; then
        info "would set origin/HEAD -> $default [dry-run]"
      else
        ok "set origin/HEAD -> $default"
      fi
    fi
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
    if git worktree list --porcelain | grep -qxF "branch refs/heads/$br"; then
      info "$br (in worktree) — skipped"
      continue
    fi

    if [[ -z "$default" ]]; then
      warn "$br — cannot evaluate (no default branch)"
      continue
    fi

    case "$MODE" in
      prune)
        if is_branch_safely_dead "$d" "$br" "$default" "$evidence"; then
          delete_branch "$d" "$repo" "$br"
        else
          info "$br — kept: $REASON"
        fi ;;
      clean)
        if is_branch_safely_merged "$d" "$br" "$default" "$evidence"; then
          delete_branch "$d" "$repo" "$br"
        else
          warn "$br — has unique work: $REASON"
        fi ;;
      *)
        if is_branch_safely_merged "$d" "$br" "$default" "$evidence"; then
          ok "$br — safely deletable: $REASON"
        else
          warn "$br — has unique work: $REASON"
        fi ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  [[ "$extras" -eq 0 ]] && ok "no extra local branches"
  echo
)

main() {
  local repo_count=0
  local banner="$MODE"
  $DRY_RUN && banner="$MODE (dry-run)"
  echo "${c_blue}━━━ git-hygiene ${banner} ━━━${c_reset}  ${c_dim}root: $ROOT${c_reset}"
  echo
  for d in "$ROOT"/*/; do
    [[ -d "$d/.git" || -f "$d/.git" ]] || continue
    audit_repo "$d"
    repo_count=$((repo_count + 1))
  done
  echo "${c_blue}━━━ scanned $repo_count repos ━━━${c_reset}"
}

main
