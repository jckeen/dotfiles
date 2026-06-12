# 0005. Prevent doc drift with a per-repo doc contract, CI checker, and drift-sweep skill

- **Status:** Accepted
- **Date:** 2026-06-12

## Context

A reconciliation audit in operator-commons found 62 drifted doc items and six
generalizable root causes: PR-loop surfaces stay fresh while pull-based
surfaces freeze; methodology artifacts outlive their methodology; out-of-band
state changes (dashboard issue closes, MCP-applied migrations) trigger no doc
event; volatile facts hardcoded in prose; rename residue; and multi-session
parallelism without a hygiene contract. The pattern applies to every active
repo. The governing principle: **a doc surface is either generated/CI-asserted,
updated as a side effect of the merge loop, or explicitly marked historical —
anything requiring a separate remembering-event WILL drift.**

## Decision

We will add a portable three-part system to dotfiles, then roll it out per
repo via a skill:

1. **A per-repo `.doc-contract` manifest** declaring every tracked Markdown
   file as exactly one of LIVING, GENERATED, SOURCE, or HISTORICAL, plus
   BANNED pattern guards.
2. **A portable checker, `claude/scripts/check-doc-truth.sh`**, that asserts
   the contract in CI (fail-closed, bash + git + grep only).
3. **A `/drift-sweep` skill** with two auto-detected modes: *bootstrap* (write
   the contract into a repo, banner historical docs, wire CI, fix first-run
   violations) and *sweep* (audit the out-of-band gap: closed issues vs
   tracker checkboxes, migration high-water marks, stale PRs, ghost
   worktrees).

Dotfiles adopts its own contract first and serves as the template. The global
CLAUDE.md gains a short "Doc contract" section; the handoff skill gains
session-end hygiene steps.

## Specification

### `.doc-contract` format (repo root)

```
# tier        path-or-glob (bash glob, repo-relative)
LIVING        README.md
LIVING        CHANGELOG.md
GENERATED     docs/tools.md
SOURCE        claude/skills/*/SKILL.md
HISTORICAL    docs/audits/*.md
# guard       extended regex (grep -Ei), scanned over LIVING+GENERATED+SOURCE
BANNED        Agent Commons
BANNED        \b[0-9]{2,}\+? (tests|tools)\b
```

- Tier matching is **first-match-wins**, top to bottom (like .gitignore).
- `#` comments and blank lines ignored.
- **SOURCE** is for Markdown that is executable config rather than a doc
  surface (skill definitions, agent prompts, templates): no banner, no
  dead-ref check, but BANNED patterns still apply — rename residue hides in
  skill frontmatter.
- `BANNED` takes an optional tier scope: `BANNED:LIVING,GENERATED <regex>`.
  Unscoped BANNED lines apply to LIVING+GENERATED+SOURCE. The default
  checkbox guard is proposed scoped to `LIVING,GENERATED` — PR templates and
  plan-executing skills (SOURCE) legitimately contain checkboxes.

### Checker rules (`check-doc-truth.sh`)

Each violation prints `file:line — rule — message`; any violation exits 1.

1. **Coverage:** every git-tracked `*.md` must match a tier entry. An
   undeclared doc fails CI — forcing the tier decision at creation time.
2. **Stale entries:** a non-glob contract path matching no tracked file fails
   (the contract itself must not drift). Glob entries may match zero files.
3. **Historical banner:** every HISTORICAL file must contain the marker
   `Historical` and `point-in-time` (case-insensitive) within its first 5
   lines. Canonical banner:
   `> **Historical** — point-in-time record (YYYY-MM-DD). Do not act on this.`
   An ADR-style header (`**Status:**` + `**Date:**` in the first 5 lines)
   also satisfies the rule — ADRs carry their own temporal marker.
4. **Dead refs:** every relative Markdown link target in LIVING + GENERATED
   docs must exist on disk (anchors and external URLs ignored). Files named
   `CHANGELOG*` are exempt: changelogs are append-only narrative whose old
   links rot legitimately; rewriting history is worse than the rot.
