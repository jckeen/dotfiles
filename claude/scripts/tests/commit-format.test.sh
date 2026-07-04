#!/usr/bin/env bash
# commit-format.test.sh — fixture tests for check-commit-format.sh.
# Builds throwaway git repos under mktemp, makes empty commits with known
# subjects, then runs the REAL checker with cwd set to the fixture repo and
# asserts exit code + an output fragment. The checker operates on the current
# git repo (git rev-list/git log), so it is run in-place — not copied. Run
# directly; exit 1 on any failure. Mirrors install-integrity.test.sh.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REAL_CHECKER="$SCRIPT_DIR/../check-commit-format.sh"

pass=0
failed=0
R=""

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
}

# commit <subject> — empty commit with the given subject verbatim.
commit() {
  git -C "$R" commit --allow-empty -q -m "$1"
}

# check <name> <expected-exit> [<required output fragment>] -- <checker args...>
check() {
  local name="$1" want="$2" frag="${3:-}"
  shift 3
  [[ "${1:-}" == "--" ]] && shift
  local out rc
  out="$(cd "$R" && "$REAL_CHECKER" "$@" 2>&1)"
  rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$want frag='$frag'; got rc=$rc)"
    echo "$out" | sed 's/^/      | /'
  fi
  rm -rf "$R"
}

# --- Case 1: all-conventional range passes ----------------------------------
new_repo
commit "chore: init"
base="$(git -C "$R" rev-parse HEAD)"
commit "feat: add x"
commit "fix(scope): y"
# Sanity: base..HEAD must contain exactly the two later commits.
n="$(git -C "$R" rev-list --count "$base..HEAD")"
[ "$n" -eq 2 ] || { echo "FAIL - setup: expected 2 commits in range, got $n"; failed=$((failed + 1)); }
check "good: conventional subjects pass" 0 "conventional" -- "$base" HEAD

# --- Case 2: non-conventional subject fails ---------------------------------
new_repo
commit "chore: init"
base="$(git -C "$R" rev-parse HEAD)"
commit "added stuff"
n="$(git -C "$R" rev-list --count "$base..HEAD")"
[ "$n" -eq 1 ] || { echo "FAIL - setup: expected 1 commit in range, got $n"; failed=$((failed + 1)); }
check "bad: non-conventional subject fails" 1 "Non-conventional" -- "$base" HEAD

# --- Case 3: revert auto-message is skipped ---------------------------------
new_repo
commit "chore: init"
base="$(git -C "$R" rev-parse HEAD)"
commit 'Revert "feat: x"'
check "skip-revert: revert auto-message passes" 0 "" -- "$base" HEAD

# --- Case 4: empty range is a clean pass ------------------------------------
new_repo
commit "chore: init"
check "empty-range: nothing to lint passes" 0 "nothing to lint" -- HEAD HEAD

# --- Case 5: unresolvable base fails closed ---------------------------------
new_repo
commit "chore: init"
check "fail-closed: bogus base SHA fails" 1 "failing closed" \
  -- deadbeefdeadbeefdeadbeefdeadbeefdeadbeef HEAD

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
