#!/usr/bin/env bash
# review-and-push.sh — Review overnight changes, then push if safe
# Routes the committed delta to the required review lane and validates the
# resulting receipt immediately before push.
#
# Flow:
#   1. Require a clean working tree and pin the commit to review
#   2. Run tests — STOP if they fail
#   3. Classify the committed delta and run the REQUIRED lane's gate on it
#   4. Prompt to push (or accept --auto-push)
#   5. Validate the current review receipt, then push
#
# Lane routing (ADR-0008): `review-receipt.py lane` classifies the committed
# delta and gate_select_lane picks the gate. Ordinary tier-2 work goes to the
# Antigravity gate; a risk surface keeps the Codex gate and is never
# downgradable; a tier-1 diff needs no reviewer dispatch and collects its
# exemption receipt through the cheapest lane. The receipt check at step 5 names
# the lane that was dispatched rather than a hardcoded one: review-receipt.py
# refuses any receipt whose lane ranks below what the diff requires, and naming
# the dispatched lane additionally requires the review this run performed to
# still be approved.
#
# Environment:
#   REVIEW_LANE=auto|codex|antigravity   override the lane (auto is the default;
#     `antigravity` on a codex-required diff is REFUSED, not honoured).
#   REVIEW_LANE_FALLBACK=codex|block     what to do when the Antigravity gate
#     exits 3 (could not run: agy missing, byte/line cap, unverifiable model
#     pin). Default `codex` re-runs the diff through the Codex gate and records
#     the degradation in the lane ledger; `block` refuses the push instead.
#     A blocking verdict (exit 2) never falls back — a refusal is not an outage.
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
# Lane selection is shared with both gates (ADR-0008).
# shellcheck source=gate-lib.sh
source "$SCRIPT_DIR/gate-lib.sh"

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

# cd does not override inherited repository/index/object routing. A routed
# checkout answers every checkpoint below while the tests run in REPO_DIR, so a
# clean alternate worktree can approve pushing REPO_DIR's unreviewed HEAD
# (#401). Reject the same evidence overrides as git-hygiene.sh — this is a copy
# of the guard at the top of that script — before touching any repository; only
# variable names belong in diagnostics. SSH/credential transport and defensive
# flags remain available.
git_environment_overrides=""
for git_environment_name in "${!GIT_@}"; do
  case "$git_environment_name" in
    GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_OBJECT_DIRECTORY|GIT_DIR|GIT_WORK_TREE|\
    GIT_IMPLICIT_WORK_TREE|GIT_COMMON_DIR|GIT_GRAFT_FILE|GIT_INDEX_FILE|\
    GIT_REPLACE_REF_BASE|GIT_PREFIX|GIT_SHALLOW_FILE|GIT_NAMESPACE|GIT_ATTR_SOURCE|\
    GIT_CONFIG|GIT_CONFIG_*)
      git_environment_overrides+="${git_environment_overrides:+, }$git_environment_name" ;;
  esac
done
if [[ -n "$git_environment_overrides" ]]; then
  echo "error: Git environment overrides prevent verifying the repository under review; unset: $git_environment_overrides" >&2
  exit 1
fi