5. **Banned patterns:** no BANNED regex may match in LIVING, GENERATED, or
   SOURCE docs. HISTORICAL docs are exempt — old audits legitimately name old
   things.
6. **No shadow trackers (default guard):** bootstrap proposes
   `BANNED:LIVING,GENERATED ^\s*[-*] \[ \]` — an unchecked checkbox in an active doc fails CI,
   forcing open work into GitHub issues. Per-repo opt-out by omitting the
   line (e.g. a repo that legitimately ships a setup checklist).

Keep LIVING small — every entry is a freshness promise the merge loop must
keep. Deleting an obsolete doc is always preferable to declaring it — a
wrong doc is worse than no doc.

### `/drift-sweep` skill

- **Bootstrap mode** (no `.doc-contract` in repo): inventory tracked `*.md`,
  propose tiers for user confirmation, write the contract, add historical
  banners, wire `check-doc-truth.sh` into the repo's CI, then fix everything
  the first run flags (rename residue, dead refs, hardcoded counts → repoint
  at canonical sources). Retirement protocol: when billing a doc historical,
  also `rg -il "system of record|single source of truth|canonical tracker"`
  and repoint every doc that cites it as authoritative.
  **Shadow trackers get migrated, not tiered:** a checkbox/TODO file
  (TODO.md, LAUNCH_CHECKLIST.md, …) is offered no tier — bootstrap proposes
  migrating each open item to a GitHub issue (closed items to the changelog
  if worth keeping), then deleting the file or marking it HISTORICAL.
  GitHub issues/milestones are the only open-work tracker.
  **Distribution:** bootstrap vendors a copy of the checker into the target
  repo (its scripts dir) and wires a CI step — CI stays self-contained. The
  canonical copy lives in dotfiles `claude/scripts/check-doc-truth.sh`.
- **Sweep mode** (contract exists): run the checker repo-wide; diff
  `gh issue list --state closed` against open checkboxes/issue mentions in
  tracker docs; compare migration high-water marks in docs vs the migrations
  dir; flag PRs open >48h with review state; prune ghost worktrees and
  0-unique-commit branches (delegating to git-hygiene.sh). Output: one small
  docs PR plus a ≤10-line summary, or "clean".

After bootstrap, CI holds the line on everything merge-loop-originated; sweep
mode is only needed occasionally for the out-of-band gap. Wiring sweep into
the existing git-hygiene.timer remains a documented one-liner, deliberately
not done now.

### Global guidance + handoff additions

- `claude/CLAUDE.md` "Definition of done" gains the doc-contract rules:
  three tiers, retirement protocol, never hardcode volatile facts in prose CI
  can't assert, GitHub issues are the only open-work tracker (files may point
  at them, never duplicate them), plans/scratch live outside the repo.
- The handoff skill adds session-end hygiene: prune own worktrees and
  0-unique-commit branches, push or PR every branch, note review state of any
  open PR in the handoff.
- The PR template names the LIVING doc surfaces so the docs sweep is a
  diff-able artifact, not a judgment call.

## Consequences

**Positive**
- Drift originating in the merge loop becomes a CI failure instead of a
  remembering-event; rename residue and rotting counts are blocked at PR time.
- One-time bootstrap per repo; after that the contract maintains itself
  (undeclared docs fail CI immediately).
- Checker is dependency-free bash — portable to non-TypeScript repos.

**Negative**
- Every new Markdown file requires a one-line contract entry (intentional
  friction: it forces the tier decision).
- The out-of-band gap (dashboard closes, MCP migrations) is narrowed, not
  closed — sweep mode must be run occasionally.
- BANNED regexes can false-positive; the escape hatch is moving the doc to
  HISTORICAL or refining the pattern, both explicit acts.

## Alternatives considered

- **Prose-only contract in CLAUDE.md** — CI can't assert it; the contract
  itself becomes a pull-based surface and drifts.
- **Directory convention (docs/archive = historical)** — forces file moves in
  every repo, can't express per-file exceptions.
- **Scheduled cloud sweep per repo** — recurring cost and auth complexity for
  a gap that's cheap to audit on demand; revisit if out-of-band drift recurs.
