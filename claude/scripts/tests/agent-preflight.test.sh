#!/usr/bin/env bash
# agent-preflight.test.sh — repository sync failures must stop agent launchers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

TEST_HOME="$(mktemp -d)"
TEST_DEV="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
HEALTH_CALLS="$(mktemp)"
trap 'rm -rf "$TEST_HOME" "$TEST_DEV" "$SHIM_DIR"; rm -f "$HEALTH_CALLS"' EXIT

mkdir -p "$TEST_DEV/good" "$TEST_DEV/linked-upstream" "$TEST_DEV/bad/.git" "$TEST_DEV/broken/.git"
printf 'gitdir: /tmp/simulated-linked-worktree\n' > "$TEST_DEV/good/.git"
printf 'gitdir: /tmp/simulated-linked-worktree-with-upstream\n' > "$TEST_DEV/linked-upstream/.git"
cat > "$SHIM_DIR/git" <<'EOF'
#!/usr/bin/env bash
repo=""
if [ "${1:-}" = "-C" ]; then
  repo="$2"
  shift 2
fi
case "${1:-} ${2:-}" in
  "rev-parse --is-inside-work-tree")
    if [ "$(basename "$repo")" = "broken" ] && [ "${BROKEN_REPO_HEALTHY:-0}" != "1" ]; then
      echo "fatal: simulated repository discovery failure" >&2
      exit 128
    fi
    echo true
    ;;
  "rev-parse --path-format=absolute")
    printf '%s\n' "$repo/.git-common"
    ;;
  "rev-parse --abbrev-ref")
    if [ "$(basename "$repo")" = "good" ]; then
      echo "fatal: no upstream configured" >&2
      exit 128
    fi
    echo origin/main
    ;;
  "remote -v")
    printf 'origin\thttps://example.invalid/repo.git (fetch)\n'
    ;;
  "pull --ff-only")
    if [ "$(basename "$repo")" = "bad" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      echo "fatal: simulated pull failure" >&2
      exit 42
    fi
    echo "Already up to date."
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$SHIM_DIR/git"

export HOME="$TEST_HOME"
export PATH="$SHIM_DIR:/usr/bin:/bin"

# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"

_dev_dir() {
  printf '%s\n' "$TEST_DEV"
}

health_probe() {
  echo called >> "$HEALTH_CALLS"
  return "${HEALTH_RC:-0}"
}

if pull_all_output="$(pull-all 2>&1)"; then
  fail "pull-all returned success when one repository failed"
elif grep -q 'fatal: simulated pull failure' <<< "$pull_all_output"; then
  ok "pull-all returns failure and preserves the failing repository output"
else
  fail "pull-all failed without surfacing the repository error"
fi

if grep -Eq 'good[[:space:]]+No upstream branch; skipped' <<< "$pull_all_output"; then
  ok "pull-all safely skips a fresh linked worktree without an upstream"
else
  fail "pull-all tried to pull or silently skipped a fresh linked worktree"
fi

if grep -Eq 'linked-upstream[[:space:]]+Already up to date' <<< "$pull_all_output"; then
  ok "pull-all updates a linked worktree that has an upstream"
else
  fail "pull-all left an upstream-backed linked worktree potentially stale"
fi

if grep -Eq 'broken[[:space:]]+fatal: simulated repository discovery failure' <<< "$pull_all_output"; then
  ok "pull-all reports repository discovery failures"
else
  fail "pull-all silently skipped an unhealthy repository"
fi

if _agent_preflight "resume" health_probe --model test >/dev/null 2>&1; then
  fail "agent preflight continued after repository sync failed"
elif [ ! -s "$HEALTH_CALLS" ]; then
  ok "agent preflight stops before health checks and runtime launch"
else
  fail "agent preflight ran health checks after repository sync failed"
fi

export ALL_PULLS_SUCCEED=1
export BROKEN_REPO_HEALTHY=1
HEALTH_RC=9
if _agent_preflight "resume" health_probe --model test >/dev/null 2>&1; then
  fail "agent preflight continued after its runtime health check failed"
else
  ok "agent preflight propagates runtime health-check failures"
fi

mkdir -p "$TEST_DEV/dotfiles"
cat > "$TEST_DEV/dotfiles/check-claude.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--heal" ] || exit 8
exit 9
EOF
cat > "$TEST_DEV/dotfiles/check-codex.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--strict" ] || exit 8
exit 9
EOF
cat > "$TEST_DEV/dotfiles/check-antigravity.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--strict" ] || exit 8
exit 9
EOF
chmod +x "$TEST_DEV/dotfiles/check-claude.sh" \
  "$TEST_DEV/dotfiles/check-codex.sh" \
  "$TEST_DEV/dotfiles/check-antigravity.sh"
