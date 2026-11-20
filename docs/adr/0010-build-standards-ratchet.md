# 0010. Hold every repo to shared build standards by ratchet

- **Status:** Accepted (delivery steps 2-4 pending the pilot)
- **Date:** 2026-11-16

## Context

The shared rules in `agents/canon/CANON.md` say how agents plan, verify, review
and spend CI. They say nothing about the shape of the code the agents write. A
TypeScript standard has been in use informally on one project: a file-size
ceiling, a schema / machine / logic split per feature, injected I/O and clock,
no type assertions, fakes over mocks, and structure rules kept in the linter.
No instruction file, reviewer agent, skill or CI job carries it, so each
builder gets it only when a brief happens to quote it.

### Project floor (measured 2026-11-16)

A regular-expression sweep of tracked, non-test `.ts`/`.tsx` files in nine
local repos, named by letter because most are private (total lines, not executable lines; mock and file-reading counts
are over test files):

| Repo | Files | Over 300 lines | Over 1000 | Largest | `as T` | Mock/spy calls | Tests calling `readFileSync` |
|---|---|---|---|---|---|---|---|
| A | 359 | 63 | 6 | 2937 | 551 | 1174 | 250 |
| B | 505 | 67 | 12 | 7491 | 306 | 1390 | 52 |
| C | 527 | 99 | 11 | 3410 | 480 | 1375 | 137 |
| D | 91 | 21 | 0 | 792 | 33 | 136 | 0 |
| E | 69 | 11 | 1 | 1521 | 104 | 0 | 6 |
| F | 50 | 9 | 0 | 890 | 74 | 0 | 12 |
| G | 122 | 2 | 0 | 384 | 40 | 29 | 3 |
| H | 78 | 3 | 0 | 451 | 17 | 0 | 3 |
| I | 9 | 0 | 0 | 176 | 1 | 0 | 0 |

Three of the nine have a lint config naming any of `max-lines`,
`consistent-type-assertions` or `no-explicit-any`. A hard gate would turn the
three largest repos red on its first run.

### External floor (verified 2026-11-16)

- **ESLint bulk suppressions** — `https://eslint.org/docs/latest/use/suppressions`:
  `--suppress-all` records every existing violation of a rule configured as
  `"error"` in `eslint-suppressions.json` at the project root; suppression
  allowances are counts per file and rule, not proof that newly added code
  is clean; a suppression that is no longer needed makes ESLint exit
  non-zero until `--prune-suppressions` removes it.
- **typescript-eslint `consistent-type-assertions`** —
  `https://typescript-eslint.io/rules/consistent-type-assertions/`:
  `assertionStyle: "never"` bans type assertions; `const` assertions are
  always allowed.
- **Ruff** — `https://docs.astral.sh/ruff/linter/`: no baseline file;
  `ruff check --add-noqa` writes a suppression comment on each violating line,
  and `lint.per-file-ignores` exempts paths.

### Design critique (Codex, 2026-11-16)

A first draft claimed ESLint bulk suppressions were the whole ratchet. A Codex
pre-build critique (default model; the run did not report a model name)
disproved that with reproductions, and this ADR is the revision:

- ESLint 9.39.5 reports one `max-lines` violation for a file of 301 lines and
  for one of 3000, so a suppressed over-budget file can grow unseen.
- The suppressions file is an input the pull request controls: raising a
  count, or adding an entry for a new file, makes new violations pass.
  Suppressions hold a count per file and rule, not the identity of a
  violation.
- Ruff 0.16.8 accepts further violations under `per-file-ignores` and on an
  already suppressed line; a ShellCheck disable accepts more inside its scope.
  Those are exemptions, not ratchets. Ruff has no file-length rule.
- The gate review of this ADR found three more over three rounds, all one
  family: a violation added under an unchanged exemption is invisible to a
  comparison of ordinary linter output, in Python and shell and equally under
  an ESLint disable comment; and a scheduled prune cannot make an already
  stale merged tree pass. The Decision therefore states guarantees and an
  explicit out-of-scope list instead of a mechanism. A second Codex critique
  (2026-11-16, default model) swept every known channel against the
  guarantees and supplied the file-identity rule, the incomplete-measurement
  rule and the wording of guarantees 3 and 4.
