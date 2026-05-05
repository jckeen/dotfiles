---
name: review
description: Review recent or specified code changes for correctness, security, quality, and missing verification. Use when the user asks for a review, pre-ship check, PR review, or quality/security pass.
---

# Review

Act in code-review mode. Lead with findings, ordered by severity, and cite file
paths and line numbers.

## Workflow

1. Determine scope from the user. If unspecified, inspect recent local changes:
   - Prefer `git status --short`
   - Use `git diff --staged`, `git diff`, and recent commits as needed
2. Read the surrounding code before judging behavior.
3. Check for:
   - correctness bugs and edge cases
   - security issues at trust boundaries
   - missing validation, authorization, or error handling
   - regressions in public APIs, schemas, or user flows
   - missing or weak tests for changed behavior
   - unnecessary complexity only when it affects maintainability
4. Report only issues you can ground in the code. If there are no findings,
   say that clearly and mention residual risk or test gaps.

## Output

Use this order:

1. Findings, highest severity first
2. Open questions or assumptions
3. Brief change summary only if useful
4. Verification reviewed or still missing

Do not bury findings after a general summary.
