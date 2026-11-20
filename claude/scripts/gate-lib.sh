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

# Clear clean-worktree ownership globals unconditionally on source so
# entrypoints that source gate-lib.sh and invoke gate_cleanup (such as
# review-and-push.sh's tier-1 path) never act on inherited environment values.
GATE_CLEAN_WT=""
GATE_CLEAN_WT_EXTRA=""
GATE_CLEAN_WT_ROOT=""
GATE_CLEAN_WT_PID=""
# shellcheck disable=SC2034  # Initialized on source; shared across gates.
GATE_RECEIPT_REPO=""
# shellcheck disable=SC2034  # Initialized on source; shared across gates.
GATE_WORK_REPO=""
GATE_CLI_LAUNCHER=""
GATE_GIT_ENV_UNSET=()
for _gate_git_var in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES \
  GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE \
  GIT_NAMESPACE GIT_PREFIX GIT_ATTR_SOURCE GIT_CONFIG GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT; do
  GATE_GIT_ENV_UNSET+=(-u "$_gate_git_var")
done
unset _gate_git_var

# ─── Artifact capture and receipts ─────────────────────────────
# All content extraction belongs to the helper: even a normal worktree diff
# can execute a configured clean filter before --no-textconv takes effect.
# A review that CLAIMS the artifact retires EVERY lane's receipt for it, not only
# this lane's: a blocking verdict must not be bypassable by the other lane's older
# approval (#480). Capture (gate_extract_diff) touches only this lane; each gate
# calls gate_claim once its feasibility checks have passed and it is about to
# reach a verdict, so a lane that degrades (exit 3) leaves the other lane's
# approval valid (#499). Warn just BEFORE the claim retires anything. Presence
# only: whether that receipt was valid is `review-receipt.py check`'s business.
gate_warn_competing_receipt() {
  local repo="${GATE_RECEIPT_REPO:-.}" receipts other
  receipts="$(git -C "$repo" rev-parse --git-path review-receipts 2>/dev/null)" || return 0
  [[ "$receipts" == /* ]] || receipts="$repo/$receipts"
  for other in codex antigravity; do
    [[ "$other" != "$GATE_REVIEWER" ]] || continue
    [[ -f "$receipts/$other.json" ]] || continue
    yellow "⚠ The $other lane already holds a receipt for this artifact; this review's verdict retires it (#480)."
    yellow "  A review that then blocks must not leave an older approval able to ship."
    yellow "  If $other was the required lane and already approved, re-run its gate before pushing."
  done
}

gate_init_receipt() {
  RECEIPT_HELPER="$SCRIPT_DIR/review-receipt.py"
  command -v python3 >/dev/null 2>&1 || { red "Python 3 is required for artifact receipts."; exit 2; }
  [[ -f "$RECEIPT_HELPER" ]] || { red "Review receipt helper missing: $RECEIPT_HELPER"; exit 2; }
  python3 "$RECEIPT_HELPER" invalidate --repo "${GATE_RECEIPT_REPO:-.}" --reviewer "$GATE_REVIEWER" || exit 2
}

gate_reject_git_routing_overrides() {
  local git_overrides="" git_var
  for git_var in "${!GIT_@}"; do
    case "$git_var" in
      GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_OBJECT_DIRECTORY|GIT_DIR|GIT_WORK_TREE|\
      GIT_IMPLICIT_WORK_TREE|GIT_COMMON_DIR|GIT_GRAFT_FILE|GIT_INDEX_FILE|\
      GIT_REPLACE_REF_BASE|GIT_PREFIX|GIT_SHALLOW_FILE|GIT_NAMESPACE|GIT_ATTR_SOURCE|\
      GIT_CEILING_DIRECTORIES|GIT_CONFIG|GIT_CONFIG_PARAMETERS|GIT_CONFIG_COUNT|\
      GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*)
        git_overrides+="${git_overrides:+, }$git_var" ;;
    esac
  done
  if [[ -n "$git_overrides" ]]; then
    red "✖ Inherited Git routing or configuration overrides conflict with --clean-worktree; unset: $git_overrides"
    exit 2
  fi
}

gate_resolve_base() {
  [[ "${CLEAN_WORKTREE:-false}" != true ]] || gate_reject_git_routing_overrides
  local repo="${GATE_RECEIPT_REPO:-.}"
  if [[ -z "$BASE" ]]; then
    BASE="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    [[ -z "$BASE" ]] && BASE="main"
  fi
  BASE_REF=""
  if git -C "$repo" rev-parse --verify --quiet --end-of-options "origin/$BASE^{commit}" >/dev/null; then
    BASE_REF="origin/$BASE"
  elif git -C "$repo" rev-parse --verify --quiet --end-of-options "$BASE^{commit}" >/dev/null; then
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

_gate_remove_worktree() {
  local repo="$1" wt="$2" removed=0 common entry registered
  [[ -n "$wt" ]] || return 0
  if [[ -n "$repo" ]]; then
    if env "${GATE_GIT_ENV_UNSET[@]}" git -C "$repo" -c core.hooksPath=/dev/null worktree remove --force -- "$wt" >/dev/null 2>&1; then
      removed=1
    fi
  fi
  rm -rf -- "$wt" >/dev/null 2>&1 || true
  if [[ "$removed" -ne 1 && -n "$repo" ]]; then
    common="$(env "${GATE_GIT_ENV_UNSET[@]}" git -C "$repo" -c core.hooksPath=/dev/null rev-parse --path-format=absolute --git-common-dir 2>/dev/null && printf .)" || common=""
    common=${common%$'\n.'}
    if [[ -n "$common" && -d "$common/worktrees" ]]; then
      for entry in "$common/worktrees"/*; do
        [[ ! -L "$entry" && -d "$entry" && -f "$entry/gitdir" && ! -L "$entry/gitdir" ]] || continue
        registered="$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read().rstrip(b"\r\n").decode("utf-8", "surrogateescape"), end="")' "$entry/gitdir" 2>/dev/null && printf .)" || continue
        registered=${registered%.}
        if [[ "$registered" == "$wt/.git" ]]; then
          rm -rf -- "$entry" >/dev/null 2>&1 || true
        fi
      done
    fi
  fi
}

_gate_materialize_detached_worktree() {
  local repo="$1" dest="$2" head="$3"
  env "${GATE_GIT_ENV_UNSET[@]}" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -C "$repo" \
    -c core.sparseCheckout=false -c submodule.recurse=false \
    -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    worktree add --no-checkout --quiet --detach -- "$dest" "$head" || return 1
  python3 "$RECEIPT_HELPER" materialize \
    --repo "$dest" --receipt-repo "$repo" --head "$head" || return 1
}

gate_clean_worktree_add_extra() {
  local dest="$1" head="$2"
  [[ "${GATE_CLEAN_WT_PID:-}" == "$$" && -n "${GATE_RECEIPT_REPO:-}" && -n "${RECEIPT_HELPER:-}" ]] || return 1
  gate_reject_git_routing_overrides
  # Record before creation so EXIT/signal handlers still clean up if aborted mid-setup.
  GATE_CLEAN_WT_EXTRA="$dest"
  _gate_materialize_detached_worktree "$GATE_RECEIPT_REPO" "$dest" "$head"
}

gate_clean_worktree_remove_extra() {
  [[ "${GATE_CLEAN_WT_PID:-}" == "$$" && -n "${GATE_CLEAN_WT_EXTRA:-}" ]] || return 0
  local wt_extra="$GATE_CLEAN_WT_EXTRA" repo="${GATE_RECEIPT_REPO:-}"
  GATE_CLEAN_WT_EXTRA=""
  _gate_remove_worktree "$repo" "$wt_extra"
}

gate_clean_worktree_cleanup() {
  [[ "${GATE_CLEAN_WT_PID:-}" == "$$" ]] || return 0
  local wt_root="${GATE_CLEAN_WT_ROOT:-}" wt="${GATE_CLEAN_WT:-}" wt_extra="${GATE_CLEAN_WT_EXTRA:-}" repo="${GATE_RECEIPT_REPO:-}"
  GATE_CLEAN_WT_EXTRA=""
  GATE_CLEAN_WT_ROOT=""
  GATE_CLEAN_WT=""
  GATE_CLEAN_WT_PID=""
  [[ -n "$wt_root" || -n "$wt" || -n "$wt_extra" ]] || return 0
  _gate_remove_worktree "$repo" "$wt_extra"
  _gate_remove_worktree "$repo" "$wt"
  [[ -z "$wt_root" ]] || rm -rf -- "$wt_root" >/dev/null 2>&1 || true
}

gate_clean_worktree_setup() {
  if [[ "${FORCE_COMMITTED:-false}" != true || "${FORCE_UNCOMMITTED:-false}" == true ]]; then
    red "✖ --clean-worktree requires --committed and cannot be combined with --uncommitted."
    exit 2
  fi
  if [[ -z "${RECEIPT_HELPER:-}" || ! -f "$RECEIPT_HELPER" ]]; then
    red "✖ Review receipt helper is missing for --clean-worktree setup."
    exit 2
  fi
  gate_reject_git_routing_overrides
  local repo_raw pinned_head tmp_base wt_root_canon wt_base
  repo_raw="$(env "${GATE_GIT_ENV_UNSET[@]}" git rev-parse --show-toplevel && printf .)" || {
    red "✖ Cannot resolve repository root for --clean-worktree."
    exit 2
  }
  repo_raw=${repo_raw%$'\n.'}
  GATE_RECEIPT_REPO="$(cd -P -- "$repo_raw" && pwd -P && printf .)" || {
    red "✖ Cannot canonicalize repository root for --clean-worktree."
    exit 2
  }
  GATE_RECEIPT_REPO=${GATE_RECEIPT_REPO%$'\n.'}
  pinned_head="$(env "${GATE_GIT_ENV_UNSET[@]}" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -C "$GATE_RECEIPT_REPO" rev-parse --verify --end-of-options 'HEAD^{commit}')" || {
    red "✖ Cannot resolve HEAD commit for --clean-worktree."
    exit 2
  }
  tmp_base="${TMPDIR:-/tmp}"
  while [[ "$tmp_base" != "/" && "$tmp_base" == */ ]]; do
    tmp_base="${tmp_base%/}"
  done
  GATE_CLEAN_WT_ROOT="$(mktemp -d "$tmp_base/gate-clean-wt.XXXXXX")" || {
    red "✖ Cannot create temporary directory for --clean-worktree."
    exit 2
  }
  GATE_CLEAN_WT_PID="$$"
  if ! chmod 700 "$GATE_CLEAN_WT_ROOT"; then
    rm -rf -- "$GATE_CLEAN_WT_ROOT" || true
    GATE_CLEAN_WT_ROOT=""
    GATE_CLEAN_WT_PID=""
    red "✖ Cannot set permissions on temporary clean worktree directory."
    exit 2
  fi
  if ! wt_root_canon="$(cd -P -- "$GATE_CLEAN_WT_ROOT" && pwd -P && printf .)"; then
    rm -rf -- "$GATE_CLEAN_WT_ROOT" || true
    GATE_CLEAN_WT_ROOT=""
    GATE_CLEAN_WT_PID=""
    red "✖ Cannot canonicalize temporary clean worktree directory."
    exit 2
  fi
  GATE_CLEAN_WT_ROOT=${wt_root_canon%$'\n.'}
  wt_base="$(basename -- "$GATE_CLEAN_WT_ROOT")"
  GATE_CLEAN_WT="$GATE_CLEAN_WT_ROOT/$wt_base"
  # Arm cleanup before `git worktree add` so an interruption during creation or
  # materialization removes both the temporary checkout and worktree metadata.
  # shellcheck disable=SC2064
  trap "${GATE_EXIT_HANDLER:-gate_cleanup}" EXIT
  if ! _gate_materialize_detached_worktree "$GATE_RECEIPT_REPO" "$GATE_CLEAN_WT" "$pinned_head"; then
    red "✖ Failed to materialize clean detached worktree for --clean-worktree."
    exit 2
  fi
  # shellcheck disable=SC2034  # Read by gate_extract_diff and sourcing gates.
  GATE_WORK_REPO="$GATE_CLEAN_WT"
}

