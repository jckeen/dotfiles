#!/usr/bin/env bash
# doc-refs.test.sh — fixture tests for check-doc-refs.sh.
# Builds throwaway git repos under mktemp, copies the checker in so its
# self-resolved REPO_ROOT (SCRIPT_DIR/../..) lands on the fixture repo, stages
# fixture Markdown, runs the copy, and asserts exit code + an output fragment.
# Run directly; exit 1 on any failure. Mirrors install-integrity.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
CHECKER="$SCRIPT_DIR/../check-doc-refs.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh git repo with the checker copied to claude/scripts/ so it
# resolves REPO_ROOT to the fixture root, plus an empty claude/hooks/ dir.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  mkdir -p "$R/claude/scripts" "$R/claude/hooks"
  cp "$CHECKER" "$R/claude/scripts/check-doc-refs.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/check-doc-refs.sh"
}

# w <repo-relative path> <line>...  — write a file, one arg per line.
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  git -C "$R" add -A >/dev/null 2>&1
  local out rc
  out="$(cd "$R" && ./claude/scripts/check-doc-refs.sh 2>&1)"
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

# --- Case 1: GOOD — existing hook, existing skill dir, live relative link ----
new_repo
mkdir -p "$R/claude/skills/foo"
printf '// real hook\n' > "$R/claude/hooks/Real.hook.ts"
w exists.md '# Exists'
w guide.md \
  'Runs the Real.hook.ts hook.' \
  'See the skill at claude/skills/foo/ for details.' \
  'Also read [the notes](./exists.md).'
check "good refs resolve" 0 "doc-refs: OK"

# --- Case 2: BAD (hook) — reference to a hook that does not exist -------------
new_repo
w guide.md 'This wires up Ghost.hook.ts on every prompt.'
check "missing hook fails" 1 "missing hook"

# --- Case 3: BAD (skill) — reference to a skill dir that does not exist -------
new_repo
w guide.md 'Load the skill from claude/skills/nonexistent/ here.'
check "missing skill dir fails" 1 "missing skill dir"

# --- Case 4: BAD (link) — relative link to a file that does not exist ---------
new_repo
w guide.md 'Follow [x](./nope.md) for more.'
check "broken relative link fails" 1 "broken link"

# --- Case 5: ALLOWLIST — broken hook ref inside CHANGELOG.md is skipped -------
new_repo
w CHANGELOG.md '# Changelog' '' '- Removed Ghost.hook.ts in the PAI decommission.'
check "changelog allowlisted broken ref passes" 0 "doc-refs: OK"

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
