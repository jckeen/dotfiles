#!/usr/bin/env bash
# agent-preflight.test.sh — repository sync warns and continues; runtime health
# still gates every launcher. Two fixtures: real temporary git repos and
# worktrees (classification, HEAD/file preservation), then a git PATH shim for
# the pull/health interplay that needs scripted failures.
set -uo pipefail

# Exported shell functions take precedence over the fixture's PATH shims.
unset -f git codex claude

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

TEST_HOME="$(mktemp -d)"
TEST_DEV="$(mktemp -d)"
REAL_DEV="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
HEALTH_CALLS="$(mktemp)"
WRAPPER_CALLS="$(mktemp)"
RUNTIME_CALLS="$(mktemp)"
trap 'rm -rf "$TEST_HOME" "$TEST_DEV" "$REAL_DEV" "$SHIM_DIR"; rm -f "$HEALTH_CALLS" "$WRAPPER_CALLS" "$RUNTIME_CALLS"' EXIT

export HOME="$TEST_HOME"
# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"

ACTIVE_DEV="$REAL_DEV"
_dev_dir() {
  printf '%s\n' "$ACTIVE_DEV"
}

health_probe() {
  echo called >> "$HEALTH_CALLS"
  return "${HEALTH_RC:-0}"
}

# ── Real git fixture ───────────────────────────────────────────────────
# Dot-prefixed helpers (.origin.git, .seed, .gitdirs, .super) sit outside the
# `*/` glob pull-all scans. Immediate children of REAL_DEV:
#   ordinary          clone on main             → ff pull
#   gitfile-ordinary  --separate-git-dir clone  → ff pull (gitfile, not linked)
#   linked            worktree of ordinary, feature branch tracking origin/main,
#                     diverged and dirty        → fetch only, nothing touched
#   linked-detached   detached worktree         → fetch only
#   no-upstream       init + remote, no upstream → skipped
#   diverged-ordinary-checkout-with-a-long-name → ff pull fails (nonzero)
g() { git -c user.email=t@t.test -c user.name=test -c init.defaultBranch=main "$@"; }
commit_file() {  # commit_file REPO NAME CONTENT
  printf '%s\n' "$3" > "$1/$2"
  g -C "$1" add "$2"
  g -C "$1" commit -qm "$2: $3"
}

ORIGIN="$REAL_DEV/.origin.git"
SEED="$REAL_DEV/.seed"
LONG_NAME="diverged-ordinary-checkout-with-a-long-name"
mkdir -p "$REAL_DEV/.gitdirs"
git init -q --bare -b main "$ORIGIN"
g init -q -b main "$SEED"
commit_file "$SEED" tracked base
g -C "$SEED" remote add origin "$ORIGIN"
g -C "$SEED" push -q -u origin main

g clone -q "$ORIGIN" "$REAL_DEV/ordinary"
g clone -q --separate-git-dir="$REAL_DEV/.gitdirs/gitfile-ordinary" "$ORIGIN" "$REAL_DEV/gitfile-ordinary"
g clone -q "$ORIGIN" "$REAL_DEV/$LONG_NAME"
commit_file "$REAL_DEV/$LONG_NAME" local-only "diverges from origin"

g -C "$REAL_DEV/ordinary" worktree add -q --no-track -b feature "$REAL_DEV/linked" main
g -C "$REAL_DEV/linked" branch -q --set-upstream-to=origin/main
commit_file "$REAL_DEV/linked" feature-file "feature work"
printf 'uncommitted feature edits\n' > "$REAL_DEV/linked/tracked"
printf 'keep this\n' > "$REAL_DEV/linked/untracked"
g -C "$REAL_DEV/ordinary" worktree add -q --detach "$REAL_DEV/linked-detached" main

g init -q -b main "$REAL_DEV/no-upstream"
commit_file "$REAL_DEV/no-upstream" tracked standalone
g -C "$REAL_DEV/no-upstream" remote add origin "$ORIGIN"

