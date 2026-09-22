# Claude Autonomous Scripts

Run Claude Code headless on your repos — scheduled or on-demand.

## Quick Start

```bash
# Health check a single repo (read-only, totally safe)
./health-check.sh ~/dev/atlas

# Health check all repos overnight
./overnight.sh

# Deep overnight run (health + tests + issue fixes)
./overnight.sh --deep
```

## Scripts

| Script | What it does | Safety tier | Changes files? |
|--------|-------------|-------------|----------------|
| `health-check.sh` | Repo briefing + dependency audit | Read-only | No |
| `full-review.sh` | Full 3-phase agent pack review | Read-only | No |
| `test-coverage.sh` | Writes tests for uncovered code | Fix (edit + test) | Yes — review with `git diff` |
| `fix-issues.sh` | Picks up GitHub issues, creates fix branches | Commit (edit + commit) | Yes — review branches |
| `overnight.sh` | Orchestrates all of the above across repos | Varies | Depends on flags |
| `review-and-push.sh` | Classifies the committed delta, runs the gate for the **required review lane** (ADR-0008), validates the receipt, and pushes the current branch. Step 2's test command is `REVIEW_TEST_CMD` (empty means unset; whitespace-only is refused, like an empty `.review-test`, rather than reported as a passing run — #519), else the repo-root `.review-test` line, else a sniffed framework — a bun lockfile or `bunfig.toml` runs a declared `package.json` `scripts.test` as `bun run test` and only a bun project declaring none gets `bun test`, with `npm test` the fallback for a package.json and no bun; with none of those it prints a loud banner and records `tests: skipped`, because the receipt attests to a review and never to a test run (#490). The declared command runs under `bash -o pipefail -c` — not `eval`, so it cannot reach the wrapper's own variables, and with `pipefail` because a child shell does not inherit it and `<suite> \| tee log` would otherwise mask a red suite. Tests: `tests/review-and-push.test.sh` | Artifact review + push | Only pushes after validation |
| `run-tests.sh` | Runs this repo's own suites — the same enumeration `check-tests-wired.sh` asserts is wired into CI (`tests/*.test.sh`, `tests/*.test.py`), each suite named by its filename without the `.test.*` suffix; two files deriving one name (`foo.test.sh` beside `foo.test.py`) fail discovery in every mode, naming both, since a name must select exactly one file (#518). `--list` prints the selected names and runs nothing (so `--list --changed` is how the mapping is inspected); positional names run a subset; `--changed [--base <ref>]` runs only the suites this branch's diff can affect, applying every mapping rule to each changed path: it *is* a suite's test file, it is named inside one (so a suite that imports another's fixtures is selected too), it is named inside any tracked non-test file (followed transitively to a fixpoint, so a shared library like `gate-lib.sh` or the root `lib-symlinks.sh` reaches its callers' callers' suites), or its stem names one; `--verbose` streams every suite instead of only the failures. Selecting nothing is never a green run: an unknown name and an empty `tests/` fail, and an unresolvable base, an empty diff, or *any single* changed path that reaches no suite — a deleted or renamed suite included — widens the run to every suite, since one mappable path must not speak for an unmapped sibling. The walk costs a few seconds per changed path, so a wide diff spends ~a minute deciding before it runs anything. The `*.property.test.py` suites are reported as a named SKIP when Hypothesis is absent — they fail loudly by design, which is right for CI and would make every fresh clone red. Checkers are not run here; CI runs them beside the suites. `.review-test` points `review-and-push.sh` at this script. Tests: `tests/run-tests.test.sh` | Read-only (runs the suites) | No |
| `sync-plugins.sh` | Installs plugins listed in `$DOTFILES_DIR/claude/plugins.txt` that are not yet installed; idempotent. Installs both manifest sections — `[global]` and `[per-project]` (issue #214); enablement scoping lives in settings.json `enabledPlugins` and is checked by `PluginDriftCheck.hook.ts`. Installs are user-scope, so both this script's fast path and that hook count user-scope installs only and ignore `--scope project` plugins. Auto-run by `cc` at launch (pre-exec, so installs apply to the session being started); fast-path exits silently when there's no drift. Tests: `tests/plugin-drift.test.sh` (fast path + drift hook) | Install (calls `claude plugin install`) | No file edits — updates plugin state |
| `check-doc-truth.sh` | Portable doc-contract checker (ADR 0005); asserts every tracked `*.md` is declared in a tier, HISTORICAL docs carry a point-in-time marker, relative links in LIVING/GENERATED docs resolve, and BANNED patterns are absent from their scoped tiers. Vendored into other repos by `/drift-sweep`, so unlike the rest of this directory it holds to a bash 3.2 floor — the macOS system bash (#424); it runs in the `doc-truth` job, a required status check, and the `doc-truth (bash 3.2)` job runs it and its tests again against a real 3.2.57. Tests: `tests/doc-truth.test.sh` | Read-only | No |
| `gen-instruction-files.sh` | Builds the global instruction files — its own `TARGET` map is the authoritative list, currently the three local ones plus the root `AGENTS.md` cloud-agent brief — from the canonical sources in `agents/canon/` (ADR 0007) — shared rule blocks in `CANON.md`, per-tool voice in `fragments/`. `--check` verifies the committed artifacts are byte-current (run in CI via `check-agent-parity.sh`). Tests: `tests/agent-parity.test.sh` | Build (writes the three generated files) | Yes — regenerates committed artifacts |
| `gen-agentpack.sh` | Generates `claude/AGENTPACK.yaml` (the AgentPack manifest) from the live frontmatter of `claude/skills/*/SKILL.md` and `claude/agents/*.md` plus the hand-maintained fragment `claude/agentpack-meta.json`, so the manifest can't drift from the source (issue #207). `--check` (run in CI) exits 1 if the committed manifest is stale | Generate | Yes — rewrites `claude/AGENTPACK.yaml` |
| `jules-dispatch.sh` | Dispatches the routine catalog (`agents/routines/*.md`) to Jules over its REST API, one session per routine per repository per day (ADR 0009). Reads the API key from a file it validates itself (regular file, mode 0600, non-empty, at least 20 characters) and hands it to `curl` through a config file on stdin, so the key never reaches argv or a log. The variable holding it is unset before assignment, so an inherited export of the same name cannot carry it into a child process's environment. `curl` is invoked with `-q` first, so a `location` or `trace` line in a `~/.curlrc` cannot make the key follow a redirect or land in a trace file. The API host is a constant in the script, never read from configuration, and `curl` runs without `-L`. Resolves each repository's `source` from `GET /sources` — never constructs one — following `nextPageToken` so a repository past the first page is not mistaken for an unconnected one, and skips a repository that really is absent. Each pair's starting branch — `JULES_STARTING_BRANCH`, else the source's `githubRepo.defaultBranch.displayName` — is resolved while eligibility is decided, so a pair with neither is refused identically by a dry run and a live one and spends no slot of the daily cap. The header it injects above each routine's body states the per-run limits, the required PR label, and the conventional commit-subject types `check-commit-format.sh` enforces, since a subject outside that set makes the resulting pull request unmergeable. The ledger is validated once at startup, from the main shell where a refusal can stop the run — every query of it happens inside a command substitution, where an error would otherwise be swallowed. Idempotent per calendar day via a write-ahead ledger at `~/.local/state/jules/dispatch.jsonl` — a record is written before the request and upgraded after it, so a session created by a request that then timed out is never invisible; unresolved attempts are reported for reconciliation against `GET /sessions` and are not retried that day, and a `schedule: weekly` routine is additionally held back while its last dispatch for that repository is inside a seven-day window. A run holds an `flock` on a file in the state dir, so a manual invocation overlapping the timer is a no-op instead of a second dispatch — and because the kernel releases an `flock` when the holder dies, there is no stale lock to reclaim. Where `flock(1)` is absent it falls back to an atomic lock directory rather than running unserialized, and names the path to remove if a run was killed. A run that crosses UTC midnight stops rather than recording against the previous day, and a dispatch is not even started when less of the day remains than a request may take — a session created on one day and recorded against another would be dispatched again by the next run without counting against its cap. A failed ledger append aborts the run rather than continuing to create sessions nothing has recorded. When more pairs are eligible than the cap allows, the least-recently-dispatched pair goes first, so the cap defers work to a later day instead of starving the tail of the catalog permanently. `JULES_DAILY_CAP` (default 40) bounds the spend. Every run ends by settling what earlier ones created, and `--reconcile` runs the same pass on its own: for each `created` session in the ledger it reads `GET /sessions/{id}`, closes an open pull request the session opened with zero changed files with a one-line comment, applies `jules-routine:<routine>` (creating the label, which no repository carries until a routine PR lands there) and rewrites a title the commit-format check would reject to `chore(<routine>): …`, then records the outcome as one `"kind":"reconcile"` ledger line per settled session, carrying a `prs` array — the only API-confirmed provenance a routine PR has, and one line because the record *is* the marker that the session is done. The title governs what a squash merge lands on `main`, not the required commit-format check, which lints the subjects of the commits the PR adds: a routine PR whose bot commit subject is non-conventional stays blocked, so the pass counts it, names it in the log, and records `commit_subjects_ok: false` rather than reporting the PR as fully settled — rewriting someone else's branch is not the dispatcher's to do, which is why the conventional-subject requirement is injected into every prompt up front. That field is tri-state, because ADR-0009's custodian handoff reads the reconcile record as provenance: `true` only where the pass listed the commits of *every* pull request of the session and found nothing rejected, `false` where it listed them and one is rejected, and JSON `null` where any of them went unread (a pull request already closed or merged, an empty one it closed, a refused URL, a FAILED session, a session with no pull request) — a boolean meaning "ok" *or* "never looked" cannot be keyed on. The pull-request URL the API hands back is parsed strictly and must name `github.com` over https and the same repository the session was dispatched to, so a URL from a remote service can never become a write pointed at someone else's repository; it is matched against the whole field, one JSON value at a time and carried out of `jq` with a sentinel byte appended, so neither an embedded newline nor a trailing one (which command substitution would strip) can turn a refused value into an actionable URL — and a NUL, which no sentinel can make the shell carry, is caught inside `jq` and replaced before it reaches the pattern. Every gh write is checked rather than assumed. A session with a terminal record is skipped without an API call and one that is still running is skipped without a record, so the pass is idempotent and never freezes an outcome early. Because a reconcile record carries the same date, routine, and repository as a dispatch, every spend query filters on the record kind — otherwise closing an empty pull request would count against the daily cap and suppress the routine it belongs to. `--dry-run` resolves and prints without writing anything, in both modes; `--report [--days N]` tallies routine PRs per week from `gh` and states in the report body when a fetch hit `JULES_REPORT_LIMIT` or a query failed, so a partial merge rate cannot look authoritative to whoever reads it; `--post` comments the table on the tracker issue. Fired daily by `claude/systemd/jules-dispatch.timer`. Tests: `tests/jules-dispatch.test.sh` | Dispatch (creates cloud sessions that open PRs) | No local edits — creates remote sessions |
| `check-tests-wired.sh` | Fails when a test file under `claude/scripts/tests/` or `codex/tests/` is run by no workflow: every enumerated path must appear in `ci.yml` or `smoke-install.yml` with YAML comments stripped, or in a test file those workflows already run (one level of transitivity). `OPT_OUT` lists the tests that cannot run in CI, each with its reason. Runs in the `checks` shards. Tests: `tests/check-tests-wired.test.sh` | Read-only | No |
| `check-agent-parity.sh` | Two guards on the generated instruction files (ADR 0007). Concept parity: every canonical rule in its own `RULES` list must be present in all of `claude/CLAUDE.md`, `codex/AGENTS.md`, and `antigravity/GEMINI.md`, matched by a rule-shaped regex rather than a bare keyword, so three different voices can express the same rule. Currency: it runs `gen-instruction-files.sh --check`, so a hand-edit to any generated target fails the build. Runs in the `checks` shards, step `agent-parity (self-test + checker)`. Tests: `tests/agent-parity.test.sh` | Read-only | No |
| `check-skill-parity.sh` | Three skill-layer drift guards: every `N slash commands` / `N-agent` / `N specialized` claim in the root `README.md` must match the real number of dirs under `claude/skills/` and files under `claude/agents/` (every occurrence, not the first); the Claude and shared-agent changelog/handoff skills must emit the same section headings, or cross-tool session resume breaks; and `CLAUDE-GUIDE.md`'s slash-command table must list exactly the shipped skill dirs. Also invokes `check-workflow-invariants.py`. Runs in the `checks` shards, step `skill-parity (self-test + checker)`. Tests: `tests/skill-parity.test.sh` | Read-only | No |
| `check-workflow-invariants.py` | Asserts the declared semantic anchors — small, reviewable regexes rather than whole-file hashes — in each runtime's shared workflow body, and holds that frontmatter and HTML comments cannot satisfy an instruction. Reaches CI through `check-skill-parity.sh`, which invokes it; its own fixtures run in the `checks` shards, step `capability and workflow contracts`. Tests: `tests/workflow-invariants.test.py` | Read-only | No |
| `check-capability-parity.py` | Validates the capability dispositions and read-only probes without launching a runtime or a hook; `--live-home` additionally reports installed-provider drift and unmodeled skill directories as advisory JSON. Presence or configuration is never taken as proof of runtime execution or hook trust. Runs in the `checks` shards, step `capability and workflow contracts`. Tests: `tests/capability-parity.test.py` | Read-only | No |
| `check-doc-refs.sh` | Fails when a tracked Markdown doc references a hook or skill *path* that is not on disk: `<Word>.hook.ts` / `<Word>.hook.sh` must exist under `claude/hooks/`, and a `(claude\|codex\|agents\|antigravity)/skills/<name>/` form must be a real directory. Scope is deliberately narrow — a bare slash-command like `/clear` is not treated as a skill path, since many are Claude built-ins rather than repo dirs. Runs in the `checks` shards, step `doc-refs (self-test + checker)`. Tests: `tests/doc-refs.test.sh` | Read-only | No |
| `check-no-personal-data.sh` | Public-repo leak guard: fails when a *tracked* file carries a machine-specific home path embedding a real local username (`/home/<name>/…`, `/Users/<name>/…`, `C:\Users\<name>\…`). The backstop for a stray `git config --global` write, which lands in the tracked `.gitconfig` — real paths belong in the untracked `.gitconfig.local`. Runs in the `checks` shards, step `no-personal-data (self-test + checker)`. Tests: `tests/no-personal-data.test.sh` | Read-only | No |
| `check-install-integrity.sh` | Two static fresh-clone guards, promoted from discipline into CI; no install is performed. Exec bits: every tracked `*.sh` with a shebang must be mode 100755 in the git index, because `core.fileMode=false` locally lets a 100644 script be committed and any `[ -x … ]` guard then skips it silently. Marketplace arms: every `@marketplace` in `claude/plugins.txt` needs a matching registration arm in `setup.sh`. Runs in the `checks` shards, step `install-integrity (self-test + checker)`. Tests: `tests/install-integrity.test.sh` | Read-only | No |
| `check-commit-format.sh` | Conventional-commit lint over the commits a pull request adds — the backstop the `conventional-commit.sh` hook cannot be, since that binds only inside a Claude session and not to a commit made with `--no-verify` or outside Claude. Validates each subject as `type(scope)?!?: description` against the enforced type set; merge commits and revert auto-messages are skipped. Runs in the `commit-format` job on pull requests only, step `Lint PR commit messages (conventional commits)`. Tests: `tests/commit-format.test.sh` | Read-only | No |
| `check-hooks-wired.sh` | Warns when a hook file under `claude/hooks/` is not named among the live `~/.claude/settings.json` hook commands — the wiring lives in the private `claude-memory` repo, which is how every documented hook once went inert with nothing to catch it. Advisory: exit 0 unless `--strict`. Not run in CI, which cannot see private settings; it is a local guard, run at every `cc` launch via `check-claude.sh` | Read-only | No |
| `check-deployed-orphans.sh` | Sweeps the *deployed* `~/.claude` for regular files left behind by a decommissioned integration — the debris `check-claude.sh`'s symlink audit never looks at (ADR 0002 removed PAI, yet its hook framework survived as regular files). `--strict` turns the report into a failure. The checker itself is not run in CI, which has no live `~/.claude`; run it by hand. Its fixtures point it at throwaway dirs and do run, in the `checks` shards, step `deployed-orphans (self-test)`. Tests: `tests/deployed-orphans.test.sh` | Read-only | No |

### Test suites

Every suite in `tests/` is wired into `.github/workflows/ci.yml`, where the
`checks` context is an aggregator over four parallel shards
(`checks (receipts|gates|runtime|checkers)`) grouped so the four slowest suites
never queue behind each other (#472). Locally, `run-tests.sh` runs the same
enumeration — `run-tests.sh --list`, `run-tests.sh <name>…`, or
`run-tests.sh --changed` — and `.review-test` points `review-and-push.sh` at it.
Beyond the per-script suites named in the table above:

| Suite | What it pins |
| --- | --- |
| `tests/review-multipart.property.test.py` | Hypothesis properties for the fragment splitter: fragments rejoin to the original, none exceeds the UTF-8 byte bound, none is empty, each is a contiguous byte slice of the packet, and a bound too small for one character fails closed |
| `tests/review-receipt.property.test.py` | Hypothesis properties for `classify_tier` against an independently written oracle — a risk token or glob, an active file mode, a diff over either captured ceiling (lines or bytes), a policy missing the byte ceiling, or an unenumerable path list can never reach tier 1 — plus single-leaf receipt tampering refused by `check` |
| `tests/setup-fuzz-layouts.test.sh` | Seeded fuzzer over `setup.sh --yes --dry-run`: pseudo-random `$HOME` layouts (`.bashrc`, `.gitconfig`, `.claude`, `~/.agents/skills`, dangling links, a bun stub, `~/.codex`) each asserted byte-identical before and after. `SEED` reproduces a run and is printed on failure; `LAYOUTS` sets the count |
| `tests/lib-snapshot.sh` | Not a suite — the shared full-fidelity directory snapshot (every path, file hash, and symlink target) sourced by `setup-dry-run.test.sh` and `setup-fuzz-layouts.test.sh` so both compare identically |

Hypothesis is pinned in `tests/requirements-property.txt` and installed by the
`property tests` CI step. The property suites import it unconditionally and exit
with the install command rather than skipping, so a missing dependency cannot
turn into silent zero coverage.

## Large review requests

The Codex gate sends oversized requests as contiguous direct-input parts in one
native read-only session. Parts are bounded by UTF-8 bytes rather than
characters and never split a character, so a non-ASCII request cannot produce a
fragment several times the intended size. Intermediate acknowledgments cannot
authorize a push.
The helper `review-multipart.py` verifies native persisted inputs, rejects
compaction, and checks the observed model window against the native bundled
catalog. Larger context is scoped to the same model's supported capacity. Missing
or changed history, unsupported CLI metadata, and incomplete reviews fail closed.
The normal setup links the helper alongside the gate; install them together.
Gate or helper changes require independent review outside the configured gates.

## The Morning Workflow

After an overnight run, you don't read every diff. You run:

```bash
# Review and push one repo (prompts before pushing)
./review-and-push.sh ~/dev/atlas

# Review and push all repos
for repo in ~/dev/atlas ~/dev/stringer ~/dev/smss; do
  ./review-and-push.sh "$repo"
done

# Auto-push after tests, the required review gate, and receipt validation
./review-and-push.sh ~/dev/atlas --auto-push
```

What `review-and-push.sh` does:

1. Requires a clean non-default branch, then pins the current commit.
2. Runs the declared test command and stops on failure. The command comes from
   `REVIEW_TEST_CMD`, else a `.review-test` line at the repo root, else a
   sniffed framework; when nothing declares one the step says so loudly and
   prints `tests: skipped` so a PR body cannot imply the receipt covers tests
   (#490). In this repo `.review-test` runs `claude/scripts/run-tests.sh`.
3. Classifies the committed artifact with `review-receipt.py lane` and runs the
   gate for the **required lane** with `--require --committed` (ADR-0008). A
   tier-1 diff dispatches no gate: the wrapper records the exemption receipt
   itself, so a docs-only push never depends on a reviewer's size limits (#482).
4. Prompts for confirmation, unless `--auto-push` was selected.
5. Validates the receipt after confirmation, immediately before push, naming the
   lane it dispatched. That enforces the diff's lane requirement and also
   requires the review this run performed to still be approved.
6. Pushes the reviewed commit to the current branch with an explicit refspec.

Blocking findings, failed reviewer execution, and missing or stale receipts
prevent pushing. Gate exit 0 alone does not prove a review completed: explicit
tier/no-diff exemptions are reported separately from successful reviews.
Changing the artifact invalidates approval and requires affected verification
and review again. The wrapper requires the pinned commit to remain current
through tests, review, and confirmation. Staged, unstaged, and untracked changes
stop the wrapper before testing and at each later checkpoint, so verification
cannot rely on uncommitted fixes. Index flags that hide tracked changes also
require separate inspection before shipping. Where `core.fileMode` is `false`,
executable-bit changes never reach `git status`, so tracked file modes are
compared against the index directly and a mismatch stops the wrapper the same
way; record the intended mode with `git update-index --chmod=+x` (or `-x`)
before shipping. Inherited repository, index, object, and configuration routing
(`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG*`, and the rest of
that family) is refused outright before any repository is inspected, because a
routed checkout can answer every checkpoint while the tests run somewhere else.
Ordinary ignored dependencies and
test artifacts remain supported. `--auto-push` removes the prompt, not the checks. The pre-push
hook validates each pushed ref's commit receipt independently of whether the
secret scanner runs. For a PR explicitly targeting a nondefault base, run the
gate and receipt check with `--base <ref>`, then use
`REVIEW_RECEIPT_BASE=<ref> git push ...` for that push. The hook otherwise
requires the repository's default base. The setting selects the expected
base; it does not bypass artifact validation.
The selected remote must have exactly one nonempty configured push URL, or
one nonempty configured fetch URL when no push URL is set. Empty or multiple
values are rejected even when Git normalizes them to a single destination.
The wrapper rejects resolved destinations that name another remote or would
be transformed by another URL rewrite; use a direct destination in that case.
It requires Git protocol v2 with server-option support to inspect branch aliases
and rejects advertised symbolic destination refs. An unadvertised destination
must have no resolved object when the push occurs, so it cannot overwrite an
existing branch. Git cannot distinguish an absent ref from a hidden dangling
alias: such an alias may create its missing nondefault target. These checks
cannot guard server-side ref changes after validation.
It selects the branch's `pushRemote`, then `remote.pushDefault`, then the
branch's fetch remote, falling back to `origin` when none is configured.
Committed scope keeps unrelated working changes out of the push review even
when the fetch upstream is current and the selected push fork is behind.
Dirty instruction surfaces still block committed review. An explicit
`--uncommitted` review includes ignored instruction files in its review target.
It covers both staged changes and later workspace edits.
Text diffs preserve physical lines, including embedded control characters,
and quote filenames in their headers.
Instruction coverage includes shared skill bundles and canonical sources under
`agents/skills/` and `agents/canon/`, Claude skill and agent sources under
`claude/skills/` and `claude/agents/`, and the Claude AgentPack manifest,
metadata, and policy files. Source ancestor entries (`agents`, `claude`, and
`claude/scripts`) and the Codex output schema are also review inputs, including
when modified outside the committed delta. Ignored references inside these bundles remain
bound to the receipt; ordinary documentation outside them keeps its usual policy.
Instruction checks recognize Git-managed CRLF text conversion for regular files
and sparse checkout omissions while retaining raw workspace hashes.
Automatic text conversion respects Git's binary classification; explicitly
forced text conversion retains Git's configured behavior.
Known ignored agent runtime credentials and state are excluded from instruction
discovery. Named instruction files inside runtime directories remain covered.
A directory Git refuses to descend into is reported as one trailing-slash entry,
and a hand-made `.git` earns that treatment, so every such boundary in the
ignored sweep is inspected rather than judged by its own name (#496): one of this
repository's own registered worktrees is dropped, a real repository is allowed
only when its own listing — tracked and untracked, without honouring its
`.gitignore` — holds no instruction path, no further boundary and **no gitlink**,
and anything else refuses. The gitlink case is why that listing is read with
`--stage`: a populated tracked submodule inside such a repository is printed as
one bare path with no trailing slash and its contents are never enumerated, so
only its mode `160000` distinguishes a whole unchecked tree from an ordinary
file. A path listed as a file where the working tree holds a directory is refused
on the same grounds. A visible (non-ignored) boundary keeps failing closed in the
snapshot itself.
Recognized runtime artifacts explicitly included in the review target block
review before their contents can reach a reviewer. These filename and directory
rules are not a general secret scanner.

Receipts live in the worktree's Git metadata, outside tracked files. They are
local evidence, not signatures against the filesystem owner. The checker
uses artifact identity and attempt tokens for freshness; clock adjustments
do not invalidate a completed review. It requires the outgoing commit to be
that worktree's current HEAD and rejects submodules and non-UTF-8 review content.
An unchanged canonical instruction link such as `AGENTS.md -> CLAUDE.md` is
supported when it takes one relative hop to a tracked regular instruction file
inside the repository. Link and target must match the review base, HEAD, index
and working tree; the receipt binds both identities and contents. Absolute,
external, chained, dangling, sparse, directory or untracked targets are unsupported.
This includes directory links that redirect installed skill or gate sources;
an instruction-diff override does not bypass snapshot restrictions.
Changing a canonical link or target requires separate instruction review until
the gate can follow aliases in its self-review policy. Installed global links
outside the repository are unaffected. Ordinary leaf symlinks remain
reviewable as link text. Review another branch in its own worktree; resolve
unsupported content explicitly before shipping.
Reviewer dispatch information and observed identity are recorded separately.
The configured docs-only size limit is captured with the review policy and
checked again when its exemption is completed or used for shipping.
Classification and exemption validation use the same policy implementation.
Passive filename filters retain instruction files, executable files, and
symlinks, including staged executable modes when `core.filemode` is disabled.
Documentation exemptions require nonexecutable regular files with
recognized documentation names.
No-diff exemptions also validate the changed paths; an empty patch cannot
exempt an active path. Review path selection uses a fixed literal policy,
and repository and worktree paths retain their exact whitespace.

## Safety Tiers

### Codex review runtime

The Codex gate honors `CODEX_GATE_BIN` when explicitly set. Otherwise it probes
`~/.codex/packages/standalone/current/bin/codex`, then the root-level
`~/.codex/packages/standalone/current/codex`, before falling back to `PATH`.
Set `CODEX_GATE_BIN=codex` to deliberately select the
executable on `PATH`. The receipt records the executable used by that run.

The gate runs Codex in the foreground and validates its exit status, structured
result, and artifact receipt. Native Codex handles terminal cancellation and
its tool processes. Send cancellation to the foreground job; a signal sent
only to the Bash wrapper may wait until the current command returns. Observed
cancellation invalidates approval, including during receipt creation.

The gate provides no hard execution deadline or detached-process containment.
Unattended jobs that require those guarantees must obtain them from their
execution host. An explicitly set `CODEX_GATE_TIMEOUT` is rejected so it cannot
silently imply a deadline. Offline fixtures run in required Linux CI and the
[native macOS portability workflow](../../.github/workflows/smoke-install.yml).
Failures report a diagnostic hint and a private temporary log path without
printing raw reviewer stderr, which may contain reviewed content. Inspect that
log when needed and keep it out of repositories.

### Review lanes (ADR-0008)

One classifier names the lane, and the receipt carries the answer, so the lane
requirement is enforced at the push boundary rather than by whichever gate
someone chose to run.

| Subcommand | What it does |
|---|---|
| `review-receipt.py lane --repo . --scope committed [--base <ref>]` | Read-only. Prints `{tier, reason, risk_paths, required_lane}` and **mints nothing** — no receipt, no attempt marker, no run directory, so asking cannot invalidate an approval already in hand |
| `review-receipt.py check --repo . --head <sha> [--base <ref>]` | Validates shipping evidence. Recomputes the classification on the re-captured patch, refuses a mismatch, and refuses a receipt whose lane ranks below the requirement. Checking by hand, run it with **no** `--reviewer` — it enforces the lane requirement without your needing to know which lane ran. Naming a lane additionally requires that lane's own receipt to be current, which is why `review-and-push.sh` names the lane it dispatched |
| `review-receipt.py stats --repo . [--since-days N]` | Lane × outcome counts from `<git-dir>/review-receipts/ledger.jsonl`, plus how often the Antigravity lane degraded to Codex |

`required_lane` is one of `any` (tier-1 docs diff — an exemption receipt from
either lane ships it, whether a gate's tier valve or `review-and-push.sh`
recorded it), `antigravity` (ordinary tier-2 work — the default lane), or
`codex` (a risk surface, an empty changed-path list, or a classification the
helper could not compute). Lanes rank `any < antigravity < codex`. Size alone
never escalates the lane: a large ordinary diff is still ordinary.

Tier 1 has two captured size ceilings, both in the receipt's `policy` so the
two lanes and `check` share one answer (#494): `tier1_max_lines` (default 200,
override `GATE_TIER1_MAX_LINES`) and `tier1_max_bytes` (default 65536, **no
environment override on purpose** — `review-and-push.sh` classifies with its own
`lane` call before any gate runs, so a knob only the gates honoured would make
the wrapper choose the tier-1 skip and then refuse to record the exemption it had
just chosen; adding one means forwarding it there in the same change). The byte
ceiling exists because the line ceiling is not
a size limit — one 200,000-byte line is a 1-line diff — and it sits far below
the Antigravity lane's measured 185,000-byte input window so that a diff the
valve waves through would still be dispatchable there. A docs diff above either
ceiling is **escalated to an ordinary review**, not refused, and a receipt whose
policy is missing or unreadable classifies tier 2 requiring `codex`. Both gates
therefore check their own size caps and their reviewer's availability only
*after* the tier valve: those are facts about a dispatch, and a tier-1 diff has
none.

On a codex-required diff the Antigravity gate still runs and still mints its
receipt, announcing itself as a **supplementary** lane — an independent-lineage
second opinion, not shipping evidence. Receipts are version 2; a version-1
receipt carries no lane requirement and is rejected outright, so the first push
after this landed needs a fresh gate run.

**One artifact holds at most one receipt.** `begin` retires *every* lane's
receipt and attempt token, not only its own, so the receipt that survives always
belongs to the most recently started review. Both gates exit 2 on blocking
findings **without** recording anything, so a blocked review leaves no approval
for `check` to accept — an older receipt from the other lane cannot ship a diff
the newest verdict rejected. Re-run the lane and approve and the push goes
through as usual. Two consequences: a review already in flight in the other lane
can no longer record its outcome once a newer one starts, and a supplementary
second opinion belongs **before** the shipping review, because running it
afterwards retires the shipping receipt. A gate's cancellation trap uses
`invalidate`, which stays own-lane: a review that never started cannot reach a
verdict, so it must not cost an untouched approval.

That transition is serialized by an exclusive `flock` on
`<git-dir>/review-receipts/.lock`, held by every writer of the shared attempt and
receipt state — `begin`, `complete`'s deciding attempt check and receipt write,
and `invalidate`. Two gates starting at once would otherwise interleave their
cross-lane invalidations and leave both lanes' attempt tokens live. `check` is
deliberately lock-free: it re-asserts the attempt token on both sides of the
artifact capture, so a transition landing mid-check can only make it refuse, and a
slow check never blocks a gate.

**Known limitation: a degraded lane still costs the other lane's approval.** A
gate that exits 3 — agy missing, a diff above its byte cap, an unverifiable model
pin — has already run `begin`, so the other lane's receipt is gone even though a
degraded lane is not a verdict. Recovery is to re-run the required gate. The
refusal is deliberately conservative: nothing distinguishes "could not run" from
"ran and blocked" at the push boundary without trusting the gate that failed. See
#499 for the retraction design that would avoid the cost.

The ledger is written by `complete` (0600, append-only) and is **never read by
`check`**: a forged ledger cannot approve a push and an unwritable one cannot
block one. The dotfiles risk list is deliberately unnarrowed, so most diffs in
*this* repository still require Codex; read `stats` before concluding anything
about lane cost.
### Low findings, filed issues, and `.codex-review-ignore`

Low-severity findings never block a push; the gate files them as GitHub issues
so they are not lost. Dedup is keyed on the **location** — the file a finding
points at — not on its title, because Codex rewords titles between runs and a
title-keyed dedup once filed one fixture finding sixteen times. Every filed
issue carries a hidden `<!-- codex-gate-loc:<owner/repo>:<file> -->` marker;
before filing, the gate fetches the repo's `codex-review` issues once and
matches on that marker:

| Existing issue for that file | What the gate does |
|------|------|
| Open | Adds one comment naming the branch, sha, and the reworded title |
| Closed as *not planned* | Prints `accepted (#N), skipping` and files nothing |
| Closed as *completed* | Files a fresh issue — the fix regressed |
| None | Files a new issue, marker included |

**Closing an issue as *not planned* is the suppression mechanism.** Accepting a
finding needs no config file: close it that way and the gate stops re-filing
that location. A failed prefetch files nothing at all, since filing without the
index is the duplicate noise this replaced. Issues are fetched and created
through plain REST, never `gh issue list --search` or `gh issue create`, whose
GraphQL backend egress-restricted sandboxes block; `harvest-codex-comments.sh`
shares that one prefetch via `gate-lib.sh`.

A repo may also declare path globs in a root `.codex-review-ignore` — one glob
per line, `#` comments, `*` spanning `/`:

```
claude/scripts/tests/*
agents/routines/*
AGENTS.md
```

Those paths are directive **by design**: gate fixtures embed injected verdicts,
prompt-injection payloads, and synthetic credential markers, and Jules routine
prompts plus the generated root `AGENTS.md` are instructions for a cloud agent
(ADR-0009), so a reviewer flagging them is reporting the fixture or the prompt
rather than a defect. The exemption is **by form, not by effect** (#484): the
reviewer is told not to report an instruction-like string there as a finding
*about this repository's instructions*, but a directive whose effect would be to
bypass a limit, skip or disable a check/review/gate/test, weaken a guard, or
expose credentials is still reported — the routine prompts are live prompts, so
adding a glob must never retire the prompt-injection check for what runs under
it. The globs only
steer the reviewer — matching paths **stay in the review scope** and are still
reviewed for real bugs, and instruction-like text anywhere else stays
suspicious. The file is repo content, so it is parsed as bounded untrusted data
(200 lines, 256 bytes per line; control characters or non-UTF-8 reject the
whole file) and fenced like the diff. A rejected file warns and the review
proceeds without it. Because the file steers what the reviewer reports, it
is itself a reviewer-instruction surface: a diff that touches it trips the
self-review guard (independent review, then the documented override), a
committed review reads the copy in the reviewed commit rather than the
working tree, and a local copy that differs from it is a dirty instruction
surface that blocks the review.

### Review of reviewer instructions and gates

The Codex and Antigravity gates refuse changes to their own instruction
surfaces, the shared skill bundles installed from `agents/skills`, and the
shared review machinery before dispatch or exemptions. Supporting files in
those installed skill bundles need the same independent review as `SKILL.md`.
Use independent review before setting a scoped
`CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1` or
`ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1` override. Changes to shared skills
or machinery require review outside both gates, because both runtimes load
those sources.
An override records no independent approval by itself; retain the actual
review evidence and validate the final artifact receipt before shipping.

### Claude script tiers

Each script uses scoped `--allowedTools` to limit what Claude can do:

| Tier | Can do | Can't do |
|------|--------|----------|
| **TIER_READONLY** | Read files, search, git status/log/diff | Edit, write, run arbitrary commands |
| **TIER_FIX** | Above + edit + write files + run tests | Commit, push |
| **TIER_COMMIT** | Above + git add/commit/branch/checkout | Push, run arbitrary commands |

`review-and-push.sh` runs the required lane's gate and validates its artifact
receipt, then performs `git push` from bash after the confirmation and evidence
checks. The tiers above describe scripts that invoke Claude through `common.sh`.

## Full Auto Mode

If you trust a script to run completely unattended:

```bash
# Per-script
./test-coverage.sh ~/dev/atlas --full-auto

# Overnight run with full auto
./overnight.sh --deep --full-auto
```

This adds `--dangerously-skip-permissions` and removes tool restrictions. A warning banner prints when active. **Use only when you've already run the script in scoped mode and trust it.** `FULL_AUTO=true` in the environment is intentionally ignored; the bypass must be passed explicitly as a CLI flag.

## Scheduling with Cron

Schedule scripts whenever makes sense for your workflow.

```bash
# Edit your crontab
crontab -e

# Nightly health check at 11pm PT (safe, read-only)
0 23 * * * /path/to/dotfiles/claude/scripts/overnight.sh >> ~/.claude/logs/overnight.log 2>&1

# Weekend deep run at 2am PT Saturday
0 2 * * 6 /path/to/dotfiles/claude/scripts/overnight.sh --deep >> ~/.claude/logs/overnight.log 2>&1
```

## Prerequisites

- [Claude Code](https://code.claude.com) installed and authenticated (`claude` on PATH)
- `gh` CLI (for `fix-issues.sh` — GitHub issue lookup and PR creation)
- Bash 4+ (macOS: `brew install bash`; Linux/WSL: included). `check-doc-truth.sh` is the one exception and runs on bash 3.2.

## Options

All scripts accept:

| Flag | Effect | Used by |
|------|--------|---------|
| `--full-auto` | Bypass all permission checks (prints warning banner) | All scripts |
| `--max-turns N` | Override max Claude turns (default: 15, full-review: 25) | All scripts |
| `--auto-push` | Push without prompting after tests, the required review gate, and current receipt validation | `review-and-push.sh` only |
| `--deep` | Enable test coverage + issue fixing phases | `overnight.sh` only |

Environment variables:

| Variable | Effect |
|----------|--------|
| `MAX_TURNS=N` | Override max turns |
| `LOG_DIR=/path` | Override log directory (default: `~/.claude/logs/`) |
| `MODEL=sonnet` | Override model (default: opus) |
| `CLAUDE_REPOS="~/a ~/b"` | Explicit repo list for `overnight.sh` |
| `CLAUDE_DEV_DIR=/path` | Dev directory for auto-detection (default: `~/dev`) |
| `REVIEW_TEST_CMD="<command line>"` | Step 2's test command in `review-and-push.sh`; outranks the repo-root `.review-test` file and framework sniffing (#490). A whitespace-only value is refused (#519). Unset for the command's own environment, so a suite that invokes the wrapper again on a fixture repo does not inherit it |
| `REVIEW_LANE=auto\|codex\|antigravity` | Override the review lane chosen by `review-and-push.sh` (default `auto`). Escalation is honoured; `antigravity` on a codex-required diff is **refused**, not honoured (ADR-0008) |
| `REVIEW_LANE_FALLBACK=codex\|block` | What to do when the Antigravity gate exits 3 (could not run). Default `codex` re-runs the diff through the Codex gate and records the degradation in the lane ledger; `block` refuses the push. A blocking verdict (exit 2) never falls back |

## Logs

All output goes to `~/.claude/logs/` with filenames like:

```
TIER_READONLY_atlas_2026-03-18_2300.log
TIER_FIX_stringer_2026-03-18_2300.log
```

## Repo Configuration

`overnight.sh` discovers repos automatically. Three ways to configure, in priority order:

### Option 1: Environment variable (explicit repos)

```bash
export CLAUDE_REPOS="~/dev/atlas ~/dev/stringer ~/dev/smss"
```

### Option 2: Config file (explicit repos)

```bash
# ~/.claude/repos — one path per line, # comments allowed
~/dev/atlas
~/dev/stringer
~/dev/smss
# ~/dev/old-project  # commented out, skipped
```

### Option 3: Auto-detect (zero config)

If neither env var nor config file exists, `overnight.sh` scans your dev directory for git repos. It finds the dev directory by checking:

1. `CLAUDE_DEV_DIR` env var
2. `~/.claude/dev-dir` file (contains one path)
3. Falls back to `~/dev`

This works on macOS (`~/dev`), Linux (`~/dev`), and WSL (`~/dev`). Keep repos on the Linux filesystem for ~10x faster I/O — avoid `/mnt/c/`.

```bash
# WSL: repos should live under ~/dev (Linux filesystem), NOT /mnt/c/
# setup.sh writes ~/.claude/dev-dir automatically — no manual config needed
```

## For Dotfiles Users

Getting started:

1. **Install prerequisites**: Claude Code, `gh` CLI, Bash 4+
2. **Make scripts executable**: `chmod +x ~/dotfiles/claude/scripts/*.sh`
3. **Configure your dev directory** (pick one):
   - Do nothing if your repos are in `~/dev` (default on all platforms including WSL)
   - `export CLAUDE_DEV_DIR="/path/to/dev"` in your shell profile (if non-standard)
4. **Test with a safe read-only run**: `./health-check.sh /path/to/your/repo`
5. **Try overnight**: `./overnight.sh` (read-only health checks across all repos)
6. **Go deeper when comfortable**: `./overnight.sh --deep` (writes tests + fixes issues)
7. **Morning review**: `./review-and-push.sh /path/to/repo` (AI reviews changes, prompts before push)
8. **Schedule with cron** when you trust the workflow (see Scheduling section above)

## Worktree lifecycle

`worktree-lifecycle.py inventory --repo /path/to/repo` reports task worktrees
separately from GitHub repository-settings drift. Use `--root /path/to/dev`
to inventory primary repositories under a shared directory. The daily hygiene
timer saves this read-only inventory to `~/.local/state/hygiene/worktrees.json`.
Read it with `hygiene-status.sh --worktrees`; `--status` describes repository
settings only.
Unreleased worktrees have unknown or active ownership and remain retained.

The task owner stops its processes, leaves the target directory, and releases
the completed artifact with its PR and session identifier:

```sh
python3 claude/scripts/worktree-lifecycle.py release --repo /path/to/repo \
  --worktree /path/to/task --head COMMITTED_HEAD --owner SESSION_ID \
  --pr PR_NUMBER --github-repo OWNER/REPO
```

A pending PR remains retained with that owner. After it merges, an authorized
session refreshes repository refs and previews the specific retirement:

```sh
git -C /path/to/repo fetch origin
python3 claude/scripts/worktree-lifecycle.py retire --repo /path/to/repo \
  --worktree /path/to/task
```

Add `--apply --archive-dir /path/to/private/archive` only when cleanup is
already authorized. The collector requires the exact released HEAD on a merged
same-repository PR, its merge commit reachable from the verified current remote
default, and a clean, unlocked worktree without active processes. Squash merges
use the actual PR head and merge identities. A changed HEAD, unknown evidence,
ignored or special files, empty directories, special index flags or submodules
means retain for separate inspection. Raw file bytes and modes must match the
committed blobs; transformed checkout contents and active content filters also
require separate retirement. Inspection does not execute those filters.
Process inspection requires Linux `/proc` and checks same-user processes'
working directories, roots, executables, open descriptors and file-backed
memory mappings. Missing or unreadable evidence retains the worktree.

Every systemd user session runs two same-user processes whose references no
scan can read: `systemd --user` and its `(sd-pam)` helper changed credentials
at exec, which clears dumpable and refuses this user every read below. Release
and retirement therefore refuse on those hosts until the operator asserts
`--trust-process-manager`. The assertion skips a process only when its
credentials are the current user's, every working directory, root, executable,
descriptor and mapping read of every thread is refused with `EACCES`, and it is
one of exactly two identities: the pid the system manager reports as `MainPID`
of `user@<uid>.service`, or a `(sd-pam)` child of that pid sharing its session.
Neither `PPid` nor `comm` is trusted for this — an orphan is reparented to pid 1
and any process can rename itself — and a service cannot borrow the manager's
session, because the manager starts each one in a session of its own. One
readable reference is evidence rather than an exemption and still retains the
worktree; so does a host where no session manager can be resolved. It stays an
assertion rather than an inference because a user unit can pass a descriptor to
the manager's file-descriptor store (`FDSTORE=1`) and close its own copy, which
no unprivileged scan can see. Both
commands need the flag, since retirement inspects again. The release record
lists each exempted pid, command and parent under `exempt_processes`, and the
recovery record carries that list into the archive beside
`retirement_exempt_processes`, what the retirement scans themselves skipped —
the two differ when the session manager restarted in between. The record is
rewritten as soon as the two scans are merged, so an archive retained by a later
check still names every identity either scan skipped. Other hosts
require an explicit platform-appropriate review. These checks sample
visible path references; the owner must account for activity in other process
namespaces or through alternate mount paths when releasing the task.

The collector verifies a recovery Git bundle including reflog-reachable
commits, archives worktree metadata including review receipts, and records
identities and file hashes in a private recovery record. It then locks the
worktree against Git pruning and renames the actual directory to
`worktree` inside that recovery directory, on the same filesystem. The result
reports `quarantined` and the retained path. Late files and writes through open
descriptors remain there, including ignored content that Git removal would
discard. Retirement never deletes the retained directory or reclaims its disk
space. Stashes and locked worktree metadata stay in the source repository.
Cross-filesystem destinations and checkouts with an explicit
`core.worktree` override are retained for separate handling. Other per-worktree
settings are preserved, and Git's resolved directory and metadata location are
verified after repair before reporting success.

As its last step — after the bundle and the recovery record are written, so the
record still names the branch the task worked on — applied retirement detaches
the quarantined worktree's own metadata HEAD at the released commit. It writes
only that worktree's `HEAD` and reflog inside the source repository's worktree
metadata; the quarantined directory, its index, the bundle and the record are
untouched, and the commit stays reachable from the merged PR, the bundle and the
detached HEAD. The result reports `detached` and the former `branch`, and
`git worktree list --porcelain` reports the quarantine as `detached`. The merged
branch ref is therefore an ordinary deletable branch afterwards, rather than one
`git branch -D` and merged-branch pruning refuse forever because a retired
worktree still has it checked out. The preview detaches nothing.

Add `--delete-branch` to have retirement delete that local branch itself. It
deletes only when the ref still names the exact merged PR head the collector
verified, is not a symbolic ref, and is held by no worktree — including one that
reports `detached` because a rebase or bisect interrupted it, whose
`rebase-merge/head-name`, `rebase-apply/head-name` and `BISECT_START` are read
exactly as Git reads them, since `update-ref` refuses none of that itself. The
delete passes the expected value, so a concurrent update makes Git refuse rather
than discard an unverified commit, and `--no-deref` means a ref that turned
symbolic in between can only delete itself, never the branch it points at.
Git has no lock that orders a worktree attaching the branch against its
deletion (`git branch -D` has the same window), so holders are read again right
after the delete; a worktree that attached in between gets the ref restored and
`branch_deleted` is false. A successful delete also removes the branch's own
`branch.<name>.*` section from the repository's local config, which
`update-ref` leaves behind, so a later branch of that name inherits no stale
upstream or rebase settings; a section it cannot remove is reported in
`branch_reason`, not raised. Any
other state — a release with no branch, a moved, absent or symbolic ref, a ref
another worktree holds — leaves the ref in place and says why under
`branch_deleted` and `branch_reason`, without failing the retirement it already
completed.

The recovery record includes the original path, quarantine path and Git
metadata path before the rename starts. If interruption leaves the tree in
quarantine but Git still points at the original path, run
`git -C /path/to/repo worktree repair /path/to/private/archive/retired-DIR/worktree`
after inspecting those paths. Before other recovery commands, verify that
`git -C /path/to/quarantine rev-parse --show-toplevel --absolute-git-dir` identifies
the retained checkout and recorded metadata; repair alone does not migrate
custom working-directory overrides. The lock remains in place across interruption
and successful repair. Keep it until an authorized owner has inspected the
retained files and decided their disposition; no automatic purge is provided.

The timer never releases or deletes worktrees; the next session owns follow-up
for pending releases. User authorization and release ownership remain
prerequisites for mutation, including when a standing order covers cleanup.
Quarantine retains late writes; it does not prevent a filesystem owner from
resuming work or creating a new directory at the original path.
