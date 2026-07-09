---
name: review
description: Read-only review of recent git changes (diff since the last review/tag) for correctness, security, and quality — flags edge cases and missing boundary error handling, hardcoded secrets, injection risks (SQL/XSS/command), sensitive data in logs, over-engineering, and dead code, then returns a prioritized checklist. Reports only; does not edit — to actually apply simplifications use simplify. Use when the user asks to "review my changes", "check this before I ship", "look over the diff", "is this safe/correct", or wants a quality/security pass on recent work.
---

When the user runs /review, do the following:

1. Run `git diff HEAD~3..HEAD` (or since last review/tag) to see recent changes.
2. Review the diff for the checklist below. Run this pass at low effort — a
   fast, literal read of what the code does, not a rewrite of the design.

**Correctness**
- Does the code do what it's supposed to?
- Are there edge cases or missing error handling at system boundaries?

**Security**
- Any hardcoded secrets, keys, or tokens?
- SQL injection, XSS, or command injection risks?
- Sensitive data in logs or responses?

**Quality**
- Unnecessary complexity or over-engineering?
- Dead code or unused imports?
- Naming clarity?

3. Present findings as a short checklist:
   - ✅ Looks good: [thing]
   - ⚠️ Worth considering: [suggestion]
   - 🚨 Fix before shipping: [issue]

4. Keep it focused — only flag things that matter. Don't nitpick style unless it hurts readability.

## Coach pass (judgment, not bugs)

After the correctness checklist above, do one fresh-eyes pass whose only question
is quality. Read the diff and the files it touches as a skeptical senior reviewer,
and answer two things:

- Would this genuinely impress a sharp reviewer, or land as
  competent-but-forgettable?
- What single change would most raise its quality — a missed edge case, a test
  that proves the hard part, a clearer abstraction, better naming, a real
  simplification, or a doc/comment that earns its place?

Cite file:line. If it's already strong, say so — don't invent nitpicks. This is
distinct from the correctness pass: it reports no bugs, only the one
highest-leverage improvement.