g init -q -b main "$REAL_DEV/.super"
commit_file "$REAL_DEV/.super" tracked super
g -c protocol.file.allow=always -C "$REAL_DEV/.super" submodule add -q "$ORIGIN" sub 2>/dev/null

commit_file "$SEED" tracked "remote change"
g -C "$SEED" push -q
remote_tip="$(g -C "$SEED" rev-parse HEAD)"

linked_head_before="$(g -C "$REAL_DEV/linked" rev-parse HEAD)"
linked_status_before="$(g -C "$REAL_DEV/linked" status --porcelain)"
detached_head_before="$(g -C "$REAL_DEV/linked-detached" rev-parse HEAD)"

if ! _pull_all_is_linked_worktree "$REAL_DEV/ordinary/" \
  && ! _pull_all_is_linked_worktree "$REAL_DEV/gitfile-ordinary/" \
  && ! _pull_all_is_linked_worktree "$REAL_DEV/.super/sub/" \
  && _pull_all_is_linked_worktree "$REAL_DEV/linked/" \
  && _pull_all_is_linked_worktree "$REAL_DEV/linked-detached/"; then
  ok "linked worktrees are identified by git-dir/common-dir, not by a gitfile"
else
  fail "worktree classification misread a gitfile checkout, submodule, or linked worktree"
fi

real_output="$(pull-all 2>&1)"
real_rc=$?
if [ "$real_rc" -ne 0 ] \
  && grep -Eq "${LONG_NAME}[[:space:]]+fatal:" <<< "$real_output"; then
  ok "pull-all stays nonzero for a real non-fast-forward pull and separates a long repo name from its git error"
else
  fail "pull-all rc=$real_rc; output: $real_output"
fi

if [ "$(g -C "$REAL_DEV/ordinary" rev-parse HEAD)" = "$remote_tip" ] \
  && [ "$(g -C "$REAL_DEV/gitfile-ordinary" rev-parse HEAD)" = "$remote_tip" ]; then
  ok "ordinary checkouts, including a gitfile checkout, still fast-forward"
else
  fail "an ordinary checkout was not fast-forwarded"
fi

if [ "$(g -C "$REAL_DEV/linked" rev-parse HEAD)" = "$linked_head_before" ] \
  && [ "$(g -C "$REAL_DEV/linked" symbolic-ref HEAD)" = "refs/heads/feature" ] \
  && [ "$(g -C "$REAL_DEV/linked" status --porcelain)" = "$linked_status_before" ] \
  && [ "$(cat "$REAL_DEV/linked/tracked")" = "uncommitted feature edits" ] \
  && [ "$(cat "$REAL_DEV/linked/untracked")" = "keep this" ]; then
  ok "a diverged, dirty linked worktree keeps its HEAD, branch, index, and files"
else
  fail "pull-all changed a linked worktree's HEAD, index, or files"
fi

if [ "$(g -C "$REAL_DEV/linked" rev-parse refs/remotes/origin/main)" = "$remote_tip" ] \
  && grep -Eq 'linked[[:space:]]+Fetched' <<< "$real_output"; then
  ok "a linked worktree fetches its upstream without pulling"
else
  fail "a linked worktree was not fetched or not reported as fetch-only"
fi

if [ "$(g -C "$REAL_DEV/linked-detached" rev-parse HEAD)" = "$detached_head_before" ] \
  && grep -Eq 'linked-detached[[:space:]]+Fetched' <<< "$real_output"; then
  ok "a detached linked worktree fetches and stays put"
else
  fail "a detached linked worktree was pulled or skipped"
fi

if grep -Eq 'no-upstream[[:space:]]+No upstream branch; skipped' <<< "$real_output"; then
  ok "an ordinary checkout without an upstream is still skipped"
else
  fail "no-upstream handling changed for ordinary checkouts"
fi

