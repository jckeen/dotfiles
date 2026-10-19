#!/usr/bin/env bun
/**
 * SymlinkRepair.hook.ts — Re-link dotfiles → ~/.claude/ on SessionStart.
 *
 * Mirrors setup.sh's link logic for runnable assets (hooks, scripts, agents,
 * chrome, skills, top-level files). If a new file lands in the dotfiles repo
 * (e.g. via `git pull`) and the user hasn't re-run setup.sh, this hook installs
 * the missing symlink so the next session sees it. Skills are linked as whole
 * directories (one link per bundle, issue #592); everything else per file.
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
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  renameSync,
  statSync,
  symlinkSync,
  unlinkSync,
} from 'fs';
import { homedir } from 'os';
import { basename, dirname, join } from 'path';
import { fileURLToPath } from 'url';

const HOME = homedir();
const HOOK_PATH = realpathSync(fileURLToPath(import.meta.url));
const DOTFILES_DIR =
  process.env.DOTFILES_DIR ?? join(dirname(HOOK_PATH), '..', '..');
const CLAUDE_SRC = join(DOTFILES_DIR, 'claude');
const CLAUDE_DST = join(HOME, '.claude');

// Top-level files in claude/ that setup.sh deliberately does NOT symlink.
// Single source of truth: claude/nolink.txt (also read by setup.sh and
// check-claude.sh via lib-symlinks.sh). No hardcoded fallback — if the manifest
// is missing we can't tell which files to skip, so we return null and main()
// skips ONLY the top-level file linking (the rest of the tree needs no filter).
// CLAUDE.md IS linked (claude/CLAUDE.md -> ~/.claude/CLAUDE.md), so a missing
// or broken link self-heals here at SessionStart, matching setup.sh.
function loadNolink(): Set<string> | null {
  try {
    const names = readFileSync(join(CLAUDE_SRC, 'nolink.txt'), 'utf-8')
      .split('\n')
      .map((l) => l.replace(/#.*/, '').trim())
      .filter(Boolean);
    return names.length > 0 ? new Set(names) : null;
  } catch {
    return null;
  }
}
const TOP_LEVEL_NOLINK = loadNolink();

type RepairAction = { kind: 'linked' | 'fixed' | 'skipped'; rel: string; reason?: string };

const actions: RepairAction[] = [];

