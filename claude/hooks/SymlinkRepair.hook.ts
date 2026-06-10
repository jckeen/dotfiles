#!/usr/bin/env bun
/**
 * SymlinkRepair.hook.ts — Re-link dotfiles → ~/.claude/ on SessionStart.
 *
 * Mirrors setup.sh's link logic for runnable assets (hooks, scripts, agents,
 * chrome, skills, top-level files). If a new file lands in the dotfiles repo
 * (e.g. via `git pull`) and the user hasn't re-run setup.sh, this hook installs
 * the missing symlink so the next session sees it.
 *
 * Safe-by-default: only acts on missing entries or broken symlinks. Existing
 * regular files and symlinks pointing elsewhere are left alone (and reported)
 * — the user's setup.sh is the authoritative tool for clobber/backup.
 *
 * TRIGGER: SessionStart (place FIRST so it can repair sibling hooks)
 * EXIT: 0 always (non-blocking, advisory)
 */
import {
  existsSync,
  lstatSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  symlinkSync,
  unlinkSync,
} from 'fs';
import { homedir } from 'os';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const HOME = homedir();
const HOOK_PATH = realpathSync(fileURLToPath(import.meta.url));
const DOTFILES_DIR =
  process.env.DOTFILES_DIR ?? join(dirname(HOOK_PATH), '..', '..');
const CLAUDE_SRC = join(DOTFILES_DIR, 'claude');
const CLAUDE_DST = join(HOME, '.claude');

// Top-level files in claude/ that setup.sh deliberately does NOT symlink.
// plugins.txt is consumed from the dotfiles repo, never from ~/.claude/.
// CLAUDE.md IS linked (claude/CLAUDE.md -> ~/.claude/CLAUDE.md), so a missing
// or broken link self-heals here at SessionStart, matching setup.sh.
// Keep in sync with the NOLINK lists in setup.sh and check-claude.sh.
const TOP_LEVEL_NOLINK = new Set(['AgentPack.md', 'settings.json', 'plugins.txt']);

type RepairAction = { kind: 'linked' | 'fixed' | 'skipped'; rel: string; reason?: string };

const actions: RepairAction[] = [];

function ensureLink(src: string, dst: string, rel: string): void {
  if (!existsSync(src)) return;
  let st;
  try {
    st = lstatSync(dst);
  } catch {
    symlinkSync(src, dst);
    actions.push({ kind: 'linked', rel });
    return;
  }
  if (st.isSymbolicLink()) {
    const cur = readlinkSync(dst);
    if (cur === src) return; // correct
    if (!existsSync(dst)) {
      // broken symlink — safe to replace
      try {
        unlinkSync(dst);
        symlinkSync(src, dst);
        actions.push({ kind: 'fixed', rel, reason: `was broken → ${cur}` });
      } catch (e) {
        actions.push({ kind: 'skipped', rel, reason: `broken, repair failed: ${e}` });
      }
      return;
    }
    actions.push({ kind: 'skipped', rel, reason: `symlink points elsewhere: ${cur}` });
    return;
  }
  actions.push({ kind: 'skipped', rel, reason: 'real file present (use setup.sh to back up)' });
}

function linkDir(
  srcDir: string,
  dstDir: string,
  filter: (name: string) => boolean,
  relPrefix: string,
): void {
  if (!existsSync(srcDir)) return;
  for (const name of readdirSync(srcDir)) {
    if (!filter(name)) continue;
    const src = join(srcDir, name);
    let st;
    try {
      st = lstatSync(src);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    ensureLink(src, join(dstDir, name), `${relPrefix}/${name}`);
  }
}

function main(): void {
  // 1) Top-level claude/* files (plugins.txt, statusline.sh, etc.)
  if (existsSync(CLAUDE_SRC)) {
    for (const name of readdirSync(CLAUDE_SRC)) {
      if (TOP_LEVEL_NOLINK.has(name)) continue;
      const src = join(CLAUDE_SRC, name);
      let st;
      try {
        st = lstatSync(src);
      } catch {
        continue;
      }
      if (!st.isFile()) continue;
      ensureLink(src, join(CLAUDE_DST, name), name);
    }
  }

  // 2) hooks/*.{sh,ts}
  linkDir(
    join(CLAUDE_SRC, 'hooks'),
    join(CLAUDE_DST, 'hooks'),
    (n) => n.endsWith('.sh') || n.endsWith('.ts'),
    'hooks',
  );

  // 3) scripts/*.sh
  linkDir(
    join(CLAUDE_SRC, 'scripts'),
    join(CLAUDE_DST, 'scripts'),
    (n) => n.endsWith('.sh'),
    'scripts',
  );

  // 4) agents/*.md
  linkDir(
    join(CLAUDE_SRC, 'agents'),
    join(CLAUDE_DST, 'agents'),
    (n) => n.endsWith('.md'),
    'agents',
  );

  // 5) chrome/* (all files)
  linkDir(join(CLAUDE_SRC, 'chrome'), join(CLAUDE_DST, 'chrome'), () => true, 'chrome');

  // 6) skills/<name>/* — preserve per-skill subdirs
  const skillsRoot = join(CLAUDE_SRC, 'skills');
  if (existsSync(skillsRoot)) {
    for (const skillName of readdirSync(skillsRoot)) {
      const skillSrc = join(skillsRoot, skillName);
      let st;
      try {
        st = lstatSync(skillSrc);
      } catch {
        continue;
      }
      if (!st.isDirectory()) continue;
      const skillDst = join(CLAUDE_DST, 'skills', skillName);
      try {
        require('fs').mkdirSync(skillDst, { recursive: true });
      } catch {}
      linkDir(skillSrc, skillDst, () => true, `skills/${skillName}`);
    }
  }

  const linked = actions.filter((a) => a.kind === 'linked');
  const fixed = actions.filter((a) => a.kind === 'fixed');
  const skipped = actions.filter((a) => a.kind === 'skipped');

  if (linked.length === 0 && fixed.length === 0 && skipped.length === 0) return;

  const lines: string[] = ['<system-reminder>', '🔗 Symlink repair:'];
  if (linked.length) {
    lines.push(`  Linked ${linked.length} missing entr${linked.length === 1 ? 'y' : 'ies'}:`);
    for (const a of linked) lines.push(`    • ${a.rel}`);
  }
  if (fixed.length) {
    lines.push(`  Fixed ${fixed.length} broken symlink${fixed.length === 1 ? '' : 's'}:`);
    for (const a of fixed) lines.push(`    • ${a.rel} (${a.reason})`);
  }
  if (skipped.length) {
    lines.push(`  Skipped ${skipped.length} (manual review):`);
    for (const a of skipped) lines.push(`    • ${a.rel} — ${a.reason}`);
  }
  lines.push('</system-reminder>');
  process.stdout.write(lines.join('\n') + '\n');
}

main();
