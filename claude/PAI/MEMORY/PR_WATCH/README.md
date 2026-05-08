# PR_WATCH — Standing PR Review Loop

State directory for the auto-PR-watch workflow. Drives the review→edit→re-review loop without manual `Monitor` invocation.

## Flow

1. You open a PR via `gh pr create` (or `mcp__github__create_pull_request`).
2. **PostToolUse hook** `~/.claude/hooks/PRWatcherAutoLaunch.hook.ts` parses the PR URL, spawns `~/.claude/PAI/TOOLS/WatchPRReviews.ts` detached in the background, and records the PID in `active.json`.
3. The watcher polls every 30s. On every new event (review, inline comment, issue comment, CI rollup change, state change), it:
   - prints to its `watcher-<owner>-<repo>-<pr>.log`
   - POSTs a banner notification to `localhost:31337/notify` (audio off — voice every event would be too loud)
   - appends a JSONL row to `queue.jsonl`
4. **UserPromptSubmit hook** `~/.claude/hooks/PRWatcherSurface.hook.ts` reads new lines from `queue.jsonl` (past `.surfaced-cursor`) and prepends a `🔔 OPEN PR FEEDBACK` block to my next prompt's context. So the next time you message me — about anything — I see the unaddressed feedback and act on it.
5. When the PR merges or closes, the watcher emits `[shutdown]`, removes itself from `active.json`, and exits 0.

The watcher honors `feedback_pr_codex_review`: it surfaces Codex 👍 reactions and stale-SHA caveats via the inline comment / review payloads. Auto-merge on clean is **not** wired in v1 (`--auto-merge` flag reserved); ship that after observing v1 in the wild.

## On-disk shape

```
~/.claude/PAI/MEMORY/PR_WATCH/
├── README.md                                 (this file)
├── active.json                               (array of {pr, repo, pid, started_at, log_path})
├── queue.jsonl                               (append-only events)
├── .surfaced-cursor                          (byte offset surfaced into context)
├── spawn.log                                 (auto-launch hook diagnostic)
└── watcher-<owner>-<repo>-<pr>.log           (one per active watcher; raw stdout)
```

`active.json` example:

```json
[
  { "pr": 42, "repo": "jckeen/atlas", "pid": 12345,
    "started_at": "2026-05-08T15:30:00.000Z",
    "log_path": "/home/jckee/.claude/PAI/MEMORY/PR_WATCH/watcher-jckeen-atlas-42.log" }
]
```

`queue.jsonl` row:

```json
{"ts":"2026-05-08T15:31:12.000Z","kind":"review","pr":42,"repo":"jckeen/atlas","line":"[review] PR #42 jckeen/atlas COMMENTED by chatgpt-codex-connector on a1b2c3d4 | 1 P1 finding inline"}
```

## Manual operations

- **List active watchers:** `jq . ~/.claude/PAI/MEMORY/PR_WATCH/active.json`
- **Stop a specific watcher:** `kill <pid>` (entry will be reaped on next auto-launch hook tick)
- **Stop all watchers:** `pkill -f WatchPRReviews.ts && echo '[]' > ~/.claude/PAI/MEMORY/PR_WATCH/active.json`
- **Replay surfaced events:** `cp /dev/null ~/.claude/PAI/MEMORY/PR_WATCH/.surfaced-cursor` (next prompt will surface every actionable event in the queue)
- **Watch one PR manually anyway:** the original Monitor pattern still works — see `reference_pr_review_watcher.md`.

## Why not a daemon?

A persistent supervisor would have to run independent of any session. Watchers are short-lived (die when the PR merges), the spawn cost is one `gh` call per 30s, and `active.json` self-heals on the next prompt via `pidAlive` reaping. Adding systemd / pm2 was out of scope for v1.
