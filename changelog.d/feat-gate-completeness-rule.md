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
- **A finding is never shortened on its way out (#788).** The run output and
  the low-finding issue feed print every field of a finding from the
  reviewer's JSON: the category as written, both ends of each line range, the
  confidence, the whole body and recommendation, and every supporting
  location. A finding too long for one request is posted in parts, and a new
  issue receives its location marker only after every part is up, so a
  half-delivered finding is filed again by the next run instead of looking
  tracked. Requests travel on stdin, the label-less retry happens only when
  GitHub refuses the label, reviewer text cannot write a location marker, and
  the closing line counts what was filed, added to an open issue, already
  accepted, not delivered and not sent.
- **The reviewer's output is kept (#788).** `review-receipt.py retain` copies
  it, byte for byte, into the worktree's receipts directory as soon as it
  exists, and the gate prints the path. A blocking, failed or cancelled
  review used to leave its findings only in the terminal. The record is
  evidence only and never decides a verdict.
- **Location markers are data (#790).** A file name containing `%`, `<`,
  `>`, a backslash or a control character is written percent-encoded under a
  second marker name, `codex-gate-loc2`, so it can neither end the marker nor
  spell another one, and it can never be read as a marker the first format
  wrote. Every other name keeps the marker it always had. The name is read
  from the reviewer's JSON, not from a tab-separated row. An issue filed
  earlier for a name that now takes the second format is filed once more.
- **A multi-part issue is completed without overwriting it.** The location
  marker is appended to the issue body as it stands when the last part is up,
  so an edit made on GitHub in the meantime is kept.
- **Reviewer text cannot drive the terminal.** The findings, the summary, the
  coverage limitations, the next steps and the dump of an output that failed
  validation all print through one filter that replaces control characters.
- **Not covered**: output the reviewer never finished writing, a killed
  process or a full disk; the Antigravity gate; the rule that acceptance is
  per file; how many comments repeated runs add to one open issue.
- A receipt recorded before this change stays valid: `check` reads the stored
  review's digest, not its shape.
