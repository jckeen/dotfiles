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
FULL_AUTO_FLAG=""

# Parse args
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=true ;;
    --full-auto) FULL_AUTO_FLAG="--full-auto" ;;
  esac
done

# Default repos — override with CLAUDE_REPOS env var
DEFAULT_REPOS=(
  "$HOME/dev/atlas"
  "$HOME/dev/stringer"
  "$HOME/dev/smss"
  "$HOME/dev/TRNN"
  "$HOME/dev/pp2qbo"
)

if [[ -n "${CLAUDE_REPOS:-}" ]]; then
  read -ra REPOS <<< "$CLAUDE_REPOS"
else
  REPOS=("${DEFAULT_REPOS[@]}")
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Claude Overnight Runner                             ║"
echo "║  Repos: ${#REPOS[@]}                                 ║"
echo "║  Mode: $([ "$DEEP" = true ] && echo "deep" || echo "health-only")  ║"
echo "║  Auto: $([ -n "$FULL_AUTO_FLAG" ] && echo "FULL AUTO" || echo "scoped permissions")  ║"
echo "║  Started: $(date)                                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Phase 1: Health checks in parallel (read-only, always safe)
echo "═══ Phase 1: Health Checks (parallel) ═══"
pids=()
for repo in "${REPOS[@]}"; do
  if [[ -d "$repo" ]]; then
    echo "→ Starting health check: $(basename "$repo")"
    "$SCRIPT_DIR/health-check.sh" "$repo" $FULL_AUTO_FLAG &
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
      "$SCRIPT_DIR/test-coverage.sh" "$repo" $FULL_AUTO_FLAG || true
    fi
  done

  echo ""
  echo "═══ Phase 3: Issue Fixes (sequential) ═══"
  for repo in "${REPOS[@]}"; do
    if [[ -d "$repo" ]]; then
      echo "→ Fixing issues: $(basename "$repo")"
      "$SCRIPT_DIR/fix-issues.sh" "$repo" $FULL_AUTO_FLAG || true
    fi
  done
fi

echo ""
echo "═══ Done: $(date) ═══"
echo "Logs: $HOME/.claude/logs/"
