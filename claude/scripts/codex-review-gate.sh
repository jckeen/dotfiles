#!/usr/bin/env bash
# codex-review-gate.sh — run a local Codex review before a push/PR and gate on it.
#
# This is the concrete mechanism behind ADR-0003 ("Codex stop-gate review over a
# PR-comment-watching loop"). The commit-push-pr skill *referenced* a Codex
# review but never actually ran one; this script is that step. It is the local
# Codex capability we lean on to ship — review happens synchronously, in-session,
# before the change leaves the machine.
#
# Flow:
#   1. Pick the diff to review: working-tree changes if any are uncommitted,
#      otherwise the committed delta against the base branch (the PR contents).
#   2. Run `codex exec review`, capturing the review summary (the agent's last
#      message). Codex emits findings as prose tagged with a priority:
#        - [P0]/[P1]/[P2] <title> — <file>:<line>
#        - [P3] (and lower / untagged nits) are low severity.
#   3. Gate:
#        - BLOCK (exit 2) if any finding is P0/P1/P2 (critical/high/medium).
#        - For P3+ findings: open a GitHub issue per finding (deduped), so
#          nothing falls through the cracks, then exit 0.
#        - Clean review: exit 0.
#
# Degrade-open (exit 0 + loud warning, never a hard block) when the tool itself
# can't run — Codex not installed, not authenticated, network error, or no
# parseable summary. A Codex outage must not wedge every push. Set
# CODEX_GATE_REQUIRED=1 to turn those degraded cases into hard failures (exit 3).
#
# Usage:
#   codex-review-gate.sh [--base <branch>] [--no-issues] [--dry-run] [--require]
#
# Exit codes:
#   0  clean, or only P3+ findings (filed as issues)
#   2  blocking findings present (P0/P1/P2) — do NOT push
#   3  tool could not run AND CODEX_GATE_REQUIRED / --require was set

set -euo pipefail

# ─── Colors ────────────────────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Args ──────────────────────────────────────────────────────
BASE=""
FILE_ISSUES=true
DRY_RUN=false
FORCE_UNCOMMITTED=false
REQUIRED="${CODEX_GATE_REQUIRED:-0}"
MAX_ISSUES="${CODEX_GATE_MAX_ISSUES:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)        BASE="$2"; shift 2 ;;
    --uncommitted) FORCE_UNCOMMITTED=true; shift ;;
    --no-issues)   FILE_ISSUES=false; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --require)     REQUIRED=1; shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *)             red "Unknown arg: $1 (try --help)"; exit 64 ;;
  esac
done

# Degrade-open helper: warn, and only hard-fail if the gate is REQUIRED.
degrade() {
  yellow "⚠ codex-review-gate: $1"
  if [[ "$REQUIRED" == "1" ]]; then
    red "  CODEX_GATE_REQUIRED is set — treating as a hard failure."
    exit 3
  fi
  yellow "  Degrading open (not blocking the push). Review manually if this matters."
  exit 0
}

command -v codex >/dev/null 2>&1 || degrade "codex CLI not found on PATH."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || degrade "not inside a git work tree."

# ─── Pick the review target ────────────────────────────────────
# Prefer the committed delta vs the base branch — that is exactly what the PR
# will contain, and it ignores unrelated unstaged/untracked WIP left in the tree
# (the workflow stages specific files, never `git add -A`, so reviewing all
# uncommitted work would gate changes that aren't part of this commit). Fall back
# to --uncommitted only when there's no committed delta yet (pre-commit use), or
# when --uncommitted is passed explicitly.
REVIEW_ARGS=()
TARGET_DESC=""

# Resolve the base to a ref that actually exists. On feature branches / fresh
# clones the local `main` is often absent while `origin/main` is present.
if [[ -z "$BASE" ]]; then
  # `|| true`: in clones without origin/HEAD the symbolic-ref pipeline fails, and
  # under `set -euo pipefail` that would abort the script before the `main`
  # fallback below — so swallow it and let the fallback run.
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
  [[ -z "$BASE" ]] && BASE="main"
fi
# Prefer the remote-tracking ref: a local `main` is often stale relative to
# `origin/main`, and reviewing against a stale base would diff in already-merged
# commits or omit real ones. Fall back to the local ref for remote-less repos.
BASE_REF=""
if git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  BASE_REF="origin/$BASE"
elif git rev-parse --verify --quiet "$BASE" >/dev/null; then
  BASE_REF="$BASE"
