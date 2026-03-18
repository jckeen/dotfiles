#!/usr/bin/env bash
# common.sh — shared config for autonomous Claude Code scripts
# Source this from other scripts: source "$(dirname "$0")/common.sh"

set -euo pipefail

# ─── Safety Tiers ──────────────────────────────────────────────
# Each tier is an array of --allowedTools arguments.
# Scripts pick the minimum tier needed for their job.

# TIER 1: Read-only — can't change anything
TIER_READONLY=(Read Grep Glob "Bash(git status)" "Bash(git log *)" "Bash(git diff *)")

# TIER 2: Lint & test — can read + run build/test commands
TIER_LINT=(Read Grep Glob Edit \
  "Bash(npm test *)" "Bash(npm run lint *)" "Bash(npm run build *)" \
  "Bash(npx *)" "Bash(pip *)" "Bash(pytest *)" "Bash(cargo test *)" \
  "Bash(git status)" "Bash(git log *)" "Bash(git diff *)")

# TIER 3: Fix — can edit files + run tests (but not commit/push)
TIER_FIX=(Read Grep Glob Edit Write \
  "Bash(npm test *)" "Bash(npm run lint *)" "Bash(npm run build *)" \
  "Bash(npx *)" "Bash(pip *)" "Bash(pytest *)" "Bash(cargo test *)" \
  "Bash(git status)" "Bash(git log *)" "Bash(git diff *)" "Bash(git stash *)")

# TIER 4: Commit — can edit + commit (but not push)
TIER_COMMIT=(Read Grep Glob Edit Write \
  "Bash(npm test *)" "Bash(npm run lint *)" "Bash(npm run build *)" \
  "Bash(npx *)" "Bash(npm audit *)" "Bash(npm outdated *)" \
  "Bash(pip *)" "Bash(pytest *)" "Bash(cargo test *)" "Bash(cargo audit *)" \
  "Bash(git status)" "Bash(git log *)" "Bash(git diff *)" "Bash(git stash *)" \
  "Bash(git add *)" "Bash(git commit *)" "Bash(git branch *)" "Bash(git checkout *)")

# TIER 5: Push — full git workflow (only used by review-and-push after validation)
TIER_PUSH=(Read Grep Glob Edit Write \
  "Bash(npm test *)" "Bash(npm run lint *)" "Bash(npm run build *)" \
  "Bash(npx *)" "Bash(pip *)" "Bash(pytest *)" "Bash(cargo test *)" \
  "Bash(git status)" "Bash(git log *)" "Bash(git diff *)" \
  "Bash(git add *)" "Bash(git commit *)" "Bash(git push *)" \
  "Bash(git branch *)" "Bash(git checkout *)" \
  "Bash(gh pr *)")

# ─── Defaults ──────────────────────────────────────────────────

MAX_TURNS="${MAX_TURNS:-15}"
LOG_DIR="${LOG_DIR:-$HOME/.claude/logs}"
MODEL="${MODEL:-opus}"

# ─── Helpers ───────────────────────────────────────────────────

log_file() {
  local name="$1"
  local repo_name
  repo_name=$(basename "$REPO_DIR")
  local timestamp
  timestamp=$(date +%Y-%m-%d_%H%M)
  mkdir -p "$LOG_DIR"
  echo "$LOG_DIR/${name}_${repo_name}_${timestamp}.log"
}

build_allowed_tools_args() {
  local -n tier_ref=$1
  local args=""
  for tool in "${tier_ref[@]}"; do
    args+="--allowedTools \"$tool\" "
  done
  echo "$args"
}

run_claude() {
  local tier_name="$1"
  local prompt="$2"
  local extra_args="${3:-}"
  local log
  log=$(log_file "$tier_name")

  # Build --allowedTools from the tier
  local -n tier=$tier_name
  local tool_args=()
  for tool in "${tier[@]}"; do
    tool_args+=(--allowedTools "$tool")
  done

  # Check for --full-auto override
  local perm_args=()
  if [[ "${FULL_AUTO:-false}" == "true" ]]; then
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ⚠  FULL AUTO MODE — all permissions bypassed       ║"
    echo "║  Override: FULL_AUTO=true                            ║"
    echo "║  Repo: $REPO_DIR"
    echo "╚══════════════════════════════════════════════════════╝"
    perm_args=(--dangerously-skip-permissions)
    tool_args=()  # not needed with full bypass
  fi

  echo "→ Running: $tier_name"
  echo "→ Repo: $REPO_DIR"
  echo "→ Max turns: $MAX_TURNS"
  echo "→ Log: $log"
  echo ""

  cd "$REPO_DIR"

  claude -p "$prompt" \
    "${tool_args[@]}" \
    "${perm_args[@]}" \
    --max-turns "$MAX_TURNS" \
    --model "$MODEL" \
    $extra_args \
    2>&1 | tee "$log"
}

# ─── Argument Parsing ─────────────────────────────────────────

parse_args() {
  REPO_DIR=""
  FULL_AUTO="${FULL_AUTO:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full-auto)
        FULL_AUTO=true
        shift
        ;;
      --max-turns)
        MAX_TURNS="$2"
        shift 2
        ;;
      --log-dir)
        LOG_DIR="$2"
        shift 2
        ;;
      *)
        REPO_DIR="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$REPO_DIR" ]]; then
    echo "Usage: $(basename "$0") <repo-path> [--full-auto] [--max-turns N]"
    exit 1
  fi

  # Resolve to absolute path
  REPO_DIR=$(cd "$REPO_DIR" && pwd)
}
