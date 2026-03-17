---
name: commit-push-pr
description: Commit, push, and create a PR in one shot — Boris Cherny's most-used daily command
user_invocable: true
disable-model-invocation: true
---

Commit, push, and create a PR for the current work. $ARGUMENTS

1. Run `git status` and `git diff --staged` to understand current state
2. If there are unstaged changes, stage the relevant files (not `git add -A` — be specific, skip secrets and generated files)
3. Run the project's build/test/lint command if one exists. If it fails, fix it first
4. Write a conventional commit message (`type: short description`) based on the actual changes
5. Commit
6. Push to the current branch (create remote tracking branch if needed)
7. Create a PR with `gh pr create`:
   - Title: concise, under 70 characters
   - Body: what changed, why, how it was tested
   - Link any related issues with "Fixes #N" or "Relates to #N"
8. Output the PR URL
