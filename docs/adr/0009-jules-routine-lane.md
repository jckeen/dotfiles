# 0009. Jules as the daily-routine lane

- **Status:** Accepted (2026-09-19, after the first live dispatch)
- **Date:** 2026-09-18

## Context

The review lanes are covered: Antigravity runs the ordinary review pass, Codex
guards the risk surfaces, and a conductor session integrates. Nothing owns the
*standing* work — the small, repetitive, evidence-checkable cleanups that never
justify a session of their own and so never happen: dead code that outlived its
caller, an assertion that cannot fail, a helper copied three times and drifted
twice, lint debt, documentation a checker already proves wrong.

That work has a shape: the finding is deterministic, the diff is small, and a
human can accept or reject it in under a minute. It does not need a local
session, a worktree, or the working tree at all. It needs a cloud agent, a
standing prompt, and a measurement loop that retires prompts that do not earn
their merges.

### External floor (verified 2026-09-18)

Verified live today, not from memory and not from this plan's earlier snapshot:

- **Package** — `https://registry.npmjs.org/@google/jules`: `dist-tags.latest`
  is 0.1.42, published 2025-12-16; `engines.node` is `>=18.0.0`; the single bin
  entry is `jules`. Install is npm-global, so the repository's existing
  `~/.local` npm prefix already puts it on PATH.
- **CLI** — `https://jules.google/docs/cli/reference/` documents
  `npm install -g @google/jules`, `jules login` (a browser Google
  authentication flow), `jules logout`, `jules version`, `jules completion`, and
  `jules remote` with `list`, `new`, and `pull` subcommands; flags `--repo`,
  `--session`, `--parallel` (on `remote new`), and global `-h/--help` and
  `--theme`. This page resolves an item the plan had recorded as unverifiable:
  `https://developers.google.com/jules/docs/cli` and
  `https://developers.google.com/jules/docs` both return 404, but the CLI
  reference lives on `jules.google`, and it was read today.
- **REST API** — `https://developers.google.com/jules/api`: base URL
  `https://jules.googleapis.com/v1alpha`, auth header `X-Goog-Api-Key`, key
  created in the Jules web app under Settings with at most three keys per
  account. Documented endpoints: `GET /sources`, `POST /sessions`,
  `GET /sessions`, `GET /sessions/{id}/activities`,
  `POST /sessions/{id}:approvePlan`, `POST /sessions/{id}:sendMessage`.
- **Session resource** —
  `https://developers.google.com/jules/api/reference/rest/v1alpha/sessions`:
  fields `name`, `id`, `prompt`, `sourceContext`, `title`,
  `requirePlanApproval`, `automationMode`, `createTime`, `updateTime`, `state`,
  `url`, `outputs`. `AutomationMode` has exactly two values,
  `AUTOMATION_MODE_UNSPECIFIED` and `AUTO_CREATE_PR`. `SourceContext` carries a
  required `source` string of the form `sources/{source}` plus an optional
  `githubRepoContext`, inside which `startingBranch` is required.
- **Limits** — `https://jules.google/docs/usage-limits/`: Ultra allows 300 daily
  tasks on a rolling 24 hours and 60 concurrent tasks. Free is 15/3 and Pro is
  100/15. The page documents no API-specific rate limit.

### Project floor (verified locally on this branch's base)

- There is no root `AGENTS.md` today. The only generated `AGENTS.md` is
  `codex/AGENTS.md`, built by `claude/scripts/gen-instruction-files.sh`.
- ADR-0007 rejected symlinked or shim instruction files: two of three local
  runtimes resolve no include syntax, so instruction files are compiled build
  artifacts. A fourth target costs one fragment and one map entry.
- The systemd pattern is a `--user` oneshot service plus a `Persistent=true`
  timer under `claude/systemd/`, hardened with `ProtectSystem=strict` and
  `ProtectHome=read-only` plus explicit `ReadWritePaths`. Its installer
  hardcoded one unit pair.
- State directories follow `~/.local/state/<tool>/` with a `status.json` written
  by the timer's script, as `claude/scripts/hygiene-cron.sh` does.
- `named_instruction()` in the Codex gate already treats any `AGENTS*.md` as a
  risk path, so a root `AGENTS.md` inherits tier-2 review without any change.

## Decision

Adopt Jules as the routine lane.

1. **Install and presence.** `setup.sh` installs `@google/jules` npm-global
   beside Codex, prints `jules login` as a manual step under `--yes` (it is a
   browser flow and must never run unattended), and reports `jules_installed` in
   the completion summary. `agents/capabilities.json` gains `jules` as a fourth
   runtime and a `routine-lane` capability.

