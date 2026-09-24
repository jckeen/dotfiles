# Canonical shared agent rules (ADR-0007)

This file is the single source for the rules every agent on this config —
Claude Code, Codex, Antigravity, and the cloud routine lane (ADR-0009) — must
agree on word-for-word. Native import mechanisms are not universal (only Claude
Code resolves `@` imports; Codex and Antigravity have none — evidence in
ADR-0007), so the instruction files are **generated build artifacts**:

- `claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md` and the root
  `AGENTS.md` are built by `claude/scripts/gen-instruction-files.sh` from the
  per-tool skeletons in `agents/canon/fragments/` plus the shared blocks below.
  The generator's target map is the authoritative list.
- Edit a shared rule HERE (once), per-tool voice in the fragment, then
  regenerate and commit both. CI (`check-agent-parity.sh`) fails when a
  generated file is hand-edited or stale.
- The root `AGENTS.md` is the short brief a cloud agent reads from the checkout
  itself, so it carries only the rules that survive without session history. Its
  concepts are not held in phrase parity with the three local files; byte
  currency against `fragments/jules.md` is what CI asserts.

Each block is delimited by `<!-- canon:ID -->` … `<!-- /canon:ID -->`; a
fragment pulls it in with a line of the exact form `<!-- include:ID -->`.
Prose outside blocks (like this preamble) is never emitted.

## Authorized work (every local runtime)

<!-- canon:authorized-work -->
- Proceed with clear, in-scope work and honor explicit requests and applicable
  standing authorizations. Ask when missing information prevents progress or
  an action requires approval that has not already been given.
<!-- /canon:authorized-work -->

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
Claude Code carries the same ownership and verification rules in its fragment.

<!-- canon:team-hard-rules -->
- **One owner of the working tree at a time** — never edit the same files as
  another agent concurrently. Use a separate worktree, or sequence the edits.
- **Verification is adversarial, not an echo chamber** — three agents agreeing
  can be one blind spot voted thrice. When handed a "verify X" task, try to
  break it; report the disagreement rather than confirming by default.
- **Review independence:** a fresh context reduces inherited assumptions;
  high-risk changes also require a reviewer from a different model family.
  Record the actual reviewer evidence; a requested model label alone does not
  establish the model used, and a text-diff review is not browser evidence.
- **Handoff payload:** a handoff to me should carry the *claim to disprove* and
  the *exact repro command*. If it doesn't, ask for them before "reviewing."
- **Selected services are authoritative.** The operator's agent-service
  selection (`setup.sh --show-services`; machine-local at
  `$XDG_CONFIG_HOME/dotfiles/services`, all three when unset) bounds which
  runtimes you assign roles, handoffs, and review lanes to. When a step needs a
  capability that only an unselected runtime provides, report it as unavailable
  and stop for the operator. Do not install, sign in to, or launch that runtime
  to fill the gap, and do not downgrade the required lane. Ownership,
  verification, and independent-review rules still apply: with one selected
  runtime, independent review is a fresh-context session or subagent of that
  runtime, and the verdict says so.
<!-- /canon:team-hard-rules -->
