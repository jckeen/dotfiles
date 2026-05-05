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
6. Push the current branch, setting upstream if needed.
7. Create a PR with `gh pr create`:
   - title under 70 characters
   - body covering what changed, why, and how it was tested
   - issue links such as `Fixes #123` when applicable
8. Return the PR URL and verification result.

## Safety

- Never stage secrets or generated runtime state.
- Never revert unrelated work.
- If verification fails, stop and fix or report the failure before pushing.
