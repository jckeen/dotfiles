# Multi-agent lane contract

How Claude Code (`cc`), Codex (`cx`), and Antigravity work as one team on the
same repo. This is the shared playbook — all three load it through the AgentPack
(`AGENTPACK.yaml`, generated from skill/agent frontmatter by
`scripts/gen-agentpack.sh` — never edited by hand), and the operative rules are
compiled into `CLAUDE.md`, `codex/AGENTS.md`, and `antigravity/GEMINI.md` from
the canonical sources in `agents/canon/` (ADR-0007) so each tool follows them
at session start; `check-agent-parity.sh` asserts both the concepts and the
byte-currency in CI.

The team coordinates through **artifacts in the repo, not a shared chat**: the
instruction layer + skills (loaded identically via the pack), GitHub issues (the
only open-work tracker), `handoff` notes + `CHANGELOG.md`, and git itself. Keep
those honest and the team works even though the agents never talk to each other.

## Roles

The active session is the conductor: it owns the outcome, dependency order,
integration, verification, authorized delivery, and handoff. Assign other
roles explicitly for the task. Any runtime can conduct or implement; personal
model and operator defaults belong in private preferences.

| Role | Owns |
|------|------|
| **Conductor** | Planning, workstream boundaries, integration, final verification, delivery, and durable records |
| **Implementer** | A bounded change in an owned worktree, with named acceptance criteria and verification |
| **Independent reviewer** | Refutation of the final artifact from a fresh context, with a claim to disprove and exact repro |
| **Runtime/browser verifier** | Exercising the actual flow and reporting observable behavior with runtime evidence |

A fresh context reduces inherited assumptions. It does not establish a different
model lineage. High-risk changes involving authentication, authorization,
secrets, payments, destructive operations, schemas, or public trust boundaries
require a reviewer from a different model family than the implementer. Record
actual reviewer identity evidence before claiming that requirement is satisfied.

An Antigravity model label and its propagation log establish what was dispatched;
they do not prove which model served a particular run. The gate's best-effort
conversation-record spot-check is corroboration, not per-run attestation. If
actual identity cannot be established, report it as unverified and obtain the
required separate-family review elsewhere. A text-diff review is not browser or
runtime evidence, regardless of the tool or model that produced it.

## The two hard rules

1. **One owner of the working tree at a time.** Multiple agents editing the same
   files make conflicting assumptions about names, signatures, and imports. Give
   each agent its own git worktree, or strictly sequence shared-file edits with a
   lint/test/build between rounds. Parallelize freely only on read-only work
   (review, research) and non-overlapping new files.

2. **Verification is adversarial, never an echo chamber.** Ask a fresh-context
   reviewer to refute the final artifact; use a different model family when
   required above. Assign actual runtime/browser verification when the changed
   behavior needs it. Disagreement is a reason to reproduce and investigate,
   not a vote to break. Re-run any agent claim that contradicts directly
   observable evidence.

Complete simplification, documentation, changelog, and generated-file updates
before affected verification and final review. For ordinary shipping work, the
required committed-artifact gate serves as the final fresh-context review;
another identical review is unnecessary. Any later artifact edit
invalidates approval. Repeat affected checks and review after fixes, then
validate the private review receipt immediately before shipping. Exit 0 alone
is not proof of completed review; report tier/no-diff exemptions separately.

## Proportionality: gate tiers (#212) and review lanes (ADR-0008)

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