g -C "$REAL_DEV/ordinary" remote set-url origin "$REAL_DEV/.missing.git"
offline_output="$(pull-all 2>&1)"
offline_rc=$?
if [ "$offline_rc" -ne 0 ] \
  && grep -Eq 'linked[[:space:]]+fatal:' <<< "$offline_output" \
  && [ "$(g -C "$REAL_DEV/linked" rev-parse HEAD)" = "$linked_head_before" ]; then
  ok "a linked worktree fetch failure is reported, nonzero, and leaves the worktree untouched"
else
  fail "linked worktree fetch failure rc=$offline_rc; output: $offline_output"
fi
g -C "$REAL_DEV/ordinary" remote set-url origin "$ORIGIN"

: > "$HEALTH_CALLS"
preflight_err="$( { _agent_preflight "resume" health_probe --model test >/dev/null; } 2>&1 )"
preflight_rc=$?
if [ "$preflight_rc" -eq 0 ] && [ -s "$HEALTH_CALLS" ] \
  && grep -q 'continuing with local' <<< "$preflight_err" \
  && grep -q "$LONG_NAME" <<< "$preflight_err" \
  && grep -q 'fatal:' <<< "$preflight_err"; then
  ok "agent preflight warns with the failed repo and git reason, then runs health checks"
else
  fail "agent preflight rc=$preflight_rc, health=$(cat "$HEALTH_CALLS"), stderr: $preflight_err"
fi

: > "$HEALTH_CALLS"
HEALTH_RC=9
preflight_err="$( { _agent_preflight "resume" health_probe --model test >/dev/null; } 2>&1 )"
preflight_rc=$?
if [ "$preflight_rc" -ne 0 ] && grep -q 'Agent health check failed' <<< "$preflight_err"; then
  ok "a failed health check still blocks the launch when sync also failed"
else
  fail "health failure did not block after a sync failure (rc=$preflight_rc)"
fi
HEALTH_RC=0

g -C "$REAL_DEV/$LONG_NAME" reset -q --hard origin/main
: > "$HEALTH_CALLS"
preflight_err="$( { _agent_preflight "resume" health_probe --model test >/dev/null; } 2>&1 )"
preflight_rc=$?
if [ "$preflight_rc" -eq 0 ] && [ -s "$HEALTH_CALLS" ] \
  && ! grep -qi 'sync failed\|continuing with local' <<< "$preflight_err"; then
  ok "a clean sync emits no warning"
else
  fail "clean sync rc=$preflight_rc, stderr: $preflight_err"
fi

# ── Shim fixture ───────────────────────────────────────────────────────
ACTIVE_DEV="$TEST_DEV"
FAKE_GITDIRS="$TEST_DEV/.gitdirs"
mkdir -p "$TEST_DEV/good" "$TEST_DEV/linked-upstream" "$TEST_DEV/linked-offline" \
  "$TEST_DEV/bad/.git" "$TEST_DEV/broken/.git" "$TEST_DEV/dirty/.git" "$TEST_DEV/gone/.git" \
  "$TEST_DEV/unresolvable/.git" \
  "$FAKE_GITDIRS/good" "$FAKE_GITDIRS/bad" "$FAKE_GITDIRS/broken" "$FAKE_GITDIRS/dirty" \
  "$FAKE_GITDIRS/gone" "$FAKE_GITDIRS/unresolvable" \
  "$FAKE_GITDIRS/linked-main/worktrees/linked-upstream" \
  "$FAKE_GITDIRS/linked-main/worktrees/linked-offline"
# A gitfile alone must not make `good` a linked worktree (separate-git-dir).
printf 'gitdir: %s\n' "$FAKE_GITDIRS/good" > "$TEST_DEV/good/.git"
printf 'gitdir: %s\n' "$FAKE_GITDIRS/linked-main/worktrees/linked-upstream" > "$TEST_DEV/linked-upstream/.git"
printf 'gitdir: %s\n' "$FAKE_GITDIRS/linked-main/worktrees/linked-offline" > "$TEST_DEV/linked-offline/.git"
export FAKE_GITDIRS
cat > "$SHIM_DIR/git" <<'EOF'
#!/usr/bin/env bash
repo=""
if [ "${1:-}" = "-C" ]; then
  repo="$2"
  shift 2
