#!/usr/bin/env bash
# deployed-orphans.test.sh — fixture tests for check-deployed-orphans.sh.
# Builds throwaway ~/.claude fixtures under mktemp, points the checker at them
# via CLAUDE_DIR, asserts exit code + an output fragment. Run directly; exit 1
# on any failure. Mirrors install-integrity.test.sh.
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
CHECKER="$SCRIPT_DIR/../check-deployed-orphans.sh"

pass=0
failed=0
F=""

new_fixture() {
  F="$(mktemp -d)/dotclaude"
  mkdir -p "$F"
}

# check <name> <expected-exit> [<required output fragment>] [<flag>]
check() {
  local name="$1" want="$2" frag="${3:-}" flag="${4:-}"
  local out rc
  if [ -n "$flag" ]; then
    out="$(CLAUDE_DIR="$F" "$CHECKER" "$flag" 2>&1)"
  else
    out="$(CLAUDE_DIR="$F" "$CHECKER" 2>&1)"
  fi
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
}

# Populate the fixture with the PAI-decommission debris the checker must flag.
dirty_fixture() {
  new_fixture
  mkdir -p "$F/hooks/handlers"
  printf 'export {}\n' > "$F/hooks/handlers/VoiceNotification.ts"
  printf '# big legacy readme\n' > "$F/hooks/README.md"
  # A healthy symlinked hook must NOT be flagged (target existence irrelevant).
  ln -s /nonexistent/dotfiles/claude/hooks/format-on-edit.sh "$F/hooks/format-on-edit.sh"
  printf '{}\n' > "$F/settings.json.doctor-bak"
  mkdir -p "$F/commands"
  printf '*\n' > "$F/commands/.gitignore"
}

# --- dirty fixture: flags all three orphan classes, exit 0 by default --------
dirty_fixture
check "dirty: hooks debris flagged" 0 "ORPHAN  hooks/handlers/"
check "dirty: hooks README flagged" 0 "ORPHAN  hooks/README.md"
check "dirty: doctor-bak flagged" 0 "ORPHAN  settings.json.doctor-bak"
check "dirty: empty commands flagged" 0 "ORPHAN  commands/"
check "dirty: default exit stays 0" 0 "orphan(s) from decommissioned"
check "dirty: --strict exits 1" 1 "ORPHAN" "--strict"
rm -rf "$(dirname "$F")"

# --- symlinked hook is never an orphan ----------------------------------------
dirty_fixture
out="$(CLAUDE_DIR="$F" "$CHECKER" 2>&1)"
if grep -qF "format-on-edit.sh" <<<"$out"; then
  failed=$((failed + 1))
  echo "FAIL - symlinked hook must not be flagged"
  echo "$out" | sed 's/^/      | /'
else
  pass=$((pass + 1))
  echo "ok   - symlinked hook not flagged"
fi
rm -rf "$(dirname "$F")"

# --- clean fixture: runtime dirs + symlinks only → OK, strict passes ---------
new_fixture
mkdir -p "$F/hooks" "$F/projects" "$F/plugins" "$F/shell-snapshots"
ln -s /nonexistent/dotfiles/claude/hooks/format-on-edit.sh "$F/hooks/format-on-edit.sh"
ln -s /nonexistent/claude-memory/settings.json "$F/settings.json"
printf '{}\n' > "$F/history.jsonl"
check "clean: reports no artifacts" 0 "No decommissioned artifacts"
check "clean: --strict exits 0" 0 "No decommissioned artifacts" "--strict"
rm -rf "$(dirname "$F")"

# --- unknown top-level entry: noted, but never fails --strict ----------------
new_fixture
mkdir -p "$F/some-future-runtime-dir"
check "unknown: noted as UNKNOWN" 0 "UNKNOWN some-future-runtime-dir"
check "unknown: does not fail --strict" 0 "UNKNOWN" "--strict"
rm -rf "$(dirname "$F")"

# --- known PAI leftover: distinct category, fails --strict (issue #232) -------
new_fixture
mkdir -p "$F/PAI"
printf 'not pai\n' > "$F/stray-debug.log"
check "pai: PAI/ flagged as PAI-LEFTOVER" 0 "PAI-LEFTOVER PAI"
check "pai: default exit stays 0" 0 "known PAI leftover"
check "pai: --strict exits 1" 1 "PAI-LEFTOVER PAI" "--strict"
check "pai: stray file beside it stays UNKNOWN" 0 "UNKNOWN stray-debug.log"
# The stray file's own line must carry no PAI attribution (PR #225 review:
# never assert PAI provenance for arbitrary regular files).
out="$(CLAUDE_DIR="$F" "$CHECKER" 2>&1)"
if grep -F "stray-debug.log" <<<"$out" | grep -qi "PAI"; then
  failed=$((failed + 1))
  echo "FAIL - stray file must not be attributed to PAI"
  echo "$out" | sed 's/^/      | /'
else
  pass=$((pass + 1))
  echo "ok   - stray file not attributed to PAI"
fi
rm -rf "$(dirname "$F")"

# --- .pai-mode.state is a known PAI leftover (issue #248) ---------------------
new_fixture
printf '/old/target\n' > "$F/.pai-mode.state"
check "pai: .pai-mode.state flagged as PAI-LEFTOVER" 0 "PAI-LEFTOVER .pai-mode.state"
check "pai: .pai-mode.state fails --strict" 1 "PAI-LEFTOVER .pai-mode.state" "--strict"
rm -rf "$(dirname "$F")"

# --- trailing slash on CLAUDE_DIR is normalized (issue #247) ------------------
# Without normalization the "$CLAUDE_DIR/" prefix strip misses, names stay full
# paths, nothing matches any list, and --strict silently passes a dirty tree.
new_fixture
mkdir -p "$F/PAI"
out="$(CLAUDE_DIR="$F/" "$CHECKER" --strict 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "PAI-LEFTOVER PAI" <<<"$out"; then
  pass=$((pass + 1))
  echo "ok   - trailing-slash CLAUDE_DIR still strict-fails on PAI"
else
  failed=$((failed + 1))
  echo "FAIL - trailing-slash CLAUDE_DIR must normalize (got rc=$rc)"
  echo "$out" | sed 's/^/      | /'
fi
rm -rf "$(dirname "$F")"

# --- stray file alone: advisory UNKNOWN, --strict still passes ----------------
new_fixture
printf 'not pai\n' > "$F/stray-debug.log"
check "stray file: noted as UNKNOWN" 0 "UNKNOWN stray-debug.log"
check "stray file: does not fail --strict" 0 "UNKNOWN stray-debug.log" "--strict"
rm -rf "$(dirname "$F")"

# --- commands/ with real content is not an orphan -----------------------------
new_fixture
mkdir -p "$F/commands"
printf 'a real command\n' > "$F/commands/my-cmd.md"
out="$(CLAUDE_DIR="$F" "$CHECKER" 2>&1)"
if grep -qF "ORPHAN  commands/" <<<"$out"; then
  failed=$((failed + 1))
  echo "FAIL - non-empty commands/ must not be flagged"
  echo "$out" | sed 's/^/      | /'
else
  pass=$((pass + 1))
  echo "ok   - non-empty commands/ not flagged"
fi
rm -rf "$(dirname "$F")"

# --- missing CLAUDE_DIR hard-fails --------------------------------------------
out="$(CLAUDE_DIR=/nonexistent/never-exists "$CHECKER" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "not found" <<<"$out"; then
  pass=$((pass + 1))
  echo "ok   - missing dir exits 1"
else
  failed=$((failed + 1))
  echo "FAIL - missing dir should exit 1 (got rc=$rc)"
fi

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
