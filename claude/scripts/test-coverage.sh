#!/usr/bin/env bash
# test-coverage.sh — Write tests to improve coverage (TIER_FIX)
# Can edit/create test files and run tests, but won't commit.
# Review the changes with `git diff` after it runs.
#
# Usage:
#   test-coverage.sh /path/to/repo
#   test-coverage.sh /path/to/repo --max-turns 20
#   FULL_AUTO=true test-coverage.sh /path/to/repo  # bypass all permissions

source "$(dirname "$0")/common.sh"
parse_args "$@"

run_claude "TIER_FIX" "
You are a test engineer improving test coverage for this project.

1. Read the existing test files to understand the testing patterns and framework.
2. Identify the most critical untested code — focus on:
   - Core business logic with no tests
   - Recent changes (git log --oneline -10) that lack test coverage
   - Edge cases in existing tested code
3. Write focused tests following the project's existing patterns.
4. Run the test suite to verify all tests pass (existing and new).
5. If any new test fails, fix it.

Do NOT commit. Leave changes staged for review.
Output a summary of what was added and test results.
"
