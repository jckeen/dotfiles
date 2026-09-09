#!/usr/bin/env bash
# review-and-push.sh — Review overnight changes, then push if safe
# Uses the required Codex gate and validates its receipt immediately before push.
#
# Flow:
#   1. Check for uncommitted/committed changes since last push
#   2. Run tests — STOP if they fail
#   3. Run the required Codex review gate on the committed delta
#   4. Prompt to push (or accept --auto-push)
#   5. Validate the current review receipt, then push
#
# Usage:
#   review-and-push.sh /path/to/repo              # interactive (prompts before push)
#   review-and-push.sh /path/to/repo --auto-push   # push automatically if safe
#
# Run this in the morning after overnight.sh finishes.

# Preserve path bytes while removing only each command's output terminator.
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}" && printf .)" || exit 1
SCRIPT_DIR=${SCRIPT_DIR%$'\n.'}
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd && printf .)" || exit 1
SCRIPT_DIR=${SCRIPT_DIR%$'\n.'}
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

AUTO_PUSH=false

# Extended parse_args to handle --auto-push
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --auto-push) AUTO_PUSH=true ;;
    *) FILTERED_ARGS+=("$arg") ;;
  esac
done
parse_args "${FILTERED_ARGS[@]}"

cd "$REPO_DIR" || exit 1
REPO_NAME=$(basename "$REPO_DIR")
BRANCH_REF=$(git symbolic-ref --quiet HEAD) || {
  echo "Create a non-default branch before reviewing and pushing." >&2
  exit 1
}
REVIEWED_HEAD=$(git rev-parse HEAD)
check_review_target() {
  if [[ "$(git symbolic-ref --quiet HEAD)" != "$BRANCH_REF" ]]; then
    echo "Branch changed during tests or review; run tests and review again on the intended branch." >&2
    return 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$REVIEWED_HEAD" ]]; then
    echo "Commit changed during tests or review; run tests and review again on the intended commit." >&2
    return 1
  fi
}
BRANCH=${BRANCH_REF#refs/heads/}
# Preserve configured newline bytes; remove only the sentinel and Git's terminator.
REMOTE=$(
  {
    git config --get "branch.$BRANCH.pushRemote" ||
      git config --get remote.pushDefault ||
      git config --get "branch.$BRANCH.remote" || printf '%s\n' origin
  } && printf .
)
REMOTE=${REMOTE%.}
REMOTE=${REMOTE%$'\n'}
if [[ -z "$REMOTE" || "$REMOTE" == *$'\n'* ]]; then
  echo "Review and push requires one unambiguous push remote." >&2
  exit 1
fi
PUSH_URL=$(git remote get-url --push --all -- "$REMOTE" && printf .)
PUSH_URL=${PUSH_URL%.}
PUSH_URL=${PUSH_URL%$'\n'}
if [[ -z "$PUSH_URL" || "$PUSH_URL" == *$'\n'* ]]; then
  echo "Review and push requires one unambiguous push destination." >&2
  exit 1
fi

PUSH_CREATION_LEASE=()
check_destination() {
  local remote_refs default_ref symbolic_destination destination_tip alias_status=0
  # Some Git versions discard earlier URLs when an empty value resets the
  # list. Validate raw values across config scopes before trusting that result.
  if ! python3 - "$REMOTE" <<'PY'
import subprocess
import sys

for field in ("pushurl", "url"):
    configured = subprocess.run(
        ["git", "config", "--null", "--get-all", f"remote.{sys.argv[1]}.{field}"],
        stdout=subprocess.PIPE,
    )
    if configured.returncode == 1:
        continue
    values = configured.stdout.split(b"\0")
    if (configured.returncode != 0 or len(values) != 2 or not values[0]
            or values[-1] or b"\n" in values[0]):
        sys.exit(1)
    break
PY
  then
    echo "Review and push requires one unambiguous push destination with no empty configured URLs." >&2
    return 1
  fi
  git remote get-url --push --all -- "$PUSH_URL" >/dev/null 2>&1 || alias_status=$?
  if [[ "$alias_status" != 2 ]]; then
    echo "Cannot pin the push destination: it names a configured remote, or remote configuration could not be read. Use a direct destination." >&2
    return 1
  fi
  # get-url already applied one rewrite. A second invocation must use the
  # same endpoint, including rules from global, local, and included config.
  if ! python3 - "$PUSH_URL" <<'PY'
import os
import subprocess
import sys

config = subprocess.run(
    ["git", "config", "--null", "--name-only", "--get-regexp",
     r"^(url\..*\.(insteadof|pushinsteadof)|remote\..*)$"],
    stdout=subprocess.PIPE,
)
if config.returncode not in (0, 1):
    sys.exit(1)
destination = os.fsencode(sys.argv[1])
for key in set(config.stdout.split(b"\0")) - {b""}:
    if key.startswith(b"remote."):
        if key.rsplit(b".", 1)[0] == b"remote." + destination:
            sys.exit(1)
        continue
    values = subprocess.run(
        ["git", "config", "--null", "--get-all", os.fsdecode(key)],
        stdout=subprocess.PIPE,
    )
    if values.returncode != 0 or any(
        destination.startswith(prefix) for prefix in values.stdout.split(b"\0")[:-1]
    ):
        sys.exit(1)
PY
  then
    echo "Cannot pin the push destination: a configured remote or Git URL rewrite may change it, or Git configuration could not be read. Use a direct destination without further rewrites." >&2
    return 1
  fi
  # Only protocol v2 advertises non-HEAD symrefs. An empty server option
  # makes Git reject a silent fallback to an older protocol.
  remote_refs=$(git -c protocol.version=2 ls-remote --symref --server-option= -- "$PUSH_URL" HEAD "$BRANCH_REF") || {
    echo "Cannot inspect destination branches: Git protocol v2 with server-option support is required." >&2
    return 1
  }
  default_ref=$(awk '$1 == "ref:" && $3 == "HEAD" && $2 ~ /^refs\/heads\// {print $2}' <<< "$remote_refs")
  if [[ -z "$default_ref" || "$default_ref" == *$'\n'* ]]; then
    echo "Cannot establish the push destination's default branch." >&2
    return 1
  fi
  if [[ "$BRANCH_REF" == "$default_ref" ]]; then
    echo "Create a non-default branch and pull request; this script does not push the default branch." >&2
    return 1
  fi
  symbolic_destination=$(awk -v branch="$BRANCH_REF" '$1 == "ref:" && $3 == branch {print $2}' <<< "$remote_refs")
  if [[ -n "$symbolic_destination" ]]; then
    echo "Cannot push to a symbolic destination branch; use a direct branch ref." >&2
    return 1
  fi
  destination_tip=$(awk -v branch="$BRANCH_REF" '$1 != "ref:" && $2 == branch {print $1}' <<< "$remote_refs")
  PUSH_CREATION_LEASE=()
  if [[ -z "$destination_tip" ]]; then
    # A ref hidden by upload-pack may still exist at receive-pack. The empty
    # expectation rejects any existing resolved OID; advertised refs keep
    # normal FF rules. Git cannot distinguish absent and dangling symrefs.
    PUSH_CREATION_LEASE=("--force-with-lease=$BRANCH_REF:")
  fi
}
check_destination

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Review & Push: $REPO_NAME"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: What changed? ────────────────────────────────────

UNSTAGED=$(git status --porcelain 2>/dev/null || echo "")

echo "═══ Current commit ═══"
git --no-replace-objects log -1 --oneline "$REVIEWED_HEAD"
echo ""

if [[ -n "$UNSTAGED" ]]; then
  echo "═══ Uncommitted changes ═══"
  echo "$UNSTAGED"
  echo ""
  echo "⚠ There are uncommitted changes. These will NOT be pushed."
  echo "  Review them manually or run the overnight scripts again."
  echo ""
fi

# ─── Step 2: Run tests ────────────────────────────────────────

echo "═══ Running tests ═══"
TEST_LOG=$(log_file "tests")

# Detect and run the test command
TEST_RESULT=0
if [[ -f "package.json" ]]; then
  npm test 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
  pytest 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "Cargo.toml" ]]; then
  cargo test 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
