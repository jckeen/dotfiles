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
  `"error"` in `eslint-suppressions.json` at the project root; new code is
  still enforced; a suppression that is no longer needed makes ESLint exit
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
- The gate review of this ADR added two more: comparing linter output between
  trees misses a violation added under an unchanged exemption unless the
  exemptions are switched off for the comparison, and a scheduled prune
  cannot make an already stale merged tree pass.
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
| Size budget: a file over its line budget may not grow | ratchet script (line counts against the target branch) |
| Contracts at the boundary: outside data is validated once, where it enters | review; lint only for the cast and `any` bans that force it |
| Explicit state: a lifecycle is a tagged union or transition table | review |
| Pure core, injected edges: domain logic imports no I/O or clock | lint import and global restrictions on declared domain paths; review for effects reached through a wrapper |
| No type escape hatches | lint and the type checker |
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

**The ratchet mechanism.** Per-repo adoption commits a machine-readable
config: included paths, exclusions (generated and vendored output, type
declarations, fixtures, snapshots, applied migrations), a line budget per
category (source, UI component, test), how lines are counted, and which paths
are domain logic. A check then compares the pull request with its target
branch:

- line count of each included file is at most the larger of its budget and
  its line count on the target branch; a new file gets the budget only;
- lint diagnostics per file and rule do not increase, and a new file has
  none. For TypeScript this is the ESLint suppressions file plus a comparison
  of that file with the target branch's copy; for Python and shell, which have
  no count-keeping baseline, it is a comparison of linter output between the
  two trees with every existing exemption switched off (inline suppression
  comments, file-level disables and ignore lists), so a violation added under
  an unchanged exemption still counts. Where a linter has no switch for that,
  the check strips the directives from a scratch copy before linting;
- a change to the lint config, an ignore list or a disable comment is shown
  to the reviewer as a ratchet change.

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
2. A pilot on repo A that builds the ratchet check and proves it. Acceptance:
   a grown over-budget file fails; a raised or added suppression fails; a new
   file with a violation fails; and in the two-branch case from the critique
   the stale tree never reaches the target branch: the check runs on the
   merged result (a merge queue, or a branch required to be current), fails
   the second pull request on its unused suppression, and passes once that
   pull request refreshes against the target branch and prunes. The pilot is TypeScript; the
   tree-comparison path for Python and shell is proven at the first adoption
   in each.
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
- Adoption does not require wholesale refactoring, and no repo's CI turns red
  on the day it adopts.

**Negative**
- The ratchet is a script we own and must test, not a stock linter feature.
- The suppressions file changes in most pull requests that touch an old file,
  and concurrent debt reduction costs the later pull request a refresh and a
  prune before it can merge.
- Lifecycle, boundary placement and fake fidelity are reviewer judgments, so
  two reviewers can disagree.
- The ratchet records debt without paying it.
- A fix in an over-budget file carries a small extraction it would not
  otherwise need.
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
