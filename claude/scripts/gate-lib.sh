#!/usr/bin/env bash
# gate-lib.sh — shared plumbing for the review gates (#200).
#
# Sourced (never executed) by codex-review-gate.sh and antigravity-review-gate.sh
# to hold the logic that used to be maintained twice under "mirrors the other
# gate" comments: base resolution, diff-target selection, the pathspec filters,
# the untracked-file append, hash fencing, and the portable timeout wrapper.
# A fix here lands in both gates at once.
#
# Locating this file: each gate sources it from its own directory —
#   . "$(dirname "${BASH_SOURCE[0]}")/gate-lib.sh"
# which resolves in BOTH install locations because setup.sh symlinks every
# claude/scripts/*.sh (this file included) side-by-side into ~/.claude/scripts.
#
# Conventions: functions communicate through the caller's globals (BASE,
# BASE_REF, DIFF_TARGET, TARGET_DESC, DIFF_CONTENT, …) — the same variables the
# inline code used — and call the caller-defined degrade() for tool-can't-run
# cases, so each gate keeps its own degrade-open policy and messaging.

# shellcheck shell=bash

# ─── Colored line printers ─────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Base resolution ───────────────────────────────────────────
# gate_resolve_base — resolve the caller's $BASE (possibly empty) to $BASE_REF.
# Empty BASE defaults to origin/HEAD's branch, then "main". BASE_REF prefers
# the remote-tracking ref (a local `main` is often stale relative to
# `origin/main`; reviewing against a stale base would diff in already-merged
# commits or omit real ones) and falls back to the local ref for remote-less
# repos. BASE_REF stays empty when neither exists — the caller decides whether
# that degrades (codex gate) or fails closed (antigravity gate, #153).
gate_resolve_base() {
  if [[ -z "$BASE" ]]; then
    # `|| true`: in clones without origin/HEAD the symbolic-ref pipeline fails,
    # and under `set -euo pipefail` that would abort the gate before the `main`
    # fallback below — so swallow it and let the fallback run.
    BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    [[ -z "$BASE" ]] && BASE="main"
  fi
  BASE_REF=""
  if git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
    BASE_REF="origin/$BASE"
  elif git rev-parse --verify --quiet "$BASE" >/dev/null; then
    BASE_REF="$BASE"
  fi
  return 0
}

# ─── Delta detection ───────────────────────────────────────────
# gate_compute_deltas — set has_committed_delta / has_uncommitted from BASE_REF.
gate_compute_deltas() {
  has_committed_delta=false
  if [[ -n "$BASE_REF" ]] && [[ -n "$(git rev-list --max-count=1 "$BASE_REF..HEAD" 2>/dev/null)" ]]; then
    has_committed_delta=true
  fi
  has_uncommitted=false
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && has_uncommitted=true
  return 0
}

# ─── Diff-target selection ─────────────────────────────────────
# gate_select_diff_target — set DIFF_TARGET + TARGET_DESC from the flags above.
# Prefer the committed delta vs the base branch — that is exactly what the PR
# will contain, and it ignores unrelated unstaged/untracked WIP left in the
# tree (the workflow stages specific files, never `git add -A`). Fall back to
# the working tree only when there's no committed delta yet, or when
# --uncommitted was passed explicitly.
# Exits 0 itself when there is genuinely nothing to review; calls the caller's
# degrade() when the target can't be established.
gate_select_diff_target() {
  DIFF_TARGET=()
  TARGET_DESC=""
  if [[ "$FORCE_UNCOMMITTED" == "true" ]]; then
    [[ "$has_uncommitted" == "true" ]] || degrade "no uncommitted changes to review."
    DIFF_TARGET=("HEAD")
    TARGET_DESC="uncommitted working-tree changes (forced)"
  elif [[ "$has_committed_delta" == "true" ]]; then
    DIFF_TARGET=("$BASE_REF...HEAD")
    TARGET_DESC="committed changes vs $BASE_REF"
  elif [[ "$has_uncommitted" == "true" ]]; then
    DIFF_TARGET=("HEAD")
    # shellcheck disable=SC2034  # TARGET_DESC is read by the gate scripts that source this lib
    TARGET_DESC="uncommitted changes (no committed delta vs ${BASE_REF:-base})"
  else
    # Reached only with no uncommitted changes and no committed delta. That is
    # genuinely "nothing to review" ONLY if the base actually resolved — if it
    # didn't, has_committed_delta is false because we couldn't diff, not
    # because the branch matches base, so reporting success would silently
    # bypass the gate for committed work.
    [[ -n "$BASE_REF" ]] || degrade "base '$BASE' could not be resolved; cannot verify the committed delta."
    green "✓ HEAD matches $BASE_REF and no uncommitted changes — nothing to review."
    exit 0
  fi
  return 0
}

