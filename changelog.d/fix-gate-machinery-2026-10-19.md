## 2026-10-19 — fix(gates): verdicts from runs that did not complete, exit 2 only by choice, bytecode caches (#515, #579, #581)

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

## 2026-10-19 — fix(gates): a repo-root node_modules no longer blocks every gate in a bun/npm project (#651)

- **The #514 vendored-tree rule covers the repository root.** An installed
  root `node_modules` holds dependencies' own `CLAUDE.md` and `SKILL.md`
  files (`bun-types`, `playwright-core`), so `lane` and both gates refused
  every ordinary JS repo as a dirty instruction surface. `review-receipt.py`
  now leaves out a path under the root `node_modules` when that directory is
  an ignored real directory and a regular-file `bun.lock`, `bun.lockb` or
  `package-lock.json` sits beside it. Ignoring only the planted file, a
  re-included child, a symlinked lockfile, a symlinked tree or a nested
  package's `node_modules` still refuse. `bun.lockb` now also counts for the
  skill and scripts trees.
- **`review-receipt.py` is executable**, as the review-gates skill invokes it.

## 2026-10-19 — fix(gates): the Codex review cannot escalate out of its read-only sandbox (#651)

- **`-s read-only` was not read-only.** The gate pinned the sandbox but not
  the approval policy, so it inherited the user's
  `approval_policy = "on-request"` and `approvals_reviewer = "auto_review"`.
  A command the sandbox denied could be re-run with
  `sandbox_permissions = "require_escalated"`, and the automatic reviewer
  approved it, unattended and unsandboxed. A probe on codex-cli 0.163.0 wrote
  a file this way under `-s read-only`. During a gate run the reviewer acted on
  the repro text (`bun install && bun run verify`), installed `node_modules`
  into the worktree, and `verify --snapshot` refused the run. Both Codex
  invocations now pass `-c approval_policy="never"`. `review-multipart.py`
  refuses any native turn whose recorded `approval_policy` is not `never`,
  alongside the existing read-only sandbox check.

## 2026-10-19 — fix(gates): a foreign boundary's own config cannot hide a CLAUDE.md (#641)

- **`boundary_listing()` pins where and how git looks.** It ran `ls-files`
  inside a foreign repository boundary under that boundary's own config, so a
  `core.worktree` there listed a decoy directory, and `core.ignoreCase=true`
  let a tracked `claude.md` mask an untracked `CLAUDE.md` on a case-sensitive
  filesystem. Both passed the instruction-surface sweep. The listing now runs
  with `--work-tree <boundary>` and `-c core.ignoreCase=false`. The suggested
  `-c core.worktree=` does not override the repository's own setting on git
  2.43, so `--work-tree` is used.
- **Worktree pointers are parsed as git parses them.** `worktree_gitdir()`
  requires the exact `gitdir: ` prefix and removes only trailing CR/LF, and
  the registered-gitdir read does the same (`registered_worktree()`). Both
  used to `.strip()` the path, the bug class #541 fixed.

## 2026-10-19 — fix(gates): review-and-push says why an approved run did not push (#628)

- **No terminal and no `--auto-push` is exit 4 with a message.** Without a
  terminal, `read -p` printed no prompt and failed at end of input, and
  `set -e` ended the wrapper with a bare exit 1 right after "Safe to push.".
  Four agent branches hit this on 2026-10-16 and pushed by hand. The wrapper
  now prints `approved but not pushed: no terminal to confirm on; re-run with
  --auto-push, or push <sha> yourself` and exits 4. The script header and
  `claude/scripts/README.md` document every exit status.

## 2026-10-19 — fix(gates): a sibling moving origin/main no longer voids a review in flight (#680)

- **The review base is pinned when the run begins.** A gate's snapshot
  recorded `origin/main` and re-resolved it at every verify. A fetch by any
  sibling worktree moved it, and the run refused with "repository changed
  during review or after approval". That happened five times in one session
  of parallel merges, each costing a 15–20 minute re-run. `stable_capture`
  now resolves the base once, and `verify` re-captures against the commit
  pinned in the snapshot. The branch's own HEAD, tree, index and files still
  have to match exactly.
- **`check` compares merge bases, not base tips.** The reviewed diff is
  `merge_base..HEAD`, so a receipt stays valid while the base tip moves on.
  It still refuses when the merge base differs: a receipt taken with a
  narrower `--base`, or a branch the base has since absorbed.

## 2026-10-19 — test(gates): the multipart request-changed case no longer collides with concurrent runs (#680)

- **The flake was a collision, not a timing race.** The mid-run mutation
  finds the gate's request file under the shared `/tmp` by its digest. Every
  concurrent run of `codex-review-gate.test.sh` built a byte-identical
  request, so the stub found two files and its single-hit assertion failed.
  Codex then exited 1 and the case degraded to rc 3 instead of the rc 2
  verdict (#679). Four runs in parallel failed 4 of 4 before the fix. The
  fixture now adds a per-run nonce, so each run's request is unique.
- **The base-mutation cases follow the pinned base.** A sibling moving the
  base mid-review now completes the review, and the receipt survives. A base
  that absorbed the branch completes too, but `check` then refuses the
  receipt because its merge base no longer matches.