cd "$REPO_DIR" || exit 1
REPO_NAME=$(basename "$REPO_DIR")
BRANCH_REF=$(git symbolic-ref --quiet HEAD) || {
  echo "Create a non-default branch before reviewing and pushing." >&2
  exit 1
}
REVIEWED_HEAD=$(git rev-parse HEAD)
check_review_target() {
  local uncommitted mode_drift
  if [[ "$(git symbolic-ref --quiet HEAD)" != "$BRANCH_REF" ]]; then
    echo "Branch changed during tests or review; run tests and review again on the intended branch." >&2
    return 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$REVIEWED_HEAD" ]]; then
    echo "Commit changed during tests or review; run tests and review again on the intended commit." >&2
    return 1
  fi
  # Status trusts index hints that can hide tracked edits. Inspect NUL-delimited
  # records without changing the index or interpreting filename bytes as tags.
  if ! python3 - <<'PY_INDEX'
import subprocess
import sys

listing = subprocess.run(["git", "ls-files", "-v", "-z"], stdout=subprocess.PIPE)
entries = listing.stdout.split(b'\0')
if listing.returncode != 0 or any(
    entry and (entry[:1].islower() or entry[:1] == b'S') for entry in entries
):
    sys.exit(1)
PY_INDEX
  then
    echo "Cannot verify tracked input: index flags may hide changes, or index inspection failed." >&2
    echo "Clear assume-unchanged/skip-worktree flags before running tests and review." >&2
    return 1
  fi
  if ! uncommitted=$(git -c core.fsmonitor=false status --porcelain=v1 --untracked-files=all --ignore-submodules=none); then
    echo "Cannot verify a clean working tree; not running tests, review, or push." >&2
    return 1
  fi
  if [[ -n "$uncommitted" ]]; then
    echo "There are uncommitted changes; commit or stash them before running tests and review for this push." >&2
    printf '%s\n' "$uncommitted" >&2
    return 1
  fi
  # With core.fileMode=false Git ignores the executable bit, so flipping it on a
  # tracked script leaves status silent and ls-files reporting an ordinary entry
  # while the tests run the locally executable file and the push ships the old
  # mode (#402). Compare index modes against the working tree directly.
  if ! mode_drift=$(python3 - <<'PY_MODES'
import os
import stat
import subprocess
import sys
import tempfile


def git(args):
    result = subprocess.run(["git"] + args, stdout=subprocess.PIPE)
    if result.returncode != 0:
        sys.exit(1)
    return result.stdout


# Git reports mode changes itself when it trusts the filesystem, so only the
# untrusted case needs this comparison.
if git(["config", "--type=bool", "--default=true", "--get", "core.fileMode"]).strip() == b"true":
    sys.exit(0)

# Paths are resolved against the work tree root so an invocation from a
# subdirectory still inspects every tracked file. rev-parse emits the path
# verbatim, so the bytes survive without quoting or decoding. Remove only
# Git's own terminator: stripping every trailing newline would silently
# retarget a directory whose name ends in one at its shorter sibling.
toplevel = git(["rev-parse", "--show-toplevel"]).removesuffix(b"\n")
if not toplevel or b"\n" in toplevel:
    sys.exit(1)

# Filesystems that record no executable bit report the same mode whatever is
# requested; comparing against the index there would be noise, not drift.
probe_handle, probe = tempfile.mkstemp(dir=toplevel, prefix=b".review-and-push-mode-probe")
try:
    os.close(probe_handle)
    os.chmod(probe, 0o644)
    without_bit = os.lstat(probe).st_mode
    os.chmod(probe, 0o755)
    with_bit = os.lstat(probe).st_mode
finally:
    os.unlink(probe)
if without_bit & stat.S_IXUSR or not with_bit & stat.S_IXUSR:
    sys.exit(0)

# ":/" anchors the listing at the work tree root regardless of the caller's
# directory; -z keeps filename bytes intact.
for record in git(["ls-files", "-s", "-z", "--full-name", "--", ":/"]).split(b"\0"):
    if not record:
        continue
    header, _, path = record.partition(b"\t")
    fields = header.split(b" ")
    if len(fields) != 3 or not path:
        sys.exit(1)
    mode, _, stage = fields
    # Only regular blobs at stage 0 carry an executable bit worth comparing;
    # symlinks, gitlinks, and conflicted entries are Git's business, not ours.
    if stage != b"0" or mode not in (b"100644", b"100755"):
        continue
    try:
        on_disk = os.lstat(os.path.join(toplevel, path)).st_mode
    except OSError:
        # A missing or unreadable path is already a working-tree finding.
        continue
    if not stat.S_ISREG(on_disk):
        continue
    actual = b"100755" if on_disk & stat.S_IXUSR else b"100644"
    if actual != mode:
        sys.stdout.buffer.write(b"  %s in index, %s on disk: %s\n" % (mode, actual, path))
PY_MODES
  ); then
    echo "Cannot verify tracked file modes; not running tests, review, or push." >&2
    return 1
  fi
  if [[ -n "$mode_drift" ]]; then
    echo "Tracked executable bits differ from the index and core.fileMode hides them from status; record or restore them before running tests and review for this push." >&2
    printf '%s\n' "$mode_drift" >&2
    return 1
  fi
}
check_review_target
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
else:
    sys.exit(1)
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

echo "═══ Current commit ═══"
git --no-replace-objects log -1 --oneline "$REVIEWED_HEAD"
echo ""

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

REVIEW_LANE_FALLBACK="${REVIEW_LANE_FALLBACK:-codex}"
case "$REVIEW_LANE_FALLBACK" in
  codex|block) ;;
  *)
    echo "error: REVIEW_LANE_FALLBACK must be codex or block (got '$REVIEW_LANE_FALLBACK')." >&2
    exit 1
    ;;
esac