gate_cleanup() {
  gate_clean_worktree_cleanup
  [[ -z "${GATE_RUN_DIR:-}" ]] || rm -rf -- "$GATE_RUN_DIR"
}

gate_extract_diff() {
  local work_repo="${GATE_WORK_REPO:-.}"
  local args=(capture --repo "$work_repo" --scope "$GATE_SCOPE" --reviewer "$GATE_REVIEWER")
  GATE_CLAIMED=0
  [[ -z "${GATE_RECEIPT_REPO:-}" ]] || args+=(--receipt-repo "$GATE_RECEIPT_REPO")
  [[ -z "$BASE_REF" ]] || args+=(--base "$BASE_REF")
  local executable launcher
  executable="$(command -v "$GATE_CLI" && printf .)" || executable=""
  executable=${executable%$'\n.'}
  args+=(--executable "$executable")
  launcher="${GATE_CLI_LAUNCHER:-}"
  [[ -z "$launcher" || "$launcher" == "$executable" ]] || args+=(--launcher "$launcher")
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
  # A gate that already installed its own EXIT handler names it in
  # GATE_EXIT_HANDLER, so this line does not swap it out for plain cleanup
  # while the gate's cancel trap is still armed: a signal in that window used
  # to run the cancel handler under the wrong EXIT handler and leave with
  # status 2, the verdict code, for a run that reached no verdict.
  # Expanding now is the point: the handler is chosen here, once.
  # shellcheck disable=SC2064
  trap "${GATE_EXIT_HANDLER:-gate_cleanup}" EXIT
  # shellcheck disable=SC2034  # DIFF_CONTENT is consumed by both sourcing gates.
  DIFF_CONTENT="$(cat "$GATE_RUN_DIR/diff.patch")" || exit 2
  GATE_SCOPE="$(jq -r '.artifact.scope' "$GATE_RUN_DIR/snapshot.json")"
  # shellcheck disable=SC2034  # Read by the sourcing gates.
  TARGET_DESC="$GATE_SCOPE changes (pinned HEAD, base ${BASE_REF:-unused}${GATE_CLEAN_WT:+, clean worktree})"
}

