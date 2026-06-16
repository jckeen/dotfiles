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

function readManifest(): string[] {
  if (!existsSync(MANIFEST)) return [];
  return readFileSync(MANIFEST, 'utf-8')
    .split('\n')
    .map((l) => l.replace(/#.*$/, '').trim())
    .filter((l) => l.length > 0);
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

function main(): void {
  const desired = readManifest();
  if (desired.length === 0) return;

  const installed = readInstalled();
  const missing = desired.filter((p) => !installed.has(p));
  const undeclared = [...installed].filter((p) => !desired.includes(p));
  if (missing.length === 0 && undeclared.length === 0) return;

  let warning = '';
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
  process.stdout.write(`<system-reminder>\n${warning}</system-reminder>\n`);
}

main();
