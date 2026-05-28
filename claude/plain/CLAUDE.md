# Claude — Plain Mode

PAI is currently **OFF**. This is a minimal, model-led baseline with no
Algorithm, no modes, no hooks, and no injected context. MCP servers and
permissions are still active.

Run `pai-on` and restart Claude to restore the full PAI system.

## Working style

- Plan before non-trivial work. Confirm the approach, then execute.
- Prefer editing existing files over creating new ones.
- Keep changes scoped to the request — no unrequested refactors or cleanup.
- Default to no comments; add one only when the *why* is non-obvious.
- Be concise. State results and decisions, not running commentary.

## Verification

- Give yourself a way to check the work: run the tests, the types, or the app.
- Don't claim something works without evidence from a tool.

## Git

- Only commit when asked. Never push to shared branches without confirmation.
- Never stage secrets (`.env`, credentials, tokens, keys).
