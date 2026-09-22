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
# Starting a review retires EVERY lane's receipt for this artifact, not only this
# lane's: a blocking verdict must not be bypassable by the other lane's older
# approval (#480). Warn BEFORE anything is retired — the Antigravity gate's
# supplementary-lane banner prints long after `begin` has already done it, so it
# is too late to be a warning. Presence only: whether that receipt was valid is
# `review-receipt.py check`'s business, not this line's.
gate_warn_competing_receipt() {
  local receipts other
  receipts="$(git rev-parse --git-path review-receipts 2>/dev/null)" || return 0
  for other in codex antigravity; do
    [[ "$other" != "$GATE_REVIEWER" ]] || continue
    [[ -f "$receipts/$other.json" ]] || continue
    yellow "⚠ The $other lane already holds a receipt for this artifact; starting this review retires it (#480)."
    yellow "  A review that then blocks must not leave an older approval able to ship."
    yellow "  If $other was the required lane and already approved, re-run its gate before pushing."
  done
}

gate_init_receipt() {
  RECEIPT_HELPER="$SCRIPT_DIR/review-receipt.py"
  command -v python3 >/dev/null 2>&1 || { red "Python 3 is required for artifact receipts."; exit 2; }
  [[ -f "$RECEIPT_HELPER" ]] || { red "Review receipt helper missing: $RECEIPT_HELPER"; exit 2; }
  gate_warn_competing_receipt
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
  local executable
  executable="$(command -v "$GATE_CLI" && printf .)" || executable=""
  executable=${executable%$'\n.'}
  args+=(--executable "$executable")
  args+=("--tier1-max-lines=${GATE_TIER1_MAX_LINES:-200}")
  # The tier-1 BYTE ceiling is deliberately NOT overridable from here: its only
  # source is review-receipt.py's TIER1_MAX_BYTES, which every caller inherits by
  # omitting the flag (#494). A knob honoured here alone would be honoured by half
  # the pipeline — `review-and-push.sh` classifies with its own `lane` call before
  # any gate runs, so a stricter ceiling here would make the wrapper choose the
  # tier-1 skip and then refuse to record the exemption it had just chosen,
  # failing a push instead of escalating it to a review. Adding the knob means
  # forwarding it to that `lane` call in the same change, with a wrapper test.
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
  # Lane-ledger annotation only (ADR-0008); it never affects receipt validity.
  # review-and-push.sh sets it when a degraded Antigravity gate handed this diff
  # to Codex, so `review-receipt.py stats` can count the fallbacks.
  [[ -z "${REVIEW_LANE_NOTE:-}" ]] || args+=(--note "$REVIEW_LANE_NOTE")
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
# GATE_REQUIRED_LANE is the weakest lane allowed to ship the diff (ADR-0008)
# and GATE_RISK_PATHS the risk surfaces that forced it, one per line. Both
# default to the strongest answer: every path out of this function that could
# not read a validated classification leaves GATE_REQUIRED_LANE=codex, so a
# malformed classifier can only ever over-require review, never under-require it.
gate_classify_tier() {
  GATE_TIER=2
  GATE_TIER_REASON="full pass (default)"
  GATE_REQUIRED_LANE=codex
  GATE_RISK_PATHS=""
  if [[ "${GATE_FORCE_FULL:-0}" == "1" ]]; then
    GATE_TIER_REASON="full pass (GATE_FORCE_FULL=1)"
    return 0
  fi
  local classification
  if ! classification="$(python3 "$RECEIPT_HELPER" classify --snapshot "$GATE_RUN_DIR/snapshot.json" 2>/dev/null)"; then
    GATE_TIER_REASON="full pass (artifact classification failed)"
    return 0
  fi
  # A tier-2 diff may never carry required_lane "any": that pairing would let a
  # tier-1 exemption receipt ship work the valve sent to a full review.
  if ! jq -se 'length == 1 and (.[0] | type == "object" and
      (.tier == 1 or .tier == 2) and (.reason | type == "string") and
      (.required_lane == "any" or .required_lane == "antigravity" or .required_lane == "codex") and
      (.tier == 1 or .required_lane != "any") and
      (.risk_paths | type == "array") and (.risk_paths | map(type) | all(. == "string")))' \
      <<< "$classification" >/dev/null 2>&1; then
    GATE_TIER_REASON="full pass (invalid artifact classification)"
    return 0
  fi
  # shellcheck disable=SC2034  # GATE_TIER/GATE_TIER_REASON are read by the sourcing gate scripts
  GATE_TIER="$(jq -r '.tier' <<< "$classification")"
  # shellcheck disable=SC2034
  GATE_TIER_REASON="$(jq -r '.reason' <<< "$classification")"
  # shellcheck disable=SC2034  # Read by the sourcing gates and review-and-push.sh.
  GATE_REQUIRED_LANE="$(jq -r '.required_lane' <<< "$classification")"
  # shellcheck disable=SC2034
  GATE_RISK_PATHS="$(jq -r '.risk_paths[]' <<< "$classification")"
  return 0
}

