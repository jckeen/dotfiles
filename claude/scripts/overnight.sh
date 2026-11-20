#!/usr/bin/env bash
# overnight.sh — Run all repos through health checks + optional deeper work
# Designed for off-peak hours. Runs health checks in parallel across all repos,
# then optionally runs deeper tasks sequentially.
#
# Usage:
#   overnight.sh                          # health checks only (safe, read-only)
#   overnight.sh --deep                   # health + test coverage + issue fixes
#   overnight.sh --deep --full-auto       # full autonomous mode (be sure!)
#
# Configure your repos below or set CLAUDE_REPOS env var:
#   export CLAUDE_REPOS="~/dev/beacon ~/dev/stringer ~/dev/smss"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEEP=false
FULL_AUTO_ARGS=()
LOG_DIR="${LOG_DIR:-$HOME/.claude/logs}"
RUN_STAMP="$(date +%Y-%m-%d_%H%M%S)"
SUMMARY_FILE="$LOG_DIR/overnight-summary-${RUN_STAMP}.md"

# Parse args
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=true ;;
    --full-auto) FULL_AUTO_ARGS=(--full-auto) ;;
  esac
done

# ─── Repo Discovery ───────────────────────────────────────────
# Priority: CLAUDE_REPOS env var > config file > auto-detect from dev directory
#
# To set your dev directory, either:
#   export CLAUDE_DEV_DIR=~/dev           (env var)
#   echo ~/dev > ~/.claude/dev-dir        (config file)
#   Or it defaults to ~/dev
#
# To set explicit repos:
#   export CLAUDE_REPOS="~/dev/beacon ~/dev/stringer"
#   Or list them in ~/.claude/repos (one path per line)

discover_dev_dir() {
  # 1. Env var override
  if [[ -n "${CLAUDE_DEV_DIR:-}" ]]; then
    echo "$CLAUDE_DEV_DIR"
    return
  fi

  # 2. Config file (written by setup.sh — single source of truth)
  if [[ -f "$HOME/.claude/dev-dir" ]]; then
    cat "$HOME/.claude/dev-dir"
    return
  fi

  # 3. Default ~/dev
  echo "$HOME/dev"
}