Separately from the tiers, the Antigravity lane refuses diffs it could only
review in part: `agy` print mode delivers about 185 KB of a single user message
to the model and silently drops the rest (#409), so above
`ANTIGRAVITY_GATE_MAX_BYTES` (default 185000) the gate degrades instead of
dispatching. The cap is checked before the tier valve, so an oversized
docs-only diff cannot collect a tier-1 receipt either. A large change gets no
Gemini-lineage verdict until it is split.

Named failure mode: **the valve fails toward the full pass.** A classification
error, an unmeasurable diff, or an unknown file class escalates to tier 2 —
nothing ever falls back to the skip. Renames can't launder either: diffs and
changed-path lists are computed with `--no-renames`, so `git mv guard.sh
notes.md` is classified under both paths and reviewed as a full delete+add.

### Which lane reviews it (ADR-0008)

The same classifier also names the **required lane**, and the receipt carries it:

- **Tier 1** requires lane `any` — either gate's exemption receipt ships it.
- **Tier 2 with no risk path** requires `antigravity`. This is the default lane
  for ordinary work; the Codex GitHub bot supplies the cross-family second
  opinion after the push.
- **Risk paths, an empty changed-path list, or an unreadable classification**
  require `codex`. Size alone never escalates the lane: a large ordinary diff is
  still ordinary.

Lanes rank `any < antigravity < codex`, and a receipt ships a diff only when its
lane ranks at or above the requirement — enforced by `review-receipt.py check`,
so `githooks/pre-push` needs no lane logic of its own. Escalation is always
allowed (`REVIEW_LANE=codex`); **downgrade never is** — `REVIEW_LANE=antigravity`
on a codex-required diff is refused rather than honoured. On such a diff the
Antigravity gate still runs and still mints its receipt, announcing itself as a
**supplementary** lane: an independent-lineage second opinion, not the shipping
gate.

A degraded lane is not a verdict. Antigravity exit 3 (agy missing, unverifiable
model pin, a diff above the byte cap) means the lane could not run, so
`review-and-push.sh` falls back to Codex and records the degradation in the lane
ledger; `REVIEW_LANE_FALLBACK=block` refuses the push instead. Exit 2 — blocking
findings, or a verifiably wrong model — never falls back.

`review-and-push.sh` checks the receipt naming the lane it dispatched, which also
requires the review that run performed to still be approved. Checking by hand,
use the generic no-`--reviewer` form above: it enforces the same lane requirement
without needing to know which lane ran. Read the ledger with
`review-receipt.py stats --since-days 7` before drawing conclusions about lane
cost; the dotfiles risk list is deliberately unnarrowed, so most diffs *in this
repository* stay on Codex.

## Handoff payload

When the conductor hands verification to another agent, the handoff (a `handoff`
note or an issue) carries the **claim to disprove** and the **exact command to
reproduce** — not just "please review." A verifier with a falsifiable target and
a repro is worth three that were asked to nod.

Mechanically:

- **Gate-mediated refutation:** `codex-review-gate.sh --claim "<claim>"
  --repro "<cmd>"` injects the falsifiable payload into the structured Codex
  review. Assign browser/runtime claims to a working tool that can exercise
  the actual flow and retain inspectable evidence (target, flow, expected
  observable, claim to disprove). Antigravity's `browser-verify` skill is one
  available route; choose by capability rather than runtime name.
- **Verdicts are artifacts:** the verifier persists its verdict (handoff note
  or issue comment; browser evidence under `~/.claude/handoffs/evidence/`)
  before the team acts on it. Output that only reached one terminal is lost.
- **Resume, don't cold-start:** handoff notes carry a "Session continuity"
  section (codex session id, agy conversation id); the receiving agent resumes
  that session when one is listed (`codex resume <id>`, `agy --conversation <id>`).

## Dispatch mechanics

Use the active runtime's native agent controls and obey its actual delegation
authorization rules. When applicable user or instruction requirements authorize
agents, assign useful bounded tasks; keep one editing owner per worktree and
sequence overlapping changes. The shared orchestrate runtime contract documents
the supported workflow in `agents/skills/orchestrate/references/runtime-contracts.md`.

When calling a Codex companion from another runtime, use a result-returning
interface and inspect the completed artifact. Resolve installed executable or
plugin paths instead of embedding a cache version. The local Codex review gate
provides the shipping review interface; a detached forwarder without a result
channel is not evidence that review completed.

For Antigravity, use the gate's configured model label from the current
`ANTIGRAVITY_GATE_MODEL` setting and verify dispatch against its log. Keep the
review prompt on stdin, bound execution time, and preserve the gate's permission
and sandbox settings. Consult `claude/scripts/antigravity-review-gate.sh` and
`claude/scripts/gate-lib.sh` for the executable invocation and validation rules.
A matching dispatch label does not establish actual per-run model identity.

Shipping uses the applicable `commit-push-pr` skill. Ask which lane the diff
requires, then run **that** gate with `--require` after the last commit;
degraded or failed execution supplies no approval:

```sh
python3 ~/.claude/scripts/review-receipt.py lane --repo . --scope committed
```

Immediately before push, check the receipt against the outgoing HEAD — with no
`--reviewer`, so the receipt's own recorded classification decides which lanes
may ship it:

```sh
python3 ~/.claude/scripts/review-receipt.py check --repo . \
  --head "$(git rev-parse HEAD)"
```

Pass the same `--base <ref>` if one was selected. Naming a lane with
`--reviewer` narrows the check to that lane; it can never satisfy a stronger
requirement, so use it for diagnosis rather than for shipping. Successful review
receipts and explicit current tier/no-diff exemptions are distinct evidence.
Missing, stale, or below-requirement evidence blocks shipping. A receipt records
artifact review; it does not itself prove different model lineage or real
runtime/browser verification. Never bypass hooks to evade a missing review or
receipt.