# ─── Diff extraction + filtering ───────────────────────────────
# gate_extract_diff — set DIFF_CONTENT for "${DIFF_TARGET[@]}". Excludes
# dependency lockfiles and binary/minified assets via git pathspecs — no review
# value, and they burn quota + the line budget. `git diff HEAD` omits untracked
# files, so a brand-new file would go unreviewed in an uncommitted review
# (#150) — append them as added-file diffs, respecting .gitignore and the same
# asset/lockfile exclusions as the tracked diff.
# --no-renames: rename detection would collapse `git mv risk-surface.sh
# notes.md` into a near-empty R100 hunk listed only under the DESTINATION
# path, letting a rename launder a risk surface past the tier valve and the
# self-review guard while shrinking its content out of the review. Renames
# are reviewed as full delete+add instead.
gate_extract_diff() {
  DIFF_CONTENT="$(git diff --no-renames "${DIFF_TARGET[@]}" -- \
    ':!*-lock.yaml' ':!*-lock.json' ':!package-lock.json' ':!*.lock' ':!bun.lockb' \
    ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.pdf' \
    ':!*.min.js' ':!*.min.css' ':!*.map' \
    2>/dev/null)"
  if [[ "${DIFF_TARGET[0]}" == "HEAD" ]]; then
    local f ut
    while IFS= read -r -d '' f; do
      case "$f" in
        *-lock.yaml|*-lock.json|*.lock|bun.lockb|\
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.pdf|*.min.js|*.min.css|*.map) continue ;;
      esac
      # --no-index exits 1 when files differ (always, for a new file) — swallow it.
      ut="$(git diff --no-index --no-color -- /dev/null "$f" 2>/dev/null || true)"
      [[ -n "$ut" ]] && DIFF_CONTENT+="${DIFF_CONTENT:+$'\n'}$ut"
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
  fi
  return 0
}

# gate_changed_paths — print the changed paths of "${DIFF_TARGET[@]}", one per
# line, including untracked files when reviewing the working tree. Used by the
# codex self-review guard and the tier valve. --no-renames so BOTH sides of a
# rename are listed and classified — otherwise `git mv` shows only the
# destination path and can launder a risk surface into a docs-only diff.
gate_changed_paths() {
  local p
  p="$(git diff --no-renames --name-only "${DIFF_TARGET[@]}" 2>/dev/null || true)"
  if [[ "${DIFF_TARGET[0]}" == "HEAD" ]]; then
    p+="${p:+$'\n'}$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  fi
  printf '%s\n' "$p"
}

# ─── Hash fencing ──────────────────────────────────────────────
# Portable hasher — sha1sum (Linux), shasum (macOS), cksum (POSIX fallback).
_hash() {
  if   command -v sha1sum >/dev/null 2>&1; then sha1sum
  elif command -v shasum  >/dev/null 2>&1; then shasum
  else cksum
  fi
}

# gate_fence <PREFIX> <content> — print "PREFIX_<16 hex>" where the suffix is
# derived from a hash of the content itself, so injected text inside the fenced
# content can't emit a matching closing marker.
gate_fence() {
  local prefix="$1"; shift
  printf '%s_%s' "$prefix" "$(printf '%s' "$*" | _hash | tr -cd '0-9a-f' | cut -c1-16)"
}

