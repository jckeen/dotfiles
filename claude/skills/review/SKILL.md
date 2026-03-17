---
name: review
description: Review recent changes for quality, security, and correctness
user_invocable: true
---

When the user runs /review, do the following:

1. Run `git diff HEAD~3..HEAD` (or since last review/tag) to see recent changes.
2. Review the diff for:

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
