# Canonical shared agent rules (ADR-0007)

This file is the single source for the rules every agent on this config —
Claude Code, Codex, and Antigravity — must agree on word-for-word. Native
import mechanisms are not universal (only Claude Code resolves `@` imports;
Codex and Antigravity have none — evidence in ADR-0007), so the three
instruction files are **generated build artifacts**:

- `claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md` are built by
  `claude/scripts/gen-instruction-files.sh` from the per-tool skeletons in
  `agents/canon/fragments/` plus the shared blocks below.
- Edit a shared rule HERE (once), per-tool voice in the fragment, then
  regenerate and commit both. CI (`check-agent-parity.sh`) fails when a
  generated file is hand-edited or stale.

Each block is delimited by `<!-- canon:ID -->` … `<!-- /canon:ID -->`; a
fragment pulls it in with a line of the exact form `<!-- include:ID -->`.
Prose outside blocks (like this preamble) is never emitted.

## Conduct layer (Codex, Antigravity)

Claude Code loads FABLE.md via its native `@` import in its own fragment;
the other two carry this pointer paragraph.

<!-- canon:conduct-layer -->
At session start, read `~/.claude/FABLE.md` (in this repo: `claude/FABLE.md`)
and follow it — the operating discipline shared by every agent on this config:
outcome-first final messages, readable-over-concise prose, the
reversible/destructive/assessment autonomy switch, the end-of-turn self-check,
and evidence discipline. If a session drifts from it, re-read the file and run
its pre-send checklist.
<!-- /canon:conduct-layer -->

## Core working style (Codex, Antigravity)

Claude Code phrases the same rules in its own fragment (Working style +
Verification sections); the parity RULES in `check-agent-parity.sh` assert
the concepts stay present in all three generated files.

<!-- canon:working-style-core -->
- Treat the worktree as shared with the user; do not revert changes you did not
  make unless explicitly asked.
- Read the surrounding code before changing behavior.
- Prefer the repository's existing patterns over new abstractions.
- Keep edits scoped to the requested behavior.
- Verify meaningful changes with the smallest useful test or static check.
- Report any test you could not run.
<!-- /canon:working-style-core -->

## Two-floor grounding (all three; ADR-0006, #219)

<!-- canon:two-floor -->
- Two-floor grounding (ADR-0006): an adopt/skip verdict on an external
  technology must clear a *project floor* (a verified local fact) and an
  *external floor* (a verified source) — neither compensating for the other.
<!-- /canon:two-floor -->

## Multi-agent hard rules (Codex, Antigravity)

The lane contract from `claude/MULTI-AGENT.md`: one owner of the working
tree, adversarial verification, and the claim-to-disprove handoff payload.
Claude Code carries the conductor-voice equivalent in its fragment.

<!-- canon:team-hard-rules -->
- **One owner of the working tree at a time** — never edit the same files as
  another agent concurrently. Use a separate worktree, or sequence the edits.
- **Verification is adversarial, not an echo chamber** — three agents agreeing
  can be one blind spot voted thrice. When handed a "verify X" task, try to
  break it; report the disagreement rather than confirming by default.
- **Handoff payload:** a handoff to me should carry the *claim to disprove* and
  the *exact repro command*. If it doesn't, ask for them before "reviewing."
<!-- /canon:team-hard-rules -->
