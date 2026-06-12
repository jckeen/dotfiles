---
name: drift-sweep
description: Bootstrap a repo's doc contract or audit doc drift — declares every markdown surface (LIVING/GENERATED/SOURCE/HISTORICAL), wires the CI doc-truth checker, migrates shadow trackers to GitHub issues, and reconciles out-of-band drift (closed issues, migration high-water marks, stale PRs, ghost worktrees). Use when the user says "drift sweep", "bootstrap the doc contract", "are these docs stale", after a rename or process retirement, or pre-launch.
---

Work in the current repo. Mode is auto-detected: no `.doc-contract` at the
repo root → **Bootstrap**; contract present → **Sweep**.

Spec: ADR 0005 in dotfiles (`docs/adr/0005-doc-contract-drift-prevention.md`).
Contract format: `LIVING|GENERATED|SOURCE|HISTORICAL <glob>` (first match
wins) and `BANNED[:TIER,TIER] <regex>` guard lines.

## Bootstrap mode

1. Inventory: `git ls-files '*.md'`. For each file propose a tier:
   - **LIVING** — updated as a side effect of merges (README, CHANGELOG,
     maintained guides). Keep this list small; prefer deleting a stale doc
     over declaring it.
   - **GENERATED** — produced or asserted by CI/scripts.
   - **SOURCE** — markdown-as-config: skill/agent definitions, templates,
     rule files.
   - **HISTORICAL** — point-in-time records: old audits, dated reviews,
     retired ledgers, plans, ADRs.
   Present the table to the user for confirmation before writing anything.
2. **Shadow trackers get migrated, not tiered.** A checkbox/TODO file
   (TODO.md, LAUNCH_CHECKLIST.md, or any file whose substance is open work
   items): for each open item run
   `gh issue create --title "<item>" --body "Migrated from <file> by drift-sweep"`;
   move closed items worth keeping into CHANGELOG.md. Then delete the file,
   or mark it HISTORICAL if the user wants the record kept.
3. Ask the user for old names, parked domains, and retired hosts; add a
   `BANNED <regex>` line per answer. Propose the checkbox guard
   `BANNED:LIVING,GENERATED ^[[:space:]]*[-*] \[ \]` by default (omit if the repo
   legitimately ships checklists in active docs).
4. Write `.doc-contract` at the repo root.
5. Add the banner to each HISTORICAL file missing one, as a quote line in
   the first 5 lines:
   `> **Historical** — point-in-time record (<today>). Do not act on this.`
   Files with ADR-style `**Status:**` + `**Date:**` headers already pass.
6. Vendor the checker: copy `~/.claude/scripts/check-doc-truth.sh` into the
   repo's script directory (e.g. `scripts/check-doc-truth.sh`), `chmod +x`,
   and wire a CI step that runs it (a job/step in the repo's existing CI
   workflow; create a minimal workflow if the repo has none).
7. Run the checker; fix every violation:
   - dead-ref → fix the path if the target moved; replace the link with
     backticked plain text if the target is gone.
   - banned → repoint prose at the canonical source (a file, a script, the
     live command output) instead of the hardcoded fact.
   - Retirement protocol: for anything newly marked HISTORICAL, run
     `rg -il "system of record|single source of truth|canonical tracker"`
     and repoint every doc that bills the dead thing as authoritative.
8. Ship one PR: contract + vendored checker + CI wiring + all fixes.
   End with a summary of ≤10 lines.

## Sweep mode

1. Run the repo's vendored `check-doc-truth.sh`; collect violations.
2. Out-of-band reconciliation (the gap CI can't see):
   - `gh issue list --state all --limit 200` vs every issue-number mention
     in LIVING/GENERATED docs — fix stale open/closed language.
   - If docs cite a migration/schema high-water mark, compare it against the
     migrations directory (e.g. `prisma/migrations`, `supabase/migrations`).
   - `gh pr list` — surface any PR open >48h with its review + CI state.
   - `git worktree list` — prune ghost worktrees; delete local branches with
     no unique commits (`git branch --merged <default>`).
3. Fix doc items in one small docs PR. End with a ≤10-line summary — or
   just "clean" if nothing drifted.

## Never

- Backfill dead ledgers or fabricate history — banner + repoint and move on.
- Create a new tracker file to fix tracker drift — GitHub issues are the
  only open-work tracker.
- Hardcode a count, SHA, host, or version in prose — point at the canonical
  source CI can assert.