fi
name="$(basename "$repo")"
case "${1:-} ${2:-}" in
  "rev-parse --is-inside-work-tree")
    if [ "$name" = "broken" ] && [ "${BROKEN_REPO_HEALTHY:-0}" != "1" ]; then
      echo "fatal: simulated repository discovery failure" >&2
      exit 128
    fi
    echo true
    ;;
  "rev-parse --absolute-git-dir")
    case "$name" in
      linked-*) printf '%s\n' "$FAKE_GITDIRS/linked-main/worktrees/$name" ;;
      *) printf '%s\n' "$FAKE_GITDIRS/$name" ;;
    esac
    ;;
  "rev-parse --git-common-dir")
    if [ "$name" = "unresolvable" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      echo "fatal: simulated git metadata failure" >&2
      exit 128
    fi
    case "$name" in
      linked-*) printf '%s\n' "$FAKE_GITDIRS/linked-main" ;;
      *) printf '%s\n' "$FAKE_GITDIRS/$name" ;;
    esac
    ;;
  "rev-parse --abbrev-ref")
    if [ "$name" = "good" ]; then
      echo "fatal: no upstream configured" >&2
      exit 128
    fi
    echo origin/main
    ;;
  "remote -v")
    printf 'origin\thttps://example.invalid/repo.git (fetch)\n'
    ;;
  "fetch --prune")
    case "$name" in
      linked-*) ;;
      *) echo "fatal: shim: ordinary checkouts pull, they do not fetch-only" >&2; exit 7 ;;
    esac
    if [ "$name" = "linked-offline" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      echo "fatal: simulated fetch failure" >&2
      exit 128
    fi
    ;;
  "pull --ff-only")
    case "$name" in
      linked-*) echo "fatal: shim: a linked worktree must never be pulled" >&2; exit 7 ;;
    esac
    if [ "$name" = "unresolvable" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      echo "fatal: shim: an unclassified checkout must not be pulled" >&2
      exit 7
    fi
    if [ "$name" = "bad" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      echo "fatal: simulated pull failure" >&2
      exit 42
    fi
    if [ "$name" = "gone" ]; then
      # Mirrors a checkout whose upstream branch was deleted on origin after
      # a merge: the stale remote-tracking ref survives until a --prune fetch,
      # so a plain pull fails forever while a pruning pull fails exactly once.
      if [ "${3:-}" != "--prune" ]; then
        echo "fatal: shim: pull without --prune never clears a gone upstream" >&2
        exit 3
      fi
      echo "Your configuration specifies to merge with the ref 'refs/heads/feature'" >&2
      echo "from the remote, but no such ref was fetched." >&2
      exit 1
    fi
    if [ "$name" = "dirty" ] && [ "${ALL_PULLS_SUCCEED:-0}" != "1" ]; then
      # Mirrors a real aborted --ff-only pull: the diagnostic comes first
      # and the LAST line looks like a success (issue #280).
      echo "error: Your local changes to the following files would be overwritten by merge:" >&2
      echo "        .gitignore" >&2
      echo "Updating 1111111..2222222"
      exit 1
    fi
    echo "Already up to date."
    ;;
  *)
    exit 2
    ;;
esac
EOF
cat > "$SHIM_DIR/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex|%s\n' "$*" >> "$RUNTIME_CALLS"
EOF
cat > "$SHIM_DIR/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude|%s\n' "$*" >> "$RUNTIME_CALLS"
EOF
chmod +x "$SHIM_DIR/git" "$SHIM_DIR/codex" "$SHIM_DIR/claude"
export RUNTIME_CALLS
export PATH="$SHIM_DIR:/usr/bin:/bin"

if pull_all_output="$(pull-all 2>&1)"; then
  fail "pull-all returned success when one repository failed"
elif grep -q 'fatal: simulated pull failure' <<< "$pull_all_output"; then
  ok "pull-all returns failure and preserves the failing repository output"
else
  fail "pull-all failed without surfacing the repository error"
fi

if grep -Eq 'good[[:space:]]+No upstream branch; skipped' <<< "$pull_all_output"; then
  ok "pull-all skips a gitfile ordinary checkout without an upstream"
else
  fail "pull-all tried to pull or silently skipped a gitfile checkout without an upstream"
fi

if grep -Eq 'linked-upstream[[:space:]]+Fetched' <<< "$pull_all_output" \
  && ! grep -q 'must never be pulled' <<< "$pull_all_output"; then
  ok "pull-all fetches a linked worktree with an upstream instead of pulling it"
else
  fail "pull-all pulled or skipped an upstream-backed linked worktree"
fi

if grep -Eq 'linked-offline[[:space:]]+fatal: simulated fetch failure' <<< "$pull_all_output"; then
  ok "pull-all reports a linked worktree fetch failure with its git reason"
else
  fail "pull-all hid a linked worktree fetch failure"
fi

# When git cannot say which layout a checkout has, the safe answer is to
# report it — never to assume "ordinary" and pull into what may be a worktree.
if grep -Eq 'unresolvable[[:space:]]+.*not pulled' <<< "$pull_all_output" \
  && ! grep -q 'must not be pulled' <<< "$pull_all_output"; then
  ok "pull-all reports a checkout whose git layout cannot be resolved instead of pulling it"
else
  fail "pull-all pulled or silently skipped an unclassifiable checkout"
fi

if grep -Eq 'broken[[:space:]]+fatal: simulated repository discovery failure' <<< "$pull_all_output"; then
  ok "pull-all reports repository discovery failures"
else
  fail "pull-all silently skipped an unhealthy repository"
fi

if grep -Eq 'dirty[[:space:]]+error: Your local changes' <<< "$pull_all_output" \
  && ! grep -Eq 'dirty[[:space:]]+Updating ' <<< "$pull_all_output"; then
  ok "pull-all surfaces the first error line of a multi-line pull failure"
else
  fail "pull-all masked a multi-line pull failure behind its success-looking last line"
fi

if grep -Eq 'gone[[:space:]]+Upstream branch deleted on origin' <<< "$pull_all_output"; then
  ok "pull-all names a deleted upstream branch instead of a bare pull error"
else
  fail "pull-all did not explain a deleted-upstream pull failure"
fi

: > "$HEALTH_CALLS"
preflight_err="$( { _agent_preflight "resume" health_probe --model test >/dev/null; } 2>&1 )"
preflight_rc=$?
if [ "$preflight_rc" -eq 0 ] && [ -s "$HEALTH_CALLS" ] \
  && grep -Eq 'bad: fatal: simulated pull failure' <<< "$preflight_err" \
  && grep -Eq 'linked-offline: fatal: simulated fetch failure' <<< "$preflight_err"; then
  ok "agent preflight lists every failed repo in its warning and still reaches health checks"
else
  fail "agent preflight rc=$preflight_rc, health=$(cat "$HEALTH_CALLS"), stderr: $preflight_err"
fi

export ALL_PULLS_SUCCEED=1
export BROKEN_REPO_HEALTHY=1
if pull-all >/dev/null 2>&1; then
  ok "a deleted upstream branch is skipped rather than blocking the launch"
else
  fail "a deleted upstream branch blocked pull-all even though every other repo pulled"
fi

HEALTH_RC=9
if _agent_preflight "resume" health_probe --model test >/dev/null 2>&1; then
  fail "agent preflight continued after its runtime health check failed"
else
  ok "agent preflight propagates runtime health-check failures"
fi

mkdir -p "$TEST_DEV/dotfiles/claude/scripts"
cat > "$TEST_DEV/dotfiles/check-claude.sh" <<'EOF'
#!/usr/bin/env bash
printf 'claude:%s\n' "$*" >> "$WRAPPER_CALLS"
[ "${1:-}" = "--heal" ] || exit 8
exit "${CHECK_RC:-9}"
EOF
cat > "$TEST_DEV/dotfiles/check-codex.sh" <<'EOF'
#!/usr/bin/env bash
printf 'codex:%s\n' "$*" >> "$WRAPPER_CALLS"
exit "${CHECK_RC:-9}"
EOF
cat > "$TEST_DEV/dotfiles/check-antigravity.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--strict" ] || exit 8
exit "${CHECK_RC:-9}"
EOF
cat > "$TEST_DEV/dotfiles/claude/scripts/sync-plugins.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DEV/dotfiles/check-claude.sh" \
  "$TEST_DEV/dotfiles/check-codex.sh" \
  "$TEST_DEV/dotfiles/check-antigravity.sh" \
  "$TEST_DEV/dotfiles/claude/scripts/sync-plugins.sh"
