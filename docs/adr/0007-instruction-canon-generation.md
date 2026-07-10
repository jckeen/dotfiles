# 0007. Generate the three instruction files from a canonical source

- **Status:** Accepted (resolves #216; enables #206 and #219)
- **Date:** 2026-07-10

## Context

Issue #216 proposed making a root `AGENTS.md` the canonical instruction source,
with `CLAUDE.md` and `GEMINI.md` reduced to thin import shims — cheaper than
maintaining three full files held in parity by CI, and aligned with the
ecosystem's convergence on the AGENTS.md standard. The thin-shim design only
works if every tool can *natively expand* a reference to the canonical file at
load time. That was investigated empirically on this machine (2026-07-10):

- **Claude Code — imports supported.** `claude/CLAUDE.md` already uses `@`
  imports in production (`@~/dev/claude-memory/CLAUDE.md`, `@~/.claude/FABLE.md`)
  and their content demonstrably reaches the session context.
- **Codex CLI 0.141.0 — no import mechanism.** `codex --help` exposes none; the
  official AGENTS.md guide (developers.openai.com → learn.chatgpt.com,
  "agent-configuration/agents-md") documents only hierarchical discovery
  (`~/.codex/AGENTS.override.md` → `~/.codex/AGENTS.md` → per-directory files,
  concatenated root-down, 32 KiB cap) with no include syntax. Live test: an
  `AGENTS.md` containing `@./extra-rules.md` (the referenced file holding a
  unique codeword) was loaded — Codex answered from its body — but reported
  "NO CODEWORD": the reference was not resolved.
- **AGENTS.md standard (agents.md) — no import mechanism defined.** Nested
  files are resolved by directory proximity, not by include directives.
- **Antigravity CLI 1.1.1 — no import mechanism, and no workspace context
  file preload at all.** Live test with tools forbidden and the referenced
  file placed *outside* the workspace: `agy` reported "NO CODEWORD" and could
  not even see the workspace `GEMINI.md` body ("no project mascot in the
  loaded context"). An earlier permissive run only surfaced the codeword via
  cascade tool steps (visible in the run log), i.e. agentic file reading, not
  import resolution. Only the global `~/.gemini/config/GEMINI.md` is preloaded
  (matching this repo's setup.sh symlink and the known agy config quirks).

So native imports exist in exactly one of the three tools. A thin-shim
`GEMINI.md`/`AGENTS.md` would silently load *nothing but the shim line* in two
of them — the worst failure mode for an instruction layer.

## Decision

We accept #216's intent — one canonical place to state a shared rule — via
**generation instead of imports**:

- `agents/canon/CANON.md` holds the shared rule blocks
  (`<!-- canon:ID --> … <!-- /canon:ID -->`); `agents/canon/fragments/<tool>.md`
  holds each tool's voice, layout, and tool-specific rules, pulling shared
  blocks in with `<!-- include:ID -->` lines. Both are SOURCE surfaces.
- `claude/scripts/gen-instruction-files.sh` compiles them into
  `claude/CLAUDE.md`, `codex/AGENTS.md`, and `antigravity/GEMINI.md` — now
  committed GENERATED artifacts carrying a do-not-edit banner. `setup.sh` is
  untouched: the same three paths get symlinked as before.
- `check-agent-parity.sh` gains a byte-currency check (regenerate and diff, so
  hand-edits and stale artifacts fail CI) and keeps the concept checks against
  the generated files, extended to the lane contract and tightened from
  keyword-matching to rule-phrase matching (#206).
- The initial migration is semantics-preserving by construction: every byte of
  the generated files comes verbatim from the previous files, the shared
  blocks being extracted only where the codex and antigravity texts were
  already byte-identical. The word-level diff of the migration shows zero
  removed words — only the banner, two line re-wraps in `GEMINI.md`, and the
  new two-floor grounding block (#219, ADR-0006) added once in canon and
  emitted into all three files.

## Consequences

**Positive**
- A shared rule is edited once and provably reaches all three agents; CI
  asserts both the concepts and the bytes, ending silent hand-edit drift.
- New cross-agent rules (like two-floor grounding) land as one canon block
  instead of three hand-mirrored paraphrases that the old permissive regexes
  could not really verify.
- Per-tool voice and genuinely tool-specific guidance (Fable import wiring,
  agy teammate contract, Codex session continuity) keep their own files.

**Negative**
- Editing an instruction file now takes two steps (edit source, regenerate);
  forgetting the second is caught by CI, not prevented.
- The three loaded files each spend four lines on a generation banner.
- Claude-side text is not deduplicated (its voice shares no byte-identical
  blocks with the other two); its fragment is essentially the whole file, and
  the dedup benefit accrues mainly to new rules and the codex/antigravity pair.

## Alternatives considered

- **Root AGENTS.md + native import shims (the literal #216 proposal)** —
  rejected on the evidence above: two of three tools resolve no import syntax,
  so the shims would load empty.
- **Symlink `GEMINI.md`/`AGENTS.md` at the canonical file** — rejected: it
  forces one voice and one layout on all three tools and leaves nowhere for
  the per-tool content that genuinely diverges today (agy pin verification,
  Codex resume mechanics, Claude's import-based conduct layer).
- **Status quo (three hand-mirrored files + concept regexes)** — rejected:
  #206's audit showed the regexes asserted words, not rules, and the lane
  contract was mirrored by hand with no check at all.
