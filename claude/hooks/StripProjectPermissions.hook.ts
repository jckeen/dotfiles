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
 * e.g. /home/jckee/dev/dotfiles → -home-jckee-dev-dotfiles
 */
function toProjectSlug(dir: string): string {
  return dir.replace(/\//g, '-');
}

function main(): void {
  // Determine the current working directory (project root)
  const cwd = process.cwd();

  // Build the path to the project's settings.local.json
  const slug = toProjectSlug(cwd);
  const settingsPath = join(homedir(), '.claude', 'projects', slug, 'settings.local.json');

  if (!existsSync(settingsPath)) {
    // No project settings file — nothing to do
    console.error(`[StripProjectPermissions] No settings.local.json for ${slug}`);
    process.stdout.write('{}');
    process.exit(0);
  }

  let raw: string;
  try {
    raw = readFileSync(settingsPath, 'utf-8');
  } catch (err) {
    console.error(`[StripProjectPermissions] Failed to read ${settingsPath}: ${err}`);
    process.stdout.write('{}');
    process.exit(0);
  }

  let config: Record<string, unknown>;
  try {
    config = JSON.parse(raw);
  } catch (err) {
    console.error(`[StripProjectPermissions] Failed to parse ${settingsPath}: ${err}`);
    process.stdout.write('{}');
    process.exit(0);
  }

  // Check if permissions key exists
  if (!('permissions' in config)) {
    console.error(`[StripProjectPermissions] No permissions key in ${slug}/settings.local.json — clean`);
    process.stdout.write('{}');
    process.exit(0);
  }

  // Remove the permissions key
  delete config.permissions;
  console.error(`[StripProjectPermissions] Stripped permissions from ${slug}/settings.local.json`);

  // If the config is now empty, delete the file entirely
  const remainingKeys = Object.keys(config);
  if (remainingKeys.length === 0) {
    try {
      unlinkSync(settingsPath);
      console.error(`[StripProjectPermissions] File was empty after strip — deleted ${settingsPath}`);
    } catch (err) {
      console.error(`[StripProjectPermissions] Failed to delete empty file: ${err}`);
    }
  } else {
    // Write back with remaining config preserved
    try {
      writeFileSync(settingsPath, JSON.stringify(config, null, 2) + '\n', 'utf-8');
      console.error(`[StripProjectPermissions] Preserved ${remainingKeys.length} other key(s): ${remainingKeys.join(', ')}`);
    } catch (err) {
      console.error(`[StripProjectPermissions] Failed to write ${settingsPath}: ${err}`);
    }
  }

  process.stdout.write('{}');
  process.exit(0);
}

main();
