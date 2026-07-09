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
7. **Run the Antigravity (Gemini) gate — advisory second opinion** — `~/.claude/scripts/antigravity-review-gate.sh` (or `claude/scripts/antigravity-review-gate.sh` in this repo). Run it after the Codex gate, before the push. This is the Gemini sibling of step 6 — a different model family, biased toward front-end / runtime / boundary-condition issues. It is **advisory, not authoritative**: the merge gate stays Codex (step 6) + CI (ADR-0003).
   - **Exit 2 →** Antigravity flagged blocking issues. Surface them. Fix if they're real; if you and the user judge them false positives or out of scope, note that and proceed — do not treat this as a hard stop the way step 6 is.
   - **Exit 0 / 3 →** clean, only nits, or agy couldn't run (degrades open). Note and proceed.
   - Skip this step for changes with no runtime/front-end surface (pure docs, config) where a second review adds no signal and only burns plan quota.
8. Push to the current branch (create remote tracking branch if needed)
9. Create a PR with `gh pr create`:
   - Title: concise, under 70 characters
   - Body: what changed, why, how it was tested
   - Link any related issues with "Fixes #N" or "Relates to #N"
10. Output the PR URL
11. Check CI status with `gh pr checks <url>` (it may still be pending — note that). If any check fails, surface the failure summary. The merge gate is **Codex review (step 6) + CI green** (see ADR-0003); Antigravity (step 7) is advisory. The Codex GitHub bot (`chatgpt-codex-connector[bot]`) reviews the PR asynchronously after it opens — the Stop-hook harvest and the nightly-docs-steward backstop capture its comments as issues, so you don't need to wait on them here; just confirm CI is healthy or flag what's red.
