#!/usr/bin/env bash
# review-and-push.sh — Review overnight changes, then push if safe
# Uses the required Codex gate and validates its receipt immediately before push.
#
# Flow:
#   1. Check for uncommitted/committed changes since last push
#   2. Run tests — STOP if they fail
#   3. Run the required Codex review gate on the committed delta
#   4. Prompt to push (or accept --auto-push)
#   5. Validate the current review receipt, then push
#
# Usage:
#   review-and-push.sh /path/to/repo              # interactive (prompts before push)
#   review-and-push.sh /path/to/repo --auto-push   # push automatically if safe
#
# Run this in the morning after overnight.sh finishes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

AUTO_PUSH=false

# Extended parse_args to handle --auto-push
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --auto-push) AUTO_PUSH=true ;;
    *) FILTERED_ARGS+=("$arg") ;;
  esac
done
parse_args "${FILTERED_ARGS[@]}"

cd "$REPO_DIR" || exit 1
REPO_NAME=$(basename "$REPO_DIR")
BRANCH_REF=$(git symbolic-ref --quiet HEAD) || {
  echo "Create a non-default branch before reviewing and pushing." >&2
  exit 1
}
BRANCH=${BRANCH_REF#refs/heads/}
REMOTE=$(git config --get "branch.$BRANCH.remote" || printf '%s\n' origin)
PUSH_URL=$(git remote get-url --push --all -- "$REMOTE")
if [[ -z "$PUSH_URL" || "$PUSH_URL" == *$'\n'* ]]; then
  echo "Review and push requires one unambiguous push destination." >&2
  exit 1
fi

check_destination() {
  local remote_head default_ref
  # get-url already applied one rewrite. A second invocation must use the
  # same endpoint, including rules from global, local, and included config.
  if ! python3 - "$PUSH_URL" <<'PY'
import os
import subprocess
import sys

config = subprocess.run(
    ["git", "config", "--null", "--get-regexp", r"^url\..*\.(insteadof|pushinsteadof)$"],
    stdout=subprocess.PIPE,
)
if config.returncode not in (0, 1):
    sys.exit(1)
destination = os.fsencode(sys.argv[1])
for record in config.stdout.split(b"\0"):
    if record and destination.startswith(record.split(b"\n", 1)[1]):
        sys.exit(1)
PY
  then
    echo "Cannot pin the push destination: a Git URL rewrite still applies, or its configuration could not be read. Use a direct destination without further rewrites." >&2
    return 1
  fi
  remote_head=$(git ls-remote --symref -- "$PUSH_URL" HEAD) || return 1
  default_ref=$(awk '$1 == "ref:" && $3 == "HEAD" && $2 ~ /^refs\/heads\// {print $2}' <<< "$remote_head")
  if [[ -z "$default_ref" || "$default_ref" == *$'\n'* ]]; then
    echo "Cannot establish the push destination's default branch." >&2
    return 1
  fi
  if [[ "$BRANCH_REF" == "$default_ref" ]]; then
    echo "Create a non-default branch and pull request; this script does not push the default branch." >&2
    return 1
  fi
}
check_destination

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Review & Push: $REPO_NAME"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: What changed? ────────────────────────────────────

# Check if there's anything to review
if git rev-parse --verify '@{u}' >/dev/null 2>&1; then
  UNPUSHED=$(git log '@{u}..HEAD' --oneline)
else
  UNPUSHED=$(git log -1 --oneline)
fi
UNSTAGED=$(git status --porcelain 2>/dev/null || echo "")

if [[ -z "$UNPUSHED" && -z "$UNSTAGED" ]]; then
  echo "Nothing to review — repo is clean and up to date."
  exit 0
fi

echo "═══ Unpushed commits ═══"
if [[ -n "$UNPUSHED" ]]; then
  echo "$UNPUSHED"
else
  echo "(none)"
fi
echo ""

if [[ -n "$UNSTAGED" ]]; then
  echo "═══ Uncommitted changes ═══"
  echo "$UNSTAGED"
  echo ""
  echo "⚠ There are uncommitted changes. These will NOT be pushed."
  echo "  Review them manually or run the overnight scripts again."
  echo ""
fi

# ─── Step 2: Run tests ────────────────────────────────────────

echo "═══ Running tests ═══"
TEST_LOG=$(log_file "tests")

# Detect and run the test command
TEST_RESULT=0
if [[ -f "package.json" ]]; then
  npm test 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
  pytest 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "Cargo.toml" ]]; then
  cargo test 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "go.mod" ]]; then
  go test ./... 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
else
  echo "(no test framework detected — skipping)"
fi

if [[ $TEST_RESULT -ne 0 ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  TESTS FAILED — not pushing.                        ║"
  echo "║  Fix the failures and try again.                    ║"
  echo "╚══════════════════════════════════════════════════════╝"
  exit 1
fi
echo ""

# ─── Step 3: Review the committed artifact ──────────────────────

"$SCRIPT_DIR/codex-review-gate.sh" --require

if [[ "$AUTO_PUSH" != "true" ]]; then
  read -rp "Push to remote? (Y/n): " CONFIRM
  if [[ "$CONFIRM" != "" && "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted. Changes remain local."
    exit 0
  fi
fi

# The confirmation or another process may have changed the reviewed artifact.
if [[ "$(git symbolic-ref --quiet HEAD)" != "$BRANCH_REF" ]]; then
  echo "Branch changed during review; review again on the intended branch." >&2
  exit 1
fi
check_destination
REVIEWED_HEAD=$(git rev-parse HEAD)
python3 "$SCRIPT_DIR/review-receipt.py" check --repo "$REPO_DIR" --head "$REVIEWED_HEAD"
git push --no-follow-tags -- "$PUSH_URL" "$REVIEWED_HEAD:$BRANCH_REF"
echo "Pushed."
