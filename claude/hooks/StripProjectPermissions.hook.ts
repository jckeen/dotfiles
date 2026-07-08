#!/usr/bin/env bun
/**
 * StripProjectPermissions.hook.ts - Strip project-level permissions overrides (SessionStart)
 *
 * PURPOSE:
 * Claude Code saves narrow permissions.allow entries into project-level settings.local.json
 * when clicking "Allow" on permission prompts. These project-level permissions OVERRIDE
 * the user's global blanket permissions in ~/.claude/settings.json, causing cascading
 * permission prompts for tools that should be globally allowed.
 *
 * This hook removes the `permissions` key from the current project's settings.local.json
 * at session start, preserving all other config (hooks, MCP servers, env, etc.).
 *
 * TRIGGER: SessionStart
 */

import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

/**
 * Convert a directory path to Claude Code's project slug format.
 * e.g. /home/you/dev/dotfiles → -home-you-dev-dotfiles
 */
function toProjectSlug(dir: string): string {
  return dir.replace(/\//g, '-');
}

/**
 * Candidate locations Claude Code may persist project-level permissions to.
 * The ACTIVE one is the repo-local file (cwd/.claude/settings.local.json) —
 * that's where clicking "Allow" writes grants. The homedir projects/<slug>
 * path is kept as a fallback for CLI versions that used/return to it, so the
 * strip lands regardless of which location is in play.
 */
function candidatePaths(cwd: string): string[] {
  return [
    join(cwd, '.claude', 'settings.local.json'),
    join(homedir(), '.claude', 'projects', toProjectSlug(cwd), 'settings.local.json'),
  ];
}

/** Strip `permissions` from one settings file. Returns true if the strip landed
 *  (or there was nothing to do); false only if a needed write/delete failed. */
function stripOne(settingsPath: string): boolean {
  if (!existsSync(settingsPath)) {
    return true;
  }

  let raw: string;
  try {
    raw = readFileSync(settingsPath, 'utf-8');
  } catch (err) {
    console.error(`[StripProjectPermissions] Failed to read ${settingsPath}: ${err}`);
    return true;
  }

  let config: Record<string, unknown>;
  try {
    config = JSON.parse(raw);
  } catch (err) {
    console.error(`[StripProjectPermissions] Failed to parse ${settingsPath}: ${err}`);
    return true;
  }

  if (!('permissions' in config)) {
    return true;
  }

  delete config.permissions;
  console.error(`[StripProjectPermissions] Stripped permissions from ${settingsPath}`);

  // If the config is now empty, delete the file entirely. A failed delete/write
  // means the strip did NOT land — return false so the caller surfaces it.
  const remainingKeys = Object.keys(config);
  if (remainingKeys.length === 0) {
    try {
      unlinkSync(settingsPath);
      console.error(`[StripProjectPermissions] File was empty after strip — deleted ${settingsPath}`);
    } catch (err) {
      console.error(`[StripProjectPermissions] Failed to delete empty file: ${err}`);
      return false;
    }
  } else {
    try {
      writeFileSync(settingsPath, JSON.stringify(config, null, 2) + '\n', 'utf-8');
      console.error(`[StripProjectPermissions] Preserved ${remainingKeys.length} other key(s): ${remainingKeys.join(', ')}`);
    } catch (err) {
      console.error(`[StripProjectPermissions] Failed to write ${settingsPath}: ${err}`);
      return false;
    }
  }
  return true;
}

function main(): void {
  const cwd = process.cwd();
  let applied = true;
  for (const settingsPath of candidatePaths(cwd)) {
    if (!stripOne(settingsPath)) {
      applied = false;
    }
  }
  process.stdout.write('{}');
  process.exit(applied ? 0 : 1);
}

main();