# ─── #212: proportionality valve ───────────────────────────────
# Not every diff earns the full adversarial pass. A cheap classifier — diff
# size + changed-path match against risk surfaces — picks the tier BEFORE any
# reviewer is dispatched:
#
#   Tier 1 (reduced): docs-only AND small (≤ GATE_TIER1_MAX_LINES, default
#     200). The gate may skip with a logged "tier-1 skip" line. Override with
#     GATE_FORCE_FULL=1 to run the full pass anyway.
#   Tier 2 (full): anything touching a risk surface, above the size cap, or
#     not positively classified. NEVER downgradable — no knob skips a tier-2
#     review.
#
# NAMED FAILURE MODE: the valve fails toward the FULL pass. Any classification
# error — unmeasurable diff, unenumerable changed paths, an unparseable size
# cap, an unknown file class — escalates to tier 2; nothing ever falls back to
# the skip.

# gate_path_is_risk <path> — 0 when the path is a risk surface: gate/hook/
# instruction/CI files (the surfaces that steer reviews — aligned with the
# codex self-review guard), plus the CLAUDE.md risk list (auth, path/host
# handling, file IO, schemas, hash chains) matched by path segment and
# filename keyword. Over-matching is fine (it only escalates); under-matching
# is what the docsafe allowlist below guards against.
gate_path_is_risk() {
  case "$1" in
    *AGENTS*.md|*CLAUDE*.md|*GEMINI*.md|*FABLE*.md|*MULTI-AGENT*.md|*SKILL.md|*AGENTPACK*) return 0 ;;
    codex/*|*/codex/*|antigravity/*|*/antigravity/*) return 0 ;;
    .github/*|*/.github/*|*hooks/*|*.githooks*|*scripts/*|setup.sh|*/setup.sh|install.sh|*/install.sh) return 0 ;;
    *schema*|*.sql|*migration*) return 0 ;;
  esac
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    # oauth is covered by *auth* (SC2221/SC2222), so it is not listed separately.
    *auth*|*token*|*secret*|*credential*|*password*|*session*|*sso*|*crypt*|*hash*|*host*) return 0 ;;
  esac
  return 1
}

# gate_path_is_docsafe <path> — 0 only for file classes with no runtime
# surface. Deliberately narrow: anything not on this allowlist is an unknown
# class and escalates to the full pass.
gate_path_is_docsafe() {
  case "$1" in
    *.md|*.markdown|*.rst|LICENSE|LICENSE.*|*/LICENSE|*/LICENSE.*) return 0 ;;
  esac
  return 1
}

# gate_classify_tier — set GATE_TIER (1 reduced / 2 full) + GATE_TIER_REASON
# from DIFF_CONTENT and the changed paths of "${DIFF_TARGET[@]}". Always
# returns 0; GATE_TIER=2 is the starting state and every early exit keeps it.
gate_classify_tier() {
  GATE_TIER=2
  GATE_TIER_REASON="full pass (default)"
  if [[ "${GATE_FORCE_FULL:-0}" == "1" ]]; then
    GATE_TIER_REASON="full pass (GATE_FORCE_FULL=1)"
    return 0
  fi
  local max="${GATE_TIER1_MAX_LINES:-200}" n paths f
  if ! [[ "$max" =~ ^[0-9]+$ ]]; then
    GATE_TIER_REASON="full pass (GATE_TIER1_MAX_LINES='$max' is not a number — escalating)"
    return 0
  fi
  n="$(printf '%s\n' "$DIFF_CONTENT" | wc -l | tr -d ' ' || true)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    GATE_TIER_REASON="full pass (could not measure the diff — escalating)"
    return 0
  fi
  if (( n > max )); then
    GATE_TIER_REASON="full pass (diff is $n lines > tier-1 cap $max)"
    return 0
  fi
  paths="$(gate_changed_paths)"
  if [[ -z "${paths//[[:space:]]/}" ]]; then
    GATE_TIER_REASON="full pass (could not enumerate changed paths — escalating)"
    return 0
  fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if gate_path_is_risk "$f"; then
      GATE_TIER_REASON="full pass (risk surface: $f)"
      return 0
    fi
    if ! gate_path_is_docsafe "$f"; then
      GATE_TIER_REASON="full pass (unclassified file: $f)"
      return 0
    fi
  done <<<"$paths"
  # shellcheck disable=SC2034  # GATE_TIER/GATE_TIER_REASON are read by the sourcing gate scripts
  GATE_TIER=1
  # shellcheck disable=SC2034
  GATE_TIER_REASON="docs-only diff, $n lines ≤ $max"
  return 0
}

