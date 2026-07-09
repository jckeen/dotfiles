---
name: browser-verify
description: "Use when handed a runtime or browser verification task: prove a change actually works end-to-end in a running app, adversarially. Requires the Playwright MCP server (global mcp_config). Produces a verdict plus evidence other agents can audit."
---

# Browser Verify

This is the runtime/browser verification lane from the multi-agent contract:
the conductor hands over a claim, this skill tries to BREAK it in a real
browser, and the verdict — with evidence — becomes an artifact the whole team
can audit.

## Required payload

A verification handoff must carry (ask for anything missing before starting):

1. **Target** — URL or route, and how to start the app if not running.
2. **Flow** — the exact steps to drive (click X, submit Y, expect Z).
3. **Expected observable** — what SHOULD happen, stated concretely.
4. **Claim to disprove** — the falsifiable statement under test.

## Workflow

1. Confirm the Playwright MCP tools are available (`/mcp` lists servers). If
   absent, stop and report — do not fake a verification with static reading.
2. Start or reach the app; navigate the flow EXACTLY as specified first.
3. Then get adversarial: bad input, rapid repeats, back/forward, refresh
   mid-flow, empty states, small viewport. You are here to refute the claim,
   not confirm it.
4. Capture evidence as you go: screenshots at each decisive step, console
   errors, failed network requests.
5. Copy evidence to the shared path other agents read:
   `~/.claude/handoffs/evidence/YYYY-MM-DD-<short-slug>/`
   (create it; screenshots, console log excerpts, a one-line INDEX.md naming
   each file's moment).
6. Report the verdict:
   - **REFUTED** — the claim broke: exact step, observed vs expected, evidence file.
   - **HELD** — survived the specified flow AND the adversarial pass (list what was tried).
   - **BLOCKED** — could not complete verification: what stopped it.
7. Write or append a handoff note (`~/.claude/handoffs/YYYY-MM-DD-<project>-handoff.md`)
   with the verdict and the evidence path, so the verdict outlives this session.

## Rules

- A verdict without evidence files is not a verdict — capture before reporting.
- Disagreement with the conductor's claim is the valuable outcome; report it
  plainly with the repro, never soften it to "mostly works".
- Never test against production with destructive inputs; use local/dev targets
  unless the handoff explicitly says otherwise.