- Two pull requests that each remove one of two recorded violations merge
  without a text conflict into a tree whose suppressions file is stale, and
  ESLint then fails on the unused suppression.

The critique also found the size rule could block a fix, the wording was
TypeScript-shaped, and the delivery order switched the rule on before the
reviewer agents that contradict it were corrected. All are addressed below.

## Decision

We will add one canon block, `build-standards`, to every generated instruction
file including the cloud brief, and enforce it per repo by a ratchet that
compares each pull request with its target branch.

**The shapes**, and what can check each:

| Shape | Checked by |
|---|---|
| Size budget: a file over its line budget may not grow | the ratchet check (guarantee 1 below) |
| Contracts at the boundary: outside data is validated once, where it enters | review; lint can prohibit configured casts and uses of `any`, but cannot establish that boundary validation happens or is correct |
| Explicit state: a lifecycle is a tagged union or transition table | review |
| Pure core, injected edges: domain logic imports no I/O or clock | lint import and global restrictions on declared domain paths; review for effects reached through a wrapper |
| No type escape hatches | lint and the type checker for configured cases; review for unchecked trust in declarations and user-defined narrowing |
| Fakes over mocks; structure rules in the linter | lint for spy and mock calls in declared domain tests; review for whether a fake is faithful |

The canon block therefore says "lint where the repo has a rule, review where
it has none" and does not ask for an issue per unlintable judgment.

**Owner rulings (2026-11-16)** that depart from the standard as first written:

- **Ratchet, not a hard gate.** Recorded violations may only decrease; a new
  file meets every rule.
- **A state machine only where there is a lifecycle.** Several status flags
  are a prompt for a reviewer to look for one, not a trigger by themselves.

**Other departures.** The standard put "isolated I/O adapters" in the logic
module while forbidding that module I/O imports: adapters get their own
module. "No nested function closures" becomes lint caps on function length and
nesting depth. "Split before any patch lands" becomes "may not grow": a change
that would grow an over-budget file extracts just enough of the code it is
editing to keep the file at its current length, and nothing wider; a repo
with no configured budget has no size rule. A boundary is where outside data enters the
application, validated once by the adapter that receives it; internal calls,
React props and already validated data are not boundaries. Schema and logic
are separate responsibilities, and separate files where the repo's lint config
says so.

**What the ratchet must guarantee.** This ADR fixes the guarantees and leaves
the mechanism to the pilot, because three review rounds each found a way
round a mechanism described in prose. Per-repo adoption commits a
machine-readable config: included paths, exclusions (generated and vendored
output, type declarations, fixtures, snapshots, applied migrations), a line
budget per category (source, UI component, test), how lines are counted, and
which paths are domain logic. A check then holds, for every included file in
every language, comparing the pull request's merged result with its target
branch:

File identity is its repository-relative path: a path absent from the target
tree is new, including a rename or a copy; no allowance transfers between
paths, and a deleted path keeps none.

1. **No growth.** A file over its budget is no longer than it is on the
   target branch. A new file is within budget.
2. **No new violations, counted with exemptions off.** The number of
   diagnostics per file and rule does not increase, and a new file has none.
   The count is taken with every in-source exemption ignored (inline
   suppression comments, file-level disables, type-checker ignore and
   configuration comments) and with no per-path ignore list applied, so a
   violation added under an existing exemption counts the same as one added
   in the open. A missing or incomplete measurement, including analysis
   stopped by a parse or tool failure, fails the check; it is not debt to
   record. Scope that is meant to go unmeasured is an explicit, reviewed
   exclusion.
3. **The baseline cannot be loosened by the change it gates.** Allowed counts
   come from measuring the target tree under the comparison policy. Any
   stored baseline must agree with those measurements, and reductions in the
   merged result become the next target's limits.
