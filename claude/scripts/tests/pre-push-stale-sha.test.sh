#!/usr/bin/env bash
# pre-push-stale-sha.test.sh — fixture tests for PrePushStaleSHACheck.hook.ts.
#
# A PreToolUse hook that exits 0 is heard only through stdout JSON: its stderr
# goes to the debug log, never the transcript (#593). So a stale review must
# produce exactly one JSON object on stdout with `systemMessage` (the user) and
# PreToolUse `additionalContext` (Claude), and every no-warning path must leave
# stdout empty. `git` and `gh` are stubs on PATH; nothing touches a real repo
# or GitHub. Run directly; exit 1 on any failure.
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
HOOK="$SCRIPT_DIR/../../hooks/PrePushStaleSHACheck.hook.ts"

if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL - bun is required to run the TypeScript PreToolUse hook" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL - jq is required to check the hook's stdout JSON" >&2
  exit 1
fi

pass=0
failed=0
out=""
err=""
rc=0

die() {
  echo "FAIL - fixture setup: $1" >&2
  exit 1
}

HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"

BIN="$(mktemp -d)" || die "mktemp -d for stub bin"
trap 'rm -rf "$BIN"' EXIT

# git stub: answers the hook's two rev-parse calls from the fixture env.
cat >"$BIN/git" <<'EOF' || die "write git stub"
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "$STUB_HEAD" ;;
  "rev-parse --abbrev-ref HEAD") echo "$STUB_BRANCH" ;;
  *) exit 1 ;;
esac
EOF
# gh stub: `gh pr view --json …` prints the fixture PR, or fails when unset.
cat >"$BIN/gh" <<'EOF' || die "write gh stub"
#!/usr/bin/env bash
[[ -n "${STUB_PR:-}" ]] || exit 1
printf '%s\n' "$STUB_PR"
EOF
chmod +x "$BIN/git" "$BIN/gh" || die "chmod stubs"

# pr_json <reviewer> <reviewed-sha> [state]
pr_json() {
  jq -nc --arg login "$1" --arg oid "$2" --arg state "${3:-COMMENTED}" '{
    number: 7, headRefOid: "x", baseRefName: "main",
    url: "https://github.com/example/repo/pull/7",
    reviews: [{author: {login: $login}, state: $state, commit: {oid: $oid},
               body: "", submittedAt: "2026-10-01T00:00:00Z"}]
  }'
}

# run_hook <command> <pr-json|""> [branch]
run_hook() {
  local cmd="$1" pr="$2" branch="${3:-feat/x}" payload errf
  payload="$(jq -nc --arg c "$cmd" --arg d "$BIN" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')" || die "build payload"
  errf="$(mktemp)" || die "mktemp for stderr"
  out="$(printf '%s' "$payload" | PATH="$BIN:$PATH" STUB_HEAD="$HEAD_SHA" \
    STUB_BRANCH="$branch" STUB_PR="$pr" bun "$HOOK" 2>"$errf")"
  rc=$?
  err="$(cat "$errf")"
  rm -f "$errf"
}

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    echo "       rc=$rc stdout=$out"
    echo "       stderr=$err"
  fi
}

silent() { [ "$rc" -eq 0 ] && [ -z "$out" ]; }

# ── stale review → one JSON object on stdout, nothing on stderr ─────────
run_hook "git push origin feat/x" "$(pr_json chatgpt-codex-connector "$OLD_SHA")"
assert "stale review exits 0" '[ "$rc" -eq 0 ]'
assert "stale review writes nothing to stderr" '[ -z "$err" ]'
assert "stdout is JSON with exactly systemMessage + hookSpecificOutput" \
  '[ "$(jq -c "keys" <<<"$out")" = "[\"hookSpecificOutput\",\"systemMessage\"]" ]'
assert "hookSpecificOutput names the PreToolUse event" \
  '[ "$(jq -r ".hookSpecificOutput.hookEventName" <<<"$out")" = "PreToolUse" ]'
assert "additionalContext carries the same text as systemMessage" \
  'jq -e ".hookSpecificOutput.additionalContext == .systemMessage" <<<"$out" >/dev/null'
assert "message names the PR, reviewer, and both SHAs" \
  'jq -e ".systemMessage | test(\"STALE-REVIEW: \\\\[stale-push\\\\] PR #7 example/repo chatgpt-codex-connector reviewed 2222222222 but HEAD is 1111111111\")" <<<"$out" >/dev/null'
assert "message ends with the re-review hint" \
  'jq -e ".systemMessage | test(\"so the reviewer re-runs against the new HEAD.$\")" <<<"$out" >/dev/null'

# ── every no-warning path is silent ─────────────────────────────────────
run_hook "git push" "$(pr_json chatgpt-codex-connector "$HEAD_SHA")"
assert "review of HEAD is silent" silent

run_hook "git push" "$(pr_json chatgpt-codex-connector "${HEAD_SHA:0:10}")"
assert "short-SHA review of HEAD is silent" silent

run_hook "git push" "$(pr_json someone "$OLD_SHA" DISMISSED)"
assert "dismissed stale review is silent" silent

run_hook "git push" ""
assert "no PR for the branch is silent" silent

run_hook "git push" "$(pr_json chatgpt-codex-connector "$OLD_SHA")" HEAD
assert "detached HEAD is silent" silent

run_hook "git status" "$(pr_json chatgpt-codex-connector "$OLD_SHA")"
assert "non-push command is silent" silent

out="$(printf 'not json' | PATH="$BIN:$PATH" bun "$HOOK" 2>/dev/null)"
rc=$?
assert "malformed stdin fails open and silent" silent

echo
echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ] || exit 1
