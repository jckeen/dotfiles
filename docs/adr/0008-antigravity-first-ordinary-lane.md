# 0008. Antigravity-first ordinary review lane; Codex reserved for risk surfaces

- **Status:** Accepted (amends ADR-0003)
- **Date:** 2026-09-18

## Context

ADR-0003 chose a synchronous stop-gate review over a PR-comment-watching loop.
It named Codex as the reviewer because Codex was the only local gate at the
time. Two things changed since.

First, there are now two local gates of independent lineage
(`codex-review-gate.sh`, `antigravity-review-gate.sh`) plus the Codex GitHub bot
reviewing every PR asynchronously. Every ordinary tier-2 diff therefore paid for
**two Codex-lineage reviews** — the local gate against general usage, the bot
against the separate Code Review allowance — and got no second opinion for the
cost. The Gemini lane sat idle.

Second, a fail-open was found in the shipping check. `githooks/pre-push` calls
`review-receipt.py check` with no `--reviewer`, and `check` returned on the first
valid receipt of **either** lane. An Antigravity-only receipt already shipped a
risk-surface diff. The classifier could not have stopped it either: it returned
only `{tier, reason}`, so risk-surface, size, and docs-only were not separable in
its output, and `review-and-push.sh` hardcoded the Codex gate and
`--reviewer codex` rather than asking anything.

Optimising the quota without closing the fail-open would have made the fail-open
routine rather than accidental, so both are decided here together.

## Decision

**One classifier decides the lane, and the receipt carries the answer.**

1. `classify_tier` in `review-receipt.py` returns
   `{tier, reason, risk_paths, required_lane}` with
   `required_lane ∈ any | antigravity | codex`:
   tier 1 → `any`; tier 2 with no risk paths → `antigravity`; risk paths, an
   empty changed-path list, or a classification the helper could not compute →
   `codex`. Lanes rank `any < antigravity < codex`, and a receipt ships a diff
   when its lane ranks at or above the required lane. A read-only
   `review-receipt.py lane` subcommand prints that JSON and mints nothing.
2. `gate_classify_tier` in `gate-lib.sh` exports `GATE_REQUIRED_LANE` and
   `GATE_RISK_PATHS`. Every path out of it that could not read a validated
   classification leaves `GATE_REQUIRED_LANE=codex`. `gate_select_lane` turns a
   required lane into the gate to dispatch and honours
   `REVIEW_LANE=auto|codex|antigravity`.
3. `review-and-push.sh` classifies, dispatches the selected gate with
   `--require --committed`, and checks the receipt naming **the lane it actually
   dispatched** rather than a hardcoded `codex`. `gate_select_lane` only ever
   returns a lane at or above the requirement, so naming it enforces the
   requirement *and* additionally requires the review this run performed to
   still be approved — otherwise a stronger lane that ran and then lost its
   approval could ship on a weaker lane's older receipt. A human checking by
   hand uses the generic no-`--reviewer` form instead, which enforces the
   requirement without needing to know which lane ran.
   `REVIEW_LANE_FALLBACK=codex|block` (default `codex`) decides what happens
   when the Antigravity gate exits 3.
4. `check` fails closed. `begin` stores the classification in the receipt
   (version 2; version-1 receipts are rejected outright, because they carry no
   lane requirement). `check` recomputes the classification on the re-captured
   patch, rejects a mismatch, and rejects a receipt whose lane ranks below the
   requirement. `githooks/pre-push` needs no change — verified by
   `tests/pre-push-receipt.test.sh`, which drives the real hook over a local
   bare origin.
5. `complete` appends `{completed_at, lane, outcome, tier, required_lane, head,
   note}` to `<receipts>/ledger.jsonl` (0600, append-only, never read by
   `check`). `review-receipt.py stats [--since-days N]` prints lane × outcome
   plus the degraded-fallback count.

