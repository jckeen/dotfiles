# 0001. Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

This repo accumulates decisions — what got removed, what tooling replaced it,
why a pattern is enforced in a hook instead of CLAUDE.md. The CHANGELOG records
*what shipped*, but the *why* gets buried in commit bodies and one-off plan
files (an ad-hoc, often gitignored `Plans/` doc) that drift or get deleted.
There was no durable, greppable home for the reasoning behind a change.

## Decision

We adopt a four-layer record model, each layer owning one question:

- **GitHub Issues** — *what's next* (the backlog, the intent).
- **Pull Requests (CI-gated)** — *the unit of change* (the diff that ships; CI
  green is the merge gate).
- **ADRs** (this directory) — *why* (the durable reasoning behind a decision).
- **CHANGELOG** — *what shipped* (the chronological record of merged change).

ADRs live in `docs/adr/` as `NNNN-kebab-title.md`, numbered sequentially from
`0001`. The set is **append-only**: a decision that no longer holds is not
edited or deleted — a new ADR is written that supersedes it, and the old one is
marked `Status: Superseded by ADR-XXXX`. `0000-template.md` is the starting
point for new records.

## Consequences

**Positive**
- The reasoning behind a change survives even when the plan file or branch is gone.
- Clear ownership per layer — no duplicating "why" into the CHANGELOG.
- Append-only history is auditable; superseded decisions stay readable in context.
- The template is short enough for an agent to fill in at decision time.

**Negative**
- One more artifact to maintain; discipline required to actually write the ADR.
- Supersede-don't-delete means the directory grows monotonically.
