## 2026-10-19 — fix(skills): operator-lane instruction-surface pass (claude.dev audit, changelog fragments)

- **`orchestrate`** (#596) no longer invokes skills that left with the
  superpowers plugin or that `skillOverrides` hides; steps state the outcome
  and name a skill only "if available". The MUST/Mandatory wording is gone,
  and the skill gains model/effort routing for subagents, the agent-team
  cost note, a phase-level workflow line and an HTML-for-long-output line.
  `session-retro` (both runtimes) generalizes a missed trigger description
  instead of pasting the user's phrasing. `branch-hygiene` addresses Claude,
  not "the Codex agent".
- **`agents/canon/fragments/claude.md`** → `claude/CLAUDE.md` (#596):
  `bun outdated`; `fd`/`bat`/`eza` only when installed; session start no longer
  re-reads what the harness already loads; the doc-contract bullet names the
  `drift-sweep` skill "if it is enabled". The Git section adds "push once per
  unit of work, not once per fix" (from closed #587): every push re-runs CI
  and, where the `codex-review` workflow runs, requests a Codex bot review.
- **`CLAUDE-GUIDE.md`** (#672): the `OperatorQueueReminder` hook row calls
  `~/.claude/operator-queue.md` the legacy queue and says the handoff skills
  file new items as issues (the skills themselves moved in #712); the hook's
  header comment says the same.
- **Changelog fragments:** the claude and jules fragments, both `changelog`
  skills, the Claude `handoff` step 4, `orchestrate` and `MULTI-AGENT.md` now
  send a PR's entry to its `changelog.d/BRANCH-SLUG.md` fragment where the
  repo keeps `changelog.d/`, with the format `assemble-changelog.sh --check`
  accepts. The jules fragment exempts the PR that folds the fragments in.
- **`review-gates`** gains a "Codex bot threads before merge" section
  (`codex-threads.sh` list/resolve, reply before resolving).
- **Tier-1 byte ceiling** (#642): `MULTI-AGENT.md` and `claude/scripts/README.md`
  name `TIER1_MAX_BYTES` in `review-receipt.py` instead of restating the
  figure; ADR-0008 keeps its dated figure.
- **Codex gate findings (2026-11-05).** `claude/AGENTPACK.yaml` regenerated for
  the `changelog` description. `review-gates` allows the one manual
  `@codex review` the workflow itself asks for (a review that ended without
  completing is not retried automatically). Both `changelog` skills say the
  branch slug is not unique and the validator accepts only letters, digits,
  `.`, `_` and `-`, so an existing fragment is confirmed to be this branch's
  before it is updated, and a colliding or invalid slug gets a distinct name.
