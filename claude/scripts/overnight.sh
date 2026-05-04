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
#   export CLAUDE_REPOS="~/dev/atlas ~/dev/stringer ~/dev/smss"

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
DEEP=false
FULL_AUTO_ARGS=()

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
#   export CLAUDE_REPOS="~/dev/atlas ~/dev/stringer"
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

# Phase 1: Health checks in parallel (read-only, always safe)
echo "═══ Phase 1: Health Checks (parallel) ═══"
pids=()
for repo in "${REPOS[@]}"; do
  if [[ -d "$repo" ]]; then
    echo "→ Starting health check: $(basename "$repo")"
    "$SCRIPT_DIR/health-check.sh" "$repo" "${FULL_AUTO_ARGS[@]}" &
    pids+=($!)
  else
    echo "⚠ Skipping $repo (not found)"
  fi
done

# Wait for all health checks
for pid in "${pids[@]}"; do
  wait "$pid" || echo "⚠ Health check PID $pid exited with error"
done
echo ""
echo "═══ Phase 1 complete ═══"

# Phase 2: Deeper work (sequential, only with --deep)
if [[ "$DEEP" == "true" ]]; then
  echo ""
  echo "═══ Phase 2: Test Coverage (sequential) ═══"
  for repo in "${REPOS[@]}"; do
    if [[ -d "$repo" ]]; then
      echo "→ Improving tests: $(basename "$repo")"
      "$SCRIPT_DIR/test-coverage.sh" "$repo" "${FULL_AUTO_ARGS[@]}" || true
    fi
  done

  echo ""
  echo "═══ Phase 3: Issue Fixes (sequential) ═══"
  for repo in "${REPOS[@]}"; do
    if [[ -d "$repo" ]]; then
      echo "→ Fixing issues: $(basename "$repo")"
      "$SCRIPT_DIR/fix-issues.sh" "$repo" "${FULL_AUTO_ARGS[@]}" || true
    fi
  done
fi

echo ""
echo "═══ Done: $(date) ═══"
echo "Logs: $HOME/.claude/logs/"
