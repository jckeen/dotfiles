# Multi-agent lane contract

How Claude Code (`cc`), Codex (`cx`), and Antigravity work as one team on the
same repo. This is the shared playbook — all three load it through the AgentPack
(`AGENTPACK.yaml`), and the operative rules are mirrored into `CLAUDE.md`,
`codex/AGENTS.md`, and `antigravity/GEMINI.md` so each tool follows them at
session start.

The team coordinates through **artifacts in the repo, not a shared chat**: the
instruction layer + skills (loaded identically via the pack), GitHub issues (the
only open-work tracker), `handoff` notes + `CHANGELOG.md`, and git itself. Keep
those honest and the team works even though the agents never talk to each other.

## Lanes

The value is not three workers — it's **independent model lineages
disagreeing**. Codex (GPT-5.x) and Antigravity earn their keep when they
*refute*, not when they rubber-stamp. Assign the refuter role explicitly.

Lineage honesty (#205): the Antigravity lane counts as an independent *lineage*
only when a Gemini-tier slug is verifiably honored — and as of 2026-07-09 none
was (every `gemini-3.1-pro*` slug silently fell back; see Dispatch mechanics).
Until one is, treat that lane as **runtime/browser evidence, model-agnostic**,
not as a third lineage. The check is automated now: request a slug via
`antigravity-review-gate.sh --model <slug>` (or `ANTIGRAVITY_GATE_MODEL`) and
the gate verifies the recorded model after dispatch (`gate_verify_agy_model` in
`claude/scripts/gate-lib.sh`) — loud warning on fallback, hard failure with
`--require`.

| Agent | Lane | Owns |
|-------|------|------|
| **Claude Code** (Opus, 1M ctx) | **Conductor** | Plan/decompose, hold the through-line, drive the main implementation, write the failing test first, own handoffs + issues + changelog |
| **Codex** (GPT-5.x) | **Independent verifier + rescue** | Adversarial refutation of the conductor's fix, from-scratch reimplementation to cross-check, deep root-cause when the conductor is stuck |
| **Antigravity** (model verified per run — see above) | **Runtime/browser verification + front-end** | Prove it actually runs end-to-end, own UI-heavy surfaces and in-browser verification artifacts |

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

   Match reasoning effort to the job: run the correctness review at **low**
   effort on purpose — a fast, literal read of the diff, not a high-effort pass
   that invents problems or rewrites the design. Reserve high effort for the
   work itself and for the judgment (coach) pass. A correctness reviewer
   straining for findings is as costly as one that skims.

## Proportionality: gate tiers (#212)

Not every diff earns the full adversarial tax. Both review gates
(`codex-review-gate.sh`, `antigravity-review-gate.sh`) run a cheap classifier
(`gate_classify_tier` in `claude/scripts/gate-lib.sh`) — diff size plus
changed-path match against risk surfaces — before dispatching any reviewer:

- **Tier 1 (reduced):** docs-only diffs at or under `GATE_TIER1_MAX_LINES`
  (default 200). The gate may skip, logging a `tier-1 skip` line. Force the
  full pass anyway with `GATE_FORCE_FULL=1`.
- **Tier 2 (full):** anything touching a risk surface — auth/token/secret/
  credential names, path/host handling, schemas, hash chains, and gate/hook/
  CI/instruction files (AGENTS*.md, CLAUDE.md, GEMINI.md, SKILL.md, `codex/`,
  `antigravity/`, `.github/`, `scripts/`, hooks) — or above the size cap, or
  not positively classified. **Never downgradable**: no knob skips a tier-2
  review, and an adversarial `--claim`/`--repro` dispatch always runs full.

Named failure mode: **the valve fails toward the full pass.** A classification
error, an unmeasurable diff, or an unknown file class escalates to tier 2 —
nothing ever falls back to the skip.

## Handoff payload

When the conductor hands work to Codex or Antigravity, the handoff (a `handoff`
note or an issue) carries the **claim to disprove** and the **exact command to
reproduce** — not just "please review." A verifier with a falsifiable target and
a repro is worth three that were asked to nod.

Mechanically:

- **Gate-mediated refutation:** `codex-review-gate.sh --claim "<claim>"
  --repro "<cmd>"` injects the falsifiable payload into the structured Codex
  review; browser/runtime claims go to Antigravity via the `browser-verify`
  skill (target, flow, expected observable, claim to disprove).
- **Verdicts are artifacts:** the verifier persists its verdict (handoff note
  or issue comment; browser evidence under `~/.claude/handoffs/evidence/`)
  before the team acts on it. Output that only reached one terminal is lost.
- **Resume, don't cold-start:** handoff notes carry a "Session continuity"
  section (codex session id, agy conversation id); the receiving agent resumes
  that session when one is listed (`codex resume <id>`, `agy --conversation <id>`).

## Dispatch mechanics

**Codex: route through the companion script, never the forwarder agent (#179).**
The `codex:codex-rescue` plugin agent is fire-and-forget only — it is Bash-only
(no channel to return results), makes exactly one companion call, prefers
`--background` for anything substantial (detaching the job into a handle it is
forbidden to poll), and prompting it to "analyze" makes its wrapper model do the
work instead of Codex. Anything that needs a result back MUST call the companion
directly:

```sh
node "$(fd codex-companion.mjs ~/.claude/plugins/cache | head -1)" \
  task|adversarial-review [--wait|--background] [--base <ref>]
# background jobs: ... status | result | cancel
```

Version-pin gotcha: the plugin cache path embeds the plugin version and moves on
every plugin update — always resolve it via `fd` (or `find -name` where fd isn't
installed), never hardcode the versioned path. Squash-merge gotcha: after a
squash merge, `git merge-base --is-ancestor` is always false for the source
branch — verify a change landed with `git grep <symbol> origin/main`, not commit
ancestry.

**Antigravity: dispatch non-interactively with a verified model slug (#177).**
The verified high-tier dispatch is:

```sh
timeout 300 agy -p "<prompt>" --model claude-opus-4-6-thinking
```

Two `--model` failure modes, neither of which errors:

- A display-name string from `agy models` (e.g. `--model "Gemini 3.1 Pro
  (High)"`) hangs print mode forever behind an interactive picker — always wrap
  `agy` in `timeout`.
- An unrecognized lowercase slug silently falls back to the default flash-low
  tier (as of 2026-07-09, every `gemini-3.1-pro*` variant and
  `claude-sonnet-4-6-thinking` fell back; only `claude-opus-4-6-thinking` was
  honored). Post-dispatch verification is automated (#205): gate runs that
  request a slug (`antigravity-review-gate.sh --model <slug>` /
  `ANTIGRAVITY_GATE_MODEL`) check the newest
  `~/.gemini/antigravity-cli/conversations/*.db` afterwards via
  `gate_verify_agy_model` and warn loudly on fallback (hard failure under
  `--require`). For manual `agy -p` dispatches, run the same check by hand:
  `strings <db> | grep -E 'gemini-|claude-'` — `gemini-default` /
  `gemini-3.5-flash-low` there means the slug was ignored.
