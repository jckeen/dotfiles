## 2026-11-03 — feat(skills): loops, waiting and autonomy guidance for orchestrate

- **`orchestrate`**: fixes the stale claim that a named agent's final text
  never reaches the lead. A teammate's idle notification carries its final
  answer but long reports are truncated, so every agent also writes its full
  report to a scratchpad file. The background-agents bullet becomes fork mode
  (on by default since 2.1.302; `subagent_type: "fork"` for full-context side
  tasks, never for unbiased review). The workflows bullet covers scale (10+
  items, adversarial verification, run-until-dry), `pipeline()` over barrier
  `parallel()`, and a slice first; batch operations switch to one agent per
  item above about ten files. New bullets cover waiting and loops (`Monitor`,
  background Bash, `/loop` with a stop condition, `/goal`, command Stop hooks
  with the block cap, `/schedule`), hard caps set before launch, a delegation
  template, and the Agent call's `effort`. The frontmatter gains an
  `argument-hint` and a trigger-led description, and a top line points at the
  Close the Loop checklist, since only the start of a skill survives
  compaction.
- **`check-skill-refs.sh`** (new, local, advisory): warns when orchestrate,
  `claude/CLAUDE.md`, `MULTI-AGENT.md` or CLAUDE-GUIDE's "The Workflow" tells
  the model to run a skill that is missing or `"off"` in the live
  `skillOverrides`, unless the line hedges with "if available". Runs at `cc`
  launch from `check-claude.sh`; its self-test runs in CI.
- **`session-retro`**: auto mode no longer claims `overnight.sh` fires it;
  unattended runs are `/orchestrate` with no user present or
  `/session-retro --auto`.
- **`autonomous-run`** (new Claude skill, `claude-only` in
  `skill-coverage.tsv`): the decision layer for unattended or looping work.
  Five questions before launch, a first-match-wins pick between in-session
  work, a workflow, `/loop`, `/goal`, a command Stop hook and `/schedule`, a
  strictness ladder for checks, always-on guardrails (stop condition and cap
  before launch, verification Claude did not author, stop-and-ask triggers)
  and a report shape. README and CLAUDE-GUIDE count and list 18 slash
  commands, and `claude/AGENTPACK.yaml` is regenerated (it was also stale for
  the `changelog` description on the base branch).
- **`CLAUDE-GUIDE.md`**: "Stop Hooks (Auto-QA Pattern)" becomes "Loops &
  Unattended Runs", with the five questions, a primitive table, the
  strictness ladder and the headless `claude --bare -p` shape. The Stop hook
  template now uses the documented `1>&2 || exit 2` shape (the old one piped
  checks through `tail`, so it could never block) and explains
  `stop_hook_active` and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. The Workflow's
  simplify and changelog steps no longer name switched-off skills flatly,
  Golden Rule 8 says loops need a finish line, and Autonomous Scripts points
  at #740 for `overnight.sh` gaps.
- **`claude/CLAUDE.md`** (via `agents/canon/fragments/claude.md`): one
  Working-style line sends unattended or looping work to `autonomous-run`.

- **Codex gate findings (2026-11-05).** Workflows need the user's explicit
  opt-in and `/effort ultracode` is never set for them; the strictness ladder
  governs the loop's own check and never replaces the wrap-up's independent
  review; `/schedule` is decided before the shape of the work; the headless
  shape drops `--bare`, which skips hooks and CLAUDE.md; the Stop hook template
  keeps its own attempt count because the block cap resets on every tool call;
  `check-skill-refs.sh` judges hedges per sentence, with wrapped lines joined.

- **Second Codex round (2026-11-05).** The Stop hook template runs through
  `bash` (no executable bit to forget), reports "stopped at cap" to Claude as
  one final block and to the person as a `systemMessage` rather than on a
  stderr nobody reads; a command Stop hook is chosen before a judged `/goal`;
  `check-skill-refs.sh` splits clauses at commas and parentheses so a hedged
  parenthetical exempts only its own ref, and doubles every separator byte so
  a ref right after a comma is still seen.

- **Third Codex round (2026-11-05).** The Stop hook template stops at once
  when its attempt count cannot be written, instead of retrying unbounded;
  `check-skill-refs.sh` exempts another runtime's skill only when its
  possessive names that ref, not every ref in the clause.
