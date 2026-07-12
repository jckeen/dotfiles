---
name: drift-sweep
description: Bootstrap or audit a repository documentation contract, classify Markdown truth surfaces, migrate shadow trackers to GitHub issues, and reconcile stale operational facts. Use when the user says drift sweep, asks whether docs are stale, retires or renames a process, wants a .doc-contract, or is preparing a launch.
---

# Drift Sweep

Work in the current repository. Read ADR 0005 in the dotfiles repository when
available. Use bootstrap mode when `.doc-contract` is absent and sweep mode when
it exists.

The contract format is `LIVING|GENERATED|SOURCE|HISTORICAL <glob>` with first
match winning, plus optional `BANNED[:TIER,TIER] <regex>` guards.

## Bootstrap

1. Inventory tracked Markdown with `git ls-files '*.md'` and propose a tier for
   each file:
   - `LIVING`: maintained by normal product or release work; keep this set small.
   - `GENERATED`: produced or asserted by scripts or CI.
   - `SOURCE`: Markdown used as configuration, skills, templates, or rules.
   - `HISTORICAL`: point-in-time plans, audits, reviews, and retired records.
2. Present the classification before writing it. Prefer deleting stale guidance
   over declaring it living.
3. Migrate shadow trackers instead of tiering them. Move genuine open work into
   GitHub issues, preserve worthwhile completed history in the changelog, then
   delete or mark the old tracker historical.
4. Ask for retired names, domains, and hosts that should become `BANNED` guards.
   Propose a no-unchecked-checkbox guard for living/generated docs unless the
   repository intentionally ships active checklists.
5. Write `.doc-contract`. Add the standard dated historical banner near the top
   of historical files that lack an ADR-style status/date header.
6. Vendor `check-doc-truth.sh` from the dotfiles scripts into the repository's
   script directory and wire it into existing CI.
7. Run the checker and fix dead references, banned facts, and authoritative
   links to retired sources. Search for prose that still calls newly historical
   material the system of record or canonical tracker.
8. Ship the contract, checker, CI wiring, and fixes together through the
   repository's normal PR workflow.

## Sweep

1. Run the vendored checker and collect every violation.
2. Compare issue references in living/generated docs against current GitHub
   issue state.
3. Compare documented migration or schema high-water marks against canonical
   migration directories.
4. Inspect stale PRs and ghost worktrees. Do not delete branches or worktrees
   with unique or unintegrated work.
5. Fix verified drift in one small documentation change, or report `clean` when
   nothing is stale.

## Guardrails

- Never fabricate history or backfill a retired ledger.
- Never create another tracker file to replace a stale tracker.
- Never hardcode an unstable count, SHA, version, or host in prose when CI
  cannot assert it.
- Treat issue creation, branch deletion, and publication according to the
  repository's authorization rules; do not infer broader external authority.
