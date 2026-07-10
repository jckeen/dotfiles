#!/usr/bin/env bun
/**
 * PluginDriftCheck.hook.ts — Warn if installed plugins drift from manifest.
 *
 * Reads $DOTFILES_DIR/claude/plugins.txt (the install manifest, source of
 * truth across machines — setup.sh keeps it in the dotfiles repo and does
 * not symlink it into ~/.claude/) and diffs against
 * ~/.claude/plugins/installed_plugins.json. If anything is missing, emits a
 * <system-reminder> warning at SessionStart pointing at sync-plugins.sh.
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
 * TRIGGER: SessionStart
 * EXIT: 0 always (warnings are non-blocking)
 */

import { existsSync, readFileSync, realpathSync } from 'fs';
import { homedir } from 'os';
import { dirname, join } from 'path';
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

interface Manifest {
  global: string[];
  perProject: string[];
}

function readManifest(): Manifest {
  const manifest: Manifest = { global: [], perProject: [] };
  if (!existsSync(MANIFEST)) return manifest;
  // Lines before any section marker count as global, so a manifest without
  // markers (the pre-#214 format) parses identically to the old hook.
  let section: keyof Manifest = 'global';
  for (const raw of readFileSync(MANIFEST, 'utf-8').split('\n')) {
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

function readInstalled(): Set<string> {
  if (!existsSync(INSTALLED)) return new Set();
  try {
    const data = JSON.parse(readFileSync(INSTALLED, 'utf-8'));
    return new Set(Object.keys(data.plugins ?? {}));
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

function main(): void {
  const manifest = readManifest();
  // Dedupe so a plugin duplicated across sections (warned below) doesn't
  // skew the install-drift counts.
  const desired = [...new Set([...manifest.global, ...manifest.perProject])];
  if (desired.length === 0) return;

  let warning = '';

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

  if (warning.length === 0) return;
  process.stdout.write(`<system-reminder>\n${warning}</system-reminder>\n`);
}

main();