sync-memory() { return 0; }
export WRAPPER_CALLS

if _check_claude_launch_health >/dev/null 2>&1 \
  || _check_codex_launch_health >/dev/null 2>&1 \
  || _check_antigravity_launch_health >/dev/null 2>&1; then
  fail "a launcher health wrapper ignored actual checker failure"
else
  ok "all launcher integrations propagate strict runtime checker failures"
fi

if grep -Fxq 'codex:--heal --strict' "$WRAPPER_CALLS"; then
  ok "Codex launcher safely heals missing managed links before strict validation"
else
  fail "Codex launcher did not enable safe managed-link healing"
fi

# ── Memory sync failure must not hide the Claude config health check ───
sync-memory() {
  echo "  Memory commit stayed local because its committed history failed validation." >&2
  return 1
}
: > "$WRAPPER_CALLS"
health_err="$( { CHECK_RC=0 _check_claude_launch_health >/dev/null; } 2>&1 )"
health_rc=$?
if [ "$health_rc" -eq 0 ] && grep -Fxq 'claude:--heal' "$WRAPPER_CALLS" \
  && grep -q 'continuing with local memory' <<< "$health_err" \
  && grep -q 'stayed local' <<< "$health_err"; then
  ok "a failed memory sync warns, keeps its diagnostic, and still runs check-claude --heal"
