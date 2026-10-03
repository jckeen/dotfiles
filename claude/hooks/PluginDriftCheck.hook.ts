#!/usr/bin/env bun
/**
 * PluginDriftCheck.hook.ts — Warn if installed plugins drift from manifest.
 *
 * Reads $DOTFILES_DIR/claude/plugins.txt (the install manifest, source of
 * truth across machines — setup.sh keeps it in the dotfiles repo and does
 * not symlink it into ~/.claude/) and diffs against
 * ~/.claude/plugins/installed_plugins.json. If anything is missing, emits a
 * <system-reminder> warning at SessionStart pointing at sync-plugins.sh.
 * Both drift directions are measured against USER-scope installs only:
 * `--scope project` and `--scope local` plugins belong to a checkout, not to
 * the manifest, and are intentionally absent from it (see readInstalled).
 *
 * The manifest is split into `# [global]` and `# [per-project]` sections
 * (issue #214). Both sections must be INSTALLED; only [global] plugins should
 * be ENABLED in ~/.claude/settings.json `enabledPlugins` — [per-project]
 * plugins belong in each project's .claude/settings.json. Scoping drift is
 * reported as a warning alongside install drift. Everything here is
 * warn-only: the migration window has live settings still carrying the old
 * fully-global set, and a session must never be blocked over plugin scoping.
 * A marker-less (pre-#214) manifest PARSES as before — all lines global —
 * but the scoping checks are new, so advisory warnings can appear where the
 * old hook was silent.
 *
 * Mods (issue #594): a plugin whose hooks/hooks.json has a "modules" key runs
 * JS/TS in-session, and its `tool.check` / `tool.call` hooks can approve a call
 * that an `ask` rule or one of this repo's (non-managed) settings hooks would
 * stop. Every installed plugin is scanned (marketplace cache, claude.ai synced,
 * ~/.claude/skills plugins) and each mod not allowlisted by a
 * `# mods-ok: <id>` line in the manifest is named. An unreadable or malformed
 * hooks.json is skipped, fail-open like the rest of this hook.
 *
 * TRIGGER: SessionStart
 * EXIT: 0 always (warnings are non-blocking)
 */

import { existsSync, readdirSync, readFileSync, realpathSync } from 'fs';
import { homedir } from 'os';
import { basename, dirname, join } from 'path';
import { fileURLToPath } from 'url';

const HOME = homedir();

// Resolve the dotfiles repo via the real (symlink-resolved) path of this
// hook file: $DOTFILES_DIR/claude/hooks/PluginDriftCheck.hook.ts
const HOOK_PATH = realpathSync(fileURLToPath(import.meta.url));
const DOTFILES_DIR =
  process.env.DOTFILES_DIR ?? join(dirname(HOOK_PATH), '..', '..');
const MANIFEST = join(DOTFILES_DIR, 'claude', 'plugins.txt');
const INSTALLED = join(HOME, '.claude', 'plugins', 'installed_plugins.json');
const SETTINGS = join(HOME, '.claude', 'settings.json');
const PLUGINS_ROOT = join(HOME, '.claude', 'plugins');
const SKILLS_DIR = join(HOME, '.claude', 'skills');

interface Manifest {
  global: string[];
  perProject: string[];
  modsOk: string[];
}

