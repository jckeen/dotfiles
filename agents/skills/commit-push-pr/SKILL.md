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
   same script `cc` uses; it runs `codex exec --output-schema` over a
   gate-computed, injection-fenced diff and parses structured JSON findings).
   Run it **after the commit, before the push**, so it reviews the committed
   delta vs the base branch — exactly the PR contents — and ignores unrelated
   WIP in the tree. This is the ADR-0003 stop-gate made concrete:
   - Exit 2 → STOP: critical/high/medium findings, unreadable output, or a
     diff touching the reviewer's own instruction files (AGENTS*.md / codex/ —
     self-review is untrusted; use the Antigravity gate + human eyes, or
     `CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1` after reading those changes). Fix in
     a follow-up commit, re-run the gate, then continue. Do not push past it.
   - Exit 0 → clean, or only low findings (already filed as GitHub issues).
     Proceed.
   - Exit 3 / loud warning → Codex could not run; the gate degrades open. Note
     it and continue, or set `CODEX_GATE_REQUIRED=1` to hard-require the review.
7. Run `~/.claude/scripts/antigravity-review-gate.sh` as an advisory,
   cross-lineage second opinion for runtime, frontend, or boundary-sensitive
   changes. Skip it for pure docs/config when it adds no signal. Treat real
   findings as actionable, but do not make this advisory gate authoritative
   over the Codex stop-gate and CI.
8. Push the current non-default branch, setting upstream if needed.
9. Create a PR with `gh pr create`:
   - title under 70 characters
   - body covering what changed, why, and how it was tested
   - issue links such as `Fixes #123` when applicable
10. Inspect `gh pr checks` and report pending or failed checks. The merge gate is
    the Codex review plus CI green (see ADR-0003).
11. Enable auto-merge only when an applicable standing order explicitly grants
    that authority and the required review/CI conditions are satisfied.
    Otherwise return the PR URL and verification state without merging.

## Safety

- Never stage secrets or generated runtime state.
- Never revert unrelated work.
- Never push implementation directly to a default or protected branch.
- Never force-push, bypass hooks, or amend published history under this skill.
- If verification fails, stop and fix or report the failure before pushing.
