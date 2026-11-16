<!-- GENERATED FILE (ADR-0007) — do not edit directly.
     Sources: agents/canon/CANON.md + agents/canon/fragments/claude.md
     Regenerate: claude/scripts/gen-instruction-files.sh -->

# Global Claude Code Instructions

## Personal context

Identity and private preferences live in the private `claude-memory` repo,
imported here (see the README's "The private memory repos" section).

@~/dev/claude-memory/CLAUDE.md

## Working style

- Proceed with clear, in-scope work and honor explicit requests and applicable
  standing authorizations. Ask when missing information prevents progress or
  an action requires approval that has not already been given.
- Plan before non-trivial work: state the approach, and confirm it only when
  the goal or design is genuinely ambiguous.
- If the goal is unclear, ask before coding — don't guess at intent.
- Prefer editing existing files over creating new ones.
- Read the surrounding code before changing behavior — prefer the existing
  patterns over new abstractions.
- Keep changes scoped to the request — no unrequested refactors or cleanup.
- Write code comments for invariants, external constraints, or non-obvious
  reasons. Match the surrounding file's comment density and idiom.
- Be concise. State results and decisions, not running commentary.
- Match ceremony to the task. A clear tactical ask ("add this line", "run this
  check") gets done and reported — no plan, no variants, no preamble. Reserve
  heavyweight planning for genuinely complex work.
- Lead with the state change. When a merge, approval, CI result, or deploy
  lands, open the reply with one status line (`✅ PR #N merged`) before detail —
  don't bury it in tool output.
- If the same error appears 3+ times, stop and explain the root cause instead of
  retrying. Course-correct early if the approach turns out to be wrong.
- Unattended or looping work follows the `autonomous-run` skill: stop condition,
  cap and verification gate are written before launch.

## Tech stack

- **TypeScript** primary; **bun** as the runtime — never npm/npx.
- In Bash, prefer `rg` over `grep`; use `fd`, `bat`, `eza` over
  `find`/`cat`/`ls` only when `command -v` shows they're installed. In
  portable code that ships to others, use language-native fs APIs and prefer
  `find` over `fd` (fd isn't guaranteed installed).
- Never hardcode user paths — use `$HOME` or relative paths.
- Explicit error handling; never silently swallow errors.
- Use the latest stable version of any dependency — don't trust versions from
  training data. Check the registry before adding; run `bun outdated` after.
- Calling an external API: fetch the live reference for that exact endpoint and
  version at code-time — verify every field, param, and scope against the live
  page rather than extrapolating from memory.

## Build standards

- **Build standards hold in every language (ADR-0010).** Each is enforced by
  lint where the repo has a rule for it and by review where it has none; the
  repo's config holds the numbers.
  - *Size budget:* where the repo's config sets a line budget, a file over it
    may not grow. A change that would grow it extracts just enough of the
    code it is editing to keep the file at its current length; that
    extraction is part of the change, and any wider split is its own change.
    No configured budget, no size rule.
  - *Contracts at the boundary:* data entering the application from outside
    (a request, a webhook, model output, a file, the environment) is validated
    once, where it enters, by the language's contract mechanism: a runtime
    schema with the static type derived from it, where the language has one.
    Internal calls and data already validated are not boundaries.
  - *Explicit state:* a feature with a lifecycle models it as a tagged union
    or a transition table, never as loose booleans or one type with many
    optional fields. A feature with no lifecycle gets no state machine.
  - *Pure core, injected edges:* domain logic takes its dependencies and the
    current time as arguments instead of importing network, disk, database or
    clock. Adapters and orchestration, whose job is the I/O, live in their
    own modules.
  - *No type escape hatches:* no `any`-equivalent and no unchecked cast.
    Narrow with a check or a parse.
  - *Fakes over mocks:* test domain behaviour against an in-memory
    implementation of the port, not by spying on which method was called.
    Rules about who may import what belong in the linter, not the test runner.
  - *Ratchet:* in a repo that has recorded its baseline, existing violations
    may only decrease and a new file meets every rule. In one that has not,
    new files and new functions meet these; an edit inside existing code
    follows that code's current shape, and nothing existing is rewritten to
    conform.

## Session start

- The harness already loads `CLAUDE.md` and a git status snapshot with recent
  commits — don't re-read them. When picking up project work, read
  `CHANGELOG.md` if present, plus any unfolded `changelog.d/` fragments, which
  hold the newest entries; run `git status`/`git log` only when no snapshot
  is in context. If a project has no `CLAUDE.md`, offer to bootstrap one.

## Verification

- Give yourself a way to check the work: run the tests, the types, or the app.
- Don't claim something works without evidence from a tool. Report any test you
  could not run rather than silently skipping it.
- Address root causes, not symptoms. When fixing a bug, write a failing test
  that reproduces it first, then fix it.
- A test asserts behavior: call the code and check its result. Never assert on
  source text, or only that a mock was called. Use the lowest test level that
  proves the change, and a fake over a mock.
- Audit during the build, not at a final gate. The moment a risky surface (auth,
  path/host handling, file IO, schemas, hash chains) has a complete first draft,
  run the security/review pass then — in parallel with continuing. Auditing at
  the discovery moment collapses rework cycles.
- Re-run a subagent's "verified via X" claim yourself when it contradicts what
  you can check directly — empirical beats confident assertion. The underlying
  concern may still be real even if its verification line was hallucinated.
- Two-floor grounding (ADR-0006): an adopt/skip verdict on an external
  technology must clear a *project floor* (a verified local fact) and an
  *external floor* (a verified source) — neither compensating for the other.
- Promote a "must NOT happen" requirement from discipline into code/CI whenever
  the fix is small (~<50 LOC) — a checklist item waiting to be remembered is the
  failure it guards against (schema refinement on env, host allowlist, a CI gate).
- A `--dry-run` or non-interactive (`--yes`) flag is only correct when *every*
  destructive write sits behind the guard AND no default overwrites existing
  state with empty. Verify by running it against a throwaway `HOME` and diffing
  the target — a dry-run that mutates real config is worse than none.
- A reviewer's finding is usually a category, not an instance. Before pushing the
  fix, sweep the same neighborhood — sibling routes, every path resolution, every
  shell flag — and ship the unified fix in one pass.
- When an audit, review, or verification pass surfaces a real, actionable finding,
  file a GitHub issue for it without asking — this is pre-authorized. One issue per
  distinct finding, with repro/evidence and a suggested fix. Don't file for trivia
  or anything already tracked. This is judgment-based, so it lives here as a
  standing order, not as a hook (hooks fire on lifecycle events and can't judge
  whether a finding is worth filing).

## Definition of done

- Docs are part of "done," not a follow-up. For any substantive change —
  especially a removal, migration, or refactor — update every doc surface in the
  same pass: READMEs, CONTRIBUTING, `docs/`, and the relevant `CLAUDE.md`. Keep
  history accurate (changelogs and dated archives may name removed things) but
  make active guidance reflect the present; verify with a `grep -ri <removed>`.
- Treat `CHANGELOG.md` as living: update it every 1–2 meaningful commits,
  appending rather than rewriting — not batched to end-of-session, which gets
  lost when a session ends early. Where a repo keeps `changelog.d/`, add or
  update the PR's `changelog.d/<branch-slug>.md` fragment instead of editing
  `CHANGELOG.md`; a fragment allows no `<` placeholders (write NAME-style
  ones), code fences or HTML comments.
- Doc contract: a repo's Markdown surfaces are declared in a root
  `.doc-contract` (LIVING / GENERATED / SOURCE / HISTORICAL + BANNED guards)
  and asserted in CI by `check-doc-truth.sh`; bootstrap or audit one with
  the `drift-sweep` skill if it is enabled (ADR 0005 in dotfiles). Keep
  LIVING small — a wrong doc is worse than no doc; delete or mark HISTORICAL
  rather than let it freeze.
- Never hardcode a count, version, SHA, or hostname in guidance prose that CI
  can't assert — point at the canonical source instead. A dated record (a
  CHANGELOG entry, a handoff note) is a point-in-time statement and may state
  the figure it measured. GitHub issues are the only
  open-work tracker: docs may link issues, never duplicate their state
  (no TODO.md / checklist files).
- Retiring a process or doc: same day, add the historical banner
  (`> **Historical** — point-in-time record (date). Do not act on this.`),
  then `rg -il "system of record|single source of truth|canonical tracker"`
  and repoint every doc that bills the dead thing as authoritative.

## Parallel agents

- Never run multiple agents editing the same files at once — they make
  conflicting assumptions about names, signatures, and imports. Parallelize
  read-only work (review, research) and non-overlapping new files freely; for
  shared-file edits use staged sequential rounds, verifying (lint/test/build)
  between rounds. The same applies to two interactive sessions sharing one git
  checkout — one owner at a time.

## Multi-agent teamwork

When Codex (`cx`) and Antigravity share this repo, we're one team coordinating
through artifacts — instructions + skills, GitHub issues, `handoff` notes, and
git — not a shared chat. Full role table and rationale: `MULTI-AGENT.md`; gate
selection, handoff payload, and verdict-persistence mechanics: the
`review-gates` skill. The non-negotiables:

- **One owner of the working tree at a time** — each agent gets its own
  worktree, or edits are sequenced.
- **Verification is adversarial, not an echo chamber** — assign the refuter
  role explicitly; route disagreement to a fix, not a tie-break.
- **A handoff carries the claim to disprove and the exact repro command**, not
  just "please review".
- **Verdicts are artifacts** — persist a rescue diagnosis or verification
  verdict (handoff note or issue comment) before the team acts on it.
- **Proportional pre-build critique & post-build escalation** — add independent
  pre-build design critique (across selected services, or a fresh-context
  subagent when one runtime is selected) for Tier-3 changes (`>3` files across module
  boundaries, schemas/migrations, or auth/trust/gate boundaries), while
  single-agent planning suffices for smaller changes; all required and
  requested reviews still apply in full. Re-run affected checks and required
  reviews after every fix: if P0/P1 blockers or unapproved required reviews
  remain after 2 fix rounds, stop as blocked for the operator; once required
  reviews, blocking threads, and CI are clear, harvest optional P2/P3 nits as
  follow-up issues (`harvest-codex-comments.sh`) and merge.
- **Synchronous verification & delivery ownership** — never end a turn while a
  verification test or review gate is still running in the background; run
  checks in the foreground (`BASH_DEFAULT_TIMEOUT_MS=600000`) and land commits or
  record a blocker handoff before stopping.

## Git

- Commit/push autonomy is governed by the autonomy rules above and any
  private standing orders, not flatly forbidden here: the default is don't
  commit or push unless asked, but a standing order may grant blanket
  authorization for ordinary commits/push. Destructive or shared-branch
  operations (force-push, rebase, branch deletion, pushing to a protected
  branch) always confirm first.
- Use conventional commit messages: `type: short description` — the full type
  set is the one enforced by `claude/scripts/check-commit-format.sh`
  (`feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`, `perf`,
  `build`, `ci`, `revert`).
- Stage specific files — avoid `git add -A` / `git add .` so secrets and
  generated files don't slip in. Never stage `.env`, credentials, tokens, keys.
- Push once per unit of work, not once per fix. Every push to a PR re-runs the
  full CI suite and, in repos running the `codex-review` workflow, gets an
  automatic `@codex review` request (docs-only diffs that touch no
  instruction surface are skipped and pass at once). Commit locally as often as you like,
  run lint/types/tests locally, and push when the change is ready for review
  or CI.

## CI cost

- **Hosted CI minutes are a budget, in every repo.** The target: the full
  suite runs once per merge and every other run is cheap. With a merge queue
  that one run is the queue's. Without one it is the pull request's required
  run, and the default branch may skip a job only when that same job already
  passed on the identical tree; a job the pull request did not run (one that
  needs protected secrets, or runs only on the default branch) still runs
  there. When the task is CI, apply the measures: cancel
  superseded pull-request runs, group routine dependency updates, and skip a
  job only by a path rule, behind one always-running required check that
  fails unless every job passed or was skipped by that rule. When the task is
  something else, change no CI: file an issue. Required checks, branch
  protection and merge queues are the operator's decision: propose, never
  change. Never save minutes by weakening what gates a merge.

## Auth at the boundary

If a service could ever need auth, build it in from the first commit: auth by
default rather than by config, a closed failure mode, and no ambient credential
attached to a URL or path read from persisted state. Never assume "auth will be
added later" or "the layer above handles it." For any new entry point (HTTP
route, IPC accept-loop, WebSocket upgrade, external-input queue consumer,
mutating CLI subcommand), follow the `auth-boundary` skill's checklist.
