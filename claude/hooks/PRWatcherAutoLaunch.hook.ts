#!/usr/bin/env bun
/**
 * PRWatcherAutoLaunch.hook.ts — PostToolUse hook that detects PR creation
 * and launches WatchPRReviews.ts in the background, so the watch→fix→
 * re-review loop becomes part of the standing workflow with zero manual
 * Monitor invocation.
 *
 * TRIGGERS (from settings.json PostToolUse matcher):
 *   - tool_name === "Bash" && tool_input.command matches /\bgh\s+pr\s+create\b/
 *   - tool_name === "mcp__github__create_pull_request"
 *
 * INPUT  (stdin JSON, harness-supplied):
 *   { tool_name, tool_input, tool_response, transcript_path, ... }
 *
 * OUTPUT: nothing on stdout (PostToolUse output is not surfaced as context).
 *         All diagnostics → ~/.claude/PAI/MEMORY/PR_WATCH/spawn.log.
 *
 * STATE:
 *   ~/.claude/PAI/MEMORY/PR_WATCH/active.json   — array of {pr, repo, pid, started_at, log_path}
 *   ~/.claude/PAI/MEMORY/PR_WATCH/spawn.log     — append-only diagnostic log
 *
 * IDEMPOTENCY:
 *   - Reaps active.json entries whose PIDs are dead (cleanup on each run).
 *   - If (repo, pr) already has a live watcher, skip spawn (no double-watch).
 *
 * SAFETY:
 *   - Hook returns within ~200ms; spawn is detached + unref'd.
 *   - Never throws back to Claude; all errors land in spawn.log.
 *   - Skips silently if PR cannot be parsed (e.g. user ran `gh pr create --help`).
 */

import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync, renameSync, openSync, closeSync, unlinkSync, statSync } from "fs";
import { spawn } from "child_process";
import { homedir } from "os";
import { join } from "path";

const PAI = join(homedir(), ".claude", "PAI", "MEMORY", "PR_WATCH");
const ACTIVE = join(PAI, "active.json");
const ACTIVE_LOCK = join(PAI, "active.json.lock");
const QUEUE = join(PAI, "queue.jsonl");
const SPAWN_LOG = join(PAI, "spawn.log");
const WATCHER = join(homedir(), ".claude", "PAI", "TOOLS", "WatchPRReviews.ts");
const LOCK_STALE_MS = 30_000; // any lockfile older than this is presumed crashed

interface ActiveEntry {
  pr: number;
  repo: string;
  pid: number;
  started_at: string;
  log_path: string;
}

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  tool_response?: unknown;
}

function logDiag(msg: string): void {
  try {
    if (!existsSync(PAI)) mkdirSync(PAI, { recursive: true });
    appendFileSync(SPAWN_LOG, `${new Date().toISOString()} ${msg}\n`);
  } catch {
    /* swallow */
  }
}

function readActive(): ActiveEntry[] {
  try {
    if (!existsSync(ACTIVE)) return [];
    const raw = readFileSync(ACTIVE, "utf8").trim();
    if (!raw) return [];
    return JSON.parse(raw) as ActiveEntry[];
  } catch (e) {
    logDiag(`readActive failed: ${(e as Error).message}`);
    return [];
  }
}

function writeActive(entries: ActiveEntry[]): void {
  // Atomic write: tmp file + rename. Same-fs rename is atomic on Linux,
  // so a concurrent reader never sees a half-written file. Concurrent
  // writers are serialized one level up by withActiveLock.
  try {
    const tmp = `${ACTIVE}.tmp.${process.pid}`;
    writeFileSync(tmp, JSON.stringify(entries, null, 2) + "\n");
    renameSync(tmp, ACTIVE);
  } catch (e) {
    logDiag(`writeActive failed: ${(e as Error).message}`);
  }
}

