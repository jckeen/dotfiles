---
name: simplify
description: Review recently changed code for unnecessary complexity and simplify it
user_invocable: true
---

When the user runs /simplify, do the following:

1. Run `git diff HEAD~3..HEAD` to see recent changes (or use the scope the user specifies)
2. Delegate to the `code-simplifier` subagent to review the changes
3. Present the findings grouped by confidence level:
   - **High confidence** — safe to apply immediately
   - **Medium confidence** — worth discussing
   - **Low confidence** — optional improvements
4. Apply the high-confidence simplifications automatically
5. Ask about medium-confidence ones before applying
6. Commit the simplifications as `refactor: simplify [area]`
