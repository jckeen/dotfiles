#!/usr/bin/env bash
# gh-bootstrap — apply standard auto-hygiene settings to GitHub repos
#
# Usage:
#   gh-bootstrap                        # apply to repo of cwd
#   gh-bootstrap owner/repo             # apply to one named repo
#   gh-bootstrap --all DIR              # apply to every git repo in DIR
#   gh-bootstrap --check                # report drift, no changes (cwd)
#   gh-bootstrap --check --all DIR      # report drift across all repos in DIR
#   gh-bootstrap --check owner/repo     # report drift for one named repo
#
# Settings applied (idempotent):
#   delete_branch_on_merge       = true  # auto-delete branch on PR merge
#   allow_auto_merge             = true  # `gh pr merge --auto` (requires GH Pro on private)
#   allow_update_branch          = true  # UI button to fast-forward PR branch
#   allow_squash_merge           = true  # squash is the only merge style
#   allow_merge_commit           = false
#   allow_rebase_merge           = false
#   squash_merge_commit_title    = PR_TITLE
#   squash_merge_commit_message  = PR_BODY
#
# Requires: gh (authenticated as a user with admin access on the repo).

set -euo pipefail

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
ok()    { echo "${c_green}✓${c_reset} $*"; }
warn()  { echo "${c_yellow}⚠${c_reset} $*"; }
fail()  { echo "${c_red}✗${c_reset} $*"; }
info()  { echo "${c_blue}ℹ${c_reset} $*"; }
dim()   { echo "${c_dim}$*${c_reset}"; }

# Desired state — single source of truth
declare -ra FIELDS=(
  delete_branch_on_merge
  allow_auto_merge
  allow_update_branch
  allow_squash_merge
  allow_merge_commit
  allow_rebase_merge
  squash_merge_commit_title
  squash_merge_commit_message
)
declare -rA DESIRED=(
  [delete_branch_on_merge]=true
  [allow_auto_merge]=true
  [allow_update_branch]=true
  [allow_squash_merge]=true
  [allow_merge_commit]=false
  [allow_rebase_merge]=false
  [squash_merge_commit_title]=PR_TITLE
  [squash_merge_commit_message]=PR_BODY
)

require_gh() {
  command -v gh >/dev/null 2>&1 || { fail "gh CLI not installed"; exit 2; }
  gh auth status >/dev/null 2>&1 || { fail "gh not authenticated — run 'gh auth login'"; exit 2; }
}

