# 0004. Adopt selected ideas from Every's compound-engineering plugin (not the plugin)

- **Status:** Accepted (decision made 2026-06-03; remaining adoption tracked in #77)
- **Date:** 2026-06-03

## Context

Every Inc ships an open-source **compound-engineering-plugin** for Claude Code
that packages ~40+ `ce-*` skills and 50+ agents around one thesis: *each unit of
engineering work should make the next one easier* (brainstorm → plan → execute →
review → **compound**). It also ships a distinct **agent-native** track —
skills that audit and design codebases so AI agents are first-class operators.

Our setup is already mature and convergent with this philosophy (~12 custom
skills, 17 review subagents, hooks, systemd timers, an overnight autonomous
suite, Boris-Cherny practices, and the in-flight Issues/ADRs/session-retro
additions). So the question is not "adopt the plugin" — most of it duplicates
what we have — but which *ideas* fill genuine gaps. We also prefer
auto-invocation over memorized commands, which a 40-command `ce-*` namespace
would work against.

## Decision

**Do not install the plugin wholesale** — it is ~80% redundant with our skills
and subagents, multi-target (Bun/Codex/Cursor), and would create command sprawl
and a competing vocabulary. Instead:

1. **Adopt the ideas** that are missing — the explicit "compound/codify" step
   (write each learning back as reusable knowledge) and the agent-native
   architecture lens — folding them into existing skills/CLAUDE.md.
2. **Adapt** the `agent-native-audit` checklist into an in-house
   `agent-native-review` subagent scoped to *our skills and entry points*, not
   product-UI parity.
3. **Skip** everything that duplicates existing capability or targets stacks we
   don't use.

## Component assessment (representative)

| Component | Verdict | Reason |
|---|---|---|
| `ce-brainstorm` / `ce-plan` / `ce-work` | SKIP | Covered by plan mode, `decompose`, `max`, overnight suite. |
| `ce-code-review` / `ce-simplify-code` | SKIP | We have 17 review agents + `review` + `simplify`. |
| `ce-commit*` / `ce-clean-gone-branches` | SKIP | Duplicates `commit-push-pr` + `branch-hygiene`. |
| `ce-compound` / `ce-sessions` | ADOPT (idea) | This *is* our `session-retro` loop — adopt the explicit codify discipline. |
| **`agent-native-audit`** | ADAPT | Port its principle checklist into an in-house subagent; don't install. |
| `agent-native-architecture` | ADOPT (idea) | Capture principles as design guidance in CLAUDE.md / future ADR. |
| `healing-skill` (auto-fix stale SKILL.md) | ADOPT (idea) | Fuel for the self-improving-skills loop. |
| Stack-specific (`ce-dhh-rails-style`, Xcode, Ruby) | SKIP | We're TS/bun. |

**On `agent-native-audit`:** it scores a codebase against agent-native
principles (action parity, context parity, shared workspace, atomic primitives,
governed execution) and emits a prioritized gap report. As written it targets
*product apps with a UI*; on a dotfiles/config repo principles 1–3 don't map.
Worth porting as a lens for our own tools — *are our skills atomic primitives or
do they bundle too much judgment? do agents get the runtime context they need?
do autonomous scripts have explicit completion signals and governed boundaries?*
(the last intersects our auth-at-the-boundary rule for `claude-server`).

## Consequences

**Positive**
- No new vocabulary to memorize; everything stays in our namespace and
  auto-invocation conventions.
- We capture the two genuinely new ideas without ~40 redundant skills.

**Negative**
- "Adopt the idea, not the skill" requires us to do the porting (tracked as
  GitHub Issues so it doesn't slip).
- We forgo upstream maintenance and risk drifting from Every's evolving
  definitions (low impact — principles, not APIs).

## Alternatives considered

- **Install the plugin as-is** — rejected: command sprawl, redundancy, conflicts
  with the no-memorized-commands constraint.
- **Run agent-native-audit unmodified on this repo** — rejected: it's tuned for
  product UIs; low signal on a config repo.

## Notes

The canonical `every.to/guides/agent-native` article body could not be retrieved
(metadata-only/gated); the philosophy here is reconstructed from secondary
sources and the plugin's own docs. Principle count varies by source (5 vs 8);
this ADR uses the five-principle framing. Verify against
`compound-engineering/skills/ce-agent-native-audit/SKILL.md` before building the
in-house subagent.
