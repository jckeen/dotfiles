#!/usr/bin/env bash
# ci-efficiency.test.sh — fixture tests for check-ci-efficiency.py.
# Builds throwaway .github trees under mktemp and runs the REAL checker on
# them, asserting exit code and an output fragment. Run directly; exit 1 on
# any failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
CHECKER="$SCRIPT_DIR/../check-ci-efficiency.py"

python3 -c 'import yaml' 2>/dev/null \
  || { echo "ci-efficiency.test: PyYAML is not installed" >&2; exit 1; }

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
check "the finding names the way out" 1 "ci-efficiency: no-cancel" "$R"

new
wf ci.yml <<'Y'
on:
  pull_request:
concurrency:
  group: x
  cancel-in-progress: false
jobs: {}
Y
check "a literal false does not count" 1 "cannot confirm" "$R"

new
wf ci.yml <<'Y'
on:
  pull_request:
# cancel-in-progress: true
jobs: {}
Y
check "a commented-out setting does not count" 1 "cannot confirm" "$R"

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
check "ungrouped ecosystem is named" 1 "'github-actions' updates for '/' are not grouped" "$R"
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

# --- Cases a text search gets wrong; the checker parses the YAML -------------
new
wf ci.yml <<'Y'
"on":
  "pull_request":
    branches: [main]
jobs: {}
Y
check "quoted trigger keys are read" 1 "cannot confirm" "$R"

new
wf push.yml <<'Y'
on:
  push:
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo pull_request
Y
check "the word in a run step is not a trigger" 0 "ci-efficiency: OK" "$R"

new
wf ci.yml <<'Y'
on: pull_request
concurrency: {group: "ci-${{ github.ref }}", cancel-in-progress: true}
jobs: {}
Y
check "inline concurrency mapping counts" 0 "ci-efficiency: OK" "$R"

new
wf ci.yml <<'Y'
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cancel-in-progress: true
Y
check "the setting inside a run block does not count" 1 "cannot confirm" "$R"

new
wf ci.yml <<'Y'
on: pull_request
concurrency: ci-${{ github.ref }}
jobs: {}
Y
check "a bare group name cancels nothing" 1 "cannot confirm" "$R"

new
wf ci.yml <<'Y'
on: pull_request
jobs:
  a:
    concurrency: {group: "a-${{ github.ref }}", cancel-in-progress: true}
  b:
    concurrency: {group: "b-${{ github.head_ref }}", cancel-in-progress: "${{ github.event_name == 'pull_request' }}"}
Y
check "every job cancelling counts" 0 "ci-efficiency: OK" "$R"

new
wf ci.yml <<'Y'
on: pull_request
jobs:
  a:
    concurrency: {group: "a-${{ github.ref }}", cancel-in-progress: true}
  b:
    runs-on: ubuntu-latest
Y
check "one job without cancellation is drift" 1 "cannot confirm" "$R"

# A workflow far larger than a pipe buffer is still judged.
new
{
  printf 'on:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n'
  i=0
  while [ "$i" -lt 4000 ]; do printf '      - run: echo step-%s\n' "$i"; i=$((i + 1)); done
} > "$R/.github/workflows/big.yml"
check "a very long workflow is still judged" 1 "big.yml" "$R"

