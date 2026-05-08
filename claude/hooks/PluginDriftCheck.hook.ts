#!/usr/bin/env bun
/**
 * PluginDriftCheck.hook.ts — Warn if installed plugins drift from manifest.
 *
 * Reads ~/.claude/plugins.txt (the install manifest, source of truth across
 * machines) and diffs against ~/.claude/plugins/installed_plugins.json.
 * If anything is missing or extra, emits a <system-reminder> warning at
 * SessionStart pointing at ~/.claude/scripts/sync-plugins.sh.
 *
 * TRIGGER: SessionStart
 * EXIT: 0 always (warnings are non-blocking)
 */

import { existsSync, readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const HOME = homedir();
const MANIFEST = join(HOME, '.claude', 'plugins.txt');
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
  if (missing.length === 0) return;

  const list = missing.map((p) => `  • ${p}`).join('\n');
  process.stdout.write(
    `<system-reminder>\n` +
      `⚠️  Plugin drift: ${missing.length} of ${desired.length} plugins from ` +
      `~/.claude/plugins.txt are not installed:\n${list}\n\n` +
      `Run \`~/.claude/scripts/sync-plugins.sh\` to install them, then restart Claude Code.\n` +
      `</system-reminder>\n`,
  );
}

main();
