# Shared agent sources

## Instruction canon (`agents/canon/`)

`agents/canon/` is the canonical source for every global instruction file
(ADR-0007): shared cross-agent rules live once in `CANON.md`, per-tool voice and
tool-specific guidance in a `fragments/<tool>.md` skeleton.
`claude/scripts/gen-instruction-files.sh` compiles them; the `TARGET` map in
that script is the authoritative list of what it builds, and every target is a
committed build artifact. Edit the sources here and regenerate — CI's
`check-agent-parity.sh` fails on hand-edits or stale artifacts.

The root `AGENTS.md` is one of those targets, built from `fragments/jules.md`
(ADR-0009). It is the brief an agent reads from the checkout itself when it has
no session history — Jules, or a Codex cloud task — so it carries only the rules
that survive without one: how to verify a change in this repository, the pull
request conventions, the doc contract, and what is out of bounds. It stays short
because Codex concatenates a repository's root `AGENTS.md` with the global
`~/.codex/AGENTS.md` under a size cap. Unlike the three local files it is not
held to the concept-parity phrase list in `check-agent-parity.sh`; byte currency
against its fragment is what CI asserts.

## Shared agent skills (`agents/skills/`)

`agents/skills/` is the agent-neutral workflow skill set — the single source
consumed by every non-Claude agent in this setup:

- **Codex**: `setup.sh` directory-links each skill into the documented user
  scope at `~/.agents/skills/<name>/`; per-file links under
  `~/.codex/skills/<name>/` remain as compatibility support for older clients.
- **Antigravity (agy)**: `setup.sh` dir-symlinks each skill into
  `~/.gemini/config/skills/<name>/`.

Claude Code keeps its own richer set under `claude/skills/`.
`agents/skill-coverage.tsv` classifies every workflow as shared or
runtime-specific, and `claude/scripts/check-skill-parity.sh` fails CI when a
skill is added, removed, or promoted without updating that contract. The
`changelog` and `handoff` pairs must also keep identical artifact shapes.

Keep these skills generic and public-safe — personal preferences and private
project context belong in the private memory repos (`codex-memory`,
`agy-memory`), not here.

> **Transition note:** this directory was `codex/skills/` until 2026-07
> (issue #166). It was renamed because it had become the shared source for
> both Codex and Antigravity, not a Codex-only set. Re-run `./setup.sh`
> after pulling so the `~/.agents/skills/`, compatibility
> `~/.codex/skills/`, and `~/.gemini/config/skills/`
> symlinks repoint at the new path.

## Routine catalog (`agents/routines/`)

Each file in `agents/routines/` is one standing prompt for the cloud routine
lane (ADR-0009). `claude/scripts/jules-dispatch.sh` turns the catalog into one
Jules session per routine per repository per day; a daily systemd timer fires
it, and `--dry-run` shows what a day would dispatch without creating anything.

The frontmatter is a contract, not documentation — the dispatcher parses it
strictly and refuses to dispatch a routine whose header does not validate. An
edit made while a run is in flight is honoured: the dispatcher re-reads the file
before each session and re-checks the whole eligibility decision, so pausing a
routine, dropping a repository from its list, or slowing it to `weekly` stops the
repositories still queued behind it.

| Key | Meaning |
|-----|---------|
| `name` | Must match the filename stem and `[a-z0-9-]+` |
| `schedule` | `daily` or `weekly`, and enforced: the timer fires daily, and a `weekly` routine is skipped while its last dispatch for that repository is inside a seven-day window |
| `repos` | `all` (every repository `GET /sources` returns) or a list of `OWNER/NAME`; compared without case, and a repository listed twice is rejected |
| `max_prs_per_run` | Pull requests the routine may open in one run |
| `max_files` | Files one of its pull requests may change |
| `label` | Must be `jules-routine:<name>`; the measurement query keys off it |
| `acceptance` | The one sentence that decides whether a pull request qualifies |
| `paused` | `true` takes the routine out of the rotation without deleting it |

The body is the prompt. The dispatcher prepends the repository, the routine
name, the hard limits, the required label, and the acceptance line, so the
prompt a session receives carries the frontmatter's concrete values — the file
never repeats them in prose.

A dispatch run holds an `flock` on a file under the state directory, so a manual
invocation that overlaps the timer is a clean no-op rather than a second dispatch
of the same routine. The kernel releases it when the holder exits, so a killed
run leaves nothing behind to reclaim.

When the catalog offers more eligible pairs than `JULES_DAILY_CAP` allows, the
pair whose last dispatch is oldest goes first — never-dispatched pairs ahead of
everything. Whatever the cap defers sits at the front of the next day's queue,
so a large catalog slows down rather than silently dropping its last routines.

**Adding a routine** means answering one question: what evidence makes a pull
request from this routine obviously correct? If the answer is "a reviewer's
judgement", the routine does not belong here. Every routine in the catalog can
name a deterministic signal — zero references, a mutation receipt, a linter
finding, a checker's output, a failing snapshot.

**Tuning rule.** A routine whose merge rate stays under 30% for two weeks
running gets its prompt rewritten or `paused: true`. Read the rates with
`jules-dispatch.sh --report`, which covers every repository the routine was ever
dispatched to as well as the ones it currently lists — removing a repository
must not quietly rewrite the history the decision rests on — and states in the
report body whenever a query failed, a fetch hit its bound, or a routine's
frontmatter was rejected. A pattern of wrong pull requests is fixed by an
exclusion in the routine's prompt, never by loosening the review gate that
caught them.

## Capability and workflow contracts

`capabilities.json` declares each runtime's provider, scope, owner, prerequisite
interface, and passive probe. The cloud routine lane is modeled as its own
capability: Jules installs nothing on this machine, so its disposition is
`unsupported` for every locally-provisioned capability, and the one row where it
is real names the dispatcher as the provider. `claude/scripts/check-capability-parity.py` checks
public provider references in CI. Add `--live-home "$HOME"` for an advisory
installed-provider report; additional local skills are allowed. The report
checks presence and configuration, not execution, authentication, hook trust,
or equivalence between runtime internals. Unsupported and advisory capabilities
are explicit; no unverified hook adapter is installed by this contract.

`workflow-invariants.json`, adjacent to `skill-coverage.tsv`, declares the small
instruction requirements shared workflows must carry. The skill-parity checker
checks each Claude body and the shared Codex/Antigravity body or local override.
It ignores Markdown formatting, wrapping, frontmatter and comments; fixtures
verify that removing an invariant fails with its workflow and runtime named.
These checks detect declared instruction drift without requiring identical
wording or proving that an agent followed the instructions during execution.