new
wf broken.yml <<'Y'
on: [pull_request
jobs: {}
Y
check "unparsable YAML is reported, not passed" 1 "parse   .github/workflows/broken.yml" "$R"

new
dep <<'Y'
version: 2
updates:
  - directory: /
    package-ecosystem: npm
    schedule: {interval: weekly}
Y
check "key order does not hide an entry" 1 "'npm' updates for '/' are not grouped" "$R"

new
dep <<'Y'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    groups: {}
Y
check "an empty groups mapping is not grouping" 1 "'npm' updates" "$R"

new
rmdir "$R/.github/workflows"
check "a checkout with no CI config says so" 0 "no CI config to check" "$R"

# --all also audits a checkout that has only a Dependabot config.
D="$TMP/deponly"; mkdir -p "$D/x/.git" "$D/x/.github"
printf 'version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n' > "$D/x/.github/dependabot.yml"
check "--all includes Dependabot-only checkouts" 1 "1 checkout(s) with CI config, 1 with findings" --all "$D"

# --- Forms GitHub evaluates at run time: only recognised ones are confirmed ---
for expr in '${{ false }}' "\${{ github.event_name == 'push' }}" '${{ inputs.cancel }}'; do
  new
  printf 'on: pull_request\nconcurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: %s\njobs: {}\n' "$expr" \
    > "$R/.github/workflows/ci.yml"
  check "unrecognised expression is unconfirmed: $expr" 1 "cannot confirm" "$R"
done

for group in 'ci-${{ github.run_id }}' 'ci' '${{ github.sha }}'; do
  new
  printf 'on: pull_request\nconcurrency:\n  group: %s\n  cancel-in-progress: true\njobs: {}\n' "$group" \
    > "$R/.github/workflows/ci.yml"
  check "group that pairs no two pushes is unconfirmed: $group" 1 "cannot confirm" "$R"
done

new
wf ci.yml <<'Y'
on:
  pull_request:
  push:
concurrency:
  group: ci-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs: {}
Y
check "per-run group off pull requests is recognised" 0 "ci-efficiency: OK" "$R"

new
wf ci.yml <<'Y'
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cat <<'F'
          # ci-efficiency: no-cancel — example fixture data
          F
Y
check "a marker inside a script is not a marker" 1 "cannot confirm" "$R"

new
wf ci.yml <<'Y'
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo hi
# ci-efficiency: no-cancel — must run to completion
Y
check "a comment after a script is a marker" 0 "ci-efficiency: OK" "$R"

new
dep <<'Y'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    groups:
      sec:
        applies-to: security-updates
        patterns: ["*"]
Y
check "a security-only group is not routine grouping" 1 "'npm' updates" "$R"

new
dep <<'Y'
version: 2
multi-ecosystem-groups:
  infra:
    schedule: {interval: weekly}
updates:
  - package-ecosystem: docker
    directory: /
    patterns: ["*"]
    multi-ecosystem-group: infra
  - package-ecosystem: terraform
    directory: /
    patterns: ["*"]
    multi-ecosystem-group: infra
Y
check "multi-ecosystem groups count as grouped" 0 "ci-efficiency: OK" "$R"

# --all: one clean and one drifting checkout, plus a directory with no .git.
A="$TMP/all"; mkdir -p "$A/good/.git" "$A/good/.github/workflows" \
  "$A/bad/.git" "$A/bad/.github/workflows" "$A/notrepo/.github/workflows"
printf 'on:\n  pull_request:\nconcurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true\n' > "$A/good/.github/workflows/ci.yml"
printf 'on:\n  pull_request:\n' > "$A/bad/.github/workflows/ci.yml"
printf 'on:\n  pull_request:\n' > "$A/notrepo/.github/workflows/ci.yml"
check "--all counts only git checkouts" 1 "2 checkout(s) with CI config, 1 with findings" --all "$A"
check "--all names the drifting repo" 1 "bad" --all "$A"

# One bad file is a finding, never a hang or a traceback, and --all goes on.
new
wf ci.yml <<'Y'
on: pull_request
jobs: &jobs
  a: *jobs
Y
out="$(timeout 10 "$CHECKER" "$R" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq "cannot confirm"; then pass=$((pass + 1))
else echo "FAIL a self-containing anchor ends: exit $rc"; printf '%s\n' "$out"; failed=$((failed + 1)); fi

new
printf '\xff\xfe on: pull_request\n' > "$R/.github/workflows/ci.yml"
check "a file that is not UTF-8 is a parse finding" 1 "parse   .github/workflows/ci.yml" "$R"

if [ "$(id -u)" -ne 0 ]; then
  B="$TMP/all2"; mkdir -p "$B/a/.git" "$B/a/.github/workflows" "$B/b/.git" "$B/b/.github/workflows"
  printf 'on:\n  pull_request:\n' > "$B/a/.github/workflows/ci.yml"; chmod 000 "$B/a/.github/workflows/ci.yml"
  printf 'on:\n  pull_request:\n' > "$B/b/.github/workflows/ci.yml"
  check "an unreadable workflow is a parse finding" 1 "parse   .github/workflows/ci.yml" --all "$B"
  check "--all goes on past an unreadable workflow" 1 "2 checkout(s) with CI config, 2 with findings" --all "$B"
  chmod 600 "$B/a/.github/workflows/ci.yml"
fi

check "unknown flag is a usage error" 2 "" --nope
check "--all without a directory is a usage error" 2 "" --all
check "missing directory is a usage error" 2 "not a directory" "$TMP/absent"

echo "ci-efficiency.test: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
