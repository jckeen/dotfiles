#!/usr/bin/env bash
# full-review.sh — Full agent pack review (TIER_READONLY)
# Runs the 3-phase review workflow from AgentPack.md. Changes nothing.
#
# Usage:
#   full-review.sh /path/to/repo
#   full-review.sh /path/to/repo --max-turns 25

source "$(dirname "$0")/common.sh"
MAX_TURNS="${MAX_TURNS:-25}"
parse_args "$@"

run_claude "TIER_READONLY" "
Run a full 3-phase agent pack review on this project. For each phase,
spawn the relevant agents in parallel and collect findings.

Phase 1 — Product refinement:
Spawn product-strategist, ux-reviewer, growth-strategist, trust-safety agents in parallel.

Phase 2 — Architecture and implementation:
Spawn frontend-architect, backend-architect, content-reviewer, security-reviewer agents in parallel.

Phase 3 — Launch hardening:
Spawn qa-lead, perf-accessibility, launch-operator, code-simplifier agents in parallel.

After all phases complete, produce a unified report:
- CRITICAL issues (must fix before shipping)
- HIGH issues (should fix soon)
- MEDIUM/LOW (nice to have)
- Overall assessment: SHIP IT / NEEDS WORK / NOT READY
"