else
  fail "memory sync failure rc=$health_rc, wrapper calls: $(tr '\n' '|' < "$WRAPPER_CALLS"), stderr: $health_err"
fi

: > "$WRAPPER_CALLS"
if CHECK_RC=9 _check_claude_launch_health >/dev/null 2>&1; then
  fail "a failed Claude config check was hidden behind the memory sync warning"
elif grep -Fxq 'claude:--heal' "$WRAPPER_CALLS"; then
  ok "config health failure still fails the Claude wrapper when memory sync also failed"
else
  fail "the Claude wrapper failed without running its config checker"
fi

sync-memory() { return 0; }
health_err="$( { CHECK_RC=0 _check_claude_launch_health >/dev/null; } 2>&1 )"
if [ -z "$health_err" ]; then
  ok "a successful memory sync emits no warning"
else
  fail "a successful memory sync warned: $health_err"
fi

# ── Launchers reach the runtime on sync failure, never on health failure ─
unset ALL_PULLS_SUCCEED BROKEN_REPO_HEALTHY
export CODEX_MEMORY_REPO="$TEST_DEV/.no-such-codex-memory"
mkdir -p "$TEST_HOME/.claude"
printf '{}\n' > "$TEST_HOME/.claude-settings-target"
: > "$TEST_HOME/.claude-md-target"
ln -s "$TEST_HOME/.claude-settings-target" "$TEST_HOME/.claude/settings.json"
ln -s "$TEST_HOME/.claude-md-target" "$TEST_HOME/.claude/CLAUDE.md"
sync-memory() { return 1; }

