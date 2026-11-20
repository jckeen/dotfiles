## 2026-11-19 — docs(canon): prefer real engines and parsers over hand-rolled scanners in tests

- Added a shared rule to `agents/canon/CANON.md` (`working-style-core`) and `agents/canon/fragments/claude.md` (`Verification`) preferring real engines or parsers (for example, PostgreSQL `PREPARE` and `pg_locks`) over hand-rolled regex or grammar scanners in tests, and regenerated `claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md`, and `AGENTS.md`.
- Added the `real-engine-tests` parity check to `claude/scripts/check-agent-parity.sh` with drift and bare-keyword regression coverage in `claude/scripts/tests/agent-parity.test.sh`.