sync-memory() { return 0; }

if _check_claude_launch_health >/dev/null 2>&1 \
  || _check_codex_launch_health >/dev/null 2>&1 \
  || _check_antigravity_launch_health >/dev/null 2>&1; then
  fail "a launcher health wrapper ignored actual checker failure"
else
  ok "all launcher integrations propagate strict runtime checker failures"
fi

: > "$HEALTH_CALLS"
unset BROKEN_REPO_HEALTHY
HEALTH_RC=0
if _agent_preflight "resume" health_probe resume >/dev/null 2>&1 \
  && [ -s "$HEALTH_CALLS" ]; then
  ok "resume mode skips repository pulls but still enforces runtime health"
else
  fail "resume mode bypassed its strict runtime health check"
fi

: > "$HEALTH_CALLS"
if _agent_preflight "--conversation --conversation= --continue --continue=" health_probe \
    --conversation=synthetic-id >/dev/null 2>&1 \
  && [ -s "$HEALTH_CALLS" ]; then
  ok "equals-form resume flags skip pulls but still enforce runtime health"
else
  fail "equals-form resume flags were misclassified as fresh launches"
fi

: > "$HEALTH_CALLS"
if _agent_preflight "-conversation -conversation= -continue -continue=" health_probe \
    -conversation=synthetic-id >/dev/null 2>&1 \
  && [ -s "$HEALTH_CALLS" ]; then
  ok "single-dash long resume flags skip pulls but still enforce health"
else
  fail "single-dash long resume flags were misclassified as fresh launches"
fi

: > "$HEALTH_CALLS"
if _agent_preflight "resume fork" health_probe 'resume=database' >/dev/null 2>&1; then
  fail "a fresh Codex prompt containing resume= skipped repository pulls"
elif [ ! -s "$HEALTH_CALLS" ]; then
  ok "equals matching is opt-in and does not misclassify Codex prompts"
else
  fail "Codex prompt classification reached health after a failing pull"
fi

: > "$HEALTH_CALLS"
if _agent_preflight "--resume --resume=" health_probe -- '--resume=prompt' \
    >/dev/null 2>&1; then
  fail "prompt text after -- was classified as a resume flag"
elif [ ! -s "$HEALTH_CALLS" ]; then
  ok "resume detection stops at the option terminator"
else
  fail "option-terminator handling reached health after a failing pull"
fi

: > "$HEALTH_CALLS"
if _agent_preflight "resume fork" health_probe exec resume >/dev/null 2>&1; then
  fail "a positional Codex prompt word was classified as a resume subcommand"
elif [ ! -s "$HEALTH_CALLS" ]; then
  ok "bare Codex resume subcommands are recognized only in command position"
else
  fail "Codex command-position handling reached health after a failing pull"
fi

mkdir -p "$TEST_DEV/demo-project"
if _codex_is_resume_invocation -m gpt-5 resume --last \
  && _codex_is_resume_invocation demo-project --profile work fork --last \
  && _codex_is_resume_invocation --image=/tmp/example.png resume --last \
  && _codex_is_resume_invocation -i/tmp/example.png fork --last \
  && ! _codex_is_resume_invocation exec 'resume=database' \
  && ! _codex_is_resume_invocation -- 'resume'; then
  ok "Codex resume parser skips recognized global options and their values"
else
  fail "Codex resume parser misclassified a global-option command line"
fi

echo ""
echo "agent-preflight: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
