# Multi-agent lane contract

How Claude Code (`cc`), Codex (`cx`), and Antigravity work as one team on the
same repo. This is the shared playbook — all three load it through the AgentPack
(`AGENTPACK.yaml`), and the operative rules are mirrored into `CLAUDE.md` and
`codex/AGENTS.md` so each tool follows them at session start.

The team coordinates through **artifacts in the repo, not a shared chat**: the
instruction layer + skills (loaded identically via the pack), GitHub issues (the
only open-work tracker), `handoff` notes + `CHANGELOG.md`, and git itself. Keep
those honest and the team works even though the agents never talk to each other.

## Lanes

The value is not three workers — it's **three independent model lineages
disagreeing**. Codex (GPT-5.x) and Antigravity (Gemini) earn their keep when they
*refute*, not when they rubber-stamp. Assign the refuter role explicitly.

| Agent | Lane | Owns |
|-------|------|------|
| **Claude Code** (Opus, 1M ctx) | **Conductor** | Plan/decompose, hold the through-line, drive the main implementation, write the failing test first, own handoffs + issues + changelog |
| **Codex** (GPT-5.x) | **Independent verifier + rescue** | Adversarial refutation of the conductor's fix, from-scratch reimplementation to cross-check, deep root-cause when the conductor is stuck |
| **Antigravity** (Gemini) | **Runtime/browser verification + front-end** | Prove it actually runs end-to-end, own UI-heavy surfaces and in-browser verification artifacts |

Lanes are defaults, not walls — whoever holds the working tree does the edit.

## The two hard rules

1. **One owner of the working tree at a time.** Multiple agents editing the same
   files make conflicting assumptions about names, signatures, and imports. Give
   each agent its own git worktree, or strictly sequence shared-file edits with a
   lint/test/build between rounds. Parallelize freely only on read-only work
   (review, research) and non-overlapping new files.

2. **Verification is adversarial, never an echo chamber.** Three agents agreeing
   can be one correlated blind spot voted three times. The chain: the conductor
   implements → Codex tries to refute on a fresh checkout → Antigravity proves it
   in the browser/runtime. Disagreement is the signal — route it to a fix, not a
   tie-break. Re-run any "verified via X" claim that contradicts what you can
   check directly; empirical beats confident assertion.

## Handoff payload

When the conductor hands work to Codex or Antigravity, the handoff (a `handoff`
note or an issue) carries the **claim to disprove** and the **exact command to
reproduce** — not just "please review." A verifier with a falsifiable target and
a repro is worth three that were asked to nod.
