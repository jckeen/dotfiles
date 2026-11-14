#!/usr/bin/env bash
# check-ci-efficiency.sh — report where a repo's CI config wastes hosted minutes.
#
# The mechanical half of the CI cost standard: the full suite runs once per
# merge, on the commit that lands, and every other run is cheap.
# Read-only and offline — it reads the checkout's .github/ directory and
# nothing else. Two rules can be asserted from files alone:
#
#   cancel   a workflow triggered by pull_request sets `cancel-in-progress`
#            (to anything but a literal false), so a new push stops the run
#            it supersedes.
#            `pull_request_target` is not judged: those workflows are
#            privileged writers (labels, statuses), not test suites, and
#            several must run to completion.
#   groups   every `updates` entry in .github/dependabot.yml has `groups`, so
#            routine updates share one pull request, and one CI run.
#
# The rest of the standard (path-selected jobs behind one aggregate check, no
# repeat run on the default branch, merge queue for long suites) is a design
# decision per repo and is not judged here.
#
# A workflow that must not cancel carries a line of the form
#   # ci-efficiency: no-cancel — <reason>
# and is skipped; the marker without a reason is itself reported.
#
# Usage:
#   check-ci-efficiency.sh [DIR]        # one checkout (default: cwd)
#   check-ci-efficiency.sh --all DIR    # every git checkout directly in DIR
# Exit: 0 clean, 1 drift found, 2 usage error.

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

strip_comments() { sed -E 's/(^|[[:space:]])#.*$//' "$1"; }

# check_repo DIR — print one line per finding; return 1 when any was printed.
check_repo() {
  local dir="$1" wf body found=0 name
  for wf in "$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    name=".github/workflows/$(basename "$wf")"
    body="$(strip_comments "$wf")"
    printf '%s\n' "$body" \
      | grep -Eq '(^|[[:space:],[])pull_request([]:,[:space:]]|$)' || continue
    if grep -Eq '^[[:space:]]*#[[:space:]]*ci-efficiency:[[:space:]]*no-cancel' "$wf"; then
      grep -Eq '^[[:space:]]*#[[:space:]]*ci-efficiency:[[:space:]]*no-cancel[^[:alnum:]]+[[:alnum:]]' "$wf" \
        || { echo "  cancel  $name: no-cancel marker has no reason"; found=1; }
      continue
    fi
    if ! printf '%s\n' "$body" | grep -E '^[[:space:]]*cancel-in-progress:' \
        | grep -Evq 'cancel-in-progress:[[:space:]]*false[[:space:]]*$'; then
      echo "  cancel  $name: pull_request runs are never cancelled when superseded"
      found=1
    fi
  done
  local dep
  for dep in "$dir/.github/dependabot.yml" "$dir/.github/dependabot.yaml"; do
    [ -f "$dep" ] || continue
    # One record per `- package-ecosystem:` entry; flag each without `groups:`.
    while IFS= read -r eco; do
      [ -n "$eco" ] || continue
      echo "  groups  .github/$(basename "$dep"): '$eco' updates are not grouped"
      found=1
    done < <(strip_comments "$dep" | awk '
      function flush() { if (eco != "" && !grouped) print eco }
      /^[[:space:]]*-[[:space:]]*package-ecosystem:/ {
        flush(); eco = $0; sub(/^.*package-ecosystem:[[:space:]]*/, "", eco)
        gsub(/["\047[:space:]]/, "", eco); grouped = 0; next
      }
      /^[[:space:]]+groups:[[:space:]]*$/ { grouped = 1 }
      END { flush() }')
  done
  return "$found"
}

main() {
  local all="" target="."
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --all) all="${2:-}"; [ -n "$all" ] && [ $# -eq 2 ] || { usage >&2; exit 2; } ;;
    -*) usage >&2; exit 2 ;;
    *) [ $# -le 1 ] || { usage >&2; exit 2; }; target="${1:-.}" ;;
  esac

  local drift=0 checked=0 d out
  if [ -n "$all" ]; then
    [ -d "$all" ] || { echo "not a directory: $all" >&2; exit 2; }
    for d in "$all"/*/; do
      d="${d%/}"
      [ -e "$d/.git" ] && [ -d "$d/.github/workflows" ] || continue
      checked=$((checked + 1))
      if ! out="$(check_repo "$d")"; then
        drift=$((drift + 1)); basename "$d"; echo "$out"
      fi
    done
    echo "ci-efficiency: $checked checkout(s) with workflows, $drift with findings"
  else
    [ -d "$target" ] || { echo "not a directory: $target" >&2; exit 2; }
    if ! out="$(check_repo "$target")"; then
      drift=1; echo "$out"
    else
      echo "ci-efficiency: OK"
    fi
  fi
  [ "$drift" -eq 0 ]
}

main "$@"
