---
name: commit-push-pr
description: Commit current work, push the branch, and create a GitHub pull request with a concise title, body, and verification notes.
---

# Commit, Push, PR

Use when the user asks to commit, push, open a PR, ship the current branch, or
make a pull request.

## Workflow

1. Inspect state:
   - `git status --short`
   - `git diff --staged`
   - `git diff`
2. Determine which files belong to the requested change. Leave unrelated user
   changes alone.
3. Run the smallest useful verification command if one exists and has not
   already run.
4. Stage only relevant files.
5. Commit with a conventional message:
   - `feat: ...`
   - `fix: ...`
   - `docs: ...`
   - `refactor: ...`
   - `test: ...`
   - `chore: ...`
6. Run the Codex review gate — `~/.claude/scripts/codex-review-gate.sh` (the
   same script `cc` uses; it shells out to `codex exec review`). Run it **after
   the commit, before the push**, so it reviews the committed delta vs the base
   branch — exactly the PR contents — and ignores unrelated WIP in the tree.
   This is the ADR-0003 stop-gate made concrete:
   - Exit 2 → STOP: critical/high/medium (P0–P2) findings. Fix them in a
     follow-up commit (or get an explicit override), re-run the gate, and only
     then continue. Do not push past it.
   - Exit 0 → clean, or only low (P3+) findings (already filed as GitHub issues).
     Proceed.
   - Exit 3 / loud warning → Codex could not run; the gate degrades open. Note
     it and continue, or set `CODEX_GATE_REQUIRED=1` to hard-require the review.
7. Push the current branch, setting upstream if needed.
8. Create a PR with `gh pr create`:
   - title under 70 characters
   - body covering what changed, why, and how it was tested
   - issue links such as `Fixes #123` when applicable
9. Return the PR URL and verification result. The merge gate is the Codex review
   (step 6) plus CI green (see ADR-0003).

## Safety

- Never stage secrets or generated runtime state.
- Never revert unrelated work.
- If verification fails, stop and fix or report the failure before pushing.
