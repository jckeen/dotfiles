# PAI Decommission Plan

**Status:** DRAFT — nothing executed yet. Review/edit before running any phase.
**Date:** 2026-06-03
**Goal:** Remove the PAI system from this machine and from the dotfiles +
claude-memory repos, while keeping (a) your own 12 skills, (b) the atlas skills,
(c) the `claude-memory` cross-machine sync repo, and (d) all genuinely portable
personal knowledge.

---

## 1. Where PAI lives (full footprint)

PAI is spread across **3 repos + live `~/.claude` + 2 systemd units + a running daemon + a config dir**.

| Location | What it is | Verdict |
|---|---|---|
| `~/.claude/PAI/` (386 MB) | PAI engine: ALGORITHM, PAI_SYSTEM_PROMPT, TOOLS, PULSE, DOCUMENTATION, PAI-Install, MEMORY | DELETE (after salvage) |
| `~/.claude/skills/` — 44 PAI skills | Agents, Research, ISA, RedTeam, Council, Telos, FirstPrinciples, IterativeDepth, Webdesign, … | DELETE |
| `~/.claude/skills/` — your 12 | branch-hygiene, changelog, claude-server, commit-push-pr, decompose, fix-issue, handoff, kickoff, log-error, max, review, simplify (symlinked from dotfiles) | KEEP |
| `~/.claude/skills/` — 5 atlas | atlas-brief*, atlas-learn, atlas-meeting-prep, atlas-missed (symlinked from ~/dev/atlas) | KEEP |
| `~/.claude/` misc | `ISA.md`, `settings.plain.json` (PAI_DIR env + refs), `.env → ~/.config/PAI/.env`, `MEMORY/`, `teams/`, `agents/`, `commands/` | CLEAN / DELETE |
| `~/dev/claude-memory/` (private, GitHub-backed) | `pai-config/` (PAI CLAUDE.md + settings + hooks), `pai-user/`, `dev/memory/`, `stringer/`, `trnn/`, `bootstrap.sh` | KEEP repo, strip PAI layer |
| `~/dev/dotfiles/` | `pai-mode.sh`, `claude/PAI/`, `claude/plain/`, PAI logic in `setup.sh`, `pai-*` aliases + `sync-pai-config` in `.bash_aliases`, `claude/systemd/pai-voice-server.service` | STRIP PAI |
| systemd `--user` | `pai-pulse.service` (enabled + RUNNING), `pai-voice-server.service` (enabled). `git-hygiene.timer` and `atlas-*` are NOT PAI. | DISABLE pai-* only |
| Running process | `bun run ~/.claude/PAI/PULSE/pulse.ts` (PID 326, up since May 27) | STOP |
| `~/.config/PAI/` | `.env` (ELEVENLABS key etc.), `PAI-Install/` | KEEP `.env` decision; DELETE PAI-Install |

> Note: "plain mode" (PAI currently OFF via `pai-mode.sh off`) only repoints
> `CLAUDE.md` and strips PAI hooks from settings. It does NOT remove skills, the
> engine, the daemon, or systemd units — they are all still present/active.

---

## 2. What to KEEP (portable knowledge)

**Already safe — curated and on GitHub in `claude-memory`:**
- `pai-user/` — identity, `AISTEERINGRULES.md` (151 lines), `ABOUTME.md`, `PROJECTS/`, `TELOS/`
- `dev/memory/` — `MEMORY.md` (18 KB) + ~dozens of `feedback_*.md` distilled learnings (the canon)
- `stringer/`, `trnn/` — per-project memory

**Not backed up anywhere — RESCUE before deleting** (~50 KB, in `~/.claude/PAI/USER/`):
`OUR_STORY, TECHSTACKPREFERENCES, WRITINGSTYLE, RHETORICALSTYLE, AI_WRITING_PATTERNS,`
`OPINIONS, RESUME, CONTACTS, ALGOPREFS, BASICINFO, DEFINITIONS, CORECONTENT, FEED,`
`TELOS/{WISDOM, NARRATIVES, BOOKS, BELIEFS}` (each 75–200 words, lightly populated).

