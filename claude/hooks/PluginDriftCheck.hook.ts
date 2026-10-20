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
 * stop. Every installed plugin is scanned (marketplace cache, relative-path
 * plugins loaded in place from a local-path marketplace, claude.ai synced,
 * ~/.claude/skills and the project's .claude/skills plugins) and each mod not
 * allowlisted by a
 * `# mods-ok: <id>` line in the manifest is named. A project .claude/skills
 * mod is named even when allowlisted: its id shares the `@skills-dir`
 * namespace with ~/.claude/skills, so a cloned repo could otherwise ship a
 * plugin under an allowlisted name. For a plugin of any origin, a
 * hooks.json, plugin.json or marketplace.json that exists but cannot be read
 * or parsed is named as unverifiable: Claude Code's loader may accept what
 * this parser rejects, so skipping it would hide the mod. Only a file that is
 * not there at all is skipped.
 *
 * Every relative-path entry of a registered local marketplace is scanned,
 * enabled or not. Enablement can also come from --settings, managed settings
 * or --add-dir, none of which this hook can see, so filtering on it would
 * fail open; an advisory warning for a catalog mod nobody enabled is the
 * cheaper error. Every JSON file is read through readJsonFile(), which
 * refuses anything but a regular file of at most 1 MiB, so a FIFO cannot hang
 * the hook and /dev/zero cannot exhaust memory.
 *
 * Loader listing (#647): `claude plugin list --json` is Claude Code's own
 * account of every installed plugin and the directory it loads from
 * (`readFromFolder`, else `installPath`). Each listed directory is scanned IN
 * ADDITION to the static enumeration above — a union, never a replacement, so
 * a plugin either side misses is still read. The listing names no hook
 * modules, so whether a directory ships a mod is still this hook's own parse
 * of hooks.json. When the CLI is missing, fails, or prints something that is
 * not a JSON array, the static scan runs alone, as before.
 *
 * Best-effort and advisory, not a security boundary: a parser differential
 * with Claude Code's loader is still possible for hooks.json itself; see #647.
 *
 * Every name and path printed comes from files a cloned repo or a marketplace
 * controls, and the output becomes model context, so each is passed through
 * shown() first. An id shown() prints unchanged is its own allowlist key; any
 * other id (unsafe characters, or over 300 characters) is printed sanitized
 * alongside the key `sha256:<first 16 hex of the SHA-256 of the raw id's
 * UTF-16LE code units>`, and only
 * that token allowlists it (#648) — so every printed key clears its warning,
 * and no raw id can match an allowlist line by spelling out a token.
 *
 * Two rules govern everything read from a marketplace, a project or settings:
 *
 * RULE 1, isolation. Each untrusted item (a catalog entry, a plugin dir) is
 * processed inside its own try/catch; a throw names that
 * item as unverifiable and the scan goes on. Each warning section runs
 * guarded too, and main() is wrapped, so whatever was collected is emitted
 * even if something unexpected throws. No untrusted value is interpolated,
 * compared or used as a key before `typeof === 'string'`.
 *
 * RULE 2, fail toward reporting. A skip that depends on a read (is this dir
 * ~/.claude/skills? does this file exist?) treats an unreadable or malformed
 * input as "report it".
 *
 * Service selection (issue #425): a plugin whose agent service the operator
 * deselected (today: `*@openai-codex` when Codex is off) is not install or
 * scoping drift. The rule lives in lib-services.sh (services_effective +
 * services_filter_plugins), which this hook runs through bash so it and
 * sync-plugins.sh cannot disagree. Rule 2 applies: if the selection cannot be
 * read, every manifest plugin is reported as before, with a note saying so.
 *
 * Mid-session rescan (#618): Claude Code has no hook event for a plugin
 * install, enable or /reload-plugins, so the hook is also registered on
 * UserPromptSubmit. There, the cheap path reads this session's state file
 * (~/.local/state/plugin-drift/<session_id>, plain text, written by the last
 * full scan) and stats every path that scan read or listed — one stat each, no
 * JSON parsing. Only when a size, mtime, inode or existence changed does it run
 * the full mod scan again, and it then names only the mods (and unverifiable
 * plugins) this session has not been told about yet. A missing or damaged
 * state file is a change (rule 2). The install-drift section runs at
 * SessionStart only.
 *
 * TRIGGER: SessionStart, UserPromptSubmit
 * EXIT: 0 always (warnings are non-blocking)
 */

import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'fs';
import { spawnSync } from 'child_process';
import { createHash } from 'crypto';
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
const KNOWN_MARKETPLACES = join(PLUGINS_ROOT, 'known_marketplaces.json');
const MAX_JSON_BYTES = 1024 * 1024;
// Per-session rescan state (#618). Pruned at SessionStart after STATE_TTL_MS.
const STATE_DIR = join(HOME, '.local', 'state', 'plugin-drift');
const STATE_TTL_MS = 30 * 24 * 60 * 60 * 1000;
// `claude plugin list --json` measured ~1 s; the cap keeps a wedged CLI from
// holding the session start.
const LIST_TIMEOUT_MS = 10_000;
// Code, so it comes from this hook's own checkout, never from DOTFILES_DIR
// (which only relocates the manifest) — the same rule as sync-plugins.sh.
const LIB_SERVICES = join(dirname(HOOK_PATH), '..', '..', 'lib-services.sh');

type JsonRead =
  | { state: 'absent' }
  | { state: 'bad' }
  | { state: 'ok'; value: unknown };

// The one reader for every plugin-side JSON file. Opened non-blocking and
// checked on the open descriptor, so a FIFO, a device (/dev/zero), a
// directory or an oversized file is `bad` without being read, and a swap
// between check and read cannot slip one past. `absent` means nothing is
// there at all; a dangling symlink is `bad`.
function readJsonFile(path: string): JsonRead {
  watch(path);
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
  } catch {
    return present(path) ? { state: 'bad' } : { state: 'absent' };
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_JSON_BYTES) return { state: 'bad' };
    const buf = Buffer.alloc(stat.size + 1);
    const n = readSync(fd, buf, 0, buf.length, 0);
    if (n > stat.size) return { state: 'bad' }; // Grew since the fstat.
    return { state: 'ok', value: JSON.parse(buf.toString('utf-8', 0, n)) };
  } catch {
    return { state: 'bad' };
  } finally {
    closeSync(fd);
  }
}

// Every path a full scan reads or lists, with its signature taken BEFORE the
// read, so a change that lands during the scan still trips the next rescan.
const watched = new Map<string, string>();

// One stat: size, mtime, inode, or the error code. Never opens the file, so a
// FIFO or device costs no more than a regular file.
function signature(path: string): string {
  try {
    const st = statSync(path);
    return `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch (err) {
    const code = (err as { code?: unknown } | null)?.code;
    return `-${typeof code === 'string' ? code : 'ERR'}`;
  }
}

function watch(path: string): void {
  if (!watched.has(path)) watched.set(path, signature(path));
}

// The hook input (Claude Code's own JSON on stdin, not a plugin file): `cwd`
// follows the session into a --worktree, where $CLAUDE_PROJECT_DIR stays on
// the main checkout; `session_id` keys the rescan state.
interface HookInput {
  cwd: string | null;
  sessionId: string | null;
  event: string | null;
}
function readInput(): HookInput {
  const none: HookInput = { cwd: null, sessionId: null, event: null };
  if (process.stdin.isTTY) return none;
  try {
    const input = JSON.parse(readFileSync(0, 'utf-8').slice(0, MAX_JSON_BYTES));
    const str = (v: unknown) => (typeof v === 'string' && v ? v : null);
    return {
      cwd: str(input?.cwd),
      sessionId: str(input?.session_id),
      event: str(input?.hook_event_name),
    };
  } catch {
    return none;
  }
}
const INPUT = readInput();

// Claude Code reads project .claude/skills plugins from the session's working
// directory (no parent search). $CLAUDE_PROJECT_DIR is scanned too: a
// worktree without its own .claude/skills, and a desktop worktree session,
// load the main checkout's.
const PROJECT_DIRS = [
  ...new Set(
    [INPUT.cwd ?? process.cwd(), process.env.CLAUDE_PROJECT_DIR].filter(
      (d): d is string => !!d,
    ),
  ),
];

const SAFE_ID = /^[A-Za-z0-9._@/-]+$/;

// True when shown() prints the text unchanged, so it can be copied into a
// `# mods-ok:` line.
function verbatim(text: string): boolean {
  return SAFE_ID.test(text) && text.length <= 300;
}

// Untrusted text in model context: keep plugin-id and path characters only,
// so a name cannot carry a newline, a closing tag or an instruction. Safe
// text is printed whole; text that needed changing is also capped.
function shown(text: string): string {
  if (verbatim(text)) return text;
  const safe = text.replace(/[^A-Za-z0-9._@/-]/g, '_');
  return safe.length > 100 ? `${safe.slice(0, 100)}...` : safe;
}

// The one `# mods-ok:` key for an id. A token is never verbatim (`:` is
// outside SAFE_ID), so a raw id cannot collide with another id's token. The
// hash input is the id's UTF-16 code units, not UTF-8: UTF-8 encoding turns
// every lone surrogate (valid in a JSON name) into U+FFFD, which would give
// distinct ids one key.
function allowKey(id: string): string {
  if (verbatim(id)) return id;
  const units = Buffer.from(id, 'utf16le');
  return `sha256:${createHash('sha256').update(units).digest('hex').slice(0, 16)}`;
}

function bullets(items: string[]): string {
  return items.map((p) => `  • ${shown(p)}`).join('\n');
}

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
  watch(dir);
  try {
    return readdirSync(dir)
      .filter((d) => !d.startsWith('.'))
      .map((d) => join(dir, d));
  } catch {
    return [];
  }
}

function readJson(path: string): unknown {
  const read = readJsonFile(path);
  return read.state === 'ok' ? read.value : null;
}

function pluginName(dir: string): string | null {
  const name = (
    readJson(join(dir, '.claude-plugin', 'plugin.json')) as {
      name?: unknown;
    } | null
  )?.name;
  return typeof name === 'string' ? name : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// A plugin entry's relative-path source, resolved from the marketplace root
// (the directory holding .claude-plugin/): "./x", "." for the root itself, or
// a bare name under metadata.pluginRoot. Object sources are fetched into
// cache/ and anything with ".." is refused by Claude Code, so both are null.
function relativeSource(
  root: string,
  source: unknown,
  pluginRoot: unknown,
): string | null {
  if (typeof source !== 'string' || source.split('/').includes('..'))
    return null;
  if (source === '.' || source.startsWith('./')) return join(root, source);
  if (typeof pluginRoot === 'string' && !source.includes('/'))
    return join(root, pluginRoot, source);
  return null;
}

// Where a scanned plugin came from. `local` and `project` files were never
// installed by the user; all origins are read the same way (see header).
type Origin = 'installed' | 'local' | 'project';
interface Scanned {
  id: string;
  dir: string;
  origin: Origin;
  // The plugin or its entry could not be read: report without reading hooks.
  unverifiable?: boolean;
}

function unverifiable(id: string, origin: Origin): Scanned {
  return { id, dir: '', origin, unverifiable: true };
}

// True when something may be at the path, a dangling symlink included. Only
// "no such entry" is absence; any other lstat error counts as present, so an
// unreadable path is reported rather than skipped (rule 2).
function present(path: string): boolean {
  watch(path);
  try {
    lstatSync(path);
    return true;
  } catch (err) {
    const code = (err as { code?: unknown } | null)?.code;
    return code !== 'ENOENT' && code !== 'ENOTDIR';
  }
}

// Every plugin dir but a cache version goes through here, so the origins'
// checks cannot drift: a plugin.json that exists but yields no name is
// unverifiable, never skipped. `id` is a marketplace entry's id; without one
// (synced, skills dirs), a dir with no plugin.json is not a plugin and the id
// is the manifest name plus `suffix`.
function scanPlugin(
  origin: Origin,
  dir: string,
  id?: string,
  suffix = '@skills-dir',
): Scanned | null {
  if (!present(join(dir, '.claude-plugin', 'plugin.json')))
    return id ? { id, dir, origin } : null;
  const name = pluginName(dir);
  return {
    id: id ?? `${name ?? basename(dir)}${suffix}`,
    dir,
    origin,
    unverifiable: name === null,
  };
}

// The catalog entries of one local marketplace, each isolated (rule 1).
function catalogPlugins(
  market: string,
  root: string,
  catalogPath: string,
): Scanned[] {
  const found: Scanned[] = [];
  const read = readJsonFile(catalogPath);
  const catalog = read.state === 'ok' ? read.value : null;
  const plugins = isRecord(catalog) ? catalog.plugins : null;
  if (!Array.isArray(plugins)) {
    if (read.state !== 'absent')
      found.push(unverifiable(`marketplace.json@${market}`, 'local'));
    return found;
  }
  const metadata = isRecord(catalog) ? catalog.metadata : null;
  const pluginRoot = isRecord(metadata) ? metadata.pluginRoot : undefined;
  plugins.forEach((plugin: unknown, index: number) => {
    try {
      const name = isRecord(plugin) ? plugin.name : undefined;
      const src = isRecord(plugin) ? plugin.source : undefined;
      // An entry that names nothing cannot be identified, so it is reported
      // (rule 2); an object source is fetched into cache/.
      if (typeof name !== 'string') {
        found.push(unverifiable(`entry-${index}@${market}`, 'local'));
        return;
      }
      if (isRecord(src)) return;
      const id = `${name}@${market}`;
      const dir = relativeSource(root, src, pluginRoot);
      if (dir === null) {
        // Not a usable relative path: a `..` path Claude Code refuses is
        // nothing to scan; any other shape is unknown, so reported.
        if (typeof src !== 'string') found.push(unverifiable(id, 'local'));
        return;
      }
      const scanned = scanPlugin('local', dir, id);
      if (scanned) found.push(scanned);
    } catch {
      found.push(unverifiable(`entry-${index}@${market}`, 'local'));
    }
  });
  return found;
}

// Relative-path plugins of marketplaces added from a local
// `directory` or `file` source: Claude Code loads these in place from the
// marketplace folder and never copies them into cache/. A git or GitHub
// marketplace's clone is skipped — its plugins load from the cache copy.
function localMarketplacePlugins(): Scanned[] {
  const found: Scanned[] = [];
  const known = readJsonFile(KNOWN_MARKETPLACES);
  if (known.state === 'absent') return found;
  if (known.state === 'bad' || !isRecord(known.value))
    return [unverifiable('known_marketplaces.json', 'local')];
  for (const [market, entry] of Object.entries(known.value)) {
    try {
      const source = isRecord(entry) ? entry.source : null;
      const kind = isRecord(source) ? source.source : undefined;
      if (kind !== 'directory' && kind !== 'file') continue;
      const path = isRecord(source) ? source.path : undefined;
      if (typeof path !== 'string') {
        found.push(unverifiable(`marketplace.json@${market}`, 'local'));
        continue;
      }
      // A `file` source is the catalog itself, read where it is under any
      // name; relative plugin sources resolve from two directories above it.
      const root = kind === 'directory' ? path : dirname(dirname(path));
      const catalogPath =
        kind === 'directory'
          ? join(path, '.claude-plugin', 'marketplace.json')
          : path;
      found.push(...catalogPlugins(market, root, catalogPath));
    } catch {
      found.push(unverifiable(`marketplace.json@${market}`, 'local'));
    }
  }
  return found;
}

// The plugins Claude Code's loader reports (#647), or null when the listing is
// unavailable. Rule 1 per entry; an entry naming no usable directory is
// unverifiable. A skills-dir plugin that is not user scope comes from a
// project's .claude/skills, so it gets that origin and the allowlist never
// covers it; an unknown scope counts as a project's (rule 2).
function runListing(): Scanned[] | null {
  const result = spawnSync('claude', ['plugin', 'list', '--json'], {
    cwd: PROJECT_DIRS[0],
    encoding: 'utf-8',
    maxBuffer: MAX_JSON_BYTES,
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: LIST_TIMEOUT_MS,
  });
  if (result.error || result.status !== 0) return null;
  let listing: unknown;
  try {
    listing = JSON.parse(String(result.stdout));
  } catch {
    return null;
  }
  if (!Array.isArray(listing)) return null;
  const found: Scanned[] = [];
  listing.forEach((entry: unknown, index: number) => {
    try {
      const id = isRecord(entry) ? entry.id : undefined;
      if (typeof id !== 'string') {
        found.push(unverifiable(`listed-${index}@plugin-list`, 'installed'));
        return;
      }
      const scope = isRecord(entry) ? entry.scope : undefined;
      const origin: Origin =
        id.endsWith('@skills-dir') && scope !== 'user' ? 'project' : 'installed';
      const folder = isRecord(entry) ? entry.readFromFolder : undefined;
      const install = isRecord(entry) ? entry.installPath : undefined;
      const dir =
        typeof folder === 'string' && folder
          ? folder
          : typeof install === 'string' && install
            ? install
            : null;
      found.push(dir === null ? unverifiable(id, origin) : { id, dir, origin });
    } catch {
      found.push(unverifiable(`listed-${index}@plugin-list`, 'installed'));
    }
  });
  return found;
}

// The listing costs ~1 s, so its result is cached across sessions, keyed on
// the files it is derived from and the directory it ran in. The cache can only
// ADD directories to the scan (the static enumeration always runs), so a
// stale or forged cache cannot hide a plugin; a cache that is absent, damaged
// or keyed differently is a miss and the CLI runs again.
//   K <sig> <path>        a key file and its signature when listed
//   C <dir>               the directory the listing ran in
//   L <origin> <id> <dir> one listed plugin; dir `-` is unverifiable
// Every field is URI-encoded.
// The `.` keeps it apart from every per-session file (statePath's charset).
const LISTING_CACHE = join(STATE_DIR, 'listing.cache');
const LISTING_KEYS = [INSTALLED, KNOWN_MARKETPLACES, SETTINGS];

function listingKey(): string[] {
  return [
    ...LISTING_KEYS.map((path) => `K ${signature(path)} ${encodeURIComponent(path)}`),
    `C ${encodeURIComponent(PROJECT_DIRS[0] ?? '')}`,
  ];
}

function cachedListing(key: string[]): Scanned[] | null {
  try {
    const st = statSync(LISTING_CACHE);
    if (!st.isFile() || st.size > MAX_JSON_BYTES) return null;
    const lines = readFileSync(LISTING_CACHE, 'utf-8').split('\n');
    if (lines[0] !== 'plugin-drift-listing v1') return null;
    if (lines.slice(1, 1 + key.length).join('\n') !== key.join('\n')) return null;
    const found: Scanned[] = [];
    for (const line of lines.slice(1 + key.length)) {
      if (line.length === 0) continue;
      const [tag, origin, id, dir, extra] = line.split(' ');
      if (tag !== 'L' || extra !== undefined || id === undefined || dir === undefined)
        return null;
      if (origin !== 'installed' && origin !== 'project') return null;
      const plugin = decodeURIComponent(id);
      found.push(
        dir === '-'
          ? unverifiable(plugin, origin)
          : { id: plugin, dir: decodeURIComponent(dir), origin },
      );
    }
    return found;
  } catch {
    return null;
  }
}

function saveListing(key: string[], found: Scanned[]): void {
  const lines = ['plugin-drift-listing v1', ...key];
  for (const { id, dir, origin, unverifiable: bad } of found)
    lines.push(
      `L ${origin} ${encodeURIComponent(id)} ${bad ? '-' : encodeURIComponent(dir)}`,
    );
  atomicWrite(LISTING_CACHE, lines);
}

function loaderPlugins(): Scanned[] | null {
  for (const path of LISTING_KEYS) watch(path);
  const key = listingKey();
  const cached = cachedListing(key);
  if (cached !== null) return cached;
  const found = runListing();
  // A failed listing is not cached, so the next scan asks again.
  if (found !== null) saveListing(key, found);
  return found;
}

// Every plugin on disk, ids in the `enabledPlugins` forms
// (<plugin>@<marketplace>, <name>@synced, <name>@skills-dir). Every cached
// version is scanned, not only the recorded installPath: a session started
// before an update still runs the old one.
function pluginDirs(): Scanned[] {
  const found: Scanned[] = [];
  const origin = 'installed';
  for (const market of subdirs(join(PLUGINS_ROOT, 'cache')))
    for (const plugin of subdirs(market))
      for (const dir of subdirs(plugin))
        found.push({ id: `${basename(plugin)}@${basename(market)}`, dir, origin });
  for (const bucket of subdirs(join(PLUGINS_ROOT, 'synced')))
    for (const dir of subdirs(bucket)) {
      const scanned = scanPlugin(origin, dir, undefined, '@synced');
      if (scanned) found.push(scanned);
    }
  found.push(...localMarketplacePlugins());
  for (const dir of subdirs(SKILLS_DIR)) {
    const scanned = scanPlugin(origin, dir);
    if (scanned) found.push(scanned);
  }
  // A project skills dir is skipped only when it provably IS
  // ~/.claude/skills (a session started in HOME); a path that fails to
  // resolve is scanned, and one that exists but cannot be listed is named.
  for (const project of PROJECT_DIRS) {
    const skills = join(project, '.claude', 'skills');
    if (sameDir(skills, SKILLS_DIR)) continue;
    let entries: string[];
    watch(skills);
    try {
      entries = readdirSync(skills).filter((d) => !d.startsWith('.'));
    } catch {
      if (present(skills)) found.push(unverifiable(skills, 'project'));
      continue;
    }
    for (const entry of entries) {
      const dir = join(skills, entry);
      try {
        const scanned = scanPlugin('project', dir);
        if (scanned) found.push(scanned);
      } catch {
        found.push(unverifiable(`${entry}@skills-dir`, 'project'));
      }
    }
  }
  found.push(...(loaderPlugins() ?? []));
  return found;
}

function sameDir(a: string, b: string): boolean {
  try {
    return realpathSync(a) === realpathSync(b);
  } catch {
    return false;
  }
}

interface ModFindings {
  mods: Set<string>;
  unknown: Set<string>;
}

function findMods(allowed: string[]): ModFindings {
  const mods = new Set<string>();
  const unknown = new Set<string>();
  for (const { id, dir, origin, unverifiable: noManifest } of pluginDirs()) {
    const key = allowKey(id);
    if (origin !== 'project' && allowed.includes(key)) continue;
    const label =
      shown(id) +
      // A project mod is always named, so no key would clear it.
      (key === id
        ? ''
        : origin === 'project'
          ? ' (sanitized)'
          : ` (sanitized; allowlist key: ${key})`) +
      (origin === 'project' ? ' (project .claude/skills)' : '');
    if (noManifest) {
      unknown.add(label);
      continue;
    }
    try {
      const hooks = readJsonFile(join(dir, 'hooks', 'hooks.json'));
      if (hooks.state === 'ok') {
        const value = hooks.value;
        if (typeof value === 'object' && value !== null && 'modules' in value)
          mods.add(label);
      } else if (hooks.state === 'bad') {
        // No hooks.json is no mod; one that cannot be read is reported.
        unknown.add(label);
      }
    } catch {
      unknown.add(label);
    }
  }
  return { mods, unknown };
}

// `rescan` marks a mid-session report, which names only what is new.
function modsWarning({ mods, unknown }: ModFindings, rescan = false): string {
  let warning =
    rescan && (mods.size > 0 || unknown.size > 0)
      ? `⚠️  Plugin mods: plugin files changed mid-session (an install, ` +
        `update, enable or /reload-plugins); the rescan found these not ` +
        `reported earlier in this session (#618).\n`
      : '';
  if (unknown.size > 0) {
    const list = [...unknown].map((p) => `  • ${p}`).join('\n');
    warning +=
      `⚠️  Plugin mods (unverifiable): ${unknown.size} plugin(s) have a ` +
      `hooks.json, plugin.json, marketplace.json or catalog entry this hook ` +
      `cannot read or parse (malformed, not a regular file, or over 1 MiB), so ` +
      `whether they ship a mod is unknown — review each manually:\n${list}\n\n`;
  }
  if (mods.size === 0) return warning;
  // Labels were already passed through shown().
  const list = [...mods].map((p) => `  • ${p}`).join('\n');
  return (
    warning +
    `⚠️  Plugin mods: ${mods.size} installed plugin(s) ship a mod (a "modules" key ` +
    `in hooks/hooks.json) — in-session code that can approve tool calls past ` +
    `\`ask\` rules and the settings hooks (issue #594):\n${list}\n\n` +
    `Review each with \`claude plugin validate <dir>\` (CLAUDE-GUIDE.md, Hooks), ` +
    `then allowlist it with a \`# mods-ok: <id>\` line in ${shown(MANIFEST)} ` +
    `(for a sanitized id, the \`sha256:\` key shown), or uninstall it. ` +
    `A project .claude/skills mod is always named: the allowlist cannot vouch ` +
    `for a repo's copy.\n`
  );
}

function errorText(err: unknown): string {
  try {
    return shown(err instanceof Error ? err.message : String(err));
  } catch {
    return 'unprintable error';
  }
}

// Rule 1: every section's warnings are kept even when a later one throws.
let collected = '';
function section(name: string, check: () => string): void {
  try {
    collected += check();
  } catch (err) {
    collected +=
      `⚠️  PluginDriftCheck: the ${name} check failed (${errorText(err)}); ` +
      `its warnings are missing this session.\n`;
  }
}

function emit(warning: string): void {
  if (warning.length === 0) return;
  process.stdout.write(`<system-reminder>\n${warning}</system-reminder>\n`);
}

// The manifest plugins the saved agent-service selection manages, or null
// (with the reason) when it cannot be determined — rule 2: report them all.
function selectedPlugins(
  ids: string[],
): { kept: Set<string> | null; reason: string } {
  if (!existsSync(LIB_SERVICES)) {
    return { kept: null, reason: `${shown(LIB_SERVICES)} is missing` };
  }
  const result = spawnSync(
    'bash',
    [
      '-c',
      '. "$1" || exit 3; sel="$(services_effective)" || exit 2; services_filter_plugins "$sel"',
      'plugin-drift',
      LIB_SERVICES,
    ],
    { input: ids.join('\n') + '\n', encoding: 'utf-8', timeout: 5000 },
  );
  if (result.error || result.status !== 0) {
    const why =
      result.status === 2
        ? 'the saved selection is damaged'
        : result.error
          ? errorText(result.error)
          : `exit ${result.status}`;
    return { kept: null, reason: why };
  }
  const kept = new Set(
    String(result.stdout)
      .split('\n')
      .filter((l) => l.length > 0),
  );
  return { kept, reason: '' };
}

function driftWarning(manifest: Manifest): string {
  let warning = '';
  // Dedupe so a plugin duplicated across sections (warned below) doesn't
  // skew the install-drift counts.
  const desired = [...new Set([...manifest.global, ...manifest.perProject])];
  if (desired.length === 0) return warning;

  // A plugin in BOTH sections is unsatisfiable: the scoping checks below
  // would demand it be globally enabled and not globally enabled at once.
  const duplicated = manifest.global.filter((p) =>
    manifest.perProject.includes(p),
  );
  if (duplicated.length > 0) {
    const list = bullets([...new Set(duplicated)]);
    warning +=
      `⚠️  Plugin manifest: ${new Set(duplicated).size} plugin(s) listed in BOTH the ` +
      `[global] and [per-project] sections of ${shown(MANIFEST)} — unsatisfiable scoping; ` +
      `keep each plugin in exactly one section:\n${list}\n\n`;
  }

  const selection = selectedPlugins(desired);
  const managed = (p: string) =>
    selection.kept === null || selection.kept.has(p);
  if (selection.kept === null) {
    warning +=
      `⚠️  Plugin drift: the agent-service selection could not be read ` +
      `(${selection.reason}); every manifest plugin is checked. ` +
      `Fix it with \`setup.sh --select-services\`.\n`;
  }

  // Every install and scoping list below is built from these filtered lists.
  // Reverse drift still compares against the whole manifest: a deselected
  // service's plugin that is installed is declared, not undeclared.
  const wanted = desired.filter(managed);
  const wantedGlobal = manifest.global.filter(managed);
  const wantedPerProject = manifest.perProject.filter(managed);

  const installed = readInstalled();
  const missing = wanted.filter((p) => !installed.has(p));
  const undeclared = [...installed].filter((p) => !desired.includes(p));
  if (missing.length > 0) {
    const list = bullets(missing);
    warning +=
      `⚠️  Plugin drift: ${missing.length} of ${wanted.length} plugins from ` +
      `${shown(MANIFEST)} are not installed:\n${list}\n\n` +
      `Run \`~/.claude/scripts/sync-plugins.sh\` to install them, then restart Claude Code.\n`;
  }
  if (undeclared.length > 0) {
    const list = bullets(undeclared);
    warning +=
      `⚠️  Plugin drift (reverse): ${undeclared.length} installed plugin(s) missing from ` +
      `the manifest — a fresh-clone setup would drop them:\n${list}\n\n` +
      `Add them to ${shown(MANIFEST)} (or uninstall them) to resolve.\n`;
  }

  const enabled = readGloballyEnabled();
  if (enabled !== null) {
    const notEnabled = wantedGlobal.filter((p) => enabled[p] !== true);
    const overScoped = wantedPerProject.filter((p) => enabled[p] === true);
    if (notEnabled.length > 0) {
      const list = bullets(notEnabled);
      warning +=
        `⚠️  Plugin scoping: ${notEnabled.length} [global] plugin(s) from the manifest ` +
        `are not enabled in ~/.claude/settings.json \`enabledPlugins\`:\n${list}\n\n` +
        `Add them there (value \`true\`) so they load in every session.\n`;
    }
    if (overScoped.length > 0) {
      const list = bullets(overScoped);
      warning +=
        `⚠️  Plugin scoping: ${overScoped.length} [per-project] plugin(s) are enabled ` +
        `globally in ~/.claude/settings.json — their skills dilute every session's ` +
        `skill list (issue #214):\n${list}\n\n` +
        `Move each to the target project's .claude/settings.json \`enabledPlugins\` ` +
        `(targets are noted in ${shown(MANIFEST)}) and remove it from the global map. ` +
        `Warning only — nothing is blocked.\n`;
    }
  }
  return warning;
}

// ── Rescan state (#618) ─────────────────────────────────────────────────
// Plain text, one record per line, so the cheap path parses no JSON:
//   P <project dir>     a project dir the scan read (a cwd change is a change)
//   W <sig> <path>      a watched path and its signature at scan time
//   M|U <label>         a mod / unverifiable label already reported
// Paths are URI-encoded so a newline in an untrusted path cannot forge a
// record; labels went through shown(), which leaves no newline.
interface ScanState {
  projects: string[];
  watched: [string, string][];
  reported: Set<string>;
}

function statePath(): string {
  const id = INPUT.sessionId;
  return join(
    STATE_DIR,
    id !== null && /^[A-Za-z0-9_-]{1,128}$/.test(id) ? id : 'no-session',
  );
}

// null when absent, unreadable, oversized or not this format (rule 2: the
// caller treats that as a change and rescans).
function readState(): ScanState | null {
  try {
    const path = statePath();
    const st = statSync(path);
    if (!st.isFile() || st.size > MAX_JSON_BYTES) return null;
    const lines = readFileSync(path, 'utf-8').split('\n');
    if (lines[0] !== 'plugin-drift-state v1') return null;
    const state: ScanState = { projects: [], watched: [], reported: new Set() };
    for (const line of lines.slice(1)) {
      if (line.length === 0) continue;
      const tag = line.slice(0, 2);
      const rest = line.slice(2);
      if (tag === 'P ') state.projects.push(decodeURIComponent(rest));
      else if (tag === 'W ') {
        const space = rest.indexOf(' ');
        if (space < 0) return null;
        state.watched.push([decodeURIComponent(rest.slice(space + 1)), rest.slice(0, space)]);
      } else if (tag === 'M ' || tag === 'U ') state.reported.add(line);
      else return null;
    }
    return state;
  } catch {
    return null;
  }
}

// Write-then-rename, so a concurrent reader sees the old file or the new one.
// Advisory: a failed write only means the next run scans or lists again.
function atomicWrite(path: string, lines: string[]): void {
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    writeFileSync(tmp, lines.join('\n') + '\n', { mode: 0o600 });
    renameSync(tmp, path);
  } catch {
    try {
      unlinkSync(tmp);
    } catch {
      // Nothing was written.
    }
  }
}

function writeState(reported: Set<string>): void {
  const lines = ['plugin-drift-state v1'];
  for (const dir of PROJECT_DIRS) lines.push(`P ${encodeURIComponent(dir)}`);
  for (const [path, sig] of watched) lines.push(`W ${sig} ${encodeURIComponent(path)}`);
  lines.push(...reported);
  // Without state the next prompt rescans and re-reports (rule 2).
  atomicWrite(statePath(), lines);
}

// Old sessions' state files, so the directory cannot grow without bound.
function pruneState(): void {
  try {
    const now = Date.now();
    for (const name of readdirSync(STATE_DIR)) {
      const path = join(STATE_DIR, name);
      try {
        if (now - lstatSync(path).mtimeMs > STATE_TTL_MS) unlinkSync(path);
      } catch {
        // Gone already, or not ours to remove.
      }
    }
  } catch {
    // No state dir yet.
  }
}

function reportedKeys({ mods, unknown }: ModFindings): Set<string> {
  return new Set([...[...mods].map((l) => `M ${l}`), ...[...unknown].map((l) => `U ${l}`)]);
}

// The cheap path: true when nothing the last scan read has changed.
function unchanged(state: ScanState | null): boolean {
  if (state === null) return false;
  if (state.projects.join('\n') !== PROJECT_DIRS.join('\n')) return false;
  return state.watched.every(([path, sig]) => signature(path) === sig);
}

function rescan(): void {
  const state = readState();
  if (unchanged(state)) return;
  const manifest = readManifest();
  watch(MANIFEST);
  const before = state?.reported ?? new Set<string>();
  let found: ModFindings | null = null;
  section('plugin mods', () => {
    found = findMods(manifest.modsOk);
    const fresh: ModFindings = {
      mods: new Set([...found.mods].filter((l) => !before.has(`M ${l}`))),
      unknown: new Set([...found.unknown].filter((l) => !before.has(`U ${l}`))),
    };
    return modsWarning(fresh, true);
  });
  // A scan that threw keeps the old state, so the next prompt tries again.
  if (found !== null) writeState(new Set([...before, ...reportedKeys(found)]));
}

function main(): void {
  if (INPUT.event === 'UserPromptSubmit') {
    rescan();
    return;
  }
  const manifest = readManifest();
  watch(MANIFEST);
  let found: ModFindings | null = null;
  section('plugin mods', () => {
    found = findMods(manifest.modsOk);
    return modsWarning(found);
  });
  section('plugin drift', () => driftWarning(manifest));
  pruneState();
  if (found !== null) writeState(reportedKeys(found));
}

try {
  main();
} catch (err) {
  collected += `⚠️  PluginDriftCheck failed (${errorText(err)}).\n`;
}
emit(collected);
