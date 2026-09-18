#!/usr/bin/env bash
# check-tests-wired.sh — fail when a test file exists but no workflow runs it.
#
# A test under claude/scripts/tests/ or codex/tests/ only protects anything if
# a workflow invokes it. Three shipped unwired before this guard existed
# (review-multipart, codex-review-multipart, review-and-push), each caught by
# hand. This makes the wiring a CI assertion: every enumerated test file's
# repo-relative path must appear in ci.yml or smoke-install.yml with YAML
# comments stripped (a mention in a comment is not wiring), or in a test file
# those workflows already run (one level of transitivity, which is how
# codex-remote-recovery.test.sh reaches codex/tests/test_remote_control_recover.py).
#
# Usage:  check-tests-wired.sh [--quiet]   (--quiet: suppress the success line)

set -euo pipefail

QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
  esac
done

# Tests intentionally NOT wired — every entry carries the reason it cannot run
# in CI. Anything here is skipped.
OPT_OUT=(
  # Opt-in native regression: needs a real Codex binary passed via --codex plus
  # Python's websockets package (codex/README.md, "native regression").
  codex/tests/test_shared_server_native.py
)

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

# Bash 3.2 floor (no mapfile / arrays of globs): the enumeration is a glob list
# and the corpus is a plain string searched with grep -F.
TEST_GLOBS='claude/scripts/tests/*.test.sh claude/scripts/tests/*.test.py codex/tests/*.py'

strip_comments() { sed -E 's/(^|[[:space:]])#.*$//' "$@"; }

corpus=""
for wf in .github/workflows/ci.yml .github/workflows/smoke-install.yml; do
  [ -f "$wf" ] || { red "workflow missing: $wf"; continue; }
  corpus="$corpus
$(strip_comments "$wf")"
done

# Here-string, not a pipe: on a corpus this size grep -q exits at the first
# match, the writer takes SIGPIPE, and pipefail would report the hit as a miss.
wired() { grep -qF -- "$1" <<<"$corpus"; }

# One level of transitivity: a test the workflows run may invoke other test
# files, so its (comment-stripped) contents join the corpus before checking.
extra=""
for f in $TEST_GLOBS; do
  [ -e "$f" ] || continue
  wired "$f" && extra="$extra
$(strip_comments "$f")"
done
corpus="$corpus$extra"

is_opted_out() {
  local o
  for o in "${OPT_OUT[@]}"; do [ "$1" = "$o" ] && return 0; done
  return 1
}

for f in $TEST_GLOBS; do
  [ -e "$f" ] || continue
  is_opted_out "$f" && continue
  wired "$f" || red "test file not run by any workflow: $f"
done

if [ "$VIOLATIONS" -ne 0 ]; then
  echo "  Fix: add a step to the 'checks' job in .github/workflows/ci.yml, e.g."
  echo "      - name: <name> (self-test)"
  echo '        if: ${{ !cancelled() }}'
  echo "        run: claude/scripts/tests/<name>.test.sh"
  echo "  or add the path to OPT_OUT in check-tests-wired.sh with the reason it"
  echo "  cannot run in CI."
  exit 1
fi

[ "$QUIET" -eq 1 ] || green "tests-wired: OK — every non-opted-out test file is run by a workflow"
