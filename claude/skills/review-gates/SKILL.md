---
name: review-gates
description: Multi-agent review-gate mechanics for repos shared with Codex and Antigravity — which gate lane a change requires, how to run and check a receipt, the handoff payload (claim to disprove + exact repro), review independence, and persisting verdicts. Use before running any review gate, before handing work to another agent, before merging, or when a gate refuses a receipt.
---

# Review gates and multi-agent handoffs

The always-loaded rules (one owner of the working tree, adversarial
verification, claim-to-disprove handoffs, verdicts as artifacts) live in the
global instructions. This skill carries the mechanics. Full role table and
rationale: `MULTI-AGENT.md` in the dotfiles repo.

## Assign roles explicitly

The active session is the conductor and owns planning, integration,
verification, delivery, and handoffs. Assign bounded implementation,
independent review, or runtime/browser verification to agents with the needed
capabilities. Any runtime can conduct or implement; personal defaults belong in
private preferences. Refute, don't rubber-stamp.

## One owner of the working tree

The Parallel agents rule applies across tools too. Each agent gets its own
worktree, or edits are sequenced. Never run two agents editing the same files
at once, and never share one git checkout between two interactive sessions.

## Verification is adversarial

Three agents agreeing can be one blind spot voted thrice. Assign the refuter
role explicitly; route disagreement to a fix, not a tie-break.

## Review independence

A fresh context reduces inherited assumptions; high-risk changes also require a
reviewer from a different model family. Record the actual reviewer evidence: a
requested model label alone does not establish the model used, and a text-diff
review is not browser evidence.

## Ask which lane before running a gate (ADR-0008)

```
review-receipt.py lane --repo . --scope committed
```

names the required lane.

- Ordinary tier-2 work goes to `antigravity-review-gate.sh`.
- A risk surface (or a classification the helper could not read) requires
  `codex-review-gate.sh` and is never downgradable.
- A tier-1 docs diff takes either gate's tier valve.
- `review-receipt.py check` refuses a receipt whose lane ranks below the
  requirement, so run the *named* gate rather than the familiar one, and check
  the receipt with no `--reviewer`.
- An Antigravity gate that exits 3 could not run and falls back to Codex; exit 2
  is a verdict and never falls back.
- `review-and-push.sh` performs the whole selection itself.

## Codex bot threads before merge

A repo running the `codex-review` workflow also runs a GitHub Codex bot. It
reviews a PR when it opens, and the workflow posts one `@codex review` request
for each later head it has not reviewed. Its findings arrive as review threads, often after the
local gate has approved. Where the ruleset is enforced, each thread must be
resolved before the PR can merge, and the `codex-findings` label marks PRs that
still have one. Before merging, or when a PR stalls on that label:

```
~/.claude/scripts/codex-threads.sh list --pr N
~/.claude/scripts/codex-threads.sh resolve --thread ID --reply "Fixed in <sha>: ..."
```

Fix the real findings and push them together. In a repo running that
workflow the push gets an automatic `@codex review` request, so don't post one
by hand; the workflow skips a docs-only diff that touches no instruction
surface, and such a PR passes at once with no bot review to wait for. Reply
with where each was
fixed, or with why it is moot, then resolve. Never resolve a thread without a
reply.

## Handoff payload

When handing work to another agent, the note carries the *claim to disprove*
and the *exact repro command*, not just "please review". For gate-mediated
refutation, pass them directly:

```
codex-review-gate.sh --claim "<claim>" --repro "<cmd>"
```

## Verdicts are artifacts

A rescue diagnosis or verification verdict from another agent must be persisted
(handoff note or issue comment) before the team acts on it — output that only
reached one terminal is lost work. Notes carry a "Session continuity" section
(codex session id / agy conversation id) so the next hand-back resumes instead
of cold-starting.