# ─── Lane selection (ADR-0008) ─────────────────────────────────
# gate_select_lane <required-lane> — print the lane to dispatch:
#   codex        the diff requires the Codex lane, or REVIEW_LANE=codex
#   antigravity  ordinary tier-2 work, or REVIEW_LANE=antigravity where allowed
#   skip         tier 1 (required lane "any"): no reviewer needs to be
#                dispatched at all. A caller that still needs shipping evidence
#                records the exemption receipt itself — capture, then
#                `review-receipt.py complete --outcome tier-1`, which refuses any
#                artifact that is not a small docs-only diff
#                (`review-and-push.sh` does this). Asking a gate for it instead
#                couples the exemption to that gate's dispatch-feasibility
#                limits (#482).
# Returns 1 (with a reason on stdout/stderr) on an unusable request. The one
# asymmetry is deliberate: REVIEW_LANE=antigravity on a codex-required diff is
# REFUSED rather than honoured, because that request is exactly the downgrade
# the required lane exists to prevent. Escalation (REVIEW_LANE=codex on an
# ordinary diff) is always allowed.
gate_select_lane() {
  local required="${1:-}" requested="${REVIEW_LANE:-auto}"
  # Refusals go to stderr: callers read the chosen lane from stdout.
  case "$required" in
    any|antigravity|codex) ;;
    *) red "✖ gate_select_lane: unknown required lane '$required'." >&2; return 1 ;;
  esac
  case "$requested" in
    auto) ;;
    codex) printf 'codex\n'; return 0 ;;
    antigravity)
      if [[ "$required" == codex ]]; then
        red "✖ REVIEW_LANE=antigravity refused: this diff requires the Codex lane." >&2
        red "  A risk-surface diff is never downgradable (ADR-0008); unset REVIEW_LANE." >&2
        return 1
      fi
      printf 'antigravity\n'
      return 0
      ;;
    *)
      red "✖ REVIEW_LANE must be auto, codex, or antigravity (got '$requested')." >&2
      return 1
      ;;
  esac
  case "$required" in
    any)         printf 'skip\n' ;;
    antigravity) printf 'antigravity\n' ;;
    codex)       printf 'codex\n' ;;
  esac
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

# ─── Filed-issue dedup by location ─────────────────────────────
# Two feeds file GitHub issues out of Codex output: this gate's low findings
# and harvest-codex-comments.sh's PR-bot comments. Both must answer the same
# question before writing — "is this already tracked?" — so the fetch lives
# here and both share one mechanism.
#
# Codex paraphrases finding titles between runs, so a title-keyed dedup filed
# ONE fixture finding as sixteen issues. The stable key is the FILE the finding
# points at (line numbers drift): every issue the gate files carries a hidden
# marker `<!-- codex-gate-loc:<owner/repo>:<file> -->` and lookups grep for it.
#
# Existing issues are fetched ONCE via REST (repos/{owner}/{repo}/issues),
# never `gh issue list --search` / `gh issue create`: those go through GitHub's
# GraphQL API, which egress-restricted proxies (Claude Cloud routine sandboxes)
# block, while plain REST under repos/{owner}/{repo}/... is served. jq's @tsv
# escapes newlines, so the whole index is one record per issue in memory.
GATE_ISSUE_REPO=""
GATE_ISSUE_INDEX=""
# Stands in for an absent state_reason so no field before the body is ever
# empty; see the read-collapsing note in gate_issue_prefetch.
GATE_ISSUE_NO_REASON="-"