**From the auto-logs — 3 files worth extracting** (assessed; everything else is disposable):
1. `PAI/MEMORY/LEARNING/REFLECTIONS/algorithm-reflections.jsonl` (165 KB) — structured post-session reflections, not in the canon.
2. `PAI/MEMORY/KNOWLEDGE/Ideas/github-solo-owner-admin-merge-limit.md` — real gotcha (`gh pr merge --admin` does not bypass code-owner reviews).
3. `PAI/MEMORY/KNOWLEDGE/Research/agent-stall-investigation.md` (18 KB) — research-grade Forge/codex context-starvation investigation.

**Disposable auto-logs (verified):**
- `LEARNING/FAILURES/` (492 files, 65 MB) — raw session transcripts/forensics.
- `LEARNING/ALGORITHM/` (134) + `LEARNING/SYSTEM/` (57) + `LEARNING/SIGNALS/ratings.jsonl` — sentiment telemetry; distilled version already in canon.
- `PAI/MEMORY/WORK/` (138) + `~/.claude/MEMORY/WORK/` (52) — session ISA stage-tracking stubs; deliverables live in real repos.
- `~/.claude/MEMORY/LEARNING/` (`denied-tools.jsonl`), `RELATIONSHIP/` daily-brief logs, empty `WISDOM/`/`RESEARCH/` READMEs.

---

## 3. Phased execution

### Phase 0 — Rescue (no deletions)
```bash
# 3 salvaged auto-log files into the backed-up repo
cp ~/.claude/PAI/MEMORY/LEARNING/REFLECTIONS/algorithm-reflections.jsonl \
   ~/dev/claude-memory/dev/PAI_algorithm_reflections.jsonl
cp ~/.claude/PAI/MEMORY/KNOWLEDGE/Ideas/github-solo-owner-admin-merge-limit.md \
   ~/dev/claude-memory/dev/memory/gotcha_github_solo_owner_admin_merge.md
cp ~/.claude/PAI/MEMORY/KNOWLEDGE/Research/agent-stall-investigation.md \
   ~/dev/claude-memory/dev/memory/research_forge_context_starvation.md

# Unsynced USER content (only the real files, not the symlinks back to pai-user)
mkdir -p ~/dev/claude-memory/pai-user/USER-ARCHIVE
for f in OUR_STORY TECHSTACKPREFERENCES WRITINGSTYLE RHETORICALSTYLE AI_WRITING_PATTERNS \
         OPINIONS RESUME CONTACTS ALGOPREFS BASICINFO DEFINITIONS CORECONTENT FEED; do
  [ -f ~/.claude/PAI/USER/$f.md ] && [ ! -L ~/.claude/PAI/USER/$f.md ] && \
    cp ~/.claude/PAI/USER/$f.md ~/dev/claude-memory/pai-user/USER-ARCHIVE/
done
mkdir -p ~/dev/claude-memory/pai-user/USER-ARCHIVE/TELOS
for f in WISDOM NARRATIVES BOOKS BELIEFS; do
  [ -f ~/.claude/PAI/USER/TELOS/$f.md ] && [ ! -L ~/.claude/PAI/USER/TELOS/$f.md ] && \
    cp ~/.claude/PAI/USER/TELOS/$f.md ~/dev/claude-memory/pai-user/USER-ARCHIVE/TELOS/
done

cd ~/dev/claude-memory && git add -A && git commit -m "archive: salvage PAI USER content + 3 auto-log files before decommission"
# (push when ready)
```
**Verify:** confirm the files landed and the commit exists before proceeding.

### Phase 1 — Stop the live system (reversible)
```bash
systemctl --user disable --now pai-pulse.service
systemctl --user disable --now pai-voice-server.service
systemctl --user daemon-reload
# confirm the daemon is gone (PID 326):
ps aux | grep -E "pulse.ts|voice-server" | grep -v grep || echo "stopped"
```
Leave `git-hygiene.timer` and `atlas-*` units alone — not PAI.

### Phase 2 — Migrate keep-content into the plain setup
- Fold the worth-keeping behavioral content into the plain global CLAUDE.md
  (`~/dev/dotfiles/claude/plain/CLAUDE.md`): the useful parts of
  `AISTEERINGRULES.md`, `ABOUTME.md`, `TECHSTACKPREFERENCES.md`. Decide how much
  you actually want loaded every session (lean is the point of plain mode).
