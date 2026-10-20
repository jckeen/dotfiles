# Roadmap

How this repo tracks work — the four-layer record model (see
[ADR-0001](docs/adr/0001-record-architecture-decisions.md)):

| Layer | Question | Where |
|-------|----------|-------|
| **GitHub Issues** | What's next? | [Issues](https://github.com/jckeen/dotfiles/issues) + milestones |
| **PRs (CI-gated)** | Is this change safe to land? | one PR per issue, CI green = merge |
| **ADRs** | Why did we decide this? | [`docs/adr/`](docs/adr/) |
| **CHANGELOG** | What shipped? | [`CHANGELOG.md`](CHANGELOG.md) (current quarter; entries not yet folded in, in `changelog.d/`; older quarters in [`docs/changelog/`](docs/changelog/)) |

This file is the at-a-glance index of the **current milestone**. Issues are the
live source of truth; close them via PRs and the milestone reflects status.

---

## Milestone: Operator pass — 2026-10

The 2026-10-19/20 backlog burn-down shipped every change an agent could land on
its own. What remains is the work the repo's own rules keep in the operator
lane: gate machinery, instruction surfaces, and `.github/` workflows. Each is
prepared as a reviewed, tested patch with its apply order in the operator-pass
handoff README, and every issue it closes is on the
[Operator pass — 2026-10](https://github.com/jckeen/dotfiles/milestone/2)
milestone.

- **Gate machinery**: review-receipt false positives, a pinned review base, and
  a read-only sandbox for both reviewers, plus the Antigravity default model pin.
- **Instruction surfaces**: the claude.dev audit fixes, the handoff skills
  filing operator actions as issues, and changelog-fragment guidance.
- **`.github/` workflows**: the changelog-fragment CI checks, late Codex-review
  harvesting, and the bash 3.2 status-line run.
- **Then**: enforce the `codex-review` ruleset (#615) once the review-gates
  thread-resolution line has landed.

Follow-ups that need no operator review are ordinary open issues; the
[issue list](https://github.com/jckeen/dotfiles/issues) is the tracker.

## Past milestones

- [Coding setup hardening — 2026-06](https://github.com/jckeen/dotfiles/milestone/1?closed=1):
  doc drift fixed, skills brought to the authoring spec, verification made
  first-class, the ADR practice established, and the enforcement-hardening
  follow-up (secret scan, a local Codex gate on push, commit-format and
  agent-parity CI). Details are in the 2026 Q2 changelog archive.

---

_Past work lives in [`CHANGELOG.md`](CHANGELOG.md) and its quarterly archives
in [`docs/changelog/`](docs/changelog/); the reasoning behind
structural changes lives in [`docs/adr/`](docs/adr/)._