**Tier 1's size ceiling is policy, not a gate's prompt cap** (amended
2026-09-22, #494). Whether a tier-1 exemption was *available* used to depend on
which gate you asked, because each gate checked its own dispatch feasibility
before its tier valve: the Antigravity lane refused a docs-only diff above its
500-line or measured 185,000-byte limits, the Codex lane refused one above 5,000
lines or on a machine with no `codex` installed — and the Codex lane minted the
very exemption the other refused. A one-line, 200,000-byte docs diff was tier 1
to the classifier and unreviewable to one gate.

The ceiling therefore lives in `classify_tier` as captured policy —
`tier1_max_lines` (default 200) beside `tier1_max_bytes` (default 65536) — so
both lanes and `check` give one answer, and a docs diff above it is **escalated
to an ordinary review** rather than refused by whichever gate was asked. 64 KiB
sits far below the Antigravity lane's measured window, so a diff the valve waves
through is still dispatchable there if a caller forces the full pass. A receipt
whose byte ceiling is absent (one minted before this existed) or unreadable
classifies tier 2 requiring `codex`: fail closed, never "no limit".

Consequently **both gates now run their tier valve before their own size caps
and before their reviewer-availability check.** Those are facts about a message
that a tier-1 diff never sends. The self-review guard stays *ahead* of the
valve: it is about trust, not feasibility, and must fire whether or not a
reviewer runs.

**Escalation is always allowed; downgrade never is.** `REVIEW_LANE=codex` on an
ordinary diff is honoured. `REVIEW_LANE=antigravity` on a codex-required diff is
**refused**, not honoured — that request is exactly the downgrade the required
lane exists to prevent.

**A degraded lane is not a verdict.** Antigravity exit 3 (agy missing, an
unverifiable model pin, a diff above its measured 185 KB input window) means the
lane could not run, so the diff falls back to Codex and the degradation is
recorded in the ledger. Exit 2 — blocking findings, or a verifiably wrong model
— **never** falls back: a refusal is not an outage, and re-asking a different
reviewer would be verdict shopping. For the same reason the Antigravity gate
exits 2, never 3, whenever the output it did get carries blocking findings,
whatever interrupted the run (print-timeout expiry, exit 124, a nonzero agy
exit, an unverifiable model pin): a degraded exit must never hide a verdict
from the fallback. A partial that is clean or P3-only still degrades, because
partial output is never certified complete.

**The Antigravity gate still runs on codex-required diffs** and still mints its
receipt, announcing itself as a *supplementary* lane. A second opinion of
independent lineage is worth having, and a Codex-family implementer needs one;
it simply is not shipping evidence for that diff.

**The dotfiles risk list is not narrowed here.** `review-receipt.py`'s risk
surfaces (`*scripts/*`, hooks, `.github/`, instruction files, and the
`auth|token|secret|credential|password|session|sso|crypt|hash|host|schema|migration`
substrings) keep most *dotfiles* diffs on Codex. That is deliberate: this ADR
changes routing, not the definition of risk, and loosening both at once would
make the quota saving impossible to attribute. The saving lands in the
application repositories (stringer, operator-commons, keen-media, impact-dash,
TRNN), where ordinary diffs are the common case. The ledger is the evidence;
read it with `stats` before proposing any change to the risk list.

## Consequences

**Positive**
- The pre-push fail-open is closed: lane sufficiency is enforced by the checker
  on every push, not by whichever gate someone happened to run.
- Ordinary tier-2 diffs cost one Gemini review instead of one Codex review, and
  the Codex GitHub bot becomes a genuine cross-family second opinion rather than
  a duplicate of the local gate.
- Lane usage is measurable for the first time. `run-*` receipt directories are
  ephemeral and `<lane>.json` is overwritten per attempt, so nothing before the
  ledger could count reviews per lane.
- A malformed or unreadable classification can only over-require review. Both
  the tier valve and the lane selector fail toward the strongest answer.

**Negative**
- Every existing receipt is invalidated by the version bump; the next push after
  this lands needs a fresh gate run.
- Ordinary diffs now depend on `agy` being installed and authenticated. The
  fallback keeps that from wedging a push, but a machine with no `agy` silently
  routes ordinary work back to Codex — visible only in the ledger, which is why
  `stats` counts the degradations. Tier-1 diffs are unaffected: the tier valve
  sits ahead of BOTH gates' size caps and reviewer-availability checks, so a
  docs-only diff still mints its exemption receipt with neither `agy` nor
  `codex` on `PATH` at all (asserted in `tests/antigravity-review-gate.test.sh`
  and `tests/codex-review-gate.test.sh` against a PATH built without them).
- Two knobs exist where there were none (`REVIEW_LANE`,
  `REVIEW_LANE_FALLBACK`). Neither can weaken a codex-required diff, but both
  are surface a reader has to know about.
- In this repository the change is nearly a no-op by design, because the risk
  list keeps most diffs on Codex. The benefit is realised elsewhere.
