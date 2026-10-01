## 2026-10-19 — fix(gates): verdicts from runs that did not complete, exit 2 only by choice, bytecode caches

- **A failed, timed-out or cancelled Antigravity run is held to the
  completed-run parse (#579).** Its output was searched for anchored P0–P2
  lines only, so a stray blocker (`- [P3] nit; also [P1] bypass`) or text that
  is not findings at all left as a degraded exit 3 with no block marker, and an
  older Codex receipt for the same artifact stayed shippable. `agy_output_may_block`
  now decides every exit after agy wrote output; absent output, `LGTB` and
  P3-only output still degrade. The Codex gate already applied this rule.
- **Exit 2 is only ever an exit a gate chose (#515).** On bash 5.2 a signal that
  lands while the shell re-parses a command substitution makes the trap command
  fail to parse; the handler never runs and `set -e` ends the shell with status
  2, the verdict code. Bash 5.3 runs the handler. Each gate's EXIT handler now
  catches a status 2 that no `exit` command produced: the Codex gate invalidates
  its lane and exits 3, the Antigravity gate exits 1, and both keep exit 2 when
  the reviewer's output already carries a verdict. A fixture holds the shell in
  that parse on demand. Not closed: where bash is not checking command status
  the signal is dropped and the gate runs on.
- **An ignored `__pycache__` beside a skill or agent script no longer blocks a
  committed review (#581).** `review-receipt.py` leaves out a regular `*.pyc`
  directly inside an ignored `__pycache__` directory when the `.py` it was
  compiled from sits beside that directory; anything else there still counts as
  a dirty instruction surface.
