#!/usr/bin/env bash
# no-personal-data.test.sh — fixture tests for check-no-personal-data.sh.
# Builds throwaway git repos under mktemp, COPIES the checker into the fixture
# so it resolves REPO_ROOT (SCRIPT_DIR/../..) to the fixture, stages files so
# `git ls-files` sees them, runs the checker, asserts exit code + an output
# fragment. Run directly; exit 1 on any failure. Mirrors install-integrity.test.sh.
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
CHECKER="$SCRIPT_DIR/../check-no-personal-data.sh"

pass=0
failed=0
R=""

# new_repo — fresh git repo with the checker copied to its canonical location
# so the copy's REPO_ROOT (SCRIPT_DIR/../..) resolves to the fixture root.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  mkdir -p "$R/claude/scripts"
  cp "$CHECKER" "$R/claude/scripts/check-no-personal-data.sh"
  chmod +x "$R/claude/scripts/check-no-personal-data.sh"
}

# w <repo-relative path> <line>...  — write a file, one arg per line
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# check <name> <expected-exit> [<required output fragment>]
# Stages all files first (the checker only sees tracked files via git ls-files).
check() {
  local name="$1" want="$2" frag="${3:-}"
  git -C "$R" add -A >/dev/null 2>&1
  local out rc
  out="$(cd "$R" && ./claude/scripts/check-no-personal-data.sh 2>&1)"
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

# --- Case 1: portable / placeholder forms only → pass ------------------------
new_repo
w notes.md '$HOME/dev/x' '/home/you/dev/x' '~/foo'
check "portable+placeholder forms pass" 0 "No machine-specific home paths"

# The "leak" fixtures below are assembled from fragments at RUNTIME so the literal
# /home/<user>/ and C:\Users\<user>\ patterns never appear in THIS tracked file —
# otherwise check-no-personal-data would flag its own test data as a real leak
# (the gate caught exactly that during development). The fixture repo still gets
# the fully-assembled path, so the checker is genuinely exercised.
_u="realuser"

# --- Case 2: real /home/<user>/ path → fail ---------------------------------
new_repo
w leak.md "/home/$_u/dev/dotfiles"
check "real /home path fails" 1 "machine-specific home paths"

# --- Case 3: real Windows C:\Users\<user>\ path → fail ----------------------
new_repo
w leak.md 'C:\Users\'"$_u"'\AppData'
check "real windows home path fails" 1 "machine-specific home paths"

# --- Case 4: placeholder usernames are not flagged → pass --------------------
new_repo
w examples.md '/home/user/foo' '/Users/me/bar'
check "placeholder usernames not flagged" 0 "No machine-specific home paths"

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
