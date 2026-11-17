## 2026-11-17 — feat(gates): the Codex review covers the whole category on the first pass (#787)

- **Why**: gated pull requests in one application repo averaged 2.2 gate
  rounds, and a third of them took three or more. The reviewer reported one
  instance of a defect per round, and a review that said it had skipped part
  of the change could still pass.

- **Review prompt (`claude/scripts/codex-review-gate.sh`)**: the gate-computed
  diff still defines what changed, and repository reads now establish what the
  changes do. The reviewer maps every path that depends on a changed contract
  (writers, readers, validators, error exits, cancellation, retries) before
  judging it, reports every place a defect occurs, and names the rule that
  closes the category. A finding must explain how the changes introduce,
  expose or incompletely repair a concrete failure, so an unrelated defect in
  unchanged code is not a finding of the review.
- **Claim mode**: refuting the claim is now an added obligation inside the
  complete review, and one counterexample no longer ends it.
- **Committed reviews** name the pinned commit and tell the reviewer to read
  context from it, so an uncommitted repair in the working tree cannot make a
  committed defect look closed.
- **`claude/scripts/codex-review-schema.json`** gains a required `coverage`
  object (status, areas examined, limitations) and a required, bounded
  `supporting_locations` list on every finding. The local validator requires
  both, and holds each location to a repository-relative path with an ordered
  line range.
- **Approval now requires complete coverage.** A review whose coverage is not
  `complete`, that names nothing it examined, or that lists anything it did
  not examine, blocks with exit 2 and a block marker, whatever its verdict or
  findings. The prompt and the schema descriptions state every limit the
  local validator holds the output to. The same rule applies to a
  failed, cancelled or superseded run through the one output validator.
- **Blocking output** prints each finding's category, the rule that closes it
  and the other places it occurs. The gate had been discarding the first two.
- **Low-finding issues and comments** keep the other places a finding occurs
  (#788).
- A receipt recorded before this change stays valid: `check` reads the stored
  review's digest, not its shape.
