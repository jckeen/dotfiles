#!/usr/bin/env bun
/**
 * WatchPRReviews.ts — Monitor-friendly watcher for GitHub PR review activity
 *
 * Designed to run inside the Monitor tool. Polls a GitHub PR every
 * INTERVAL_S seconds and emits one stdout line per *new* event since
 * the last poll. Each line becomes a Monitor notification.
 *
 * What it watches (all dedup'd by id, so each event fires exactly once):
 *   - PR-level reviews (chatgpt-codex-connector, human reviewers, etc.)
 *   - Inline review comments (line-pinned suggestions)
 *   - Issue-level comments (@codex review pings, free-form discussion)
 *   - CI check rollup (transitions: pending → success | failure)
 *   - PR state changes (open → merged | closed)
 *
 * Usage (inside the Monitor tool):
 *   Monitor({
 *     description: "PR #123 review activity",
 *     persistent: true,
 *     timeout_ms: 3600000,
 *     command: "bun $HOME/.claude/PAI/TOOLS/WatchPRReviews.ts --pr 123"
 *   })
 *
 * From within a repo with `gh` configured, --repo is auto-detected. To
 * watch another repo:
 *   bun WatchPRReviews.ts --pr 18 --repo jckeen/atlas
 *
 * Output format (stable; one line per event):
 *   [<kind>] PR #<num> <repo> | <one-line summary>
 *
 * Filters:
 *   --no-ci       Don't emit CI rollup transitions
 *   --no-bots     Don't emit bot reviews/comments (e.g. for human-only watch)
 *   --bots-only   Only emit bot activity (Codex, Dependabot, etc.)
 *   --interval N  Poll every N seconds (default 30; min 10)
 *   --quiet-once  Don't emit a startup snapshot of pre-existing state
 *
 * Exit:
 *   0  Clean shutdown (PR merged or closed; we stop watching)
 *   2  Misconfigured (bad args, gh not authed)
 *   nonzero on uncaught error
 *
 * Robustness:
 *   - All gh failures are logged at debug and the watcher keeps polling.
 *     A transient API hiccup never kills the watch.
 *   - Dedup uses GitHub-assigned numeric ids; safe across `gh`/PR rebases.
 */

import { execSync, spawnSync, spawn } from "child_process";
import { appendFileSync, readFileSync, writeFileSync, existsSync } from "fs";

interface Args {
  pr: number;
  repo: string;
  intervalS: number;
  includeCI: boolean;
  includeBots: boolean;
  botsOnly: boolean;
  quietOnce: boolean;
  notify: boolean;
  queuePath: string | null;
  activePath: string | null;
}

function parseArgs(argv: string[]): Args {
  let pr: number | null = null;
  let repo: string | null = null;
  let intervalS = 30;
  let includeCI = true;
  let includeBots = true;
  let botsOnly = false;
  let quietOnce = false;
  let notify = false;
  let queuePath: string | null = null;
  let activePath: string | null = null;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--pr") pr = Number(argv[++i]);
    else if (a === "--repo") repo = argv[++i];
    else if (a === "--interval") intervalS = Math.max(10, Number(argv[++i]));
    else if (a === "--no-ci") includeCI = false;
    else if (a === "--no-bots") includeBots = false;
    else if (a === "--bots-only") botsOnly = true;
    else if (a === "--quiet-once") quietOnce = true;
    else if (a === "--notify") notify = true;
    else if (a === "--queue") queuePath = argv[++i];
    else if (a === "--active") activePath = argv[++i];
    else if (a === "-h" || a === "--help") {
      process.stderr.write(
        "Usage: WatchPRReviews --pr <num> [--repo owner/repo] [--interval 30]\n" +
          "  [--no-ci] [--no-bots|--bots-only] [--quiet-once]\n" +
          "  [--notify]                # POST each event line to localhost:31337/notify (banner only)\n" +
          "  [--queue <path>]          # Append each event as JSONL {ts,kind,pr,repo,line} to <path>\n" +
          "  [--active <path>]         # On terminal state, remove our entry from <active.json>\n",
      );
      process.exit(0);
    }
  }

  if (pr === null || Number.isNaN(pr)) {
    process.stderr.write("WatchPRReviews: --pr <number> is required\n");
    process.exit(2);
  }

  if (repo === null) {
    try {
      const out = execSync("gh repo view --json nameWithOwner -q .nameWithOwner", {
        stdio: ["ignore", "pipe", "pipe"],
      })
        .toString()
        .trim();
      if (!out) throw new Error("empty");
      repo = out;
    } catch {
      process.stderr.write(
        "WatchPRReviews: --repo not given and could not infer from cwd. " +
          "Run inside a gh-configured repo or pass --repo owner/name.\n",
      );
      process.exit(2);
    }
  }

  if (botsOnly) includeBots = true;

  return { pr, repo, intervalS, includeCI, includeBots, botsOnly, quietOnce, notify, queuePath, activePath };
}