async function withActiveLock<T>(fn: () => Promise<T> | T): Promise<T> {
  // Cooperative file lock around RMW of active.json. `openSync(path, 'wx')`
  // throws EEXIST if the file already exists, which is our test-and-set.
  // Stale lockfile (older than LOCK_STALE_MS) is auto-removed on next try
  // so a crashed prior holder doesn't wedge the system.
  const start = Date.now();
  let held = false;
  let fd: number | null = null;
  while (Date.now() - start < 2_000) {
    try {
      fd = openSync(ACTIVE_LOCK, "wx");
      writeFileSync(fd, String(process.pid));
      held = true;
      break;
    } catch {
      // Either lock is held or stale. Check age.
      try {
        const s = statSync(ACTIVE_LOCK);
        if (Date.now() - s.mtimeMs > LOCK_STALE_MS) {
          logDiag(`active.json.lock stale (${Date.now() - s.mtimeMs}ms), removing`);
          unlinkSync(ACTIVE_LOCK);
          continue;
        }
      } catch {
        // lock vanished between attempts; loop again
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }
  if (!held) {
    // Lock timeout — DO NOT proceed with unlocked RMW. Same reasoning as
    // the watcher's removeFromActive (Codex P2): an unlocked write could
    // overwrite a competing locked write and drop live entries. Skip this
    // spawn opportunity; reapDead on the next hook tick will catch any
    // dead entries left behind, and the user can manually invoke Monitor
    // as a fallback. (If lock contention persists past 2s the system has
    // a deeper problem worth surfacing in spawn.log.)
    logDiag("active.json.lock acquire timed out — skipping spawn (no unlocked write)");
    return undefined as unknown as T;
  }
  try {
    return await fn();
  } finally {
    if (fd !== null) {
      try { closeSync(fd); } catch { /* ignore */ }
    }
    if (held) {
      try { unlinkSync(ACTIVE_LOCK); } catch { /* ignore */ }
    }
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function reapDead(entries: ActiveEntry[]): ActiveEntry[] {
  const live = entries.filter((e) => pidAlive(e.pid));
  if (live.length !== entries.length) {
    logDiag(`reaped ${entries.length - live.length} dead watcher entries`);
  }
  return live;
}

interface PRRef {
  owner: string;
  repo: string;
  pr: number;
}

function parsePRUrl(s: string | undefined): PRRef | null {
  if (!s) return null;
  const m = s.match(/https?:\/\/github\.com\/([^/\s]+)\/([^/\s]+)\/pull\/(\d+)/);
  if (!m) return null;
  return { owner: m[1], repo: m[2], pr: Number(m[3]) };
}

function extractPRFromBash(input: Record<string, unknown> | undefined, response: unknown): PRRef | null {
  const cmd = (input?.command as string) ?? "";
  if (!/\bgh\s+pr\s+create\b/.test(cmd)) return null;
  // gh pr create prints the PR URL to stdout on success.
  const stdout = readToolStdout(response);
  return parsePRUrl(stdout);
}

function readToolStdout(response: unknown): string {
  if (!response) return "";
  if (typeof response === "string") return response;
  if (typeof response === "object" && response !== null) {
    const r = response as Record<string, unknown>;
    if (typeof r.stdout === "string") return r.stdout;
    // claude code Bash tool wraps content in {output: ...} on some shapes
    if (typeof r.output === "string") return r.output;
  }
  return "";
}

function extractPRFromMCP(toolName: string, response: unknown): PRRef | null {
  if (toolName !== "mcp__github__create_pull_request") return null;
  if (!response || typeof response !== "object") return null;
  const r = response as Record<string, unknown>;
  // MCP github tools return shapes that vary by server version:
  //   - top-level {html_url, number, ...}
  //   - top-level {url, number, ...} (some shims rename html_url)
  //   - {structuredContent: {html_url|url, ...}} (newer MCP convention)
  //   - {content: [{type:"text", text:"...PR URL..."}]}
  // Try each in order.
  const tryString = (s: unknown): PRRef | null =>
    typeof s === "string" ? parsePRUrl(s) : null;

  const direct = tryString(r.html_url) ?? tryString(r.url);
  if (direct) return direct;

  if (r.structuredContent && typeof r.structuredContent === "object") {
    const sc = r.structuredContent as Record<string, unknown>;
    const found = tryString(sc.html_url) ?? tryString(sc.url);
    if (found) return found;
  }

  if (Array.isArray(r.content)) {
    for (const item of r.content) {
      if (typeof item === "object" && item !== null) {
        const i = item as Record<string, unknown>;
        const found = tryString(i.text);
        if (found) return found;
      }
    }
  }
  return null;
}

function spawnWatcher(ref: PRRef): Promise<ActiveEntry | null> {
  const repoSlug = `${ref.owner}/${ref.repo}`;
  const logPath = join(PAI, `watcher-${ref.owner}-${ref.repo}-${ref.pr}.log`);
  return new Promise<ActiveEntry | null>((resolve) => {
    try {
      // Use bash -c so nohup + redirection + & detach cleanly. We do NOT
      // double-fork ourselves; the shell handles it.
      const cmd = [
        "nohup",
        "bun",
        WATCHER,
        "--pr",
        String(ref.pr),
        "--repo",
        repoSlug,
        "--notify",
        "--queue",
        QUEUE,
        "--active",
        ACTIVE,
        "--quiet-once",
      ]
        .map((p) => (/[\s"']/.test(p) ? `'${p.replace(/'/g, "'\\''")}'` : p))
        .join(" ");

      const child = spawn("bash", ["-c", `${cmd} >>'${logPath.replace(/'/g, "'\\''")}' 2>&1 &  echo $!`], {
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
      });

      let pidOut = "";
      child.stdout?.on("data", (d) => (pidOut += d.toString()));

      const settle = (): void => {
        const pid = Number(pidOut.trim().split("\n").pop());
        if (!Number.isFinite(pid) || pid <= 0) {
          logDiag(`spawnWatcher: failed to capture PID for ${repoSlug}#${ref.pr}, output=${pidOut.slice(0, 200)}`);
          try { child.unref(); } catch { /* ignore */ }
          resolve(null);
          return;
        }
        try { child.unref(); } catch { /* ignore */ }
        resolve({
          pr: ref.pr,
          repo: repoSlug,
          pid,
          started_at: new Date().toISOString(),
          log_path: logPath,
        });
      };

      // Resolve on the bash subshell's exit (or its stdout EOF) — both
      // signal that `echo $!` has flushed. Fall back to a 1s timeout so a
      // hung subshell can never wedge the hook.
      let settled = false;
      const wrap = (): void => {
        if (settled) return;
        settled = true;
        settle();
      };
      child.on("exit", wrap);
      child.stdout?.on("end", wrap);
      const guard = setTimeout(wrap, 1000);
      child.on("error", (e) => {
        clearTimeout(guard);
        if (settled) return;
        settled = true;
        logDiag(`spawnWatcher error: ${e.message}`);
        try { child.unref(); } catch { /* ignore */ }
        resolve(null);
      });
    } catch (e) {
      logDiag(`spawnWatcher threw: ${(e as Error).message}`);
      resolve(null);
    }
  });
}

async function main(): Promise<void> {
  // Drain stdin
  let raw = "";
  try {
    for await (const chunk of process.stdin) raw += chunk;
  } catch {
    /* ignore */
  }

  let input: HookInput = {};
  try {
    input = JSON.parse(raw || "{}") as HookInput;
  } catch {
    return;
  }

  const tool = input.tool_name ?? "";
  let ref: PRRef | null = null;
  if (tool === "Bash") ref = extractPRFromBash(input.tool_input, input.tool_response);
  else if (tool === "mcp__github__create_pull_request") ref = extractPRFromMCP(tool, input.tool_response);

  if (!ref) return;

  if (!existsSync(PAI)) mkdirSync(PAI, { recursive: true });
  const repoSlug = `${ref.owner}/${ref.repo}`;

  // Whole RMW-and-spawn under the lock so two concurrent hook firings can't
  // both pass the idempotency check and double-spawn.
  await withActiveLock(async () => {
    let active = reapDead(readActive());
    if (active.some((e) => e.pr === ref!.pr && e.repo === repoSlug && pidAlive(e.pid))) {
      logDiag(`already watching ${repoSlug}#${ref!.pr}, skipping spawn`);
      writeActive(active);
      return;
    }
    const entry = await spawnWatcher(ref!);
    if (!entry) {
      logDiag(`spawn failed for ${repoSlug}#${ref!.pr}`);
      writeActive(active);
      return;
    }
    active.push(entry);
    writeActive(active);
    logDiag(`spawned watcher for ${repoSlug}#${ref!.pr} pid=${entry.pid}`);
  });
}

main().catch((e) => {
  logDiag(`hook fatal: ${(e as Error).message}`);
  process.exit(0); // never block tool flow
});
