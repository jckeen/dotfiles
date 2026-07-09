---
name: simplify
description: Review and simplify recently changed code by removing unnecessary complexity without changing behavior. Use when the user asks to simplify, reduce over-engineering, clean up a patch, or make code easier to maintain.
---

# Simplify

Make the code simpler while preserving behavior and public interfaces unless the
user explicitly asks for an interface change.

## Workflow

1. Identify the scope from the user. If unspecified, inspect recent changes with
   `git status --short` and relevant diffs.
2. Read call sites and tests before editing.
3. Look for high-confidence simplifications:
   - dead code, unused imports, unreachable branches
   - wrappers that only forward to another function
   - abstractions used once with no clear payoff
   - duplicated conditionals that can be expressed more directly
   - redundant error handling that adds no context
4. Apply high-confidence edits directly when they are scoped and testable.
5. For medium-confidence changes, explain the tradeoff before changing behavior
   or public structure.
6. Run the smallest useful formatter, typecheck, lint, or test command.

## Constraints

- Do not add a new abstraction just to remove an old one.
- Do not churn unrelated files.
- Do not change behavior to make code look cleaner.
- Preserve user changes already present in the worktree.

## Output

Summarize what was simplified and what verification ran. If tests could not run,
say why.
