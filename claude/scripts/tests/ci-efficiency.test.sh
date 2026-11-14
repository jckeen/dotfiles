#!/usr/bin/env bash
# ci-efficiency.test.sh — fixture tests for check-ci-efficiency.sh.
# Builds throwaway .github trees under mktemp and runs the REAL checker on
# them, asserting exit code and an output fragment. Run directly; exit 1 on
# any failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
CHECKER="$SCRIPT_DIR/../check-ci-efficiency.sh"

pass=0
failed=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
n=0

# new — start a fresh fixture checkout; sets R.
new() { n=$((n + 1)); R="$TMP/r$n"; mkdir -p "$R/.github/workflows" "$R/.git"; }
wf() { cat > "$R/.github/workflows/$1"; }
dep() { cat > "$R/.github/dependabot.yml"; }

# check <name> <want-exit> <output fragment or ""> [checker args…]
check() {
  local name="$1" want="$2" frag="$3" out rc
  shift 3
  out="$("$CHECKER" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL $name: exit $rc, want $want"; printf '%s\n' "$out"; failed=$((failed + 1)); return
  fi
  if [ -n "$frag" ] && ! printf '%s' "$out" | grep -Fq -- "$frag"; then
    echo "FAIL $name: output lacks '$frag'"; printf '%s\n' "$out"; failed=$((failed + 1)); return
  fi
  pass=$((pass + 1))
}

new
wf ci.yml <<'Y'
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs: {}
Y
check "cancelling workflow is clean" 0 "ci-efficiency: OK" "$R"

new
wf ci.yml <<'Y'
on: [push, pull_request]
jobs: {}
Y
check "pull_request without cancel is drift" 1 "cancel  .github/workflows/ci.yml" "$R"

new
wf ci.yml <<'Y'
on:
  pull_request:
concurrency:
  group: x
  cancel-in-progress: false
jobs: {}
Y
check "a literal false does not count" 1 "never cancelled" "$R"

new
wf ci.yml <<'Y'
on:
  pull_request:
# cancel-in-progress: true
jobs: {}
Y
check "a commented-out setting does not count" 1 "never cancelled" "$R"

new
wf nightly.yml <<'Y'
on:
  schedule:
    - cron: '0 3 * * *'
jobs:
  a:
    if: github.event.pull_request.merged == false
Y
check "no pull_request trigger is not judged" 0 "ci-efficiency: OK" "$R"

new
wf writer.yml <<'Y'
on:
  pull_request_target:
    types: [opened]
jobs: {}
Y
check "pull_request_target is not judged" 0 "ci-efficiency: OK" "$R"

new
wf close.yml <<'Y'
# ci-efficiency: no-cancel — one short job per closed pull request
on:
  pull_request:
    types: [closed]
jobs: {}
Y
check "marker with a reason is skipped" 0 "ci-efficiency: OK" "$R"

new
wf close.yml <<'Y'
# ci-efficiency: no-cancel
on:
  pull_request:
jobs: {}
Y
check "marker without a reason is drift" 1 "no-cancel marker has no reason" "$R"

new
dep <<'Y'
version: 2
updates:
  - package-ecosystem: 'npm'
    directory: '/'
    groups:
      all:
        patterns: ['*']
  - package-ecosystem: github-actions
    directory: /
    # groups:
Y
check "ungrouped ecosystem is named" 1 "'github-actions' updates are not grouped" "$R"
out="$("$CHECKER" "$R" 2>&1)"
if printf '%s' "$out" | grep -q "'npm'"; then
  echo "FAIL grouped ecosystem was reported"; failed=$((failed + 1))
else
  pass=$((pass + 1))
fi

new
dep <<'Y'
version: 2
updates:
  - package-ecosystem: bun
    directory: /
    groups:
      all:
        patterns: ['*']
Y
check "fully grouped dependabot is clean" 0 "ci-efficiency: OK" "$R"

# --all: one clean and one drifting checkout, plus a directory with no .git.
A="$TMP/all"; mkdir -p "$A/good/.git" "$A/good/.github/workflows" \
  "$A/bad/.git" "$A/bad/.github/workflows" "$A/notrepo/.github/workflows"
printf 'on:\n  pull_request:\nconcurrency:\n  group: g\n  cancel-in-progress: true\n' > "$A/good/.github/workflows/ci.yml"
printf 'on:\n  pull_request:\n' > "$A/bad/.github/workflows/ci.yml"
printf 'on:\n  pull_request:\n' > "$A/notrepo/.github/workflows/ci.yml"
check "--all counts only git checkouts" 1 "2 checkout(s) with workflows, 1 with findings" --all "$A"
check "--all names the drifting repo" 1 "bad" --all "$A"

check "unknown flag is a usage error" 2 "" --nope
check "--all without a directory is a usage error" 2 "" --all
check "missing directory is a usage error" 2 "not a directory" "$TMP/absent"

echo "ci-efficiency.test: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
