#!/usr/bin/env bun
/**
 * PrePushStaleSHACheck.hook.ts — PreToolUse Bash guardrail that warns when
 * `git push` is about to obsolete an in-flight Codex (or other reviewer)
 * review on the current branch's open PR.
 *
 * TRIGGER (settings.json PreToolUse matcher: "Bash"):
 *   tool_input.command matches /\bgit\s+push\b/
 *
 * BEHAVIOR:
 *   1. Resolve current working dir → repo + branch via `git`.
 *   2. Find the open PR for that branch via `gh pr view`.
 *   3. Fetch the latest review per reviewer; pull `reviewed_sha` from each
 *      review's `Reviewed commit:` body header (Codex's convention) or
 *      `commit_id` field. Compare against local HEAD.
 *   4. If any reviewer's reviewed_sha != HEAD: print a one-line
 *      `[stale-push]` warning to stderr so the user sees it inline with
 *      the Bash tool's output.
 *   5. NEVER block. Always exit 0. The warning is informational —
 *      legitimate fix-for-Codex pushes intentionally make the prior
 *      review stale.
 *
 * INPUT (stdin JSON, harness-supplied):
 *   { tool_name, tool_input, transcript_path, ... }
 *
 * OUTPUT: stderr only when stale; otherwise silent.
 *
 * SAFETY:
 *   - <500ms typical (one `gh pr view` call, one `git rev-parse`).
 *   - All errors swallowed → push always proceeds.
 *   - Skips when not in a git repo, no PR exists, no review on file,
 *     or `gh` is unavailable.
 */

import { spawnSync } from "child_process";

// Belt-and-suspenders: any unhandled rejection or sync exception STILL
// exits 0 so the push is never blocked by this hook (Forge MED).
process.on("unhandledRejection", () => process.exit(0));
process.on("uncaughtException", () => process.exit(0));

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  cwd?: string;
}

interface PRInfo {
  number: number;
  headRefOid: string;
  url: string;
  baseRefName: string;
  reviews: Array<{
    author: { login: string } | null;
    state: string;
    commit: { oid: string } | null;
    body: string;
    submittedAt: string;
  }>;
}

function gitOut(args: string[], cwd: string): string | null {
  const proc = spawnSync("git", args, { encoding: "utf8", cwd });
  if (proc.status !== 0) return null;
  return proc.stdout.trim();
}

function ghJson<T>(args: string[], cwd: string): T | null {
  const proc = spawnSync("gh", args, { encoding: "utf8", cwd });
  if (proc.status !== 0 || !proc.stdout) return null;
  try {
    return JSON.parse(proc.stdout) as T;
  } catch {
    return null;
  }
}

function reviewedShaFromBody(body: string): string | null {
  // Codex's formal review body decorates the marker with markdown:
  //   **Reviewed commit:** `3a3e0e197d`
  // The actual sha is *truncated to ~10 chars* in the body — `commit.oid`
  // from GraphQL gives the full 40-char value, so prefer that and treat
  // the body parse as fallback for non-Codex reviewers who happen to
  // include this header. Match anything (incl. ** and `) between the
  // marker and the hex sha.
  const m = body.match(/Reviewed commit:[^\n]*?([0-9a-f]{7,40})/i);
  return m ? m[1] : null;
}

function shasMatch(a: string, b: string): boolean {
  // SHA prefix-equality: GitHub frequently reports a short 7-10 char
  // prefix, while local HEAD is always full 40. Accept either side
  // being a prefix of the other.
  if (a === b) return true;
  if (a.length < b.length) return b.startsWith(a);
  return a.startsWith(b);
}

function emitStale(pr: number, repoSlug: string, reviewerLogin: string, reviewedSha: string, headSha: string): void {
  const line = `[stale-push] PR #${pr} ${repoSlug} ${reviewerLogin} reviewed ${reviewedSha.slice(0, 10)} but HEAD is ${headSha.slice(0, 10)} — ping \`@codex review\` after push`;
  // stderr lands in the Bash tool's user-visible output — gives me an
  // immediate signal at push time, not just on next prompt.
  process.stderr.write(`⚠️ STALE-REVIEW: ${line}\n`);
}

async function main(): Promise<void> {
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

  if (input.tool_name !== "Bash") return;
  const cmd = (input.tool_input?.command as string) ?? "";
  if (!/\bgit\s+push\b/.test(cmd)) return;

  // cwd from harness is the user's intended working dir; fallback to
  // process.cwd() inherits from the Claude Code session, which is
  // virtually always the same repo. The mismatch case (running in a
  // different shell context) is exotic — accept the small ambiguity.
  const cwd = input.cwd || process.cwd();

  // Are we even in a git repo? `git rev-parse` returns null on failure
  // because gitOut returns null when status != 0.
  const head = gitOut(["rev-parse", "HEAD"], cwd);
  if (!head) return;
  const branch = gitOut(["rev-parse", "--abbrev-ref", "HEAD"], cwd);
  if (!branch || branch === "HEAD") return; // detached head — no PR mapping

  // gh pr view defaults to "current branch's PR" when run inside the repo.
  // We ask for reviews + headRefOid + number. The GraphQL representation
  // includes commit.oid per review.
  const pr = ghJson<PRInfo>([
    "pr",
    "view",
    "--json",
    "number,headRefOid,url,baseRefName,reviews",
  ], cwd);
  if (!pr || !pr.number) return; // no PR for this branch

  const repoSlug = (() => {
    // pr.url is like "https://github.com/jckeen/dotfiles/pull/30"
    const m = pr.url?.match(/github\.com\/([^/]+)\/([^/]+)\//);
    return m ? `${m[1]}/${m[2]}` : "unknown/unknown";
  })();

  // Track most recent review per reviewer so multi-round Codex reviews
  // don't double-warn. submittedAt is ISO-8601, lex-sortable.
  const latestPerReviewer = new Map<string, PRInfo["reviews"][number]>();
  for (const r of pr.reviews ?? []) {
    const login = r.author?.login;
    if (!login) continue;
    const prev = latestPerReviewer.get(login);
    if (!prev || r.submittedAt > prev.submittedAt) {
      latestPerReviewer.set(login, r);
    }
  }

  let warnedAny = false;
  for (const [login, r] of latestPerReviewer) {
    // Prefer GraphQL commit.oid (full 40-char sha); body parse is the
    // fallback for non-Codex reviewers who follow the same convention
    // but where commit.oid is missing for some reason.
    const reviewedSha = r.commit?.oid ?? reviewedShaFromBody(r.body);
    if (!reviewedSha) continue;
    if (shasMatch(reviewedSha, head)) continue; // already up to date — no warn
    // Skip review states whose staleness is irrelevant: PENDING is a
    // draft the reviewer hasn't published; DISMISSED was explicitly
    // discarded.
    if (r.state === "PENDING" || r.state === "DISMISSED") continue;
    emitStale(pr.number, repoSlug, login, reviewedSha, head);
    warnedAny = true;
  }

  if (warnedAny) {
    process.stderr.write(
      "  └─ This push is intentional if you're addressing those findings. After it lands, ping `@codex review` so the reviewer re-runs against the new HEAD.\n",
    );
  }
}

main().catch((err) => {
  // Never block the push.
  process.stderr.write(`PrePushStaleSHACheck: ${err}\n`);
  process.exit(0);
});