fi

has_committed_delta=false
if [[ -n "$BASE_REF" ]] && [[ -n "$(git rev-list --max-count=1 "$BASE_REF..HEAD" 2>/dev/null)" ]]; then
  has_committed_delta=true
fi
has_uncommitted=false
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && has_uncommitted=true

if [[ "$FORCE_UNCOMMITTED" == "true" ]]; then
  [[ "$has_uncommitted" == "true" ]] || degrade "no uncommitted changes to review."
  REVIEW_ARGS=(--uncommitted)
  TARGET_DESC="uncommitted working-tree changes (forced)"
elif [[ "$has_committed_delta" == "true" ]]; then
  REVIEW_ARGS=(--base "$BASE_REF")
  TARGET_DESC="committed changes vs $BASE_REF"
elif [[ "$has_uncommitted" == "true" ]]; then
  REVIEW_ARGS=(--uncommitted)
  TARGET_DESC="uncommitted changes (no committed delta vs ${BASE_REF:-base})"
else
  # Reached here only with no uncommitted changes and no committed delta. That
  # is genuinely "nothing to review" ONLY if the base actually resolved — if it
  # didn't, has_committed_delta is false because we couldn't diff, not because
  # the branch matches base, so reporting success would silently bypass the gate
  # for committed work. Fail closed in that case.
  [[ -n "$BASE_REF" ]] || degrade "base '$BASE' could not be resolved; cannot verify the committed delta."
  green "✓ HEAD matches $BASE_REF and no uncommitted changes — nothing to review."
  exit 0
fi

bold "→ Codex review gate"
echo "  Reviewing: $TARGET_DESC"
echo ""

# ─── Run the review ────────────────────────────────────────────
SUMMARY_FILE="$(mktemp -t codex-review.XXXXXX.txt)"
ERR_FILE="$(mktemp -t codex-review-err.XXXXXX.txt)"
cleanup() { rm -f "$SUMMARY_FILE" "$ERR_FILE"; }
trap cleanup EXIT

# `-o` writes the agent's last message (the review summary). Note: the scoping
# flags (--uncommitted / --base) cannot be combined with a custom [PROMPT]
# positional, so we use Codex's default review instructions. codex exec returns
# non-zero when it surfaces findings; don't let that abort us.
set +e
codex exec review "${REVIEW_ARGS[@]}" \
  -o "$SUMMARY_FILE" >/dev/null 2>"$ERR_FILE"
CODEX_RC=$?
set -e

if [[ ! -s "$SUMMARY_FILE" ]]; then
  [[ -s "$ERR_FILE" ]] && { yellow "  codex stderr:"; sed 's/^/    /' "$ERR_FILE" | head -20; }
  degrade "Codex produced no review summary (rc=$CODEX_RC)."
fi

# ─── Parse findings from the summary prose ─────────────────────
# Findings look like:  - [P1] <title> — <file>:<line>
# Priority → severity:  P0/P1/P2 block;  P3 and lower are low/info → issues.
#
# Anchor to the finding-LINE shape (line start, optional bullet, then [P#]) so a
# priority label mentioned inside a finding's prose detail — or a clean verdict
# like "No [P0]/[P1]/[P2] findings" — is not miscounted as a blocking finding.
BLOCK_RE='^[[:space:]]*-?[[:space:]]*\[P[012]\]'
LOW_RE='^[[:space:]]*-?[[:space:]]*\[P[3-9]\]'
N_BLOCK="$(grep -cE "$BLOCK_RE" "$SUMMARY_FILE" || true)"
N_LOW="$(grep -cE "$LOW_RE" "$SUMMARY_FILE" || true)"
N_TOTAL=$((N_BLOCK + N_LOW))

echo "  Findings: $N_TOTAL total — $N_BLOCK blocking (P0–P2), $N_LOW low (P3+)"
echo ""

