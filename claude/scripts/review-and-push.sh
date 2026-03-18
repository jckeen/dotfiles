#!/usr/bin/env bash
# review-and-push.sh — Review overnight changes, then push if safe
# Uses Claude to review Claude's work with a fresh context.
#
# Flow:
#   1. Check for uncommitted/committed changes since last push
#   2. Run tests — STOP if they fail
#   3. Run a security + quality review on the diff
#   4. Generate a one-page summary for you
#   5. If tests pass and no CRITICAL findings: prompt to push
#   6. Push only with your confirmation (or --auto-push)
#
# Usage:
#   review-and-push.sh /path/to/repo              # interactive (prompts before push)
#   review-and-push.sh /path/to/repo --auto-push   # push automatically if safe
#
# Run this in the morning after overnight.sh finishes.

source "$(dirname "$0")/common.sh"

AUTO_PUSH=false

# Extended parse_args to handle --auto-push
ORIG_ARGS=("$@")
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --auto-push) AUTO_PUSH=true ;;
    *) FILTERED_ARGS+=("$arg") ;;
  esac
done
parse_args "${FILTERED_ARGS[@]}"

cd "$REPO_DIR"
REPO_NAME=$(basename "$REPO_DIR")

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Review & Push: $REPO_NAME"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: What changed? ────────────────────────────────────

# Check if there's anything to review
UNPUSHED=$(git log @{u}..HEAD --oneline 2>/dev/null || echo "")
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

# ─── Step 3: AI review of the diff ────────────────────────────

echo "═══ AI Review ═══"

DIFF_STAT=$(git diff @{u}..HEAD --stat 2>/dev/null || echo "no upstream to compare")
DIFF_FULL=$(git diff @{u}..HEAD 2>/dev/null || echo "")
COMMIT_LOG=$(git log @{u}..HEAD --format="%h %s" 2>/dev/null || echo "")

REVIEW_LOG=$(log_file "review")

# Use structured JSON output for the review
claude -p "
You are reviewing changes made by an autonomous Claude Code session overnight.
Your job is to catch anything that should NOT be pushed.

## Commits being reviewed:
$COMMIT_LOG

## Diff stats:
$DIFF_STAT

## Full diff:
$DIFF_FULL

## Review checklist:
1. **Tests**: Do the changes include tests? Do they look correct?
2. **Security**: Any secrets, credentials, or injection risks introduced?
3. **Correctness**: Do the changes actually fix/implement what the commit messages claim?
4. **Regressions**: Could any of these changes break existing functionality?
5. **Code quality**: Any obvious issues (dead code, bad patterns, missing error handling)?

## Output format:
Start with a VERDICT line — one of:
- VERDICT: SAFE TO PUSH — no critical issues found
- VERDICT: NEEDS REVIEW — issues found that a human should look at
- VERDICT: DO NOT PUSH — critical problems detected

Then a brief summary (under 20 lines) of:
- What changed (high level)
- Number of files / lines changed
- Any findings by severity (CRITICAL / HIGH / MEDIUM / LOW)
- Specific concerns if any

Be concise. The reader wants a 30-second decision, not a thesis.
" \
  --allowedTools "Read" "Grep" "Glob" \
  --max-turns 5 \
  --model "$MODEL" \
  2>&1 | tee "$REVIEW_LOG"

echo ""

# ─── Step 4: Extract verdict and decide ───────────────────────

VERDICT=$(grep -i "VERDICT:" "$REVIEW_LOG" | head -1 || echo "VERDICT: UNKNOWN")

echo "═══════════════════════════════════════════════════════"
echo "  $VERDICT"
echo "═══════════════════════════════════════════════════════"
echo ""

if echo "$VERDICT" | grep -qi "DO NOT PUSH"; then
  echo "Blocking push. Review the log: $REVIEW_LOG"
  exit 1
fi

if echo "$VERDICT" | grep -qi "NEEDS REVIEW"; then
  if [[ "$AUTO_PUSH" == "true" ]]; then
    echo "Auto-push enabled but review flagged issues. NOT pushing."
    echo "Review the log: $REVIEW_LOG"
    exit 1
  fi
  echo "The review flagged issues. Read the summary above."
  read -rp "Push anyway? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted. Changes remain local."
    exit 0
  fi
fi

if echo "$VERDICT" | grep -qi "SAFE TO PUSH"; then
  if [[ "$AUTO_PUSH" == "true" ]]; then
    echo "Auto-pushing (tests passed, review clean)..."
    git push
    echo "Pushed."
    exit 0
  fi
  read -rp "Push to remote? (Y/n): " CONFIRM
  if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
    echo "Aborted. Changes remain local."
    exit 0
  fi
  git push
  echo "Pushed."
  exit 0
fi

# Unknown verdict — be safe
echo "Could not determine verdict. Review manually."
echo "Log: $REVIEW_LOG"
exit 1