# Resolve owner/repo from a directory's origin remote, or echo input as-is
resolve_repo() {
  local arg="$1"
  if [[ "$arg" == */* && "$arg" != /* && "$arg" != ./* ]]; then
    echo "$arg"
    return 0
  fi
  local url
  url=$(git -C "$arg" remote get-url origin 2>/dev/null || true)
  [[ -z "$url" ]] && return 1
  # https://github.com/owner/repo.git  OR  git@github.com:owner/repo.git
  echo "$url" | sed -E 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|; s|.*[:/]([^/:]+/[^/]+)$|\1|'
}

# Read current state — emit one "key=value" line per field
# Returns 0 on success, 99 on error (cannot read).
read_state() {
  local repo="$1"
  local jq_filter
  # Build ".field1, .field2, ..." for jq array literal
  jq_filter=$(printf '.%s, ' "${FIELDS[@]}" | sed 's/, $//')
  local raw
  if ! raw=$(gh api "repos/$repo" --jq "[$jq_filter] | @tsv" 2>/dev/null); then
    return 99
  fi
  awk -v fields="${FIELDS[*]}" -F'\t' '
    BEGIN { n = split(fields, F, " ") }
    { for (i=1; i<=n; i++) print F[i] "=" $i }
  ' <<< "$raw"
}

# Compute drift — print TSV "field<TAB>current<TAB>desired" per mismatch.
# Returns 0 if clean, drift-count if drifted, 99 if cannot read.
compute_drift() {
  local repo="$1"
  local state
  if ! state=$(read_state "$repo"); then
    return 99
  fi
  local drift=0
  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    local want="${DESIRED[$k]}"
    if [[ "$v" != "$want" ]]; then
      printf '%s\t%s\t%s\n' "$k" "$v" "$want"
      drift=$((drift + 1))
    fi
  done <<< "$state"
  return $drift
}

apply_repo() {
  local repo="$1"
  echo "${c_blue}┌── $repo${c_reset}"

  # Build the gh api flags from desired state
  local args=()
  for f in "${FIELDS[@]}"; do
    args+=( -f "$f=${DESIRED[$f]}" )
  done

  if ! gh api -X PATCH "repos/$repo" "${args[@]}" --silent 2>/tmp/gh-bootstrap-err.$$; then
    fail "PATCH failed: $(cat /tmp/gh-bootstrap-err.$$ 2>/dev/null | head -1)"
    rm -f /tmp/gh-bootstrap-err.$$
    return 1
  fi
  rm -f /tmp/gh-bootstrap-err.$$

  # Verify
  local out drift
  out=$(compute_drift "$repo") && drift=0 || drift=$?
  if [[ "$drift" == "0" ]]; then
    ok "all 8 settings applied"
  elif [[ "$drift" == "99" ]]; then
    fail "PATCH succeeded but cannot re-read settings"
    return 1
  else
    fail "drift remains after PATCH:"
    echo "$out" | awk -F'\t' '{printf "    %s: %s → %s\n", $1, $2, $3}'
    return 1
  fi
}

check_repo() {
  local repo="$1"
  local out drift
  out=$(compute_drift "$repo") && drift=0 || drift=$?
  if [[ "$drift" == "99" ]]; then
    fail "$repo — cannot read settings (no access or not a real repo?)"
    return 1
  fi
  # If all 8 fields drift with empty current values, user lacks admin access (e.g., a fork upstream)
  if [[ "$drift" == "8" ]] && ! echo "$out" | awk -F'\t' '{print $2}' | grep -q '[a-zA-Z]'; then
    info "$repo — skipped (no admin access, likely an upstream fork)"
    return 0
  fi
  if [[ "$drift" == "0" ]]; then
    ok "$repo — clean"
  else
    warn "$repo — $drift drift:"
    echo "$out" | awk -F'\t' '{printf "    %s: %s → %s\n", $1, $2, $3}'
  fi
}

main() {
  require_gh

  local mode=apply
  local target=""
  local all_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) mode=check; shift ;;
      --all)   all_dir="${2:?--all needs a directory}"; shift 2 ;;
      -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)       target="$1"; shift ;;
    esac
  done

  # Build target list
  local -a repos=()
  if [[ -n "$all_dir" ]]; then
    for d in "$all_dir"/*/; do
      [[ -d "$d/.git" || -f "$d/.git" ]] || continue
      local r
      r=$(resolve_repo "$d") || continue
      [[ -n "$r" ]] && repos+=("$r")
    done
  elif [[ -n "$target" ]]; then
    local r
    r=$(resolve_repo "$target") || { fail "could not resolve $target"; exit 1; }
    repos+=("$r")
  else
    local r
    r=$(resolve_repo ".") || { fail "cwd is not a git repo with origin remote"; exit 1; }
    repos+=("$r")
  fi

  local count=${#repos[@]}
  local fn="$mode"_repo
  echo "${c_blue}━━━ gh-bootstrap $mode ━━━${c_reset}  ${c_dim}$count repo(s)${c_reset}"
  echo

  local failed=0
  for r in "${repos[@]}"; do
    if ! "$fn" "$r"; then
      failed=$((failed + 1))
    fi
  done

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo "${c_green}━━━ all $count repo(s) succeeded ━━━${c_reset}"
  else
    echo "${c_red}━━━ $failed of $count repo(s) failed ━━━${c_reset}"
    exit 1
  fi
}

main "$@"
