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
- Keep changes scoped to the request — no unrequested refactors or cleanup.
- Default to no comments; add one only when the *why* is non-obvious.
- Be concise. State results and decisions, not running commentary.
- If the same error appears 3+ times, stop and explain the root cause instead of
  retrying. Course-correct early if the approach turns out to be wrong.

## Tech stack

- **TypeScript** primary; **bun** as the runtime — never npm/npx.
- In Bash, prefer `rg`, `fd`, `bat`, `eza` over `grep`/`find`/`cat`/`ls`. In
  portable code that ships to others, use language-native fs APIs and prefer
  `find` over `fd` (fd isn't guaranteed installed).
- Never hardcode user paths — use `$HOME` or relative paths.
- Explicit error handling; never silently swallow errors.

## Session start

- Read `CLAUDE.md` and `CHANGELOG.md` if present; run `git status` and
  `git log --oneline -5` to orient. If a project has no `CLAUDE.md`, offer to
  bootstrap one.

## Verification

- Give yourself a way to check the work: run the tests, the types, or the app.
- Don't claim something works without evidence from a tool.
- Address root causes, not symptoms. When fixing a bug, write a failing test
  that reproduces it first, then fix it.

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
