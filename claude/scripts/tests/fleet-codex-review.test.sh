#!/usr/bin/env bash
# fleet-codex-review.test.sh — fixture tests for fleet-codex-review.sh against
# a fake `gh` (no framework). The invariant under test: the ruleset that
# requires `codex-review` is never created before the workflow that posts it
# is current on the default branch. Run directly; exit 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/../fleet-codex-review.sh"
export CANON_DIR="${CODEX_WORKFLOWS_DIR:-$SCRIPT_DIR/../../../.github/workflows}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh. State lives in $FIX: workflow (none|current|stale|partial, where
# partial = codex-review.yml current and codex-findings.yml missing;
# error = every file read fails with HTTP 500), ruleset (0|1|error),
# branch (0|1), openpr (0|1). Every write is logged to $FIX/writes.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
st() { cat "$FIX/$1"; }
all="$*"
case "$1 $2" in
  "pr list")
    case "$(st openpr)" in
      1) echo 7 ;;
      error) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  "pr create") echo "pr create" >>"$FIX/writes"; echo "https://github.com/o/r/pull/8"; exit 0 ;;
  "pr merge") echo "pr merge" >>"$FIX/writes"; exit 0 ;;
  "workflow run") echo "workflow run" >>"$FIX/writes"; exit 0 ;;
esac
method=GET
[[ "$all" == *"-X POST"* ]] && method=POST
[[ "$all" == *"-X PUT"* ]] && method=PUT
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
if [ "$method" != GET ]; then
  if [ -e "$FIX/fail_$method" ]; then
    echo "fake gh: $method failed" >&2
    exit 1
  fi
  echo "$method ${path#repos/o/r/}" >>"$FIX/writes"
  [[ "$all" == *"--input -"* ]] && cat >"$FIX/input"
  exit 0
fi
case "$path" in
  repos/o/r) echo main ;;
  repos/o/r/contents/*)
    f=${path%%\?*}
    f=${f##*/}
    w=$(st workflow)
    # reread_error: the first read of each file succeeds, any later one
    # fails, so a code path that reads twice acts on a failed read.
    if [ -e "$FIX/reread_error" ]; then
      if [ -e "$FIX/read_$f" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
      : >"$FIX/read_$f"
    fi
    if [ "$w" = partial ]; then
      if [ "$f" = codex-review.yml ]; then w=current; else w=none; fi
    fi
    case "$w" in
      none) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      error) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
      current) base64 -w0 <"$CANON_DIR/$f" ;;
      stale) printf 'old' | base64 -w0 ;;
    esac
    ;;
  repos/o/r/rulesets)
    case "$(st ruleset)" in
      1) echo 42 ;;
      error) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac
    ;;
  repos/o/r/git/ref/heads/ci/codex-review-status)
    case "$(st branch)" in
      1) ;;
      error) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    ;;
  repos/o/r/git/ref/heads/main) echo deadbeef ;;
  *) echo "fake gh: unexpected $path" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"

pass=0
failed=0
n=0

# case <name> <workflow> <ruleset> <branch> <openpr> <args> <expected writes, ; separated> [exit]
run_case() {
  n=$((n + 1))
  FIX="$TMP/c$n"
  mkdir -p "$FIX"
  export FIX
  echo "$2" >"$FIX/workflow"
  echo "$3" >"$FIX/ruleset"
  echo "$4" >"$FIX/branch"
  echo "$5" >"$FIX/openpr"
  : >"$FIX/writes"
  # o/r is in neither list, so the test names its own mode through a copy
  # of the script with o/r added to ENFORCE (or left advisory).
  local script="$TMP/fleet$n.sh"
  if [ "${9:-enforce}" = enforce ]; then
    sed 's|^ENFORCE=(|ENFORCE=(\n  o/r|' "$FLEET" >"$script"
  else
    cp "$FLEET" "$script"
  fi
  mkdir -p "$TMP/root$n/claude/scripts" "$TMP/root$n/.github/workflows"
  cp "$CANON_DIR/codex-review.yml" "$CANON_DIR/codex-findings.yml" "$TMP/root$n/.github/workflows/"
  mv "$script" "$TMP/root$n/claude/scripts/fleet.sh"
  [ -e "$FIX/unreadable_canonical" ] && chmod 000 "$TMP/root$n/.github/workflows/codex-findings.yml"
  PATH="$TMP/bin:$PATH" bash "$TMP/root$n/claude/scripts/fleet.sh" $6 o/r >"$FIX/out" 2>&1
  local code=$?
  local got
  got="$(paste -sd';' "$FIX/writes")"
  if [ "$got" = "$7" ] && [ "$code" = "${8:-0}" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1 — writes '$got' (want '$7'), exit $code (want ${8:-0})"
    sed 's/^/    /' "$FIX/out"
  fi
}

run_case "check writes nothing" none 0 0 0 --check ""
n_next=$((n + 1))
mkdir -p "$TMP/c$n_next" && touch "$TMP/c$n_next/unreadable_canonical"
run_case "an unreadable canonical workflow ships nothing" none 0 0 0 --apply "" 2
run_case "missing workflows open the rollout PR, no ruleset" none 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-review.yml;PUT contents/.github/workflows/codex-findings.yml;pr create;pr merge"
run_case "stale workflows open the rollout PR, no ruleset" stale 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-review.yml;PUT contents/.github/workflows/codex-findings.yml;pr create;pr merge"
run_case "only the workflow that is not current is shipped" partial 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-findings.yml;pr create;pr merge"
run_case "a missing codex-findings.yml holds the ruleset" partial 0 0 1 --apply ""
# A failed file write stops before the PR: no PR for an empty branch.
n_next=$((n + 1))
mkdir -p "$TMP/c$n_next" && touch "$TMP/c$n_next/fail_PUT"
run_case "a failed workflow write opens no PR and fails" none 0 0 0 --apply "POST git/refs" 1
run_case "open rollout PR is reused" none 0 1 1 --apply ""
run_case "leftover branch without a PR is never reset" none 0 1 0 --apply "" 1
run_case "an unreadable PR list opens nothing and fails" none 0 0 error --apply "" 1
run_case "an unreadable branch (not a 404) is never created over and fails" none 0 error 0 --apply "" 1
run_case "current workflow creates the ruleset, then evaluates every open PR" current 0 0 0 --apply "POST rulesets;workflow run"
if jq -e '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks
    == [{context: "codex-review", integration_id: 15368}]' "$FIX/input" >/dev/null &&
  jq -e '.rules[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution' "$FIX/input" >/dev/null; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: ruleset body must pin codex-review to the Actions app and require thread resolution: $(cat "$FIX/input" 2>/dev/null)"
fi
run_case "existing ruleset is left alone" current 1 0 0 --apply ""
n_next=$((n + 1))
mkdir -p "$TMP/c$n_next" && touch "$TMP/c$n_next/reread_error"
run_case "the rollout acts on the one checked read, never a reread" partial 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-findings.yml;pr create;pr merge"
n_next=$((n + 1))
mkdir -p "$TMP/c$n_next" && touch "$TMP/c$n_next/reread_error"
run_case "a stale file whose sha cannot be read writes nothing at all" stale 0 0 0 --apply "" 1
run_case "an unreadable workflow (not a 404) ships nothing and fails" error 0 0 0 --apply "" 1
run_case "unreadable rulesets never create a duplicate and fail" current error 0 0 --apply "" 1
run_case "advisory repo never gets a ruleset" current 0 0 0 --apply "" 0 advisory

echo "fleet-codex-review: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
