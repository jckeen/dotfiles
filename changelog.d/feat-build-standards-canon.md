## 2026-11-16 — feat(canon): build standards in every instruction file (ADR-0010)

- **`agents/canon/CANON.md`** gains a `build-standards` block: size budget,
  contracts at the boundary, explicit state, pure core with injected I/O and
  clock, no type escape hatches, fakes over mocks, and a ratchet for existing
  code. All four fragments include it, so it reaches Claude Code, Codex,
  Antigravity and the cloud brief. The block holds no numbers; each repo's
  lint config does.
- **`docs/adr/0010-build-standards-ratchet.md`** records the decision, the
  measured state of nine repos, the Codex design critique that disproved the
  first draft's ratchet, and the delivery order (a pilot on one large repo is next).
- **`claude/scripts/check-agent-parity.sh`** asserts the rule is present in
  the three local instruction files.
- **`claude/agents/code-simplifier.md`** and
  **`agents/skills/simplify/SKILL.md`** no longer treat a single-caller port
  or adapter as something to inline. **`claude/agents/test-writer.md`**
  prefers an in-memory fake for domain tests, keeps mocks for adapter and
  contract tests, and never restructures production code to make it fakeable.
