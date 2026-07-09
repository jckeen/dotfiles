# 0006. Verified compound-engineering assessment: port the agent-native persona, adopt two loop ideas, still don't install

- **Status:** Accepted (amends ADR-0004; closes #77)
- **Date:** 2026-07-09

## Context

ADR-0004 (2026-06-03) decided not to install Every's
**compound-engineering-plugin** and to adapt two ideas instead — but its Notes
admit the assessment was reconstructed from secondary sources without reading
the plugin's actual skill files, and issue #77 stayed open pending the grounded
recommendation. This ADR is that recommendation, based on reading the upstream
repo (`EveryInc/compound-engineering-plugin`) directly at v3.19.0.

The plugin has changed materially since 0004 was written:

- **It went "agentless" and skills-only.** The ~50 standalone agents and the
  ~40-skill sprawl 0004 assessed are gone. Today it ships **30 skills**
  (29 `ce-*` plus `/lfg`) around one loop: ideate → brainstorm → plan → work →
  **compound**, with `docs/solutions/` as the knowledge store the next
  iteration reads.
- **`agent-native-audit` — the component #77 asked about — no longer exists.**
  Both `agent-native-audit` and `agent-native-architecture` (and their `ce-`
  variants) appear in the plugin's own legacy-cleanup list
  (`src/data/plugin-legacy-artifacts.ts`), removed during the 2026-06 surface
  reduction. The agent-native content survives as two skill-local personas:
  `skills/ce-code-review/references/personas/agent-native-reviewer.md` (the
  audit checklist, matured: triage, priority tiers, a "noun test", a
  what-not-to-flag list, anchored confidence calibration) and
  `skills/ce-plan/references/agents/agent-native-planning-strategist.md`.
- **It is heavily maintained and multi-target.** 22.9k stars, MIT, multiple
  commits per day (last push 2026-07-09), 83 open issues; a Bun build compiles
  the same skills to Claude Code, Codex, Cursor, Antigravity, Devin, and
  seven more harnesses — upstream's equivalent of this repo's AgentPack
  three-way parity layer.

Our own baseline also moved since 0004: 17 skills + 17 review agents, the
doc-contract/CI drift system (ADR-0005), auto-memory, session-retro, the
three-agent Claude/Codex/Antigravity loop, and the plugin ecosystem
(superpowers, soundcheck, pr-review-toolkit, code-review, feature-dev, posthog)
already cover the plugin's core loop end to end. The evaluation bar stays the
one 0004 set: does a component add capability we don't have, and is adopting
it cheaper than adapting the idea?

## Decision

We reaffirm 0004's core call — **do not install the plugin** — and update its
adaptation targets to match what upstream actually ships today:

1. **Port the `agent-native-reviewer` persona, not the deleted skill.** Vendor
   its checklist (MIT, ~200 lines, self-contained) as the in-house
   `agent-native-review` subagent 0004 scoped, keeping the lenses that map to
   a config/tooling repo — primitives-over-workflows tool design, context
   parity for subagents, governed execution/completion signals, the anchored
   confidence rubric — and dropping the product-UI action-parity machinery.
2. **Adopt the `ce-compound-refresh` lifecycle as an idea.** Its five explicit
   outcomes for aging knowledge (Keep / Update / Consolidate / Replace /
   Delete) fill a real gap: session-retro and auto-memory only *add* knowledge;
   nothing prunes MEMORY.md topic files or ERRORS.md when entries go stale.
3. **Adopt the `ce-pov` two-floor grounding rule as an idea.** A verdict on an
   external technology must clear a *project floor* (a verified local fact) and
   an *external floor* (a verified source) — neither compensating for the
   other. Fold this into how we run adopt/skip evaluations (deep-research and
   future ADRs of this kind); no new skill.
4. **Skip everything else** — per-component table below.

ADR-0004's status is marked amended by this ADR. Its "adopt the compound/codify
discipline" item is already realized (session-retro, auto-memory, log-error,
the changelog cadence); its "healing-skill" item has no upstream counterpart
left and is covered by session-retro's description-fixing loop.

## Component assessment (verified against v3.19.0)

