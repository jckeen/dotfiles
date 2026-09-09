#!/usr/bin/env bash
# gate-lib.sh — shared plumbing for the review gates (#200).
#
# Sourced by both gates for artifact capture, receipts, risk classification,
# hash fences, model dispatch evidence, and the portable timeout wrapper.
# Shared values intentionally live in the sourcing gate's globals.

# shellcheck shell=bash

# ─── Colored line printers ─────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Artifact capture and receipts ─────────────────────────────
# All content extraction belongs to the helper: even a normal worktree diff
# can execute a configured clean filter before --no-textconv takes effect.
gate_init_receipt() {
  RECEIPT_HELPER="$SCRIPT_DIR/review-receipt.py"
  command -v python3 >/dev/null 2>&1 || { red "Python 3 is required for artifact receipts."; exit 2; }
  [[ -f "$RECEIPT_HELPER" ]] || { red "Review receipt helper missing: $RECEIPT_HELPER"; exit 2; }
  python3 "$RECEIPT_HELPER" invalidate --repo . --reviewer "$GATE_REVIEWER" || exit 2
}

gate_resolve_base() {
  if [[ -z "$BASE" ]]; then
    BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    [[ -z "$BASE" ]] && BASE="main"
  fi
  BASE_REF=""
  if git rev-parse --verify --quiet --end-of-options "origin/$BASE^{commit}" >/dev/null; then
    BASE_REF="origin/$BASE"
  elif git rev-parse --verify --quiet --end-of-options "$BASE^{commit}" >/dev/null; then
    BASE_REF="$BASE"
  fi
  if [[ -z "$BASE_REF" && "$FORCE_UNCOMMITTED" != "true" ]]; then
    red "✖ Base '$BASE' could not be resolved; refusing a dirty fallback that omits committed work."
    exit 2
  fi
}

gate_select_diff_target() {
  GATE_SCOPE=auto
  [[ "$FORCE_UNCOMMITTED" == true ]] && GATE_SCOPE=uncommitted
  [[ "${FORCE_COMMITTED:-false}" == true ]] && GATE_SCOPE=committed
  return 0
}

gate_cleanup() {
  [[ -z "${GATE_RUN_DIR:-}" ]] || rm -rf -- "$GATE_RUN_DIR"
}

gate_extract_diff() {
  local args=(begin --repo . --scope "$GATE_SCOPE" --reviewer "$GATE_REVIEWER")
  [[ -z "$BASE_REF" ]] || args+=(--base "$BASE_REF")
  args+=(--executable "$(command -v "$GATE_CLI" || true)")
  args+=("--tier1-max-lines=${GATE_TIER1_MAX_LINES:-200}")
  GATE_RUN_DIR="$(python3 "$RECEIPT_HELPER" "${args[@]}")" || exit 2
  trap gate_cleanup EXIT
  # shellcheck disable=SC2034  # DIFF_CONTENT is consumed by both sourcing gates.
  DIFF_CONTENT="$(cat "$GATE_RUN_DIR/diff.patch")" || exit 2
  GATE_SCOPE="$(jq -r '.artifact.scope' "$GATE_RUN_DIR/snapshot.json")"
  # shellcheck disable=SC2034  # Read by the sourcing gates.
  TARGET_DESC="$GATE_SCOPE changes (pinned HEAD, base ${BASE_REF:-unused})"
}

gate_changed_paths() {
  jq -r '.artifact.changed_paths[]' "$GATE_RUN_DIR/snapshot.json"
}

gate_assert_unchanged() {
  python3 "$RECEIPT_HELPER" verify --snapshot "$GATE_RUN_DIR/snapshot.json" || exit 2
}

gate_record_pass() {
  local outcome="$1" output="${2:-}" args
  gate_assert_unchanged
  if [[ "${GATE_RECEIPT_ELIGIBLE:-1}" != 1 ]]; then
    yellow "⚠ No shipping receipt: reviewer dispatch identity was not verified."
    return 0
  fi
  args=(complete --snapshot "$GATE_RUN_DIR/snapshot.json" --outcome "$outcome")
  [[ -z "$output" ]] || args+=(--output "$output")
  [[ -z "${GATE_REQUESTED_MODEL:-}" ]] || args+=(--requested-model "$GATE_REQUESTED_MODEL")
  [[ -z "${GATE_OBSERVED_MODEL:-}" ]] || args+=(--observed-model "$GATE_OBSERVED_MODEL")
  [[ -z "${GATE_MODEL_EVIDENCE:-}" ]] || args+=(--model-evidence "$GATE_MODEL_EVIDENCE")
  python3 "$RECEIPT_HELPER" "${args[@]}" || exit 2
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

# A reduced pass must use the same captured policy as receipt validation.
# Classification errors keep the full pass; only validated helper output
# can select a docs-only exemption.
gate_classify_tier() {
  GATE_TIER=2
  GATE_TIER_REASON="full pass (default)"
  if [[ "${GATE_FORCE_FULL:-0}" == "1" ]]; then
    GATE_TIER_REASON="full pass (GATE_FORCE_FULL=1)"
    return 0
  fi
  local classification
  if ! classification="$(python3 "$RECEIPT_HELPER" classify --snapshot "$GATE_RUN_DIR/snapshot.json" 2>/dev/null)"; then
    GATE_TIER_REASON="full pass (artifact classification failed)"
    return 0
  fi
  if ! jq -se 'length == 1 and (.[0] | type == "object" and
      (.tier == 1 or .tier == 2) and (.reason | type == "string"))' \
      <<< "$classification" >/dev/null 2>&1; then
    GATE_TIER_REASON="full pass (invalid artifact classification)"
    return 0
  fi
  # shellcheck disable=SC2034  # GATE_TIER/GATE_TIER_REASON are read by the sourcing gate scripts
  GATE_TIER="$(jq -r '.tier' <<< "$classification")"
  # shellcheck disable=SC2034
  GATE_TIER_REASON="$(jq -r '.reason' <<< "$classification")"
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