2. **A root `AGENTS.md`, generated.** `agents/canon/fragments/jules.md` plus a
   target-map entry produces it. It is the brief for an agent with no session
   history, so it carries only what survives that: how to verify a change here,
   the pull request conventions, the doc contract, and what is out of bounds. It
   is enforced by the generator's byte-currency check, deliberately not by the
   concept-parity phrase list — holding a short cloud brief to every local
   file's phrases would defeat the reason it is short.

3. **A routine catalog, not code.** `agents/routines/<name>.md` — frontmatter as
   a contract the dispatcher parses strictly, body as the prompt. Six routines
   ship: `dead-code-remover`, `useless-test-pruner`, `dup-unifier`,
   `lint-debt-fixer`, `doc-drift-fixer`, and the weekly dotfiles-only
   `setup-layout-fuzzer`. Every one of them can name a deterministic signal; a
   routine that can only appeal to a reviewer's judgement does not belong.

4. **REST, not the CLI, for dispatch.** `claude/scripts/jules-dispatch.sh` calls
   the API directly. The CLI authenticates through a browser flow whose
   credential location is documented nowhere, so a unit running under
   `ProtectHome=read-only` cannot be shown to work; the REST path takes a key
   from a file the script validates itself. The key must be a regular file, not
   a symlink, mode 0600, non-empty, at least 20 characters, and within a
   restricted charset. It reaches `curl` through a config file on stdin, so it
   never enters argv or a log. The host is a constant in the script — never read
   from configuration — and `curl` runs with `--proto =https` and without `-L`,
   so no redirect can carry the key elsewhere. A repository's `source` is always
   read back from `GET /sources` and never constructed. A daily ledger at
   `~/.local/state/jules/dispatch.jsonl` makes the run idempotent per calendar
   day, and `JULES_DAILY_CAP` (default 40 of Ultra's 300) bounds the spend.

   Nine properties came from the review passes rather than the first draft, and
   each is now pinned by a test: `schedule` is *enforced* (a `weekly` routine is
   held back while its last dispatch for that repository is inside a seven-day
   window — parsed-but-ignored would have made the field decoration and run the
   weekly fuzzer seven times a week); `curl` is invoked with `-q` first, so a
   `location` or `trace` line in a `~/.curlrc` cannot defeat the stdin config; a
   run holds a lock directory, because a manual invocation overlapping the timer
   would otherwise read the same spend and dispatch twice; a failed ledger append
   is reported as an *unrecorded* dispatch rather than a successful one, since the
   session already exists by then; and `--dry-run` suppresses the `--report
   --post` comment, because "writes nothing" has to hold in every mode.

   A second round added four more. `GET /sources` is paginated — `pageSize`
   defaults to 30 and `nextPageToken` is omitted on the last page — so an
   unpaginated request would have reported every repository past the 30th as not
   connected, which reads like a configuration problem rather than a bug; the
   listing now asks for 100 per page and follows the token, validating it before
   it reaches a URL. The stale-lock reclaim is a read-check-replace sequence and
   is not atomic on its own. Two attempts to make it safe with `mkdir` were both
   races — the second only moved the race into the lock guarding the first — so
   serialization is an `flock`: the kernel releases it when the holder dies, which
   removes the staleness concept and the whole class of bug with it. Where
   `flock(1)` is absent (macOS, which also has no systemd timer) the run reports
   that it is not serialized rather than implying that it is.
   A failed ledger append now aborts the whole run rather than returning to a
   loop that would create an unrecorded session for every remaining pair. And
   `claude/systemd/install.sh` reads the script it validates out of the unit's own
   `ExecStart` line, because the unit names a fixed path under `$HOME` and a
   second copy of that path in the installer could agree with the checkout the
   installer was run from while disagreeing with what systemd will execute.

   The last rounds were all about the seams the earlier fixes created. The ledger
   append is built in memory and written with one `printf`, because a single small
   write to an O_APPEND file is atomic and a concurrent reader must never see half a
   line — otherwise a `--report` run, or a dispatch about to stand down on the lock,
   would reject a torn record and turn an intended no-op into a failure; and the
   ledger is validated only once the run owns the lock, for the same reason. The
   test suite pins both the day-edge margin and the clock, because a suite that
   fails for two minutes a day, or for one second at midnight, is worse than no
   suite. A `mktemp` failure could have had the suite overwrite the installed
   `/bin/curl`. And twice a case was deleted rather than shipped, because a fake
   `curl` cannot prove the real one ignores a config file and a default margin
   cannot be distinguished from zero at an ordinary time of day — shipping an
   assertion that cannot fail would have contradicted `useless-test-pruner`, a
   routine this same change adds.

   An eleventh round: the page token was guarded by a character allowlist, which
   would have aborted source discovery on a perfectly valid base64 token containing
   `+` or `/` — making pagination depend on an encoding the documentation never
   promises. The token is opaque, so it is percent-encoded instead, which is both
   correct for any token and sufficient to keep it from breaking out of the query
   string. Only a length bound remains.

   A tenth round found the same subshell mistake a third time, and this one got a
   structural answer rather than another local fix. The ledger read that builds the
   report scope sat inside a `printf` argument, so a malformed ledger produced a
   report over current repositories only, with no caveat and a zero exit status.
   Rather than patch that call, the ledger is now validated once at startup from
   the main shell — the one place a refusal can actually stop the run — so no
   query of it can fail quietly no matter where it is nested.

   The three instances are worth naming together, because they look different and
   are the same bug: a `die` inside a process substitution, an assignment inside a
   command substitution, and a read nested in a `printf` argument. In each case the
   failing code ran in a subshell whose exit status the caller never saw.

   A ninth round: the report queried only a routine's *current* repositories, so
   removing one deleted its pull request history from the window and moved the
   merge rate with nothing to indicate a repository had been dropped. The scope is
   now the current list union the repositories the ledger records for that routine.

   An eighth round closed the day-boundary gap properly. Checking the UTC date
   before each candidate is not enough: a request can take as long as its timeout,
   so one begun just before midnight can create its session on the next day while
   both ledger records carry this one — and the next run would dispatch that pair
   again without the session counting against the new day's cap. A dispatch is now
   refused unless more of the day remains than a request can consume, and the
   request timeout and the margin are derived from one constant so they cannot
   drift apart.

   One low finding was worth promoting rather than filing: if the caller's
   environment already exported a variable of the name the script uses for the
   key, a plain assignment KEEPS the export attribute, and the key is then in the
   environment of every child process — `curl`, `jq`, `gh` — readable from
   `/proc/PID/environ`. Verified locally both ways. The variable is unset before
   it is assigned, and the test asserts on the environment a child actually
   received.

   A seventh round found both previous fixes one level too narrow, which is the
   lesson worth keeping: a review finding is a category, not an instance. Phase two
   rechecked `paused` but not the rest of what phase one had decided, so a
   repository dropped from a routine mid-run still dispatched; the whole
   eligibility decision is now re-validated in one function, so a new rule cannot
   be added to phase one and forgotten. And the report caveat named failed queries
   but not routines whose frontmatter was rejected — also absent from the table,
   also invisible in a posted comment. The three reasons a report can be partial
   now go through one caveat builder for the same reason.

   A sixth round found two, both about trusting a partial answer. A failed
   `gh pr list` skipped its repository and set the exit code, but the posted table
   said nothing — and an exit code no one sees is not a caveat, so a routine could
   be retired on counts that silently omit a repository; the failure now appears in
   the report body and in the posted comment. And phase two rereads the catalog
   file, so it now rechecks `paused` as well: an operator pausing a routine while
   earlier requests are in flight expects the queued repositories to stop too.

   A fifth round found four more, one of them the kind only a reviewer reading for
   exactly this finds: `JULES_DAILY_CAP=08` disabled the cap entirely, because
   bash reads a leading zero as octal inside `[[ -ge ]]`, the comparison errors,
   and an errored test is a false one — so every candidate dispatched. Verified
   locally before fixing. Leading zeros are now rejected wherever a value reaches
   an arithmetic comparison, including `max_files` and `max_prs_per_run`. A run
   that crosses UTC midnight stops instead of recording against the previous day
   and spending its budget. A missing `flock(1)` now falls back to an atomic lock
   directory rather than running unserialized behind a warning, because a warning
   is not a guarantee. And `--report` says when its fetch hit the bound, since the
   bound is applied before the date window and the retirement rule is decided on
   those numbers.

   A fourth round closed the last two gaps. The ledger is now write-ahead: a
   record goes in *before* the request and is upgraded after it, because a POST
   that creates a session and then times out is indistinguishable from one that
   never landed — and without the first record the pair vanished from the ledger,
   so the next run dispatched it again and the original session never counted
   against the cap. An unresolved attempt is reported for reconciliation against
   `GET /sessions` and is not retried that day: a duplicate cloud session is the
   one outcome this script must never produce on its own. Both records of a
   dispatch share an attempt id, so the cap counts them once. And repository
   identity is lowercased everywhere, with a repeated entry rejected outright,
   because GitHub names are case-insensitive: `Owner/Repo` and `owner/repo`
   resolved to the same source while keying the ledger differently, and every
   eligibility check runs before the first session is created, so both copies
   passed.

   A third round found the ordering problem. With more eligible pairs than the
   daily cap allows, a fixed alphabetical order starves the tail *permanently*:
   ten connected repositories and the default cap of 40 would let the first four
   routines consume the whole budget every day, and the weekly fuzzer and the test
   pruner would never run once. Candidates are now ordered by how long it has been
   since that exact (routine, repository) pair last ran, never-dispatched first, so
   what the cap defers today leads tomorrow's queue and the cap is a rate limit
   rather than a cliff.

   Three rounds turned up the same bash mistake twice in different dress: a `die`
   inside a process substitution and an assignment inside a command substitution
   both happen in a subshell, so neither reached the caller. The first made an
   empty routine selection look like a successful run; the second silently
   emptied the resolved source list.

5. **A timer, not GitHub Actions.** The key stays on this machine.
   `claude/systemd/jules-dispatch.{service,timer}` fires at 09:00 with
   `Persistent=true`, mirroring `git-hygiene.service`'s hardening, with
   `~/.local/state/jules` as the only writable path — the key directory is
   deliberately absent from `ReadWritePaths`, so the unit can read the
   credential and never rewrite it. `claude/systemd/install.sh` became a loop
   over a table of unit pairs; adding a timer is now one row.

6. **Measurement, with a retirement rule.** `--report [--days N]` tallies
   opened, merged, and closed per routine per week from the `jules-routine:*`
   labels and can post the table on the tracker issue. A routine whose merge
   rate stays under 30% for two weeks running gets its prompt rewritten or
   `paused: true`. A pattern of wrong pull requests is answered by an exclusion
   in the prompt, never by loosening the gate that caught them.

## Consequences

The lane is verifiable before it is ever live. `claude/scripts/tests/jules-dispatch.test.sh`
drives the dispatcher against a fake `curl` and pins the credential refusals, the
absence of the key from argv and from every state file, same-day idempotency, the
daily cap, the skip for an unconnected repository, `paused: true`, and a
byte-identical state directory after `--dry-run`. It also proves the shipped
catalog parses, so the first timer firing is not what discovers a typo.

The cost is a new autonomous PR source. Its containment is that every routine PR
is labelled, capped in files, required to carry its own evidence and revert
command, and forbidden from touching CI, hooks, or instruction surfaces — and
that the measurement loop retires a routine that does not earn its merges rather
than leaving it to accumulate noise.

Status moved to **Accepted** on 2026-09-19: the first live dispatch
(`doc-drift-fixer` on `jckeen/dotfiles`, session `11332863501956419331`, PR
#477) converted the items below from assumptions into recorded facts. The three
gaps it also exposed are tracked in #479 and do not change the decision.

### Verified by the first live dispatch (2026-09-19)

Each of these was unverified because the documentation does not state it, not
because it was not looked for. None was load-bearing for the code that shipped.

- **The bot's PR author login.** The pull request's *author* is the connecting
  account (`jckeen`); the *commit* author is `google-labs-jules[bot]
  <161369871+google-labs-jules[bot]@users.noreply.github.com>`. The PR body
  ends with "PR created automatically by Jules for task <id> started by
  @<login>". The commit is unsigned (`verification.reason: unsigned`), and a
  commit author, a body footer, or a branch name can be written by anyone with
  push access, so none of them authenticates provenance. The only authenticated
  signal is the Jules API: `GET /sessions/{id}` lists the pull request under
  `outputs[].pullRequest` for a session the dispatcher's ledger created. The
  required `jules-routine:*` label was NOT applied — Jules has no label
  affordance (#479).
- **Whether Jules pushes branches to the same repository or to a fork.** Same
  repository: branch `jules-11332863501956419331-9a0451b0`
  (`jules-<session id>-<8 hex>`), base `main`. `delete-branch-on-close.yml`
  removed it the moment PR #477 closed unmerged, so routine branches need no
  extra cleanup.
- **The exact `source` string for a given repository.** The reference documents
  `sources/{source}`; the guide shows `sources/github/{owner}/{repo}`. The
  dispatcher therefore resolves it from `GET /sources` by matching owner and
  name, and never constructs it. Observed 2026-09-19: `GET /sources` returned
  `sources/github/jckeen/dotfiles`, i.e. the guide's spelling, for 33 sources.
- **Whether `githubRepoContext` may be omitted.** Answered 2026-09-19 by the
  first live dispatch: it may not. `POST /sessions` without it returned
  `400 INVALID_ARGUMENT` ("Request contains an invalid argument."), and no
  session was created. `GET /sources` reports each repository's default branch
  as `githubRepo.defaultBranch.displayName` (`main` for `jckeen/dotfiles`), so
  the dispatcher now sends that branch unless `JULES_STARTING_BRANCH` overrides
  it, and refuses a pair with neither before the write-ahead record. The
  resent request created `sessions/11332863501956419331`.
- **Whether API-created sessions draw on the same 300-task daily pool, and any
  API-specific rate limit.** The usage-limits page documents plan task limits
  and says nothing about the API. `JULES_DAILY_CAP` defaults to 40 for that
  reason.
- **Where the CLI stores its credentials.** Undocumented; it is the whole reason
  dispatch goes through REST rather than `jules remote new`.
- **The `jules version` invocation used by `setup.sh`.** The CLI reference lists
  a `version` command, so the spelling is documented rather than guessed — but it
  has never been executed on this machine, and no page states whether it writes
  anything under `$HOME`. `setup.sh` therefore skips it entirely under
  `--dry-run` and tolerates a non-zero exit outside it, so a wrong spelling or a
  state-writing probe degrades to the string "installed" rather than breaking
  setup or the dry-run no-writes contract.

One property is deliberate rather than unverified, and is easy to mistake for a
bug: **`--dry-run` still requires a valid key file.** It performs the live
`GET /sources` — that call is how it resolves `repos: all` and how it reports a
repository that is not connected — and only the session-creating `POST` is
suppressed. So a dry run refuses on a missing, group-readable, or malformed key
exactly as a real run does. What `--dry-run` guarantees is that it creates no
session and leaves the state directory byte-identical, not that it works without
a credential.

### The first live dispatch (operator step)

Create a key in the Jules web app under Settings, connect the repositories to
Jules, then:

```bash
install -d -m 700 ~/.config/jules
install -m 600 /dev/null ~/.config/jules/api-key   # paste the key into it

# 1. Resolve-only: prints every routine and repository it would dispatch,
#    writes nothing, creates nothing.
claude/scripts/jules-dispatch.sh --dry-run

# 2. One routine, one repository, for real — the smallest live surface.
claude/scripts/jules-dispatch.sh --routine doc-drift-fixer --repo jckeen/dotfiles

# 3. Record what the run resolved, then enable the timer.
jq . ~/.local/state/jules/dispatch.jsonl
bash claude/systemd/install.sh
```

Step 2's ledger line carries the actual `source` string and session URL. With
the first routine pull request in hand, record the bot's author login and whether
the branch is same-repo or a fork, move this ADR to **Accepted**, and hand the
custodian changes over.

## Handoffs

These belong to the private `claude-memory` repository and are not in this
change:

- **Custodian trusted-bot allowlist** — there is no login to allowlist. The PR
  author is the connecting account and the commit author is an unsigned
  `google-labs-jules[bot]`, both reproducible by any contributor, so an
  author-keyed allowlist would let an unrelated PR impersonate a routine. Trust
  a routine PR only when the Jules API confirms it: the PR URL appears in
  `outputs[].pullRequest` of a session whose id is in the dispatcher's ledger.
  The dispatcher should publish that reconciliation (a `--reconcile` pass or a
  ledger field) so the custodian never re-derives provenance from PR text.
- **Routine-PR classifier** — the `jules-routine:*` label is not applied by the
  platform (#479), and the `jules-` branch prefix and body footer are hints for
  triage only, never a trust key. Classification follows the same API-confirmed
  session → PR mapping as the allowlist above. The narrow auto-merge gate
  does not change: docs-only, lockfile, or version-only diffs, with CI green and
  no Codex `CHANGES_REQUESTED`. A code-changing routine PR waits for the
  conductor, and the Codex bot review remains the cross-family check.

## Alternatives considered

- **GitHub Actions instead of a local timer.** Rejected: the API key would have
  to become a repository secret, which puts a credential that can open pull
  requests across every connected repository into a surface any workflow change
  can reach. The timer keeps it in one 0600 file on one machine.
- **The `jules` CLI instead of REST.** Rejected for dispatch: undocumented
  credential storage cannot be reconciled with `ProtectHome=read-only`. The CLI
  is still installed, because `jules remote list` and `jules remote pull` are
  the interactive way into a session.
- **A `check-jules.sh` health checker.** Rejected: the existing `check-*.sh`
  scripts audit managed symlinks and local-state boundaries, and Jules has
  neither. Presence is reported by `setup.sh` and the capability contract.
- **Routines as code rather than prompts.** Rejected: the value is in the
  judgement about what qualifies, which is exactly what a prompt expresses and a
  script cannot. The contract that must be mechanical — limits, labels,
  acceptance — is the frontmatter, and that *is* enforced by code.