gate_changed_paths() {
  jq -r '.artifact.changed_paths[]' "$GATE_RUN_DIR/snapshot.json"
}

gate_assert_unchanged() {
  python3 "$RECEIPT_HELPER" verify --snapshot "$GATE_RUN_DIR/snapshot.json" || exit 2
}

# Claim the captured artifact for this lane (#499): retires the other lane's
# receipt and supersedes a review in flight there. Call it once the gate can
# reach a verdict — after the tier valve, size caps, reviewer presence and the
# reviewer's own run — and before ANY exit that is a verdict, blocking ones
# included. Idempotent per run. A refusal means another review claimed this
# artifact first, so this attempt is superseded: exit 2, never a degraded 3.
gate_claim() {
  [[ "${GATE_CLAIMED:-0}" != 1 ]] || return 0
  gate_warn_competing_receipt
  python3 "$RECEIPT_HELPER" claim --snapshot "$GATE_RUN_DIR/snapshot.json" || exit 2
  GATE_CLAIMED=1
}

# Record a blocking verdict against the captured artifact (#573): a durable
# marker that `review-receipt.py check` holds every receipt captured before it
# to, whichever lane recorded it. Needs no live attempt, so it runs BEFORE
# gate_claim at every blocking exit: a claim refused as superseded exits 2 and
# must not take the marker with it. Idempotent per run. A failed write is
# reported and the exit still blocks; the claim that follows still retires the
# other lanes as before.
gate_block() {
  [[ "${GATE_BLOCKED:-0}" != 1 ]] || return 0
  [[ -n "${GATE_RUN_DIR:-}" && -f "$GATE_RUN_DIR/snapshot.json" ]] || return 0
  if python3 "$RECEIPT_HELPER" block --snapshot "$GATE_RUN_DIR/snapshot.json" >/dev/null; then
    GATE_BLOCKED=1
  else
    red "  Could not record the blocking-verdict marker; the claim below still retires the other lanes."
  fi
}

