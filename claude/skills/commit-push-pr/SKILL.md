---
name: commit-push-pr
description: Commit, push, and create a PR in one shot — Boris Cherny's most-used daily command
disable-model-invocation: true
---

Commit, push, and create a PR for the current work. $ARGUMENTS

1. Run `git status` and `git diff --staged` to understand current state
2. If there are unstaged changes, stage the relevant files (not `git add -A` — be specific, skip secrets and generated files)
3. Run the project's build/test/lint command if one exists. If it fails, fix it first
4. Write a conventional commit message (`type: short description`) based on the actual changes
5. Commit
6. **Run the local Codex review gate** — `~/.claude/scripts/codex-review-gate.sh` (or `claude/scripts/codex-review-gate.sh` in this repo). Run it **after the commit, before the push**, so it reviews the committed delta vs the base branch (exactly the PR contents) and ignores any unrelated WIP still in the tree. This is the concrete ADR-0003 stop-gate.
   - **Exit 2 → STOP.** Codex found critical/high/medium (P0–P2) issues. Surface them, fix them with a follow-up commit (or get an explicit override from the user), then re-run the gate. Do not push past a blocking review.
   - **Exit 0 →** clean, or only low (P3+) findings — which the gate has already filed as GitHub issues so they're tracked. Proceed.
   - **Exit 3 / loud warning →** Codex couldn't run (not installed/authed, offline). The gate degrades open; note it and continue, or set `CODEX_GATE_REQUIRED=1` if this change must not ship un-reviewed.
7. Push to the current branch (create remote tracking branch if needed)
8. Create a PR with `gh pr create`:
   - Title: concise, under 70 characters
   - Body: what changed, why, how it was tested
   - Link any related issues with "Fixes #N" or "Relates to #N"
9. Output the PR URL
10. Check CI status with `gh pr checks <url>` (it may still be pending — note that). If any check fails, surface the failure summary. The merge gate is **Codex review (step 6) + CI green** (see ADR-0003) — no need to wait on PR comments; just confirm CI is healthy or flag what's red.
