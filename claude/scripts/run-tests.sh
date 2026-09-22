#!/usr/bin/env bash
# run-tests.sh — discover and run this repo's own test suites.
#
# dotfiles has no package.json / pyproject.toml, so nothing could answer the
# question "run this repo's tests" (#490): review-and-push.sh printed "no test
# framework detected — skipping" and shipped on a receipt that attested to no
# test run. This is that answer, and `.review-test` at the repo root points the
# wrapper at it.
#
# The suite list is the same enumeration check-tests-wired.sh asserts is wired
# into CI: claude/scripts/tests/*.test.sh and *.test.py. A suite's NAME is its
# filename with the .test.sh / .test.py suffix removed. Checkers are NOT run
# here — several sweep a live ~/.claude that CI and a fresh clone do not have;
# ci.yml runs them beside the suites.
#
# Usage:
#   run-tests.sh                      # every suite
#   run-tests.sh --list               # print the suite names, run nothing
#   run-tests.sh doc-refs jules-dispatch
#                                     # only the named suites
#   run-tests.sh --changed            # suites this branch's diff can affect
#   run-tests.sh --changed --base upstream/main
#   run-tests.sh --verbose            # stream every suite's output
#
# Exit status: 0 when no selected suite failed, 1 otherwise. Selecting nothing
# is never a green run — an unknown name, an empty repo, or a --changed mapping
# the heuristic cannot attribute all fail or widen rather than report success
# having tested nothing.

set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT" || exit 1

TESTS_DIR="claude/scripts/tests"
PROPERTY_REQUIREMENTS="$TESTS_DIR/requirements-property.txt"

LIST_ONLY=0
CHANGED=0
VERBOSE=0
BASE_REF="origin/main"
REQUESTED=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --changed) CHANGED=1 ;;
    --verbose | -v) VERBOSE=1 ;;
    --base)
      [ "$#" -ge 2 ] || { echo "error: --base needs a git ref" >&2; exit 1; }
      BASE_REF="$2"
      shift
      ;;
    --base=*) BASE_REF="${1#--base=}" ;;
    -h | --help)
      sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