if [[ "$N_TOTAL" -eq 0 ]]; then
  # No anchored finding lines. Decide in this order:
  #
  # 1. Recognized clean verdict → clean. Phrasings that name the (absent)
  #    priority labels — e.g. "No [P0]/[P1]/[P2] findings" — count, by allowing
  #    up to ~40 chars between "no" and the noun. Checked FIRST so a clean
  #    verdict that mentions labels isn't mistaken for format drift below.
  # 2. Otherwise, if [P#] tokens appear but on no recognizable finding line
  #    (e.g. a future build emits JSON with "title":"[P1] …"), our parser can't
  #    see them — fail closed (degrade / hard-fail when required), never clean.
  # 3. Otherwise the summary is unparseable → fail closed.
  if grep -qiE 'no.{0,40}(issue|finding|problem|concern|bug|blocking)|(did not|do not|could not|no).{0,30}(find|identif|surfac|spot|see)|found no|looks good|lgtm|nothing to (flag|report)' "$SUMMARY_FILE"; then
    green "✓ Codex review clean — no findings. Safe to push."
    exit 0
  fi
  if grep -qE '\[P[0-9]\]' "$SUMMARY_FILE"; then
    # Priority tokens are present but on no recognizable finding line. With this
    # Codex version (0.128.0) `-o` emits PROSE with findings on `- [P#]` lines
    # (verified empirically), so this means the format drifted — there may be
    # real findings we can't read. BLOCK (fail closed), don't degrade open: a
    # gate that can't parse possible findings must stop the push, not wave it on.
    red "✖ Codex output not recognized — priority tokens present but unparseable:"
    sed 's/^/  /' "$SUMMARY_FILE"
    red "Push blocked: cannot confirm review is clean (possible format drift)."
    exit 2
  fi
  yellow "  Review summary (no [P#] findings, no recognizable clean verdict):"
  sed 's/^/    /' "$SUMMARY_FILE"
  degrade "Codex summary was not parseable as findings or a clean verdict."
fi

# Strip the leading "- [Pn] " marker and split "<title> — <loc>".
finding_title() { sed -E 's/^[[:space:]]*-?[[:space:]]*\[P[0-9]\][[:space:]]*//; s/ +—.*$//' <<<"$1"; }
finding_loc()   { sed -nE 's/.* — (.*)$/\1/p' <<<"$1"; }

# ─── P3+ → GitHub issues (don't let them fall through) ─────────
if [[ "$N_LOW" -gt 0 ]]; then
  yellow "Low findings (P3+):"
  grep -E "$LOW_RE" "$SUMMARY_FILE" | sed 's/^/  /'
  echo ""
  if [[ "$FILE_ISSUES" == "true" ]] && command -v gh >/dev/null 2>&1; then
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
    filed=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$filed" -ge "$MAX_ISSUES" ]] && { yellow "  (reached MAX_ISSUES=$MAX_ISSUES; remaining not filed)"; break; }
      title="$(finding_title "$line")"
      loc="$(finding_loc "$line")"
      issue_title="codex review: ${title}"
      # Dedupe: skip if an open issue with the same title already exists.
      if gh issue list --state open --search "in:title ${issue_title}" --json title \
           --jq '.[].title' 2>/dev/null | grep -qxF "$issue_title"; then
        echo "  ↷ exists, skipping: $issue_title"
        continue
      fi
      body="Filed automatically by codex-review-gate (low-priority Codex finding).

**Location:** \`${loc:-unspecified}\`
**Branch:** \`${branch}\`

${line}"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] would file issue: $issue_title"
      elif url="$(gh issue create --title "$issue_title" --body "$body" --label "codex-review" 2>/dev/null)"; then
        echo "  ✓ filed: $url"; filed=$((filed+1))
      elif url="$(gh issue create --title "$issue_title" --body "$body" 2>/dev/null)"; then
        echo "  ✓ filed (no label): $url"; filed=$((filed+1))
      else
        yellow "  ⚠ could not file issue: $issue_title"
      fi
    done < <(grep -E "$LOW_RE" "$SUMMARY_FILE")
  elif [[ "$FILE_ISSUES" == "true" ]]; then
    yellow "  (gh CLI not found — not filing issues; address the above manually)"
  fi
  echo ""
fi

# ─── Gate on blocking findings ─────────────────────────────────
if [[ "$N_BLOCK" -gt 0 ]]; then
  red "✖ BLOCKING findings (P0–P2) — do not push until these are addressed:"
  echo ""
  grep -E "$BLOCK_RE" "$SUMMARY_FILE" | sed 's/^/  /'
  echo ""
  red "Push blocked by codex-review-gate ($N_BLOCK P0–P2 finding(s))."
  echo "Full review summary:"
  sed 's/^/  /' "$SUMMARY_FILE"
  exit 2
fi

green "✓ Codex review clean of blocking findings — safe to push."
exit 0