# ─── #205: post-dispatch model verification (agy lane) ─────────
# agy's --model takes the exact DISPLAY LABEL from `agy models` (e.g.
# "Gemini 3.1 Pro (High)"). Slug forms (gemini-3.1-pro*, …) are silently
# ignored — exit 0, flash-tier fallback — which quietly collapses the
# "independent lineage" premise of the Antigravity lane (MULTI-AGENT.md).
# Two checks, layered:
#   1. gate_verify_agy_label — PRIMARY: parse the pin agy logged as propagated
#      to the backend. Deterministic; a mismatch means the run verifiably used
#      another model.
#   2. gate_verify_agy_model — SECONDARY, best-effort: spot-check the newest
#      conversation records for the label. Ground truth but racy (fresh runs
#      sit in the .db-wal; parallel conversations reorder mtimes).

# gate_verify_agy_label <requested-label> <agy-log-file>
# agy logs the model pin it hands to the backend as
#   model_config_manager.go] Propagating selected model override to backend: label="<label>"
# (format verified against agy 1.1.1). Compare the LAST propagated label to
# the requested one.
#   returns 0 — propagated label matches the request
#   returns 1 — propagated label DIFFERS: the pin failed; the run used another
#               model (callers should treat the review as invalid)
#   returns 2 — no propagation line (log missing/empty or format drift):
#               unverifiable, caller decides how loud to be
gate_verify_agy_label() {
  local want="$1" log="$2" line got
  [[ -s "$log" ]] || return 2
  line="$(grep -F 'Propagating selected model override to backend: label=' "$log" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 2
  # Extract the Go %q-quoted label, tolerating trailing fields after the
  # closing quote (e.g. `label="…" session=42`) — anything unextractable is
  # unverifiable (return 2), never a false mismatch.
  if [[ "$line" =~ label=\"([^\"]*)\" ]]; then
    got="${BASH_REMATCH[1]}"
  else
    return 2
  fi
  if [[ "$got" == "$want" ]]; then
    green "✓ model pin verified: agy propagated label \"$got\" to the backend."
    return 0
  fi
  red "✖ MODEL PIN FAILED: requested \"$want\" but agy propagated \"$got\" to the backend."
  return 1
}

# gate_verify_agy_model <requested-label>
#   returns 0 — a recent conversation record contains the label, or the check
#               is impossible (records/`strings` missing): impossibility
#               degrades to a warning rather than a false fallback verdict.
#   returns 1 — records exist but none of the newest mention the label.
# Tests override the records location via AGY_CONVERSATIONS_DIR.
gate_verify_agy_model() {
  local want="$1"
  local dir="${AGY_CONVERSATIONS_DIR:-$HOME/.gemini/antigravity-cli/conversations}"
  local files f
  # Newest-first ordering is what we need; the glob only ever matches agy's
  # own conversation files, so ls-parsing caveats don't apply. Include the
  # -wal files: a fresh run's records sit there until SQLite checkpoints.
  # shellcheck disable=SC2012
  files="$(ls -t "$dir"/*.db "$dir"/*.db-wal 2>/dev/null | head -n 3 || true)"
  if [[ -z "$files" ]]; then
    yellow "⚠ model DB spot-check: no conversation records under $dir — cannot confirm the recorded model (warning only)."
    return 0
  fi
  if ! command -v strings >/dev/null 2>&1; then
    yellow "⚠ model DB spot-check: 'strings' not found — cannot inspect the conversation records (warning only)."
    return 0
  fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if strings "$f" 2>/dev/null | grep -qF "$want"; then
      green "✓ model DB spot-check: $(basename "$f") records the requested label '$want'."
      return 0
    fi
  done <<<"$files"
  red "✖ model DB spot-check: none of the newest conversation records mention '$want' —"
  red "  the run may have fallen back to the default tier (see MULTI-AGENT.md)."
  return 1
}

# ─── Portable timeout ──────────────────────────────────────────
# _tmo — GNU `timeout` (Linux), `gtimeout` (macOS coreutils), else run without
# a ceiling rather than hard-fail on macOS (#151). Exit 124 (timed out) is only
# produced by the first two.
_tmo() {
  if   command -v timeout  >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"
  fi
}
