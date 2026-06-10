#!/usr/bin/env bash
# check-commit-format.sh — server-side conventional-commit lint for PR commits.
#
# The conventional-commit.sh PreToolUse hook enforces format only inside a Claude
# session — `git commit --no-verify`, a commit made outside Claude, or any other
# tool bypasses it entirely. This script is the backstop the hook can't be: a CI
# gate over the commits a PR actually adds, so malformed history can't reach main.
#
# Validates each commit subject against:  type(scope)?!?: description
#   type ∈ feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert
# Merge commits and revert auto-messages are skipped.
#
# Usage:
#   check-commit-format.sh                 # lint origin/main..HEAD (best-effort)
#   check-commit-format.sh <base>..<head>  # explicit range (CI passes this)
#   check-commit-format.sh <base> <head>   # two-arg form

set -euo pipefail

TYPES='feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert'
# type, optional (scope), optional !, ": ", then a non-empty description.
SUBJECT_RE="^(${TYPES})(\([a-z0-9._/-]+\))?!?: .+"

# --- Resolve the commit range ---------------------------------
if [[ $# -eq 2 ]]; then
  RANGE="$1..$2"
elif [[ $# -eq 1 ]]; then
  RANGE="$1"
else
  base="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [[ -z "$base" ]] && base="main"
  if git rev-parse --verify --quiet "origin/$base" >/dev/null; then
    RANGE="origin/$base..HEAD"
  elif git rev-parse --verify --quiet "$base" >/dev/null; then
    RANGE="$base..HEAD"
  else
    echo "check-commit-format: no base branch found; linting HEAD only." >&2
    RANGE="HEAD~1..HEAD"
  fi
fi

# --- Collect commit hashes in the range -----------------------
# Fail CLOSED: if the range can't be resolved (bad SHA, shallow checkout, ref
# fetch failure), git rev-list errors — we must NOT swallow that into an empty
# "nothing to lint" pass, or a CI checkout glitch would silently disable the gate.
set +e
commits_raw="$(git rev-list --no-merges "$RANGE" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "✖ check-commit-format: cannot resolve range '$RANGE' — failing closed." >&2
  echo "  git: $commits_raw" >&2
  exit 1
fi
mapfile -t commits < <(printf '%s\n' "$commits_raw" | grep -v '^[[:space:]]*$' || true)
if [[ "${#commits[@]}" -eq 0 ]]; then
  echo "check-commit-format: no commits in range ($RANGE) — nothing to lint."
  exit 0
fi

bad=0
for sha in "${commits[@]}"; do
  subject="$(git log -1 --format=%s "$sha")"
  # Skip revert auto-messages git itself generates.
  [[ "$subject" == Revert\ * ]] && continue
  if [[ ! "$subject" =~ $SUBJECT_RE ]]; then
    if [[ "$bad" -eq 0 ]]; then
      echo "✖ Non-conventional commit subject(s) in $RANGE:" >&2
      echo "  Expected: type(scope)?: description   (type ∈ ${TYPES//|/, })" >&2
      echo "" >&2
    fi
    bad=$((bad + 1))
    printf '  %s  %s\n' "${sha:0:9}" "$subject" >&2
  fi
done

if [[ "$bad" -ne 0 ]]; then
  echo "" >&2
  echo "Reword with: git rebase -i $RANGE   (or amend if it's a single commit)." >&2
  exit 1
fi

echo "check-commit-format: OK — ${#commits[@]} commit(s) in $RANGE are conventional."