function ghJson<T>(args: string[]): T | null {
  // Run a `gh api` (or `gh pr`) call returning JSON. Returns null on any
  // failure (network blip, rate limit, transient 5xx). The caller's only
  // concern is "do I have data right now"; absent data → skip this tick.
  const proc = spawnSync("gh", args, { encoding: "utf8" });
  if (proc.status !== 0 || !proc.stdout) return null;
  try {
    return JSON.parse(proc.stdout) as T;
  } catch {
    return null;
  }
}

function isBot(login: string): boolean {
  return /\[bot\]$/i.test(login) || /-(bot|connector)$/i.test(login);
}

function emit(line: string): void {
  // One stdout line = one Monitor notification. Keep them tight.
  process.stdout.write(line.replace(/\s+$/, "") + "\n");
}

function notifyPush(line: string): void {
  // Fire-and-forget banner (voice_enabled:false — voice every event would be too loud).
  // Detached + unref'd so a hung notify server cannot block the polling loop.
  try {
    const body = JSON.stringify({ message: line, voice_enabled: false });
    const child = spawn(
      "curl",
      [
        "-s",
        "--max-time",
        "1",
        "-X",
        "POST",
        "http://localhost:31337/notify",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
      ],
      { stdio: "ignore", detached: true },
    );
    child.unref();
    child.on("error", () => {});
  } catch {
    // notify is best-effort; never let it kill the watcher
  }
}

function appendQueue(queuePath: string, kind: string, pr: number, repo: string, line: string): void {
  // Append-only JSONL — surface hooks tail this file via byte-cursor.
  try {
    const row = JSON.stringify({
      ts: new Date().toISOString(),
      kind,
      pr,
      repo,
      line,
    });
    appendFileSync(queuePath, row + "\n");
  } catch {
    // best-effort
  }
}

function removeFromActive(activePath: string, pr: number, repo: string): void {
  // Read-modify-write of active.json on terminal state. Single watcher per
  // (repo, pr) so the no-lock race is bounded by hook spawn frequency.
  try {
    if (!existsSync(activePath)) return;
    const raw = readFileSync(activePath, "utf8").trim();
    if (!raw) return;
    const arr = JSON.parse(raw) as Array<{ pr: number; repo: string; pid: number }>;
    const next = arr.filter((e) => !(e.pr === pr && e.repo === repo));
    writeFileSync(activePath, JSON.stringify(next, null, 2) + "\n");
  } catch {
    // best-effort — auto-launch hook reaps stale entries on next tick
  }
}

function kindFromLine(line: string): string {
  const m = line.match(/^\[([^\]]+)\]/);
  return m ? m[1] : "unknown";
}

function firstLine(s: string): string {
  return (s ?? "").split("\n")[0].slice(0, 200);
}

interface ReviewRow {
  id: number;
  user: { login: string };
  state: string;
  submitted_at: string;
  commit_id: string;
  body: string;
}
interface CommentRow {
  id: number;
  user: { login: string };
  body: string;
  path?: string;
  line?: number;
  commit_id?: string;
  created_at: string;
}
interface PRView {
  state: "OPEN" | "MERGED" | "CLOSED";
  mergeStateStatus: string;
  reviewDecision: string;
  headRefOid: string;
  statusCheckRollup: Array<{ name: string; conclusion: string; status: string }>;
}

const TERMINAL_STATES: ReadonlySet<string> = new Set(["MERGED", "CLOSED"]);
const FINAL_CI: ReadonlySet<string> = new Set([
  "SUCCESS",
  "FAILURE",
  "CANCELLED",
  "TIMED_OUT",
  "ACTION_REQUIRED",
  "STARTUP_FAILURE",
]);

function ciSummary(rollup: PRView["statusCheckRollup"] | undefined): string {
  if (!rollup || rollup.length === 0) return "no-checks";
  const counts: Record<string, number> = {};
  for (const c of rollup) {
    const k = (c.conclusion || c.status || "UNKNOWN").toUpperCase();
    counts[k] = (counts[k] || 0) + 1;
  }
  return Object.entries(counts)
    .sort()
    .map(([k, v]) => `${k}=${v}`)
    .join(",");
}

