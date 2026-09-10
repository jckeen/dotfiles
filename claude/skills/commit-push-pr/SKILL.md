---
name: commit-push-pr
description: Commit, push, and create a PR in one shot — Boris Cherny's most-used daily command
disable-model-invocation: true
---

Commit, push, and create a PR for the current work. $ARGUMENTS

1. Run `git status` and `git diff --staged` to understand current state
2. Finish simplification, intended documentation, changelog, and required generated-file updates. Stage only relevant files; never use `git add -A`, stage secrets, or include generated runtime state.
3. Run affected build/test/lint checks on the final changes. If they fail, fix them first and restage only the intended corrections.
4. Write a conventional commit message (`type: short description`) based on the actual changes
5. Commit
6. **Run the local Codex review gate** — `~/.claude/scripts/codex-review-gate.sh --require` (or the repo copy). Run it **after the last commit, before the push**; select `--base <ref>` when needed to identify the PR base. It reviews the committed delta and records private evidence bound to the artifact.
   - Blocking findings, unreadable output, or an unavailable reviewer stop shipping. Fix in a follow-up commit, repeat affected verification, and rerun final review. A degraded run does not approve shipping.
   - Exit 0 alone does not establish completed review. Distinguish a successful-review receipt from an explicit tier/no-diff exemption and report exemptions as such.
   - If the self-instruction guard blocks, independently read those instructions and obtain refutation from a different model family. Record that evidence and the reason before a scoped `CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1` override, or use the Antigravity gate with `--require` and its receipt as the independent alternate. Never bypass hooks.
7. **Require a separate-family reviewer for high-risk changes:** authentication, authorization, secrets, payments, destructive operations, schemas, and public trust boundaries. Verify actual reviewer identity; a fresh context alone or an Antigravity dispatch label does not establish a different model family. The Antigravity gate is otherwise an advisory second opinion for relevant runtime/frontend changes. A text-diff review is not runtime/browser evidence. Fix actionable findings and repeat final verification/reviews after any artifact edit.
8. **Check the receipt immediately before push:**

   ```bash
   python3 ~/.claude/scripts/review-receipt.py check --repo . \
     --head "$(git rev-parse HEAD)" --reviewer codex
   ```

   Use `--reviewer antigravity` for the independently approved alternate gate and the same `--base <ref>` if one was selected. Missing, stale, or mismatched evidence blocks shipping; only a checker-accepted current exemption may replace review under the applicable gate policy. Any subsequent artifact edit invalidates approval: commit the intended edits, rerun affected verification and required reviews, then recheck. Push the current non-default branch, creating its upstream if needed.
   For an explicitly selected nondefault PR base, use `REVIEW_RECEIPT_BASE=<ref> git push ...` with the same reviewed base. Without this one-push setting the hook requires the repository's default base; never select a narrower base just to pass it.
9. Create a PR with `gh pr create`:
   - Title: concise, under 70 characters
   - Body: what changed, why, how it was tested
   - Link any related issues with "Fixes #N" or "Relates to #N"
10. Output the PR URL
11. Check CI status with `gh pr checks <url>` and report pending or failed checks. Enable auto-merge only when the user's authorization, applicable artifact review evidence, and required CI checks permit it (see ADR-0003). The Codex GitHub bot (`chatgpt-codex-connector[bot]`) reviews asynchronously; its later comments do not replace the local shipping gate. Never push implementation directly to a default/protected branch, force-push, bypass hooks, or amend published history under this skill.

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