: > "$RUNTIME_CALLS"
cx_err="$( { CHECK_RC=0 cx exec task >/dev/null; } 2>&1 )"
cx_rc=$?
if [ "$cx_rc" -eq 0 ] && grep -Fxq 'codex|--strict-config exec task' "$RUNTIME_CALLS" \
  && grep -q 'bad: fatal: simulated pull failure' <<< "$cx_err"; then
  ok "cx launches Codex on a sync failure with healthy config, with the warning visible"
else
  fail "cx rc=$cx_rc, runtime calls: $(tr '\n' '|' < "$RUNTIME_CALLS"), stderr: $cx_err"
fi

: > "$RUNTIME_CALLS"
if CHECK_RC=9 cx exec task >/dev/null 2>&1; then
  fail "cx launched Codex after its config health check failed"
elif [ ! -s "$RUNTIME_CALLS" ]; then
  ok "cx never reaches Codex when config health fails alongside a sync failure"
else
  fail "cx invoked Codex despite the health failure: $(cat "$RUNTIME_CALLS")"
fi

: > "$RUNTIME_CALLS"
cc_err="$( { CHECK_RC=0 cc --model test >/dev/null; } 2>&1 )"
cc_rc=$?
if [ "$cc_rc" -eq 0 ] && grep -Fxq 'claude|--remote-control --chrome --model test' "$RUNTIME_CALLS" \
  && grep -q 'continuing with local memory' <<< "$cc_err" \
  && grep -q 'bad: fatal: simulated pull failure' <<< "$cc_err"; then
  ok "cc launches Claude on repo and memory sync failures with healthy config"
else
  fail "cc rc=$cc_rc, runtime calls: $(tr '\n' '|' < "$RUNTIME_CALLS"), stderr: $cc_err"
fi

: > "$RUNTIME_CALLS"
if CHECK_RC=9 cc --model test >/dev/null 2>&1; then
  fail "cc launched Claude after its config health check failed"
elif [ ! -s "$RUNTIME_CALLS" ]; then
  ok "cc never reaches Claude when config health fails alongside sync failures"
else
  fail "cc invoked Claude despite the health failure: $(cat "$RUNTIME_CALLS")"
fi
sync-memory() { return 0; }

# ── Resume classification (unchanged behavior) ─────────────────────────
: > "$HEALTH_CALLS"
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

# Fresh launches are told apart from resumes by whether pull-all ran: a
# fresh launch prints "Syncing repos..." and the sync warning, a resume prints
# neither.
fresh_launch_synced() {  # fresh_launch_synced RESUME_KEYS ARGS…
  local keys="$1" out
  shift
  : > "$HEALTH_CALLS"
  out="$(_agent_preflight "$keys" health_probe "$@" 2>&1)"
  grep -q 'Syncing repos' <<< "$out" && [ -s "$HEALTH_CALLS" ]
}

if fresh_launch_synced "resume fork" 'resume=database'; then
  ok "equals matching is opt-in and does not misclassify Codex prompts"
else
  fail "a fresh Codex prompt containing resume= skipped repository pulls"
fi

if fresh_launch_synced "--resume --resume=" -- '--resume=prompt'; then
  ok "resume detection stops at the option terminator"
else
  fail "prompt text after -- was classified as a resume flag"
fi

if fresh_launch_synced "resume fork" exec resume; then
  ok "bare Codex resume subcommands are recognized only in command position"
else
  fail "a positional Codex prompt word was classified as a resume subcommand"
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

# Separated --image/-i VALUE forms are valid Codex global options; the parser
# must consume the value and still see the resume subcommand (issue #276).
if _codex_is_resume_invocation --image /tmp/example.png resume --last \
  && _codex_is_resume_invocation -i /tmp/example.png fork --last \
  && ! _codex_is_resume_invocation --image /tmp/example.png exec 'task' \
  && ! _codex_is_resume_invocation --image; then
  ok "Codex resume parser consumes separated image option values"
else
  fail "a separated --image value hid the resume subcommand from the parser"
fi

echo ""
echo "agent-preflight: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