discover_repos() {
  # 1. CLAUDE_REPOS env var (space-separated)
  if [[ -n "${CLAUDE_REPOS:-}" ]]; then
    read -ra repos <<< "$CLAUDE_REPOS"
    printf '%s\n' "${repos[@]}"
    return
  fi

  # 2. Config file (one repo per line)
  if [[ -f "$HOME/.claude/repos" ]]; then
    grep -v '^\s*#' "$HOME/.claude/repos" | grep -v '^\s*$'
    return
  fi

  # 3. Auto-detect: find git repos in the dev directory
  local dev_dir
  dev_dir=$(discover_dev_dir)
  if [[ ! -d "$dev_dir" ]]; then
    echo "Error: dev directory not found: $dev_dir" >&2
    echo "Set CLAUDE_DEV_DIR or create ~/.claude/dev-dir" >&2
    exit 1
  fi

  for dir in "$dev_dir"/*/; do
    if [[ -d "$dir/.git" ]]; then
      echo "${dir%/}"
    fi
  done
}

mapfile -t REPOS < <(discover_repos)

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "No repos found. Set CLAUDE_REPOS, create ~/.claude/repos, or put git repos in ~/dev/"
  exit 1
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Claude Overnight Runner                             ║"
echo "║  Repos: ${#REPOS[@]}                                 ║"
echo "║  Mode: $([ "$DEEP" = true ] && echo "deep" || echo "health-only")  ║"
echo "║  Auto: $([ ${#FULL_AUTO_ARGS[@]} -gt 0 ] && echo "FULL AUTO" || echo "scoped permissions")  ║"
echo "║  Started: $(date)                                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

mkdir -p "$LOG_DIR"
{
  printf '# Overnight Run Summary (%s)\n\n' "$RUN_STAMP"
  printf '| Repo | Phase | Status | Exit | Note |\n'
  printf '| --- | --- | --- | --- | --- |\n'
} > "$SUMMARY_FILE"

record_status() {
  local repo_name="$1" phase="$2" status="$3" rc="$4" note="${5:-}"
  printf '| %s | %s | %s | %s | %s |\n' "$repo_name" "$phase" "$status" "$rc" "$note" >> "$SUMMARY_FILE"
}

any_failures=0

# Phase 1: Health checks in parallel (read-only, always safe)
echo "═══ Phase 1: Health Checks (parallel) ═══"
pids=()
pid_repos=()
for repo in "${REPOS[@]}"; do
  if [[ -d "$repo" ]]; then
    echo "→ Starting health check: $(basename "$repo")"
    "$SCRIPT_DIR/health-check.sh" "$repo" "${FULL_AUTO_ARGS[@]}" &
    pids+=($!)
    pid_repos+=("$(basename "$repo")")
  else
    echo "⚠ Skipping $repo (not found)"
    record_status "$(basename "$repo")" "health-check" "skipped" "0" "repo missing"
  fi
done

# Wait for all health checks
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  rname="${pid_repos[$i]}"
  rc=0
  wait "$pid" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "⚠ Health check for $rname (PID $pid) exited with code $rc"
    record_status "$rname" "health-check" "failed" "$rc" "see logs"
    any_failures=1
  else
    record_status "$rname" "health-check" "passed" "0" ""
  fi
done
echo ""
echo "═══ Phase 1 complete ═══"

# Phase 2: Deeper work (sequential, only with --deep)
if [[ "$DEEP" == "true" ]]; then
  declare -A skip_phase3=()
  echo ""
  echo "═══ Phase 2: Test Coverage (sequential) ═══"
  for repo in "${REPOS[@]}"; do
    if [[ -d "$repo" ]]; then
      rname="$(basename "$repo")"
      status_out=""
      if [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]] \
        || ! status_out="$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        echo "⚠ Skipping Phase 2 for $rname: git status inspection failed"
        record_status "$rname" "test-coverage" "failed" "1" "git status inspection failed"
        any_failures=1
        skip_phase3["$repo"]=1
        continue
      elif [[ -n "$status_out" ]]; then
        echo "⚠ Skipping Phase 2 for $rname: working tree has pre-existing uncommitted changes"
        record_status "$rname" "test-coverage" "skipped" "1" "pre-existing dirty working tree"
        any_failures=1
        skip_phase3["$repo"]=1
        continue
      fi
      echo "→ Improving tests: $rname"
      rc=0
      "$SCRIPT_DIR/test-coverage.sh" "$repo" "${FULL_AUTO_ARGS[@]}" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        echo "⚠ Test coverage failed for $rname (exit $rc)"
        record_status "$rname" "test-coverage" "failed" "$rc" "see logs"
        any_failures=1
      else
        record_status "$rname" "test-coverage" "passed" "0" ""
      fi
      # Isolate any uncommitted Phase 2 edits before Phase 3 runs on the repo.
      dirty=""
      if [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]] \
        || ! dirty="$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        echo "⚠ Failed to inspect Phase 2 working tree in $rname"
        record_status "$rname" "phase2-stash" "failed" "1" "git status inspection failed"
        any_failures=1
        skip_phase3["$repo"]=1
      elif [[ -n "$dirty" ]]; then
        stash_msg="overnight-phase2-autostash-${RUN_STAMP}"
        if git -C "$repo" stash push -u -m "$stash_msg" >/dev/null 2>&1; then
          echo "→ Stashed uncommitted Phase 2 edits in $rname ($stash_msg)"
          record_status "$rname" "phase2-stash" "stashed" "0" "$stash_msg"
        else
          echo "⚠ Failed to stash dirty Phase 2 tree in $rname"
          record_status "$rname" "phase2-stash" "failed" "1" "dirty tree left for phase 3"
          any_failures=1
          skip_phase3["$repo"]=1
        fi
      fi
    fi
  done

  echo ""
  echo "═══ Phase 3: Issue Fixes (sequential) ═══"
  for repo in "${REPOS[@]}"; do
    if [[ -d "$repo" ]]; then
      rname="$(basename "$repo")"
      p3_dirty=""
      p3_ok=1
      if [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]] \
        || ! p3_dirty="$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        p3_ok=0
      fi
      if [[ -n "${skip_phase3[$repo]:-}" || "$p3_ok" -ne 1 || -n "$p3_dirty" ]]; then
        echo "⚠ Skipping Phase 3 for $rname: working tree is not clean or Phase 2 isolation failed"
        record_status "$rname" "fix-issues" "skipped" "1" "dirty working tree / phase 2 isolation failed"
        any_failures=1
        continue
      fi
      echo "→ Fixing issues: $rname"
      rc=0
      "$SCRIPT_DIR/fix-issues.sh" "$repo" "${FULL_AUTO_ARGS[@]}" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        echo "⚠ Issue fix failed for $rname (exit $rc)"
        record_status "$rname" "fix-issues" "failed" "$rc" "see logs"
        any_failures=1
      else
        record_status "$rname" "fix-issues" "passed" "0" ""
      fi
    fi
  done
fi

echo ""
echo "═══ Done: $(date) ═══"
echo "Logs: $LOG_DIR"
echo "Summary: $SUMMARY_FILE"
if [[ "$any_failures" -ne 0 ]]; then
  echo "⚠ One or more overnight tasks failed — see $SUMMARY_FILE" >&2
  exit 1
fi
