# Global Claude Code Instructions

Portable global guidance for all projects — the public, anyone-can-use layer.
A project's own `CLAUDE.md` always takes precedence over this file.

## Personal context

Identity, org context, and private preferences are **not** kept here — this repo
is public. They live in a separate, private `claude-memory` repo and are pulled
in via the import below. If you cloned these dotfiles, point this at your own
`claude-memory` or delete the line; everything below works without it. See the
README's "The private memory repos" section for how to set up `claude-memory`.

@~/dev/claude-memory/CLAUDE.md

## Working style

- Plan before non-trivial work. Confirm the approach, then execute.
- If the goal is unclear, ask before coding — don't guess at intent.
- Prefer editing existing files over creating new ones.
- Read the surrounding code before changing behavior — prefer the existing
  patterns over new abstractions.
- Keep changes scoped to the request — no unrequested refactors or cleanup.
- Default to no comments; add one only when the *why* is non-obvious.
- Be concise. State results and decisions, not running commentary.
- Match ceremony to the task. A clear tactical ask ("add this line", "run this
  check") gets done and reported — no plan, no variants, no preamble. Reserve
  heavyweight planning for genuinely complex work.
- Lead with the state change. When a merge, approval, CI result, or deploy
  lands, open the reply with one status line (`✅ PR #N merged`) before detail —
  don't bury it in tool output.
- If the same error appears 3+ times, stop and explain the root cause instead of
  retrying. Course-correct early if the approach turns out to be wrong.

## Tech stack

- **TypeScript** primary; **bun** as the runtime — never npm/npx.
- In Bash, prefer `rg`, `fd`, `bat`, `eza` over `grep`/`find`/`cat`/`ls`. In
  portable code that ships to others, use language-native fs APIs and prefer
  `find` over `fd` (fd isn't guaranteed installed).
- Never hardcode user paths — use `$HOME` or relative paths.
- Explicit error handling; never silently swallow errors.
- Use the latest stable version of any dependency — don't trust versions from
  training data. Check the registry before adding; run `npm outdated` after.
- Calling an external API: fetch the live reference for that exact endpoint and
  version at code-time — verify every field, param, and scope against the live
  page rather than extrapolating from memory.

## Session start

- Read `CLAUDE.md` and `CHANGELOG.md` if present; run `git status` and
  `git log --oneline -5` to orient. If a project has no `CLAUDE.md`, offer to
  bootstrap one.

## Verification

- Give yourself a way to check the work: run the tests, the types, or the app.
- Don't claim something works without evidence from a tool. Report any test you
  could not run rather than silently skipping it.
- Address root causes, not symptoms. When fixing a bug, write a failing test
  that reproduces it first, then fix it.
- Audit during the build, not at a final gate. The moment a risky surface (auth,
  path/host handling, file IO, schemas, hash chains) has a complete first draft,
  run the security/review pass then — in parallel with continuing. Auditing at
  the discovery moment collapses rework cycles.
- Re-run a subagent's "verified via X" claim yourself when it contradicts what
  you can check directly — empirical beats confident assertion. The underlying
  concern may still be real even if its verification line was hallucinated.
- Promote a "must NOT happen" requirement from discipline into code/CI whenever
  the fix is small (~<50 LOC) — a checklist item waiting to be remembered is the
  failure it guards against (schema refinement on env, host allowlist, a CI gate).
- A reviewer's finding is usually a category, not an instance. Before pushing the
  fix, sweep the same neighborhood — sibling routes, every path resolution, every
  shell flag — and ship the unified fix in one pass.
- When an audit, review, or verification pass surfaces a real, actionable finding,
  file a GitHub issue for it without asking — this is pre-authorized. One issue per
  distinct finding, with repro/evidence and a suggested fix. Don't file for trivia
  or anything already tracked. This is judgment-based, so it lives here as a
  standing order, not as a hook (hooks fire on lifecycle events and can't judge
  whether a finding is worth filing).
- Debugging Vercel prod errors: use `vercel logs --expand --no-branch --json`
  (CLI ≥54) for full multi-line messages — the MCP runtime-logs tool truncates
  to one line, and the CLI silently filters to the current git branch without
  `--no-branch`.

## Definition of done

- Docs are part of "done," not a follow-up. For any substantive change —
  especially a removal, migration, or refactor — update every doc surface in the
  same pass: READMEs, CONTRIBUTING, `docs/`, and the relevant `CLAUDE.md`. Keep
  history accurate (changelogs and dated archives may name removed things) but
  make active guidance reflect the present; verify with a `grep -ri <removed>`.
- Treat `CHANGELOG.md` as living: update it every 1–2 meaningful commits,
  appending rather than rewriting — not batched to end-of-session, which gets
  lost when a session ends early.
- Doc contract: a repo's Markdown surfaces are declared in a root
  `.doc-contract` (LIVING / GENERATED / SOURCE / HISTORICAL + BANNED guards)
  and asserted in CI by `check-doc-truth.sh`; bootstrap or audit one with
  `/drift-sweep` (ADR 0005 in dotfiles). Keep LIVING small — a wrong doc is
  worse than no doc; delete or mark HISTORICAL rather than let it freeze.
- Never hardcode a count, version, SHA, or hostname in prose that CI can't
  assert — point at the canonical source instead. GitHub issues are the only
  open-work tracker: docs may link issues, never duplicate their state
  (no TODO.md / checklist files).
- Retiring a process or doc: same day, add the historical banner
  (`> **Historical** — point-in-time record (date). Do not act on this.`),
  then `rg -il "system of record|single source of truth|canonical tracker"`
  and repoint every doc that bills the dead thing as authoritative.

## Parallel agents

- Never run multiple agents editing the same files at once — they make
  conflicting assumptions about names, signatures, and imports. Parallelize
  read-only work (review, research) and non-overlapping new files freely; for
  shared-file edits use staged sequential rounds, verifying (lint/test/build)
  between rounds. The same applies to two interactive sessions sharing one git
  checkout — one owner at a time.

## Multi-agent teamwork

When Codex (`cx`) and Antigravity share this repo, we're one team coordinating
through artifacts — instructions + skills (loaded identically via the AgentPack),
GitHub issues, `handoff` notes, and git — not a shared chat. Full role table and
rationale: `MULTI-AGENT.md`. The operative rules:

- **Lanes (defaults, not walls):** I'm the conductor — plan/decompose, hold the
  through-line, drive the main implementation, own handoffs + issues + changelog.
  Codex is the independent verifier + rescue (refute my fix on a fresh checkout,
  reimplement to cross-check, deep root-cause when I'm stuck). Antigravity owns
  runtime/browser verification and front-end surfaces.
- **One owner of the working tree at a time** — the Parallel agents rule applies
  across tools too. Each agent gets its own worktree, or edits are sequenced.
- **Verification is adversarial, not an echo chamber** — three agents agreeing
  can be one blind spot voted thrice. Assign the refuter role explicitly; route
  disagreement to a fix, not a tie-break.
- **Handoff payload:** when I hand to Codex/Antigravity, the note carries the
  *claim to disprove* and the *exact repro command*, not just "please review."

## Git

- Only commit when asked. Never push to shared branches without confirmation.
- Use conventional commit messages: `type: short description`
  (`feat`, `fix`, `refactor`, `chore`, `docs`, `test`).
- Stage specific files — avoid `git add -A` / `git add .` so secrets and
  generated files don't slip in. Never stage `.env`, credentials, tokens, keys.

## Auth at the boundary

If a service could ever need auth, build it in from the first commit. Never
assume "auth will be added later" or "the layer above handles it." Across six
repos, every CWE-306 finding traced to the same *auth-by-config* pattern — a
route that authenticates only when an env var is set, trusting some upstream
layer to catch it. For any new entry point (HTTP route, IPC accept-loop,
WebSocket upgrade, external-input queue consumer, mutating CLI subcommand):

1. Auth-by-default, not auth-by-config — the framework wiring forces it.
2. Refuse to start if the auth secret is unset or too short.
3. Opt-out is explicit, named, and greppable (e.g. `@PublicRoute(reason="…")`).
4. Never trust upstream layers — each layer rejects on its own.
5. Failure mode is closed — if the auth check throws, reject the request.
6. Local dev uses a real token through the same verifier — no skip-auth branch.
