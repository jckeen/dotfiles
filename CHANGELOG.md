# Changelog

## 2026-07-10 — feat: instruction canon — generate the three instruction files from one source (#216, #206, #219)

### What changed
- **ADR-0007** — investigated #216's thin-shim proposal empirically: only
  Claude Code resolves `@` imports; Codex CLI 0.141.0 (docs + live test) and
  Antigravity CLI 1.1.1 (live test, tools forbidden, out-of-workspace file)
  resolve none. Accepted the intent via **generation**: `agents/canon/CANON.md`
  (shared rule blocks) + `agents/canon/fragments/{claude,codex,antigravity}.md`
  (per-tool voice) compiled by `claude/scripts/gen-instruction-files.sh` into
  `claude/CLAUDE.md`, `codex/AGENTS.md`, `antigravity/GEMINI.md` — now
  committed GENERATED artifacts with a do-not-edit banner. Migration is
  semantics-preserving: zero removed words; only the banner, two GEMINI.md
  re-wraps, and the new two-floor block.
- **check-agent-parity.sh (#206)** — concept RULES extended with the lane
  contract (`one-owner-worktree`, `adversarial-verification`,
  `handoff-claim-repro`) and `two-floor-grounding`; weak keyword regexes
  (`scope|scoped|unrelated` etc.) tightened to rule-phrase matching over
  unwrapped markdown; new byte-currency check (`gen-instruction-files.sh
  --check`) fails CI on hand-edits or stale artifacts. Test suite rebuilt:
  15 fixture cases including per-rule drift, tightened-regex, hand-edit,
  orphaned/unknown canon block, and idempotency.
- **Two-floor grounding (#219, ADR-0006)** — encoded once in canon and emitted
  into all three instruction files: an adopt/skip verdict on an external
  technology must clear a project floor (verified local fact) and an external
  floor (verified source), neither compensating for the other.
- **`.doc-contract`** — the three instruction files moved SOURCE → GENERATED;
  `agents/canon/**` added as SOURCE. README, agents/README, scripts README,
  and MULTI-AGENT.md repointed at the canon.

### Decisions made
- Rejected literal root-AGENTS.md shims (would load empty in 2 of 3 tools) and
  symlinking (kills per-tool voice); generation keeps per-tool divergence real
  while making shared rules single-source. Evidence in ADR-0007.

### Post-review hardening (Codex adversarial pass on PR #234)
- **Leak guard (P1):** a malformed marker (trailing space, or an include line
  inside a canon block) previously shipped literally with rc=0 — the generator
  now fails loudly if any rendered line still matches `<!-- (include|canon):`.
  Two new fixture cases (17 total).
- **Negation limit documented** in check-agent-parity.sh's header: phrase
  matching asserts presence, not affirmation; the byte-lock to reviewed canon
  sources is the mitigation.
- **session-retro** now routes instruction-file proposals at `agents/canon/`
  + regeneration instead of the generated artifacts.

## 2026-07-10 — chore: split plugin enablement into global vs per-project scope (#214)

### What changed
- **`claude/plugins.txt`** — restructured into `# [global]` (16 plugins,
  enabled in `~/.claude/settings.json`) and `# [per-project]` (vercel,
  playwright, sentry, posthog, soundcheck — enabled only via each target
  project's `.claude/settings.json`) sections. Markers are comments, so
  setup.sh / sync-plugins.sh install both sections unchanged. Target projects
  documented per plugin on their own comment lines — NOT inline, because
  setup.sh's and check-install-integrity.sh's marketplace awk does not strip
  trailing inline comments.
- **`PluginDriftCheck.hook.ts`** — now parses the sections and additionally
  warns when a `[global]` plugin is missing from global `enabledPlugins` or a
  `[per-project]` plugin is enabled globally. Warn-only by design (exit 0
  always): live settings still carry the old fully-global set during the
  migration window, and a session must never be blocked over plugin scoping.
  A marker-less manifest parses as before (all lines = global), though the
  scoping checks are new, so advisory warnings can appear where the old hook
  was silent.
- **`sync-plugins.sh` / `claude/scripts/README.md`** — documented that
  installation covers both sections; scoping governs enablement only.
- **Adversarial-review round** — playwright's targets gained clarity-engine
  (`@playwright/test` + `playwright.config.ts` in the nested `app/`
  package.json, missed by the top-level-only sweep); hook hardened: warns on
  a plugin listed in both sections (unsatisfiable scoping), tolerates leading
  whitespace before section markers, dedupes install-drift counts.

### Decisions made
- The actual `enabledPlugins` migration (global settings live in
  claude-memory; per-project snippets for operator-commons, stringer, smss,
  clarity-engine, agent-pack, allora-engine, vlcek-built) is applied
  separately — this PR delivers the manifest/hook/doc layer plus the exact
  JSON in the PR body.

## 2026-07-09 — chore: full open-issue/PR sweep across the fleet (orchestrated, 10 PRs, 18 issues closed)

### What changed
- **Every open dotfiles issue and PR closed** in one orchestrated session: 8
  parallel worktree agents (fix/build), 4 adversarial reviewers, 2 phase-2
  agents; every code PR got an independent refutation review before merge.
- **PR #164 merged** (harvester REST-only for the cloud-proxy sandbox), then
  **#182**: the harvester skips obsolete bot comments (#159). Empirical
  correction to GitHub's docs: outdated comments keep `position`, the real
  signal is `line: null`; GraphQL resolved-thread check is strictly best-effort.
- **Antigravity gate hardened (#185)** — whole-verdict LGTB match only (#152),
  fail-closed on unresolved base refs (#153), prompt+diff delivered via stdin so
  secrets never hit argv (#154, verified against agy 1.1.0), skill invokes the
  installed gate path (#155); stray-[P#]-token guard on the P3-only pass path;
  new 12-assertion PATH-shim test wired into CI. #148 closed with the
  mitigation record.
- **setup.sh --dry-run now honors its no-writes contract (#187 + #192,
  closes #133 f.1, #189)** — link_file() and ~20 call sites guarded; repair
  mode previews under dry-run; stateful-CLI probes (gh/codex/login-shell)
  gated as a class (gh ≥2.9x writes `device-id` on ANY invocation — the CI-only
  failure); byte-strict regression test + smoke-install zero-mutation assertion.
- **Docs reconciled with live state (#183, closes #66 #52 #118; #115/#112
  closed as false positive)** — SECURITY/CONTRIBUTING point at channels that
  exist, BRANCH_PROTECTION documents the real required-checks set
  (shellcheck/tsc/doc-truth), README tree/tables refreshed.
- **Generated GitHub Pages site (#186, closes #168)** — MkDocs Material over
  existing markdown, build-time skill/agent catalog from live frontmatter,
  strict build, deploy workflow. Needs Settings → Pages → "GitHub Actions"
  before first deploy.
- **ADR-0006 (#184, closes #77)** — verified assessment of Every's
  compound-engineering plugin; `agent-native-audit` was removed upstream;
  verdicts: adapt the reviewer persona + memory-refresh + two-floor grounding,
  skip the rest.
- **Multi-agent dispatch mechanics encoded (#188, closes #177 #178 #179)** —
  companion-direct Codex routing (forwarder is fire-and-forget only), verified
  agy slug `claude-opus-4-6-thinking` (unknown slugs silently fall back to
  flash-low), Teammate Contract in GEMINI.md.
- **Autonomy Kit adoptions (#190)** — coach pass (judgment-only review),
  "name the bar" quality self-check, effort-matched reviews; attribution to
  Joe Amditis (MIT). Receipt tokens/caps/picker evaluated and deferred as
  harness-only.
- **codex/skills → agents/skills (#191, closes #166)** — the shared skill set
  is now agent-neutral on disk; checkers/parity/docs updated; live relink
  verified (agy discovers all 8 shared skills post-rename).
- **claude-memory**: janitor PR #17 pending user merge; security sweep #16
  partially remediated (token metadata redacted), disposition on the issue.

### Decisions made
- Merges go through auto-merge + required checks after an independent
  adversarial review — never a direct unreviewed merge.
- Discussions stays disabled (questions → Issues with `question` label);
  private-vulnerability-reporting enablement left to the operator.

### Known issues
- Pages deploy fails until the Pages source is set to GitHub Actions.
- claude-memory #16 remainder: settings.json findings need a foreground
  session; operator-commons token rotation due before 2026-07-16.

## 2026-07-09 — feat: the three-agent loop made real (closes the capability-audit gaps #169–#176)

### What changed
- **codex-review-gate.sh rewritten for structured output (#169)** — reviews now run
  `codex exec --output-schema` against a vendored JSON schema
  (`claude/scripts/codex-review-schema.json`); the ~100 lines of prose-regex and
  format-drift heuristics are gone. The gate computes and FENCES the diff itself
  (hash-derived boundary, untrusted-data framing, `-s read-only`) so changed-file
  content can't re-scope the review. Strict shape validation (verdict/severity
  enums) and a non-zero-exit-with-clean-approve guard both fail closed.
- **Adversarial refutation mode (#170)** — `--claim "<claim>" --repro "<cmd>"`
  injects the falsifiable handoff payload; the reviewer is instructed to refute,
  not confirm. Wired into MULTI-AGENT.md's handoff-payload contract.
- **Antigravity browser/runtime lane is real (#172, #173)** — global
  `mcp_config.json` seeded from `antigravity/mcp_config.json.example`
  (Playwright MCP + GitHub MCP, token resolved at launch via `gh auth token`,
  never stored); new `browser-verify` skill (falsifiable payload in, verdict +
  evidence out at `~/.claude/handoffs/evidence/`); verified live — agy lists
  both servers, playwright browser_* tools, and the skill.
- **agy session-start handoff injection (#174)** — `antigravity/hooks.json` +
  `claude/scripts/agy-inject-handoff.sh` (PreInvocation): interactive agy
  sessions get the project's latest handoff note as ephemeral context; skips
  gate runs (`ANTIGRAVITY_GATE=1`) and repeat invocations. Verified live: agy
  quoted the note's heading with a workspace attached.
- **Gate canary (#175)** — on empty review output the agy gate now runs a PONG
  canary to distinguish one failed review from a systemic `--print` stdout
  regression, and warns loudly before degrading.
- **Handoff loop closed (#171) + session continuity (#176)** — codex/AGENTS.md
  and antigravity/GEMINI.md gain a Team Handoffs section (read
  `~/.claude/handoffs/` at session start; persist verdicts as artifacts);
  both handoff skills gain an optional "Session continuity" section carrying
  codex session ids / agy conversation ids for resume-not-cold-start.

### The loop working on itself
The rewritten Codex gate live-blocked its own rewrite five rounds running, with
real findings each time (prompt-obedience scoping, `readlink -f` on macOS,
rc-ignored approve, weak enum validation, hook word-splitting, unfenced
claim/repro payloads, and the self-review problem: a diff that edits the
reviewer's own AGENTS.md can steer the review that judges it). All fixed —
including a new self-review guard that fails closed toward the cross-vendor
gate when a diff touches the Codex instruction surface. One finding
(env-var propagation through the timeout wrapper) was empirically REFUTED and
answered with an explicitness change rather than a behavior change. That is the
refuter lane doing exactly what #170 asked for.


## 2026-07-09 — feat: Antigravity joins the shared-workflow config (agy-memory + antigravity/ layer)

### What changed
- **`antigravity/GEMINI.md`** — public-safe global rules for Antigravity (`agy`),
  the Gemini sibling of `codex/AGENTS.md`: Fable conduct layer, working style,
  multi-agent lanes (Antigravity = runtime/browser verifier + front-end),
  public safety, private-memory pointers. Symlinked to `~/.gemini/config/GEMINI.md`
  by `setup.sh` (new section 5c) — verified live: `agy` loads it and quotes its lane.
- **Shared workflow skills across agents** — the agent-neutral skill set in
  `codex/skills/` (review, simplify, fix-issue, commit-push-pr, handoff,
  changelog, branch-hygiene, repo-health) is now dir-symlinked into
  `~/.gemini/config/skills/`, so Codex and Antigravity run the same workflows
  from one source. Verified live: all 8 discovered by `agy`.
- **`agy-memory` private repo** (github.com/jckeen/agy-memory) — third member of
  the memory trio: `GEMINI.local.md` + `MEMORY.md`, linked into
  `~/.gemini/config/` by setup.sh, mirroring codex-memory.
- **`check-antigravity.sh`** — drift check mirroring `check-codex.sh` (link
  verification, local-state warnings, orphan cleanup with `--fix`); wired into
  the smoke-install CI workflow.
- **`check-agent-parity.sh` now checks three files** — every canonical
  cross-agent rule must appear in `claude/CLAUDE.md`, `codex/AGENTS.md`, AND
  `antigravity/GEMINI.md`; self-test fixtures extended (4 cases).
- **fix: `fix-issue` skill YAML** — unquoted `: ` in the description made the
  frontmatter invalid YAML; Antigravity's strict parser silently dropped the
  skill from discovery (Codex tolerated it). Description now quoted.

### Decisions made
- Antigravity global rules live at `~/.gemini/config/GEMINI.md` — verified
  empirically (marker probe): the `rules/` subdir is NOT loaded there, and
  `skills.json` entries need absolute paths (`~/` is not expanded).
- `codex/skills/` stays the single source for the shared set rather than
  renaming to a neutral `agents/skills/` now — the rename touches 6+ surfaces
  (CI tests, README, doc-contract); proposed as a follow-up issue instead.


## 2026-07-09 — chore: Claude Cloud routine fleet moved to Opus 4.8

### What changed
- The 12-routine Claude Cloud fleet (nightly/weekly automation across the owned
  repos) now runs on **`claude-opus-4-8`** (Opus 4.8), up from a Sonnet mix
  (`claude-sonnet-4-6`, plus `claude-sonnet-5` on docs-steward + codex-harvest).
  These routines do real unattended code work — dep upgrades, security triage,
  docs edits, PR merges — so the reasoning headroom is worth the higher per-token
  cost. Individual routines can be dialed back to Sonnet for cost per-routine.
- Source of truth is the **`jw-routines`** repo (private, `jckeen/jw-routines`),
  not this one: the model is set per-routine in `routines/<slug>/meta.json` and
  pushed to the live triggers via `push-routines.mjs` + the in-session
  `RemoteTrigger` tool. See that repo's README ("Model") for the policy. Recorded
  here because dotfiles is the hub that references the fleet (review-automation
  spec, `commit-push-pr` skill); the per-routine model state is not duplicated.

## 2026-07-09 — feat: automatic review pipeline (Antigravity gate + Codex-bot comment capture)

### What changed
- **Antigravity (Gemini) review gate** hardened and wired as an advisory second
  gate in `/commit-push-pr` (and `/orchestrate`), alongside Codex. Runs
  `agy --mode plan --sandbox` with **no** `--dangerously-skip-permissions`; the
  reviewed diff is fenced as untrusted data with a hash-derived boundary
  (prompt-injection hardening). New `/antigravity-review` skill.
- **Codex-bot comment capture** — `harvest-codex-comments.sh` files
  `chatgpt-codex-connector[bot]` PR review comments as deduped GitHub issues
  (marker `codex-comment-id`); a warn-only `PreMergeCodexHarvest` PreToolUse hook
  runs it at `gh pr merge` time so bot findings aren't lost when a PR merges
  before the bot comments. Hook wiring lives in claude-memory settings.
- **Cloud backstop** — a `nightly-codex-comment-harvest` Claude Cloud routine
  (daily) sweeps the fleet for comments that land after a session ends
  (auto-merge / web merges).
- Follow-up fixes from the bot's own review: include untracked files in
  uncommitted Antigravity reviews; portable `timeout` (gtimeout fallback) and
  `sha1sum`/`shasum`/`cksum` for macOS.
- Design recorded in `docs/superpowers/specs/2026-07-09-review-automation-design.md`.

### Why
- Make review and post-PR comment capture automatic, so shipping by conversation
  (or `/orchestrate`) needs no remembered tool calls.

## 2026-07-08 — feat: /max → /orchestrate; full-lifecycle skill orchestration

### What changed
- Renamed the `max` skill to **`orchestrate`** (dir, frontmatter, and all
  references: README, CLAUDE-GUIDE, session-retro, decompose, AGENTPACK.yaml).
  The name now describes what it does rather than just "effort."
- **Roll-call the skills first** (Plan First) — before executing it now scans the
  available-skills list and invokes the matching process skills (brainstorming /
  systematic-debugging / TDD) without being asked.
- **Close the Loop** (new section) — when work is done it fires the wrap-up
  skills in order automatically: `/verify` → `/code-review`(+`/security-review`)
  → `/simplify` → `/changelog`/`/handoff` → `/session-retro`. Closes the gap
  where session-retro had to be requested manually.
- Description keeps "maximum effort / go all-in" trigger phrasing so habitual
  wording still routes here.

## 2026-07-08 — fix: preserve url.*.insteadOf rewrites across setup.sh runs

### What changed
- **`setup.sh`** — the `.gitconfig.local` regeneration now preserves any
  `url.<base>.insteadOf` rewrites the user added, the same way it preserves
  `safe.directory` entries. Without this, the SSH→HTTPS rewrite that lets
  `claude plugin install` clone github-sourced plugins (e.g. soundcheck) on an
  HTTPS-only machine was silently wiped on the next setup run. It's preserved,
  not forced — a fresh clone with no such entry gets none. Verified with a
  capture→wipe→restore round-trip.

## 2026-07-08 — feat: adopt soundcheck security plugin; thin security-reviewer

### What changed
- **`claude/plugins.txt`** — added `soundcheck@soundcheck` (third-party,
  thejefflarson/soundcheck) for its automatic background security triage on
  generated code — the one review capability the stack lacked (everything else
  is diff/PR-time). Its on-demand commands overlap code-review/pr-review-toolkit
  and collide with the built-in /security-review, so the comment says lean on the
  background triage, not those commands.
- **`setup.sh`** — marketplace registration arm for the `soundcheck` marketplace
  (keeps check-install-integrity green).
- **`security-reviewer` agent** — thinned to in-context app-logic review (broken
  authorization/IDOR, trust boundaries, business-logic flaws) and now explicitly
  defers the generic OWASP/CWE pattern catalog to soundcheck and CVEs to
  dependency-doctor, so the three don't run the same pass three ways.

### Known issues
- `claude plugin install` clones github-sourced plugins over SSH; a machine
  authenticating to GitHub via HTTPS only (no GitHub SSH key) will see the
  install step fail (setup.sh tolerates it and continues). Marketplace + plugin
  identifier are verified correct.

## 2026-07-08 — refactor: deferred audit refactors (#135–#141)

### What changed
Implemented via three parallel worktree-isolated agents (file-disjoint groups),
then merged and re-verified together (tsc, all self-tests + checkers, shellcheck,
setup.sh --check/--repair, --yes --dry-run smoke).
- **lib-symlinks.sh** (#135) — single shared enumerator of the claude/ symlink
  tree, sourced by both setup.sh (linking + audit) and check-claude.sh; removed
  the triplicated tree walks and the nolink fallback duplicated across three bash
  consumers + the TS hook (`claude/nolink.txt` is now the sole source).
- **checker-lib.sh** (#136) — `resolve_script_path`, repo-root resolution, and
  the colored fail-counter helpers factored out of the ~13 copies across the
  dotfiles-local checkers and their self-tests. `check-doc-truth.sh` kept
  deliberately standalone (vendored by /drift-sweep).
- **non-interactive `--yes`** (#137) — setup.sh takes safe prompt defaults and
  skips logins; smoke-install now runs `./setup.sh --yes --dry-run` against a
  throwaway HOME.
- **doc-refs code-strip** (#138) — check-doc-refs.sh now blanks fenced/inline
  code before link resolution (matching check-doc-truth), so links inside code
  blocks stop false-positiving; +3 self-test cases.
- **git-config heredoc** (#139) — the 4 near-identical `.gitconfig.local`
  heredocs collapsed to one parameterized by per-platform editor/helper.
- **bun pin** (#140) — pin the bun *release version* and verify the binary
  against the release SHASUMS, instead of hashing the mutable installer script.
- **cc/cx preflight** (#141) — shared `_agent_preflight` helper removes the
  duplicated resume-detection + cd + sync sequence from cc and cx.

## 2026-07-08 — fix/perf: workflow-optimization audit findings

### What changed
- **Hooks reconciled with CI.** `StripProjectPermissions.hook.ts` watched
  `~/.claude/projects/<slug>/`, a path Claude Code never writes, so it never
  fired — repointed at the real repo-local `.claude/settings.local.json`.
  `conventional-commit.sh` and `check-commit-format.sh` disagreed on valid
  types/syntax (a commit could pass one gate and fail the other); the hook now
  shares the CI checker's type list and subject regex.
- **setup.sh link accounting.** `link_file` now no-ops when a link is already
  correct (was rm+recreating every link each run) and counts real creations;
  `audit_link` returns a repaired code so `--repair` reports "Repaired: N",
  excludes fixed links from Broken, and exits 0 on success. Git identity prompts
  gained the `|| true` guard the other prompts already had.
- **CI streamlined.** Added a `concurrency` block (cancels superseded runs);
  collapsed the five non-required pure-bash checker jobs into one `checks` job
  with a single checkout (shellcheck/tsc/doc-truth stay separate — they are the
  required status checks); dropped the dead shellcheck `additional_files`.
- **Shell workflow.** `pull-all` now pulls repos concurrently (biggest daily
  win — cc/cx wait on the slowest pull, not the sum); `_dev_dir` is memoized;
  `git-hygiene` reads default-branch subjects once instead of per-commit, drops
  dead code, guards `cd`, and fixes the origin-slug regex. `cc-pane`/`cc-tab`
  now validate the project name like the PowerShell side.
- **Guards + docs.** `check-skill-parity.sh` now CI-asserts the README
  "N-agent" count (was hardcoded 8x, unguarded). CLAUDE.md's commit-authorization
  contradiction with the standing-order/conduct layers resolved. AgentPack phase
  gaps fixed (schema-reviewer/ux-reviewer placement); agent overlaps scoped
  (security-reviewer defers CVEs to dependency-doctor); changelog/review/simplify
  trigger collisions disambiguated.

### Decisions made
- The two large structural refactors surfaced by the audit — a shared symlink
  enumerator (setup.sh × check-claude.sh triplication + the nolink fallback) and
  a shared checker-lib for the 13 `resolve_script_path` copies — plus a
  non-interactive `--yes` install mode and the doc-refs/doc-truth link-check
  dedup, are deferred to their own PRs (filed as issues) rather than bundled
  into this one, since they touch the critical install path and need
  fresh-clone testing.

## 2026-07-06 — fix: Fable-layer review findings (Codex pass on #130)

### What changed
- README repo tree now lists `claude/FABLE.md` and `claude/skills/fable-mode/`
  (the inventory was stale after #130).
- Reconciled the autonomy contradiction Codex flagged: CLAUDE.md's "plan
  before non-trivial work, confirm the approach" and FABLE.md's "never ask
  before reversible work" now state the same composed rule — state the
  approach, confirm only when the goal is genuinely ambiguous, then execute
  without re-asking step by step.

## 2026-07-06 — feat: Fable conduct layer (FABLE.md + /fable-mode)

### What changed
- **`claude/FABLE.md`** — operating discipline distilled from Claude Fable 5
  on its last session day: outcome-first final messages, readable-over-concise
  prose, the reversible/destructive/assessment autonomy switch, the end-of-turn
  self-check, evidence discipline, and a pre-send checklist. Imported by
  `claude/CLAUDE.md` (via the `~/.claude/FABLE.md` symlink) so every future
  model on this config — Opus included — inherits the same behavior.
- **`/fable-mode` skill** — recalibration ritual: re-read the layer, audit the
  last three replies against the checklist, state corrections, continue.
- Wired everywhere the config is consumed: AgentPack atoms
  (`instruction:fable-conduct-layer`, `skill:fable-mode`) for
  Codex/Cursor/ChatGPT targets, a Conduct Layer section in `codex/AGENTS.md`,
  `.doc-contract` SOURCE entry, README + CLAUDE-GUIDE skill tables (15 → 16).

### Decisions made
- The layer is a top-level `claude/` file (auto-symlinked by setup.sh) rather
  than a hook injection — imports are simpler, and the async-hook
  additionalContext path is a known 400-error footgun.
- Written model-agnostic: it's a contract about how to operate, not a model
  identity.

## 2026-07-04 — test: fixture self-tests for the 5 remaining checkers (#125)

### What changed
- **Self-tests for every CI checker** — added fixture harnesses for
  `check-doc-refs`, `check-no-personal-data`, `check-agent-parity`,
  `check-skill-parity`, and `check-commit-format` (20 cases total), each wired
  into its CI job to run before the checker (mirroring the `doc-truth` and
  `install-integrity` pattern). All 7 gate checkers now have self-tests; a
  checker that regresses to an unconditional `exit 0` is now caught. Closes the
  remainder of #125.
- Each test copies its (script-dir-resolving) checker into a throwaway repo so
  `REPO_ROOT` points at the fixture; `commit-format`'s runs the real checker in
  a fixture repo since it operates on cwd. Negatives assert the specific failure
  fragment, and the harness was mutation-tested (an always-pass checker turns the
  negatives red) to prove the tests aren't vacuous.
- **`no-personal-data.test.sh` assembles its leak fixtures at runtime** — the
  literal `/home/<user>/` and `C:\Users\<user>\` patterns would otherwise sit in
  a tracked file and trip `check-no-personal-data` against the repo itself. The
  gate caught this self-hosting bug during development.

### Decisions made
- `commit-format`'s self-test lives in the PR-only `commit-format` job (that
  checker only runs on PRs anyway), so it's gated on every PR.

### Known issues
- None outstanding from the June 2026 audit — #120–#125 all resolved.

## 2026-07-03 — fix: fresh-clone audit findings + install-integrity CI gate

### What changed
- **`check-codex.sh` + `claude/hooks/worktree-guard.sh` exec bits** — both were
  tracked `100644`; a fresh clone couldn't run them. `setup.sh` guards the Codex
  health check on `[ -x check-codex.sh ]`, so the missing bit *silently skipped*
  it. Restored to `100755` (#120, and a second offender the new guard surfaced).
- **`openai-codex` marketplace arm in `setup.sh`** — `plugins.txt` lists
  `codex@openai-codex` but the marketplace `case` had no arm for it, so the codex
  plugin fell through to "Unknown marketplace" and never installed on fresh
  machines. Added the `github:openai/codex-plugin-cc` registration (#121).
- **`.gitconfig.local` no longer wipes user `safe.directory` entries** —
  `setup.sh` rewrites the file with `cat >` each run; it now captures existing
  `safe.directory` entries first and restores them after (idempotent, `set -u`
  safe), so hand-added project entries survive a re-run (#122).
- **`setup.sh` degraded-host crashes** — three `set -e`/pipefail capture
  assignments (`GIT_EMAIL`, `WIN_USER`, `cc_type`) now `|| true`, so a failed
  probe degrades to the intended warning instead of aborting the installer (#123).
- **AGENTPACK.yaml skill descriptions regenerated from `SKILL.md`** — `jj`'s
  description was the literal folded-scalar indicator `">-"` and 7 others were
  truncated mid-word; all now word-boundary truncated from source (#124).
- **New CI gate `install-integrity`** — `check-install-integrity.sh` asserts
  every shebanged `*.sh` is `100755` and every `plugins.txt` marketplace has a
  `setup.sh` arm (the two regressions above, promoted from discipline into CI),
  with a fixture self-test `tests/install-integrity.test.sh` (#125).
- **`smoke-install.yml` path filter** aligned with the files its `bash -n` step
  checks (added `check-codex.sh`, `git-hygiene.sh`, `hygiene-status.sh`) so PRs
  touching only those actually trigger the smoke (#125).
- **README** — corrected "same skill set as Claude" (Codex ships a public-safe
  subset, not the full 15) to "the public-safe skill subset".

### Decisions made
- The new checker uses `git rev-parse --show-toplevel` (like `check-doc-truth.sh`)
  so its self-test can drive it against a throwaway fixture repo.
- Left `smoke-install.yml`'s `continue-on-error` grace period and MULTI-AGENT.md's
  Antigravity framing as-is (intentional / roadmap, not defects).

### Known issues
- 6 of 7 remaining checkers still lack fixture self-tests (tracked in #125); only
  `doc-truth` and now `install-integrity` have them.

### What changed
- **`delete-branch-on-close.yml`** — a `pull_request: closed` workflow that
  deletes a PR's head branch when it's closed **unmerged**, scoped to same-repo
  non-default branches. Closes the gap left by `delete_branch_on_merge` (which
  only fires on merge): discarded nightly-drift PRs from the scheduled Claude
  Cloud routine had been orphaning their `claude/*` branches on origin. Branch
  remains recoverable via the closed PR's Restore button. `head.ref` is passed
  through `env:` and quoted, never interpolated into `run:` (no injection).
- **Plugin drift auto-heals at `cc` launch** — the `cc()` launcher now runs
  `sync-plugins.sh` pre-exec on a fresh start (skipped on resume), so any
  manifest plugin missing from the install gets installed *before* the session
  loads its plugins — no manual run + restart. `PluginDriftCheck.hook.ts` stays
  as the SessionStart detection safety net for sessions launched outside `cc`.
- **`sync-plugins.sh` fast path** — exits silently when every manifest plugin is
  already installed (one small file read instead of N `claude plugin install`
  calls), keeping the every-launch sync near-instant in the no-drift case.
- Backfill: cleaned the accumulated stale `claude/*` remote branches and merged
  the lingering nightly-drift README fix.

## 2026-06-18 — feat: multi-agent lane contract for cc/cx/Antigravity

### What changed
- **`claude/MULTI-AGENT.md`** — canonical lane contract defining how Claude Code (`cc`), Codex (`cx`), and Antigravity work as one team on a shared repo. Coordinates through artifacts (instructions + skills via the AgentPack, GitHub issues, `handoff` notes, git) rather than a live shared chat. Lanes: Claude Code = conductor (plan, drive implementation, own handoffs/issues/changelog); Codex = independent verifier + rescue (refute on a fresh checkout, reimplement to cross-check); Antigravity = runtime/browser verification + front-end.
- **`claude/AGENTPACK.yaml`** — AgentPack manifest (atoms, profiles, compatibility) for Claude Code, Codex, Cursor, and ChatGPT. Registers the lane-contract as an instruction atom so all three tools inherit identical instructions and skills.
- **`claude/CLAUDE.md` + `codex/AGENTS.md`** — mirrored operative rules so `cc`, `cx`, and Antigravity follow the lane contract at session start.

## 2026-06-18 — feat: add worktree-guard PreToolUse hook

### What changed
- **`claude/hooks/worktree-guard.sh`** — PreToolUse(Bash) guard that prevents branch create/switch in the primary checkout when another session has active worktrees. Always allows `git worktree` ops and any branch op run from inside a linked worktree. Fails open (any error exits 0) to avoid wedging git. Verified with 6 pipe-tests.

## 2026-06-12 — fix: doc-truth v2 — code spans/fences exempt from dead-ref

### What changed
- **`check-doc-truth.sh` DOC_TRUTH_VERSION=2** — the dead-link rule now
  strips fenced code blocks and inline code spans before extracting links
  (line numbers preserved), so regexes like `[a-z0-9](?:…)` in docs no
  longer false-positive as dead refs. BANNED (Rule 5) intentionally still
  sees code spans — rename residue usually lives in backticks. Found during
  the agent-pack /drift-sweep bootstrap; +4 regression tests (37 total).

## 2026-06-12 — feat: doc-contract drift prevention (ADR 0005)

### What changed
- **`.doc-contract` + `check-doc-truth.sh`** — every tracked markdown file
  is declared LIVING/GENERATED/SOURCE/HISTORICAL; CI (`doc-truth` job) fails
  on undeclared docs, missing historical banners, dead relative links, and
  BANNED patterns (rename residue, hardcoded volatile facts, unchecked
  checkboxes in active docs). Checker is dependency-free bash, vendored into
  other repos by the new skill.
- **`/drift-sweep` skill** — bootstrap a repo's contract (migrating shadow
  trackers like TODO.md into GitHub issues) or sweep out-of-band drift
  (closed issues vs doc mentions, migration high-water marks, stale PRs,
  ghost worktrees).
- Global CLAUDE.md/AGENTS.md gain the doc-contract + retirement-protocol
  rules (parity-guarded); handoff skill now prunes worktrees/branches and
  records PR review state; PR template names the LIVING doc surfaces.
- ROADMAP.md no longer duplicates issue state with checkboxes — issues are
  the live tracker, the file points at them.

## 2026-06-11 — feat: two-way plugin drift check; workflow-efficiency fixes

### What changed
- **`PluginDriftCheck.hook.ts`** now warns in both directions: manifest entries
  not installed (as before) AND installed plugins missing from `plugins.txt` —
  the reverse drift that was only caught by manual audit on 2026-06-10.
- Removed duplicate standalone `@playwright/mcp` registrations from
  `~/.claude.json` (global + `~/dev` project) — the playwright plugin already
  provides the same ~25 tools, so every session was loading them twice.
  Backup at `~/.claude.json.bak-playwright-dedup`.
- Atlas skill descriptions (`atlas-brief`, `atlas-meeting-prep`, in the atlas
  repo) no longer claim systemd-timer automation that is disabled.
- Standing orders (claude-memory): default branches with required status
  checks get branch + PR + auto-merge, not direct pushes that bypass the gates.

## 2026-06-10 — fix: wire dormant hooks, declare drifted plugins (audit follow-up)

### What changed
- **`PrePushStaleSHACheck.hook.ts`** — removed the dead PAI queue emission
  (`~/.claude/PAI/MEMORY/PR_WATCH/queue.jsonl` had no consumer anywhere); the
  stderr warning is the whole behavior now. Registered as a `PreToolUse: Bash`
  hook in settings.json (claude-memory).
- **`ntfy-awaiting-input.sh`** — registered as `PreToolUse: AskUserQuestion`
  with a fresh random `NTFY_TOPIC` in the settings env block. Test push
  delivered successfully.
- **`claude/plugins.txt`** — declared `codex@openai-codex` and
  `security-guidance@claude-plugins-official`, which were installed manually
  but missing from the manifest (fresh-clone setup would have dropped them).
- Deleted orphaned `~/.claude/checkpoint-repos.txt` (live file; its consumer
  was removed long ago — only mention left was a claude-memory CHANGELOG entry).

### Decisions made
- Atlas timers (atlas-brief / meeting-prep / missed) left disabled per
  operator call — installed but intentionally off for now.
- Audit pattern to remember: "exists + symlinked" ≠ "wired" — registration in
  settings.json is the activation step that keeps getting skipped.

## 2026-06-10 — feat: statusline gains cwd + running-agent count, finally wired into settings

### What changed
- **`claude/statusline.sh`** — line 2 now opens with the ~-abbreviated working
  directory (bold blue, PS1-style) separated from the repo link by a dim `·`;
  line 1 shows `⚙N agents` (cyan) when subagent transcripts under
  `<transcript>/subagents/agent-*.jsonl` were written to in the last minute.
  Parses the new `transcript_path` field from the statusline JSON.

### Decisions made
- Discovered `statusline.sh` was never actually referenced from
  `settings.json` — the `/statusline` command generated a throwaway minimal
  script before the gap surfaced. Wired `statusLine` (in claude-memory
  settings.json) to `bash $HOME/.claude/statusline.sh` and deleted the
  duplicate.
- "Agents running" = mtime heuristic on subagent transcripts (<1 min), since
  subagents run in-process and leave no separate process to count.

## 2026-06-10 — feat: drift guards, handoff surfacing, session ledger, retro auto mode

### What changed
- **`claude/nolink.txt` manifest** — the un-symlinked-files list had four
  hardcoded copies (setup.sh ×2, check-claude.sh, SymlinkRepair.hook.ts) that
  the audit found disagreeing. Now one manifest, read by all four consumers
  (each keeps a hardcoded fallback).
- **`check-skill-parity.sh` + CI `skill-parity` job** — asserts the README's
  "N slash commands" claim matches `claude/skills/`, and that the Claude/Codex
  changelog + handoff skills require identical artifact headings. Guards the
  exact drift fixed this week.
- **`HandoffReminder.hook.sh`** (SessionStart, advisory) — if a <7-day-old
  handoff note exists for the current project in `~/.claude/handoffs/`, its
  path is injected into context at session start. Ships unwired;
  `check-hooks-wired` prompts until it's added to settings.json.
- **Session ledger** — statusline now extracts `session_id`/`cost`/`duration`/
  `lines` again (cost and ±lines display had silently dropped out of the JSON
  parse while the docs still advertised them), restores the `$X.XX` and
  `+N -N` segments, and writes one tiny TSV per session to `~/.claude/ledger/`
  (machine-local). New `ledger` shell function aggregates spend by
  day/project; `ledger --prune` drops >90-day entries.
- **`/session-retro --auto`** — in unattended runs (`/max`, overnight),
  proposals go to `~/.claude/retro-proposals/` instead of blocking on
  confirmation; applying still requires an explicit yes in some session.

### Why
The audit's repeated finding was duplicated-surface drift; the manifest and the
CI guard make two whole classes of it structurally impossible. Handoff
surfacing and the ledger close loops where data was written but never read.

## 2026-06-10 — docs: README slimmed to a quickstart that defers to CLAUDE-GUIDE

### What changed
- **README: 886 → ~570 lines.** The duplicated middle (shell-command tables,
  skills table, agent roster, hook details, status line, core workflow,
  keyboard shortcuts, session management, best practices) collapsed into one
  compact "Daily use" section of pointers. README now owns setup + the guided
  tour; **CLAUDE-GUIDE.md is the single canonical daily reference**.
- **CLAUDE-GUIDE gained the missing daily surface**: `cx`, `check-codex`,
  `projects`, `sessions`, worktree jumps (`za`–`ze`/`z0`, `gw*`), and the
  multi-session helpers — so deferring to it is actually complete.
- **New `docs/WINDOWS.md`**: the PowerShell deep-dive (wsl6/ccgrid tables,
  manual install, WSLENV bridge one-liner, distro/dev-dir overrides) moved out
  of README intact.

### Why
Three doc surfaces (README, CLAUDE-GUIDE, trees) carried overlapping tables
that drifted independently — the audit found count mismatches and stale hook
states. One canonical surface per topic; README links instead of repeating.

## 2026-06-10 — feat: cross-tool skill parity + agents inherit the session model

### What changed
- **Paired Claude/Codex skills now produce identical artifacts.** Codex
  `changelog` and `handoff` use the exact same section headings as their Claude
  counterparts, and Codex `handoff` saves to the shared `~/.claude/handoffs/`
  directory — so either tool can resume a session the other started.
- **Codex `branch-hygiene`** gained the `claude project purge` cleanup section
  (it's a shell command; works from any agent).
- **Codex `review`** explicitly names the secrets/injection/sensitive-log
  checks the Claude version flags.
- **All 17 agents dropped their `model: opus` pins.** They inherit the session
  model; the orchestrator picks a lighter model per-run when the task warrants
  it. Rationale noted in AgentPack.md.
- Audited but left alone: `commit-push-pr`, `fix-issue`, `simplify` pairs are
  already semantically aligned — prose differs by design (Codex-idiomatic
  format), workflow and safety rails match.

### Why
Paired skills had drifted enough that the two tools wrote differently-shaped
changelogs and handoff notes, breaking cross-tool session resume. Model pins
predate Fable 5; pinning every review agent to opus wasted cost on light tasks
and would silently stale as models change.

## 2026-06-09 — fix: full-environment audit — cc arg leak, portable paths, doc drift

### What changed
- **`cc <project>` no longer leaks the project name into Claude as a prompt.**
  `cc` cd'd into the project but never `shift`ed, so `claude` received the
  project name as its positional prompt argument — and every multi-session
  helper (`cc-pane`, `cc-tab`, `cc-multi`, `ccgrid`, `cctab`, `ccpane`) routes
  through that path. `cx` already shifted; `cc` now matches.
- **`sessions` finds real Claude sessions again.** The old
  `pgrep -f "node.*claude"` pattern matched plugin broker processes (node paths
  containing `.claude/`) instead of the native `claude` binary. Now `pgrep -x claude`.
- **Private-memory paths derived, not hardcoded.** `setup.sh` and the
  `.bash_aliases` auto-repair path looked for `claude-memory` at a hardcoded
  `~/dev/` instead of the dev dir derived from the checkout location — silently
  skipping bootstrap for anyone cloning under `~/code` etc.
- **NOLINK lists unified.** `setup.sh` (×2), `check-claude.sh`, and
  `SymlinkRepair.hook.ts` each had a different idea of which files aren't
  symlinked. Now aligned (and cross-referenced): `plugins.txt` is no longer
  linked into `~/.claude/` (nothing reads it there), and `setup.sh --check`
  audits the `CLAUDE.md` link it previously skipped.
- **`check-claude.sh` now health-checks/heals `*.ts` hooks**, not just `*.sh` —
  a missing TypeScript hook symlink was invisible to `--heal`.
- **Removed dead PAI-era "Algorithm phase" block from `statusline.sh`** (read a
  `~/.claude/MEMORY/WORK` dir that no longer exists) and the last stale
  "Algorithm" comment in `.bash_aliases`.
- **Hook robustness:** `StripProjectPermissions.hook.ts` exits non-zero
  (non-blocking) when its strip fails to land instead of reporting success;
  `SymlinkRepair.hook.ts` drops a stray `require()` for a proper import.
- **Skill auto-triggering:** `/simplify` and `/handoff` descriptions gained
  concrete "use when" trigger phrases.
- **Doc drift fixed:** README now says 14 slash commands (was 12) and lists
  `/jj` + `/session-retro`; repo tree includes the validation scripts,
  `plugins.txt`, `chrome/`, `docs/`, `ROADMAP.md`; README hooks section points
  at CLAUDE-GUIDE's table as the canonical wired-state source; ROADMAP
  checkboxes now reflect the closed issues (#69–#80, only #77 open); ADR-0004
  status moved Proposed → Accepted.

### Why
Full workflow audit (launch path, hooks, skills, agents, CI/leak surface, docs)
ahead of heavier autonomous use. The recurring failure shape was drift between
duplicated surfaces — NOLINK lists, doc tables, hardcoded paths — so fixes
favor single sources of truth and cross-references over new machinery.

## 2026-06-09 — fix: wire the Claude Code hooks (they were never registered)

### What changed
- **Root cause: every hook was inert.** `~/.claude/settings.json` had no `hooks`
  key at all, so none of the 8 documented hooks ran — including
  `SymlinkRepair.hook.ts`, the SessionStart backstop that re-links new scripts.
  That's why newly-added scripts surfaced as `MISSING` and never self-healed.
  Wired the recommended set in `claude-memory/settings.json`: the 4 SessionStart
  hooks (SymlinkRepair, StripProjectPermissions, HygieneStatus, PluginDriftCheck),
  `conventional-commit` (PreToolUse/Bash), and `format-on-edit` (PostToolUse).
  `ntfy-awaiting-input` and `PrePushStaleSHACheck` stay intentionally off.
- **`cc --heal` now runs on every launch, incl. resume.** It was gated behind
  `resuming == 0`, so `cc -c` / `--continue` / `--resume` skipped self-heal —
  the other reason new scripts stayed `MISSING`. Pull/sync still skip on resume;
  heal (fast, zero-clobber) no longer does.
- **`format-on-edit` is now project-gated.** It only runs a formatter where the
  project opts in (a local prettier, or a black/rustfmt/gofmt config) — the
  global fallback is gone, so hand-wrapped Markdown docs and repos that don't use
  a formatter are never reformatted against their style.
- **`check-hooks-wired.sh` drift-guard.** New local guard (run at every `cc`
  launch via `check-claude.sh`) warns when a hook file exists but isn't
  registered in `settings.json`, with an explicit opt-out list. Public CI can't
  see the private settings, so this lives where the real merged settings are.

### Why
Surfaced when newly-merged scripts reported `MISSING` at session start and `cc`
didn't self-heal. The investigation found the whole hook system was documented as
active but never wired — the same documented-but-not-enforced gap as the prior
entry. Now the wiring is real, drift-guarded, and reflected in CLAUDE-GUIDE's
hooks table (with a Wired column).

## 2026-06-09 — feat: enforcement hardening + local Codex review gate on push

### What changed
- **Secret scanning in CI (`secret-scan`).** New `gitleaks/gitleaks-action@v3`
  job scans every tracked file (and full history on PRs) for committed
  secrets — API keys, tokens, private keys, account IDs. Closes the gap where
  the only leak guard (`check-no-personal-data.sh`) caught machine *home paths*
  but nothing token-shaped, despite the README promising otherwise. A root
  `.gitleaks.toml` extends the default ruleset and allowlists the placeholders
  and example files we ship on purpose (`codex/config.toml.example`, append-only
  history) so the scan stays meaningful.
- **Local Codex review gate, actually run.** New
  `claude/scripts/codex-review-gate.sh` makes ADR-0003 concrete: it runs
  `codex exec review` on the change with a JSON output schema, **blocks the push
  on any critical/high/medium finding** (exit 2), and **files a GitHub issue per
  low/info finding** (deduped, labeled `codex-review`) so nothing falls through
  the cracks. Degrades open (never wedges a push) when Codex can't run, unless
  `CODEX_GATE_REQUIRED=1`. Wired into **both** `commit-push-pr` skills (Claude +
  Codex) as a real step between staging and commit — previously the skill only
  *referenced* a Codex review without ever invoking one.
- **Claude/Codex rule-set parity guard (`agent-parity`).** New
  `check-agent-parity.sh` fails CI when a canonical working-style/public-safety
  rule is present in one of `claude/CLAUDE.md` / `codex/AGENTS.md` but not the
  other. Caught real drift on first run: added "read the surrounding code before
  changing behavior" and "report any test you could not run" to `claude/CLAUDE.md`
  so the two rule sets mirror.
- **Server-side conventional-commit lint (`commit-format`).** New
  `check-commit-format.sh` + CI job lints the commits a PR adds, closing the
  `git commit --no-verify` / out-of-session bypass of the local
  `conventional-commit.sh` hook.
- **Broadened doc-reference guard.** `check-doc-refs.sh` now also validates
  relative Markdown links `[text](path)` resolve to real files/dirs, on top of
  the existing hook/skill path checks. Skips external URLs, anchors, and
  placeholders.
- **Auto-memory now version-controlled.** Claude Code's per-project memory
  (`~/.claude/projects/<proj>/memory/`) is symlinked into the private
  `claude-memory` repo (`claude-code-memory/<proj>/`) — only the `memory/`
  subdir, never the `.jsonl` transcripts — so durable facts survive a machine
  loss and sync across machines. (Lands in `claude-memory`, not here.)

### Why
A workflow audit found the enforcement layer lagged the stated policy: the
public-safety promise covered secrets the CI never scanned for, the "Codex
stop-gate review" was documented but never executed, the two agents' rule files
could silently diverge, and the commit-format hook was bypassable. Each gap is
now promoted from discipline into a CI gate or a real workflow step.

### Known issues
- `smoke-install.yml` stays `continue-on-error` (non-gating) through ~2026-11 by
  design — fresh runners can't run the full installer or `--check` (symlinks
  don't exist yet). The syntax + `--help` coverage is real; the gating flip is
  the documented follow-up.

## 2026-06-04 — feat: check-claude.sh self-heals missing symlinks at launch (`--heal`)

### What changed
- **`check-claude.sh`** — new `--heal` flag that auto-creates **MISSING** symlinks (nothing exists at the destination, so linking clobbers nothing and the source is guaranteed present). Reports each as `HEALED` and a `Self-healed N missing link(s)` summary line. **Guardrail:** heals only the zero-clobber MISSING case (nothing at all exists at the destination). Any non-symlink path already sitting there — a regular file *or* a directory — plus `WRONG` targets and orphaned links stay report-only, since those can be intentional divergence. The source is re-validated immediately before linking and the link is confirmed to resolve afterward, so a vanished source or a racing run can't print a false `HEALED`. Standalone `check-claude` (no flag) remains a pure read-only reporter. Also generalized arg parsing so `--fix` and `--heal` can coexist.
- **`.bash_aliases` `cc()`** — the launch-time health check now runs `check-claude.sh --heal`, so a skill/script added to the dotfiles repo since the last `setup.sh` gets linked automatically on the next `cc` instead of nagging the user to run `setup.sh`.

### Why
Four skills/scripts added to the repo after the last `setup.sh` (`skills/jj`, `skills/session-retro`, `scripts/check-doc-refs.sh`, `scripts/check-no-personal-data.sh`) surfaced as `MISSING` warnings at every launch with no auto-fix — the check detected drift but only told the user to run a command. `setup.sh --repair` already heals, but it's too aggressive for launch (it backs up `NOT LINKED` files and rewrites `WRONG` targets). `--heal` is the conservative middle: self-heal the safe case, report the ambiguous ones.

## 2026-06-03 — chore: coding-setup hardening (skills, ADRs, drift-guard, portable CLAUDE.md)

### What changed
- **Doc drift scrubbed (Tier 1).** Removed the three phantom hooks left by the PAI decommission (`PRWatcherAutoLaunch`, `PRWatcherSurface`, `PromptProcessing`) from `CLAUDE-GUIDE.md`, `README.md`, and `claude/hooks/tsconfig.json`; reconciled the hooks tables to the 8 hooks that actually exist on disk.
- **Skills brought to the Agent Skills authoring spec (Tier 2).** Rewrote 5 weak descriptions (`changelog`, `claude-server`, `kickoff`, `log-error`, `review`) to third-person WHAT + "Use when…" triggers so the agent auto-invokes them instead of waiting to be typed. Removed the misspelled no-op `user_invocable` field from all 11 skills (the real field is `user-invocable`, default true).
- **Verification made first-class (Tier 3).** Added a `/verify` step to the workflow and command table in `CLAUDE-GUIDE.md` — Boris Cherny's "#1 quality multiplier."
- **Doc-reference drift-guard (Tier 3).** New `claude/scripts/check-doc-refs.sh` fails CI when a doc references a hook/skill file that doesn't exist; wired a `doc-refs` job into `ci.yml`. Allowlists append-only history (CHANGELOG, SECURITY_FINDINGS, Plans, ADRs).
- **`commit-push-pr`** now surfaces `gh pr checks` (CI status) after opening a PR — the gate is Codex stop-review + CI green, not PR comments (ADR-0003).
- **Agent-native / compounding (Tier 4).** New skills: `jj` (jujutsu for single-agent work; worktrees for multi-agent) and `session-retro` (proposes improvements to your own skills on a thank-you, propose→confirm→apply).
- **ADR practice established.** `docs/adr/` with a template + ADR-0001 (the four-layer Issues/PRs/ADRs/CHANGELOG record model), backfilled ADR-0002 (PAI decommission) and ADR-0003 (Codex stop-gate over PR-watch), and ADR-0004 (Every compound-engineering evaluation — don't install, adopt two ideas).
- **Portable CLAUDE.md.** `claude/CLAUDE.md` is now generic and imports personal identity from the private `claude-memory/CLAUDE.md` (`@~/dev/claude-memory/CLAUDE.md`); the public repo no longer ships a personal "About me."
- **Privacy cleanup.** Removed `SECURITY_FINDINGS_20260524.md` from the public repo (preserved privately in `claude-memory`) and untracked + gitignored `Plans/`.
- **Roadmap.** `ROADMAP.md` indexes the milestone "Coding setup hardening — 2026-06" (issues #69–80).

### Why
An audit of the skills and workflow against Boris Cherny's practices, the Code w/ Claude 2026 guidance, and the Agent Skills authoring spec. Goals: kill doc drift, make the agent auto-invoke skills (fewer commands to memorize), make verification first-class, and adopt agent-native compounding so the toolset self-maintains. Decisions are recorded as ADRs; the backlog as GitHub Issues + `ROADMAP.md`.

### Known issues
- `PrePushStaleSHACheck.hook.ts` remains on disk but its companion PR-watcher hooks are gone — likely orphaned; flagged for review.
- ADR-0004's `agent-native-review` subagent and the "compound/codify" + healing-skill ideas are scoped but not yet built (tracked in #77).

## 2026-06-03 — chore: decommission PAI

### What changed
- **Removed PAI entirely** from the live system and both repos. Deleted the PAI engine (`~/.claude/PAI`, 386 MB), the 45 PAI skills, the 18 PAI subagents, the ~40 PAI hooks, `~/.claude/MEMORY`, `ISA.md`, and the pulse + voice-server systemd units/daemon. The plain-mode toggle (`pai-mode.sh`, `pai-on`/`pai-off`/`pai-status`) is gone — plain is now simply the baseline.
- **`claude/CLAUDE.md`** (relocated from `claude/plain/CLAUDE.md`) — now the standalone global instructions, symlinked into `~/.claude/CLAUDE.md` by setup.sh. Absorbed the portable identity/steering/tech-stack content and the "auth at the boundary" rule from the old PAI USER files.
- **`setup.sh`** — dropped `--pai`/`--no-pai`, the USE_PAI prompt, the pai-config/pai-user copy block, and PAI-gated bootstrap. `bootstrap.sh` now runs unconditionally for the private settings layer. Kept dev/memory auto-memory + claude-memory safe.directory.
- **`.bash_aliases`** — removed the pai aliases and `sync-pai-config`.
- **`claude/systemd/install.sh`** — installs only the git-hygiene timer (voice server gone).
- **`claude/skills/{decompose,max}`** — decoupled from the removed PAI Algorithm; now use platform-native parallelism and the skills that still exist.
- **`README.md`, `CLAUDE-GUIDE.md`, `CONTRIBUTING.md`** — scrubbed of PAI; private-repo docs rewritten for the slimmed claude-memory.
- Settings moved to `claude-memory/settings.json` (private, linked by bootstrap). ElevenLabs/Telegram secrets deleted.

### Why
The PAI experiment ran its course. Removing it returns the setup to a lean, model-led baseline — the direction the toggle (2026-05-28) was already testing — while keeping the genuinely reusable tooling (git-hygiene, codex, chrome bridge, review agents, personal skills) and the cross-machine `claude-memory` repo. Full record in `Plans/PAI-DECOMMISSION.md`. Rollback tarballs in `~/` for the non-git live files.

## 2026-05-28 — feat(claude): pai-off/pai-on toggle for testing plain Claude

### What changed
- **`pai-mode.sh`** (new, 0755) — top-level script with `off` / `on` / `status` subcommands that swaps `~/.claude/CLAUDE.md` and `~/.claude/settings.json` between the full PAI config and a lean "plain" baseline. `off` saves the current PAI symlink targets to `~/.claude/.pai-mode.state`, generates `~/.claude/settings.plain.json` from the live PAI settings via `jq` (stripping `hooks`, `dynamicContext`, `contextFiles`, `loadAtStartup`, identity blocks, `statusLine`, voice, and spinner keys while keeping `mcpServers`, `permissions`, `enabledPlugins`, and `env`), then repoints the symlinks. `on` restores the saved targets exactly. Both are idempotent and refuse to clobber a non-symlink. Generated artifacts live in `~/.claude/` and are never committed, so personal MCP config stays local.
- **`claude/plain/CLAUDE.md`** (new) — the lean, public-safe instruction file `pai-off` points at: ~25 lines of generic working/verification/git guidance, no Algorithm/modes/hooks, no personal data.
- **`.bash_aliases`** — added `pai-off`, `pai-on`, `pai-status` aliases.
- **`setup.sh`** — added `pai-mode.sh` to both the bin-link section (1c) and `run_health_audit`, so it symlinks into `~/.local/bin` and is health-checked alongside the other top-level helpers.
- **`.github/workflows/ci.yml`** — added `pai-mode.sh` to the shellcheck `additional_files` list. Verified clean at `--severity=error` (the CI gate) and at default severity.
- **`README.md`** — new "PAI mode toggle (test plain Claude)" subsection documenting the commands, the keep/strip split, the restart requirement, and the expected `check-claude` flag while in plain mode.

### Why
The AI-tooling landscape in 2026 is converging on strategic minimalism — power users keep `CLAUDE.md` lean and invest in verification infrastructure rather than heavy prompt scaffolding, and Boris Cherny (Head of Claude Code) runs an almost-unconfigured setup. Testing that hypothesis on this machine previously meant manually moving two symlinks aside, which also killed MCP servers and the permission allowlist and made "plain Claude" annoying to use. This toggle makes the experiment one command and fully reversible: plain mode stays usable (MCP + permissions kept) and `pai-on` provably restores the exact prior state, so switching back and forth is safe.

## 2026-05-22 — fix(setup): symlink dotfiles bin scripts onto PATH

### What changed
- **`setup.sh`** — new install section **1c** symlinks `gh-bootstrap.sh`, `git-hygiene.sh`, and `hygiene-status.sh` from `$DOTFILES_DIR` into `~/.local/bin`. `run_health_audit` (`--check` / `--repair`) now covers these three symlinks as well.

### Why
These top-level helper scripts shipped in the repo but `setup.sh` never wired them onto PATH, so a fresh shell would fail `gh-bootstrap.sh --all ~/dev` with `command not found` even though the script existed. `~/.local/bin` is already prepended to PATH by `.bash_profile`, so symlinking there is the minimal idiomatic fix and keeps the script's existing self-contained location in `$DOTFILES_DIR`.

## 2026-05-14 — fix(windows/wsl6): pre-warm WSL distro + opt-in pane serialization

### What changed
- **`windows/wsl-helpers.ps1`** — `wsl6` now pre-warms the WSL distro (single `wsl.exe -d <distro> -- true` call) before spawning the six panes, so they attach to an already-running VM instead of cold-starting it six times in parallel. Adds a `$env:WSL6_PANE_DELAY_MS` opt-in: when set to a positive integer, `wsl6` issues each `split-pane` as a separate `wt.exe` IPC call with the configured delay between them, fully serializing pane creation. Default 0 preserves the previous all-at-once chained-command behavior.

### Why
On the Surface Pro 11 (Snapdragon X / ARM, less compute than the desktop), `wsl6` occasionally lands one of the six panes in a state where stdin isn't wired to its bash child — cursor blinks, typing produces nothing. Single warm `wsl.exe` attach measures ~300ms on this machine; six in parallel against a cold WSL2 VM contend for VM startup + ConPTY allocation slots. Pre-warming collapses the cold-start window and is free when the distro is already running. The serialization knob is the bigger hammer reserved for cases where pre-warm alone isn't enough — costs ~$delayMs × 7 of visible tab assembly in exchange for a guaranteed-attached pane.

Note on scope: the user reports the stuck-pane symptom most often manifests *after* running `cc` (which launches `claude --remote-control --chrome` plus MCP servers) inside one of the panes. That timing suggests a second contributor beyond the pure spawn race — likely resource contention or focus loss when chrome / playwright-mcp / context7-mcp all spin up on a memory-tight ARM box. This change targets the spawn-race contributor only; if `wsl6 → cc → stuck pane` still reproduces after this, the next investigation is on the cc-launch side (chrome focus stealing, EcoQoS suspension of background bash processes, etc.).

## 2026-05-14 — feat(claude): SessionStart symlink self-heal

### What changed
- **`claude/hooks/SymlinkRepair.hook.ts`** (new, 100755) — SessionStart hook that re-links missing/broken dotfiles → `~/.claude/` symlinks. Mirrors `setup.sh`'s link logic for hooks (`*.{sh,ts}`), scripts (`*.sh`), agents (`*.md`), chrome, per-skill files, and top-level claude/* files (minus the `NOLINK` set: `AgentPack.md`, `CLAUDE.md`, `settings.json`). Resolves `$DOTFILES_DIR` via `realpathSync(self)` so it works regardless of where dotfiles live.
- Safe-by-default: only installs missing entries or replaces broken symlinks. Existing regular files and symlinks pointing elsewhere are skipped and reported — clobbering remains `setup.sh`'s job.
- Emits a single `<system-reminder>` summarizing linked/fixed/skipped entries; silent when nothing to do. Non-blocking (exit 0 always).
- Registered first in `pai-config/settings.json` SessionStart array so it can repair sibling hooks (including `PluginDriftCheck` itself) before they fire next session.

### Why
The 2026-05-13 PR added `PluginDriftCheck.hook.ts` and `sync-plugins.sh` to the dotfiles repo but neither got symlinked into `~/.claude/` on this machine because `setup.sh` wasn't re-run. The hook runner silently skips registered commands whose paths don't exist, and `PluginDriftCheck` only detects *plugin* drift, not its own missing symlink — chicken-and-egg. `SymlinkRepair` closes that loop: once linked, it self-heals all sibling drift going forward, so `git pull` in the dotfiles repo is enough to install new hooks/scripts at next SessionStart without a manual `setup.sh` invocation.

## 2026-05-13 — feat(claude): SessionStart plugin-drift warning + sync-plugins.sh

### What changed
- **`claude/hooks/PluginDriftCheck.hook.ts`** (new, 100755) — SessionStart hook that diffs the dotfiles plugin manifest against `~/.claude/plugins/installed_plugins.json` and emits a `<system-reminder>` warning when any manifest entry is missing. Non-blocking (exit 0 always). Resolves the manifest via `realpathSync(import.meta.url)` walked up to the dotfiles repo, with `$DOTFILES_DIR` env-var override.
- **`claude/scripts/sync-plugins.sh`** (new, 100755) — Companion installer. Walks the manifest line by line and runs `claude plugin install` for each entry. Uses `set -eo pipefail` so install failures actually fail the script (without pipefail, `cmd | tail -1` masks the install's exit). Symlink resolution uses a portable `resolve_script_path()` (`cd -P` + `readlink` with no flags) so it works on BSD readlink (macOS) and GNU readlink alike.

### Why
Before this PR, plugin drift between machines was invisible until someone noticed a slash command was missing. The hook surfaces drift at SessionStart so the user knows what to reconcile, and `sync-plugins.sh` is the one-shot remediation the warning points at. Both resolve their manifest from the dotfiles repo (where `setup.sh` actually keeps it — `plugins.txt` is in the `NOLINK` list and is not symlinked into `~/.claude/`), so they work even when run on a clean bootstrap.

## 2026-05-13 — feat(shell): adopt `.bash_profile` for login-shell PATH + cc availability

### What changed
- **`.bash_profile`** (new, tracked) — Adopts the standard distro convention: exports the bun PATH (so the PAI installer's `grep -q '\.bun/bin'` skip-check holds) and sources `~/.bashrc` for login shells. Single source of truth, version controlled, audit-able.
- **`setup.sh`** — Symlinks `~/.bash_profile` → `dotfiles/.bash_profile` (alongside the existing `.bash_aliases` symlink). Replaces the earlier ephemeral self-heal block with a structural symlink, so the fix survives any tool that re-touches `$HOME`. Adds a final verification step that runs `bash -li -c 'type cc'` and warns loudly if a login shell still cannot resolve `cc` — catches regressions before the user opens a fresh `wsl6`.
- **`windows/cc-functions.ps1`** — `cctab`, `ccpane`, and `ccgrid` now invoke `bash -lic 'cc "$1"'` (login + interactive + command) instead of `bash -lc`. The `-i` flag forces interactive mode so `~/.bashrc`'s non-interactive guard (`case $- in *i*) ;; *) return;; esac`) doesn't return early before the `cc` function gets defined.

### Why
`wsl.exe -d Ubuntu --cd ~/dev` (what `wsl6` invokes for each of its 6 panes) launches a **login** shell. By bash convention, login shells read `~/.bash_profile` and skip `~/.bashrc`. The PAI installer creates `~/.bash_profile` to put bun on PATH but doesn't delegate to `.bashrc`, so `cc`, `pull-all`, `projects`, NVM, cargo, and the `cd ~/dev` auto-jump only appear after the user manually runs `source ~/.bashrc` in each pane. The PowerShell launchers had a parallel bug: `bash -lc` is login + non-interactive, and `.bashrc`'s interactive guard returns immediately, so `cc` was never defined for those tab/pane spawns either. Promoting `.bash_profile` into the dotfiles repo (instead of patching it in place via setup.sh) makes the fix structural — the repo owns the file, the symlink survives `link_file`, and the PAI installer's idempotent skip-check sees the bun-PATH line and never overwrites. The new `bash -li` verification in setup.sh fails loudly the moment a regression appears, instead of waiting for the user to discover it the next time they open `wsl6`.

## 2026-05-05 — README: collapse platform-specific & reference content into accordions

### What changed
- **`README.md`** — Restructured for intentional, audience-aware reading. The three Quick Start platforms (Windows / macOS / Linux) are now `<details>` accordions so a reader on one platform isn't scrolling past the other two. The Windows-only PowerShell helper deep-dive (~85 lines of WSL ↔ PS bridging) is now collapsed by default. Reference-density sections — *What gets installed / configured*, *Platform-specific behavior*, *Safety hooks line-by-line*, *full keyboard shortcut list*, *claude-memory* and *codex-memory* deep dives, *Customizing*, *Repo Structure tree* — also collapsed, with one-line summaries left visible. Added `<br>` after each `<summary>` so GitHub renders code blocks/tables inside `<details>` correctly. The Session Management section was redundant with Shell Commands & Aliases above; compressed to a one-line "remote access is always on" pointer.

### Why
The README was 780 lines, and reading it top-to-bottom forced a Windows user past macOS prerequisites, an experienced user past tool-install tables, and a non-PAI user past memory-repo internals. Accordions let each reader stop at the depth they need without losing the "I know this exists if I want it" affordance. Net length went up slightly (843 lines from `<details>` wrappers and blank-line padding) but visible-on-load length is roughly half of what it was.

## 2026-05-05 — Repo hygiene: redact per-project audit details from older entries

### What changed
- **`CHANGELOG.md`** — Compressed three older 2026-05-03 ADR entries into a single, generic entry. Removed the per-project CWE-306 cross-reference enumeration and the per-stack audit details. Removed project names from the 2026-04-04 Stop-hook and architecture-diagram bullets.

### Why
The deleted entries paired specific personal-project names with specific vulnerability classes and "still-TBD" status. That mapping is more useful to an outside reader than the changelog actually needed to be — the projects are public on the GitHub profile already, but enumerating them next to vuln status creates a hit-list that no one needed. The changelog still records *that* the work happened and *what* the principle is; it no longer hands out the per-repo scorecard. Innocuous mentions (alias-usage examples, service filenames) left intact.

## 2026-05-05 — Repo hygiene: remove stale root-level docs; gitignore prevention rules

### What changed
- **Deleted** `PAI-MIGRATION-HANDOFF.md` (one-shot migration doc from 2026-03-22, migration long since complete; full text preserved in commit `8ddea74`).
- **Deleted** `SECURITY_FINDINGS_20260419.md` and `SECURITY_FINDINGS_20260503.md` (point-in-time static-analysis snapshots; remediations already shipped in PRs #3 and #18 — the audit trail lives in those PRs, not in committed report files).
- **Deleted** `ADR/AUTH-AT-THE-BOUNDARY.md` and the empty `ADR/` and `Plans/` directories. The cross-service architectural decision didn't belong in dotfiles. The load-bearing principle was distilled into a new `## Auth at the Boundary` section in `~/dev/claude-memory/pai-user/AISTEERINGRULES.md` (steers all PAI agents). Per-stack code snippets remain available in commit `ed86ea2` if needed for reference.
- **`.gitignore`** — Added `SECURITY_FINDINGS_*.md` and `*-HANDOFF.md` patterns so future agents writing one-off reports at the root don't accidentally commit them. Ignore comment points authors to `claude-memory/pai-user/AISTEERINGRULES.md` as the right home for cross-cutting decisions.

### Why
Root of the dotfiles repo had collected three one-off documents (a migration handoff, two weekly security reports) and an architectural decision record that was binding on six service repos but only physically present here. Symptom of "no convention for where reports go." Distilling the ADR into a steering rule retains the prescriptive value (auth-by-default at the boundary, refuses to start if secret unset, opt-out is greppable) without dragging 462 lines of per-stack code into a config repo.

## 2026-05-05 — branch-hygiene: add `claude project purge` step

### What changed
- **`claude/skills/branch-hygiene/SKILL.md`** — Added `## Project state cleanup` section documenting the v2.1.126 `claude project purge [path]` primitive. Wires post-archive cleanup so dead-project Claude Code state (transcripts, file history, config entries, tasks) gets reclaimed alongside branches. Recommends `--dry-run` before `--yes`, mentions `--all` for periodic cleanup. From the PAI Upgrade Report 2026-05-05 (MEDIUM tier).

Commit `45cede3`.

## 2026-05-05 — Reposition README as jumpstart guide; install PS helpers into both PS 5.1 and PS 7

### What changed
- **`README.md`** — Significant top-of-file rewrite. New "What you get (and why it matters)" section explicitly outlines the UX wins (`cc`/`cx` aliases, status line, slash commands, agent pack, hooks, multi-session tooling, auto-hygiene, Codex parity, symlink hygiene) so users understand the experience before installing. Quick Start split into per-platform sections — **Windows (WSL2)** with explicit prerequisites (`wsl --install -d Ubuntu`, `winget install Microsoft.PowerShell` for PS 7, Windows Terminal), **macOS** (Xcode CLT + Homebrew), and **Linux**. Repositions the repo as "the jumpstart for Claude Code + Codex" rather than just dotfiles. Try-it-now block moved up and expanded with `projects` / `sessions` aliases. PowerShell section calls out PS 7 as preferred and explains the dual-host install behavior. Setup-script flag table added (`--check`, `--repair`, `--no-pai`, `--pai`).
- **`setup.sh`** §7b — Refactored into `install_ps_helpers_for_host()` that takes the host exe. Loops over **both** `powershell.exe` (5.1) and `pwsh.exe` (7) when present so users opening either host see the helpers. Creates the profile directory before the file (PS 7 path doesn't exist by default on a fresh machine). Suppresses benign `Set-ExecutionPolicy` noise via try/catch + `*>$null`. Prints which host + version + profile path is being wired so the user can confirm.

### Why
1. **PS 7 dual-host bug**: User reported `wsl6: term not recognized` in PowerShell 7 immediately after the previous PR merged. Root cause: PS 5.1 and PS 7 use different `$PROFILE` paths, and the installer only ran `powershell.exe` (5.1). Fixed by looping over both hosts.
2. **README positioning**: The previous README opened with "Production-ready Claude Code setup with 4 hooks, 11 slash commands…" — feature-list framing. Restated as a jumpstart for using Claude/Codex on a fresh Mac or Windows machine, with explicit per-platform prerequisites and a "what you get and why it matters" section so users understand the experience and don't have to remember commands.

End-to-end verified by running the new dual-host installer against the live machine (PS 5.1 + PS 7), refreshing both profiles, and confirming `wsl6` is dot-sourced in both. Audit clean (44/44 symlinks).

## 2026-05-05 — Make `wsl6` agent-neutral by file split; clarify README install path

### What changed
- **`windows/wsl-helpers.ps1`** (new) — Agent-neutral PowerShell helpers. `wsl6` moved here from `cc-functions.ps1`. Self-contained: defines its own `Test-WtAvailable` and `$WslDistro`, depends on nothing Claude-specific. Header explicitly states "These helpers do NOT call Claude Code, Codex, or any AI agent."
- **`windows/cc-functions.ps1`** — `wsl6` removed; replaced by a one-line pointer comment to `wsl-helpers.ps1`. Header updated to call out the split and note future `cx-functions.ps1` could mirror cc-functions for Codex.
- **`setup.sh`** §7b — Now copies BOTH files to `$env:USERPROFILE\.<name>.ps1` and dot-sources each from `$PROFILE`. Loop-based, idempotent, regex-escaped duplicate-check per file. Prompt reworded to call out which file is agent-neutral and which is Claude-specific.
- **`README.md`** — "Try it now" expands with a WSL-PowerShell callout (`wsl6` first, then `ccgrid`/`cctab`/`ccpane`/`ccprojects`), `dotfiles-update` documented as the "I missed a prompt" recovery path. Multi-session/PowerShell section adds a file-scope table (agent-neutral vs Claude-specific). Manual install snippet + bash bridge updated to install both files. Repo Structure tree updated.

### Why
`wsl6` worked regardless of agent but lived inside a file named `cc-functions.ps1`, which made it look Claude-coupled. The split makes the agent-neutral nature visible at the filesystem level — a Codex-only or no-agent user can dot-source just `wsl-helpers.ps1`. The README "Try it now" section now answers "how do I get wsl6?" upfront instead of burying it 150 lines into the multi-session subsection. End-to-end verified by running the new install snippet against the user's live `$PROFILE` — both files deployed, no duplicate profile entries, audit clean (44/44 symlinks).

## 2026-05-05 — Fix WSL→Windows PowerShell install: clone-path agnostic + WSLENV + error propagation

### What changed
- **`setup.sh`** section 7b — Builds `$DOTFILES_UNC` dynamically from `$DOTFILES_DIR` (replaces hardcoded `\home\<user>\dev\dotfiles\`). Adds `WSLENV="DOTFILES_UNC"` so the env var actually crosses the WSL→Windows boundary (without it, `$env:DOTFILES_UNC` arrived empty and the install silently fell back to a malformed UNC path). Captures `${PIPESTATUS[0]}` so a failing `powershell.exe` no longer gets masked by the `sed 's/^/  /'` pipe — failure now prints "PowerShell install FAILED (exit N)" instead of the success message.
- **`README.md`** — Same `WSLENV` fix to the documented bash bridge one-liner. Without it, the example as published would silently fail on a fresh machine because `$env:WSL_USER` and `$env:WSL_DISTRO` arrived empty in PowerShell.

### Why
Codex review on PR #21 flagged P1 (clone path hardcoded) and P2 (sed masking the exit code). End-to-end testing of the fix surfaced a third bug: WSL2 does not auto-propagate env vars to `powershell.exe` — `WSLENV` opt-in is required. So the bash bridge in both setup.sh and the README would have failed on any machine that hadn't pre-set `WSLENV`. All three issues are fixed; verified by test runs that confirm correct UNC resolution, env var propagation, and non-zero exit propagation through the `sed` pipe.

## 2026-05-05 — `wsl6` PowerShell helper + auto-install on WSL setup

### What changed
- **`windows/cc-functions.ps1`** — New `wsl6` function. Opens a Windows Terminal tab with 6 plain WSL shells in a precise 3-column × 2-row grid (3 up, 3 down). Three even-width columns via `-V -s 0.6667` then `-V -s 0.5`, then horizontal split each column. No project launching — just plain WSL shells.
- **`setup.sh`** — New section 7b. On WSL, calls `powershell.exe` to copy `cc-functions.ps1` to `$env:USERPROFILE\.cc-functions.ps1` and dot-source it from `$PROFILE`. Idempotent: re-running setup refreshes the local copy and skips the profile edit if already wired. Replaces the manual README copy-paste step.
- **`README.md`** — Documents `wsl6` in the PowerShell command table; flags the README install block as the manual fallback (setup.sh is now primary).

### Why
The README install block worked but required reading docs and copy-pasting on every new machine. Setup.sh now does it automatically, which matches the rest of the dotfiles bootstrap pattern (audio routing, claude-memory bootstrap, etc.). The `wsl6` function specifically addresses "open 6 WSL shells in a 3×2 grid" without needing project arguments — the existing `ccgrid` requires named projects and uses alternating splits, which doesn't produce a clean 3×2 layout.

## 2026-05-05 — Hygiene automation: shared status reader + Codex parity

### What changed
- **`hygiene-status.sh`** — New top-level script. Reads `~/.local/state/hygiene/status.json` (the cached drift state) and emits in one of 5 modes: `--status` (one-liner), `--text` (silent if clean), `--cli` (color, silent if clean), `--json` (raw), `--reminder` (Claude hook). Single source of truth for both agents and CLI.
- **`claude/hooks/HygieneStatus.hook.sh`** — Refactored to a thin `exec` wrapper around `hygiene-status.sh --reminder`. Behavior unchanged; logic now shared.
- **`claude/scripts/hygiene-cron.sh`** — State file moved from `~/.claude/state/` to `~/.local/state/hygiene/` (XDG-neutral). Logs moved from `~/.local/share/git-hygiene/` to the same dir.
- **`check-claude.sh` and `check-codex.sh`** — Both now call `hygiene-status.sh --cli` so `cc` and `cx` surface drift the same way at launch.
- **`claude/skills/branch-hygiene/SKILL.md` and `codex/skills/branch-hygiene/SKILL.md`** — New skill registered for both agents. Documents the three-layer setup, the 3-signal merge confirmation, and the rule that agent-spawned `gh repo create`/`clone` must run `gh-bootstrap.sh` manually (the shell wrapper only fires from the user's interactive shell).

### Why
Original implementation was Claude-pathed (`~/.claude/state/`) and the hook surfaced drift only on Claude SessionStart. Codex has no SessionStart hook, so `cx` had no drift visibility. Moving state to XDG-neutral path and routing both check scripts through the same status reader makes the whole loop agent-agnostic. The new skill teaches both agents how to inspect, fix, and respond to hygiene state on demand.

## 2026-05-05 — Hygiene automation: zero-touch loop

### What changed
- **`claude/systemd/git-hygiene.service` + `git-hygiene.timer`** — New systemd user units. Timer fires daily at 09:30 (with 15min jitter, `Persistent=true` so missed runs catch up); service is oneshot.
- **`claude/scripts/hygiene-cron.sh`** — Daily wrapper invoked by the service. Always runs `gh-bootstrap --check --all ~/dev` and writes `~/.claude/state/hygiene-status.json`. On Sundays only, also runs `git-hygiene clean ~/dev --yes`. Logs to `~/.local/share/git-hygiene/cron.log`.
- **`claude/hooks/HygieneStatus.hook.sh`** — SessionStart hook (registered in claude-memory's `pai-config/settings.json`). Reads the cached JSON state in ~11ms; emits a `<system-reminder>` only when drift exists or state is older than 48h. Silent otherwise.
- **`.bash_aliases`** — New `gh()` wrapper function. Intercepts `gh repo create` and `gh repo clone` to run `gh-bootstrap.sh` on the new repo immediately. All other gh subcommands pass through unchanged.
- **`claude/systemd/install.sh`** — Extended to install `git-hygiene.timer` alongside `pai-voice-server.service`. Voice server logic is unchanged.

### Why
Closes the "remember to run the script" gap from the 2026-05-05 morning session. Now the loop is fully automatic: GitHub auto-deletes branches on merge → `git-hygiene` weekly cleans whatever local state slips through → `gh-bootstrap` auto-applies on every new repo via shell wrapper → SessionStart hook surfaces drift if any of the above ever stops working. Drift detection is daily (cached, hooks read-only), cleanup is weekly (Sunday-only inside the daily wrapper).

## 2026-05-05 — Branch hygiene tooling: `git-hygiene.sh` + `gh-bootstrap.sh`

### What changed
- **`git-hygiene.sh`** — New script for multi-repo branch hygiene. `audit` mode reports (default branch, dirty state, deletable branches); `clean` mode runs `git fetch --prune`, sets `origin/HEAD` if missing, and deletes local branches that are confirmed merged via three independent signals: cherry patch-equivalence, commit-subject presence on default, or `gh pr` MERGED state. Skips current branches, worktree-checked-out branches, and dirty trees. `--yes` flag for non-interactive runs.
- **`gh-bootstrap.sh`** — New script that applies the 8 standard auto-hygiene repo settings (delete-branch-on-merge, allow-auto-merge, allow-update-branch, squash-only, PR-title/body squash format) via `gh api PATCH`. Modes: `gh-bootstrap` (cwd), `gh-bootstrap owner/repo`, `gh-bootstrap --all DIR`, `--check` for read-only drift report. Idempotent. Detects forks-without-admin and skips gracefully.

### Why
Server-side auto-hygiene (delete-branch-on-merge, GitHub Pro auto-merge) added 2026-05-04 cleans the remote but leaves stale local branches and "gone" upstream tracking refs. `git-hygiene.sh` closes the local-side gap so multi-repo `git pull` stays clean. `gh-bootstrap.sh` makes the server-side setup itself reproducible — one command for any new repo, drift-detection across all of them. `git cherry` alone misses squash-merged branches when squash collapses 2+ commits — the subject-search and PR-state signals catch that case.

## 2026-05-04 — Security sweep remediations

### What changed
- **`claude/scripts/common.sh` + `overnight.sh`** — `FULL_AUTO=true` in the environment is ignored; full-auto now requires the explicit `--full-auto` CLI flag. Overnight runner forwards that flag with an array instead of unquoted string expansion.
- **`windows/cc-functions.ps1`** — WSL launch commands now pass project names as positional bash args (`cc "$1"`) instead of interpolating them into `bash -ic "cc $p"`.
- **`setup.sh`** — Validates the Windows username before writing WSL editor config, writes `.gitconfig.local` with mode `0600`, validates audit sources are inside the dotfiles tree, and warns if the canonical bun path is missing.
- **`claude/systemd/install.sh`** — Port cleanup now reports failed `kill` / `kill -9` attempts instead of masking them.

### Why
Follow-up to the 2026-05-03 static security sweep. The report-only PR is now actionable: confirmed injection and unsafe-bypass paths are fixed while preserving the normal Claude launcher workflow.

## 2026-04-24 — check-claude.sh: exclude `plugins.txt` from symlink audit

### What changed
- **`check-claude.sh`** — Added `plugins.txt` to the `NOLINK` exclusion list alongside `AgentPack.md`. The manifest is consumed directly by `setup.sh` from `$DOTFILES_DIR/claude/plugins.txt` (see `setup.sh:376`) and is not meant to be symlinked into `~/.claude/`.

### Why
Auditor was reporting a spurious `MISSING plugins.txt (not present in ~/.claude/)` warning on every run since the plugin manifest landed in #2 — the file exists where it's used, the check was asking the wrong question.

## 2026-04-22 — Post-merge cleanup: PS injection, installer portability, README fixes

### What changed
- **`windows/cc-functions.ps1`** — Added `Test-SafeProjectName` helper (allow-list `^[A-Za-z0-9][A-Za-z0-9._-]*$`) and gated `Test-WslProject` on it. Closes shell-metachar interpolation into `bash -ic "cc $p"` — the project-name validator runs upstream of every `wsl.exe`/`wt.exe` call site.
- **`claude/systemd/install.sh`** — Wrapped the :8888 squatter scan in `command -v ss` so the installer warns and skips instead of silently falling through on minimal environments without `iproute2`.
- **`SECURITY_FINDINGS_20260419.md`** — Corrected stale refs: `setup.sh:361` → `:458`; `setup.sh:388–389` → `:485–486`; `hooks/ntfy-awaiting-input.sh` → `claude/hooks/ntfy-awaiting-input.sh` (both findings). Vulnerabilities unchanged; line numbers now match the current tree.
- **`README.md`** — Fixed displaced agents-list tree (16 agent files were rendering under `windows/cc-functions.ps1`) and replaced the bash→PowerShell bridge one-liner's `<you>` literal with auto-resolved `$(whoami)` + `${WSL_DISTRO_NAME:-Ubuntu}` env vars so it pastes verbatim.

### Why
Post-merge verification of 2026-04-21's four PRs surfaced real defects: stale doc refs that would waste triage time, a self-targeting injection vector in the new PS launchers, a `ss`-missing environment gap in the installer, and two README regressions. All fixed in one bundled PR to avoid splinter PRs.

## 2026-04-21 — PowerShell launchers: ccgrid / ccpane / cctab / ccprojects / ccupdate

### What changed
- **`windows/cc-functions.ps1`** — New PowerShell module defining five commands that mirror the bash `cc-pane` / `cc-tab` / `cc-multi` helpers. `ccgrid` opens a new Windows Terminal tab with N auto-tiled split panes, one per project, each running `cc <project>` inside WSL. `ccupdate` refreshes the local copy from the canonical WSL source after dotfiles pulls.
- **`README.md`** — New "From PowerShell (Windows-side)" subsection under Multi-session. Install snippet copies the file to a local Windows path and dot-sources *that*, because `RemoteSigned` (the recommended policy) blocks scripts loaded directly from `\\wsl.localhost\...` with a "not digitally signed" error. Documents env-var overrides (`CC_WSL_DISTRO`, `CC_DEV_DIR`) and gives a five-repo `ccgrid` example.

### Why
The existing bash helpers only work when you're already inside WSL. Running Claude from a native PowerShell prompt (common on Windows laptops) meant manually chaining `wt.exe split-pane wsl.exe ...` or opening panes one at a time. `ccgrid dotfiles atlas stringer beacon pai` now does five repos in one command.

### Verified
- `powershell.exe -ExecutionPolicy RemoteSigned` dot-sourcing the local copy registers all five functions.
- `ccupdate` resolves its own script path via `$MyInvocation.MyCommand.ScriptBlock.File` (since `$PSCommandPath` is empty inside dot-sourced function bodies), discovers the WSL source via `wsl.exe -- bash -c 'echo $USER'`, and copies successfully.

## 2026-04-21 — systemd installer clears stale :8888 squatters before restart

### What changed
- **`claude/systemd/install.sh`** — New "Clearing port 8888 before restart" step: stops the unit, scans `ss -lntp` for any remaining :8888 listener, and SIGTERM→SIGKILLs it. Runs `systemctl --user reset-failed` before the final restart so a prior crash-loop's rate-limit counter doesn't block the first good start.

### Why
On a fresh WSL/Linux laptop, a manually-launched `bun run ~/.claude/VoiceServer/server.ts` can be holding port 8888 when the installer runs. The systemd unit then crash-loops with `EADDRINUSE`, `bootstrap.sh --check` reports `DOWN`, and re-running `bootstrap.sh` doesn't help — nothing in the pipeline was killing the foreign process. The detection block is idempotent: when nothing is squatting the port, it's a silent no-op.

## 2026-04-20 — Document the `claude-memory` private repo contract

### What changed
- **`README.md`** — Replaced the thin "Persistent Memory" section with a full "The `claude-memory` private repo" section covering structure (pai-config, pai-user, dev/memory, bootstrap.sh), what setup.sh copies vs. what bootstrap.sh symlinks, and a minimal scaffold for anyone creating their own.
- **`setup.sh`** — When `claude-memory/pai-config` is missing, the message now points at the README section; when the memory repo is missing, the message distinguishes auto-memory-only vs. full PAI integration.

### Why
Prior docs only covered `dev/memory/` (Claude's native auto-memory). Anyone following them hit "pai-config not found" the instant they enabled PAI mode. The README now documents the contract explicitly so a fork can either fulfill it or know to use `--no-pai`.

## 2026-04-20 — PAI mode is now opt-in via prompt / flag

### What changed
- **`setup.sh`** — New prompt "Are you using (or planning to use) PAI? [Y/n]" runs near the top. Default is **Y** (current behavior preserved). Non-interactive override via `--no-pai` / `--pai` flags or `USE_PAI=0|1` env var.
- **Gated under `USE_PAI=1`:** the `claude-memory/pai-config` copy, the `claude-memory/pai-user` copy, and the final `bash claude-memory/bootstrap.sh` step.
- **Manual-steps footer** — non-PAI users are pointed at `claude` instead of `cc` (the `cc` wrapper assumes PAI).
- **`README.md`** — Quick Start documents the flags and the PAI/non-PAI distinction.

### Why
`setup.sh` previously assumed every user runs PAI and its private `claude-memory` repo. That's fine for my laptops but blocks anyone else from forking this repo for a Claude-Code-only setup. Making PAI opt-in costs 10 lines and unlocks the non-PAI path without changing the default experience.

## 2026-04-20 — Bun install-location agnosticism

### What changed
- **`setup.sh` §2b** — After bun is present (installed or found), always ensure a symlink at `~/.bun/bin/bun` pointing at the detected binary.
- **`claude/systemd/install.sh`** — Replaced the strict `[ -x ~/.bun/bin/bun ]` prerequisite with detect-and-symlink; fails only if bun is absent everywhere.

### Why
The systemd voice-server unit hardcodes `%h/.bun/bin/bun` (systemd can't do PATH lookups). Users installing bun via brew (`/opt/homebrew/bin/bun`), npm, or any non-curl path saw "bun not found at ~/.bun/bin/bun" even though `bun --version` worked. Canonicalizing via symlink keeps the unit file + every hardcoded path happy regardless of install method.

## 2026-04-20 — Setup.sh writes gh credential helper to `.gitconfig.local`

### What changed
- **`setup.sh` §6** — Replaced `gh auth setup-git` with direct `git config --file ~/.gitconfig.local` writes for `credential.https://github.com.helper` and `credential.https://gist.github.com.helper`. Uses `$(command -v gh)` for portability across macOS (`/opt/homebrew/bin/gh`) and Linux (`/usr/bin/gh`).
- **`claude/hooks/*.{sh,ts}` + `setup.sh`** — Restored executable bit (`0755`); they had been committed as `0644`, causing "Permission denied" at SessionStart.
- **`README.md`** — Added `bun` to the "What Gets Installed" table.

### Why
`gh auth setup-git` (added in the prior entry) writes to `~/.gitconfig` — which is symlinked to this repo's tracked `.gitconfig`. Running it on a new machine was mutating the shared dotfile with machine-specific helper paths and trying to commit them back. Writing to `.gitconfig.local` (gitignored, per-machine) keeps the shared `.gitconfig` clean while still giving every machine a working credential helper for github.com.

## 2026-04-20 — Setup.sh installs Bun for TypeScript hooks

### What changed
- **`setup.sh` §2b** — Installs Bun if missing (via `brew install oven-sh/bun/bun` on macOS when brew is present, otherwise the official `curl | bash` installer). Also PATH-prepends `~/.bun/bin` in the current script session when bun is found on disk but not on PATH yet.

### Why
`StripProjectPermissions.hook.ts` and any future `*.hook.ts` files use `#!/usr/bin/env bun` and fire at SessionStart. Missing bun causes `cc` to fail on first launch with a confusing "bun: not found" error.

## 2026-04-20 — Setup.sh wires `gh` as git credential helper

### What changed
- **`setup.sh` §6** — After detecting `gh auth status` is OK, now also runs `gh auth setup-git` (idempotent: skipped when `credential.https://github.com.helper` already points to `gh auth git-credential`).

### Why
On the fresh laptop, `cc` ran `pull-all` across many repos and each `git pull` prompted for a GitHub username/password — because `gh auth login` only authenticates the `gh` CLI, not git itself. `gh auth setup-git` registers gh as the per-host credential helper so every `git pull` uses the existing gh token with no prompt. Per-host wiring means non-github hosts still use the platform helper (osxkeychain / git-credential-manager.exe / store).

## 2026-04-20 — Setup.sh Claude auth gate

### What changed
- **`setup.sh` §3a** — New "Checking Claude Code authentication" step runs `claude auth status`, offers to launch `claude auth login` (browser OAuth) if unauthenticated. Only runs §3b plugin install when signed in (prevents the silent install failures we hit on the fresh laptop).
- **Setup footer** — Manual-steps list now includes `claude auth login` + "re-run setup.sh" when auth was skipped.

### Why
Fresh-machine setup installed the CLI and *tried* to install plugins before the user had run `claude auth login`. Plugin installs swallowed errors, then `cc` failed because `claude --remote-control` needs a valid token. The gate makes the dependency explicit and recoverable in-place.

## 2026-04-17 — Plugin auto-install on setup + `cc --resume` fast path

### What changed
- **`claude/plugins.txt`** — New manifest listing 18 Claude Code plugins (format: `plugin@marketplace`). Source of truth for fresh-machine plugin installation.
- **`setup.sh`** — Added §3b "Claude Code plugins" step: registers each referenced marketplace (`claude-plugins-official`, `anthropic-agent-skills`) if missing, then installs each manifest plugin that isn't already present. Fully idempotent — safe to re-run.
- **`.bash_aliases` `cc()`** — Detects `--resume` / `-r` / `--continue` / `-c` anywhere in args. Resume path skips the heavy sync (pull-all, sync-memory, sync-pai-config, check-claude.sh) and never cds away from the current directory. Flag passes through to `claude` unchanged.

### Why
Setting up a new laptop next week — plugin list was manual. Resume was slow because every invocation did a full repo + memory sync even when the user just wanted to pick up where they left off.

## 2026-04-16 — PAI upgrade integration (Algorithm gates + env cleanup)

### What changed
- **`.bash_aliases`** — Removed `CLAUDE_CODE_NO_FLICKER=0` workaround (v2.1.110 `/tui fullscreen` replaces it); added `ENABLE_PROMPT_CACHING_1H=1` (v2.1.108+, extends prompt cache TTL 5m→1h for long Algorithm sessions).
- **Algorithm v3.7.0 PLAN phase** — Added **File Ownership Gate** (mandatory when 2+ parallel agents selected): produce File Ownership Map in PRD Decisions, no two agents write to the same file. Fixes the #1 reflection failure mode (15+ occurrences of shared-file stomping).
- **Algorithm v3.7.0 PLAN phase** — Added **Worktree Agent Pre-Commit Footer**: formatter + typechecker + linter required before worktree commits. Fixes 6 reflections of unformatted-commit merge failures.
- **Algorithm v3.7.0 VERIFY phase** — Added **Capability-Obligation Enforcement**: selected capabilities must be invoked or explicitly dropped with logged reason (`/simplify` was silently skipped 8 times).
- **Algorithm v3.7.0 VERIFY phase** — Added **Claim-Verification Gate**: when 2+ sub-agents used, independently spot-verify 2-3 concrete claims per agent (fixes 5 reflections of hallucinated SHA/line-ref findings creating false blockers).
- **Algorithm v3.7.0 OBSERVE phase** — Added **Prescribed-Task Fast-Path**: skip THINK/PLAN for fully-specified tasks ≤3 files.
- **Algorithm v3.7.0 OBSERVE phase** — Added **Browser Smoke Check** as first context-recovery action for UI/frontend tasks (fixes 5 reflections of CSP/render bugs missed by code-only analysis).
- **Memory cleanup** — Removed `project_no_flicker_workaround.md` (condition met; workaround retired).

### Audits (no changes required)
- **Hooks audit** — Zero uses of `updatedInput` or `additionalContext` in `~/.claude/hooks/`. PAI hooks not affected by v2.1.110 bug fixes.
- **`--enable-auto-mode` flag** — Only appears in old session logs, not in any active PAI code. Nothing to clean up.
- **SKILL.md front-matter** — All 59 SKILL.md files have required `name` + `description` (spec-compliant on mandatory fields). Follow-ups flagged: no skills use `allowed-tools:` (future permission-prompt reduction opportunity); `Utilities/SKILL.md` description is 2020 chars (spec max 1024) — needs dedicated refactor.

### Source
Three-thread PAI upgrade scan: user context (Thread 1) + Anthropic ecosystem sources (Thread 2, 15 techniques from v2.1.108–2.1.112 + Agent Skills spec + MCP 2025-11-25) + internal reflection mining (Thread 3, 90 entries over 13 days, 6 upgrade candidates).

## 2026-04-16 — Fix permission prompts and update documentation

### What changed
- **StripProjectPermissions hook** — New SessionStart hook auto-strips `permissions` blocks from project-level `settings.local.json` that override global blanket permissions. Root cause of recurring permission prompts.
- **Removed redundant permissions** — Dropped `Write(~/.claude/**)` and `Edit(~/.claude/**)` from settings.json allow list (already covered by blanket `Write`/`Edit`).
- **setup.sh --check / --repair** — New flags for symlink health audits across both dotfiles and claude-memory repos. Normal setup.sh now also calls bootstrap.sh.
- **cc alias health check** — `_check_critical_symlinks()` validates settings.json and CLAUDE.md symlinks before every launch, auto-repairs if broken.
- **Handoff read-before-write** — Skill now reads existing handoff file before writing to avoid Claude Code's overwrite confirmation prompt.
- **setup.sh deploys .ts hooks** — Hook symlink loop now includes `*.ts` files, not just `*.sh`.
- **Documentation updated** — README and CLAUDE-GUIDE hook tables corrected (removed references to deleted block-dangerous.sh/block-secrets.sh, added new hooks). Added decompose and max skills to repo tree.
- **Standing orders in CLAUDE.md** — Added top-of-file "ACT, NEVER ASK" section to prevent model from asking permission for standing-order operations.

## 2026-04-15 — Fix statusline CWD parsing and tab colors

### What changed
- **Fixed statusline repo/branch display** — `IFS=$'\t' read` collapsed empty JSON fields, causing CWD to land in wrong variable. Switched to `readarray` with one-field-per-line jq output.
- **Fixed printf %b escape collision** — OSC 8 link backslashes + repo names like "clarity-engine" triggered `\c` stop-output. Switched to raw ESC bytes + `printf '%s'`.
- **Added `.claude-color` files** — clarity-engine (cyan), dotfiles (violet) for tab and statusline coloring.
- **Cleanup** — removed duplicate cache-read dead code, replaced `date` subprocess with printf builtin, fixed misleading comment.

## 2026-03-22 (session 7 — PAI migration kickoff)

### What changed
- **Forked PAI** — forked `danielmiessler/Personal_AI_Infrastructure` to `jckeen/Personal_AI_Infrastructure` as the next-gen dotfiles platform. Cloned to `~/dev/pai`
- **Created USER tier files** in the PAI fork:
  - `PAI/USER/ABOUTME.md` — role, expertise, current projects, working style
  - `PAI/USER/DAIDENTITY.md` — personality traits (directness 90, precision 85, curiosity 70), peer-to-peer relationship model
  - `PAI/USER/AISTEERINGRULES.md` — all behavioral rules migrated from this repo's `CLAUDE.md`
  - `PAI/USER/AGENTPACK.md` — 16-agent review orchestra with 3-phase workflow
- **PAI-MIGRATION-HANDOFF.md** — comprehensive handoff documenting what migrates, what gets replaced, what stays

### Decisions made
- Fork PAI (not submodule, not cherry-pick) — `~/.claude/` IS the repo
- Port bash hooks to TypeScript for consistency with PAI's Bun runtime
- Install all 12 PAI packs (full suite)
- Set up ElevenLabs voice server
- Track upstream PAI via `git remote add upstream`
- This dotfiles repo becomes a thin bootstrap layer (setup.sh, .gitconfig, .bash_aliases)

### Next sessions
- Session 2: Port hooks to TypeScript, create security patterns.yaml
- Session 3: Migrate skills, agents, autonomous scripts, status line
- Session 4: Merge settings.json, install packs
- Session 5: Voice server, rewrite setup.sh
- Session 6: End-to-end verification

## 2026-03-20 (session 6 — WSL Linux filesystem migration)

### What changed
- **Single source of truth for dev dir** — `setup.sh` now writes `~/.claude/dev-dir` with the resolved path (derived from dotfiles repo location). All scripts (`.bash_aliases`, `overnight.sh`, `check-claude.sh`) read from this file instead of each independently guessing via platform detection. Moving the dev folder just requires re-running `setup.sh`
  - `setup.sh`: derives `DEV_DIR` from repo location, writes `~/.claude/dev-dir`, uses actual paths for safe.directory
  - `check-claude.sh`: derives `DEV_DIR` from repo location
  - `.bash_aliases` `_dev_dir()`: reads `~/.claude/dev-dir`, falls back to `~/dev`
  - `overnight.sh` `discover_dev_dir()`: reads `~/.claude/dev-dir` (env var override still works), removed WSL platform detection

## 2026-03-19 (session 5 — ccforeveryone.com gap analysis)

### What changed
- **Stop hook template in CLAUDE-GUIDE.md** — added `Stop` hook pattern for auto-QA (typecheck/lint/test after each Claude response). Template goes in project-level `.claude/settings.local.json`, not global
- **Architecture diagram preloading in `cc()`** — if `.ai/diagrams/*.md` exists in the current directory, diagrams are appended to Claude's system prompt via `--append-system-prompt`. Opt-in per project, no change to behavior when diagrams don't exist
- **CLAUDE.local.md documented** — added brief section to CLAUDE-GUIDE.md explaining the gitignored personal preferences file
- **Stop hooks deployed to 5 active projects** — covering pytest, eslint, typecheck+lint, next build, and jest stacks. All via `.claude/settings.local.json` (gitignored)
- **Architecture diagrams added to two projects** — Mermaid diagrams for data flow / dependency / service boundaries on a Python pipeline, and service-architecture / state-machine / ER diagrams on a Next.js service.
- **block-secrets.sh regex fix** — `git add .ai/...` was falsely matching the `git add .` blocker. Fixed to only match `.` as the full argument
- **Cleaned stale SMSS permissions** — removed old one-off `Bash(...)` permission entries from early sessions

- **Security hardening for public repo** (full audit):
  - `statusline.sh`: replaced `eval` on jq output with safe tab-delimited `read`; moved cache from `/tmp` (world-writable) to `$XDG_RUNTIME_DIR` or `~/.cache`; replaced `source` cache loading with `IFS read`
  - `setup.sh`: removed `curl | sudo bash` for Node.js (now prompts user to install manually); added confirmation before all `sudo` operations; only installs missing packages; made WSL audio setup opt-in
  - Removed hardcoded `jckeen` references from setup.sh and scripts/README.md

### Decisions made
- `Bash(*)` in settings.json stays — it's intentional for the power-user workflow, and the deny list + hooks provide guardrails. Users who want tighter permissions can override in their project settings
- `--full-auto` / `FULL_AUTO=true` stays documented — it's clearly marked as opt-in with warning banners, and the tiered permission system is the default

### Source
- Gap analysis of ccforeveryone.com (Claude Code for Everyone by Carl Vellotti) against our dotfiles setup
- Security review of full repo for public consumption

## 2026-03-18 (session 4 — cleanup and fixes)

### What changed
- **Deleted `sync-claude.sh`** — 92 lines of dead code; `setup.sh` uses symlinks exclusively, making the copy-based sync obsolete
- **`check-claude.sh` now checks scripts/** — added loop that verifies `claude/scripts/*.sh` symlinks alongside hooks, agents, and skills
- **`review-and-push.sh` uses `run_claude()`** — replaced bare `claude -p` call with `run_claude "TIER_READONLY"`, gaining the honesty guardrail, `--full-auto` support, and consistent logging from `common.sh`
- **`overnight.sh` WSL detection** — `discover_dev_dir()` now auto-detects WSL and resolves to `/mnt/c/Users/<user>/dev` using the same `/proc/version` + `cmd.exe` pattern as `.bash_aliases`'s `_dev_dir()`
- **`CLAUDE-GUIDE.md` expanded** — added Shell Commands table, Safety Hooks table (4 hooks with triggers), and Autonomous Scripts table (6 scripts with examples)
- **`README.md` cleaned** — removed `sync-claude.sh` from repo tree listing

## 2026-03-18 (session 3 — full sweep)

### What changed
- **Removed handoffs/ from repo** — `git rm`'d session-specific handoff files, added `claude/handoffs/` to `.gitignore`. Handoffs are ephemeral and potentially sensitive; they shouldn't live in a public dotfiles repo
- **safe.directory for claude-memory** — setup.sh WSL section now auto-adds the claude-memory repo to git safe.directory alongside dotfiles
- **Scripts deployment** — setup.sh now symlinks `claude/scripts/*.sh` into `~/.claude/scripts/`, and `.bash_aliases` adds that directory to PATH. Headless scripts (health-check.sh, overnight.sh, etc.) are now callable directly
- **`dotfiles-update` function** — new shell function in `.bash_aliases`: pulls latest dotfiles repo, re-runs setup.sh. One command to get up to date
- **Secret-detection hook** (`block-secrets.sh`) — PreToolUse hook that blocks staging known secret files (.env, credentials.json, private keys, etc.) and catches `git add -A` / `git add .` to prevent accidental secret sweep-ins. Also scans commit messages for inline API keys
- **Conventional commit hook** (`conventional-commit.sh`) — PreToolUse hook that validates commit messages match `type: description` format (feat, fix, refactor, chore, docs, test, style). Handles both heredoc and inline -m styles
- **Agent evaluation** — reviewed all 5 "thin" agents (content-reviewer, ux-reviewer, product-strategist, growth-strategist, trust-safety) against built-in subagent_type equivalents. All 5 kept — they add structured output formats, grounding rules ("only report issues with file/line references"), and domain-specific checklists that the built-ins lack

### Decisions made
- All 16 agents stay — no redundancy with built-in subagent_types
- Handoffs belong in gitignore, not the repo — they're session-specific and may contain sensitive context
- Scripts deployed via PATH rather than individual aliases — cleaner and auto-discovers new scripts
- `git add -A` / `git add .` blocked by hook — enforces staging specific files, which prevents accidental secret commits

## 2026-03-18 (session 2 — continued)

### What changed (latest)
- **Private `claude-memory` repo** — memory files moved to `github.com/jckeen/claude-memory` (private), symlinked into `~/.claude/projects/`. Keeps dotfiles public while memory stays private and survives machine rebuilds
- **setup.sh wires memory automatically** — detects dev directory, creates symlink, preserves existing files if migrating
- **check-claude.sh verifies memory** — checks symlink health, catches broken/missing links
- **CLAUDE.md changelog rule tightened** — changed from "at end of session" to "after every 1-2 commits" to prevent drift
- **`cc` auto-syncs memory** — commits and pushes pending memory changes from the last session before launching Claude. New `sync-memory` function in `.bash_aliases`
- **README documents memory setup** — step-by-step instructions for creating a private `claude-memory` repo, explains why it's separate from dotfiles
- **Full doc audit fixes** — agent counts corrected to 16 everywhere, CLAUDE-GUIDE.md now lists `cc` as recommended start command, `.bash_aliases` paths use `_dev_dir()` instead of hardcoded `~/dev/dotfiles`, `sync-claude.sh` respects NOLINK list, README line threshold aligned to 400, handoffs directory added to repo tree

### What changed (earlier)
- **Removed AgentPackJCK.md** — old project-specific agent pack from shitmyspousesays.com, superseded by the generic agent pack
- **Removed stale `.claude/` directory** from dotfiles repo — contained old flat-format skills and empty handoffs, all superseded by `claude/` directory
- **Added `check-claude.sh`** — health check script that verifies config symlinks, detects orphans (symlinks whose dotfiles source was removed), finds stale backups, and supports `--fix` for auto-cleanup. Runs as part of `cc` command before launching Claude
- **AgentPack.md now on-demand** — no longer symlinked into `~/.claude/` (saves context tokens every session). CLAUDE.md tells Claude where to find it when needed for multi-agent reviews
- **CLAUDE.md trimmed from 119 to 89 lines** — removed "Available Skills" and "Available Subagents" listings (Claude already discovers these from installed files)
- **setup.sh auto-discovers files** — no longer hardcodes which top-level files to link. Uses `NOLINK` list for intentional exceptions (like AgentPack.md)
- **check-claude.sh safety** — orphan detection only touches symlinks pointing into the dotfiles repo. Backup cleanup only removes `.backup` files where the original is already a working symlink
- **Cleaned up 9 stale `.backup` files** across `~/.claude/`

### Decisions made
- Dotfiles repo is the right pattern but needed pruning — keep what's custom, lean on built-in platform features for the rest
- Custom skills (all 9) are worth keeping — they add workflow guardrails the official plugins intentionally omit
- Custom agent MD files kept for now — the 4 without built-in equivalents (repo-scout, test-writer, schema-reviewer, dependency-doctor) are clearly needed; the others add output format templates that improve quality
- `full-review.sh` needs real-world testing — may not reliably spawn 12 subagents in headless mode

## 2026-03-18

### What changed
- **4 new agents** — `repo-scout` (fast codebase orientation), `dependency-doctor` (dep audits, CVEs), `test-writer` (bug reproduction, coverage), `schema-reviewer` (DB schema/migration safety). Agent Pack now at 16 agents
- **Autonomous scripts** (`claude/scripts/`) — headless Claude Code runners with tiered permissions:
  - `health-check.sh` — read-only repo briefing + dependency audit
  - `test-coverage.sh` — write tests for uncovered code
  - `full-review.sh` — full 3-phase agent pack review
  - `fix-issues.sh` — pick up GitHub issues and fix them
  - `overnight.sh` — orchestrate all scripts across multiple repos
  - `review-and-push.sh` — AI reviews overnight changes, pushes only after tests pass + review clears
- **5 safety tiers** — READONLY, LINT, FIX, COMMIT, PUSH via `--allowedTools` scoping. No script pushes by default. `--full-auto` flag available as opt-in for `--dangerously-skip-permissions`
- **Honesty guardrails** — all review agents and the script prompt wrapper now instruct Claude not to hallucinate findings. "A clean report is a valid outcome"
- **Auto-detect repos** — `overnight.sh` discovers repos via `CLAUDE_REPOS` env var, `~/.claude/repos` config file, or auto-scanning the dev directory. Works on macOS, Linux, and WSL without editing scripts
- **Full documentation** in `claude/scripts/README.md` — prerequisites, all flags, env vars, cron scheduling, morning workflow, setup guide for dotfiles users

### Decisions made
- Opus 4.6 everywhere — accuracy over cost savings
- `--allowedTools` scoping over `--dangerously-skip-permissions` as default
- Nothing pushes automatically — review-and-push.sh is the gatekeeper
- Deferred: cross-repo-tracker, incident-responder, api-documenter (not needed yet)

## 2026-03-17

### What changed
- **CLAUDE.md overhaul** — Rewrote global instructions based on Boris Cherny's tips and official Claude Code best practices. Added: context hygiene as top priority, verification rules (always test before shipping), interview pattern for vague prompts, CLAUDE.md maintenance rules (under 200 lines, prune ruthlessly), subagent-for-review pattern
- **New PostToolUse hook: `format-on-edit.sh`** — Auto-formats files after Claude edits them using the project's formatter (prettier, black, rustfmt, gofmt). This is what the Claude Code team uses internally — handles the last 10% of formatting
- **New subagents** — Added `security-reviewer` (reviews code for injection, auth flaws, secrets, insecure data handling) and `code-simplifier` (finds and removes unnecessary complexity, premature abstractions, dead code)
- **New skills** — Added `/fix-issue` (pick up a GitHub issue end-to-end: investigate → plan → test → implement → PR) and `/simplify` (delegates to code-simplifier subagent, applies safe changes automatically)
- **README rewritten as best practices guide** — Comprehensive Claude Code mastery guide sourced from Boris Cherny (creator), official docs, and experience. Covers: context management, Plan Mode, verification, prompting patterns, parallelization, CLAUDE.md as compounding engineering, hooks vs CLAUDE.md, anti-patterns to avoid
- **CLAUDE-GUIDE.md condensed to quick reference** — Cheat sheet format instead of duplicating the README
- **settings.json updated** — Added PostToolUse hook for formatting, set `preferredModel: "opus"` (Boris's recommendation: Opus requires less steering and is faster in practice)
- **setup.sh updated** — Now deploys agents directory and hooks with proper permissions, handles directory-based skill format correctly
- **sync-claude.sh updated** — Now syncs agents directory with add/remove tracking

### Decisions made
- Hooks for enforcement, CLAUDE.md for guidance — anything that MUST happen every time goes in a hook, not CLAUDE.md
- Opus as default model — per Boris Cherny: "you steer it less and it's better at tool use, so it's almost always faster"
- Subagents for investigation and review — protects main context from file-read bloat
- README is the single source of truth for best practices — CLAUDE-GUIDE.md is just a quick reference card
- Verification is non-negotiable — baked into CLAUDE.md as a top-level rule

### Follow-up additions
- Added `/commit-push-pr` skill — Boris's most-used daily command. Commits, pushes, and creates a PR in one shot
- Added self-improvement loop rule to CLAUDE.md — "Every time you make a mistake, suggest adding a rule to prevent it"
- Added voice dictation and "let Claude handle git" tips to README
- Updated CLAUDE-GUIDE.md quick reference with new commands

### Sources
- Boris Cherny (creator of Claude Code): https://howborisusesclaudecode.com
- Official best practices: https://code.claude.com/docs/en/best-practices
- Boris's Threads posts on parallelization, Plan Mode, hooks, and subagents
- Boris on Lenny's Podcast: https://www.lennysnewsletter.com/p/head-of-claude-code-what-happens
- Boris on The Pragmatic Engineer: https://newsletter.pragmaticengineer.com/p/building-claude-code-with-boris-cherny
- Trail of Bits claude-code-config for security patterns

## 2026-03-16

### What changed
- Fixed Claude Code `/voice` in WSL2: added `libasound2-plugins` to setup.sh, created `.asoundrc` that routes ALSA through PulseAudio/WSLg, and setup.sh now deploys it to both `~/.asoundrc` (symlink) and `/etc/asound.conf` (copy)
- Root cause: WSL has no direct hardware audio — ALSA needs to be told to route through WSLg's PulseAudio server

### Manual steps after setup.sh
- Ensure Windows microphone permissions are enabled (Settings > Privacy & Security > Microphone)
- Verify with: `arecord -D default -f cd -d 3 /tmp/test.wav && aplay /tmp/test.wav`
- Relaunch Claude Code, then `/voice` should work

## 2026-03-15

### What changed
- Added `pulseaudio-utils` to setup.sh for Claude Code voice mode in WSL

## 2026-03-14

### What changed
- Enabled always-on remote control (`enableRemoteControl: true` in settings.json)
- Added shell aliases: `claude-server` (spawn worktree + remote) and `claude-rc` (remote control current session)
- Sessions are now accessible from `claude.ai/code` and Claude mobile app — no more TMUX dependency

### Decisions made
- Remote control replaces tmux as the primary way to persist and access Claude sessions
- Shell aliases in `.bash_aliases` deployed via symlink in setup.sh

## 2026-03-12

### What changed
- Made Agent Pack generic — no longer tied to SMSS project
- Added Claude Code starter guide (`CLAUDE-GUIDE.md`)
- Added tmux config with mouse support
- Created 4 skills: `/kickoff`, `/changelog`, `/log-error`, `/review`
- Added session workflow and context hygiene rules to global CLAUDE.md
- Expanded `setup.sh` into full WSL bootstrap (installs tmux, gh, node, claude, configures git credential helper)
- Switched setup.sh to symlinks instead of copies (keeps dotfiles and live config in sync)

### Decisions made
- Global CLAUDE.md owns workflow rules; project CLAUDE.md owns project-specific context only
- Agent Pack stays generic — project-specific priorities go in each project's CLAUDE.md
- Skills live in dotfiles and deploy to `~/.claude/skills/`

## 2026-03-11

### What changed
- Initial dotfiles setup: `.gitconfig`, Claude settings, CLAUDE.md
- Added Agent Pack (originally SMSS-specific)

### Decisions made
- Dotfiles repo as single source of truth for dev environment config
- Claude Code config managed via dotfiles, not manually
