## 2026-11-16 — feat(agents): a test-architect agent

- **`test-architect`** is a new read-only agent that audits how a test suite
  is built. It flags tests that read source files and assert on their text,
  tests whose only assertion is that a mock was called, assertions that
  cannot fail, decision logic covered
  only through database-backed or end-to-end tests, and string-matching gates
  that keep collecting test cases. It reports the suite's shape against a
  70 / 20 / 10 pyramid as a reference, not a quota, and returns a remediation
  plan for `test-writer`. It joins Phase 3 of the agent pack review and
  `full-review.sh`.
- **`test-writer`** now writes to the same standard: lowest test level first,
  an in-memory fake over a spy, assertions on results, and no tests that read
  source code.
