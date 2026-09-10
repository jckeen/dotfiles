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
3. Finish simplification, intended documentation, changelog, and generated-file
   updates. Run the smallest useful verification affected by the final changes.
4. Stage only relevant files.
5. Commit with a conventional message:
   - `feat: ...`
   - `fix: ...`
   - `docs: ...`
   - `refactor: ...`
   - `test: ...`
   - `chore: ...`
6. Run `~/.claude/scripts/codex-review-gate.sh --require --committed` **after the last
   commit, before the push**. Supply `--base <ref>` when needed to identify the
   PR base. The gate reviews the committed delta and records private evidence
   bound to that artifact.
   - Blocking findings, unreadable output, or an unavailable reviewer stop
     shipping. Fix in a follow-up commit and repeat affected verification and
     final review. Do not treat a degraded run as approval.
   - Exit 0 alone does not mean review completed. Distinguish a successful
     review receipt from an explicit tier/no-diff exemption; record an
     exemption as an exemption, never as a reviewer verdict.
   - For the self-instruction guard, independently read the affected
     instructions and route refutation through a different model family.
     A scoped `CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1` override may follow that
     independent review; record the reason and evidence. Alternatively use
     the Antigravity gate with `--require` and its receipt when it provides the
     independent review. Never bypass hooks to evade the guard.
7. Require a review from a different model family than the implementer for
   authentication, authorization, secrets, payments, destructive operations,
   schemas, or public trust boundaries. A fresh Codex reviewer of Codex work
   supplies context independence only. Use a suitable separate-family reviewer
   and verify its actual identity; an Antigravity dispatch label alone does
   not prove the model used. For other relevant runtime/frontend changes,
   `~/.claude/scripts/antigravity-review-gate.sh` can add an advisory opinion.
   A text-diff review is not runtime/browser verification.
8. Immediately before pushing, validate the artifact evidence:

   ```bash
   python3 ~/.claude/scripts/review-receipt.py check --repo . \
     --head "$(git rev-parse HEAD)" --reviewer codex
   ```

   Use `--reviewer antigravity` for the independently approved alternate gate
   and the same `--base <ref>` if one was selected. A missing, stale, or
   mismatched receipt blocks the push; only a checker-accepted current
   exemption may replace completed review under the applicable gate policy.
   Any subsequent artifact edit invalidates approval. Recommit intended edits,
   rerun affected verification and required reviews, and recheck the receipt.
   Push the current non-default branch, setting upstream if needed.
   For an explicitly selected nondefault PR base, scope that same base to the
   push with `REVIEW_RECEIPT_BASE=<ref> git push ...` so the hook checks the
   intended receipt. Without this one-push setting the hook requires the
   repository's default base; never select a narrower base just to pass it.
9. Create a PR with `gh pr create`:
   - title under 70 characters
   - body covering what changed, why, and how it was tested
   - issue links such as `Fixes #123` when applicable
10. Inspect `gh pr checks` and report pending or failed checks. Require the
    applicable artifact review evidence and required CI checks to be green
    before enabling auto-merge (see ADR-0003).
11. Enable auto-merge only when an applicable standing order explicitly grants
    that authority and the required review/CI conditions are satisfied.
    Otherwise return the PR URL and verification state without merging.

## Safety

- Never stage secrets or generated runtime state.
- Never revert unrelated work.
- Never push implementation directly to a default or protected branch.
- Never force-push, bypass hooks, or amend published history under this skill.
- If verification fails, stop and fix or report the failure before pushing.

## Worktree disposition

Finish delivery by recording the disposition of every task worktree. Follow
`claude/scripts/README.md` → Worktree lifecycle for the shared release,
preview, and retirement commands. Stop its reviewer/runtime processes first
and run lifecycle commands from outside the target worktree.

After verified integration, retire released worktrees only when the user or
applicable standing authorization permits cleanup. Archive recovery data and
review evidence before moving the directory into retained, locked quarantine.
Retirement does not delete the quarantine or reclaim its disk space.
Preserve primary/current/locked
worktrees, unique work, dirty/untracked/ignored content, and stashes. Never use
branch names or commit subjects as merge evidence.

If the PR is pending, record a release for the exact completed artifact when
appropriate, retain the worktree with its owner and PR, and give the next
session the retirement command. A later merge does not grant deletion rights.
The hygiene timer inventories these releases but never removes worktrees.
Unknown ownership or unavailable remote evidence means retained with a reason.