| Component | What it does | Overlap here | Verdict | Rationale |
|---|---|---|---|---|
| Core loop: `ce-ideate` / `ce-brainstorm` / `ce-plan` / `ce-work` | Q&A requirements → implementation-ready plan → gated execution in worktrees | Plan mode, superpowers brainstorming/writing-plans/executing-plans, `decompose`, worktree tooling | SKIP | Full duplication; adds a competing 4-command vocabulary. |
| `ce-compound` (+ `docs/solutions/`, CONCEPTS.md) | Captures each solved problem as structured, frontmattered docs the next run reads | session-retro, auto-memory MEMORY.md, log-error, changelog | SKIP (idea already adopted) | The codify discipline 0004 wanted is now our retro/memory loop; their file layout adds ceremony without new capability. |
| `ce-compound-refresh` | Maintains the knowledge store: Keep / Update / Consolidate / Replace / Delete each aging entry | Nothing — our memory only grows | ADAPT (idea) | Real gap: add a refresh pass over MEMORY.md/ERRORS.md to session-retro. Next action 2. |
| **`agent-native-audit` / `agent-native-architecture`** | (Removed upstream 2026-06; in the plugin's legacy-cleanup list) | n/a | SKIP (gone) | Cannot adopt a deleted skill; its successor is the persona below. |
| **`agent-native-reviewer` persona** (in `ce-code-review`) | Audit checklist: action/context parity, shared workspace, primitives-over-workflows, anti-pattern table, confidence anchors | No equivalent among the 17 agents (security-reviewer is adjacent, different lens) | ADAPT | Vendor as the in-house `agent-native-review` subagent scoped to our skills/hooks/entry points; UI-parity steps don't map to a dotfiles repo. Next action 1. |
| `ce-pov` | Graded Adopt/Trial/Hold/Reject verdict on an external input, gated by two grounding floors (project fact + external source) | deep-research (generic, not project-grounded); ADR practice | ADAPT (idea) | The two-floor rule is the novel part; capture it as method, not another skill. Next action 3. |
| `ce-code-review` / `ce-doc-review` / `ce-simplify-code` | Persona-based review, doc review, behavior-preserving simplification | 17-agent orchestra, `review`, `simplify`, code-review + pr-review-toolkit + soundcheck plugins, Codex/Antigravity gates | SKIP | Densest overlap in the whole plugin. |
| `ce-debug` | Systematic root-cause with causal-chain gate and predictions | superpowers systematic-debugging, codex rescue | SKIP | Covered. |
| `ce-commit` / `ce-commit-push-pr` / `ce-worktree` / `ce-resolve-pr-feedback` | Git workflow: commits, PRs, worktree isolation, PR-feedback resolution | commit-push-pr, standing orders, commit-format hook, worktree tooling, branch-hygiene | SKIP | Covered, and our versions encode local policy (staging rules, gates). |
| `/lfg` | Hands-off pipeline: plan → work → simplify → review → fix → ship → watch CI | `orchestrate`, overnight suite, auto-merge bootstrap | SKIP | Covered. |
| `ce-strategy` / `ce-product-pulse` / `ce-sweep` | STRATEGY.md anchor; usage/error pulse reports; Slack/GitHub feedback ingestion with cursors | posthog plugin (pulse), Atlas (inbox/Slack), GitHub issues | SKIP | Product-team loops; wrong shape for a dotfiles repo. `ce-sweep`'s cursor-based ingestion may merit a look for product repos — out of scope here. |
| `ce-polish` / `ce-test-browser` / `ce-test-xcode` / `ce-riffrec-*` | UX polish sessions, browser/Xcode test loops, screen-recording analysis | playwright + claude-in-chrome, Antigravity's runtime-verification lane; no Xcode | SKIP | Stack mismatch or covered. |
| `ce-explain` / `ce-promote` / `ce-proof` / `ce-dogfood` / `ce-setup` / `ce-optimize` | Personal explainers, announcement copy, Every's Proof editor, plugin self-config, metric-driven optimization loops | Every-specific services or niche | SKIP | Tied to Every's products (Proof, Spiral) or low-value for this setup. |
| Multi-target build (`src/` converters → 12 harnesses) | One skill source compiled to Claude/Codex/Cursor/Antigravity/Devin/… | AgentPack + three-way symlink parity | SKIP (reference) | Same idea, different scale. Their converter architecture is a design reference if our parity layer ever outgrows symlinks; no action now. |

## Consequences

**Positive**
- #77 closes with a verified decision instead of a reconstructed one; the one
  concrete artifact worth taking (the persona checklist) is identified by path
  and is MIT-licensed for vendoring.
- Two cheap, high-leverage ideas (knowledge refresh outcomes, two-floor
  grounding) land in existing skills — no new vocabulary, no plugin install.

**Negative**
- Vendoring the persona forgoes upstream's ongoing calibration improvements;
  we accept occasional manual re-syncs against a fast-moving repo (multiple
  commits/day) — mitigated by the port being a lens, not an API.
- Three follow-up items must actually get filed and built, or this ADR repeats
  0004's fate of a decision without adoption.

## Alternatives considered

- **Install the plugin as-is** — rejected again: ~25 of 30 skills duplicate
  existing capability, and a 30-command `ce-*` namespace conflicts with our
  auto-invocation convention.
- **Install and disable the redundant skills** — rejected: the plugin is a
  compiled bundle updated daily; curating exclusions is ongoing maintenance
  for two files' worth of value.
- **Wait for upstream to re-ship a standalone agent-native audit** — rejected:
  upstream deliberately consolidated it into review personas ("agentless"
  surface reduction); no signal it returns.

## Next actions

Each is scoped to become its own GitHub issue:

1. **Build `agent-native-review` subagent** — vendor
   `ce-code-review/references/personas/agent-native-reviewer.md` (MIT,
   attribute upstream) into `claude/agents/agent-native-review.md`, rescoped:
   drop UI action-parity (steps 1–2, 5), keep tool-design primitives, context
   parity for subagents, governed execution, and the confidence anchors;
   target our skills, hooks, and entry points.
2. **Add a knowledge-refresh pass to session-retro** — apply the five
   ce-compound-refresh outcomes (Keep / Update / Consolidate / Replace /
   Delete) to auto-memory topic files and ERRORS.md when a retro runs, so
   memory prunes as well as grows.
3. **Encode the two-floor grounding rule** — add ce-pov's project-floor +
   external-floor gate to the deep-research skill (and note it in the ADR
   template's Context guidance) so future adopt/skip verdicts must cite one
   verified local fact and one verified external source.
4. **Mark ADR-0004 amended** — status line updated to point here (done in the
   same PR as this ADR).
