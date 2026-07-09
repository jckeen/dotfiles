# Review-automation pipeline — design

**Date:** 2026-07-09
**Goal:** Make code review and post-PR comment capture *automatic* so the operator
talks naturally and `/orchestrate` is the main verb. No step should depend on the
operator (or the model) remembering to run a tool.

## Context

- The model runs all git commands in this workflow (confirmed with the operator),
  so **Claude Code hooks** — which fire on the model's tool calls — can enforce and
  automate the loop with no cloud infrastructure for the in-session parts.
- Two reviewers already exist and diverge by design: the **local Codex gate**
  (`codex-review-gate.sh`, pre-push, on the diff) and the **GitHub Codex bot**
  (`chatgpt-codex-connector[bot]`, server-side, after the PR opens). Neither is a
  superset; the bot's comments were being missed because PRs merged before it
  commented.
- Antigravity (`agy`) gained a hardened review gate (`antigravity-review-gate.sh`,
  PR #149) but is not yet wired into the ship flow.

## Design (approach C — enforced + cloud backstop)

1. **Antigravity in the ship flow (local).** Add an advisory Antigravity step to
   `/commit-push-pr` next to the Codex gate. Runs whenever the model ships;
   `/orchestrate` inherits it. Advisory = surfaces findings but Codex + CI remain
   the authoritative merge gate (ADR-0003).

2. **Push-guard hook (local, warn-only).** A `PreToolUse` Bash hook matching
   `git push` that warns (never blocks — matches `PrePushStaleSHACheck` philosophy,
   always exit 0) when HEAD has no review receipt. Signals a skipped review at push
   time without wedging docs-only / revert / hotfix pushes.

3. **Stop-hook harvest (local).** A `Stop` hook that, at end of turn, finds any PR
   the session touched, pulls new `chatgpt-codex-connector[bot]` review comments,
   and files one deduped GitHub issue per actionable comment. Captures bot comments
   while the session is still open. Best-effort: a PR opened right before the turn
   ends may not have bot comments yet — that gap is closed by (4).

4. **Cloud backstop (RemoteTrigger).** Fold a Codex-bot-comment sweep into the
   existing **`nightly-docs-steward`** routine (daily 07:00 UTC, already sources 7
   fleet repos). Catches comments that land after the session ends, fleet-wide,
   within a day. **Depends on the `GH_TOKEN` fix below.**

## Dependency: cloud `GH_TOKEN` rotation (operator action)

All 11 cloud routines authenticate via a fleet-wide `GH_TOKEN` env var in the
`My Cloud Environment` Claude Cloud environment. Routines are failing because that
secret expired/lost scope (their own prompts say to STOP and report on 403). The
secret lives in claude.ai environment settings — not reachable from the local
shell or the routine API. Fix: mint a fine-grained PAT over all `jckeen` repos with
Contents + Issues + Pull requests (Read & Write), update the `GH_TOKEN` secret at
claude.ai, and "Run now" one routine to confirm. The cloud backstop (4) is inert
until this is done.

## Mechanism notes

- Hook files live in `claude/hooks/` (dotfiles); wiring lives in the live
  `~/.claude/settings.json` `hooks` block, whose source is the private
  `claude-memory` repo. Both the hook file and the wiring must land.
- Review receipt for the push guard: the review gates write a marker
  (`.git/.last-review-<sha>` or similar) that the guard reads; absence → warn.

## Out of scope (YAGNI)

- Hard-blocking push guard (chosen: warn-only).
- A dedicated new routine for the backstop (chosen: fold into `nightly-docs-steward`).
- Automating cloud-secret rotation (not reachable locally).