gate_record_pass() {
  local outcome="$1" output="${2:-}" args
  gate_assert_unchanged
  if [[ "${GATE_RECEIPT_ELIGIBLE:-1}" != 1 ]]; then
    # No receipt, so no claim either: a clean run nobody can attribute is not a
    # verdict and must not cost the other lane's approval (#499).
    yellow "⚠ No shipping receipt: reviewer dispatch identity was not verified."
    return 0
  fi
  gate_claim
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
#
# A lane whose runtime is not a selected agent service (#425) is unavailable,
# not skipped: gate_select_lane refuses it, naming the service and the opt-in
# command, rather than dispatching it or quietly picking another lane.

# gate_service_selected <service> — 0 when <service> is one of the operator's
# selected agent services, 1 when it is not, 2 when the saved selection cannot
# be read (reason on stderr). The selection is machine-local state parsed by
# lib-services.sh at the dotfiles root; this file is reached through per-file
# symlinks in ~/.claude/scripts, so the root is found from its REAL path. No
# saved selection means all services, the rule setup.sh migrates by; so does an
# install that predates lib-services.sh.
# _gate_services_read <lib> — print the saved selection; exit 1 when none was
# ever saved, 2 when it cannot be read. Run it in a subshell so the library's
# names stay out of the gate's namespace. It is a function, not an inline
# command substitution, because bash 3.2 (macOS) mis-scans quote characters in
# comments inside a multi-line command substitution.
_gate_services_read() {
  local lib="$1" path rc=0
  # shellcheck source=../../lib-services.sh
  . "$lib" || exit 2
  path="$(services_config_path)"
  services_load_saved "$path" && exit 0
  rc=$?
  # lib-services.sh reports absent when the file cannot even be statted; only
  # a genuine ENOENT means no selection was ever saved.
  [[ "$rc" -eq 1 ]] || exit "$rc"
  python3 -c '
import os, sys
try:
    os.lstat(sys.argv[1])
except FileNotFoundError:
    sys.exit(1)
except OSError:
    sys.exit(2)
sys.exit(2)' "$path"
}

gate_service_selected() {
  local service="$1" self lib selection rc=0
  self="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")" || return 2
  lib="${self%/*}/../../lib-services.sh"
  [[ -f "$lib" ]] || return 0
  selection="$(_gate_services_read "$lib")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) echo "The saved agent-service selection cannot be read; run ./setup.sh --show-services." >&2
       return 2 ;;
  esac
  case ",$selection," in
    *",$service,"*) return 0 ;;
  esac
  return 1
}