4. **Enforcement changes are reviewed.** Both trees are measured under the
   same identified enforcement policy. A change to the policy or to the
   machinery that enforces it (effective path classification, rule settings,
   counting, toolchain, invocation, the checker's own code) needs
   machine-verifiable reviewer approval, bound to the exact revisions
   compared and verified outside the pull request's control. That approval
   waives none of the other guarantees.

Out of scope, stated so it is not mistaken for a guarantee: the ratchet
counts violations and does not track their identity, so replacing one
violation with another of the same rule in the same file passes; it measures
only what a configured rule or the line counter can see, so the reviewed
shapes in the table above are not ratcheted; and it does not judge whether an
approved enforcement policy or path classification is appropriate: code in an
excluded path, including new, copied or relocated code, is outside what it
measures.

ESLint bulk suppressions are a candidate for recording TypeScript counts, not
the mechanism: used alone they fail guarantees 1, 2 and 3.

SQL is outside the size and pure-core shapes: its contracts are the database's
types and constraints, and applied migrations are never rewritten for a
budget.

**Delivery:**

1. This ADR, the canon block in all four generated files, a parity rule, and
   the three reviewer corrections the block would otherwise contradict:
   `code-simplifier` and the Codex `simplify` skill stop treating a
   single-caller port or adapter as something to inline, and `test-writer`
   prefers fakes for domain tests, keeps mocks for adapter and contract
   tests, and never restructures production code to make it fakeable. Until a
   repo adopts the ratchet the block binds new files and new functions only;
   an edit inside existing code follows that code's current shape.
2. A pilot on repo A that builds the check and demonstrates both permitted
   changes and rejected regressions:
   - *size:* unchanged existing debt passes; growth above the budget,
     crossing the budget and an oversized new file fail;
   - *diagnostics:* an ordinary addition, an addition under each supported
     exemption mechanism, a per-path suppression and a new file with a
     violation all fail, for each adopted linter and type checker;
   - *identity:* rename, copy, deletion and recreation;
   - *baseline:* a pull request's self-raised allowance fails, and so does
     reintroducing debt after an earlier merge reduced it, even when a stored
     baseline is stale;
   - *enforcement changes:* category and exclusion changes, counting changes,
     and changes to the checker, its invocation or the toolchain fail with
     missing or stale approval and pass with valid approval only when the
     other guarantees hold;
   - *measurement:* a missing or incomplete measurement fails;
   - *concurrency:* two debt reductions can both merge after verification
     against the current target, and a result checked against an earlier
     target cannot authorize the later merge.

   The TypeScript pilot establishes these first; each Python and shell
   adoption establishes the applicable cases for its tools.
3. A `build-standards` skill with a reference per language (TypeScript,
   Python, shell): lint rules, contract mechanism, ratchet setup, and the
   builder hand-off line that `decompose` and `orchestrate` put in briefs.
   The architect agents and the `review` skill check against the block.
4. One adoption pull request per repo, and an issue per file over 1000 lines.

The critique advised holding the canon block until the pilot passes. We
activate it in step 1 instead, worded so it claims no enforcement a repo does
not have: the shapes are an owner decision that does not depend on the
pilot, and the pilot tests only the mechanism.

## Consequences

**Positive**
- Every builder and reviewer on every runtime, cloud included, reads the same
  shapes.
- The numbers live in per-repo config that CI asserts, not in prose.
- Adoption records existing measurable debt without requiring wholesale
  refactoring; the adoption pull request must show the adopted checks pass.

**Negative**
- The ratchet is a script we own and must test, not a stock linter feature.
- Baseline maintenance and concurrent debt reduction may need extra work; the
  pilot establishes those costs, and every merge needs verification against
  the current target.
- Lifecycle, boundary placement and fake fidelity are reviewer judgments, so
  two reviewers can disagree.
- The ratchet records debt without paying it.
- A fix that would grow an over-budget file needs enough extraction to
  satisfy the size rule.
- Structure tests that read source files stay in the test runner until each
  is ported to a lint rule. Repos with no lint config need one first.

## Alternatives considered

- **Hard gate from day one** — the three largest repos would fail CI until
  several hundred files were refactored.
- **Prose only, no lint** — a rule waiting to be remembered; the measured
  state is what that produces.
- **Schema / machine / logic trio for every feature** — forces an empty
  machine on stateless features and contradicts `code-simplifier`.
- **ESLint bulk suppressions alone** — disproved by the critique above.
- **A shared ESLint preset package** — deferred until the pilot shows the rule
  set is stable.