function ciAllFinal(rollup: PRView["statusCheckRollup"] | undefined): boolean {
  if (!rollup || rollup.length === 0) return false;
  return rollup.every((c) => FINAL_CI.has((c.conclusion || "").toUpperCase()));
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const tag = `PR #${args.pr} ${args.repo}`;

  const seenReviews = new Set<number>();
  const seenComments = new Set<number>();
  const seenIssueComments = new Set<number>();
  let lastCISummary: string | null = null;
  let lastState: string | null = null;
  let firstPoll = true;

  const record = (line: string): void => {
    // Wraps emit() to also push notify + append queue when those flags are set.
    // We keep emit() as the stdout primitive so existing Monitor invocations
    // (without --notify / --queue) behave identically.
    emit(line);
    const kind = kindFromLine(line);
    if (args.notify) notifyPush(line);
    if (args.queuePath) appendQueue(args.queuePath, kind, args.pr, args.repo, line);
  };

  record(`[startup] ${tag} watching every ${args.intervalS}s`);

  // Persistent loop. Monitor's persistent:true keeps us alive; we only
  // exit when the PR reaches a terminal state (merged/closed).
  while (true) {
    const reviews = ghJson<ReviewRow[]>([
      "api",
      `repos/${args.repo}/pulls/${args.pr}/reviews`,
    ]);
    const inlineComments = ghJson<CommentRow[]>([
      "api",
      `repos/${args.repo}/pulls/${args.pr}/comments`,
    ]);
    const issueComments = ghJson<CommentRow[]>([
      "api",
      `repos/${args.repo}/issues/${args.pr}/comments`,
    ]);
    const view = ghJson<PRView>([
      "pr",
      "view",
      String(args.pr),
      "--repo",
      args.repo,
      "--json",
      "state,mergeStateStatus,reviewDecision,headRefOid,statusCheckRollup",
    ]);

    const passesBotFilter = (login: string): boolean => {
      const bot = isBot(login);
      if (!args.includeBots && bot) return false;
      if (args.botsOnly && !bot) return false;
      return true;
    };

    if (reviews) {
      for (const r of reviews) {
        const known = seenReviews.has(r.id);
        seenReviews.add(r.id);
        if (known) continue;
        if (firstPoll && args.quietOnce) continue;
        if (!passesBotFilter(r.user.login)) continue;
        record(
          `[review] ${tag} ${r.state} by ${r.user.login} on ${r.commit_id.slice(0, 10)} | ${firstLine(r.body) || "(no body)"}`,
        );
      }
    }

    if (inlineComments) {
      for (const c of inlineComments) {
        const known = seenComments.has(c.id);
        seenComments.add(c.id);
        if (known) continue;
        if (firstPoll && args.quietOnce) continue;
        if (!passesBotFilter(c.user.login)) continue;
        const where = c.path ? `${c.path}:${c.line ?? "?"}` : "<file>";
        record(`[inline] ${tag} ${c.user.login} @ ${where} | ${firstLine(c.body)}`);
      }
    }

    if (issueComments) {
      for (const c of issueComments) {
        const known = seenIssueComments.has(c.id);
        seenIssueComments.add(c.id);
        if (known) continue;
        if (firstPoll && args.quietOnce) continue;
        if (!passesBotFilter(c.user.login)) continue;
        record(`[comment] ${tag} ${c.user.login} | ${firstLine(c.body)}`);
      }
    }

    if (view) {
      // CI rollup transitions: emit when the summary string changes,
      // not on every poll. Final-state transition gets a clearer line.
      if (args.includeCI) {
        const summary = ciSummary(view.statusCheckRollup);
        if (summary !== lastCISummary) {
          if (lastCISummary !== null) {
            const final = ciAllFinal(view.statusCheckRollup) ? " FINAL" : "";
            record(`[ci${final}] ${tag} ${lastCISummary} → ${summary}`);
          } else if (!firstPoll || !args.quietOnce) {
            record(`[ci] ${tag} ${summary}`);
          }
          lastCISummary = summary;
        }
      }

      // PR state transitions; merged or closed = we're done.
      if (lastState !== null && view.state !== lastState) {
        record(`[state] ${tag} ${lastState} → ${view.state}`);
      }
      lastState = view.state;

      if (TERMINAL_STATES.has(view.state)) {
        record(`[shutdown] ${tag} reached terminal state ${view.state}`);
        if (args.activePath) removeFromActive(args.activePath, args.pr, args.repo);
        process.exit(0);
      }
    }

    firstPoll = false;
    await new Promise((r) => setTimeout(r, args.intervalS * 1000));
  }
}

main().catch((err) => {
  process.stderr.write(`WatchPRReviews fatal: ${err}\n`);
  process.exit(1);
});
