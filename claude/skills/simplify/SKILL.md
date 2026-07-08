---
name: simplify
description: Review recently changed code for unnecessary complexity and edit it in place to simplify — removes over-engineering, dead code, and premature abstractions while preserving behavior. Unlike review (which only reports), this applies the changes. Use after building a feature, or when the user says "simplify this", "this feels over-engineered", "clean this up", or "de-engineer".
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
