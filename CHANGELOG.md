# Changelog

## 2026-09-23 — fix(receipts): claim at the verdict, a synchronized check, and three capture fixes

- **A degraded gate no longer costs the other lane's approval.** `begin` retired
  every lane's receipt before the gate knew it could run, so an Antigravity run
  that exited 3 (agy missing, a size cap, an unverifiable pin) voided a Codex
  approval of the same commit, and recovery was a paid re-run (#499). The step is
  split: `review-receipt.py capture` opens only this lane's attempt, and `claim`
  — refusing a superseded attempt, then retiring every other lane — runs only
  once a gate can reach a verdict: the Codex gate after its reviewer produced
  output (and on a failed or cancelled run whose output is not verifiably free
  of blocking findings, which now exits 2 rather than 3), the Antigravity gate after its model-pin check, before a failed local
  compile/lint check, in `verdict_in_partial_output` before a partial
  blocking verdict, and in a new cancellation handler when agy had already
  written blocking findings (exit 2; otherwise the signal is re-raised as
  before). `gate_record_pass`
  claims too, so no-diff and tier-1 receipts behave as before. `complete` refuses
  an unclaimed attempt. `begin` stays as capture-then-claim for other callers;
  receipt format is unchanged. The competing-receipt warning now prints at the
  claim. Tests in `review-receipt.test.py` pin capture/claim ordering, the
  serialized claim race and the unclaimed refusal; both gate suites pin that a
  degraded run leaves the other approval shippable and a blocking verdict
  retires it. Closes #499.
- **`check`'s decision is synchronized with `claim`.** Its validation stays
  lock-free, but the deciding assertion — attempt token still live, receipt still
  the one validated — now runs under the transition lock, so a claim landing
  after the last lock-free token read makes it refuse instead of approving a
  retired receipt (#533). An in-process test runs a real `claim` in that window.
- **The common Git directory keeps a trailing whitespace byte.** Capture stripped
  all whitespace from `rev-parse --git-common-dir`, so a store path ending in a
  space named a directory no worktree pointer matched and capture aborted with
  `cannot snapshot non-file`. Only Git's terminating newline is removed now, as
  the other path helpers do (#541).
- **A primary checkout nested under a linked worktree is recognized as this
  repository's own.** It is registered, but holds the common Git directory rather
  than a `.git` pointer file, so it was treated as a foreign boundary. A real
  `.git` directory whose realpath is the common Git directory now qualifies; any
  other repository still fails closed (#540).
- **Installed dependencies under a skill or `claude/scripts` no longer block every
  gate run.** The #439 hook-tree exemption extends to `claude/skills/<name>/node_modules`
  and `claude/scripts/node_modules`, only when git ignores the `node_modules`
  directory itself (not merely the file inside it) and the
  directory that owns it carries `bun.lock` or `package-lock.json` (a regular
  file). Without the lockfile, when not ignored, or anywhere else, those paths
  stay instruction surfaces and fail closed (#514).

## 2026-09-23 — feat(worktree-lifecycle): expire retired worktrees, keep recovery files

- **`worktree-lifecycle.py expire` removes retired quarantines from
  `git worktree list`.** With `--apply` it removes the quarantined checkout and
  its Git registration for entries retired longer ago than `--older-than`.
  Without `--apply` it only reports, offline, one entry per archive entry with
  a reason. Closes #562.
- **The recovery files are permanent.** `repository.bundle`,
  `worktree-metadata.tar` and `recovery.json` are never deleted, rewritten or
  moved; a test pins them byte-identical across `--apply`. Nine gate rounds on
  the first design each found another way the archive could be the only record
  of something, so expire no longer has to prove that negative. If the archive
  ever grows, a later command can prune recovery files from an explicit
  operator list.
- **Checkout-side guards.** A checkout is removed only when it is clean down to
  raw bytes, its HEAD, lock and release record match the entry, its bundle and
  metadata tar still hash to what retirement recorded, and its live Git
  metadata holds nothing written since retirement (every file byte-identical
  to the archived tar, index included, apart from retirement's own lock,
  gitdir and head-to-head detach). It is renamed to `worktree-expiring` and
  inspected again before `git worktree remove`. Entries without a registered
  checkout, and registrations without an entry, are reported and left alone.
- The daily hygiene timer runs the report only and saves it to
  `retired-worktrees.json`; `hygiene-status.sh --status` adds a
  `retired worktrees: N (oldest Xd, M expirable)` line, and the quiet modes
  speak up while M > 0. Retirement now records `retired_at`.

## 2026-09-22 — fix(hooks): operator-queue reminder shows the session project in full

- **`OperatorQueueReminder.hook.sh` no longer prints the whole queue into every
  session.** The full queue overflowed into the tool-results file, so the agent
  saw only a preview. Now the hook prints in full only the items whose
  `project:` matches the session's project (any word, case-insensitive), plus
  every item that is due today or overdue. Every other project collapses to one
  line with its item count, oldest age and next deadline. The session project
  is the basename of the repo's main checkout, found through
  `git rev-parse --git-common-dir`, so agent worktrees still count as the repo.
- Output is bounded at every level and a cut never splits a UTF-8 character. A
  tab inside a field no longer hides an item. A failed parse prints one warning
  line, and the hook always exits 0. `OPERATOR_QUEUE_SHOW_ALL=1` restores the
  full list. `operator-queue-reminder.test.sh` pins it. Closes #558. (#566)

## 2026-09-22 — fix(harvest): one consolidated issue per PR, harvested at PR close

- **One issue per PR, not per comment.** `harvest-codex-comments.sh` files
  `Codex review of #<n>: <title>` with one checklist item per bot comment:
  priority, `path:line`, link and the full comment quoted. A per-PR marker and
  a per-comment id marker (both exact, and not forgeable from comment text)
  prevent duplicates, including comments tracked by the old one-per-comment
  issues. New comments are appended to a body re-read just before each edit,
  so ticked boxes survive, and a closed issue is reopened. A body that would
  exceed GitHub's size limit spills into a `(continued)` issue. Items that fail
  to post are retried on the next run. Closes #556.
- **Labels.** `codex-finding` always, plus `instruction-surface` when a
  comment's path matches the Codex gate's self-review pattern; a test fails if
  the harvester's copy of that pattern drifts. When GitHub rejects a label, the
  harvester retries with fewer labels. Refs #557.
- **Harvested at PR close.** The new `harvest-codex-comments.yml` workflow runs
  on merged same-repo PRs with least-privilege `GITHUB_TOKEN` permissions and
  one harvest at a time per PR. The nightly routine stays as a backstop.
  `PreMergeCodexHarvest.hook.sh` notes on `--auto` merges that the close-time
  harvest will file anything the bot finds later. Closes #555. (#565)

## 2026-09-22 — docs(changelog): quarterly archives and `resolve-changelog.py`

- **`CHANGELOG.md` holds the current quarter.** Older quarters moved verbatim
  into HISTORICAL files under `docs/changelog/`, linked at the bottom of this
  file, declared in `.doc-contract` and allowlisted in `check-doc-refs.sh`.
- **`claude/scripts/resolve-changelog.py` is the standard fix for a DIRTY
  changelog head.** Run it after `git merge origin/main` stops on this file. It
  keeps both sides' new dated sections with origin's on top and edits no entry
  text. It resolves only a prepend it can prove against the merge base (git's
  index stages, or diff3 markers), refuses anything else without touching the
  file, and `--check` is a dry run. Its suite runs in CI through
  `doc-refs.test.sh`. Closes #561. (#564)

## 2026-09-22 — fix(jules-dispatch): `--report` and `--post` pinned to github.com

- The per-repository `gh pr list` reads and the `--post` tracker comment passed
  a hostless `--repo owner/name`, which `gh` resolves through `GH_HOST`. An
  Enterprise default could have built the weekly table from another host's PRs
  and posted it there. Both now pass `--repo github.com/<owner>/<name>`, as
  `--reconcile` already did, and gh rejects a ledger repo that carries its own
  host as malformed. A test with `GH_HOST=ghe.example` requires every `--repo`
  to name github.com. Closes #554. (#563)

## 2026-09-22 — fix(tests): the test runner and the wrapper refuse a selection that names nothing

- **`run-tests.sh` refuses two files that derive one suite name.** Beside
  `foo.test.sh`, a `foo.test.py` also derived `foo`, and the first-match lookup
  meant `run-tests.sh foo` or a `--changed` diff touching the second file ran
  the first one and reported green. Discovery now exits non-zero naming both
  files, in every mode, so the extension-free names `--list`, subset selection,
  `--changed` and `.review-test` use stay unchanged. The new cases in
  `run-tests.test.sh` pin it. Closes #518.
- **`review-and-push.sh` refuses a whitespace-only `REVIEW_TEST_CMD`.** It was
  treated as a declared command; `bash -c` ran nothing, exited 0, and step 2
  printed `tests: passed (REVIEW_TEST_CMD)`. It now fails closed before any gate
  runs, the same as a `.review-test` that declares no command; an empty value
  still means unset. The new cases in `review-and-push.test.sh` pin it.
  Closes #519.
## 2026-09-22 — fix(worktree-lifecycle): branch config, attach race, retained exemptions, host-state diagnostic

- **`retire --delete-branch` removes the branch's config section.** It deleted
  the ref with `update-ref -d`, which leaves `branch.<name>.*` in `.git/config`,
  so a later branch of the same name silently inherited the old upstream, merge
  and rebase settings. A successful delete now removes exactly that subsection
  (never the section of a branch whose name merely extends it); a removal that
  fails is reported in `branch_reason` rather than failing the retirement.
  Closes #521.

- **A worktree that attaches the branch mid-delete gets it back.** Git has no
  lock that serializes `worktree add` against a ref deletion — `git branch -D`
  has the same window — so the holder check was a stale snapshot. Holders are now
  read again straight after the delete, and a worktree that attached in between
  gets the ref restored (created only if still absent) and a refused
  `branch_deleted`. This narrows the race rather than closing it: an attach
  that resolved the branch before the delete but writes its `HEAD` after the
  re-read can still land on a missing branch, and only a lock Git itself
  honoured would close that. Refs #522.

- **A retained archive names every exemption both retirement scans observed.**
  The merged exemption list was only written with the quarantine paths, after
  the metadata and relocation checks, so an archive retained by one of those
  checks lacked the identities the second scan skipped. The record is now
  rewritten immediately after the merge. Closes #542.

- **The test suite names a stray Git marker above the temporary directory.**
  Retirement inspects every archive ancestor, and the fixtures archive under the
  system temp directory, so host state such as an empty `/tmp/.git` failed most
  cases with an opaque `git could not verify evidence (exit 128)`. Module setup
  now refuses once, naming the marker's path as host state; the tests in
  `claude/scripts/tests/worktree-lifecycle.test.py` pin the check, the config
  cleanup, the restore and the persisted exemptions. Closes #511.

## 2026-09-22 — fix(jules-dispatch): the harvested review findings on --reconcile

- **Every reconcile `gh` call names `github.com`.** The pull-request URL was
  validated as github.com, but `--repo owner/name` without a host takes it from
  `GH_HOST`, so an Enterprise default would have sent the close, label and title
  writes to a same-named repository there. `pr view/close/edit` and `label
  create` now pass `--repo github.com/<owner>/<name>`, and the commits read
  passes `gh api --hostname github.com`. Closes #527.
- **`max_files` is enforced before a routine pull request is labeled.** Every
  dispatch record now carries the limit the session was given, and a pull
  request over it is recorded `blocked-oversized` with the reason in its `prs`
  entry, counted in `status.json` as `reconcile.oversized`, and left open,
  unlabeled and unretitled for a person. A dispatch record written before the
  field existed skips the check and its reconcile record carries `max_files:
  null`; a ledger value that is not a positive integer is refused. Closes #530.
- **`reconcile.blocked_subjects` counts subjects**, not the pull requests that
  carry them. Closes #529.
- **`--reconcile` no longer requires the routine catalog.** Its sessions come
  from the ledger and outlive their routine files, so `--reconcile --routine
  <removed>` and a pass over an emptied catalog now settle the sessions left
  behind; dispatch and `--report` still refuse a missing or empty catalog.
  Closes #531.
- **ADR-0009 states the `commit_subjects_ok: null` contract exactly:** not
  every pull request of the session was examined and none that was carries a
  rejected subject — the pass may well have listed another pull request's
  commits. Closes #525.

The new cases in `claude/scripts/tests/jules-dispatch.test.sh` pin each of these.
## 2026-09-22 — docs(scripts): checker rows say what the checkers check

- **The `check-doc-refs.sh` and `check-skill-parity.sh` rows describe every guard
  the scripts run.** The doc-refs row named only the hook and skill path checks,
  so a documentation edit rejected for a broken relative link had no row to
  explain it; it now names the link check, what it skips, and the allowlisted
  docs. The skill-parity row stated a fixed number of guards and omitted the
  `agents/skill-coverage.tsv` disposition check entirely; it now lists that guard
  and states no total. Harvested from the GitHub Codex bot's review of #489.
  Closes #545. Closes #546.
- **The 2026-09-21 note on `| head` sites says what was actually found.** Two of
  the re-checked pipelines wrap in `|| true`, one relies on the absence of
  `set -e`, and one is an `if` condition; the entry claimed three `|| true`.
  Closes #544.
## 2026-09-22 — ci: the `checks` aggregator runs on a cancelled run

- **A cancelled run leaves the required `checks` context red, not absent.** The
  aggregator ran under `!cancelled()`, so cancelling a run after a shard had
  gone red skipped it — and branch protection reads a skipped required job as
  success, which left the PR mergeable on a run nothing had verified. It now
  runs under `always()` and fails on any aggregate other than `success`,
  cancelled included; `docs/BRANCH_PROTECTION.md` records why. Harvested from
  the GitHub Codex bot's review of #513. Closes #520.
- **`check-skill-parity.sh`'s header lists the workflow-coverage guard** it has
  run since `agents/skill-coverage.tsv` existed; the header had stopped at the
  guide table. Refs #545.

## 2026-09-22 — fix(gate): the ignore list, the tier ceiling, and the boundary sweep

- **`.codex-review-ignore` now exempts the FORM of a directive, never its
  effect.** The globs exist because gate fixtures and the live Jules routine
  prompts (ADR-0009) are imperative on purpose, and the reviewer kept reporting
  that imperative voice as an embedded instruction (#466). But those routine
  bodies are dispatched to a cloud agent, so the glob was also retiring the
  prompt-injection check for exactly the content that check exists to protect.
  The gate prompt now splits the exemption in two: do not report an
  instruction-like string under those paths as a finding *about this
  repository's instructions*, but DO report a directive whose effect would be to
  bypass a limit, skip or disable a check/review/gate/test, weaken a guard, or
  expose credentials. Same wording in the `.codex-review-ignore` header and the
  script README; three gate assertions pin it. Refs #484.

- **The gate self-test's startup-cancellation case interrupts one known phase
  instead of racing the whole run.** It waited for a `run-*/snapshot.json` to
  appear and then sent SIGINT, but `review-receipt.py begin` writes that file
  early in `gate_extract_diff`, so the window it opened spanned everything after
  it: on a loaded runner the signal landed mid-command-substitution (bash reports
  a parse error and the gate exits 2) or after the review had already finished
  (exit 0, a valid receipt) — two `main` failures, weeks apart, same case. The
  signal now comes from inside the gate's first `jq` call, the `.artifact.scope`
  read that follows capture and precedes any dispatch, while the gate is parked
  waiting for that child; the case also asserts it reached the signalling phase
  and dispatched no reviewer. Locally the old signal reproduced the "exit 0, left
  a receipt" failure verbatim in 14 of 40 randomized-delay runs, and the new one
  passed 15 of 15 plus every suite run since. Refs #512.
- **Every repository boundary in the ignored sweep is inspected, not just the ones
  whose own name looks like an instruction file.** `ls-files` collapses a
  directory it will not descend into to one trailing-slash entry, and a hand-made
  `.git` (HEAD, objects, refs — no `init`) is enough to earn that. The sweep
  reached its fail-closed path only when `instruction(entry)` was true, so
  `vendor/nested/` was dropped silently and `vendor/nested/CLAUDE.md` beneath it
  was never seen: the receipt then asserted a clean instruction surface it had not
  checked. Now a boundary is allowed only if it is one of this repository's own
  registered worktrees (the #474 allowlist, `.git`-pointer check included) or a
  real repository whose listing — tracked and untracked, deliberately without
  `--exclude-standard`, so its own `.gitignore` cannot hide a file from us —
  holds no instruction path, no further boundary and no gitlink. Anything else
  refuses. The gitlink half came from the Codex gate on this very change: a
  populated tracked submodule inside such a repository is printed as one bare path
  with no trailing slash and its contents are never enumerated, so
  `vendor/nested/dependency` passed every check while `dependency/CLAUDE.md` sat
  underneath it. The listing is now read with `--stage`, mode `160000` refuses
  whether or not the submodule is populated, and a path listed as a file where the
  disk holds a directory refuses too. Benign vendored repositories still capture
  normally. Refs #496.
- **The tier-1 size ceiling is policy now, not one gate's prompt cap.** Whether a
  docs-only diff could take the exemption depended on which gate you asked: the
  Antigravity gate refused one above its 500-line or measured 185,000-byte
  limits, the Codex gate above 5,000 lines or with no `codex` installed — and the
  Codex lane minted the exemption the other refused. `classify_tier` now carries
  `tier1_max_bytes` (default 65536, with no environment knob on purpose: the
  shipping wrapper classifies before any gate runs, so a gate-only override would
  pick the tier-1 skip and then refuse to record it) beside `tier1_max_lines`,
  captured in the
  receipt like every other policy field, so both lanes and `check` agree and a
  byte-huge docs diff is **escalated to an ordinary review** instead of refused.
  A receipt with no byte ceiling — one minted before this existed — reads as
  unclassifiable and requires Codex. Both gates' tier valves moved ahead of their
  size caps and of the `codex`/`agy` presence checks, since a tier-1 diff
  dispatches no message for those limits to be about; the self-review guard stays
  ahead of the valve, because it is about trust, not feasibility. ADR-0008
  amended. Refs #494, #482.
- **`gate_select_lane`'s `skip` comment describes the mechanism that exists.**
  Since #492 a tier-1 diff dispatches no gate at all; `review-and-push.sh`
  records the exemption itself. Refs #493.

## 2026-09-22 — feat(ci): a runner for this repo's own tests, and `checks` split into four shards

- **`claude/scripts/run-tests.sh` — the answer to "run this repo's tests".**
  There wasn't one: dotfiles has no `package.json` or `pyproject.toml`, so
  `review-and-push.sh` step 2 printed `(no test framework detected — skipping)`
  and went on to mint a receipt attesting to a review and no test run at all
  (#490; two agent sessions shipped on it). The runner discovers the same
  enumeration `check-tests-wired.sh` asserts is wired into CI, names each suite
  by its filename, and takes `--list`, a subset by name, `--changed`, and
  `--verbose`; the summary is per-suite PASS/FAIL with wall times. Selecting
  nothing is never a green run — an unknown name and an empty `tests/` fail
  closed, and an unresolvable base ref, an empty diff, or a changed path the
  name mapping cannot attribute widen the run to every suite rather than
  quietly narrow it. The mapping follows names through every tracked non-test
  file to a *fixpoint*, not to a depth limit, because no suite mentions
  `gate-lib.sh` directly — it is reached through `codex-review-gate.sh`, and the
  installer suites reach the root `lib-symlinks.sh` only through `setup.sh`, so
  any fixed bound would drop a genuinely affected suite while other matches kept
  the widening fallback from firing. Every rule only ever adds suites, so an
  over-wide mapping costs time and never coverage. Every changed path must reach
  a suite on its own — one mappable path cannot speak for an unmapped sibling —
  and a rename or a deletion widens to everything. The `*.property.test.py` suites are a named SKIP when
  Hypothesis is absent: they fail loudly by design, which is right for CI and
  would make every fresh clone's pre-push run red.
- **Step 2 takes its command from the repo, not from guesswork.**
  `REVIEW_TEST_CMD`, else a `.review-test` line at the repo root, else framework
  sniffing — where a bun lockfile or `bunfig.toml` keeps the project off npm
  without overriding what it declares: a `package.json` `scripts.test` runs as
  `bun run test`, and `bun test` (bun's own runner) is only for a bun project
  that declares no test script, with `npm test` the fallback where there is no
  bun at all. `.review-test`
  runs through `bash -o pipefail -c`, not `eval`: not `eval` so a line read out
  of the repository cannot reach the wrapper's variables and weaken the
  checkpoints after it, and with `pipefail` because a child shell does not
  inherit it and `<suite> | tee log` would otherwise report tee's success and
  let a red suite reach the push. `REVIEW_TEST_CMD` is unset for the command's
  own environment: it names *this* repo's tests, and that command is usually a
  suite that runs the wrapper again against a fixture repo (about forty times in
  `review-and-push.test.sh`), where inheriting it would recurse or fail — the
  shipping fixtures scrub it for the same reason. A declared-but-empty file
  fails closed. With nothing declared the step prints a
  banner saying the receipt attests to no test run and records
  `tests: skipped`, so a PR body can quote it honestly. This repo's
  `.review-test` runs `run-tests.sh --changed`.
- **The `checks` job is now four parallel shards (#472).** It had grown to
  ~12.6 min of serial steps and a p90 of 10.6 min. `checks-shards` is a matrix
  over `receipts`, `gates`, `runtime`, and `checkers`, grouped so the four
  slowest suites — review receipts and shipping boundaries (3.6 min), the Codex
  gate self-test (2.5 min), the claude-operator runner (1.8 min), and the
  Antigravity gate self-test (1.7 min) — land in different shards. Wall time is
  the slowest shard; a fifth shard would buy nothing, since the receipts suite
  alone is the floor. No step was removed and every `run:` body is unchanged, so
  `check-tests-wired.sh` still reads the same wiring shape; its fix-hint and the
  `claude/scripts/README.md` rows now name the shards. `checks` itself stays as
  a small aggregator job that `needs` the shards and fails unless all of them
  succeeded — a matrix job produces one status context per leg, not one for the
  set, and branch protection points at the single name.
## 2026-09-22 — fix(jules-dispatch): reconcile provenance says what it actually checked

- **`commit_subjects_ok` is tri-state, so "not examined" can no longer read as
  "ok"** (#508). The first live reconcile pass recorded
  `{"action":"noop",…,"commit_subjects_ok":true}` for #477 — a pull request that
  was already closed when the pass ran, whose only commit subject
  (`No changes needed: doc drift checkers pass`) `check-commit-format.sh`
  rejects. The pass never listed its commits. ADR-0009's custodian handoff reads
  the reconcile record as the provenance a consumer must not re-derive from PR
  text, and a boolean meaning "ok" *or* "never looked" cannot be keyed on. The
  field is now `true` only where the commits were listed and checked, and JSON
  `null` (present, not absent) on every branch that read none: a pull request
  already closed or merged, an empty one the pass closed, a refused URL or ledger
  field, a FAILED session, a session with no pull request. The record covers the
  whole session, so `true` means *every* pull request of it was examined: a
  `false` wins outright, but one unexamined pull request weakens a clean read
  back to `null` in either order — caught by the Codex gate on the first round of
  this fix, where a closed PR beside a clean one still read `true`.
  `status.json`'s
  `reconcile.blocked_subjects` is a count of pull requests whose commits *were*
  read and rejected, so it is unchanged.
- **A pull-request URL is validated before command substitution can trim it**
  (#505, Codex gate, low). The whole-field contract held for an *embedded*
  newline but not a trailing one: `$(jq -r …)` strips trailing newlines, so
  `…/pull/9\n` reached the anchored pattern as `…/pull/9`, passed, and could
  drive a real `gh` write. The value now leaves `jq` with a sentinel byte
  appended and the sentinel is checked before it is stripped, so the newline is
  still on the string when the pattern rejects it; a non-string `pullRequest.url`
  is replaced with a placeholder rather than letting `jq -r` render a number or
  an object into something the pattern might accept. A sentinel cannot rescue a
  NUL, though — the gate's low finding on this fix, the same class one byte
  further: `"…/pull/9\u0000"` is a legal JSON string and command substitution
  drops the NUL *mid*-string with only a warning, so a byte the shell cannot
  carry is now caught inside `jq` and becomes a placeholder no pattern accepts.
  Three regression tests, and the embedded-newline case still passes.
## 2026-09-22 — fix(worktree-lifecycle): a retired worktree releases its branch ref

- **Applied retirement detaches the quarantined worktree's own metadata HEAD.**
  Retiring fourteen merged task worktrees left every one of them registered with
  its branch still checked out, so `git branch -D` — and any merged-branch
  pruning — refused each of those branches forever with `cannot delete branch
  'X' used by worktree at '<quarantine>'`. The detach is the last step, after the
  recovery bundle and `recovery.json` are written, so the record still names the
  branch the task worked on. It writes only that worktree's `HEAD` and reflog in
  the source repository's worktree metadata: the quarantined directory, its
  index, the bundle and the record are untouched, and the commit stays reachable
  from the merged PR, the bundle and the detached HEAD. Verified through the same
  `git worktree list --porcelain` the operator reads, and a preview detaches
  nothing. Closes #498.
- **`retire --delete-branch` finishes the post-merge cleanup, fail-closed.** It
  deletes the local branch only when the ref still names the exact merged PR head
  the collector already verified, is not a symbolic ref, and is held by no
  worktree. `update-ref -d` enforces none of that: it deletes a branch another
  worktree has checked out, and a worktree interrupted mid-rebase or mid-bisect
  reports `detached` while Git still refuses to delete the branch it started
  from, so the same `rebase-merge/head-name`, `rebase-apply/head-name` and
  `BISECT_START` state Git reads is read here, with a test pinning both refusals
  side by side. The delete passes the expected value so a concurrent update makes
  Git refuse rather than discard an unverified commit, and `--no-deref` means a
  ref that turned symbolic between the check and the write can only delete
  itself, never the branch it points at. Every other state leaves the ref alone
  and says why under `branch_deleted` and `branch_reason` instead of failing a
  retirement that already completed.

## 2026-09-22 — feat(jules-dispatch): --reconcile settles what a routine session left behind

- **`--reconcile` closes empty routine pull requests and applies the label the
  platform never does.** Two live sessions showed what the lane actually gets
  back: a COMPLETED session opens a pull request even when its change set is
  empty (#477 — zero changed files, the title `Routine: doc-drift-fixer - clean
  run`, which the required commit-format check rejects, and no label), and a
  second session completed with `outputs` null, no change set and no pull
  request at all. None of that is fixable at dispatch time, so it is settled
  afterwards. For each `created` session in the ledger the pass reads
  `GET /sessions/{id}`; an open pull request with zero changed files is closed
  with a one-line comment, one that changed something gets
  `jules-routine:<routine>` (creating the label, which no repository carries
  until a routine PR lands there) and, if its title is not a conventional
  subject, a `chore(<routine>): …` one; a session that produced no pull request
  or failed is recorded as such. The pass runs standalone and at the end of
  every dispatch, including a dispatch that created nothing. Refs #479.
- **The pull-request URL the API hands back is never trusted.** It is matched
  against an anchored `https://github.com/<owner>/<name>/pull/<n>` pattern and
  must name the same repository the session was dispatched to; anything else is
  recorded as an error and acted on by nothing, because a URL from a remote
  service attached to an ambient `gh` credential is otherwise a write primitive
  pointed at someone else's repository. Every gh write is checked, so a failed
  close or label is a counted failure and leaves no record claiming success —
  which is what lets the next run retry it.
- **Every ledger spend query now filters on the record kind.** A reconcile
  record carries the same `.date`, `.routine`, and `.repo` as a dispatch, so
  without the filter closing an empty pull request would have counted against
  the daily cap, satisfied the same-day idempotency check, and held a weekly
  routine inside its cadence window — suppressing the very routine the record
  belongs to. `dispatched_today`, `unresolved_attempts`, `already_dispatched`,
  `dispatched_within`, `last_dispatch_epoch`, and `ledger_repos` all share one
  prelude, and a test pins that a ledger full of today's reconcile records still
  dispatches the pair.
- **Idempotent by ledger query, not by memory.** A session with a terminal
  reconcile record is skipped without an API call; a session still running is
  skipped with no record at all, so the next run looks again rather than
  freezing its outcome at "we looked too early". Records for one session are
  held until the whole session is settled, so a retryable failure part-way
  through leaves nothing behind. `--dry-run` holds in the new mode too: it may
  read `GET /sessions` and `gh pr view`, prints `[DRY] would …`, and leaves the
  state directory byte-identical. Standalone the pass dies without `gh`; inside
  a dispatch it logs one line and counts one failure rather than taking the
  dispatch down with it. `status.json` gains a `reconcile` block.
  `tests/jules-dispatch.test.sh` covers all of it with a fake `gh` alongside the
  fake `curl`, and never the live API.
- **The retitle's boundary is reported, not papered over** (Codex gate, high).
  `check-commit-format.sh` lints the subjects of the commits a pull request
  adds, not the pull request's title, so a conventional title fixes what a
  squash merge lands on `main` and leaves the required check exactly as it was.
  Rewriting a session's branch is not the dispatcher's to do, so the pass now
  reads the pull request's commits, logs how many subjects the check rejects,
  records `commit_subjects_ok: false`, and counts them in `status.json` —
  instead of reporting a still-blocked pull request as fully settled.
- **One ledger record per session, not one per pull request** (Codex gate,
  medium, twice). Records were appended a line at a time, so a failure after
  the first line left the session looking reconciled while the rest of its
  pull-request provenance was never written, and every later run skipped the
  gap. A record now *is* the "this session is settled" marker: one line
  carrying a `prs` array, which is the same unit of write every other ledger
  append already relies on rather than a new claim about multi-line atomicity.
  A record past the length bound is refused and retried rather than truncated.
- **Three more ways the session response could mislead the pass** (Codex gate,
  medium). A `pullRequest.url` carrying an embedded newline was split into two
  URLs before the anchored pattern saw either, so one malformed field could
  drive writes to two pull requests; outputs are now read one JSON value at a
  time and the whole field must match. A response whose `outputs` could not be
  parsed fell through to a terminal `no-pr` record, freezing an outcome nobody
  had read; it is now a counted failure and retried. And the commit-subject
  report is taken from `repos/{o}/{n}/pulls/{n}/commits`, the only payload that
  carries each commit's parents, so merge commits and the revert auto-message
  are skipped exactly as `check-commit-format.sh` skips them — otherwise a pull
  request CI is perfectly happy with would have been reported as blocked.
- **Two more ways a malformed or long response could mislead the pass** (Codex
  gate, medium). The commits endpoint pages at 100, so a rejected subject on
  page two was missed under a terminal record that stopped anything looking
  again; the fetch now paginates and the pages are concatenated locally. And
  jq's `//` replaces `false` as well as `null`, so an `outputs: false` response
  counted as zero pull requests and earned a permanent `no-pr` record — outputs
  are now tested by type, and anything that is neither absent, null, nor an
  array is a counted failure that is retried.

## 2026-09-21 — fix(review-receipt): a blocked review retires the other lane's approval

- **A failed newer review can no longer be bypassed by an older competing
  approval.** `begin` invalidated only its own lane, so with an Antigravity
  approval already in hand for the unchanged HEAD, a Codex gate that then
  reported blocking findings and exited 2 left that approval standing — and
  because `githooks/pre-push` calls `check` with no `--reviewer`, which accepts
  either lane's receipt, a plain `git push` shipped the diff the newest verdict
  had just rejected. `begin` now retires every lane's receipt and attempt token,
  not just its own, so the only receipt that can exist belongs to the most recent
  attempt; a blocked review, which records nothing, therefore leaves nothing for
  the push boundary to accept. Re-running the lane and approving ships as before.
  Bumping the competing attempt token also supersedes a review already in flight
  in the other lane, closing the same hole when the two overlap in time. The
  `invalidate` subcommand keeps its own-lane scope: a gate's cancellation trap can
  fire before `begin`, and a review that never started cannot reach a verdict, so
  it must not cost an untouched approval. Receipt format and every other lane
  rule are unchanged, so existing receipts stay valid. `review-receipt.test.py`
  covers both lane orderings and the in-flight case, and
  `tests/pre-push-receipt.test.sh` drives the real hook and a real `git push`:
  before the fix the blocked-review push reached the origin. Closes #480.
- **The attempt transition is serialized, so two gates cannot start at once and
  both stay live.** Retiring the competing lane and opening this lane's attempt
  are several file operations, and two concurrent `begin` calls could interleave
  them: each retired the other's lane before either wrote its own token, leaving
  BOTH tokens live and the bypass above reachable again. Every writer of the
  shared attempt and receipt state — `begin`, `complete`'s deciding attempt check
  and receipt write, and the `invalidate` subcommand — now runs under an exclusive
  `flock` on `<git-dir>/review-receipts/.lock`. flock rather than a lock
  directory for the reason `jules-dispatch.sh` gives: the kernel releases it when
  the holder dies, so a killed or cancelled gate cannot wedge the next one.
  `check` stays lock-free by design — it re-asserts the attempt token on both
  sides of the artifact capture, so a transition landing mid-check can only make
  it refuse, and a slow check must never block a gate. Found by a non-gate review
  of the first commit; the three new tests fail on it, the interleaving one with
  both lanes reported live.
- **Both gates now say so before they retire anything.** `gate_init_receipt`
  warns, ahead of `begin`, when the other lane already holds a receipt for this
  artifact and names the recovery. The Antigravity gate's supplementary-lane
  banner prints long after `begin` has run, so it was too late to be a warning.
- **Documented: a degraded lane still costs the other lane's approval.** A gate
  that exits 3 (agy missing, byte cap, unverifiable model pin) has already run
  `begin`, so the other lane's receipt is gone even though a degraded lane is not
  a verdict. Re-run the required gate. The refusal is deliberately conservative —
  at the push boundary nothing distinguishes "could not run" from "ran and
  blocked" without trusting the gate that failed — and the case is exercised by
  `workflow-shipping-rewrites.test.py`. Follow-up issue #499 tracks a retraction
  design that would not cost the approval.

## 2026-09-21 — chore(doctor): declutter plugins and slim the always-loaded global instructions

- **Eleven `[global]` plugins left `claude/plugins.txt`.** `/doctor` found eight
  with zero lifetime uses (playground, claude-code-setup, claude-md-management,
  code-review, code-simplifier, frontend-design, github, greptile) that were
  already disabled in `~/.claude/settings.json` but still installed, so
  `PluginDriftCheck.hook.ts` warned at every session start; they are now
  uninstalled and dropped from the manifest. `pr-review-toolkit` (six uses since
  install, six resident agent descriptions), `feature-dev`, and
  `commit-commands` are disabled and dropped for the same reason. Re-enable any
  of them by restoring its manifest line and flipping `enabledPlugins`.
- **The global instructions shed the README prose and the gate mechanics.**
  `agents/canon/fragments/claude.md` loses the "this repo is public, repoint
  the import" explanation (README material) and keeps only the four
  non-negotiables of the multi-agent section; the lane-selection, handoff
  payload, and verdict-persistence mechanics move to the new
  `claude/skills/review-gates/SKILL.md`, loaded on demand. Concept parity is
  unchanged (`check-agent-parity.sh` still finds every canonical rule), and
  the generated `claude/CLAUDE.md` is regenerated in the same change.

## 2026-09-21 — fix(review-receipt): nested worktrees and vendored instruction names

- **An own worktree no longer aborts the snapshot, and only an own worktree is
  dropped.** `git ls-files --others` reports a directory it will not descend into
  as one entry with a trailing slash, so the `.claude/worktrees/agent-…/` entry
  matched `instruction()` and reached `file_bytes()`, which refuses a directory:
  every gate run from the main checkout failed with `cannot snapshot non-file`
  while any agent worktree was retained. Both the `untracked` and the
  `ignored_instructions` comprehension now drop such an entry, but only when
  `os.path.realpath` of it is one of this repository's own worktrees per `git
  worktree list --porcelain -z` *and* the directory's `.git` pointer file names a
  gitdir inside this repo's worktree store that points back at that same pointer
  file. Three weaker forms of the check were fail-open, each caught in review of
  this change: skipping every trailing-slash entry let any directory holding a
  `.git` with HEAD, objects and refs hide a dirty `.claude/skills/*/SKILL.md` and
  still mint a receipt; the registered path alone let a decoy inherit the
  registration of a worktree whose directory had been removed, since git keeps
  listing it and stops calling it prunable once the path is occupied again; and
  requiring only that `.git` be a file admitted a foreign repository planted there
  with `git init --separate-git-dir`. `-z` because git prints worktree paths raw,
  so a newline in one would otherwise truncate the entry and synthesize a line
  that was never a worktree. Every other boundary keeps failing closed.
  Closes #474, closes #495.
- **A dependency's own `CLAUDE.md` is not an instruction surface.** #426 cleared
  only the `hook` term of `instruction()`, and `named_instruction()` matches on
  basename alone, so `claude/hooks/node_modules/bun-types/CLAUDE.md` still
  blocked a committed review on a clean tree. The vendored/lockfile test now
  short-circuits the whole predicate, fires only *below* the hook marker so a
  dependency that vendors a `githooks/` directory cannot hide its own `AGENTS.md`,
  and recognises the installed hook trees (`.claude/hooks`, `.codex/hooks`,
  `.gemini/hooks`) alongside `claude/hooks`. Real `AGENTS.md`, `SKILL.md` and
  `node_modules/example/AGENTS.md` outside a hook tree stay in scope, which
  `review-receipt.test.py` asserts alongside the name variants that slipped
  through. The predicate is unchanged for all 256 tracked paths. Closes #439.

## 2026-09-21 — fix(review): record tier-1 exemptions without dispatching a gate

- A tier-1 (docs-only) diff needs no reviewer, but `review-and-push.sh` collected
  its exemption receipt by running the Antigravity gate, whose line cap and
  measured prompt-byte cap run *before* its tier valve. A docs-only diff above
  either cap therefore exited 3, costing a needless Codex fallback — or, under
  `REVIEW_LANE_FALLBACK=block`, refusing a push no reviewer was going to look at.
  The wrapper now records the exemption itself through the same capture path the
  gates use, so no reviewer's dispatch limits can decide whether an exemption is
  available. `review-receipt.py` remains the authority: `complete --outcome
  tier-1` refuses any artifact that is not a small docs-only diff and `check`
  recomputes the classification, so nothing recorded this way can ship a diff
  whose required lane is above `any`. Gates are unchanged, including the
  Antigravity gate's refusal to exempt a diff too large for its own input window
  when it is invoked directly. New dispatch cases in
  `tests/review-and-push.test.sh` drive the real Antigravity gate with tiny caps
  and assert the tier-1 push succeeds under both fallback settings, that a
  demoted or instruction-surface Markdown diff gets no exemption, and that an
  oversized *ordinary* diff still degrades and falls back as before. Closes #482.

## 2026-09-21 — fix(worktree-lifecycle): exempt the uninspectable systemd user-session pair

- `release` (and therefore `retire`) always refused on any systemd user-session
  host: `systemd --user` and its `(sd-pam)` helper are same-uid processes whose
  cwd, root, exe, descriptor targets and maps refuse this user with `EACCES`,
  and fail-closed retained on that. New `--trust-process-manager` exempts that
  pair, and only on the whole signature (current user's credentials, every
  reference of every thread denied with `EACCES`, and an identity the user
  cannot forge) — one readable reference is evidence, not an exemption. Without the flag the refusal now names the pid and
  the flag instead of repeating the generic message. Each exempted pid, comm and
  ppid lands in the release record's `exempt_processes` and travels into the
  recovery record, so the archive shows what was never inspected.
- **Identity comes from the system manager** (Codex review finding, medium):
  `PPid` 1 does not mean pid 1 started a process — an orphan is reparented — and
  `comm` is self-settable, so the first draft would have exempted a same-user
  look-alike. The manager is now the pid `systemctl show --property=MainPID
  user@<uid>.service` reports, and the helper must be a `(sd-pam)` child of that
  pid in the manager's own session, which a service cannot be: systemd starts
  each service in a session of its own. A host where that pid cannot be resolved
  exempts nothing.
- **Why an assertion rather than an inference** (Codex review finding, medium):
  pid 1 starting a process proves no shell in a worktree did, so it holds no
  cwd, root, exe or mapping there — but a user unit can hand a worktree
  descriptor to the manager's file-descriptor store (`FDSTORE=1`) and close its
  own copy, and no unprivileged scan can read those targets. The residual is the
  operator's call, so the exemption is opt-in on both commands and recorded.
- **What the archive shows** (Codex review finding, medium): retirement inspects
  again and its scans can exempt different pids than release did, so
  `recovery.json` now carries `retirement_exempt_processes` — every identity
  either retirement scan skipped — beside the release record's
  `exempt_processes`. A restarted session manager therefore changes the archived
  identities without failing the archival recheck, which ignores that key.
- Cases: the pair refusing release until asserted, the asserted pair released and
  retired end to end with real `EACCES` (record and `recovery.json` both list
  it), retirement still needing the flag, the archive recording what retirement
  itself exempted after the manager restarts under a new pid, the manager's
  descriptor table that lists names while refusing every target, seven identity
  look-alikes that retain even under the assertion (including an unnamed pid
  claiming `comm` `systemd` and a `(sd-pam)` child in a session of its own),
  partial readability on each of the five surfaces, and `EPERM` instead of
  `EACCES`. The fixture answers for the system manager the way it answers for
  `gh`. Closes #475.

## 2026-09-21 — fix(gen): SIGPIPE in --check, plus checker docs and an unasserted count

- **`gen-instruction-files.sh --check` no longer dies of SIGPIPE.** The stale-diff
  preview was `sed … | head -20`, which makes `sed` the pipe *writer*: once a diff
  outgrew the pipe buffer, `head` closed the read end, `sed` took SIGPIPE, and
  `pipefail` + `set -e` ended `--check` inside the target loop — remaining targets
  were never compared and the operator saw a bare exit 141 instead of the stale
  list. `head` now reads the file first and `sed` indents what it emits, the fix
  #422 applied to the Antigravity gate. A new `agent-parity.test.sh` case builds a
  200k-line stale target followed by a second stale one and asserts exit 1 with
  both names in the summary; it reproduced exit 141 before the change. The other
  `| head` sites in `claude/scripts/` were re-checked rather than trusted: none
  runs under `set -e`; two wrap the pipeline in `|| true`, one relies on the
  absence of `set -e`, and one is an `if` condition. Closes #443.
- **Every drift guard is in the scripts table.** `claude/scripts/README.md` listed
  a couple of the `check-*` scripts; it now carries a row for each one, naming
  what it asserts and the CI job and step that runs it — including the three that
  reach CI only through another script or only as a self-test, and the two that
  are local guards rather than CI gates. Closes #445.
- **ADR-0009 no longer states a source count.** The 2026-09-19 observation that
  `GET /sources` uses the guide's `sources/github/{owner}/{repo}` spelling stands;
  the fixed number of connected repositories beside it was asserted nowhere and
  now points at `jules-dispatch.sh --dry-run`, which logs the live count it read.
  Closes #485.

## 2026-09-21 — fix(jules-dispatch): resolve the starting branch while deciding eligibility

- The branch lookup moved out of `dispatch_one` and into phase one, the
  eligibility pass a dry run and a live run share. A pair whose source reports no
  default branch and has no `JULES_STARTING_BRANCH` override is now refused
  before it is queued, so it no longer spends a slot of the daily cap and defers
  a valid pair behind it (#486), and `--dry-run` reports the same refusal instead
  of promising a dispatch the live run rejects (#487). The resolved branch travels
  with the candidate, so nothing re-resolves it in phase two.
- The injected prompt header now demands conventional commit subjects, naming the
  type set `check-commit-format.sh` enforces. The first live run's subject was
  `No changes needed: doc drift checkers pass`, which that required check rejects;
  the catalog files already asked for conventional subjects and the session
  ignored them, so the requirement sits in the first line it reads. This is
  option (b) of #479's gap 1 only — the empty-PR and label gaps stay open.
- `jules-dispatch.test.sh`: three cases added (cap not spent by a branchless
  pair, the dry-run refusal with a byte-identical state dir, and the header's
  type list asserted against the checker's own `TYPES`, so the two cannot drift).

## 2026-09-19 — fix(jules-dispatch): send the source's default branch as startingBranch

- `GitHubRepoContext.startingBranch` is required: the first live `POST /sessions`
  without it returned `400 INVALID_ARGUMENT` (ADR-0009's open question,
  answered). The dispatcher now takes the branch from `GET /sources`
  (`githubRepo.defaultBranch.displayName`) unless `JULES_STARTING_BRANCH`
  overrides it, and refuses a pair with neither before the write-ahead record so
  nothing is charged against the cap. The fake curl in `jules-dispatch.test.sh`
  now captures the request body; three cases cover the derived branch, the
  override, and the refusal.

## 2026-09-19 — chore(codex-gate): declare Jules routine prompts in `.codex-review-ignore`

- `agents/routines/*` and the generated root `AGENTS.md` are instruction-bearing
  by design (ADR-0009), and the gate filed one low finding per file for exactly
  that (#457–#464, closed as not planned). Declaring them steers the reviewer off
  those strings; the paths stay in review scope. Closes #466.

## 2026-09-18 — feat(review): Antigravity-first ordinary lane, Codex for risk surfaces (ADR-0008)

- **Closed a pre-push fail-open.** `githooks/pre-push` calls `review-receipt.py
  check` with no `--reviewer`, and `check` returned on the first valid receipt of
  *either* lane — so an Antigravity-only receipt already shipped a risk-surface
  diff. Receipts are now version 2 and carry the classification that produced
  them; `check` recomputes it on the re-captured patch, refuses a mismatch, and
  refuses a receipt whose lane ranks below what the diff requires. The hook
  itself needed no change, which `tests/pre-push-receipt.test.sh` proves by
  driving the real hook over a local bare origin.
- **One classifier names the lane.** `classify_tier` now returns `{tier, reason,
  risk_paths, required_lane}` with `required_lane ∈ any | antigravity | codex`
  (tier 1 → `any`; tier 2 with no risk path → `antigravity`; risk paths, an
  empty changed-path list, or an unreadable classification → `codex`). Lanes rank
  `any < antigravity < codex`. Size alone never escalates the lane. New
  read-only `review-receipt.py lane` prints that JSON and mints nothing.
- **Dispatch.** `gate_classify_tier` exports `GATE_REQUIRED_LANE` and
  `GATE_RISK_PATHS` — every path that could not read a validated classification
  leaves the lane at `codex` — and new `gate_select_lane` turns a requirement
  into the gate to run. `review-and-push.sh` classifies, dispatches that gate
  with `--require --committed`, and drops `--reviewer codex` from its receipt
  check. `REVIEW_LANE=auto|codex|antigravity` overrides the choice: escalation is
  honoured, and `antigravity` on a codex-required diff is **refused** rather than
  honoured. `GATE_FORCE_FULL=1` keeps the strongest lane in the wrapper too, as
  it already did inside `gate_classify_tier` (Codex gate finding on #473).
- **A degraded lane is not a verdict.** `REVIEW_LANE_FALLBACK=codex|block`
  (default `codex`): Antigravity exit 3 — agy missing, an unverifiable model pin,
  a diff above its measured 185 KB input window — falls back to Codex and records
  the degradation. Exit 2 (blocking findings, verifiably wrong model) never falls
  back; re-asking a different reviewer would be verdict shopping.
- On a codex-required diff the Antigravity gate still runs and still mints its
  receipt, now announcing itself as a **supplementary** lane: an
  independent-lineage second opinion, not shipping evidence.
- **Measurement.** `complete` appends `{completed_at, lane, outcome, tier,
  required_lane, head, note}` to `<git-dir>/review-receipts/ledger.jsonl` (0600,
  append-only, `O_NOFOLLOW`, never read by `check` — a forged ledger cannot
  approve a push and an unwritable one cannot block one). New
  `review-receipt.py stats [--since-days N]` prints lane × outcome plus the
  "antigravity degraded → codex" count. Nothing before this could count reviews
  per lane: `run-*` directories are ephemeral and `<lane>.json` is overwritten
  per attempt.
- **The dotfiles risk list is deliberately NOT narrowed** (`*scripts/*`, hooks,
  `.github/`, instruction files, and the `auth|token|secret|…|schema|migration`
  substrings), so most diffs *in this repository* still require Codex. The quota
  saving lands in the application repos where ordinary diffs are the common case.
  Read the ledger before proposing any change to the risk list.
- Breaking: every existing receipt is invalidated by the version bump, so the
  first push after this lands needs a fresh gate run.
## 2026-09-18 — feat: Jules as the daily-routine lane (ADR-0009)

- The standing, evidence-checkable cleanups nobody schedules — dead code, tests
  that cannot fail, drifted duplicate helpers, lint debt, doc drift — now have a
  lane. `agents/routines/*.md` holds one standing prompt per routine, six to
  start, and `claude/scripts/jules-dispatch.sh` turns the catalog into one Jules
  session per routine per repository per day. Rationale, the API surface verified
  on the day, and what remains unverified: `docs/adr/0009-jules-routine-lane.md`.
- Routine frontmatter is a contract, not documentation: the dispatcher parses it
  strictly and refuses a routine whose header does not validate. `schedule` is
  enforced, not decorative — a weekly routine runs on the seventh day. The prompt
  a session receives is the body with the frontmatter's concrete limits
  prepended, so a routine file never repeats its own limits in prose. An edit
  made mid-run is honoured: the whole eligibility decision is re-checked before
  each session, so pausing a routine or dropping a repository stops the ones
  still queued.
- Dispatch goes through the REST API, not the `jules` CLI, whose credential
  location is documented nowhere and so cannot be shown to work under
  `ProtectHome=read-only`. The key must be a regular file, not a symlink, mode
  0600, non-empty and at least 20 characters; it reaches `curl` through a config
  file on stdin so it never enters argv or a log; the variable holding it is
  unset before assignment so an inherited export cannot carry it into a child's
  environment. The host is a constant, every request leads with `-q` so a
  `~/.curlrc` cannot re-enable redirects or tracing, and `-L` is never passed. A
  repository's `source` is always read back from `GET /sources`, following
  `nextPageToken`, and never constructed.
- The ledger is write-ahead — a record before the request, upgraded after it —
  because a session created by a request that then timed out would otherwise be
  invisible, dispatched again by the next run and absent from the cap. Anything
  that can fail locally happens before that record, so a local failure leaves the
  pair retryable. Unresolved attempts are reported for reconciliation and not
  retried that day. `JULES_DAILY_CAP` bounds the spend, and the least
  recently dispatched pair goes first, so the cap defers work to a later day
  instead of starving the tail of the catalog permanently.
- New `jules-dispatch.{service,timer}` at 09:00, hardened like
  `git-hygiene.service`, with the state directory as its only writable path — the
  key directory is deliberately absent, so the unit reads the credential and can
  never rewrite it. `claude/systemd/install.sh` is now a loop over a table of
  unit pairs, and reads the script it validates out of each unit's own
  `ExecStart` rather than a second copy of the path that could disagree with it.
- A root `AGENTS.md` joins the generated instruction files (ADR-0007): the short
  brief an agent reads from the checkout itself when it has no session history.
  Enforced by the generator's byte-currency check rather than the concept-parity
  phrase list, because holding a deliberately short cloud brief to every local
  file's phrases would defeat the reason it is short.
- `setup.sh` installs the CLI npm-global beside Codex, prints `jules login` as a
  manual step under `--yes`, and reports `jules_installed`.
  `agents/capabilities.json` gains `jules` as a fourth runtime — `unsupported`
  for every locally-provisioned capability, because it installs nothing on this
  machine — and a `routine-lane` capability where the dispatcher is the provider.
- Measurement ships with the lane: `--report` tallies opened, merged and closed
  per routine per week, covering every repository the routine was ever dispatched
  to rather than only the ones it currently lists, and states in the report body
  whenever the numbers are partial. The retirement rule is in the ADR and
  `agents/README.md`.
- `tests/jules-dispatch.test.sh` drives all of it against a fake `curl` with a
  pinned clock, so none of it waited on a live key and none of it can fail on a
  schedule. The independent review and fifteen Codex gate rounds are recorded in
  the ADR, along with the twenty-eight further issues they found and the
  categories those fell into. Two lessons are worth carrying out of this repo:
  three findings were one bash mistake in different dress — a `die` in a process
  substitution, an assignment in a command substitution, a read nested in a
  `printf` argument, each running in a subshell whose exit status the caller
  never saw — and twice a test was deleted rather than shipped because it could
  not fail, which would have contradicted `useless-test-pruner`, a routine this
  same change adds.
- New root `.gitleaksignore` with one audited entry: an earlier commit on the
  branch carries a test fixture shaped like a Google API key, which the scanner
  caught correctly. The fixture has been renamed; the entry names the commit and
  why the match is harmless, and the file's header states that an entry means
  someone looked, never that the scanner was inconvenient.
- ADR status is **Proposed**, not Accepted: the first live dispatch needs an API
  key only the operator holds. The ADR carries the exact commands for it and the
  list of what that run will resolve.

## 2026-09-18 — test: Hypothesis property suites and a seeded setup.sh layout fuzzer

- The two pure-logic Python tools had example-based suites only. Hypothesis
  properties now cover `review-multipart.py`'s splitter — fragments rejoin to
  the original, none exceeds the UTF-8 byte bound, none is empty, each is a
  contiguous byte slice, and a bound too small for one character raises rather
  than truncating (#420, #444) — and `review-receipt.py`'s `classify_tier`
  against an oracle written from the risk list rather than from the module's own
  `risk()`/`docsafe()` helpers, since an oracle built from the implementation
  agrees with whatever bug the implementation has.
- `review-receipt.py check` is now fuzzed against single-leaf receipt tampering:
  every integrity-bearing leaf of a real receipt is refused. The five
  audit-metadata leaves the receipt deliberately does not bind
  (`policy.tier1_max_lines` and the four `reviewer.*` model/executable fields)
  are enumerated and excluded, so the threat-model boundary is written down
  instead of discovered.
- `setup-fuzz-layouts.test.sh` draws seeded pseudo-random `$HOME` layouts and
  asserts the `--dry-run` no-writes contract (#133) against each, rather than
  against the single hand-built layout `setup-dry-run.test.sh` uses. `SEED`
  makes a red run reproducible and is printed on every failure.
- Each layout runs under `env -i` with an explicit allowlist. setup.sh reads
  `DEV_DIR`, `DOTFILES_DIR`, the installer pins, `GIT_NAME`/`GIT_EMAIL` and the
  private-memory repo paths from the environment, and defaults
  `CODEX_MEMORY_REPO` to a sibling checkout, so an inherited value would make a
  layout irreproducible from `SEED` and could redirect a write outside the
  throwaway `$HOME` where the snapshot cannot see it. For the same reason the
  `bun=absent` draw prunes every `PATH` entry providing `bun` instead of leaving
  `PATH` alone, and the absent private-memory draw points at a path inside the
  throwaway `$HOME` that is never created. An "absent" axis that is not really
  absent tests nothing.
- The snapshot helper moved to `tests/lib-snapshot.sh` so both setup suites
  assert "zero mutations" with the identical comparison; `setup-dry-run.test.sh`
  sources it and is otherwise unchanged.
- `codex-review-gate.test.sh` covers three more malformed-classifier shapes
  (empty helper output, a JSON `null`, a one-element array); each must keep
  `GATE_TIER=2` and the full review pass.

## 2026-09-18 — fix(codex-gate): location-keyed issue dedup, `.codex-review-ignore`

- The gate filed every low-severity finding as a GitHub issue and deduped only
  on an exact open-issue *title* match. Codex paraphrases titles between runs,
  so one fixture finding accumulated sixteen issues in the TRNN repo; #433 is
  the same class here. Dedup is now keyed on the finding's **location**: filed
  issues carry a hidden `<!-- codex-gate-loc:<owner/repo>:<file> -->` marker
  (the file only — line numbers drift), the gate prefetches existing
  `codex-review` issues in all states once, and an already-open issue for that
  file collects one "seen again" comment instead of a duplicate.
- Closing such an issue as *not planned* now suppresses it: the gate reports
  `accepted (#N), skipping` and files nothing. Closed as *completed* means the
  code was fixed, so the same location reappearing is refiled as a regression.
  A failed prefetch files nothing rather than filing blind.
- An empty `state_reason` in the prefetched index shifted the issue body out of
  the field the marker is read from, because tab is an IFS whitespace character
  and `read` collapses a run of tabs — open-issue dedup would have silently
  never matched. Absent reasons now carry a placeholder.
- The prefetch was lifted into `gate-lib.sh`, so the gate's low-finding feed
  and `harvest-codex-comments.sh` share one REST mechanism; the repo slug is
  read from the git remote rather than GraphQL-backed `gh repo view`.
- New optional per-repo `.codex-review-ignore` declares path globs whose
  contents are hostile by design. Matching paths stay in the review scope; the
  reviewer is only told not to report instruction-like strings inside them. The
  file is parsed as bounded untrusted data and fenced like the diff. This
  repo's copy covers `claude/scripts/tests/*`, whose fixtures embed injected
  verdicts and synthetic credential markers on purpose.
- `.codex-review-ignore` is itself a reviewer-instruction surface: the gate's
  self-review guard and the receipt helper's instruction classifier both
  cover it, and a committed review reads the copy in the reviewed commit,
  never the working tree.

## 2026-09-18 — style(python): adopt ruff and gate it in CI

- Every `*.py` in the repo is now formatted by `ruff format` and linted with
  `E,F,W,I,B,UP` (`E501` ignored: line length is the formatter's job). The
  config is a root `ruff.toml`, not a `pyproject.toml`, because a root
  pyproject makes uv/pip treat dotfiles as a Python project; `required-version`
  pins ruff and the CI job runs the same pin via `uvx`. Target is `py39`, the
  macOS system python floor.
- The one-time sweep reformatted 23 files and fixed 77 findings. The
  formatter and `--fix` cleared E701/E702/I001; the 20 B023 loop-variable
  closures (four test suites and `review-receipt.py`) and one E741 were fixed
  by hand by binding the loop variable as a default argument — every closure
  is called within its own iteration, so behaviour is unchanged. No `noqa` or
  `per-file-ignores` were added.
- New required-style CI job `python-lint` (`ruff check`, `ruff format
  --check`, and `check-jsonschema --check-metaschema` over the Codex review
  output schema, which nothing validated before). Add it to branch protection
  after this lands (`docs/BRANCH_PROTECTION.md`).
- Shipped as two PRs so the reformat did not bury the review: the
  mechanical `ruff format`/`--fix` output landed first on its own, then
  this config, hand-fix and CI change on top of it.

## 2026-09-18 — ci: actionlint, JSON validity, .editorconfig

- The `checks` job now runs [actionlint](https://github.com/rhysd/actionlint)
  (pinned `docker://rhysd/actionlint:1.7.12`) over `.github/workflows`. The
  image bundles shellcheck and pyflakes, so every inline `run:` block is
  shellchecked — a surface the standalone `shellcheck` job never saw. The
  1.7.12 binary reports zero findings on the current workflows, so the step is
  blocking from the first run.
- `json-valid` step: every tracked `.json` must parse under `jq empty`, with a
  `::error::` annotation naming the file that does not. All seven tracked JSON
  files parse today.
- Root `.editorconfig` declares the observed conventions (LF, final newline,
  UTF-8, 2-space; `*.py` 4-space; `*.md` keeps trailing whitespace for hard
  line breaks). Declarative only — no file was reformatted and no CI step
  enforces it.
- yamllint was considered and rejected: its default findings are almost all
  line-length in GENERATED `AGENTPACK.yaml` and `openai.yaml`, and
  `mkdocs.yml` is already asserted by `mkdocs build --strict` in `pages.yml`.

## 2026-09-17 — ci: guard that every test file is wired into a workflow

- Three test files shipped unwired in the last two fixes and were caught by
  hand each time. New `claude/scripts/check-tests-wired.sh` makes the wiring
  a CI assertion: every `claude/scripts/tests/*.test.{sh,py}` and
  `codex/tests/*.py` path must appear in `ci.yml` or `smoke-install.yml` with
  YAML comments stripped, or in a test file those workflows already run (one
  level of transitivity, which is how `codex-remote-recovery.test.sh` reaches
  `codex/tests/test_remote_control_recover.py`). `OPT_OUT` carries the one
  test that needs a real Codex binary, with its reason.
- `tests/check-tests-wired.test.sh` covers wired, unwired, comment-only
  mention, transitive, smoke-install, opt-out, and missing-workflow cases, and
  ends by running the real checker against the repo — so the guard proves it
  is itself wired. Both run in the `checks` job beside `install-integrity`.

## 2026-09-17 — fix(review-multipart): byte-bounded fragments and CODEX_HOME isolation

- The multipart transport sliced a large review request into 200,000-character
  fragments, so token-dense Unicode produced 800,000-byte fragments far past
  the window the receiving model was sized for (#420). Fragments are now
  bounded by UTF-8 bytes and split only on character boundaries; ASCII
  requests are unaffected.
- `codex-review-multipart.test.sh` set only `HOME`, but the transport check
  reads `CODEX_HOME` first, so a runner that already exported it defeated the
  fixture's isolation (#419). The fixture pins `CODEX_HOME` per invocation,
  exports a poisoned value around the loop, and asserts that poisoned home is
  never created — dropping the pin now fails the suite instead of passing
  against the inherited value.
- Neither `codex-review-multipart.test.sh` nor `review-multipart.test.py` was
  wired into CI; both now run in the `checks` job. `review-and-push.test.sh`
  shipped unwired too and joins them there.

## 2026-09-17 — fix(agy-gate): zero timeout, long failure reports, measured input cap

- `ANTIGRAVITY_GATE_TIMEOUT=0` is documented as "disabled" but the outer
  ceiling added 30 seconds to it, capping a run the setting was meant to leave
  unbounded. Zero now passes through to both agy's `--print-timeout` and the
  portable `timeout` wrapper (#421).
- A failed `agy` run that wrote more than a pipe buffer of output or stderr
  killed the gate with SIGPIPE (141 on WSL2) before it could degrade, because
  `sed … | head -20` ran under `set -euo pipefail`. `head` now reads first, so
  the report is truncated without ending the run (#422).
- The large-diff fixture baked a bare `timeout` into its shim, which exits 127
  on stock macOS; the test resolves `timeout`/`gtimeout` the way `_tmo` does
  and falls back to running unbounded (#423).
- New `ANTIGRAVITY_GATE_MAX_BYTES` (default 185000, `0` disables) caps the
  review prompt at the measured agy print-mode input window. Only ~185 KB of a
  single user message reaches the model and the remainder is dropped with no
  truncation notice, so a larger prompt would certify a slice of a diff as a
  review of all of it. Above the cap the gate degrades and mints no receipt;
  the multipart-transport plan for this lane is dropped (#409). The cap is
  checked before the tier-1 valve, which records a receipt without
  dispatching: a docs-only diff of one 200,000-byte line clears the tier's
  line count and must not collect a reduced-ceremony receipt either.

## 2026-09-17 — fix(doc-truth): run the checker on the macOS system bash (#424)

- `check-doc-truth.sh` is vendored verbatim into other repos but read
  `git ls-files` with `mapfile`, a bash-4 builtin. On Apple's bash 3.2.57 the
  read failed and the next line dereferenced the never-populated array, so the
  checker aborted before running a single rule. It now reads the file list with
  a `while IFS= read -r` loop over a process substitution — a process
  substitution, not a pipe, so the loop body stays in this shell and keeps
  updating the violation counter.
- Sweeping the same category found the second half: under `set -u` bash 3.2.57
  calls `${arr[@]}` unbound when the array is empty, so any repo with no
  tracked markdown would have hit the same abort. Index expansion
  (`${!arr[@]}`, `${#arr[@]}`) is safe there and is what the script already used
  everywhere else — verified on a bash 3.2.57 build, not assumed.
- The header now states the real floor (bash 3.2+) instead of "bash 4+", and
  `tests/doc-truth.test.sh` grows a Cycle 7 of static guards over the checker's
  own source: bash-4 builtins, `declare` flags, case conversion, `;&`/`;;&`
  fallthrough, `{fd}` redirections, `${v@Q}`, `read -N`, bash-4 `shopt` names,
  negative subscripts, and bare `${arr[@]}`. Comment lines are stripped and
  backslash continuations joined, so neither the header's prose nor a line
  break can hide a banned construct.
- A denylist is never finished — five review passes each found more of it — so
  CI now runs a real interpreter too. A new `doc-truth (bash 3.2)` job builds
  bash 3.2.57 from the GNU sources with a pinned SHA-256 and caches it.
  `DOC_TRUTH_BASH3` steers **every** fixture rather than a handful of extra
  cases, so the failure paths get 3.2 coverage: against the pre-fix checker that
  is 34 of 49 fixtures failing, where bash 5 catches 2. A path that is not a
  genuine bash 3.x is a test failure, never a silent skip. The job is
  deliberately separate from the required `doc-truth` context so an unreachable
  ftp.gnu.org cannot block every PR; promote it once it has a track record.
- The file list is read with `git ls-files -z` and `read -d ''`. Without it
  git quotes and octal-escapes any path holding a quote, a backslash or a
  non-ASCII byte, and the checker went looking for a file named after the
  escape — a latent bug the mapfile version shared. Two fixtures cover it.
## 2026-09-17 — fix(review-and-push): routing guard and executable-bit drift

- `review-and-push.sh` inherited Git routing (`GIT_DIR`, `GIT_WORK_TREE`,
  `GIT_INDEX_FILE`, `GIT_CONFIG*`, and the rest of that family) from its caller,
  so a clean alternate checkout could answer every cleanliness, branch, and
  commit checkpoint while the tests ran in `REPO_DIR` and the push shipped an
  unreviewed `HEAD` (#401). The same guard `git-hygiene.sh` already carries now
  refuses those variables before the first Git call.
- Where `core.fileMode` is `false` — this repo included — flipping a tracked
  script's executable bit produced no `git status` output and no `ls-files`
  flag, so tests could pass on the locally executable file while the pushed
  commit kept the old mode (#402). Index modes are now compared against the
  working tree directly, on filesystems that record an exec bit at all.
- New `claude/scripts/tests/review-and-push.test.sh` covers both. The rewrite
  fixtures in `workflow-shipping-rewrites.test.py` moved their global-config
  isolation from `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM` to `HOME` and
  `XDG_CONFIG_HOME`, which the new guard leaves alone.

## 2026-09-17 — fix(setup): match plugins by user scope, not by name

- Sweeping the #437 neighborhood turned up the same scope blindness in a third
  consumer. `setup.sh` §3b matched manifest entries against raw
  `claude plugin list` output, which reports project- and local-scoped installs
  from any directory. A manifest plugin someone had installed with
  `--scope project` therefore read as already installed, and setup skipped the
  user-scope install the manifest promises. Reproduced against the live CLI:
  the project-scoped `render` matched, though no manifest entry is affected on
  this machine today.
- The rule now lives in one place. `user_scoped_plugins()` in `lib-checks.sh`
  reduces a listing to user-scope ids, `setup.sh` matches whole lines against
  it, and `tests/plugin-drift.test.sh` pins the extraction alongside the hook
  and sync cases.

## 2026-09-17 — fix(plugins): scope-aware drift check and sync fast path (#437)

- Every session warned that `render@claude-plugins-official` was "missing from
  the manifest". It is installed `--scope project` by the one repo with a
  `render.yaml`, and #393 deliberately removed it from `claude/plugins.txt`
  because `setup.sh` and `sync-plugins.sh` install at user scope. The hook read
  every key of `installed_plugins.json` regardless of scope, so the only remedy
  it suggested would have reinstated the behavior #393 fixed.
- `PluginDriftCheck.hook.ts` now measures both drift directions against
  user-scope installs. `user` is matched as an allowlist, so `--scope local`
  and any future scope do not silently satisfy the manifest; unrecognised
  record shapes still count as installed.
- `sync-plugins.sh`'s fast path had the same scope blindness in the other
  direction: a manifest plugin held only at project scope satisfied its key
  match, so it exited without installing and the hook warned again next
  session. It now matches on user-scope installs too, so the remedy the
  warning points at actually clears the warning.
- New `tests/plugin-drift.test.sh` pins both sides, wired into the `checks`
  CI job, which now sets up bun to execute the TypeScript hook.

## 2026-09-17 — test(setup-dry-run): run the no-writes suite from a worktree (#435)

- `setup-dry-run.test.sh` reported 16 false failures from any linked git
  worktree: the guard from #412 refused every `setup.sh --yes --dry-run`, so
  each assertion failed for want of output that was never produced. CI checks
  out a primary clone and never saw it, while agents work in worktrees by
  default. The suite now exports `DOTFILES_ALLOW_LINKED_WORKTREE=1` against
  its throwaway `$HOME`; the refusal itself stays covered by
  `setup-worktree-guard.test.sh`.

## 2026-09-17 — fix(check-claude): heal retired links per destination (#400)

- `check-claude.sh` zeroed a single global `HEAL` whenever `~/.claude` **or**
  `~/.claude/skills` was a symlink, which also skipped the unrelated top-level
  `~/.claude/FABLE.md` retirement. With a symlinked skills root and a real
  `~/.claude`, the later orphan scan then reported `FABLE.md` as an error and
  the launcher's `--heal` startup check failed on every run.
- The two retirement calls now recompute the decision per destination, so a
  symlinked root gates only the links beneath it. The audit-wide gate still
  applies to every enumerated link. Covered by a new case in
  `claude/scripts/tests/retired-skill-links.test.py`.

## 2026-09-16 — feat(agy): permission baseline and proceed-in-sandbox mode

- Antigravity asked for approval on nearly every command because its native
  `permissions.allow` list held only prompt-saved exact commands and the
  execution policy was the default `request-review`. `antigravity/permissions.json`
  now ships a curated allow/ask/deny baseline (read-only inspection, git reads
  and safe writes, bun/tsc/test runners, gh reads with matching `unsandboxed`
  rules) plus `toolPermission: proceed-in-sandbox` and `enableTerminalSandbox`.
- `setup.sh` merges the baseline into the machine-local settings file through
  `claude/scripts/agy-apply-permissions.py` (apply keeps local grants; prune
  resets them after a backup); `check-antigravity.sh` warns on drift. This
  replaces what the reverted classifier (#411) tried to do with a parser.
- Follow-up the same day: reads under `~/.claude`, `~/.gemini`, `~/.codex`
  and `~/dev` still prompted as non-workspace access, and commands the sandbox
  could not serve prompted for an unsandboxed run. The baseline now sets
  `allowNonWorkspaceAccess`, ships `read_file(~/…)` rules that the merge script
  expands to the machine's home, and mirrors every read-only command as
  `unsandboxed(...)`; code runners stay sandbox-only. `write_file(~/dev)` lets
  edits inside the dev tree proceed in the default mode (edits prompt unless a
  `write_file` rule covers the path).
- Antigravity review of the follow-up found two P0s: unsandboxed `cat` could
  read `~/.ssh` where the file-tool deny rules do not apply, and unsandboxed
  `echo`/`sed` could write anywhere by redirection. Text writers lost their
  unsandboxed mirrors, and command-level deny regexes now bind every run
  (sandboxed or not): secret paths and files, redirection into home dotfiles
  or system paths, and in-place `sed`/`perl` through a read-only prefix.
- Second review round: `awk`, `sed`, `fd`, `yq` and `jq` also lost their
  unsandboxed mirrors (they can execute or write), the recursive-rm deny now
  covers `/*`, `~/*` and any flag order, `sed --in-place` and `rg --pre` and
  `git -c` are denied. Only tools that can neither run code nor write leave the
  sandbox without a prompt.
- Third round settled the model: the terminal sandbox is the boundary. No
  local tool carries an `unsandboxed` rule any more; only read-only network
  commands (`git fetch`, `git pull --ff-only`, `gh` reads) may leave the
  sandbox. Reads outside the workspace are served inside it via
  `allowNonWorkspaceAccess` and the `read_file(~/…)` rules. The deny regexes
  stay as defense in depth (newline-safe, repeated-slash and traversal aware,
  absolute home paths covered) but are documented as not being a boundary.
- Fourth round (P1/P2 only): directory file rules end with `/` so prefix
  matching cannot leak into siblings; `+refspec` force pushes, `rm` with a safe
  path before the protected one, single-level `../` redirects, `git` global
  options before `-c`, and mixed-case secret paths are covered.
- Fifth round: the `unsandboxed(git fetch)` prefix admitted `--upload-pack=<cmd>`
  outside the sandbox (P0). Exec-capable flags on network git subcommands are
  denied and env-prefixed git commands (`GIT_SSH_COMMAND=…`) ask. `rm` with the
  path before its flags, `tee` with any flag, multi-level `.env.*`, and
  hardware-backed key names are covered.
- Sixth round: sandboxed `git config` could plant `core.sshCommand` for an
  unsandboxed fetch to run (P0), so git no longer leaves the sandbox at all
  (`git fetch`/`pull` prompt; only `gh` reads are unsandboxed) and config
  writes ask. Reads of `~/.config` are no longer allowed wholesale and the
  credential files under `~/.config/gh`, `~/.claude`, `~/.gemini`, `~/.codex`
  and `~/.git-credentials` are denied by path and by name (P0). `/./`,
  `${HOME}`, `--recursive`, combined `-uf`, and git global options before
  the subcommand are covered.
- Seventh round settled it: the command regex layer is removed. Every round
  produced new bypasses because shell syntax cannot be classified airtight,
  which is the lesson of #411. What remains is what agy enforces exactly:
  `read_file` denies for credential paths (the file tool matches paths, not
  text) and plain prefix denies as speed bumps inside the sandbox. `git clone`,
  `git -C` and `git -c` ask; a `git config` ask was dropped again because it
  shadowed the read-only `git config --get` allow (deny > ask > allow).
- The deny on `~/.gemini/antigravity-cli/` blocked agy's own `brain/` and
  `scratch/`; it is narrowed to `settings.json`. Bare `rm -rf /` and `rm -rf ~`
  prefixes are dropped (over-match risk); the `/*`, `~/*` and `$HOME` forms stay.
- `gh auth status` moved to ask (`--show-token` prints the token); the home
  expansion tolerates `HOME=/`.
- Codex review of the merged branch found the upgrade path left the bypass
  open (high): withdrawing a grant from the baseline does not withdraw it from
  a machine that already installed it, because `setup.sh` runs the additive
  `apply` and `check` counted the leftover as ordinary local drift. An existing
  install therefore kept `unsandboxed(git fetch)` and its
  `--upload-pack=<command>` execution path after an ordinary upgrade.
  `antigravity/permissions.json` now carries a `retired` array naming the
  withdrawn grants; `apply` deletes each exact match from the live file and
  prints one line per removal, `check` fails while any remain, and `prune`
  keeps its meaning. Loading the baseline rejects a rule listed as both current
  and retired. Retired are the three `unsandboxed` grants (`git fetch`,
  `git pull --ff-only`, `gh auth status`), `command(gh auth status)`, and the
  two `command(regex:…)` test-runner allows. Withdrawn *denies* are
  deliberately not listed: removing one would take away protection the operator
  currently has, so the two stale deny regexes stay as harmless residue.
- Second Codex round caught the same principle broken one level down (medium):
  the retirement filter ran over every bucket, so an operator who had added
  `unsandboxed(git fetch)` to their own `deny` would have had it deleted,
  turning a forbidden operation into an approvable one, and the new test
  required that removal. Retirement is now scoped to `allow` alone, the guard
  rejects a rule that is both a current grant and retired, and a test asserts
  that a retired rule kept as an operator's deny survives `apply` and passes
  `check`.

## 2026-09-16 — revert: remove the Antigravity permission classifier (#411)

- Reverted 70dfa97. The classifier merged while its required `checks` job was
  still running and that job has failed on `main` ever since (five cases fall
  to `force_ask` on the CI runner while passing locally, #415). In use it also
  did not reduce prompting: anything state-changing, network, or unfamiliar
  still asks. It returns only if it can prove a lower prompt rate and passes
  CI without environment-specific probes; the three reproduced bypasses from
  the 2026-09-15 pre-push review would need fixing first.

## 2026-09-15 — fix: setup.sh refuses linked worktrees; sync-memory names refused paths

- `setup.sh` was run from a throwaway `/tmp` review worktree, which linked two
  `~/.claude/scripts` entries at that worktree; they dangled once it was
  removed and `check-claude` blocked every launch. Setup now refuses to
  publish links from a linked git worktree (`--check` stays usable;
  `DOTFILES_ALLOW_LINKED_WORKTREE=1` overrides), with a CI test.
- `sync-memory` aborted on a memory file named `*google_oauth_published*` with
  no hint which file; the path filter treats `oauth` as auth-like by design.
  The abort now names the refused file and the fix (rename it).

## 2026-09-15 — fix: keep large Antigravity reviews linear and reject partial output

- The Antigravity gate checks for an empty diff in linear time; the quadratic
  shell substitution that #406 removed from the Codex gate had been left here
  and stalled multi-megabyte diffs for over thirty minutes.
- agy's print timeout is pinned to the gate ceiling and an expired timeout can
  never pass as a verdict. agy stderr stays out of the verdict file so model
  output cannot imitate the expiry note and a benign diagnostic cannot defeat a
  clean final-line verdict.

## 2026-09-15 — fix: preserve complete large review requests

- Large Codex reviews use contiguous input parts in one read-only session with
  supported context capacity. Missing input, compaction, changed permissions,
  and incomplete responses cannot authorize publication.
- Both review gates and receipt validation protect the new transport helper
  against self-review. Diff preparation checks whitespace without quadratic
  shell substitution.

## 2026-09-10 — feat: add Antigravity permission classifier

### What changed
- Added PreToolUse permission classifier for Antigravity (`agy-permission-classifier.py`)
  to safely auto-approve benign read-only and dev commands while prompting on state
  changes or blocking hazardous operations, mirroring Claude Code auto mode.
- Wired the classifier in `antigravity/hooks.json` and added unit test coverage in
  `claude/scripts/tests/agy-permission-classifier.test.py` and CI.

## 2026-09-10 — fix: preserve late writes and verify shipped artifacts

### What changed
- Worktree retirement keeps the actual directory in locked recovery quarantine,
  preserving late ignored files and writes through open descriptors. Interrupted
  moves retain Git metadata and recovery paths; retirement no longer deletes
  worktree contents or reclaims disk space. Explicit Git working-directory
  overrides require separate handling, and repaired locations are verified.
- Normal Claude healing removes the exact retired FABLE document link while
  preserving custom replacements, restored sources, and symlinked ancestors.
- Review-and-push refuses uncommitted input before tests and at later shipping
  checkpoints. Antigravity requires independent review of its own instruction
  surfaces and shared review machinery. Both gates protect installed shared
  skill bundles, output schemas, and ancestor entries that can redirect their
  inputs, including uncommitted changes outside the review target.
- The Codex gate recognizes both managed standalone launcher layouts before
  falling back to the executable on PATH.

## 2026-09-09 — fix: close launcher, cleanup, and review safety gaps

### What changed
- Codex review results must satisfy the full structured-result contract before
  rendering, issue creation, or approval receipts. Malformed objects, field
  values, and multiple JSON documents fail closed; valid clean and low-only
  responses remain supported.
- Corrected local ShellCheck coverage instructions, the Antigravity health
  command, the pre-merge hook table, branch-protection status, and scanner
  descriptions. Backfilled omitted historical changes from their merged PRs.
- Branch pruning stops on failed remote refresh, unknown activity, unique merge
  commits, or a dirty checkout. Preview fetches happen in a disposable clone;
  effective transport settings, relative roots, and changed remote defaults are
  preserved. Hidden untracked files and dirty submodules still block cleanup.
- Bash and zsh launchers reload changed contents, including changes pulled during
  preflight. Git diagnostics distinguish deleted upstreams from excluded refs
  and report detached checkouts and dangling stub links. `cct` passes arguments
  without writing their expanded contents into interactive history and keeps
  the project directory when the agent exits.
- Setup audits the tmux link, and tmux tolerates unavailable passthrough options.
  Launch health checks can retire exact known obsolete skill symlinks while
  preserving custom files, restored sources, and ambiguous links.
- Recovery recognizes standalone releases under the selected daemon-state home
  or the default installation, checks ownership and executable identity, and
  retains the existing process and socket safeguards.
- Comment harvesting retries only confirmed label-validation failures; queue
  freshness rejects impossible dates. Review instructions preserve the user's
  checkout, debugging applies to faulty behavior, and Render stays project opt-in.

- Retired-link migration captures entries before deletion and preserves concurrent
  replacements, with recovery diagnostics when restoration cannot be automatic.
- Review receipts bind unchanged in-repository canonical instruction links and
  their targets; unsupported or changed instruction aliases still fail closed.
- Shared capability and workflow contracts detect missing providers and safety
  instructions across runtimes, with passive installed-state reporting.
- Delivery and handoff record worktree ownership and disposition. A targeted,
  opt-in collector verifies merged artifacts, preserves hidden work and reflog
  history, and archives review evidence before removal; the timer only reports
  worktree inventory separately from repository-settings drift.
- Retirement compares raw filesystem contents with committed blobs, retains
  special files and empty directories that Git status omits, and refuses active
  content filters without running them. Native portability fixtures use physical
  temporary paths and portable timestamp setup.
- Retirement also checks process file descriptors and mappings, so background
  workers using files from another working directory keep their worktrees.

### Decisions made
- Retired-skill healing is an exact historical migration; unknown or custom
  content remains report-only. No general automatic deletion is introduced.

## 2026-09-09 — fix: retire the FABLE layer and streamline reviews

- Removed FABLE's instruction file, generated imports, and AgentPack entry.
  Shared guidance honors applicable standing authorizations without requiring
  repeated approval for the same work. Existing scope and evidence rules remain.
- Ordinary shipping uses the committed review gate as the final fresh-context
  review. High-risk changes retain separate-family review, and runtime/browser
  verification is assigned by capability. Issue delivery uses the shared
  shipping skill and its receipt checks.
- The Codex review gate selects the managed standalone installation unless an
  explicit executable override is supplied and preserves private failure
  diagnostics. Receipts record the selected runtime.
- Review execution uses the native foreground CLI. Observed cancellation
  invalidates approval, including during receipt creation. Gate changes run
  offline portability fixtures on Linux and macOS.

## 2026-09-09 — fix: preserve shared Codex sessions during startup

- `cx` probes the control socket and reuses a listening server without running
  daemon management commands. This avoids live PID-record cleanup after clock
  drift and preserves terminals when mobile Remote Control is unavailable.
- Missing or uncertain socket connections fall back locally. Daemon startup
  and repair are now explicit maintenance actions: even a native start can
  erase a live PID record when the listener appears after the socket probe.
- Socket and launcher regression tests cover reuse, ambiguous socket failures,
  conservative fallback, and a server becoming ready during startup.
- An opt-in native test holds a turn against a local mock API and verifies
  that repeated launches preserve attached clients without resending input.

## 2026-09-09 — fix: attach cx terminals to the shared Remote Control daemon

> **Historical** — point-in-time record (2026-09-09). Do not act on this.
> Automatic daemon management was retired by the shared-session fix above.

- Interactive `cx` launches now connect with `--remote unix://` after the
  already-enabled daemon starts successfully. Fresh sessions, `resume`, `fork`,
  and `agents` share the app server visible through Remote Control.
- Explicit remote options, utility subcommands, and help/version requests keep
  their native routing. Startup failures retain local access without re-pairing.
- Remote opt-in and updater identity paths follow the active `CODEX_HOME`.
- Regression coverage exercises attachment, argument routing, bounded failure
  fallback, and isolation between Codex homes.

## 2026-09-08 — fix: bind workflow reviews to the code being shipped

- Review gates reject unresolved bases, dirty instruction surfaces outside the
  committed target, failed reviewer runs, and embedded blocking priorities.
  Executable SVG and minified JavaScript remain in review coverage.
  Outside Git repositories, advisory runs retain their warning behavior;
  required runs still fail without issuing review evidence.
  Application hooks remain ordinary code; uncommitted capture supports
  unrelated base history, file/directory replacements, ignored instruction
  files, and staged content followed by workspace edits. Instruction checks
  recognize Git-managed CRLF conversion for regular files and sparse checkout
  omissions; symlink targets retain exact comparison.
  Automatic CRLF comparison respects Git's per-file binary classification.
  Uncommitted text diffs keep embedded control characters within their original
  physical lines and quote filenames in their headers.
  Receipt capture disables configured filesystem
  monitors and preserves the selected docs-only size policy through completion
  and validation.
  Classification and exemption validation share one policy. Instruction files,
  executable files, and symlinks cannot bypass review through passive filename
  filters or documentation exemptions, including staged executable modes when
  `core.filemode` is disabled. Inherited Git pathspec settings cannot
  change review selection, and exact path handling preserves repository identity.
  Source skill bundles, canonical fragments, Claude agent definitions, and
  AgentPack policy files retain instruction coverage, including ignored references.
  No-diff exemptions validate changed paths as well as the patch. Known runtime
  credentials and state stay out of review prompts when ignored, and block
  review when explicitly included. Repository instruction symlinks and staged submodules fail
  closed instead of leaving their effective content outside the snapshot.
- Private review receipts bind completed results to the base, commit, tree,
  diff, index, and workspace state. Changed artifacts and superseded attempts
  invalidate approval; wall-clock adjustments do not. The push hook checks
  each outgoing commit independently of secret-scanner availability; receipt
  helpers are installed beside gates.
  Annotated tags validate the commit they reference; local replacement refs
  cannot alter validation or secret scanning.
- The morning review script explicitly selects committed review scope even
  when the fetch upstream is current and unrelated work is dirty. It pins the
  commit before tests, uses the required Codex gate, requires that reviewer's
  receipt for the same commit after confirmation,
  and pushes the reviewed commit to a verified non-default
  branch at the actual push destination. Automatic tag pushes are disabled.
  Further URL rewrites and remote-name indirection fail closed; explicitly
  selected PR review bases can be carried through the push hook with a
  one-push setting.
  Multiline push destinations are rejected before shell output handling can
  change their meaning.
  Empty or multiple configured destination URLs are rejected even when Git
  normalizes them to a single effective URL.
  Protocol v2 destination checks reject advertised symbolic branch aliases.
  Unadvertised destinations require an empty expected object ID at push time
  instead of risking an overwrite through a hidden alias.
  Push-remote selection follows Git's configured precedence, and a current
  fetch upstream does not suppress delivery to a behind push fork.
- Shared instructions assign coordination to the active session, preserve
  separate-family review for high-risk work, and require simplification,
  documentation, and verification before final review. Personal runtime
  preferences remain private.
- The branch-protection example includes behavioral tests in required checks.
  Antigravity diagnostic commands bypass unrelated workspace preflight.

## 2026-09-08 — fix: launchers reload a changed `.bash_aliases`; dev-dir stub `.git` and off-main dotfiles guards

### What changed
- `cc`, `cx` and `agy` re-source `~/.bash_aliases` when its mtime differs from
  the one recorded at shell start, then re-enter themselves so the fresh
  definitions run. Long-lived shells (WSL6 panes open for days) kept the
  fail-closed "resolve the pull error before launching the agent" body for two
  days after #363 replaced it on disk.
- `_agent_preflight` removes an empty stub `.git` from the dev dir (seen
  2026-07-17 and 2026-09-06; it makes Claude Code treat `~/dev` as a repo with
  no HEAD). A non-empty non-repo `.git` is reported, never deleted.
- After the repo sync, the preflight warns when the primary dotfiles checkout
  is on a branch other than `main`/`master`: `~/.bash_aliases`, hooks and
  skills symlink into that checkout, so the checked-out branch *is* the live
  shell config. Feature work belongs in a worktree.
- Regression coverage for all three in `agent-preflight.test.sh` (46 cases).

### Decisions made
- Reload rather than warn: the launcher is the one place every shell passes
  through, so it heals itself instead of asking the operator to `exec bash`.
- The primary dotfiles checkout stays on `main`; branch work uses `wt-claude`
  or `git worktree add`.

## 2026-09-06 — fix: agent launchers continue after sync failures

- `cc`, `cx`, and `agy` warn with repository errors and continue with local
  files when sync fails. Claude memory publication failures also warn and
  continue; required configuration health checks still block startup.
- Linked worktrees fetch without changing their branches or files. Ordinary
  checkouts keep fast-forward pulls; unresolved Git layouts are reported and
  skipped. Standalone sync commands still return failures to their callers.
- Regression coverage exercises real Git worktrees, checkout classification,
  failed syncs, and launcher runtime reachability with passing or failing health.

## 2026-09-06 — feat: harvested Codex findings carry `codex-finding` so the janitor can expire them

### What changed
- `claude/scripts/harvest-codex-comments.sh` files each Codex-bot review comment
  with the `codex-finding` label (retrying unlabeled on a 422 so a repo without
  the label still gets the issue). The label exists in every owned repo.
- Pairs with jw-routines: the nightly docs steward now keeps one rolling
  `Docs needing review — consolidated tracker` per repo instead of a dated issue
  per night, the weekly repo janitor re-verifies every `codex-finding` against
  the default branch and closes fixed/obsolete ones with evidence, and the
  Monday fleet digest reports backlog pressure per repo.

### Decisions made
- Findings expire by evidence, not by age: a bot never closes a human-filed
  issue, and a codex finding is only closed with a sha or current file:line
  showing the concern is gone.
- Fleet-wide triage on 2026-09-06 took open issues from 317 to 233; the 84
  closed were bot-filed duplicates or already-fixed findings.

## 2026-09-05 — feat: shared `claude-operator` skill drives Claude Code from Codex

### What changed
- New agent-only skill `agents/skills/claude-operator/` (SKILL.md, two
  references, `agents/openai.yaml`, and `scripts/claude_run.py`). An operator
  agent briefs Claude from a prompt file, runs one native print-mode turn,
  gets streamed events plus the exact session ID in a fresh run directory,
  resumes that exact session for follow-ups, and stops only the process
  group it owns. Exit codes separate a completed turn (0), a failure (1), and
  a turn that ended on permission denials (2). Installed by the existing
  `setup.sh` shared-skill links; nothing new to run.
- Runner behavior, hardened through Codex and Antigravity review rounds
  before merge. Launch: interactive Bash loads startup files with stdout on
  `stderr.log` and stdin on `/dev/null`, then attaches the prompt, `cd`s,
  and execs Claude, so banners cannot pollute `events.jsonl`, a startup
  `read` cannot eat the prompt, and a `cd` cannot move Claude; the
  executable is `~/.local/bin/claude` or `--claude-bin`, never a `PATH`
  lookup (on WSL that is the Windows npm shim); option-shaped
  `--allow-tool`/`--tools`/`--model` values are rejected before launch;
  the runner refuses to nest inside a Claude Code session. Evidence: the
  prompt is validated as UTF-8 and sent byte-exact; a dangling symlink at
  the output path is rejected before it can be created through; a success
  result with a missing or different session ID is `session_mismatch`; a
  rejected CLI flag is named rather than retried with weaker settings;
  usage errors exit 64, including NaN/infinite/non-positive `--timeout`.
  Input reads are bounded: the prompt is read only up to its limit before
  rejection, and the stderr diagnostic scan reads only its prefix, so a
  wrongly chosen huge file cannot exhaust memory. Completion: a turn ends when Claude itself exits
  (peeked without reaping), not when the events pipe closes or goes quiet,
  with the drain bounded to the bytes queued at that moment, so an
  inherited or chatty descendant can neither hang the turn nor turn it into
  a timeout; a nonzero exit is `failed` (raw code in `claude_exit_code`)
  even with denials present; `needs_permission` is a completed exit-0 turn
  with denials. Ownership (Linux/WSL only, via `/proc`): the exited Claude
  process stays unreaped until the last stop signal so its zombie pins the
  group id; teardown is SIGTERM, a grace period, then SIGKILL for the whole
  group, runs on every path including normal completion, records
  `stop_errors`/`stop_survivors` instead of aborting the final `run.json`,
  turns a completed turn (success or denials) with survivors into `failed`
  so nothing resumes over a live run, ignores repeated signals
  once entered, retries if a signal lands before it can enter, and defers
  a signal that arrives between `Popen` and the group being recorded. The
  boundary is the owned Linux session: job-control groups created by a
  startup `set -m; job &` are signalled through pidfds with membership
  re-verified (Python 3.9+, kernel 5.3+); a `setsid` daemon is outside it.
  The prompt and events descriptors are attached only on the final exec, so
  a startup-defined `cd` function or DEBUG trap cannot read the prompt or
  write into the events; and both JSON surfaces are ASCII-escaped so an
  escaped lone surrogate in Claude's stream round-trips instead of raising.
- Offline mock suite `claude/scripts/tests/claude-operator-runner.test.py`
  (stdlib Python, stub `claude`, throwaway HOME with a crafted `~/.bashrc`,
  from-scratch child env) wired into the CI `checks` job; cases cover
  success, failure, denial, exact resume, missing or mismatched session ID, literal prompt,
  cwd restoration, dry-run, existing-output and dangling-link preservation,
  native-only executable selection, bypass-flag rejection, SIGINT and
  timeout cleanup, leader-exited group cleanup with a bystander check,
  launch- and teardown-boundary signal injection, inherited-pipe and
  continuously-writing descendants, denial-with-nonzero-exit precedence,
  and in-process syscall observation of group signalling and teardown
  failure.
- Docs: `agents/skill-coverage.tsv` row (agent-only, rationale),
  `codex/README.md` section, `docs/WINDOWS.md` section on the separate
  Windows Codex config root and installing the skill there.

### Decisions made
- Opt-in only: the public skill never makes Claude the default implementer;
  that preference stays in the private memory layer.
- The wrapper is documented as not an isolation boundary and exposes no
  `bypassPermissions`, `--dangerously-skip-permissions`, or `--bare`.

### Known issues
- The Windows-side copy is a manual `Copy-Item`; it does not refresh with
  `dotfiles-update`.

## 2026-09-04 — fix: recover errored Codex Remote Control during startup

> **Historical** — point-in-time record (2026-09-04). Do not act on this.
> Automatic startup stops and restarts were retired by the shared-session fix above.

### What changed
- `cx` attempts one timed managed-daemon restart for an errored Remote Control
  connection and requires `status: connected` in its startup result before
  reporting recovery. A successful exit while still connecting remains a
  visible readiness warning.
- On Linux with peer process handles, startup can restore missing daemon PID
  records after clock drift. Repair requires the previously saved updater's
  exact kernel identity and the verified control-socket owner, holds Codex's
  native locks, and leaves conflicting records or unverified processes alone.
  The control socket follows the selected daemon state, keeping custom
  `CODEX_HOME` records separate from the default home. Normal Codex commands
  perform the restart after repair; restarting the shared daemon may interrupt
  terminals already attached to it.
- Restart failures, timeouts, and persistent connection errors still allow
  local Codex to launch. Upstream output remains hidden to protect pairing
  secrets, and hosts without Remote Control opt-in remain untouched.
- Regression coverage exercises clock drift, launcher upgrades, reused PIDs,
  ownership checks, native locks, failed restarts, and unsuccessful reconnection.

## 2026-09-04 — feat: opt-in tmux persistence via `cct`

### What changed
- `.tmux.conf` is back in the repo and symlinked by `setup.sh` section 7. It
  restores the 2026-03 config and adds the two settings Claude Code documents
  for tmux (`extended-keys on`, `allow-passthrough on`) so Shift+Enter
  multi-line prompts work, plus `focus-events` and truecolor overrides.
- `setup.sh` section 1 installs `tmux` alongside gh/git/curl/jq.
- New `cct [project] [cc args…]` in `.bash_aliases`: runs `cc` inside a tmux
  session named after the project (or the current dir), attaches to an
  existing session of that name instead of recreating it, refuses to nest
  inside tmux, and types the command into the pane's login shell so `cc`'s
  preflight runs unchanged. Detach with `Ctrl-b d`. Session names drop the
  `.`/`:` tmux forbids, so each session records its dir in `CCT_DIR` and a
  same-named session for a different dir gets a `-2` suffix rather than
  being attached by mistake (Codex refutation finding on #350).
- Docs: CLAUDE-GUIDE (session start + shell commands), README (tools table,
  commands table), docs/WINDOWS.md (persistence note for the wsl6/cc* panes).

### Decisions made
- Reverses 2026-03-16 ("remote control replaces tmux"). That entry's premise
  was wrong: per the Remote Control docs, a session goes offline within
  seconds of the local `claude` process exiting, and tmux/screen is the
  documented way to keep it alive through a closed terminal. tmux and Remote
  Control are complementary.
- Opt-in only. `cc`, `wsl6`, and the `cc*` pane launchers stay tmux-free; the
  key-handling and mouse-select friction is confined to sessions the user
  chose to make persistent.

### Known issues
- Windows Terminal's extended-key support inside tmux is untested from this
  side; if Shift+Enter still sends a plain Enter, use Alt+Enter or `\` +
  Enter until it's verified.
- `cc`'s OSC 9;9 tab-colour escape does not pass through tmux; coloured tabs
  only work for non-tmux launches.

## 2026-09-02 — fix: prune confirms merges against the default branch; dry-run is read-only; ntfy sends counts only

### What changed
- `git-hygiene.sh`: the GitHub merged-PR check (prune `--gh`, and clean's
  check (c)) now queries `gh pr list … --base <default>`. A branch whose PR
  merged into a release or feature branch that never reached the default was
  previously deleted as "merged"; it is now kept, and the deletion reason
  names the base ("PR #N merged into main …").
- `--dry-run` no longer writes anything: no `git remote set-head` (a missing
  origin/HEAD is resolved read-only via `git ls-remote --symref`) and no
  `git fetch --prune`. It still runs a plain `git fetch origin` (updates refs,
  deletes none) and learns which refs a real run would drop from
  `git fetch --prune --dry-run`, treating those upstreams as gone — so the
  preview matches the real run without touching remote-tracking state.
- `hygiene-cron.sh`: the ntfy summary is now counts only ("git-hygiene pruned
  N branch(es) across M repo(s); details and recovery SHAs in
  ~/.local/state/hygiene/cron.log"). Repo and branch names, SHAs, and `$HOME`
  stay in the local log — ntfy topics are readable by anyone who guesses
  them. `NTFY_SERVER` (default `https://ntfy.sh`) was already honoured and is
  now tested.
- `git-hygiene-prune.test.sh`: 52 → 64 assertions; the `gh` shim filters by
  `--base` and a `squash-pr-release` fixture branch pins the base check.

## 2026-09-02 — feat: operator-queue items carry a `verified:` date; the reminder flags stale ones

### What changed
- The operator-action queue format (handoff skill, claude + agents) gains an
  optional `- verified: YYYY-MM-DD` line with the rule: when a session touches
  an item's subject, re-check it against live state and set/bump `verified`;
  remove the block only when done. Eight of 26 items were stale or wrong this
  morning because nothing recorded when an item was last checked.
- `OperatorQueueReminder.hook.sh` computes each item's freshness as the newest
  of `verified`/`added` (leading date prefix, so annotated dates still parse),
  marks anything older than 30 days — or undated — `[stale — re-verify]`,
  shows `verified Nd ago`, and counts stale items in the header. Deadline-first
  ordering and past-due flags are unchanged; still one awk pass, still bounded.
- Fixture suite `operator-queue-reminder.test.sh`; wired into CI.

## 2026-09-02 — feat: the daily git-hygiene timer prunes safely-dead local branches

### What changed
- `git-hygiene.sh prune` — a strict, unattended-safe mode: deletes a local
  branch only when it is not the default, checked-out, or worktree branch, was
  not touched in the last 24 h (`HYGIENE_MIN_AGE_HOURS`), and either has no
  unique commits vs `origin/<default>` or, with `--gh`, GitHub confirms a
  merged PR whose head ref is the branch and whose head SHA is the local tip
  (or a locally-fetched descendant). Squash-merged branches without that
  confirmation are kept; any `gh` failure keeps the branch. `--dry-run` for
  both `clean` and `prune`; colors only on a terminal.
- `hygiene-cron.sh` runs `prune ~/dev --yes --gh` every day in place of the
  Sunday `clean --yes` (whose subject-match heuristic is not in the safe
  class). Each deletion is logged with its full SHA and a recovery command to
  `cron.log`, appended to `deletions.tsv`, and summarised via ntfy only when
  ≥1 branch was deleted (topic falls back to the settings.json env block).
  `HYGIENE_DELETE=0` disables the prune, `HYGIENE_GH_CHECK=0` the GitHub step.
- Fixture suite `git-hygiene-prune.test.sh` (origin + clone, gh/curl shims)
  pins which branches survive; wired into CI.

## 2026-09-02 — chore: make superpowers skills opt-in

### What changed
- CLAUDE.md now overrides the superpowers plugin's session-start mandate to
  invoke a skill before any response. Its skills stay available and still
  trigger on real build/debug work, but no longer gate plain questions
  (six invocations across 41 sessions did not justify the ceremony).

## 2026-09-02 — chore: retire the FABLE.md import for Claude Code; keep it as the Codex/Antigravity contract

### What changed
- `claude/CLAUDE.md` no longer imports `FABLE.md`. Claude Code's harness
  system prompt now carries the same conduct rules natively, so the import was
  a second copy that could only drift. The one rule the harness lacks (code
  comments are constraints, not commentary) moved into CLAUDE.md directly.
- `FABLE.md` stays, reframed as the teammate contract for Codex and
  Antigravity, which still load it from their instruction files.
- Removed the `fable-mode` skill (never invoked in 41 sessions) from Claude,
  Codex, and Antigravity bundles, the AgentPack, README, and CLAUDE-GUIDE.

## 2026-09-02 — fix: pull-all no longer blocks launches on a deleted upstream branch

### What changed
- `pull-all` pulls with `--prune` and treats "no such ref was fetched" as a
  skip with an explanatory line, so a checkout whose branch was deleted on
  origin (delete-on-merge) no longer fails `cc`/`cx`/`agy` until the daily
  git-hygiene timer happened to prune it.
- Regression coverage in `agent-preflight.test.sh` for the deleted-upstream
  case, including that the pull is invoked with `--prune`.

## 2026-08-28 — chore: declare the Render plugin

- [#326](https://github.com/jckeen/dotfiles/pull/326) added Render to the
  manifest's per-project section. The section was descriptive; installer
  scope is addressed separately by [#327](https://github.com/jckeen/dotfiles/issues/327).

## 2026-08-10 — docs: correct hook source paths

- [#317](https://github.com/jckeen/dotfiles/pull/317) corrected repository-relative
  paths in the README's files and symlinks table.

## 2026-07-30 — fix: review, installation, launcher, and checker boundaries

### What changed
- [#299](https://github.com/jckeen/dotfiles/pull/299) bounded review-packet size
  arguments and escaped terminal controls when reporting fixture failures.
- [#300](https://github.com/jckeen/dotfiles/pull/300) refused symlinked Codex
  runtime roots and skill-bundle directory links, checked gitleaks Git-mode
  support, and placed npm's global executables on the configured local PATH.
- [#301](https://github.com/jckeen/dotfiles/pull/301) corrected image-option
  resume parsing, bypassed launch preflight for Antigravity utility commands,
  and surfaced the actual Git error after failed pulls.
- [#302](https://github.com/jckeen/dotfiles/pull/302) inspected symlinked deployed
  roots, reported legacy PAI links, and included review schemas in session-start
  symlink repair.
- [#303](https://github.com/jckeen/dotfiles/pull/303) corrected the then-current
  PR-review, delegation, optional-team, and Antigravity migration instructions.

## 2026-07-29 — docs: correct skill and agent source paths

- [#298](https://github.com/jckeen/dotfiles/pull/298) corrected the README's
  repository-relative paths for Claude skill and agent sources.

## 2026-07-20 — fix: self-heal Codex skill links before launch

### What changed
- `cx` now enables the existing missing-only symlink healer before its strict
  Codex health check, so newly pulled files inside shared skill bundles are
  linked before the agent starts.
- The Codex checker refuses to heal through a symlinked managed directory and
  retains strict failure behavior for ambiguous or unsafe drift.
- Added regression coverage for launcher arguments, nested skill-file healing,
  and the managed-directory boundary.

### Decisions made
- Reuse the shared checker healing contract: only an absent destination with a
  present source can be created automatically. Existing files, wrong targets,
  broken links, and unsafe directory layouts remain report-only failures.

### Known issues
- None.

## 2026-07-18 — feat: learn from verified orchestration

### What changed
- Shared orchestration now routes evidence-backed workflow lessons through the
  existing `session-retro` proposal and confirmation boundary after the
  user-facing result is verified.
- Added a bundled review-packet builder that gives fresh-context reviewers a
  bounded staged diff, path scope, falsifiable claim, exact repro, and
  verification commands without including unstaged or untracked files or author
  reasoning.
  The complete packet is size-bounded, author-controlled content sits behind a
  hash-derived untrusted-data boundary, output uses the exact measured UTF-8
  bytes, and empty path scopes fail closed. An isolated copy of the Git index
  plus a config-free temporary Git directory, object store, and worktree avoids
  repository-index mutation, clean-filter execution, worktree normalization,
  symlink traversal, fsmonitor execution, replacement refs, and
  repository-controlled diff behavior. The copied index is snapshotted to a
  tree, then compared with an empty index so staged attributes remain visible
  evidence without becoming rendering policy. Split-index companions are
  selected from the copied index's `link` extension without asking Git to read
  and refresh source metadata. Repository and caller-index paths retain their
  exact filesystem bytes and whitespace; relative caller indexes remain rooted
  at the launch directory. Selected paths, including whitespace-only filenames,
  use an unambiguous JSON array. Non-UTF-8 patches and patches containing
  terminal controls are preserved byte-for-byte as inert base64, conflicted
  indexes fail before emitting incomplete evidence, and every captured Git
  stream is drained concurrently with a bound.
- Added CI coverage for scope traversal and pathspec expansion, binary evidence,
  empty and oversized diffs, configured Git converters and clean filters,
  staged-versus-unstaged state, ordinary, linked-worktree, version-2,
  version-4, SHA-256, and discovery-rotated split indexes, source companion
  content and mtime immutability, caller-selected index immutability and
  relative-path resolution, quoted and literal-quote relative object
  alternates, executable modes, large diagnostics, symlinked worktree paths,
  staged attribute-policy changes, whitespace-bearing repository, index, and
  scope paths, newline-bearing scope paths, non-UTF-8 repository paths and
  filenames, unmerged index stages, older Git
  compatibility, routing-environment isolation, blocking unstaged attributes,
  fsmonitor hooks, local and environment-injected submodule config,
  source-repository object formats, replacement refs, non-UTF-8 and
  terminal-control bytes, bounded helper and diff diagnostics, terminal-safe
  parser errors, fail-fast fixture
  setup, and Markdown-shaped source or command content.

### Decisions made
- Reuse `session-retro` instead of creating an autonomous learning ledger or a
  second proposal format. Changelog, handoff, and GitHub issues retain their
  existing ownership of history, continuity, and unresolved work.
- Fail closed when a review packet has no staged evidence, the copied index has
  any unmerged entries, or the packet exceeds its explicit whole-packet bound.
  Every intended change must be staged before packet generation; unstaged and
  untracked state remains excluded by design.
- Render a canonical, attribute-free Git patch: staged attribute files remain
  reviewable changes, but repository config and attributes cannot suppress,
  expand, transform, or execute content while the packet is built.

### Known issues
- The packet builder covers staged Git changes. Non-Git artifacts still need
  an equivalent raw claim, repro, scope, and evidence packet assembled manually.
- Staged submodule gitlinks are covered, but nested repository content still
  needs its own review packet.

## 2026-07-17 — fix: recover stale Codex Remote Control safely

### What changed
- `cx` now bounds Remote Control lifecycle commands, reports a safe diagnostic
  command without echoing upstream stderr, and recovers the known
  dead-app-server/orphan-updater state with one pidfd-backed,
  exact-kernel-identity-checked termination and one retry.
- Updated the public Codex profile example, generated-memory safety audit,
  long-running-work guidance, AgentPack compatibility metadata, and branch
  protection pointer to match their canonical current surfaces.
- `cx` applies strict config parsing to the real agent invocation after private
  defaults are merged; direct `codex` remains the management-command surface.
- Merge-review round: the bounded Remote Control pipeline now normalizes
  SIGKILL/SIGPIPE deaths past the deadline to the documented timeout status
  (fixes a WSL2-only test failure), a missing `jq` prints a warning instead of
  silently skipping Remote Control auto-start, and the recovery module's
  docstring records the safety argument behind the pidfd/fingerprint ordering.

### Decisions made
- Keep Remote Control optional for local work and never signal a process unless
  its boot ID and exact start ticks match the fingerprint recorded after an
  earlier successful launch, and its current owner, executable, and updater
  arguments still match the managed-process contract.
- Use native Goal mode, compaction, resume, Remote Control, and durable handoffs
  for long sessions. Do not impose an arbitrary wall-clock limit or mandatory
  lifecycle hooks.

### Known issues
- The upstream cause of the experimental updater surviving its app server is
  still unknown; the launcher handles the observed state without assuming all
  Remote Control failures share that cause.
- Device-side connectivity still requires verification from a paired client.

## 2026-07-12 — fix: make the three-runtime workstation fail closed

### What changed
- Added a managed `agy` launch path with the same project selection, repository
  sync, and health-check rhythm as `cc` and `cx`, plus a pinned clean-machine
  Antigravity installer and post-setup audit.
- Repository pull and runtime health failures now stop launches. Claude memory
  auto-sync is limited to project memory trees, preserves staged user work,
  scans staged and pending commits individually, propagates commit/push
  failures, and retries safe pending commits.
- Antigravity setup and health checks now refuse symlinked runtime roots,
  validate local MCP JSON, pin the seeded GitHub and Playwright MCP packages,
  honor a relocated private memory repo, and participate in `setup.sh --check`.
- Corrected the generated AgentPack metadata so non-Claude targets describe
  their current partial portability instead of claiming full support.

### Decisions made
- Treat plugin and hook parity as capability parity across runtime-specific
  providers, not as identical marketplace package names.
- Keep Claude's existing live settings behavior unchanged in this patch; its
  merge-preserving migration and relocation work are tracked in the private
  repository rather than hidden in the public bootstrap.

### Known issues
- AgentPack user-scope Codex/Antigravity transport, target variants, and
  compiler-derived fidelity remain tracked in AgentPack issues.
- Operator Commons now tracks compatibility ingestion, platform-aware setup
  comparison, target-fidelity recommendations, and portable private agent state.

## 2026-07-12 — feat: keep Codex permissions and workflows aligned

### What changed
- Codex's portable private defaults now persist the Auto permission posture,
  automatic approval review, and a scoped reviewer policy while preserving
  machine-local trust and integration settings.
- Shared skills are linked into Codex's documented user discovery scope, and
  the docs now distinguish Claude `/skill-name` commands from Codex `/skills`
  and `$skill-name` invocation.
- Added portable `decompose`, `drift-sweep`, `fable-mode`, and `session-retro`
  workflows plus a CI-enforced coverage contract for every Claude/shared skill.

### Decisions made
- Keep runtime-specific adapters where tool semantics differ, but require every
  workflow to have an explicit shared or runtime-specific disposition.
- Preserve compatibility links for older Codex clients while making the
  documented user skill location canonical.

## 2026-07-11 — feat: persist portable Codex defaults without syncing live config

### What changed
- `setup.sh` now runs an optional `codex-memory/bootstrap.sh` before reporting
  local Codex config state, while dry-run previews the call without executing
  it.
- `cx` reapplies the private bootstrap after repository sync, so newly pulled
  personal defaults take effect without copying or symlinking the live config.
- Focused regression coverage verifies the setup dry-run boundary and the
  bootstrap-before-launch order.

### Decisions made
- Keep `~/.codex/config.toml` machine-local because it contains project trust
  and integration state. The private companion repo owns only an explicit,
  portable defaults overlay that merges into that file.

## 2026-07-11 — feat: reconnect opted-in Codex Remote Control from `cx`

### What changed
- `cx` now idempotently starts or reconnects Codex Remote Control before the
  interactive CLI when the host's persisted Codex settings show that remote
  access was already enabled.
- Remote startup failures warn without blocking local Codex use. Hosts that
  never enabled Remote Control remain untouched.
- A focused shell regression test covers startup order, failure handling, and
  the opt-in boundary, and runs in CI.

### Decisions made
- Device pairing remains Codex-managed local state. `cx` reconnects a paired
  host but never creates pairing codes or opts a new host into remote access.

## 2026-07-10 — feat: add portable Codex orchestration

### What changed
- Added the shared `orchestrate` skill for Codex and Antigravity: proportional
  planning, explicit acceptance criteria, isolated delegation, adversarial
  claim-and-repro review, integration verification, and durable handoff.
- Bundled runtime-specific dispatch guidance and Codex UI metadata with the
  skill. `setup.sh` now links complete nested skill bundles into
  `~/.codex/skills/` instead of only top-level files; its dry-run regression
  test asserts both nested metadata and references are included.
- Hardened recursive setup and audit behavior for nested bundles: file-to-dir
  transitions are backed up safely, missing nested links are reported with
  their relative path, and deeply orphaned managed links fail the audit.
- Fixed the Codex review gate's long-stderr reporting path so `pipefail` cannot
  terminate the gate with `141` before its configured degrade-or-block result.

### Decisions made
- Keep the orchestration contract agent-neutral and isolate runtime tool names
  in a reference file. Claude retains its richer native skill while Codex and
  Antigravity share the portable workflow.
- Treat same-model subagents as context-independent breadth, not an independent
  model lineage. Cross-lineage review requirements still need Claude, Codex,
  or verified Antigravity in the appropriate refuter lane.

## 2026-07-10 — fix: link scripts/*.json data files so gate schemas resolve through the symlink farm

### What changed
- **`lib-symlinks.sh` enumerates `scripts/*.json`** (plain, non-executable)
  alongside `scripts/*.sh`. Gate scripts resolve sibling files via plain
  `dirname` (no `readlink -f`), so `codex-review-schema.json` was invisible
  through `~/.claude/scripts/` and `codex-review-gate.sh` **degraded open** —
  the Codex refuter lane silently reviewed nothing. Found live while gating
  agent-pack PR #121.
- New `symlink-enumerate.test.sh` self-test (verified failing on the old
  enumerator) + CI entry; `check-claude.sh` now audits the schema link via the
  shared enumerator for free.

### Decisions made
- `scripts/README.md` and `scripts/tests/` stay unlinked — only runtime data
  files (`*.json`) ride beside the scripts.

## 2026-07-10 — fix: antigravity gate re-plumbed for agy 1.1.1 + PAI strict orphans + agentpack required-check job (#227, #232, #237)

### What changed
- **Antigravity gate stdin channel restored (#227, PR #243)** — agy 1.1.1
  intentionally stopped reading stdin when a prompt flag is present, so the
  gate's `--print ""` form failed every dispatch and degraded open. The gate
  now pipes the prompt with NO prompt flag (non-TTY stdin selects print mode) —
  verified live: PONG canary, model-label log propagation, and a full gate run
  over the fix's own diff. The self-test shim emulates 1.1.1 semantics across
  all Go-flag spellings (`--print=`, `-print`, `-p=`), so a regression to any
  prompt-flag form fails CI instead of silently no-opping the review lane.
- **Known PAI leftovers strict-fail (#232, PR #242)** — exact top-level names
  (`PAI`, `MEMORY`, `ISA.md`, `settings.plain.json`) report as PAI-LEFTOVER
  and fail `--strict`; arbitrary debris stays advisory UNKNOWN (PR #225's
  no-loose-attribution finding preserved). Follow-ups from its codex-bot
  review land here too: CLAUDE_DIR trailing-slash normalization (#247 — a
  trailing slash made the checker silently pass a dirty tree) and
  `.pai-mode.state` added to the leftover list (#248).
- **agentpack-generated is its own CI job (#237, PR #245)** — a step inside
  the shared `checks` job has no status context, so the queued operator PATCH
  would have required a context that never reports. The job now exists (with
  the #235 frontmatter self-test folded in by PR #244's resolution); the
  six-context PATCH in docs/BRANCH_PROTECTION.md is the remaining
  operator-only action.

### Decisions made
- agy prompt delivery: stdin-with-no-prompt-flag is the pinned secret-safe
  channel (undocumented upstream but changelog-acknowledged); canary +
  argv-spelling self-test are the load-bearing guards. Upstream feature
  request (stdin sentinel / --prompt-file, codex `exec [PROMPT | -]` prior
  art) queued for the operator.
- Every PR in this pass went through find → adversarial-refute → fix: the
  refuters produced one real P1 (PR #245 conflicting, context never reported),
  one real P2 (Go-flag spellings bypassing the #243 shim), and two P2 guard
  gaps folded into #244. Issue #246 (symlink blind spot) filed from review.

## 2026-07-10 — ci: shellcheck at warning severity + bot-P2 hardening + plugin migration applied (#202, #230, #231, #236)

### What changed
- **shellcheck raised to `--severity=warning` in CI (#202, PR #238)** — tree-wide
  pass: real fixes plus 14 per-line justified suppressions; adversarially
  reviewed (every quoting change proven a behavioral no-op). CI-vs-local drift
  bit twice: CI discovers `.bash_aliases` (no `.sh` extension) and runs a newer
  shellcheck than local 0.11.0 — replicate CI's discovery AND version locally.
- **Bot-P2 hardening (PR #239, closes #230 #231 #236)** — deployed-orphans
  checker hard-fails on a missing checker-lib; its self-test wired into CI;
  gen-agentpack.sh resolves the repo root from its own path (works through the
  `~/.claude/scripts/` symlink from any cwd). #229 closed as already-done;
  #232/#237 triaged (design decision / operator-only required-checks PATCH).
- **Plugin scoping migration APPLIED** (the settings half #214's entry deferred):
  claude-memory settings.json trimmed to 16 global plugins (commit 14dc1ea),
  per-project `.claude/settings.json` created in 7 target repos (uncommitted —
  each repo's own session commits). Operator-action queue seeded and live.

### Decisions made
- Merge-queue discipline under the permission classifier: single-purpose gh
  writes only (loops and read+write chains are denied); serial
  `update-branch` per merge against strict protection.

## 2026-07-10 — fix: frontmatter readers fail loudly on YAML forms they can't represent (#235)

### What changed
- **`gen-agentpack.sh` + `build-site.sh`** — the two hand-rolled frontmatter
  readers shared a silent-mangling bug class (found by the PR #233 adversarial
  review, extended by the adversarial pass on PR #244): a blank line inside a
  folded block scalar (`description: >-`) silently dropped everything after
  it; quoted scalars leaked their quotes and backslash escapes as literal
  content; literal block scalars (`|-`) had their semantic newlines
  space-joined; and the indented continuation of a multi-line plain scalar
  was silently dropped. Both readers now fail loudly (non-zero exit, message
  naming the file and key) on all four forms instead of emitting mangled
  output. Byte-identical for the current corpus, which uses none of them.
- **Tests** — new `gen-agentpack.test.sh` and `build-site.test.sh` fixture
  suites (folded-block happy paths, no-false-positive cases, and a loud-fail
  assertion per rejected form), wired into CI.

### Decisions made
- Loud-fail guards over a real YAML parse in both files: the issue's premise
  that PyYAML is already a CI dependency is false — `gen-agentpack.sh` is
  documented "python3 (stdlib only)" and ci.yml installs nothing, and
  `build-site.sh` is awk-only by contract and also runs on user machines via
  setup.sh symlinks. A PyYAML parse would add a new dependency or diverge by
  environment; the guards are deterministic and portable, and silence was the
  only unacceptable outcome.

## 2026-07-10 — feat: instruction canon — generate the three instruction files from one source (#216, #206, #219)

### What changed
- **ADR-0007** — investigated #216's thin-shim proposal empirically: only
  Claude Code resolves `@` imports; Codex CLI 0.141.0 (docs + live test) and
  Antigravity CLI 1.1.1 (live test, tools forbidden, out-of-workspace file)
  resolve none. Accepted the intent via **generation**: `agents/canon/CANON.md`
  (shared rule blocks) + `agents/canon/fragments/{claude,codex,antigravity}.md`
  (per-tool voice) compiled by `claude/scripts/gen-instruction-files.sh` into
  `claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md` — now
  committed GENERATED artifacts with a do-not-edit banner. Migration is
  semantics-preserving: zero removed words; only the banner, two GEMINI.md
  re-wraps, and the new two-floor block.
- **check-agent-parity.sh (#206)** — concept RULES extended with the lane
  contract (`one-owner-worktree`, `adversarial-verification`,
  `handoff-claim-repro`) and `two-floor-grounding`; weak keyword regexes
  (`scope|scoped|unrelated` etc.) tightened to rule-phrase matching over
  unwrapped markdown; new byte-currency check (`gen-instruction-files.sh
  --check`) fails CI on hand-edits or stale artifacts. Test suite rebuilt:
  15 fixture cases including per-rule drift, tightened-regex, hand-edit,
  orphaned/unknown canon block, and idempotency.
- **Two-floor grounding (#219, ADR-0006)** — encoded once in canon and emitted
  into all three instruction files: an adopt/skip verdict on an external
  technology must clear a project floor (verified local fact) and an external
  floor (verified source), neither compensating for the other.
- **`.doc-contract`** — the three instruction files moved SOURCE → GENERATED;
  `agents/canon/**` added as SOURCE. README, agents/README, scripts README,
  and MULTI-AGENT.md repointed at the canon.

### Decisions made
- Rejected literal root-AGENTS.md shims (would load empty in 2 of 3 tools) and
  symlinking (kills per-tool voice); generation keeps per-tool divergence real
  while making shared rules single-source. Evidence in ADR-0007.

### Post-review hardening (Codex adversarial pass on PR #234)
- **Leak guard (P1):** a malformed marker (trailing space, or an include line
  inside a canon block) previously shipped literally with rc=0 — the generator
  now fails loudly if any rendered line still matches `<!-- (include|canon):`.
  Two new fixture cases (17 total).
- **Negation limit documented** in check-agent-parity.sh's header: phrase
  matching asserts presence, not affirmation; the byte-lock to reviewed canon
  sources is the mitigation.
- **session-retro** now routes instruction-file proposals at `agents/canon/`
  + regeneration instead of the generated artifacts.

## 2026-07-10 — chore: AGENTPACK.yaml is now GENERATED from frontmatter (#207)

### What changed
- **`claude/scripts/gen-agentpack.sh`** (new) — generates `claude/AGENTPACK.yaml`
  from the live frontmatter of `claude/skills/*/SKILL.md` and
  `claude/agents/*.md` (same source of truth as build-site.sh) plus the new
  hand-maintained fragment `claude/agentpack-meta.json` (pack metadata,
  compatibility, profiles, the three instruction atoms, per-type atom
  defaults, pinned skill ordering). `--check` mode exits 1 when the committed
  manifest is stale; wired into ci.yml's shared checker block.
- **`claude/AGENTPACK.yaml`** — regenerated: gains a `# GENERATED … do not
  edit` banner and 12 descriptions (11 skills + security-reviewer agent)
  resync to current frontmatter. The old hand-applied ~296-char truncation is
  gone — it was lossy, schema-unrequired, and internally inconsistent
  (orchestrate sat untruncated at 302 chars), so no deterministic rule could
  reproduce it.
- **`.doc-contract`** — `claude/AGENTPACK.yaml` declared GENERATED,
  `claude/agentpack-meta.json` declared SOURCE (non-md, documentation-only
  entries).
- **`claude/MULTI-AGENT.md` / `claude/scripts/README.md`** — note the manifest
  is generated, never hand-edited.

### Decisions made
- **GENERATED, not HISTORICAL**: nothing consumes the manifest *today* (no
  Operator Commons pack published, `~/.agentpack` absent), but the agent-pack
  CLI's shipped git-source install (`agentpack install
  github:owner/repo@ref#subpath`) targets exactly this file, and four
  instruction surfaces (MULTI-AGENT.md, CLAUDE.md, codex/AGENTS.md,
  antigravity/GEMINI.md) bill the AgentPack as the cross-tool loading
  mechanism. Marking it HISTORICAL would have meant rewriting the declared
  team architecture; generating it removes the drift class at near-zero cost.
- Meta fragment is JSON (`agentpack-meta.json`), not YAML: parsed with
  python3 stdlib only — no PyYAML dependency in CI; AGENTPACK.yaml itself is
  already a JSON-bodied YAML document.

## 2026-07-10 — feat: agent-native-review subagent + deployed-orphan checker (#217, #215)

### What changed
- **`claude/agents/agent-native-review.md`** — ADR-0006 next action 1: the
  `agent-native-reviewer` persona from Every's compound-engineering-plugin
  (MIT, attributed) vendored as an in-house review subagent, rescoped for a
  config/tooling repo: UI action-parity dropped; verification affordances,
  context parity for subagents, primitives-over-workflows, governed execution,
  instruction-surface drift, and the anchored confidence rubric kept. Scoped to
  correctness-and-requirements findings — the lens is not a license for bloat.
- **`claude/scripts/check-deployed-orphans.sh`** — sweeps the *deployed*
  `~/.claude` for decommissioned artifacts the symlink checker never sees:
  non-symlink debris in `hooks/` (the PAI-era framework, ADR-0002),
  `settings.json.doctor-bak`, an empty `commands/` dir, plus an informational
  UNKNOWN triage list for unrecognized top-level entries. WARN-only by default
  (exit 0); `--strict` exits 1 on orphans. 13-case fixture self-test in
  `tests/deployed-orphans.test.sh`.
- **One-time live cleanup** — the PAI leftovers the checker flagged
  (`hooks/{handlers,lib,security}`, 25KB `hooks/README.md`,
  `settings.json.doctor-bak`, empty `commands/`) were backed up to
  `~/.claude/backups/pai-decommission-2026-07-10.tar.gz` (tar-verified, 36
  entries), then deleted; checker and `check-claude.sh` both report clean.

## 2026-07-10 — chore: split plugin enablement into global vs per-project scope (#214)

### What changed
- **`claude/plugins.txt`** — restructured into `# [global]` (16 plugins,
  enabled in `~/.claude/settings.json`) and `# [per-project]` (vercel,
  playwright, sentry, posthog, soundcheck — enabled only via each target
  project's `.claude/settings.json`) sections. Markers are comments, so
  setup.sh / sync-plugins.sh install both sections unchanged. Target projects
  documented per plugin on their own comment lines — NOT inline, because
  setup.sh's and check-install-integrity.sh's marketplace awk does not strip
  trailing inline comments.
- **`PluginDriftCheck.hook.ts`** — now parses the sections and additionally
  warns when a `[global]` plugin is missing from global `enabledPlugins` or a
  `[per-project]` plugin is enabled globally. Warn-only by design (exit 0
  always): live settings still carry the old fully-global set during the
  migration window, and a session must never be blocked over plugin scoping.
  A marker-less manifest parses as before (all lines = global), though the
  scoping checks are new, so advisory warnings can appear where the old hook
  was silent.
- **`sync-plugins.sh` / `claude/scripts/README.md`** — documented that
  installation covers both sections; scoping governs enablement only.
- **Adversarial-review round** — playwright's targets gained clarity-engine
  (`@playwright/test` + `playwright.config.ts` in the nested `app/`
  package.json, missed by the top-level-only sweep); hook hardened: warns on
  a plugin listed in both sections (unsatisfiable scoping), tolerates leading
  whitespace before section markers, dedupes install-drift counts.

### Decisions made
- The actual `enabledPlugins` migration (global settings live in
  claude-memory; per-project snippets for operator-commons, stringer, smss,
  clarity-engine, agent-pack, allora-engine, vlcek-built) is applied
  separately — this PR delivers the manifest/hook/doc layer plus the exact
  JSON in the PR body.

## 2026-07-09 — chore: full open-issue/PR sweep across the fleet (orchestrated, 10 PRs, 18 issues closed)

### What changed
- **Every open dotfiles issue and PR closed** in one orchestrated session: 8
  parallel worktree agents (fix/build), 4 adversarial reviewers, 2 phase-2
  agents; every code PR got an independent refutation review before merge.
- **PR #164 merged** (harvester REST-only for the cloud-proxy sandbox), then
  **#182**: the harvester skips obsolete bot comments (#159). Empirical
  correction to GitHub's docs: outdated comments keep `position`, the real
  signal is `line: null`; GraphQL resolved-thread check is strictly best-effort.
- **Antigravity gate hardened (#185)** — whole-verdict LGTB match only (#152),
  fail-closed on unresolved base refs (#153), prompt+diff delivered via stdin so
  secrets never hit argv (#154, verified against agy 1.1.0), skill invokes the
  installed gate path (#155); stray-[P#]-token guard on the P3-only pass path;
  new 12-assertion PATH-shim test wired into CI. #148 closed with the
  mitigation record.
- **setup.sh --dry-run now honors its no-writes contract (#187 + #192,
  closes #133 f.1, #189)** — link_file() and ~20 call sites guarded; repair
  mode previews under dry-run; stateful-CLI probes (gh/codex/login-shell)
  gated as a class (gh ≥2.9x writes `device-id` on ANY invocation — the CI-only
  failure); byte-strict regression test + smoke-install zero-mutation assertion.
- **Docs reconciled with live state (#183, closes #66 #52 #118; #115/#112
  closed as false positive)** — SECURITY/CONTRIBUTING point at channels that
  exist, BRANCH_PROTECTION documents the real required-checks set
  (shellcheck/tsc/doc-truth), README tree/tables refreshed.
- **Generated GitHub Pages site (#186, closes #168)** — MkDocs Material over
  existing markdown, build-time skill/agent catalog from live frontmatter,
  strict build, deploy workflow. Needs Settings → Pages → "GitHub Actions"
  before first deploy.
- **ADR-0006 (#184, closes #77)** — verified assessment of Every's
  compound-engineering plugin; `agent-native-audit` was removed upstream;
  verdicts: adapt the reviewer persona + memory-refresh + two-floor grounding,
  skip the rest.
- **Multi-agent dispatch mechanics encoded (#188, closes #177 #178 #179)** —
  companion-direct Codex routing (forwarder is fire-and-forget only), verified
  agy slug `claude-opus-4-6-thinking` (unknown slugs silently fall back to
  flash-low), Teammate Contract in GEMINI.md.
- **Autonomy Kit adoptions (#190)** — coach pass (judgment-only review),
  "name the bar" quality self-check, effort-matched reviews; attribution to
  Joe Amditis (MIT). Receipt tokens/caps/picker evaluated and deferred as
  harness-only.
- **codex/skills → agents/skills (#191, closes #166)** — the shared skill set
  is now agent-neutral on disk; checkers/parity/docs updated; live relink
  verified (agy discovers all 8 shared skills post-rename).
- **claude-memory**: janitor PR #17 pending user merge; security sweep #16
  partially remediated (token metadata redacted), disposition on the issue.

### Decisions made
- Merges go through auto-merge + required checks after an independent
  adversarial review — never a direct unreviewed merge.
- Discussions stays disabled (questions → Issues with `question` label);
  private-vulnerability-reporting enablement left to the operator.

### Known issues
- Pages deploy fails until the Pages source is set to GitHub Actions.
- claude-memory #16 remainder: settings.json findings need a foreground
  session; operator-commons token rotation due before 2026-07-16.

## 2026-07-09 — feat: the three-agent loop made real (closes the capability-audit gaps #169–#176)

### What changed
- **codex-review-gate.sh rewritten for structured output (#169)** — reviews now run
  `codex exec --output-schema` against a vendored JSON schema
  (`claude/scripts/codex-review-schema.json`); the ~100 lines of prose-regex and
  format-drift heuristics are gone. The gate computes and FENCES the diff itself
  (hash-derived boundary, untrusted-data framing, `-s read-only`) so changed-file
  content can't re-scope the review. Strict shape validation (verdict/severity
  enums) and a non-zero-exit-with-clean-approve guard both fail closed.
- **Adversarial refutation mode (#170)** — `--claim "<claim>" --repro "<cmd>"`
  injects the falsifiable handoff payload; the reviewer is instructed to refute,
  not confirm. Wired into MULTI-AGENT.md's handoff-payload contract.
- **Antigravity browser/runtime lane is real (#172, #173)** — global
  `mcp_config.json` seeded from `antigravity/mcp_config.json.example`
  (Playwright MCP + GitHub MCP, token resolved at launch via `gh auth token`,
  never stored); new `browser-verify` skill (falsifiable payload in, verdict +
  evidence out at `~/.claude/handoffs/evidence/`); verified live — agy lists
  both servers, playwright browser_* tools, and the skill.
- **agy session-start handoff injection (#174)** — `antigravity/hooks.json` +
  `claude/scripts/agy-inject-handoff.sh` (PreInvocation): interactive agy
  sessions get the project's latest handoff note as ephemeral context; skips
  gate runs (`ANTIGRAVITY_GATE=1`) and repeat invocations. Verified live: agy
  quoted the note's heading with a workspace attached.
- **Gate canary (#175)** — on empty review output the agy gate now runs a PONG
  canary to distinguish one failed review from a systemic `--print` stdout
  regression, and warns loudly before degrading.
- **Handoff loop closed (#171) + session continuity (#176)** — codex/AGENTS.md
  and antigravity/GEMINI.md gain a Team Handoffs section (read
  `~/.claude/handoffs/` at session start; persist verdicts as artifacts);
  both handoff skills gain an optional "Session continuity" section carrying
  codex session ids / agy conversation ids for resume-not-cold-start.

### The loop working on itself
The rewritten Codex gate live-blocked its own rewrite five rounds running, with
real findings each time (prompt-obedience scoping, `readlink -f` on macOS,
rc-ignored approve, weak enum validation, hook word-splitting, unfenced
claim/repro payloads, and the self-review problem: a diff that edits the
reviewer's own AGENTS.md can steer the review that judges it). All fixed —
including a new self-review guard that fails closed toward the cross-vendor
gate when a diff touches the Codex instruction surface. One finding
(env-var propagation through the timeout wrapper) was empirically REFUTED and
answered with an explicitness change rather than a behavior change. That is the
refuter lane doing exactly what #170 asked for.


## 2026-07-09 — feat: Antigravity joins the shared-workflow config (agy-memory + antigravity/ layer)

### What changed
- **`antigravity/GEMINI.md`** — public-safe global rules for Antigravity (`agy`),
  the Gemini sibling of `codex/AGENTS.md`: Fable conduct layer, working style,
  multi-agent lanes (Antigravity = runtime/browser verifier + front-end),
  public safety, private-memory pointers. Symlinked to `~/.gemini/config/GEMINI.md`
  by `setup.sh` (new section 5c) — verified live: `agy` loads it and quotes its lane.
- **Shared workflow skills across agents** — the agent-neutral skill set in
  `codex/skills/` (review, simplify, fix-issue, commit-push-pr, handoff,
  changelog, branch-hygiene, repo-health) is now dir-symlinked into
  `~/.gemini/config/skills/`, so Codex and Antigravity run the same workflows
  from one source. Verified live: all 8 discovered by `agy`.
- **`agy-memory` private repo** (github.com/jckeen/agy-memory) — third member of
  the memory trio: `GEMINI.local.md` + `MEMORY.md`, linked into
  `~/.gemini/config/` by setup.sh, mirroring codex-memory.
- **`check-antigravity.sh`** — drift check mirroring `check-codex.sh` (link
  verification, local-state warnings, orphan cleanup with `--fix`); wired into
  the smoke-install CI workflow.
- **`check-agent-parity.sh` now checks three files** — every canonical
  cross-agent rule must appear in `claude/CLAUDE.md`, `codex/AGENTS.md`, AND
  `antigravity/GEMINI.md`; self-test fixtures extended (4 cases).
- **fix: `fix-issue` skill YAML** — unquoted `: ` in the description made the
  frontmatter invalid YAML; Antigravity's strict parser silently dropped the
  skill from discovery (Codex tolerated it). Description now quoted.

### Decisions made
- Antigravity global rules live at `~/.gemini/config/GEMINI.md` — verified
  empirically (marker probe): the `rules/` subdir is NOT loaded there, and
  `skills.json` entries need absolute paths (`~/` is not expanded).
- `codex/skills/` stays the single source for the shared set rather than
  renaming to a neutral `agents/skills/` now — the rename touches 6+ surfaces
  (CI tests, README, doc-contract); proposed as a follow-up issue instead.


## 2026-07-09 — chore: Claude Cloud routine fleet moved to Opus 4.8

### What changed
- The 12-routine Claude Cloud fleet (nightly/weekly automation across the owned
  repos) now runs on **`claude-opus-4-8`** (Opus 4.8), up from a Sonnet mix
  (`claude-sonnet-4-6`, plus `claude-sonnet-5` on docs-steward + codex-harvest).
  These routines do real unattended code work — dep upgrades, security triage,
  docs edits, PR merges — so the reasoning headroom is worth the higher per-token
  cost. Individual routines can be dialed back to Sonnet for cost per-routine.
- Source of truth is the **`jw-routines`** repo (private, `jckeen/jw-routines`),
  not this one: the model is set per-routine in `routines/<slug>/meta.json` and
  pushed to the live triggers via `push-routines.mjs` + the in-session
  `RemoteTrigger` tool. See that repo's README ("Model") for the policy. Recorded
  here because dotfiles is the hub that references the fleet (review-automation
  spec, `commit-push-pr` skill); the per-routine model state is not duplicated.

## 2026-07-09 — feat: automatic review pipeline (Antigravity gate + Codex-bot comment capture)

### What changed
- **Antigravity (Gemini) review gate** hardened and wired as an advisory second
  gate in `/commit-push-pr` (and `/orchestrate`), alongside Codex. Runs
  `agy --mode plan --sandbox` with **no** `--dangerously-skip-permissions`; the
  reviewed diff is fenced as untrusted data with a hash-derived boundary
  (prompt-injection hardening). New `/antigravity-review` skill.
- **Codex-bot comment capture** — `harvest-codex-comments.sh` files
  `chatgpt-codex-connector[bot]` PR review comments as deduped GitHub issues
  (marker `codex-comment-id`); a warn-only `PreMergeCodexHarvest` PreToolUse hook
  runs it at `gh pr merge` time so bot findings aren't lost when a PR merges
  before the bot comments. Hook wiring lives in claude-memory settings.
- **Cloud backstop** — a `nightly-codex-comment-harvest` Claude Cloud routine
  (daily) sweeps the fleet for comments that land after a session ends
  (auto-merge / web merges).
- Follow-up fixes from the bot's own review: include untracked files in
  uncommitted Antigravity reviews; portable `timeout` (gtimeout fallback) and
  `sha1sum`/`shasum`/`cksum` for macOS.
- Design recorded in `docs/superpowers/specs/2026-07-09-review-automation-design.md`.

### Why
- Make review and post-PR comment capture automatic, so shipping by conversation
  (or `/orchestrate`) needs no remembered tool calls.

## 2026-07-08 — feat: /max → /orchestrate; full-lifecycle skill orchestration

### What changed
- Renamed the `max` skill to **`orchestrate`** (dir, frontmatter, and all
  references: README, CLAUDE-GUIDE, session-retro, decompose, AGENTPACK.yaml).
  The name now describes what it does rather than just "effort."
- **Roll-call the skills first** (Plan First) — before executing it now scans the
  available-skills list and invokes the matching process skills (brainstorming /
  systematic-debugging / TDD) without being asked.
- **Close the Loop** (new section) — when work is done it fires the wrap-up
  skills in order automatically: `/verify` → `/code-review`(+`/security-review`)
  → `/simplify` → `/changelog`/`/handoff` → `/session-retro`. Closes the gap
  where session-retro had to be requested manually.
- Description keeps "maximum effort / go all-in" trigger phrasing so habitual
  wording still routes here.

## 2026-07-08 — fix: preserve url.*.insteadOf rewrites across setup.sh runs

### What changed
- **`setup.sh`** — the `.gitconfig.local` regeneration now preserves any
  `url.<base>.insteadOf` rewrites the user added, the same way it preserves
  `safe.directory` entries. Without this, the SSH→HTTPS rewrite that lets
  `claude plugin install` clone github-sourced plugins (e.g. soundcheck) on an
  HTTPS-only machine was silently wiped on the next setup run. It's preserved,
  not forced — a fresh clone with no such entry gets none. Verified with a
  capture→wipe→restore round-trip.

## 2026-07-08 — feat: adopt soundcheck security plugin; thin security-reviewer

### What changed
- **`claude/plugins.txt`** — added `soundcheck@soundcheck` (third-party,
  thejefflarson/soundcheck) for its automatic background security triage on
  generated code — the one review capability the stack lacked (everything else
  is diff/PR-time). Its on-demand commands overlap code-review/pr-review-toolkit
  and collide with the built-in /security-review, so the comment says lean on the
  background triage, not those commands.
- **`setup.sh`** — marketplace registration arm for the `soundcheck` marketplace
  (keeps check-install-integrity green).
- **`security-reviewer` agent** — thinned to in-context app-logic review (broken
  authorization/IDOR, trust boundaries, business-logic flaws) and now explicitly
  defers the generic OWASP/CWE pattern catalog to soundcheck and CVEs to
  dependency-doctor, so the three don't run the same pass three ways.

### Known issues
- `claude plugin install` clones github-sourced plugins over SSH; a machine
  authenticating to GitHub via HTTPS only (no GitHub SSH key) will see the
  install step fail (setup.sh tolerates it and continues). Marketplace + plugin
  identifier are verified correct.

## 2026-07-08 — refactor: deferred audit refactors (#135–#141)

### What changed
Implemented via three parallel worktree-isolated agents (file-disjoint groups),
then merged and re-verified together (tsc, all self-tests + checkers, shellcheck,
setup.sh --check/--repair, --yes --dry-run smoke).
- **lib-symlinks.sh** (#135) — single shared enumerator of the claude/ symlink
  tree, sourced by both setup.sh (linking + audit) and check-claude.sh; removed
  the triplicated tree walks and the nolink fallback duplicated across three bash
  consumers + the TS hook (`claude/nolink.txt` is now the sole source).
- **checker-lib.sh** (#136) — `resolve_script_path`, repo-root resolution, and
  the colored fail-counter helpers factored out of the ~13 copies across the
  dotfiles-local checkers and their self-tests. `check-doc-truth.sh` kept
  deliberately standalone (vendored by /drift-sweep).
- **non-interactive `--yes`** (#137) — setup.sh takes safe prompt defaults and
  skips logins; smoke-install now runs `./setup.sh --yes --dry-run` against a
  throwaway HOME.
- **doc-refs code-strip** (#138) — check-doc-refs.sh now blanks fenced/inline
  code before link resolution (matching check-doc-truth), so links inside code
  blocks stop false-positiving; +3 self-test cases.
- **git-config heredoc** (#139) — the 4 near-identical `.gitconfig.local`
  heredocs collapsed to one parameterized by per-platform editor/helper.
- **bun pin** (#140) — pin the bun *release version* and verify the binary
  against the release SHASUMS, instead of hashing the mutable installer script.
- **cc/cx preflight** (#141) — shared `_agent_preflight` helper removes the
  duplicated resume-detection + cd + sync sequence from cc and cx.

## 2026-07-08 — fix/perf: workflow-optimization audit findings

### What changed
- **Hooks reconciled with CI.** `StripProjectPermissions.hook.ts` watched
  `~/.claude/projects/<slug>/`, a path Claude Code never writes, so it never
  fired — repointed at the real repo-local `.claude/settings.local.json`.
  `conventional-commit.sh` and `check-commit-format.sh` disagreed on valid
  types/syntax (a commit could pass one gate and fail the other); the hook now
  shares the CI checker's type list and subject regex.
- **setup.sh link accounting.** `link_file` now no-ops when a link is already
  correct (was rm+recreating every link each run) and counts real creations;
  `audit_link` returns a repaired code so `--repair` reports "Repaired: N",
  excludes fixed links from Broken, and exits 0 on success. Git identity prompts
  gained the `|| true` guard the other prompts already had.
- **CI streamlined.** Added a `concurrency` block (cancels superseded runs);
  collapsed the five non-required pure-bash checker jobs into one `checks` job
  with a single checkout (shellcheck/tsc/doc-truth stay separate — they are the
  required status checks); dropped the dead shellcheck `additional_files`.
- **Shell workflow.** `pull-all` now pulls repos concurrently (biggest daily
  win — cc/cx wait on the slowest pull, not the sum); `_dev_dir` is memoized;
  `git-hygiene` reads default-branch subjects once instead of per-commit, drops
  dead code, guards `cd`, and fixes the origin-slug regex. `cc-pane`/`cc-tab`
  now validate the project name like the PowerShell side.
- **Guards + docs.** `check-skill-parity.sh` now CI-asserts the README
  "N-agent" count (was hardcoded 8x, unguarded). CLAUDE.md's commit-authorization
  contradiction with the standing-order/conduct layers resolved. AgentPack phase
  gaps fixed (schema-reviewer/ux-reviewer placement); agent overlaps scoped
  (security-reviewer defers CVEs to dependency-doctor); changelog/review/simplify
  trigger collisions disambiguated.

### Decisions made
- The two large structural refactors surfaced by the audit — a shared symlink
  enumerator (setup.sh × check-claude.sh triplication + the nolink fallback) and
  a shared checker-lib for the 13 `resolve_script_path` copies — plus a
  non-interactive `--yes` install mode and the doc-refs/doc-truth link-check
  dedup, are deferred to their own PRs (filed as issues) rather than bundled
  into this one, since they touch the critical install path and need
  fresh-clone testing.

## 2026-07-06 — fix: Fable-layer review findings (Codex pass on #130)

### What changed
- README repo tree now lists `claude/FABLE.md` and `claude/skills/fable-mode/`
  (the inventory was stale after #130).
- Reconciled the autonomy contradiction Codex flagged: CLAUDE.md's "plan
  before non-trivial work, confirm the approach" and FABLE.md's "never ask
  before reversible work" now state the same composed rule — state the
  approach, confirm only when the goal is genuinely ambiguous, then execute
  without re-asking step by step.

## 2026-07-06 — feat: Fable conduct layer (FABLE.md + /fable-mode)

### What changed
- **`claude/FABLE.md`** — operating discipline distilled from Claude Fable 5
  on its last session day: outcome-first final messages, readable-over-concise
  prose, the reversible/destructive/assessment autonomy switch, the end-of-turn
  self-check, evidence discipline, and a pre-send checklist. Imported by
  `claude/CLAUDE.md` (via the `~/.claude/FABLE.md` symlink) so every future
  model on this config — Opus included — inherits the same behavior.
- **`/fable-mode` skill** — recalibration ritual: re-read the layer, audit the
  last three replies against the checklist, state corrections, continue.
- Wired everywhere the config is consumed: AgentPack atoms
  (`instruction:fable-conduct-layer`, `skill:fable-mode`) for
  Codex/Cursor/ChatGPT targets, a Conduct Layer section in `codex/AGENTS.md`,
  `.doc-contract` SOURCE entry, README + CLAUDE-GUIDE skill tables (15 → 16).

### Decisions made
- The layer is a top-level `claude/` file (auto-symlinked by setup.sh) rather
  than a hook injection — imports are simpler, and the async-hook
  additionalContext path is a known 400-error footgun.
- Written model-agnostic: it's a contract about how to operate, not a model
  identity.

## 2026-07-04 — test: fixture self-tests for the 5 remaining checkers (#125)

### What changed
- **Self-tests for every CI checker** — added fixture harnesses for
  `check-doc-refs`, `check-no-personal-data`, `check-agent-parity`,
  `check-skill-parity`, and `check-commit-format` (20 cases total), each wired
  into its CI job to run before the checker (mirroring the `doc-truth` and
  `install-integrity` pattern). All 7 gate checkers now have self-tests; a
  checker that regresses to an unconditional `exit 0` is now caught. Closes the
  remainder of #125.
- Each test copies its (script-dir-resolving) checker into a throwaway repo so
  `REPO_ROOT` points at the fixture; `commit-format`'s runs the real checker in
  a fixture repo since it operates on cwd. Negatives assert the specific failure
  fragment, and the harness was mutation-tested (an always-pass checker turns the
  negatives red) to prove the tests aren't vacuous.
- **`no-personal-data.test.sh` assembles its leak fixtures at runtime** — the
  literal `/home/<user>/` and `C:\Users\<user>\` patterns would otherwise sit in
  a tracked file and trip `check-no-personal-data` against the repo itself. The
  gate caught this self-hosting bug during development.

### Decisions made
- `commit-format`'s self-test lives in the PR-only `commit-format` job (that
  checker only runs on PRs anyway), so it's gated on every PR.

### Known issues
- None outstanding from the June 2026 audit — #120–#125 all resolved.

## 2026-07-03 — fix: fresh-clone audit findings + install-integrity CI gate

### What changed
- **`check-codex.sh` + `claude/hooks/worktree-guard.sh` exec bits** — both were
  tracked `100644`; a fresh clone couldn't run them. `setup.sh` guards the Codex
  health check on `[ -x check-codex.sh ]`, so the missing bit *silently skipped*
  it. Restored to `100755` (#120, and a second offender the new guard surfaced).
- **`openai-codex` marketplace arm in `setup.sh`** — `plugins.txt` lists
  `codex@openai-codex` but the marketplace `case` had no arm for it, so the codex
  plugin fell through to "Unknown marketplace" and never installed on fresh
  machines. Added the `github:openai/codex-plugin-cc` registration (#121).
- **`.gitconfig.local` no longer wipes user `safe.directory` entries** —
  `setup.sh` rewrites the file with `cat >` each run; it now captures existing
  `safe.directory` entries first and restores them after (idempotent, `set -u`
  safe), so hand-added project entries survive a re-run (#122).
- **`setup.sh` degraded-host crashes** — three `set -e`/pipefail capture
  assignments (`GIT_EMAIL`, `WIN_USER`, `cc_type`) now `|| true`, so a failed
  probe degrades to the intended warning instead of aborting the installer (#123).
- **AGENTPACK.yaml skill descriptions regenerated from `SKILL.md`** — `jj`'s
  description was the literal folded-scalar indicator `">-"` and 7 others were
  truncated mid-word; all now word-boundary truncated from source (#124).
- **New CI gate `install-integrity`** — `check-install-integrity.sh` asserts
  every shebanged `*.sh` is `100755` and every `plugins.txt` marketplace has a
  `setup.sh` arm (the two regressions above, promoted from discipline into CI),
  with a fixture self-test `tests/install-integrity.test.sh` (#125).
- **`smoke-install.yml` path filter** aligned with the files its `bash -n` step
  checks (added `check-codex.sh`, `git-hygiene.sh`, `hygiene-status.sh`) so PRs
  touching only those actually trigger the smoke (#125).
- **README** — corrected "same skill set as Claude" (Codex ships a public-safe
  subset, not the full 15) to "the public-safe skill subset".

### Decisions made
- The new checker uses `git rev-parse --show-toplevel` (like `check-doc-truth.sh`)
  so its self-test can drive it against a throwaway fixture repo.
- Left `smoke-install.yml`'s `continue-on-error` grace period and MULTI-AGENT.md's
  Antigravity framing as-is (intentional / roadmap, not defects).

### Known issues
- 6 of 7 remaining checkers still lack fixture self-tests (tracked in #125); only
  `doc-truth` and now `install-integrity` have them.

### What changed
- **`delete-branch-on-close.yml`** — a `pull_request: closed` workflow that
  deletes a PR's head branch when it's closed **unmerged**, scoped to same-repo
  non-default branches. Closes the gap left by `delete_branch_on_merge` (which
  only fires on merge): discarded nightly-drift PRs from the scheduled Claude
  Cloud routine had been orphaning their `claude/*` branches on origin. Branch
  remains recoverable via the closed PR's Restore button. `head.ref` is passed
  through `env:` and quoted, never interpolated into `run:` (no injection).
- **Plugin drift auto-heals at `cc` launch** — the `cc()` launcher now runs
  `sync-plugins.sh` pre-exec on a fresh start (skipped on resume), so any
  manifest plugin missing from the install gets installed *before* the session
  loads its plugins — no manual run + restart. `PluginDriftCheck.hook.ts` stays
  as the SessionStart detection safety net for sessions launched outside `cc`.
- **`sync-plugins.sh` fast path** — exits silently when every manifest plugin is
  already installed (one small file read instead of N `claude plugin install`
  calls), keeping the every-launch sync near-instant in the no-drift case.
- Backfill: cleaned the accumulated stale `claude/*` remote branches and merged
  the lingering nightly-drift README fix.

---

Older entries, one HISTORICAL file per quarter:

- [2026 Q2](docs/changelog/CHANGELOG-2026-Q2.md)
- [2026 Q1](docs/changelog/CHANGELOG-2026-Q1.md)