# gate_issue_marker <file> — the exact marker text for a location.
gate_issue_marker() {
  # The marker is an HTML comment; strip control characters and the closing
  # sequence so a reviewer-supplied path cannot terminate it early.
  local file
  file="$(printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/-->//g')"
  printf '<!-- codex-gate-loc:%s:%s -->' "$GATE_ISSUE_REPO" "$file"
}

# gate_issue_index_marker <file> — the marker as it appears in GATE_ISSUE_INDEX.
# The index is jq @tsv output, which doubles backslashes (and encodes tab, LF
# and CR as \t \n \r, none of which survive gate_issue_marker's control-byte
# strip), and `read -r` keeps those escapes literal. Lookups and in-run records
# must use this form or a path containing a backslash never matches: its open
# issue would be refiled every run and a not-planned closure would not suppress.
gate_issue_index_marker() {
  local marker
  marker="$(gate_issue_marker "$1")"
  printf '%s' "${marker//\\/\\\\}"
}

# gate_repo_slug — print `owner/name` for the current repo, or return 1.
# Every write (issue create, comment) must name this slug explicitly: gh's
# implicit repository (GH_REPO, an upstream default) can differ from the one
# the index was built from, and an issue filed elsewhere is invisible to dedup.
# The git remote is authoritative and needs no network; `gh repo view` is only
# the fallback for a checkout with no github.com remote, and it is itself
# GraphQL-backed — the very call a restricted sandbox may refuse. Accept a
# bare two-part slug only: a nested or empty parse is a failure, never a guess.
gate_repo_slug() {
  local url slug=""
  url="$(git config --get remote.origin.url 2>/dev/null)" || url=""
  case "$url" in
    *github.com[:/]*)
      slug="${url##*github.com}"
      slug="${slug#[:/]}"
      slug="${slug%.git}"
      slug="${slug%/}"
      ;;
  esac
  if [[ "$slug" != */* || "$slug" == */*/* ]]; then
    slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || return 1
  fi
  [[ "$slug" == */* && "$slug" != */*/* ]] || return 1
  printf '%s\n' "$slug"
}

# gate_issue_prefetch [<owner/repo>] — resolve the repo slug (unless the caller
# already knows it) and load every issue, ALL states, into GATE_ISSUE_INDEX as
# "number<TAB>state<TAB>state_reason<TAB>body". Pull requests share the
# endpoint and are dropped. Returns 1 when the slug or the fetch is
# unavailable; a caller that files anyway files blind, which is the duplicate
# noise this exists to stop.
gate_issue_prefetch() {
  if [[ -n "${1:-}" ]]; then
    GATE_ISSUE_REPO="$1"
  else
    GATE_ISSUE_REPO="$(gate_repo_slug)" || GATE_ISSUE_REPO=""
  fi
  [[ "$GATE_ISSUE_REPO" == */* ]] || return 1
  # An absent state_reason becomes GATE_ISSUE_NO_REASON, never "". Tab is an
  # IFS *whitespace* character, so `read` collapses a run of tabs into one
  # delimiter: an empty middle field would shift the body left into $reason and
  # the marker would never be found — silently defeating the dedup. Keeping
  # every field before the trailing body non-empty is what makes the read exact.
  # `gh api --jq` takes no --arg, so the placeholder travels as an env var and
  # is read with jq's env.NAME — one source of truth shared with the index
  # record gate_issue_remember appends.
  GATE_ISSUE_INDEX="$(GATE_ISSUE_NO_REASON="$GATE_ISSUE_NO_REASON" \
    gh api "repos/$GATE_ISSUE_REPO/issues?state=all&per_page=100" --paginate \
    --jq '.[] | select(.pull_request == null)
          | [(.number|tostring), .state, (.state_reason // env.GATE_ISSUE_NO_REASON), (.body // "")] | @tsv' 2>/dev/null)" || return 1
  return 0
}

# gate_issue_lookup <file> — print one of:
#   open <number>      an open issue tracks this location: comment, don't file
#   accepted <number>  closed as not_planned: the finding is accepted, skip
#   none               no match, or only closed-as-completed (regressed): file
# Closing an issue as *not planned* IS the suppression mechanism — accepting a
# finding needs no extra config file. Closing it as *completed* means the code
# was fixed, so the same location reappearing is a regression worth filing.
# Open wins over accepted so a reopened finding keeps collecting comments.
gate_issue_lookup() {
  local marker num state reason body accepted=""
  marker="$(gate_issue_index_marker "$1")"
  while IFS=$'\t' read -r num state reason body; do
    [[ -n "$num" && "$body" == *"$marker"* ]] || continue
    if [[ "$state" == "open" ]]; then
      printf 'open %s\n' "$num"
      return 0
    fi
    [[ "$reason" == "not_planned" && -z "$accepted" ]] && accepted="$num"
  done <<<"$GATE_ISSUE_INDEX"
  if [[ -n "$accepted" ]]; then
    printf 'accepted %s\n' "$accepted"
  else
    printf 'none\n'
  fi
}

# gate_issue_remember <number> <file> — add a just-filed issue to the index so
# a second finding at the same location in this run comments instead of filing.
gate_issue_remember() {
  GATE_ISSUE_INDEX+=$'\n'"$1"$'\t'"open"$'\t'"$GATE_ISSUE_NO_REASON"$'\t'"$(gate_issue_index_marker "$2")"
}

# ─── .codex-review-ignore ──────────────────────────────────────
# A per-repo list of path globs whose contents are hostile-by-design test data
# (adversarial fixtures, prompt-injection samples). Matching changed paths stay
# in the diff; the gate only tells the reviewer not to report instruction-like
# strings inside them. The file is repo content, so it is untrusted input like
# the diff: bounded (200 lines, 256 bytes per line), control characters and
# non-UTF-8 reject the whole file, and the result is fenced as data.

# gate_read_ignore_file <path> — print the accepted globs one per line, or
# print the rejection reason on stderr and return 1. A missing file is empty.
gate_read_ignore_file() {
  [[ -f "$1" ]] || return 0
  python3 - "$1" <<'PYIGNORE'
import sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
lines = raw.split(b"\n")
if lines and lines[-1] == b"":
    lines.pop()
if len(lines) > 200:
    sys.exit("more than 200 lines")
globs = []
for number, line in enumerate(lines, 1):
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError:
        sys.exit(f"line {number} is not UTF-8")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in text):
        sys.exit(f"line {number} contains a control character")
    if len(line) > 256:
        sys.exit(f"line {number} is longer than 256 bytes")
    text = text.strip()
    if not text or text.startswith("#"):
        continue
    globs.append(text)
print("\n".join(globs))
PYIGNORE
}

# gate_match_ignored_paths <globs> <paths> — print each path that matches any
# glob. Shell pattern semantics: `*` spans `/` (so `**` is a synonym), `?` and
# `[...]` as usual; no extglob.
gate_match_ignored_paths() {
  local globs="$1" paths="$2" path glob
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue
      # shellcheck disable=SC2053  # The unquoted right-hand side is the glob on purpose.
      if [[ "$path" == $glob ]]; then
        printf '%s\n' "$path"
        break
      fi
    done <<<"$globs"
  done <<<"$paths"
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
