#!/usr/bin/env bash
# PreMergeCodexHarvest.hook.sh — PreToolUse Bash guardrail. When a `gh pr merge` is
# about to run, first harvest the GitHub Codex-bot's inline PR review comments into
# tracked issues, so we never merge PAST the bot's asynchronous findings.
#
# TRIGGER (settings.json PreToolUse matcher: "Bash"):
#   tool_input.command matches /\bgh\s+pr\s+merge\b/
#
# BEHAVIOR:
#   Runs harvest-codex-comments.sh for the PR being merged (explicit number in the
#   command if present, else the current branch's PR). That script files one deduped
#   issue per Codex-bot comment. Output goes to stderr → visible in the Bash tool
#   output right before the merge proceeds.
#
# SAFETY:
#   - WARN-ONLY: always exit 0. Never blocks the merge (matches PrePushStaleSHACheck).
#   - Wrapped in `timeout` so a slow gh call can't wedge the merge.
#   - All errors swallowed; if gh/jq/the harvester are missing, it's a no-op.

set -uo pipefail

raw="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(jq -r '.tool_input.command // ""' <<<"$raw" 2>/dev/null || true)"
cwd="$(jq -r '.cwd // ""' <<<"$raw" 2>/dev/null || true)"

# Only act on `gh pr merge`.
[[ "$cmd" =~ gh[[:space:]]+pr[[:space:]]+merge ]] || exit 0

[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null || true

script="$HOME/.claude/scripts/harvest-codex-comments.sh"
[[ -x "$script" ]] || exit 0

# Explicit PR number (`gh pr merge 149 ...`) if given; otherwise the harvester
# resolves the current branch's PR.
prnum="$(grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' <<<"$cmd" | grep -oE '[0-9]+$' || true)"

if [[ -n "$prnum" ]]; then
  timeout 30 "$script" --pr "$prnum" --quiet >&2 2>&1 || true
else
  timeout 30 "$script" --quiet >&2 2>&1 || true
fi

exit 0
