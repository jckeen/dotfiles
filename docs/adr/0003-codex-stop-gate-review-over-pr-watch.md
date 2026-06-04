# 0003. Codex stop-gate review over a PR-comment-watching loop

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

Decommissioning PAI (ADR-0002) removed the PR-watcher hooks that auto-launched a
background watcher on `gh pr create` and surfaced reviewer/CI events into the
session (`PRWatcherAutoLaunch`, `PRWatcherSurface`, `PromptProcessing`). That
left an open question: do we rebuild an equivalent PR-comment-watching loop on
the lean baseline, or review by some other means? Polling a PR for review
comments and re-launching a fix loop is inherently latency-bound — it waits on
asynchronous reviewer/CI events to arrive.

## Decision

We do not rebuild the PR-watching loop. Instead we rely on **Codex review at
stop-time plus CI green** as the quality gate. Codex performs a review when the
agent stops (the stop-gate), catching issues before the change is pushed, and CI
status on the PR is the authoritative merge gate. Review happens synchronously,
in-session, rather than by watching for comments to land after the fact. The
`commit-push-pr` skill surfaces `gh pr checks` after opening a PR so CI status
is visible without a watcher.

## Consequences

**Positive**
- Simpler: no background watcher, no event-surfacing hooks, no daemon to keep alive.
- No waiting on review comments to arrive — feedback is in-session at stop-time.
- The gate is unambiguous: Codex review at stop + CI green on the PR.

**Negative**
- No automatic in-session surfacing of *human* review comments left after the
  fact — those must be pulled in manually (e.g. via `gh`).
- Quality depends on the Codex stop-gate being enabled and on CI actually
  covering the relevant checks.