# gate_require_service <lane> — refuse (return 1, reason on stderr) a lane
# whose runtime is not selected, or when the selection is unreadable.
gate_require_service() {
  local lane="$1" label rc=0
  case "$lane" in
    codex) label=Codex ;;
    antigravity) label=Antigravity ;;
    *) return 0 ;;
  esac
  gate_service_selected "$lane" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) red "✖ The $label lane is unavailable: $label is not a selected agent service." >&2
       red "  Opt in with ./setup.sh --select-services, or have the operator review this diff." >&2 ;;
    *) red "✖ The $label lane is unavailable: the agent-service selection is unreadable." >&2 ;;
  esac
  return 1
}

gate_select_lane() {
  local required="${1:-}" requested="${REVIEW_LANE:-auto}" lane
  # Refusals go to stderr: callers read the chosen lane from stdout.
  case "$required" in
    any|antigravity|codex) ;;
    *) red "✖ gate_select_lane: unknown required lane '$required'." >&2; return 1 ;;
  esac
  case "$requested" in
    auto)
      case "$required" in
        any)         lane=skip ;;
        antigravity) lane=antigravity ;;
        codex)       lane=codex ;;
      esac
      ;;
    codex) lane=codex ;;
    antigravity)
      if [[ "$required" == codex ]]; then
        red "✖ REVIEW_LANE=antigravity refused: this diff requires the Codex lane." >&2
        red "  A risk-surface diff is never downgradable (ADR-0008); unset REVIEW_LANE." >&2
        return 1
      fi
      lane=antigravity
      ;;
    *)
      red "✖ REVIEW_LANE must be auto, codex, or antigravity (got '$requested')." >&2
      return 1
      ;;
  esac
  gate_require_service "$lane" || return 1
  printf '%s\n' "$lane"
  return 0
}

