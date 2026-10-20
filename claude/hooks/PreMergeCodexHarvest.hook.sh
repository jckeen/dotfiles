#!/usr/bin/env bash
# PreMergeCodexHarvest.hook.sh — PreToolUse Bash guardrail. When a `gh pr merge` is
# about to run, first harvest the GitHub Codex-bot's inline PR review comments into
# tracked issues, so we never merge PAST the bot's asynchronous findings.
#
# TRIGGER (settings.json PreToolUse matcher: "Bash", with "if": "Bash(gh pr merge*)"
#   in the public template): a segment of tool_input.command starts with
#   `gh pr merge` (after optional VAR=value assignments) — see the match below.
#
# BEHAVIOR:
#   Runs harvest-codex-comments.sh for the PR being merged (explicit number in the
#   command if present, else the current branch's PR). That script files one deduped
#   consolidated issue per PR, one checklist item per Codex-bot comment. Its output
#   is printed as one JSON object on stdout: `systemMessage` shows it to the user and
#   PreToolUse `additionalContext` shows it to Claude. Stderr from a hook that exits
#   0 goes to the debug log only, so it cannot carry the output (#593). Nothing to
#   report → empty stdout.
#
#   With `--auto` the command only arms auto-merge, usually within a minute of
#   `gh pr create` — before the bot has reviewed — so this early pass normally finds
#   nothing. The hook still runs it, then prints a one-line note that the
#   close-time harvest (.github/workflows/harvest-codex-comments.yml, on the PR's
#   merge) will file whatever the bot posts. The two passes share the harvester's
#   per-PR dedup, so running both never files twice (#555).
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

# Only act on an executed `gh pr merge`: some segment of the command (split
# on && || ; | & and newlines) must START with it, after optional whitespace
# and VAR=value assignments. An unanchored search fired on mere mentions such
# as `rg 'gh pr merge' .` and ran the issue-writing harvester (#681).
merge_seg=""
while IFS= read -r _seg; do
  if [[ "$_seg" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    merge_seg="$_seg"
    break
  fi
done < <(printf '%s\n' "$cmd" | tr ';|&' '\n\n\n')
[[ -n "$merge_seg" ]] || exit 0

# cwd is harness-supplied (the session's working dir), not prompt content — but
# only enter it if it's a real directory, and bail (no-op) rather than run the
# harvester from the wrong place if it isn't.
if [[ -n "$cwd" ]]; then
  [[ -d "$cwd" ]] && cd "$cwd" 2>/dev/null || exit 0
fi

script="$HOME/.claude/scripts/harvest-codex-comments.sh"
[[ -x "$script" ]] || exit 0

# Explicit PR number (`gh pr merge 149 ...`) if given; otherwise the harvester
# resolves the current branch's PR.
prnum="$(grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' <<<"$merge_seg" | grep -oE '[0-9]+$' || true)"

# Portable timeout: GNU `timeout` (Linux), `gtimeout` (macOS coreutils), else run
# without a ceiling rather than hard-fail on macOS.
tmo() {
  if   command -v timeout  >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"
  fi
}

# A non-numeric `gh pr merge <url|branch>` target leaves prnum empty; the harvester
# then resolves the current branch's PR, which is correct for the common merge but
# may miss a cross-branch merge-by-URL. Good enough for a warn-only capture.
if [[ -n "$prnum" ]]; then
  out="$(tmo 30 "$script" --pr "$prnum" --quiet 2>&1 || true)"
else
  out="$(tmo 30 "$script" --quiet 2>&1 || true)"
fi

if [[ "$merge_seg" =~ (^|[[:space:]])--auto([[:space:]=]|$) ]]; then
  out="${out:+$out
}PreMergeCodexHarvest: --auto arms the merge before the Codex bot has reviewed; the close-time harvest (harvest-codex-comments.yml) will file anything it finds."
fi

if [[ -n "$out" ]]; then
  jq -n --arg m "$out" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$m}}' \
    2>/dev/null || true
fi

exit 0