- Decide native-memory home: the Claude Code memory system is the canonical
  replacement for PAI's MEMORY/. The `feedback_*.md` canon can stay in
  `claude-memory/dev/memory/` and be referenced, or be migrated.

### Phase 3 — Remove the PAI skills (keep yours + atlas)
```bash
# the 44 PAI skill dirs (NOT the 12 personal symlinks, NOT the 5 atlas symlinks)
cd ~/.claude/skills
for s in Agents ApertureOscillation Aphorisms Apify ArXiv Art AudioEditor BeCreative \
  BitterPillEngineering BrightData Browser ContextSearch Council CreateCLI CreateSkill \
  Daemon Delegation Evals ExtractWisdom Fabric FirstPrinciples ISA Ideate Interceptor \
  Interview IterativeDepth Knowledge Loop Migrate Optimize PAIUpgrade PrivateInvestigator \
  Prompting RedTeam Remotion Research RootCauseAnalysis Sales Science SystemsThinking \
  Telos USMetrics Webdesign WorldThreatModel WriteStory; do
  rm -rf "./$s"
done
# CLAUDE.md in skills/ is a PAI skills-readme; remove if PAI-specific.
```
**Verify:** `ls ~/.claude/skills` shows only your 12 + 5 atlas symlinks.

### Phase 4 — Delete the engine + live PAI data
```bash
rm -rf ~/.claude/PAI
rm -rf ~/.config/PAI/PAI-Install
rm -rf ~/.claude/MEMORY        # PAI working memory (canon is in claude-memory)
rm -f  ~/.claude/ISA.md
# settings.plain.json: strip PAI_DIR / PAI_CONFIG_DIR env and PAI _docs blocks.
# .env symlink → ~/.config/PAI/.env: keep if other tools use the key; else remove.
```

### Phase 5 — Clean the repos
**dotfiles:**
- `rm pai-mode.sh`
- `rm -rf claude/PAI`
- `rm -rf claude/plain` (after its keep-content is merged into your global CLAUDE.md elsewhere)
- `rm claude/systemd/pai-voice-server.service`
- Edit `setup.sh`: remove the PAI integration (claude-memory copy + bootstrap, `--pai`/`--no-pai`, `pai_plain_active`, claude-memory symlink audit, `pai-mode.sh` from the bin loop).
- Edit `.bash_aliases`: remove `pai-off`/`pai-on`/`pai-status` aliases and the `sync-pai-config` function (and its callers).
- Update `README.md`, `CLAUDE-GUIDE.md`, `CHANGELOG.md` to drop PAI sections.

**claude-memory:**
- `rm -rf pai-config` (PAI CLAUDE.md + hooks). NOTE: `pai-config/settings.json`
  also holds your MCP servers + permissions — extract those into your plain
  settings first if not already there.
- Edit `bootstrap.sh`: remove the PAI symlinking (pai-config/pai-user → ~/.claude).
  Keep whatever portable-config provisioning you still want.
- Rename/repurpose `pai-user/` → e.g. `identity/` if you keep the content.
- Rewrite `README.md` (currently describes the PAI split).

### Phase 6 — Final verification
```bash
grep -ril pai ~/dev/dotfiles --include=*.sh --include=*.md --include=*.json | grep -v .git
systemctl --user list-units | grep -i pai   # expect none
ps aux | grep -i pai | grep -v grep         # expect none
ls ~/.claude/skills                          # expect 12 personal + 5 atlas only
# Restart Claude Code and confirm it starts clean with the plain CLAUDE.md.
```

---

## 4. Open decisions before running
1. **`~/.config/PAI/.env`** — does anything besides PAI/voice use the ELEVENLABS key? Keep the file (just unwire) vs delete.
2. **`pai-config/settings.json` MCP + permissions** — confirm these are already
   reflected in `~/.claude/settings.plain.json` before deleting `pai-config/`.
3. **How much to load every session** — what from AISTEERINGRULES/ABOUTME/tech
   prefs goes into the lean plain CLAUDE.md vs stays as on-demand reference.
4. **claude-memory shape** — keep it as your generic cross-machine sync repo
   (rename PAI-flavored dirs) vs collapse it.
5. **Push timing** — both repos are on GitHub; decide when to push the cleaned state.
