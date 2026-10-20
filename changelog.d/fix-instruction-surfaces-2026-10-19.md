## 2026-10-19 — fix(skills): operator-lane instruction-surface pass (claude.dev audit, operator-action issues, changelog fragments)

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
  and a Codex bot review.
- **Both `handoff` skills** (#672) file a new operator action as an
  `operator-action` issue in the private repo it concerns (a public or
  multi-repo item goes in `OPERATOR_QUEUE_REPO`, matching #693), filed with
  the operator's own `gh` login, or comment on the open one, instead of
  appending to `~/.claude/operator-queue.md`. They carry the re-check,
  comment and close-only-when-done rule the reminder hook's footer used to
  state; the `[stale — re-verify]` marker is unchanged. The handoff workflow
  invariant anchors on the new wording.
- **Changelog fragments:** the claude and jules fragments, both `changelog`
  skills, the Claude `handoff` step 4, `orchestrate` and `MULTI-AGENT.md` now
  send a PR's entry to its `changelog.d/BRANCH-SLUG.md` fragment where the
  repo keeps `changelog.d/`, with the format `assemble-changelog.sh --check`
  accepts.
- **`review-gates`** gains a "Codex bot threads before merge" section
  (`codex-threads.sh` list/resolve, reply before resolving).
- **Tier-1 byte ceiling** (#642): `MULTI-AGENT.md` and `claude/scripts/README.md`
  name `TIER1_MAX_BYTES` in `review-receipt.py` instead of restating the
  figure; ADR-0008 keeps its dated figure.