elif [[ -f "go.mod" ]]; then
  go test ./... 2>&1 | tee "$TEST_LOG" || TEST_RESULT=$?
else
  echo "(no test framework detected — skipping)"
fi

if [[ $TEST_RESULT -ne 0 ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  TESTS FAILED — not pushing.                        ║"
  echo "║  Fix the failures and try again.                    ║"
  echo "╚══════════════════════════════════════════════════════╝"
  exit 1
fi
echo ""

# ─── Step 3: Review the committed artifact ──────────────────────

check_review_target
"$SCRIPT_DIR/codex-review-gate.sh" --require --committed
check_review_target

if [[ "$AUTO_PUSH" != "true" ]]; then
  read -rp "Push to remote? (Y/n): " CONFIRM
  if [[ "$CONFIRM" != "" && "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted. Changes remain local."
    exit 0
  fi
fi

# The confirmation or another process may have changed the reviewed artifact.
check_review_target
check_destination
python3 "$SCRIPT_DIR/review-receipt.py" check --repo "$REPO_DIR" --head "$REVIEWED_HEAD" --reviewer codex
git push --no-follow-tags "${PUSH_CREATION_LEASE[@]}" -- "$PUSH_URL" "$REVIEWED_HEAD:$BRANCH_REF"
echo "Pushed."
