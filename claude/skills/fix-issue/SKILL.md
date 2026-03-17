---
name: fix-issue
description: Pick up a GitHub issue, investigate, implement the fix, test, and create a PR
user_invocable: true
disable-model-invocation: true
---

Fix the GitHub issue: $ARGUMENTS

Follow this workflow:

1. **Understand**: Run `gh issue view $ARGUMENTS` to get the full issue details
2. **Investigate**: Search the codebase for relevant files. Use subagents if the investigation is broad to protect context
3. **Plan**: Outline the approach. For non-trivial fixes, share the plan before implementing
4. **Test first**: Write a failing test that reproduces the issue (when applicable)
5. **Implement**: Make the minimum changes needed to fix the issue
6. **Verify**: Run the project's test suite. Ensure the new test passes and no existing tests break
7. **Lint/typecheck**: Run any configured linters or type checkers
8. **Commit**: Use conventional commit format, e.g. `fix: resolve session timeout on token refresh (#ISSUE_NUMBER)`
9. **Push and PR**: Push the branch and create a PR with:
   - Summary of what was wrong and why
   - What the fix does
   - How it was tested
   - Link to the issue with "Fixes #ISSUE_NUMBER"
