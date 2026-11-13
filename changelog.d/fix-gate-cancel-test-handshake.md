## 2026-11-13 — test(gates): cancellation cases wait for the real event, not 8 seconds (#767)

- **`claude/scripts/tests/codex-review-gate.test.sh`**: the public Bash PID
  cancellation helper gave a whole gate run 8 seconds. Both the bootstrap
  seed run and the wait for the receipt phase, which comes at the end of a
  run, had that bound. A macOS CI runner takes about 8 seconds per gate run,
  so a different subset of the cases failed on each attempt (PR #766). The
  same four cases fail on Linux when the suite is pinned to one CPU shared
  with CPU-bound processes.
- Every wait in the helper now ends on its event and is bounded at
  300 seconds, which only turns a hang into a failure.
- Two fixed in-flight windows are now handshakes. The reviewer stub used to
  stay alive for 1 second, and the receipt hook held the gate's helper for
  0.3 seconds. Each now holds until the harness has sent its signal. A slow
  harness could otherwise miss the window and signal a gate that had already
  finished. A hold that expires before the signal fails the case explicitly.
  It never counts as a finished review.
- No gate script changes.
