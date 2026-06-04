# Roadmap

How this repo tracks work — the four-layer record model (see
[ADR-0001](docs/adr/0001-record-architecture-decisions.md)):

| Layer | Question | Where |
|-------|----------|-------|
| **GitHub Issues** | What's next? | [Issues](https://github.com/jckeen/dotfiles/issues) + milestones |
| **PRs (CI-gated)** | Is this change safe to land? | one PR per issue, CI green = merge |
| **ADRs** | Why did we decide this? | [`docs/adr/`](docs/adr/) |
| **CHANGELOG** | What shipped? | [`CHANGELOG.md`](CHANGELOG.md) |

This file is the at-a-glance index of the **current milestone**. Issues are the
live source of truth; close them via PRs and this list reflects status.

---

## Milestone: Coding setup hardening — 2026-06

Fix doc drift, bring skills to Anthropic's authoring spec, make verification
first-class, and adopt agent-native compounding. Grounded in Boris Cherny /
Code w/ Claude 2026 best practices.

### Tier 1 — Fix drift
- [ ] [#69](https://github.com/jckeen/dotfiles/issues/69) Scrub phantom-hook references and reconcile hooks docs
- [ ] [#70](https://github.com/jckeen/dotfiles/issues/70) Surface CI status in `commit-push-pr` (Codex-review-inside model)
- [ ] [#80](https://github.com/jckeen/dotfiles/issues/80) Make dotfiles CLAUDE.md portable — move personal identity to claude-memory

### Tier 2 — Skills to spec (so the agent auto-invokes; fewer commands to memorize)
- [ ] [#71](https://github.com/jckeen/dotfiles/issues/71) Rewrite weak skill descriptions to Anthropic spec
- [ ] [#72](https://github.com/jckeen/dotfiles/issues/72) Resolve `user_invocable` field + consolidate review/simplify duplicates

### Tier 3 — Verification first-class + drift-guard
- [ ] [#73](https://github.com/jckeen/dotfiles/issues/73) Make verification first-class in the workflow
- [ ] [#74](https://github.com/jckeen/dotfiles/issues/74) Add deterministic doc-reference drift-guard to CI

### Tier 4 — Agent-native / compounding
- [ ] [#75](https://github.com/jckeen/dotfiles/issues/75) `session-retro` self-improving-skills skill
- [ ] [#76](https://github.com/jckeen/dotfiles/issues/76) `jujutsu` (jj) skill
- [ ] [#77](https://github.com/jckeen/dotfiles/issues/77) Evaluate Every compound-engineering plugin (→ [ADR-0004](docs/adr/0004-compound-engineering-evaluation.md))
- [ ] [#78](https://github.com/jckeen/dotfiles/issues/78) Establish ADR practice (`docs/adr/` + template + backfill)
- [ ] [#79](https://github.com/jckeen/dotfiles/issues/79) ROADMAP.md index linking the milestone

---

_Past work lives in [`CHANGELOG.md`](CHANGELOG.md); the reasoning behind
structural changes lives in [`docs/adr/`](docs/adr/)._
