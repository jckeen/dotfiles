---
name: vercel-logs
description: Reads full Vercel production runtime logs with the CLI flags that return complete multi-line messages across every branch. Use when debugging a Vercel production or preview error, when a runtime log line looks truncated, when logs for a deployment seem to be missing, or when the user says "check the Vercel logs" or "why is prod erroring".
---

# Vercel logs

Read production errors with the CLI, not the MCP runtime-logs tool:

```bash
vercel logs --expand --no-branch --json
```

- `--expand` returns the full multi-line message. The MCP runtime-logs tool
  truncates each entry to one line, which cuts off the stack trace.
- `--no-branch` is required: without it the CLI silently filters to the
  current git branch, so production errors look absent from a feature branch.
- `--json` gives one object per entry to filter with `jq`.

These flags need a recent CLI. Run `vercel --version` and `vercel logs --help`
first; if a flag is missing, upgrade the CLI rather than dropping the flag.
