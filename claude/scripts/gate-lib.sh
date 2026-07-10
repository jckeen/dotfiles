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
gate_extract_diff() {
  DIFF_CONTENT="$(git diff "${DIFF_TARGET[@]}" -- \
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
# codex self-review guard.
gate_changed_paths() {
  local p
  p="$(git diff --name-only "${DIFF_TARGET[@]}" 2>/dev/null || true)"
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