# ── Discovery ───────────────────────────────────────────────────────
# Bash 3.2 floor (no mapfile): the enumeration is a glob and the corpus of
# names is a newline-separated string.
SUITE_FILES=()
SUITE_NAMES=()
for f in "$TESTS_DIR"/*.test.sh "$TESTS_DIR"/*.test.py; do
  [ -e "$f" ] || continue
  SUITE_FILES+=("$f")
  name="$(basename "$f")"
  name="${name%.test.sh}"
  name="${name%.test.py}"
  SUITE_NAMES+=("$name")
done

if [ "${#SUITE_FILES[@]}" -eq 0 ]; then
  echo "error: no test suites found under $TESTS_DIR/ — expected *.test.sh or *.test.py" >&2
  exit 1
fi

# suite_index <name> — echo the index of <name>, or nothing when unknown.
suite_index() {
  local i
  for i in "${!SUITE_NAMES[@]}"; do
    [ "${SUITE_NAMES[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

# ── Selection ───────────────────────────────────────────────────────
# SELECTED holds indices into SUITE_FILES, in discovery order.
SELECTED=()
select_all() {
  local i
  SELECTED=()
  for i in "${!SUITE_FILES[@]}"; do SELECTED+=("$i"); done
}

# add_selected <name> — append <name>'s index once, ignoring an unknown name
# (callers that must reject one check first).
add_selected() {
  local idx sel
  idx="$(suite_index "$1")" || return 0
  for sel in ${SELECTED[@]+"${SELECTED[@]}"}; do
    [ "$sel" = "$idx" ] && return 0
  done
  SELECTED+=("$idx")
}

# ── --changed: which suites can this branch's diff affect? ──────────
# The mapping is a heuristic — a test file names its subject, but nothing
# declares the relationship — so it is built to widen, never to narrow by
# accident. A changed path resolves to suites two ways, and BOTH are applied:
#   1. it IS a suite's test file (which also selects any suite that imports it);
#   2. some suite's source mentions its basename, or its stem names a suite
#      (claude/scripts/check-doc-truth.sh -> the doc-truth suite).
# Rule 2 follows names TRANSITIVELY, to a FIXPOINT rather than to a depth limit:
# no suite mentions gate-lib.sh, it is reached through codex-review-gate.sh, and
# the installer suites reach the root lib-symlinks.sh only through setup.sh — so
# a scan that stopped early would drop a genuinely affected suite while still
# finding enough others that the widening fallback never fired. The visited set
# makes the walk terminate (a finite set of file names), and it stops early once
# every suite is selected, since nothing can widen further.
# A path neither rule can attribute makes the whole run fall back to every suite.
# So does an unresolvable base ref and an empty diff. CI remains the place where
# everything runs regardless.

# build_scan_files — the files a name can travel through: every TRACKED file
# except the suites themselves, which are the terminal layer. Deliberately not a
# curated glob. Two curated versions of this list were both wrong — the first
# missed claude/scripts' own libraries, the second missed the root-level
# setup.sh/lib-symlinks.sh pair the installer suites exercise — because a
# hand-picked dependency list is a denylist by another name. Tracked-everything
# can only over-select, and over-selecting costs time rather than coverage.
SCAN_FILES=()
build_scan_files() {
  SCAN_FILES=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$TESTS_DIR"/*) continue ;; esac
    [ -f "$f" ] && SCAN_FILES+=("$f")
  done <<EOF
$(git ls-files)
EOF
}

changed_paths() {
  local merge_base
  git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || return 1
  merge_base="$(git merge-base HEAD "$BASE_REF")" || return 1
  [ -n "$merge_base" ] || return 1
  # --no-renames: with rename detection on, a rename reports only its
  # destination, so renaming a suite would select the new name and never see the
  # old one — which other suites may still reference by its former filename. As
  # a delete plus an add, the old path is an unmappable test path and widens the
  # run instead.
  git diff --no-renames --name-only "$merge_base" -- || return 1
  git ls-files --others --exclude-standard || return 1
}

# seed_for_path <path> — select what <path> directly attributes and set
# SEED_NAME to the name the transitive walk should start from, plus SEED_HIT when
# a suite was selected outright. Exit 1 when <path> is a test file no discovered
# suite answers to. It reports through globals rather than stdout because it calls
# add_selected: inside a command substitution that selection would be made in a
# subshell and lost.
SEED_NAME=""
SEED_HIT=""
seed_for_path() {
  local path="$1" base own stem hit
  base="$(basename "$path")"

  # A changed test file selects its own suite — and still seeds the walk, because
  # a suite may IMPORT another's (workflow-shipping-rewrites.test.py reuses
  # workflow-shipping.test.py's fixtures) and selecting only the changed file
  # would let failures confined to the importing suite escape the run. A test
  # path that names no discovered suite is unmappable, not "mappable to
  # nothing": a branch that DELETES or RENAMES a suite while touching another
  # mappable file would otherwise narrow the run to the survivor.
  case "$path" in
    "$TESTS_DIR"/*.test.sh | "$TESTS_DIR"/*.test.py)
      own="${base%.test.sh}"
      own="${own%.test.py}"
      suite_index "$own" >/dev/null || return 1
      add_selected "$own"
      SEED_HIT=1
      ;;
  esac

  # A script whose stem names a suite is that suite's subject even when the suite
  # reaches it through a variable rather than a literal.
  stem="${base%.sh}"
  stem="${stem%.py}"
  for hit in "$stem" "${stem#check-}"; do
    if suite_index "$hit" >/dev/null; then
      add_selected "$hit"
      SEED_HIT=1
    fi
  done

  SEED_NAME="$base"
}

# walk_references <seed name> — follow the name to a FIXPOINT: every file that
# mentions it hands its OWN name on, so a shared library reaches the suites of
# its callers' callers and a suite that imports another suite is reached through
# it. Sets WALK_HIT when any suite was matched, which is how the caller knows
# THIS path reached a suite (a plain selection count cannot tell: an earlier
# path may already have selected the same suite). `visited` makes it terminate;
# a full selection stops it early, since nothing can widen further.
WALK_HIT=""
walk_references() {
  local frontier="$1" next visited="" name hit suite
  while [ -n "$frontier" ]; do
    next=""
    for name in $frontier; do
      printf '%s' "$visited" | grep -qxF -- "$name" && continue
      visited="$visited$name
"
      for hit in $(grep -lF -- "$name" "${SUITE_FILES[@]}" 2>/dev/null); do
        hit="$(basename "$hit")"
        suite="${hit%.test.sh}"
        suite="${suite%.test.py}"
        WALK_HIT=1
        add_selected "$suite"
        # ...and the suite's own filename travels on, so a suite that imports
        # THIS suite's fixtures is reached too.
        [ "$hit" = "$name" ] || next="$next$hit
"
      done
      [ "${#SELECTED[@]}" -lt "${#SUITE_FILES[@]}" ] || return 0
      # -I: a tracked binary can carry a matching byte sequence and has no
      # dependency to follow.
      for hit in $(grep -IlF -- "$name" ${SCAN_FILES[@]+"${SCAN_FILES[@]}"} 2>/dev/null); do
        hit="$(basename "$hit")"
        [ "$hit" = "$name" ] || next="$next$hit
"
      done
    done
    frontier="$next"
  done
}

if [ "${#REQUESTED[@]}" -gt 0 ]; then
  for name in "${REQUESTED[@]}"; do
    if ! suite_index "$name" >/dev/null; then
      echo "error: unknown test suite: $name" >&2
      echo "       run '$(basename "${BASH_SOURCE[0]}") --list' for the suite names." >&2
      exit 1
    fi
    add_selected "$name"
  done
  if [ "$CHANGED" -eq 1 ]; then
    echo "error: --changed and an explicit suite list are mutually exclusive." >&2
    exit 1
  fi
elif [ "$CHANGED" -eq 1 ]; then
  if ! paths="$(changed_paths)"; then
    yellow "--changed: cannot resolve '$BASE_REF' (or read the diff) — running every suite."
    select_all
  elif [ -z "$paths" ]; then
    yellow "--changed: no changes against $BASE_REF — running every suite."
    select_all
  else
    build_scan_files
    fallback=""
    # EVERY changed path must reach at least one suite on its own. Checking only
    # that the combined selection is non-empty would let one mappable path speak
    # for an unmapped sibling: a change to alpha.sh plus a config nothing tests
    # would have run alpha alone.
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      SEED_HIT=""
      WALK_HIT=""
      if seed_for_path "$path"; then
        walk_references "$SEED_NAME"
      fi
      if [ -z "$SEED_HIT" ] && [ -z "$WALK_HIT" ]; then
        yellow "--changed: cannot attribute '$path' to any suite — running every suite."
        fallback=1
        break
      fi
    done <<< "$paths"
    if [ -n "$fallback" ] || [ "${#SELECTED[@]}" -eq 0 ]; then
      [ -n "$fallback" ] ||
        yellow "--changed: the changed paths map to no suite — running every suite."
      select_all
    fi
  fi
else
  select_all
fi

# --list after selection, not before: `--list --changed` is how the mapping
# heuristic is inspected without paying for a run.
if [ "$LIST_ONLY" -eq 1 ]; then
  for i in "${SELECTED[@]}"; do printf '%s\n' "${SUITE_NAMES[$i]}"; done
  exit 0
fi

# ── Optional dependencies ───────────────────────────────────────────
# The *.property.test.py suites import Hypothesis unconditionally and exit with
# an install command rather than skipping, which is right for CI (a missing
# dependency must be a red run, not silent zero coverage) and wrong for a fresh
# clone, where it would make every local run red. Probe for the module and
# report a NAMED skip instead — the summary says which suites did not run and
# how to install what they need.
HAVE_HYPOTHESIS=""
suite_missing_dep() {
  case "$1" in
    *.property.test.py)
      if [ -z "$HAVE_HYPOTHESIS" ]; then
        if python3 -c "import hypothesis" >/dev/null 2>&1; then
          HAVE_HYPOTHESIS=yes
        else
          HAVE_HYPOTHESIS=no
        fi
      fi
      [ "$HAVE_HYPOTHESIS" = no ] && {
        echo "hypothesis is not installed: python3 -m pip install --user -r $PROPERTY_REQUIREMENTS"
        return 0
      }
      ;;
  esac
  return 1
}

# ── Run ─────────────────────────────────────────────────────────────
total_suites="${#SUITE_FILES[@]}"
run_count="${#SELECTED[@]}"
echo "═══ Running $run_count of $total_suites test suites ═══"
echo ""

width=0
for i in "${SELECTED[@]}"; do
  [ "${#SUITE_NAMES[$i]}" -gt "$width" ] && width="${#SUITE_NAMES[$i]}"
done

RESULTS=()
passed=0
failed=0
skipped=0
run_start="$SECONDS"

for i in "${SELECTED[@]}"; do
  file="${SUITE_FILES[$i]}"
  name="${SUITE_NAMES[$i]}"
  if reason="$(suite_missing_dep "$file")"; then
    skipped=$((skipped + 1))
    RESULTS+=("$(printf 'SKIP  %-*s  %4s  %s' "$width" "$name" "-" "$reason")")
    yellow "skip $name — $reason"
    continue
  fi
  runner=(bash "$file")
  case "$file" in *.py) runner=(python3 "$file") ;; esac
  suite_start="$SECONDS"
  rc=0
  if [ "$VERBOSE" -eq 1 ]; then
    echo "── $name ──"
    "${runner[@]}" || rc=$?
  else
    # Output is withheld on success: 49 suites of scrollback buries the summary.
    out="$("${runner[@]}" 2>&1)" || rc=$?
  fi
  elapsed=$((SECONDS - suite_start))
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
    RESULTS+=("$(printf 'PASS  %-*s  %3ss' "$width" "$name" "$elapsed")")
  else
    failed=$((failed + 1))
    RESULTS+=("$(printf 'FAIL  %-*s  %3ss  (exit %s)' "$width" "$name" "$elapsed" "$rc")")
    if [ "$VERBOSE" -eq 0 ]; then
      echo "── $name FAILED (exit $rc) ──"
      printf '%s\n' "$out" | sed 's/^/  | /'
      echo ""
    fi
  fi
done

wall=$((SECONDS - run_start))

echo ""
echo "═══ Test summary ═══"
printf '  %s\n' "${RESULTS[@]}"
echo "  ---"
echo "  $passed passed, $failed failed, $skipped skipped of $run_count run (${total_suites} discovered) in ${wall}s"

[ "$failed" -eq 0 ]