function ensureLink(src: string, dst: string, rel: string): void {
  if (!existsSync(src)) return;
  let st;
  try {
    st = lstatSync(dst);
  } catch {
    // Missing entry. A failed link is reported, never thrown — the hook
    // promises exit 0 (issue #598).
    try {
      symlinkSync(src, dst);
      actions.push({ kind: 'linked', rel });
    } catch (e) {
      actions.push({ kind: 'skipped', rel, reason: `link failed: ${e}` });
    }
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

// setup.sh may not have run yet (fresh machine, new CLAUDE_CONFIG_DIR
// profile), so a category dir can be absent (issue #598).
function ensureDir(dir: string, rel: string): boolean {
  try {
    mkdirSync(dir, { recursive: true });
    return true;
  } catch (e) {
    actions.push({ kind: 'skipped', rel, reason: `cannot create dir: ${e}` });
    return false;
  }
}

function linkDir(
  srcDir: string,
  dstDir: string,
  filter: (name: string) => boolean,
  relPrefix: string,
): void {
  if (!existsSync(srcDir) || !ensureDir(dstDir, relPrefix)) return;
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

// Pre-#592 installs hold ~/.claude/skills/<name>/ as a real directory of
// per-file links. It is legacy only when every entry is a link to exactly
// <src>/<same name> (live or dangling) — the same test as lib-symlinks.sh's
// symlink_is_legacy_skill_dir.
function isLegacySkillDir(src: string, dir: string): boolean {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (!lstatSync(p).isSymbolicLink()) return false;
    if (readlinkSync(p) !== join(src, name)) return false;
  }
  return true;
}

function lexists(p: string): boolean {
  try {
    lstatSync(p);
    return true;
  } catch {
    return false;
  }
}

// Migration never deletes (issue #638): unlinking the per-file links by path
// raced a concurrent check-claude.sh --heal, whose directory link made
// unlink(dst/x) delete the real src/x, and Node cannot unlink "only if still a
// symlink". So the whole dir is renamed into the same archive lib-symlinks.sh
// uses, ~/.claude/.migrated-skill-dirs/<name>.<UTC timestamp>.<pid>. It holds
// only old symlinks and is safe to delete by hand.
//   'moved'      dst is gone (archived, or a rival moved it); caller links it
//   'not-legacy' dst holds other content; touched nothing
//   'failed'     reported in actions; dst left as found, or kept in the archive
type MigrateResult = 'moved' | 'not-legacy' | 'failed';
function migrateLegacySkillDir(src: string, dst: string, rel: string): MigrateResult {
  const archive = join(CLAUDE_DST, '.migrated-skill-dirs');
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const dest = join(archive, `${basename(dst)}.${stamp}.${process.pid}`);
  try {
    if (!isLegacySkillDir(src, dst)) return 'not-legacy';
    mkdirSync(archive, { recursive: true });
    // renameSync fails across filesystems rather than copying; say why.
    if (statSync(dst).dev !== statSync(archive).dev) {
      actions.push({ kind: 'skipped', rel, reason: `${archive} is on another filesystem` });
      return 'failed';
    }
    if (lexists(dest)) {
      actions.push({ kind: 'skipped', rel, reason: `${dest} already exists` });
      return 'failed';
    }
  } catch (e) {
    actions.push({ kind: 'skipped', rel, reason: `legacy skill dir check failed: ${e}` });
    return 'failed';
  }
  try {
    renameSync(dst, dest);
  } catch (e) {
    // A rival moved it first: nothing to do unless it is still here.
    if (!lexists(dst)) return 'moved';
    actions.push({ kind: 'skipped', rel, reason: `legacy skill dir move failed: ${e}` });
    return 'failed';
  }
  try {
    // A rival's directory link grabbed between the check and the rename stays
    // in the archive; putting it back could overwrite what appeared at dst.
    if (lstatSync(dest).isSymbolicLink() || isLegacySkillDir(src, dest)) return 'moved';
  } catch {
    // fall through: treat an unreadable result as non-legacy content
  }
  // Content appeared mid-flight: back onto a still-absent dst only, never over
  // something; otherwise it stays in the archive, reported.
  try {
    if (lexists(dst)) throw new Error(`${dst} reappeared`);
    renameSync(dest, dst);
    actions.push({ kind: 'skipped', rel, reason: 'content appeared during migration; restored' });
  } catch (e) {
    actions.push({ kind: 'skipped', rel, reason: `non-legacy content kept at ${dest}: ${e}` });
  }
  return 'failed';
}

function main(): void {
  // 1) Top-level claude/* files (plugins.txt, statusline.sh, etc.). Skipped
  //    entirely if nolink.txt is missing — without the filter we can't tell
  //    which top-level files must NOT be linked, and guessing risks linking
  //    private/on-demand files. The rest of the tree below needs no filter.
  //    ~/.claude itself may be absent (fresh machine), and this pass runs
  //    before any category creates it.
  if (existsSync(CLAUDE_SRC) && ensureDir(CLAUDE_DST, '.claude')) {
    if (!TOP_LEVEL_NOLINK) {
      actions.push({
        kind: 'skipped',
        rel: 'nolink.txt',
        reason: 'manifest missing — top-level files not linked (run setup.sh)',
      });
    } else {
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
  }

  // 2) hooks/*.{sh,ts}
  linkDir(
    join(CLAUDE_SRC, 'hooks'),
    join(CLAUDE_DST, 'hooks'),
    (n) => n.endsWith('.sh') || n.endsWith('.ts'),
    'hooks',
  );

  // 3) scripts/*.{sh,json,py} — gate scripts resolve sibling data files (JSON
  //    schemas, receipt helpers) via plain dirname, so a file not linked
  //    beside the script is invisible to it and the gate degrades open (issue
  //    #271; mirrors lib-symlinks.sh's scripts category).
  linkDir(
    join(CLAUDE_SRC, 'scripts'),
    join(CLAUDE_DST, 'scripts'),
    (n) => n.endsWith('.sh') || n.endsWith('.json') || n.endsWith('.py'),
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

  // 6) skills/<name> — ONE directory link per bundle, so references/,
  //    scripts/, assets/ and .claude-plugin/ reach the destination (issue
  //    #592; mirrors lib-symlinks.sh's skills category). A real directory left
  //    by the old per-file layout is converted only when it holds nothing but
  //    our own links; any other real directory is reported, never replaced.
  const skillsRoot = join(CLAUDE_SRC, 'skills');
  if (existsSync(skillsRoot) && ensureDir(join(CLAUDE_DST, 'skills'), 'skills')) {
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
      const rel = `skills/${skillName}`;
      let dstSt;
      try {
        dstSt = lstatSync(skillDst);
      } catch {
        dstSt = null;
      }
      if (dstSt?.isDirectory()) {
        const result = migrateLegacySkillDir(skillSrc, skillDst, rel);
        if (result === 'not-legacy') {
          actions.push({
            kind: 'skipped',
            rel,
            reason: 'real directory present (use setup.sh to back up)',
          });
          continue;
        }
        if (result === 'failed') continue;
        // A rival may already have relinked it; ensureLink judges that state.
        if (lexists(skillDst)) {
          ensureLink(skillSrc, skillDst, rel);
          continue;
        }
        try {
          symlinkSync(skillSrc, skillDst);
          actions.push({ kind: 'fixed', rel, reason: 'per-file links → directory link' });
        } catch (e) {
          actions.push({ kind: 'skipped', rel, reason: `migrated, relink failed: ${e}` });
        }
        continue;
      }
      ensureLink(skillSrc, skillDst, rel);
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