# ─── #205: post-dispatch model verification (agy lane) ─────────
# agy's --model takes the exact DISPLAY LABEL from `agy models` (e.g.
# "Gemini 4 Argon (High)"). Slug forms (gemini-3.1-pro*, …) are silently
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
# gate_ere_escape <text> — escape one operand for `grep -E` so it matches literally.
gate_ere_escape() {
  # The bracket expression lists `$` literally; nothing here should expand.
  # shellcheck disable=SC2016
  printf '%s' "$1" | sed -e 's/[][\\.*^$()+?{}|]/\\&/g'
}

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
  # agy 1.4.x records the model's slug (`agy models` prints it beside the
  # label: "gemini-4-argon-high	Gemini 4 Argon (High)"), not the label
  # (#696). Accept either. The slug is the label lowercased, with parentheses
  # dropped and spaces as dashes; Claude slugs also turn dots into dashes.
  # The derived slug must never widen the match: a label with no letters or
  # digits derives an empty or lone-dash slug (and `grep -F ""` matches every
  # line), and a shorter label's slug is a prefix of a longer model's slug
  # ("gemini-4-argon" vs "gemini-4-argon-high"). So the slug forms match only
  # as a whole token, bounded by characters that cannot continue a slug, and a
  # label without a letter or digit is matched literally only. Every operand
  # is escaped into one ERE so the label itself still matches literally.
  local slug dotless label_re slug_re
  slug="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]' | tr -d '()' | tr -s ' ' '-')"
  dotless="${slug//./-}"
  # Both forms match as whole tokens: nothing alphanumeric may run straight
  # into or out of them, and a slug may not continue with _ . or - either, so
  # "gemini-4-argon" matches neither "gemini-4-argon-high" nor
  # "gemini-4-argon_high". A label followed by a parenthesised tier, as
  # "Gemini 4 Argon" is by " (High)", is still a prefix match and is left to
  # the authoritative log-line check above.
  label_re="(^|[^[:alnum:]])$(gate_ere_escape "$want")([^[:alnum:]]|$)"
  slug_re=""
  if [[ "$slug" == *[a-z0-9]* ]]; then
    slug_re="(^|[^[:alnum:]_.-])($(gate_ere_escape "$slug")|$(gate_ere_escape "$dotless"))([^[:alnum:]_.-]|$)"
  fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # `grep -q` exits at the first match and `strings` then dies of SIGPIPE.
    # Under the gates' `set -o pipefail` that made a MATCH read as a miss on
    # any record large enough to still be streaming (#696), so the reader's
    # status is discarded and only grep's decides.
    if { strings "$f" 2>/dev/null || true; } | grep -qE -e "$label_re" ${slug_re:+-e "$slug_re"}; then
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
# Two formats, told apart by their name, so neither can be read as the other:
#   codex-gate-loc:   the file name as written. Used, as it always has been,
#                     for a name with no `%`, `<`, `>`, backslash or control
#                     character: for such a name it is already unambiguous,
#                     and issues filed before the second format keep matching.
#   codex-gate-loc2:  every other name, with those characters percent-encoded.
#                     The name can then neither end the comment nor spell a
#                     second marker inside it, no two names share a marker,
#                     and nothing in it is rewritten by the index's @tsv.
# A name that needs the second format is never looked up in the first: what
# the first format wrote for such names (characters dropped, backslashes
# doubled by the row it once passed through) cannot be told from another
# file's marker, so an issue filed that way is filed once more instead.
# shellcheck disable=SC2034  # Also read by the sourcing gate.
GATE_ISSUE_PARTS_FLAG='<!-- codex-gate-parts -->'
gate_issue_marker() {
  # A marker is a persisted key, written by one run and matched by another,
  # so it is derived from the name's bytes: under the C locale bash walks
  # bytes and `[:cntrl:]` is the ASCII control set, whatever locale the gate
  # was started in. A name that is not ASCII keeps its bytes as they are.
  local LC_ALL=C
  local file="$1" encoded="" char i
  if [[ "$file" != *[%\<\>\\[:cntrl:]]* ]]; then
    printf '<!-- codex-gate-loc:%s:%s -->' "$GATE_ISSUE_REPO" "$file"
    return 0
  fi
  for ((i = 0; i < ${#file}; i++)); do
    char="${file:i:1}"
    case "$char" in
      %) char=%25 ;;
      \<) char=%3C ;;
      \>) char=%3E ;;
      \\) char=%5C ;;
      [[:cntrl:]]) printf -v char '%%%02X' "'$char" ;;
    esac
    encoded+="$char"
  done
  printf '<!-- codex-gate-loc2:%s:%s -->' "$GATE_ISSUE_REPO" "$encoded"
}

