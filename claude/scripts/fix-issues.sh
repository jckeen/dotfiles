#!/usr/bin/env bash
# fix-issues.sh — Pick up GitHub issues and fix them (TIER_COMMIT)
# Creates a branch per issue, writes the fix, commits (does NOT push).
# Review branches with `git log --all --oneline` after it runs.
#
# Usage:
#   fix-issues.sh /path/to/repo                    # picks oldest open issue
#   fix-issues.sh /path/to/repo --max-turns 20

source "$(dirname "$0")/common.sh"
parse_args "$@"

run_claude "TIER_COMMIT" "
You are picking up open GitHub issues for this repo.

1. Run \`gh issue list --state open --limit 5\` to see open issues.
2. Pick the oldest actionable issue (skip ones that need clarification).
3. Create a branch: fix/issue-NUMBER
4. Read the relevant code, understand the problem.
5. Write a failing test that reproduces the issue.
6. Implement the fix.
7. Run the full test suite to verify nothing broke.
8. Commit with message: fix: short description (closes #NUMBER)

Do NOT push. Leave the branch for review.
Output: which issue you fixed, what you changed, test results.
"
