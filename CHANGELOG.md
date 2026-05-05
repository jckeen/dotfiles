# Changelog

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

## [Unreleased]

### 2026-05-03 — ADR cross-references: stringer #64 added

- **`ADR/AUTH-AT-THE-BOUNDARY.md`** — Added `stringer` row to the cross-reference table linking [#64](https://github.com/jckeen/stringer/pull/64) (256-bit CSPRNG OAuth state nonce + `crypto.timingSafeEqual` validation + `SEED_USER_PASSWORD` env-required). Five rows are now landed (`parlance`, `impact-dash`, `pp2qbo`, `smss`, `stringer`); `<TBD>` remains for `atlas`, `beacon`, `clarity-engine`, `pai-voice-server`. Annotated that `atlas` #5 (CWE-209/532) and `beacon` #17 (security headers + rate limiting) are adjacent hardening but don't add the auth-at-boundary property this ADR codifies.

### 2026-05-03 — ADR cross-references backfilled

- **`ADR/AUTH-AT-THE-BOUNDARY.md`** — Backfilled the per-repo cross-reference table with the four landed auth fixes from the 2026-05-03 multi-repo campaign: `parlance` #18 + #19, `impact-dash` #21, `pp2qbo` #19, `smss` #18. Honest `<TBD>` retained for `stringer`, `atlas`, `beacon`, `clarity-engine`, and `pai-voice-server` — these need CWE-306 follow-ups before claiming ADR conformance. Placeholder note rewritten to reflect that the parallel work concluded with partial coverage.

### 2026-05-03 — ADR: Auth at the Boundary

- **`ADR/AUTH-AT-THE-BOUNDARY.md`** — New cross-repo Architecture Decision Record codifying auth-by-default at the entry boundary as the standing rule for all jckeen-owned services. Captures the principle behind a CWE-306 (Missing Authentication) finding pattern that hit 6 repos across 4 unrelated stacks (Fastify TS, FastAPI, Next.js + Better-Auth, Next.js + jose, Next.js bearer, Python Unix-socket IPC) in the same audit week. Includes drop-in code snippets per stack, six anti-patterns with wrong/right diffs, per-framework checklists, and placeholders for the per-repo fix PRs (linked once those PRs land).
- **`README.md`** — New top-level `## ADRs` section linking the new doc.

### Why
The 6 findings shared no code — they shared an assumption ("auth is handled somewhere upstream") that's not enforceable through code review alone. The ADR makes auth-by-default the framework wiring, not the reviewer's job, and gives every stack a copy-paste pattern that fails closed by construction.

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
- **Stop hooks deployed to all 5 projects** — atlas (pytest), smss (eslint), pp2qbo (typecheck+lint), stringer (next build), TRNN (jest). All via `.claude/settings.local.json` (gitignored)
- **Architecture diagrams for pp2qbo** — 3 Mermaid diagrams: data flow pipeline, package dependency graph, service boundaries
- **Architecture diagrams for stringer** — 3 Mermaid diagrams: service architecture, assignment lifecycle state machine, core data model ER diagram
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