# gate_issue_index_marker <file> — the marker as it appears in GATE_ISSUE_INDEX.
# The index is jq @tsv output, which doubles backslashes (and encodes tab, LF
# and CR as \t \n \r, none of which gate_issue_marker leaves in a marker),
# and `read -r` keeps those escapes literal. Lookups and in-run records
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
  local url slug="" repo="${GATE_RECEIPT_REPO:-.}"
  url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)" || url=""
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
  local num state reason body author line extra
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
  # An issue filed in parts keeps its location markers in a closing comment
  # (publish_finding in codex-review-gate.sh), so its comments join the index
  # as further rows for the same issue. Only the issue author's: anyone may
  # comment on a public issue, and a marker is what makes a location read as
  # tracked or accepted. A read that fails fails the prefetch, so the caller
  # files nothing rather than filing blind. Issues closed as completed are
  # skipped: gate_issue_lookup never matches them.
  while IFS=$'\t' read -r num state reason body; do
    [[ -n "$num" && "$body" == *"$GATE_ISSUE_PARTS_FLAG"* ]] || continue
    [[ "$state" == open || "$reason" == not_planned ]] || continue
    author="$(gh api "repos/$GATE_ISSUE_REPO/issues/$num" --jq '.user.login // ""' 2>/dev/null)" || return 1
    [[ -n "$author" ]] || return 1
    extra="$(GATE_ISSUE_AUTHOR="$author" \
      gh api "repos/$GATE_ISSUE_REPO/issues/$num/comments?per_page=100" --paginate \
      --jq '.[] | select(.user.login == env.GATE_ISSUE_AUTHOR) | [(.body // "")] | @tsv' 2>/dev/null)" || return 1
    while IFS= read -r line; do
      [[ -z "$line" ]] || GATE_ISSUE_INDEX+=$'\n'"$num"$'\t'"$state"$'\t'"$reason"$'\t'"$line"
    done <<<"$extra"
  done <<<"$GATE_ISSUE_INDEX"
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

# gate_text_chars <file> — print the file's length in characters, counted as
# gate_split_text counts them (UTF-8 code points), not as `wc -m` does, whose
# answer follows the locale and is a byte count under C.
gate_text_chars() {
  python3 - "$1" <<'PYCHARS'
import sys

with open(sys.argv[1], encoding="utf-8", errors="surrogateescape", newline="") as stream:
    print(len(stream.read()))
PYCHARS
}

# gate_split_text <file> <limit> <prefix> — write <file> as <prefix>1..N, each
# at most <limit> characters, and print N. Parts end at line ends; only a line
# longer than the limit is cut inside. Nothing is added or dropped: the parts
# in order are the file.
gate_split_text() {
  python3 - "$1" "$2" "$3" <<'PYSPLIT'
import sys

path, limit, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if limit < 1:
    raise SystemExit("split limit must be positive")
with open(path, encoding="utf-8", errors="surrogateescape", newline="") as stream:
    text = stream.read()
parts, current = [], ""
for line in text.splitlines(keepends=True):
    while len(line) > limit:
        if current:
            parts.append(current)
            current = ""
        parts.append(line[:limit])
        line = line[limit:]
    if len(current) + len(line) > limit:
        parts.append(current)
        current = ""
    current += line
if current:
    parts.append(current)
for number, part in enumerate(parts, 1):
    with open(prefix + str(number), "w", encoding="utf-8", errors="surrogateescape", newline="") as stream:
        stream.write(part)
print(len(parts))
PYSPLIT
}

# gate_issue_send <endpoint> <json> [<method>] — one REST write, the request
# on stdin: a body passed as an argument fails outright past the kernel's cap
# on a single argument. Returns 0 and sets GATE_SENT_URL (the html_url GitHub
# answered with) on success. On failure GATE_SENT_LABEL_REJECTED is true only
# for an HTTP 422 whose every error is a label validation error: the one
# failure that proves nothing was created, so the one a caller may retry
# without the label. Any other failure may follow a write that succeeded.
gate_issue_send() {
  local status=0 response answer
  GATE_SENT_URL="" GATE_SENT_LABEL_REJECTED=false
  response="$(gh api "$1" ${3:+--method "$3"} --input - --include <<<"$2" 2>/dev/null)" || status=$?
  answer="$(sed '1,/^[[:space:]]*$/d' <<<"$response")"
  if [[ "$status" -eq 0 ]]; then
    GATE_SENT_URL="$(jq -er '.html_url | select(type == "string" and length > 0)' <<<"$answer" 2>/dev/null)" || GATE_SENT_URL=""
    [[ -n "$GATE_SENT_URL" ]]
    return
  fi
  if [[ "$response" =~ ^HTTP/[0-9.]+[[:space:]]422[[:space:]] ]] \
    && jq -e '
      (.errors | type == "array" and length > 0) and
      all(.errors[];
        ((.resource == "Issue" and .field == "labels") or
         (.resource == "Label" and .field == "name")) and
        (.code == "invalid" or .code == "missing" or .code == "missing_field"))
    ' <<<"$answer" >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # Read by the sourcing gate.
    GATE_SENT_LABEL_REJECTED=true
  fi
  return 1
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