function readManifest(): Manifest {
  const manifest: Manifest = { global: [], perProject: [], modsOk: [] };
  if (!existsSync(MANIFEST)) return manifest;
  // Lines before any section marker count as global, so a manifest without
  // markers (the pre-#214 format) parses identically to the old hook.
  let section: 'global' | 'perProject' = 'global';
  for (const raw of readFileSync(MANIFEST, 'utf-8').split('\n')) {
    // A whole-line comment, so setup.sh and sync-plugins.sh never install it.
    const modOk = raw.match(/^\s*#\s*mods-ok:\s*(\S+)/i);
    if (modOk) {
      manifest.modsOk.push(modOk[1]);
      continue;
    }
    const marker = raw.match(/^\s*#\s*\[(global|per-project)\]/i);
    if (marker) {
      section = marker[1].toLowerCase() === 'global' ? 'global' : 'perProject';
      continue;
    }
    const line = raw.replace(/#.*$/, '').trim();
    if (line.length > 0) manifest[section].push(line);
  }
  return manifest;
}

// User-scope installs only. The manifest is a user-scope install list —
// setup.sh and sync-plugins.sh install without `--scope`, so a fresh clone
// reproduces user-scope plugins and nothing else. `claude plugin install`
// takes `--scope user|project|local`; a project- or local-scoped install is
// owned by that checkout, not by the manifest (render@claude-plugins-official
// is the live case: the manifest deliberately excludes it), so counting it
// here reported reverse drift whose only suggested remedy — adding it to the
// manifest — would install it at user scope everywhere.
//
// `user` is an ALLOWLIST, not `project` a denylist: a scope value we have
// never heard of should read as "not the user-scope install the manifest
// promises", which at worst asks for a redundant idempotent install, rather
// than silently satisfying the manifest. Records whose shape we don't
// recognise (non-array value, or no string `scope`) are still kept, so an
// older installed_plugins.json parses as before.
function readInstalled(): Set<string> {
  if (!existsSync(INSTALLED)) return new Set();
  try {
    const data = JSON.parse(readFileSync(INSTALLED, 'utf-8'));
    const plugins: Record<string, unknown> = data.plugins ?? {};
    const userScoped = new Set<string>();
    for (const [name, records] of Object.entries(plugins)) {
      if (!Array.isArray(records)) {
        userScoped.add(name);
        continue;
      }
      // `some` on an empty array is false, so a plugin with no install
      // records is treated as not installed — which it isn't.
      const hasUserInstall = records.some((r) => {
        const scope = (r as { scope?: unknown } | null)?.scope;
        return scope === 'user' || typeof scope !== 'string';
      });
      if (hasUserInstall) userScoped.add(name);
    }
    return userScoped;
  } catch {
    return new Set();
  }
}

// Globally-enabled plugin map, or null when settings can't be read — in that
// case the scoping checks are skipped (warn-only philosophy: never guess).
function readGloballyEnabled(): Record<string, unknown> | null {
  if (!existsSync(SETTINGS)) return null;
  try {
    const data = JSON.parse(readFileSync(SETTINGS, 'utf-8'));
    const enabled = data.enabledPlugins;
    return typeof enabled === 'object' && enabled !== null ? enabled : {};
  } catch {
    return null;
  }
}

function subdirs(dir: string): string[] {
  try {
    return readdirSync(dir)
      .filter((d) => !d.startsWith('.'))
      .map((d) => join(dir, d));
  } catch {
    return [];
  }
}

function pluginName(dir: string): string | null {
  try {
    const path = join(dir, '.claude-plugin', 'plugin.json');
    const name = JSON.parse(readFileSync(path, 'utf-8')).name;
    return typeof name === 'string' ? name : null;
  } catch {
    return null;
  }
}

// [id, dir] for every plugin on disk, ids in the `enabledPlugins` forms
// (<plugin>@<marketplace>, <name>@synced, <name>@skills-dir). Every cached
// version is scanned, not only the recorded installPath: a session started
// before an update still runs the old one.
function pluginDirs(): [string, string][] {
  const found: [string, string][] = [];
  for (const market of subdirs(join(PLUGINS_ROOT, 'cache')))
    for (const plugin of subdirs(market))
      for (const version of subdirs(plugin))
        found.push([`${basename(plugin)}@${basename(market)}`, version]);
  for (const bucket of subdirs(join(PLUGINS_ROOT, 'synced')))
    for (const dir of subdirs(bucket)) {
      const name = pluginName(dir);
      if (name) found.push([`${name}@synced`, dir]);
    }
  for (const dir of subdirs(SKILLS_DIR)) {
    const name = pluginName(dir);
    if (name) found.push([`${name}@skills-dir`, dir]);
  }
  return found;
}

function modsWarning(allowed: string[]): string {
  const mods = new Set<string>();
  for (const [id, dir] of pluginDirs()) {
    if (allowed.includes(id)) continue;
    try {
      const hooks = JSON.parse(
        readFileSync(join(dir, 'hooks', 'hooks.json'), 'utf-8'),
      );
      if (typeof hooks === 'object' && hooks !== null && 'modules' in hooks)
        mods.add(id);
    } catch {
      // No hooks.json, or one Claude Code could not load either.
    }
  }
  if (mods.size === 0) return '';
  const list = [...mods].map((p) => `  • ${p}`).join('\n');
  return (
    `⚠️  Plugin mods: ${mods.size} installed plugin(s) ship a mod (a "modules" key ` +
    `in hooks/hooks.json) — in-session code that can approve tool calls past ` +
    `\`ask\` rules and the settings hooks (issue #594):\n${list}\n\n` +
    `Review each with \`claude plugin validate <dir>\` (CLAUDE-GUIDE.md, Hooks), ` +
    `then allowlist it with a \`# mods-ok: <id>\` line in ${MANIFEST}, or uninstall it.\n`
  );
}

function emit(warning: string): void {
  if (warning.length === 0) return;
  process.stdout.write(`<system-reminder>\n${warning}</system-reminder>\n`);
}

function main(): void {
  const manifest = readManifest();
  let warning = modsWarning(manifest.modsOk);
  // Dedupe so a plugin duplicated across sections (warned below) doesn't
  // skew the install-drift counts.
  const desired = [...new Set([...manifest.global, ...manifest.perProject])];
  if (desired.length === 0) return emit(warning);

  // A plugin in BOTH sections is unsatisfiable: the scoping checks below
  // would demand it be globally enabled and not globally enabled at once.
  const duplicated = manifest.global.filter((p) =>
    manifest.perProject.includes(p),
  );
  if (duplicated.length > 0) {
    const list = [...new Set(duplicated)].map((p) => `  • ${p}`).join('\n');
    warning +=
      `⚠️  Plugin manifest: ${new Set(duplicated).size} plugin(s) listed in BOTH the ` +
      `[global] and [per-project] sections of ${MANIFEST} — unsatisfiable scoping; ` +
      `keep each plugin in exactly one section:\n${list}\n\n`;
  }

  const installed = readInstalled();
  const missing = desired.filter((p) => !installed.has(p));
  const undeclared = [...installed].filter((p) => !desired.includes(p));
  if (missing.length > 0) {
    const list = missing.map((p) => `  • ${p}`).join('\n');
    warning +=
      `⚠️  Plugin drift: ${missing.length} of ${desired.length} plugins from ` +
      `${MANIFEST} are not installed:\n${list}\n\n` +
      `Run \`~/.claude/scripts/sync-plugins.sh\` to install them, then restart Claude Code.\n`;
  }
  if (undeclared.length > 0) {
    const list = undeclared.map((p) => `  • ${p}`).join('\n');
    warning +=
      `⚠️  Plugin drift (reverse): ${undeclared.length} installed plugin(s) missing from ` +
      `the manifest — a fresh-clone setup would drop them:\n${list}\n\n` +
      `Add them to ${MANIFEST} (or uninstall them) to resolve.\n`;
  }

  const enabled = readGloballyEnabled();
  if (enabled !== null) {
    const notEnabled = manifest.global.filter((p) => enabled[p] !== true);
    const overScoped = manifest.perProject.filter((p) => enabled[p] === true);
    if (notEnabled.length > 0) {
      const list = notEnabled.map((p) => `  • ${p}`).join('\n');
      warning +=
        `⚠️  Plugin scoping: ${notEnabled.length} [global] plugin(s) from the manifest ` +
        `are not enabled in ~/.claude/settings.json \`enabledPlugins\`:\n${list}\n\n` +
        `Add them there (value \`true\`) so they load in every session.\n`;
    }
    if (overScoped.length > 0) {
      const list = overScoped.map((p) => `  • ${p}`).join('\n');
      warning +=
        `⚠️  Plugin scoping: ${overScoped.length} [per-project] plugin(s) are enabled ` +
        `globally in ~/.claude/settings.json — their skills dilute every session's ` +
        `skill list (issue #214):\n${list}\n\n` +
        `Move each to the target project's .claude/settings.json \`enabledPlugins\` ` +
        `(targets are noted in ${MANIFEST}) and remove it from the global map. ` +
        `Warning only — nothing is blocked.\n`;
    }
  }

  emit(warning);
}

main();
