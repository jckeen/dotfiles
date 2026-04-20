#!/usr/bin/env bash
# health-check.sh — Read-only repo health check (TIER_READONLY)
# Runs repo-scout + dependency-doctor, outputs a report. Changes nothing.
#
# Usage:
#   health-check.sh /path/to/repo
#   health-check.sh /path/to/repo --max-turns 10
#
# To run across all repos:
#   for repo in ~/dev/atlas ~/dev/stringer ~/dev/smss; do
#     health-check.sh "$repo" &
#   done; wait

source "$(dirname "$0")/common.sh"
parse_args "$@"

run_claude "TIER_READONLY" "
You are doing a health check on this repository. Do the following:

1. Act as repo-scout: Read CLAUDE.md, CHANGELOG.md, package.json (or equivalent),
   .claude/handoffs/ (latest file), git status, git log --oneline -10.
   Produce a concise briefing: project name, stack, status, last handoff, blockers, next steps.

2. Act as dependency-doctor: Run the appropriate audit command for this project's
   ecosystem (npm audit, pip audit, etc.). Check for outdated packages.
   Report critical vulnerabilities and outdated deps.

3. Summarize overall health: HEALTHY / NEEDS ATTENTION / CRITICAL

Output a single combined report.
"
