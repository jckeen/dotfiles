## 2026-11-16 — feat(canon): a test asserts behavior

- The shared instructions for Claude Code, Codex, Antigravity and cloud agents
  carry one new rule: a test calls the code and checks its result, never
  asserts on source text or only that a mock was called, and sits at the
  lowest level that proves the change, with a fake over a mock.
  `check-agent-parity.sh` asserts the rule stays in every runtime's file.