# `lane` is read-only — it mints nothing, so classifying here cannot invalidate
# a receipt, and a classification failure stops the run rather than guessing.
#
# The cap MUST be the one the gate will capture into the receipt
# (gate_extract_diff passes GATE_TIER1_MAX_LINES the same way). Classifying
# under a different policy can route an ordinary diff to Antigravity while the
# receipt that run mints requires Codex — and because the gate exited 0 nothing
# degrades, so the push dead-ends at the final receipt check with no fallback.
if ! LANE_JSON=$(python3 "$SCRIPT_DIR/review-receipt.py" lane --repo "$REPO_DIR" \
  --scope committed "--tier1-max-lines=${GATE_TIER1_MAX_LINES:-200}"); then
  echo "Cannot classify the committed delta; not reviewing or pushing." >&2
  exit 1
fi
if ! REQUIRED_LANE=$(printf '%s' "$LANE_JSON" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["required_lane"])'); then
  echo "Cannot read the lane classification; not reviewing or pushing." >&2
  exit 1
fi
# GATE_FORCE_FULL=1 makes gate_classify_tier skip classification and keep the
# strongest lane. The `lane` helper does not read that flag, so mirror it here:
# otherwise an ordinary diff is dispatched to Antigravity, whose gate announces
# itself as supplementary, while the receipt check (which recomputes the
# ordinary classification) still ships it — the forced full pass would be
# honoured by the gate's message and by nothing else.
if [[ "${GATE_FORCE_FULL:-0}" == "1" ]]; then
  REQUIRED_LANE=codex
fi
DISPATCH_LANE=$(gate_select_lane "$REQUIRED_LANE") || exit 1

run_review_gate() {
  case "$1" in
    codex)       "$SCRIPT_DIR/codex-review-gate.sh" --require --committed ;;
    antigravity) "$SCRIPT_DIR/antigravity-review-gate.sh" --require --committed ;;
    *)           echo "error: unknown review lane '$1'." >&2; return 1 ;;
  esac
}

if [[ "$DISPATCH_LANE" == skip ]]; then
  echo "═══ Review lane: none required (tier-1 diff) ═══"
  echo "Collecting the tier-1 exemption receipt through the Antigravity gate;"
  echo "its tier valve mints the receipt without dispatching a reviewer."
  DISPATCH_LANE=antigravity
else
  echo "═══ Review lane: $DISPATCH_LANE (required: $REQUIRED_LANE) ═══"
fi

# Namespaced deliberately: a bare GATE_* name here would be re-exported into
# the gate's own environment if the caller had one set, silently overriding it.
REVIEW_GATE_RC=0
run_review_gate "$DISPATCH_LANE" || REVIEW_GATE_RC=$?
# Exit 3 means the lane could not run at all — agy missing, a diff above its
# byte/line cap, an unverifiable model pin. Exit 2 is a verdict (blocking
# findings, or a verifiably wrong model) and must NEVER fall back: a refusal is
# not an outage, and re-asking a different reviewer would be verdict shopping.
if [[ "$REVIEW_GATE_RC" -eq 3 && "$DISPATCH_LANE" == antigravity ]]; then
  if [[ "$REVIEW_LANE_FALLBACK" == block ]]; then
    echo "The Antigravity gate could not run (exit 3) and REVIEW_LANE_FALLBACK=block — not pushing." >&2
    exit 1
  fi
  echo "The Antigravity gate could not run (exit 3); falling back to the Codex lane."
  # Recorded in the lane ledger so `review-receipt.py stats` can count how often
  # the Gemini lane degrades rather than leaving it invisible.
  export REVIEW_LANE_NOTE="antigravity-degraded(exit 3): Antigravity gate could not run; reviewed by Codex"
  check_review_target
  DISPATCH_LANE=codex
  REVIEW_GATE_RC=0
  run_review_gate codex || REVIEW_GATE_RC=$?
fi
[[ "$REVIEW_GATE_RC" -eq 0 ]] || exit "$REVIEW_GATE_RC"
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
# The lane that was actually dispatched, not a hardcoded one. gate_select_lane
# only ever returns a lane at or above the requirement, so naming it here
# enforces the ADR-0008 requirement AND additionally requires the gate this run
# performed to still be approved: a stronger lane that ran and then lost its
# approval must not be able to ship on a weaker lane's older receipt.
python3 "$SCRIPT_DIR/review-receipt.py" check --repo "$REPO_DIR" --head "$REVIEWED_HEAD" \
  --reviewer "$DISPATCH_LANE"
git push --no-follow-tags "${PUSH_CREATION_LEASE[@]}" -- "$PUSH_URL" "$REVIEWED_HEAD:$BRANCH_REF"
echo "Pushed."
