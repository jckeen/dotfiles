#!/usr/bin/env bash
# fleet-codex-review.test.sh — fixture tests for fleet-codex-review.sh against
# a fake `gh` (no framework). The invariant under test: the ruleset that
# requires `codex-review` is never created before the workflow that posts it
# is current on the default branch. Run directly; exit 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/../fleet-codex-review.sh"
export CANONICAL="$SCRIPT_DIR/../../../.github/workflows/codex-review.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh. State lives in $FIX: workflow (none|current|stale), ruleset (0|1),
# branch (0|1), openpr (0|1). Every write is logged to $FIX/writes.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
st() { cat "$FIX/$1"; }
all="$*"
case "$1 $2" in
  "pr list")
    if [ "$(st openpr)" = 1 ]; then echo 7; fi
    exit 0
    ;;
  "pr create") echo "pr create" >>"$FIX/writes"; echo "https://github.com/o/r/pull/8"; exit 0 ;;
  "pr merge") echo "pr merge" >>"$FIX/writes"; exit 0 ;;
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
    case "$(st workflow)" in
      none) exit 1 ;;
      current) base64 -w0 <"$CANONICAL" ;;
      stale) printf 'old' | base64 -w0 ;;
    esac
    ;;
  repos/o/r/rulesets) [ "$(st ruleset)" = 1 ] && echo 42 ;;
  repos/o/r/git/ref/heads/ci/codex-review-status) [ "$(st branch)" = 1 ] || exit 1 ;;
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
  cp "$CANONICAL" "$TMP/root$n/.github/workflows/"
  mv "$script" "$TMP/root$n/claude/scripts/fleet.sh"
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
run_case "missing workflow opens the rollout PR, no ruleset" none 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-review.yml;pr create;pr merge"
run_case "stale workflow opens the rollout PR, no ruleset" stale 0 0 0 --apply \
  "POST git/refs;PUT contents/.github/workflows/codex-review.yml;pr create;pr merge"
# A failed file write stops before the PR: no PR for an empty branch.
n_next=$((n + 1))
mkdir -p "$TMP/c$n_next" && touch "$TMP/c$n_next/fail_PUT"
run_case "a failed workflow write opens no PR and fails" none 0 0 0 --apply "POST git/refs" 1
run_case "open rollout PR is reused" none 0 1 1 --apply ""
run_case "leftover branch without a PR is never reset" none 0 1 0 --apply "" 1
run_case "current workflow creates the ruleset" current 0 0 0 --apply "POST rulesets"
if jq -e '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks
    == [{context: "codex-review", integration_id: 15368}]' "$FIX/input" >/dev/null &&
  jq -e '.rules[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution' "$FIX/input" >/dev/null; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: ruleset body must pin codex-review to the Actions app and require thread resolution: $(cat "$FIX/input" 2>/dev/null)"
fi
run_case "existing ruleset is left alone" current 1 0 0 --apply ""
run_case "advisory repo never gets a ruleset" current 0 0 0 --apply "" 0 advisory

echo "fleet-codex-review: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
