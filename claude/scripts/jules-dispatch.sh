#!/usr/bin/env bash
# jules-dispatch.sh — dispatch the routine catalog to Jules over the REST API.
#
# The routine lane (ADR-0009): each file in agents/routines/ is a standing
# prompt with a frontmatter contract. This script turns the catalog into one
# Jules session per (routine, repo) per day, and measures the result.
#
# Why REST and not the `jules` CLI: the CLI authenticates through a browser
# OAuth flow (`jules login`) and its credential location is undocumented, so a
# unit running under ProtectHome=read-only cannot be shown to work. The REST API
# takes a key from a file this script validates itself.
#
# Usage:
#   jules-dispatch.sh [--dry-run] [--routine NAME] [--repo OWNER/NAME]
#   jules-dispatch.sh --reconcile [--routine NAME] [--repo OWNER/NAME] [--dry-run]
#   jules-dispatch.sh --report [--days N] [--post]
#
# Flags:
#   --dry-run          resolve and print what would be dispatched; write nothing
#   --routine NAME     only this routine (the catalog file's basename)
#   --repo OWNER/NAME  only this repository
#   --reconcile        settle each ledger session against GET /sessions: close a
#                      pull request the session opened with zero changed files,
#                      label and normalise the title of one that changed
#                      something, and record the outcome. The title is what a
#                      squash merge lands; a pull request whose own commit
#                      subjects the format check rejects is reported, not fixed.
#                      Runs on its own and at the end of every dispatch; needs
#                      gh. Not with --report
#   --report           tally routine PRs per week from GitHub instead of dispatching
#   --days N           report window in days (default 28)
#   --post             with --report, comment the table on the tracker issue
#
# Env:
#   JULES_API_KEY_FILE  key file (default ~/.config/jules/api-key); must be a
#                       regular file, mode 0600, non-empty, >= 20 characters
#   JULES_DAILY_CAP     max sessions created per calendar day (default 40)
#   JULES_STATE_DIR     state directory (default ~/.local/state/jules)
#   JULES_ROUTINE_DIR   routine catalog (default <repo>/agents/routines)
#   JULES_STARTING_BRANCH  starting branch for every session; when unset, each
#                       repository's default branch as reported by GET /sources
#                       (GitHubRepoContext.startingBranch is required)
#   JULES_TRACKER       owner/name#issue for --post (default jckeen/dotfiles#446)
#   JULES_FLOCK         flock(1) to use (default flock); a test seam for the
#                       branch taken when flock is unavailable
#   JULES_GH            gh(1) to use (default gh); a test seam for the branch
#                       taken when the GitHub CLI is unavailable
#   JULES_REPORT_LIMIT  --report pull-request fetch bound (default 1000); the
#                       report says so when a repository hits it
#   JULES_DAY_EDGE_MARGIN  seconds of the UTC day that must remain before a
#                       dispatch may start (default: the request timeout + 60)
#   JULES_NOW_EPOCH     override the clock (test seam; it decides the date a
#                       dispatch is recorded against, so do not set it in anger)
#
# State (all under JULES_STATE_DIR):
#   dispatch.jsonl   the ledger: dispatch records (one line per attempt and one
#                    per created session) plus `"kind":"reconcile"` records, one
#                    per settled session. Every dispatch query filters on the
#                    kind, so a reconcile record never counts as spend
#   status.json      last run's outcome, for hooks and the status line; a
#                    standalone --reconcile rewrites it too, with its own counts
#   dispatch.log     appended run log
#   dispatch.lock    flock'd for the duration of a dispatch (not a dry run)
#
# Requires: bash, curl, jq. --report and --reconcile additionally require gh.

set -euo pipefail

# The API host is a constant, never read from configuration or from a routine
# file: an ambient credential must never be attachable to an attacker-chosen
# host. `curl` is also called without -L, so a redirect cannot carry the key
# somewhere else.
readonly JULES_API_HOST="jules.googleapis.com"
readonly JULES_API_BASE="https://${JULES_API_HOST}/v1alpha"
readonly JULES_AUTOMATION_MODE="AUTO_CREATE_PR"
# The commit-subject types check-commit-format.sh enforces. That check is
# required, so a non-conventional subject makes a routine pull request
# unmergeable — the first live run's `No changes needed: doc drift checkers pass`
# did exactly that (#479). The catalog files already asked for conventional
# subjects and the session ignored them, so the requirement is repeated in the
# header this script injects, where it is the first thing the session reads.
# jules-dispatch.test.sh asserts this list still matches the checker's TYPES.
readonly COMMIT_TYPES='feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert'
# The same subject shape check-commit-format.sh applies, derived from the one
# copy of the type list above so the two cannot drift apart. --reconcile uses it
# to decide whether a routine pull request's title already passes.
readonly CONVENTIONAL_SUBJECT_RE="^(${COMMIT_TYPES})(\\([a-z0-9._/-]+\\))?!?: .+"
# The line --reconcile leaves when it closes a pull request that changed nothing.
readonly RECONCILE_EMPTY_COMMENT='Closed by jules-dispatch --reconcile: the session produced no changes (0 files changed). An empty run is a good run (#479).'
# The routine label is created on demand: the platform applies none, and
# jules-routine:* does not exist in a repository until a routine PR lands there.
readonly RECONCILE_LABEL_COLOR='5319e7'
readonly RECONCILE_LABEL_DESC='Opened by a Jules routine session (ADR-0009)'
# A bound on paging, so a server that keeps handing back a token cannot spin
# here forever. 100 sources per page, so this is 5000 repositories.
readonly SOURCES_PAGE_LIMIT=50
# One timeout for every request, so the day-edge margin below cannot drift from
# the longest a request can actually take.
readonly REQUEST_TIMEOUT=60

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"

STATE_DIR="${JULES_STATE_DIR:-$HOME/.local/state/jules}"
LEDGER="$STATE_DIR/dispatch.jsonl"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/dispatch.log"
KEY_FILE="${JULES_API_KEY_FILE:-$HOME/.config/jules/api-key}"
DAILY_CAP="${JULES_DAILY_CAP:-40}"
ROUTINE_DIR="${JULES_ROUTINE_DIR:-$REPO_ROOT/agents/routines}"
STARTING_BRANCH="${JULES_STARTING_BRANCH:-}"
TRACKER="${JULES_TRACKER:-jckeen/dotfiles#446}"
REPORT_LIMIT="${JULES_REPORT_LIMIT:-1000}"
# gh, not the REST API, for everything on the GitHub side: a pull request
# belongs to GitHub, and the Jules key must never reach github.com.
GH_BIN="${JULES_GH:-gh}"
# How much of the UTC day must remain before a dispatch may start. A request can
# take REQUEST_TIMEOUT seconds, so one begun closer to midnight than that could
# create its session on the next day while both ledger records carry this day —
# and the next run would then dispatch the pair again without the session
# counting against the new day's cap. Overridable so the guard is testable.
DAY_EDGE_MARGIN="${JULES_DAY_EDGE_MARGIN:-$((REQUEST_TIMEOUT + 60))}"

DRY_RUN=0
ONLY_ROUTINE=""
ONLY_REPO=""
MODE="dispatch"
REPORT_DAYS=28
POST=0
WANT_RECONCILE=0
WANT_REPORT=0

# Dropped before it is assigned, not just emptied: if the caller's environment
# already exported a variable of this name, a plain assignment KEEPS the export
# attribute and the key is then in the environment of every child — curl, jq, gh —
# readable from /proc/PID/environ. Verified: exporting it first and assigning
# leaves it in `env`; unsetting first does not.
unset -v API_KEY
API_KEY=""
SOURCES_JSON=""
SOURCES_PAGES=0
# Every time reading goes through these, and JULES_NOW_EPOCH overrides the clock.
# That exists so the test suite is deterministic: without it a test invocation
# spanning UTC midnight makes the run stop mid-catalog and the assertions fail on a
# schedule. Strictly validated, and documented as a test seam — it decides the date
# a dispatch is RECORDED against, so it is not a production knob.
now_epoch() {
  if [[ -n "${JULES_NOW_EPOCH:-}" ]]; then
    [[ "$JULES_NOW_EPOCH" =~ ^[1-9][0-9]*$ ]] \
      || die "JULES_NOW_EPOCH must be a positive integer with no leading zeros"
    printf '%s' "$JULES_NOW_EPOCH"
  else
    date -u +%s
  fi
}
epoch_to() { date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2"; }

NOW_EPOCH="$(now_epoch)"
TODAY="$(epoch_to "$NOW_EPOCH" '%Y-%m-%d')"
NOW_ISO="$(epoch_to "$NOW_EPOCH" '%Y-%m-%dT%H:%M:%SZ')"
CREATED=0
FAILURES=0
# Reconcile counters, reported in status.json so a pass that failed is visible
# to the hooks and the status line and not only in the exit code.
RECON_CHECKED=0
RECON_CLOSED=0
RECON_LABELED=0
RECON_RETITLED=0
RECON_BLOCKED_SUBJECTS=0
RECON_FAILURES=0
SPENT=0
DEFERRED=0
ATTEMPT_SEQ=0
# Ties one run's ledger records together, so the "attempted" and "created" lines
# of a dispatch are recognisably one unit of spend.
RUN_ID="$$.$(date -u +%s).${RANDOM}"

usage() {
  # Printed from the header block above, which is the single copy of the
  # flag list: a sed line range would drift the moment the header grows.
  sed -n '/^# Usage:/,/^# Requires:/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1\} \{0,1\}//'
}

die() { printf 'jules-dispatch: %s\n' "$1" >&2; exit 1; }

# Log lines go to stdout and, outside a dry run, to the run log. The API key is
# never passed to log(), so it cannot reach a file on disk.
log() {
  printf '%s\n' "$1"
  if [[ "$DRY_RUN" -eq 0 && -d "$STATE_DIR" ]]; then
    printf '%s %s\n' "$NOW_ISO" "$1" >> "$LOG_FILE"
  fi
}

# ── Arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --report) MODE="report"; WANT_REPORT=1 ;;
    --reconcile) MODE="reconcile"; WANT_RECONCILE=1 ;;
    --post) POST=1 ;;
    --routine)
      [[ $# -ge 2 ]] || die "--routine needs a routine name"
      ONLY_ROUTINE="$2"; shift ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo needs OWNER/NAME"
      ONLY_REPO="$2"; shift ;;
    --days)
      [[ $# -ge 2 ]] || die "--days needs a number"
      REPORT_DAYS="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

# Checked before every other flag rule, so the message names the real mistake
# rather than a consequence of it. --report tallies and --reconcile acts; asking
# for both is a mistake, not a composition.
[[ "$WANT_RECONCILE" -eq 1 && "$WANT_REPORT" -eq 1 ]] \
  && die "--reconcile cannot be combined with --report"
[[ "$REPORT_DAYS" =~ ^[1-9][0-9]*$ ]] \
  || die "--days must be a positive integer with no leading zeros, got: $REPORT_DAYS"
[[ -n "$ONLY_REPO" && ! "$ONLY_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  && die "--repo must be OWNER/NAME, got: $ONLY_REPO"
[[ "$POST" -eq 1 && "$MODE" != "report" ]] && die "--post only applies to --report"
# No leading zeros: bash reads "08" as octal inside [[ -ge ]], the comparison
# errors out, and an errored test is a false one — so the cap silently stopped
# applying and every candidate dispatched. Verified: `[[ 100 -ge 08 ]]` exits 1
# with "value too great for base".
[[ "$DAY_EDGE_MARGIN" =~ ^(0|[1-9][0-9]*)$ ]] \
  || die "JULES_DAY_EDGE_MARGIN must be a non-negative integer with no leading zeros, got: $DAY_EDGE_MARGIN"
[[ "$REPORT_LIMIT" =~ ^[1-9][0-9]*$ ]] \
  || die "JULES_REPORT_LIMIT must be a positive integer with no leading zeros, got: $REPORT_LIMIT"
[[ "$DAILY_CAP" =~ ^(0|[1-9][0-9]*)$ ]] \
  || die "JULES_DAILY_CAP must be a non-negative integer with no leading zeros, got: $DAILY_CAP"
[[ -d "$ROUTINE_DIR" ]] || die "routine catalog not found: $ROUTINE_DIR"

# An empty selection must not look like a successful run that found no work.
# Checked here, in the main shell: routine_files() is consumed through a process
# substitution, and a die() inside that subshell would not stop the caller.
if [[ -n "$ONLY_ROUTINE" ]]; then
  [[ "$ONLY_ROUTINE" =~ ^[a-z0-9-]+$ ]] || die "--routine must match [a-z0-9-]+, got: $ONLY_ROUTINE"
  [[ -f "$ROUTINE_DIR/$ONLY_ROUTINE.md" ]] \
    || die "no routine matched --routine $ONLY_ROUTINE in $ROUTINE_DIR"
else
  compgen -G "$ROUTINE_DIR/*.md" >/dev/null \
    || die "no routine matched: the catalog $ROUTINE_DIR holds no *.md file"
fi

command -v jq >/dev/null 2>&1 || die "jq is required (setup.sh installs it)"

# One spelling for a repository everywhere (see lc() below).
ONLY_REPO="$(printf '%s' "$ONLY_REPO" | tr '[:upper:]' '[:lower:]')"
# --reconcile talks to GET /sessions, so it needs curl exactly as a dispatch does.
[[ "$MODE" != "report" ]] && { command -v curl >/dev/null 2>&1 || die "curl is required"; }

# ── Routine frontmatter ──────────────────────────────────────────────
# A strict reader: unknown key, missing key, duplicate key, or a value that
# fails its type check aborts the routine. Fail closed — a header that does not
# parse is never dispatched, and the run exits non-zero so the timer's status
# reports it instead of silently doing less work.
FM_NAME=""; FM_SCHEDULE=""; FM_MAX_PRS=""; FM_MAX_FILES=""
FM_LABEL=""; FM_ACCEPTANCE=""; FM_PAUSED=""; FM_PROMPT=""
FM_REPOS=()

fm_fail() { printf 'jules-dispatch: %s: %s\n' "$1" "$2" >&2; return 1; }

# GitHub repository identities are case-insensitive. One spelling is used
# everywhere — frontmatter, --repo, the source listing, the ledger key — so a
# case variant can never become a second identity for the same repository.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

parse_routine() {
  local file="$1" stem line key value state="head" lineno=0 seen=" " in_repos=0
  stem="$(basename "$file" .md)"
  FM_NAME=""; FM_SCHEDULE=""; FM_MAX_PRS=""; FM_MAX_FILES=""
  FM_LABEL=""; FM_ACCEPTANCE=""; FM_PAUSED=""; FM_PROMPT=""
  FM_REPOS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$state" in
      head)
        [[ "$line" == "---" ]] || { fm_fail "$file:$lineno" "must open with a '---' frontmatter fence"; return 1; }
        state="fm"
        ;;
      fm)
        if [[ "$line" == "---" ]]; then state="body"; continue; fi
        if [[ "$in_repos" -eq 1 && "$line" =~ ^[[:space:]]+-[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
          # Lowercased on the way in: GitHub repository names are
          # case-insensitive, so "Owner/Repo" and "owner/repo" resolve to the same
          # source but would otherwise be two different ledger keys — and the
          # same repository would be dispatched twice in one run.
          FM_REPOS+=("$(lc "${BASH_REMATCH[1]}")"); continue
        fi
        in_repos=0
        [[ "$line" =~ ^([a-z_]+):[[:space:]]*(.*)$ ]] \
          || { fm_fail "$file:$lineno" "not a 'key: value' frontmatter line"; return 1; }
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ "$seen" == *" $key "* ]] && { fm_fail "$file:$lineno" "duplicate key '$key'"; return 1; }
        seen="$seen$key "
        case "$key" in
          name)            FM_NAME="$value" ;;
          schedule)        FM_SCHEDULE="$value" ;;
          max_prs_per_run) FM_MAX_PRS="$value" ;;
          max_files)       FM_MAX_FILES="$value" ;;
          label)           FM_LABEL="$value" ;;
          acceptance)      FM_ACCEPTANCE="$value" ;;
          paused)          FM_PAUSED="$value" ;;
          repos)
            if [[ -n "$value" ]]; then FM_REPOS=("$(lc "$value")"); else in_repos=1; fi
            ;;
          *) fm_fail "$file:$lineno" "unknown frontmatter key '$key'"; return 1 ;;
        esac
        ;;
      body)
        FM_PROMPT+="$line"$'\n'
        ;;
    esac
  done < "$file"

  [[ "$state" == "body" ]] || { fm_fail "$file" "frontmatter fence is never closed"; return 1; }

  local k
  for k in name schedule repos max_prs_per_run max_files label acceptance paused; do
    [[ "$seen" == *" $k "* ]] || { fm_fail "$file" "missing required key '$k'"; return 1; }
  done

  [[ "$FM_NAME" =~ ^[a-z0-9-]+$ ]] || { fm_fail "$file" "name must match [a-z0-9-]+"; return 1; }
  [[ "$FM_NAME" == "$stem" ]] || { fm_fail "$file" "name '$FM_NAME' does not match the filename"; return 1; }
  [[ "$FM_SCHEDULE" == "daily" || "$FM_SCHEDULE" == "weekly" ]] \
    || { fm_fail "$file" "schedule must be 'daily' or 'weekly', got '$FM_SCHEDULE'"; return 1; }
  # Leading zeros excluded by the [1-9] anchor: these values reach arithmetic
  # comparisons, where bash reads a leading zero as octal and errors.
  [[ "$FM_MAX_PRS" =~ ^[1-9][0-9]*$ ]] || { fm_fail "$file" "max_prs_per_run must be a positive integer with no leading zeros"; return 1; }
  [[ "$FM_MAX_FILES" =~ ^[1-9][0-9]*$ ]] || { fm_fail "$file" "max_files must be a positive integer with no leading zeros"; return 1; }
  [[ "$FM_LABEL" == "jules-routine:$FM_NAME" ]] \
    || { fm_fail "$file" "label must be 'jules-routine:$FM_NAME', got '$FM_LABEL'"; return 1; }
  [[ -n "$FM_ACCEPTANCE" ]] || { fm_fail "$file" "acceptance must not be empty"; return 1; }
  [[ "$FM_PAUSED" == "true" || "$FM_PAUSED" == "false" ]] \
    || { fm_fail "$file" "paused must be 'true' or 'false', got '$FM_PAUSED'"; return 1; }
  [[ "${#FM_REPOS[@]}" -gt 0 ]] || { fm_fail "$file" "repos must be 'all' or a non-empty list"; return 1; }
  local r seen_repos=" "
  for r in "${FM_REPOS[@]}"; do
    [[ "$r" == "all" || "$r" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] \
      || { fm_fail "$file" "repos entry must be 'all' or OWNER/NAME, got '$r'"; return 1; }
    # A repeated entry would dispatch the same repository twice: every
    # eligibility check runs before the first session is created, so both copies
    # pass. Rejected here rather than silently deduplicated, because a duplicate
    # in a hand-edited catalog is a mistake worth seeing.
    [[ "$seen_repos" == *" $r "* ]] \
      && { fm_fail "$file" "repos lists '$r' more than once (comparison ignores case)"; return 1; }
    seen_repos="$seen_repos$r "
  done
  if [[ "${#FM_REPOS[@]}" -gt 1 ]]; then
    for r in "${FM_REPOS[@]}"; do
      [[ "$r" == "all" ]] && { fm_fail "$file" "repos cannot mix 'all' with named repositories"; return 1; }
    done
  fi
  [[ -n "${FM_PROMPT//[[:space:]]/}" ]] || { fm_fail "$file" "prompt body is empty"; return 1; }
  return 0
}

# ── API key ──────────────────────────────────────────────────────────
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

read_api_key() {
  local mode
  [[ -e "$KEY_FILE" || -L "$KEY_FILE" ]] \
    || die "API key file not found: $KEY_FILE (create it mode 0600, or set JULES_API_KEY_FILE)"
  [[ -L "$KEY_FILE" ]] && die "API key file must not be a symlink: $KEY_FILE"
  [[ -f "$KEY_FILE" ]] || die "API key file is not a regular file: $KEY_FILE"
  mode="$(file_mode "$KEY_FILE")" || die "cannot read the mode of $KEY_FILE"
  [[ "$mode" == "600" ]] || die "API key file must be mode 0600, found 0$mode: $KEY_FILE"
  API_KEY="$(tr -d '\r\n' < "$KEY_FILE")"
  [[ -n "$API_KEY" ]] || die "API key file is empty: $KEY_FILE"
  [[ "${#API_KEY}" -ge 20 ]] || die "API key is shorter than 20 characters: $KEY_FILE"
  [[ "$API_KEY" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || die "API key contains characters outside [A-Za-z0-9._~+/=-]: $KEY_FILE"
}

# curl reads the auth header from a config file on stdin, so the key never
# appears in argv (visible in /proc and in any process listing) or in a log.
#
# -q MUST be the first argument. Without it curl first reads $CURLRC or
# ~/.curlrc, and a `location` or `trace` line there would make the key follow a
# redirect or land in a trace file — defeating the whole point of the stdin
# config. Everything this request needs is passed explicitly here.
curl_api() { # method path [body-file]
  local method="$1" path="$2" body="${3:-}"
  local args=(--proto '=https' --fail -sS --max-time "$REQUEST_TIMEOUT" -X "$method"
              -H 'Content-Type: application/json' "${JULES_API_BASE}${path}")
  [[ -n "$body" ]] && args+=(--data-binary "@$body")
  printf 'header = "X-Goog-Api-Key: %s"\n' "$API_KEY" | curl -q -K - "${args[@]}"
}

# ── Sources ──────────────────────────────────────────────────────────
# GET /sources is paginated: pageSize is 1..100 and defaults to 30, and
# nextPageToken is omitted on the last page (verified against the sources.list
# reference, 2026-09-18). A single unpaginated request would silently drop every
# connected repository past the 30th — reporting them as "not in GET /sources"
# and skipping them, which reads exactly like a configuration problem.
fetch_sources() {
  local token="" page=0 body path collected="[]"
  while :; do
    page=$((page + 1))
    [[ "$page" -le "$SOURCES_PAGE_LIMIT" ]] \
      || die "GET /sources returned more than $SOURCES_PAGE_LIMIT pages; refusing to keep paging"
    path="/sources?pageSize=100"
    if [[ -n "$token" ]]; then
      # The token is opaque, so it is percent-encoded rather than restricted to an
      # alphabet: a base64 token containing '+' or '/' is perfectly valid and an
      # allowlist would abort discovery on it, making pagination depend on an
      # undocumented encoding. @uri also neutralises anything that could break out
      # of the query string. The length bound is the only limit kept.
      [[ "${#token}" -le 4096 ]] \
        || die "GET /sources returned a nextPageToken longer than 4096 characters"
      path="$path&pageToken=$(jq -rn --arg t "$token" '$t|@uri')"
    fi
    body="$(curl_api GET "$path")" \
      || die "GET /sources failed on page $page — cannot resolve any repository"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$body" \
      || die "GET /sources page $page did not return a JSON object"
    collected="$(jq -c --argjson acc "$collected" '$acc + (.sources // [])' <<<"$body")" \
      || die "GET /sources page $page carried an unreadable sources array"
    token="$(jq -r '.nextPageToken // ""' <<<"$body")"
    [[ -n "$token" ]] || break
  done
  SOURCES_JSON="$(jq -cn --argjson s "$collected" '{sources: $s}')"
  # Page count is returned through a global, not stdout: a command substitution
  # would run this in a subshell and lose SOURCES_JSON with it.
  SOURCES_PAGES="$page"
}

# The `source` resource name is always read back from GET /sources, never
# constructed from owner/name: the documented format is `sources/{source}` and
# the guide's `sources/github/{owner}/{repo}` spelling is not guaranteed.
resolve_source() { # OWNER/NAME -> source resource name, or empty
  jq -r --arg repo "$1" '
    ($repo | ascii_downcase) as $want
    | [ (.sources // [])[]
        | select(
            (((.name // "") | ascii_downcase) | endswith("/" + $want))
            or ((((.githubRepo.owner // "") + "/" + (.githubRepo.repo // "")) | ascii_downcase) == $want)
          )
        | (.name // "") ]
    | map(select(. != "")) | first // empty' <<<"$SOURCES_JSON"
}

# GET /sources reports each repository's default branch under
# githubRepo.defaultBranch.displayName. startingBranch is REQUIRED inside
# GitHubRepoContext — the API answered INVALID_ARGUMENT to a body without it on
# 2026-09-19 — so this is where the dispatcher gets one when the operator has
# not set JULES_STARTING_BRANCH.
source_default_branch() { # source resource name -> branch, or empty
  jq -r --arg name "$1" '
    [ (.sources // [])[] | select((.name // "") == $name)
      | (.githubRepo.defaultBranch.displayName // "") ]
    | map(select(. != "")) | first // empty' <<<"$SOURCES_JSON"
}

sources_repos() {
  jq -r '
    (.sources // [])[]
    | if ((.githubRepo.owner // "") != "" and (.githubRepo.repo // "") != "")
      then (.githubRepo.owner + "/" + .githubRepo.repo)
      else ((.name // "") | split("/") | if length >= 2 then (.[-2] + "/" + .[-1]) else empty end)
      end' <<<"$SOURCES_JSON" | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u
}

# ── Ledger ───────────────────────────────────────────────────────────
# A dispatch writes TWO lines: "attempted" before the POST and "created" after
# it, sharing one attempt id. Without the first, a POST that creates a session
# remotely and then times out — or a process killed between the POST and the
# append — leaves no trace at all, so the next run dispatches the pair again and
# the original session never counts against the cap. The pre-record makes the
# ambiguous case visible and fail-closed: the pair counts as dispatched, and the
# run reports it for reconciliation against GET /sessions.
#
# Every count is over DISTINCT attempts, not lines, so the two records for one
# dispatch are one unit of spend. Lines written before this scheme existed carry
# no attempt id, so the key falls back to the session or the timestamp.
readonly LEDGER_KEY='(if ((.attempt // "") == "") then ((.session // "") + (.dispatched_at // "")) else .attempt end)'

# The ledger holds two kinds of record. Every query below that decides SPEND —
# the daily cap, same-day idempotency, the weekly cadence window, the fairness
# order, the report's scope — must see dispatch records only: a reconcile record
# carries the same .date, .routine and .repo, so without this filter a pass that
# merely closed an empty pull request would read as a dispatch and suppress the
# very routine it belongs to on the next run. Records written before reconcile
# existed carry no .kind, hence the default.
readonly LEDGER_IS_DISPATCH='((.kind // "dispatch") == "dispatch")'

# Built in memory, then appended with ONE printf. A single write of less than
# PIPE_BUF bytes to a file opened O_APPEND (which `>>` does) is atomic, so a
# concurrent reader — a --report run, or a dispatch that is about to stand down on
# the lock — never sees half a line. Letting jq write straight into the file would
# give no such guarantee, and a reader rejecting a torn line would turn an intended
# clean no-op into a failed run. The length is checked rather than assumed.
ledger_write_line() { # one complete JSON line
  [[ "${#1}" -lt 4000 ]] || {
    printf 'jules-dispatch: ledger record too long to append atomically\n' >&2
    return 1
  }
  printf '%s\n' "$1" >> "$LEDGER"
}

ledger_append() { # status attempt repo source session url
  local line
  line="$(jq -nc --arg at "$NOW_ISO" --arg date "$TODAY" --arg routine "$FM_NAME" \
    --arg repo "$3" --arg source "$4" --arg status "$1" --arg attempt "$2" \
    --arg session "$5" --arg url "$6" \
    '{dispatched_at: $at, date: $date, routine: $routine, repo: $repo,
      source: $source, status: $status, attempt: $attempt,
      session: $session, url: $url}')" || return 1
  ledger_write_line "$line"
}

# Validated ONCE, here, from the main shell. Every later query runs inside a
# command substitution, and a die() in a subshell only kills the subshell: the
# caller gets an empty field and a zero status. That exact mistake has now shown
# up three times in this file in different dress — a die in a process
# substitution, an assignment in a command substitution, and a ledger read nested
# in a printf argument — so the check lives where die() can actually stop the run.
validate_ledger() {
  [[ -s "$LEDGER" ]] || return 0
  jq -se 'all(type == "object")' "$LEDGER" >/dev/null 2>&1 \
    || die "dispatch ledger is not valid JSON lines (one object per line): $LEDGER"
}

ledger_query() { # jq-filter -> value
  [[ -s "$LEDGER" ]] || { printf '0\n'; return 0; }
  jq -s "$@" "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

dispatched_today() {
  ledger_query --arg d "$TODAY" \
    "[.[] | select($LEDGER_IS_DISPATCH and .date == \$d) | $LEDGER_KEY] | unique | length"
}

# Attempts today with no matching "created" record: a session may or may not
# exist for each one. Surfaced rather than retried, because a duplicate cloud
# session is the one outcome this script must never produce on its own.
unresolved_attempts() {
  ledger_query --arg d "$TODAY" \
    "[.[] | select($LEDGER_IS_DISPATCH and .date == \$d)] as \$t
     | (\$t | map(select((.status // \"created\") == \"attempted\") | $LEDGER_KEY) | unique) as \$a
     | (\$t | map(select((.status // \"created\") == \"created\") | $LEDGER_KEY) | unique) as \$c
     | (\$a - \$c) | length"
}

already_dispatched() { # routine repo
  local n
  n="$(ledger_query --arg d "$TODAY" --arg r "$1" --arg p "$2" \
        "[.[] | select($LEDGER_IS_DISPATCH and .date == \$d and .routine == \$r and .repo == \$p) | $LEDGER_KEY] | unique | length")"
  [[ "$n" -gt 0 ]]
}

# A weekly routine needs a cadence check, not just the same-day one: the timer
# fires daily, so without this `schedule: weekly` would be decoration and a
# weekly routine would run seven times a week. Compared on the recorded
# timestamp rather than the date string, so the window is exact and needs no
# non-portable date arithmetic.
#
# The comparison is strict (`>`), not `>=`: a dispatch exactly `seconds` old is
# OUTSIDE the window. With `>=` a daily timer firing at the same time each day
# would find the seven-day-old record still inside the cooldown and skip the
# seventh day, so a "weekly" routine would actually run every eighth day.
dispatched_within() { # routine repo seconds
  [[ -s "$LEDGER" ]] || return 1
  local n cutoff=$((NOW_EPOCH - $3))
  n="$(ledger_query --arg r "$1" --arg p "$2" --argjson cutoff "$cutoff" \
        "[.[] | select($LEDGER_IS_DISPATCH and .routine == \$r and .repo == \$p
           and ((.dispatched_at // \"\") | (try fromdateiso8601 catch 0)) > \$cutoff)] | length")"
  [[ "$n" -gt 0 ]]
}

# Seconds a routine must leave between dispatches for the same repository.
schedule_interval() {
  case "$FM_SCHEDULE" in
    weekly) printf '%s' $((7 * 86400)) ;;
    *) printf '0' ;;
  esac
}

ledger_repos() { # distinct repos a routine was ever dispatched to ("" = any)
  [[ -s "$LEDGER" ]] || return 0
  jq -sr --arg r "${1:-}" \
    "[.[] | select($LEDGER_IS_DISPATCH and (\$r == \"\" or .routine == \$r)) | .repo // empty] | unique | .[]" "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

# ── Run events (for status.json) ─────────────────────────────────────
EVENTS_FILE="$(mktemp)" || { printf 'jules-dispatch: mktemp failed\n' >&2; exit 1; }
BODY_FILE=""
LOCK_HELD=0
LOCK_FALLBACK_DIR=""
# Test seam: lets the suite exercise the flock-absent branch on a machine that
# has flock. Locking only; it reaches no credential and no URL.
FLOCK_BIN="${JULES_FLOCK:-flock}"
# `exit` stays last so the trap preserves the original exit status. The flock is
# released by the kernel when this process exits; the lock file itself stays, as
# an empty file is the lock's identity and nothing reads its contents.
# Only the process that created the fallback directory ever removes it.
trap 'rm -f "$EVENTS_FILE"; [[ -n "$BODY_FILE" ]] && rm -f "$BODY_FILE"; [[ -n "$LOCK_FALLBACK_DIR" ]] && rmdir "$LOCK_FALLBACK_DIR" 2>/dev/null; exit' EXIT

# Serialize the critical section — reading the ledger, deciding eligibility,
# creating a session, recording it — so a manual run overlapping the 09:00 timer
# cannot read the same spend and dispatch the same routine twice.
#
# flock, not a lock directory: the kernel releases an flock when the holder dies,
# so there is no abandoned lock and nothing to reclaim. Two attempts at making
# mkdir-based reclamation safe were both read-check-replace races — the second
# only moved the race into the lock that was guarding the first. A primitive with
# no staleness concept removes the whole class.
#
# flock(1) ships in util-linux, so it is present wherever the systemd timer runs.
# Where it is absent (macOS has no flock(1), and no systemd timer either) the run
# says so rather than reporting a serialization it does not have. Fd 9 is a
# literal, not a {var} allocation, so this parses under bash 3.2.
LOCK_FILE=""
LOCK_FALLBACK_DIR=""
acquire_lock() {
  LOCK_FILE="$STATE_DIR/dispatch.lock"
  if command -v "$FLOCK_BIN" >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" || die "cannot open the dispatch lock: $LOCK_FILE"
    "$FLOCK_BIN" -n 9 || return 1
    LOCK_HELD=1
    return 0
  fi

  # No flock (macOS): fall back to an atomic mkdir rather than running
  # unserialized — a warning is not a guarantee, and two concurrent runs would
  # read the same ledger and both dispatch. Deliberately no staleness logic: a
  # reclaim is a read-check-replace race, which is what the flock replaced. The
  # cost is that a SIGKILLed run leaves the directory behind, so the message
  # names the exact path to remove.
  if ! mkdir "$STATE_DIR/dispatch.lock.d" 2>/dev/null; then
    return 1
  fi
  LOCK_FALLBACK_DIR="$STATE_DIR/dispatch.lock.d"
  LOCK_HELD=1
  log "  -- flock not found; serialized with a lock directory instead"
  log "     If a run was killed, remove $LOCK_FALLBACK_DIR by hand."
  return 0
}

record() { # kind routine repo detail
  jq -nc --arg kind "$1" --arg routine "$2" --arg repo "$3" --arg detail "$4" \
    '{kind: $kind, routine: $routine, repo: $repo, detail: $detail}' >> "$EVENTS_FILE"
}

write_status() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local tmp="$STATUS_FILE.tmp"
  jq -n --slurpfile events "$EVENTS_FILE" \
    --arg checked_at "$NOW_ISO" --arg date "$TODAY" \
    --argjson cap "$DAILY_CAP" --argjson created "$CREATED" \
    --argjson dispatched_today "$(dispatched_today)" --argjson failures "$FAILURES" \
    --argjson serialized "$([[ "$LOCK_HELD" -eq 1 ]] && printf 'true' || printf 'false')" \
    --argjson deferred "$DEFERRED" \
    --argjson recon_checked "$RECON_CHECKED" --argjson recon_closed "$RECON_CLOSED" \
    --argjson recon_labeled "$RECON_LABELED" --argjson recon_retitled "$RECON_RETITLED" \
    --argjson recon_blocked "$RECON_BLOCKED_SUBJECTS" \
    --argjson recon_failures "$RECON_FAILURES" \
    '{checked_at: $checked_at, date: $date, daily_cap: $cap,
      created_this_run: $created, dispatched_today: $dispatched_today,
      deferred_to_a_later_day: $deferred, serialized: $serialized,
      failures: $failures,
      reconcile: {checked: $recon_checked, closed_empty: $recon_closed,
                  labeled: $recon_labeled, retitled: $recon_retitled,
                  blocked_subjects: $recon_blocked, failures: $recon_failures},
      events: $events}' > "$tmp"
  mv "$tmp" "$STATUS_FILE"
}

# ── Dispatch ─────────────────────────────────────────────────────────
# When the catalog produces more eligible pairs than the daily cap allows, the
# order decides what never runs. Alphabetical order starves the tail
# permanently: with ten connected repositories and the default cap, the first
# four routines would consume the whole budget every single day and the last two
# would never dispatch once.
#
# So candidates are ordered by how long it has been since that exact
# (routine, repository) pair last ran — never-dispatched first. Whatever the cap
# defers today sits at the front of tomorrow's queue, which makes the cap a rate
# limit rather than a cliff.
last_dispatch_epoch() { # routine repo -> epoch seconds, 0 if never
  [[ -s "$LEDGER" ]] || { printf '0'; return 0; }
  ledger_query --arg r "$1" --arg p "$2" \
    "[.[] | select($LEDGER_IS_DISPATCH and .routine == \$r and .repo == \$p)
          | ((.dispatched_at // \"\") | (try fromdateiso8601 catch 0))]
     | max // 0"
}

# Callers read this through a process substitution, whose subshell cannot fail
# the run — so an empty selection is rejected up front in check_selection(),
# never from in here.
routine_files() {
  local f
  for f in "$ROUTINE_DIR"/*.md; do
    [[ -e "$f" ]] || continue
    [[ -n "$ONLY_ROUTINE" && "$(basename "$f" .md)" != "$ONLY_ROUTINE" ]] && continue
    printf '%s\n' "$f"
  done
}

# Seconds until the next UTC midnight. The POSIX epoch is UTC-aligned, so the
# remainder is the seconds elapsed in the current UTC day — no date parsing and
# nothing platform-specific.
seconds_left_in_utc_day() { printf '%s' $((86400 - ($(now_epoch) % 86400))); }

# Everything phase one decided that a mid-run edit to the catalog can invalidate.
# One function, so a new eligibility rule cannot be added to phase one and
# forgotten here.
still_eligible() { # repo -> 0 if it should still dispatch
  local repo="$1" interval r in_scope=0

  if [[ "$FM_PAUSED" == "true" ]]; then
    log "  -- $FM_NAME / $repo — paused between phases; skipped"
    record skipped "$FM_NAME" "$repo" "paused between phases"
    return 1
  fi

  # `all` is resolved from GET /sources, which this run read once and does not
  # re-read; a named list is the operator's and can have changed on disk.
  if [[ "${FM_REPOS[0]}" != "all" ]]; then
    for r in "${FM_REPOS[@]}"; do
      [[ "$r" == "$repo" ]] && { in_scope=1; break; }
    done
    if [[ "$in_scope" -eq 0 ]]; then
      log "  -- $FM_NAME / $repo — removed from the routine's repos between phases; skipped"
      record skipped "$FM_NAME" "$repo" "removed from repos between phases"
      return 1
    fi
  fi

  interval="$(schedule_interval)"
  if [[ "$interval" -gt 0 ]] && dispatched_within "$FM_NAME" "$repo" "$interval"; then
    log "  -- $FM_NAME / $repo — schedule became $FM_SCHEDULE between phases; skipped"
    record skipped "$FM_NAME" "$repo" "inside the $FM_SCHEDULE cadence window"
    return 1
  fi

  return 0
}

build_prompt() { # repo
  printf 'Repository: %s\nRoutine: %s\nHard limits: at most %s pull request(s) this run; at most %s file(s) changed per pull request; every commit subject is conventional — "type: short description", type one of %s.\nRequired PR label: %s\nAcceptance: %s\n\n%s' \
    "$1" "$FM_NAME" "$FM_MAX_PRS" "$FM_MAX_FILES" "$COMMIT_TYPES" \
    "$FM_LABEL" "$FM_ACCEPTANCE" "$FM_PROMPT"
}

dispatch_one() { # routine-file repo source starting-branch
  local repo="$2" source="$3" branch="$4" prompt response session url attempt
  ATTEMPT_SEQ=$((ATTEMPT_SEQ + 1))
  attempt="$RUN_ID.$ATTEMPT_SEQ"

  # Everything that can fail LOCALLY happens before the write-ahead record, so a
  # local failure leaves nothing in the ledger and the pair is retried next run
  # rather than being marked attempted for a session that provably never existed.
  # This function is called with `|| rc=$?`, which disables errexit inside it, so
  # each step is checked explicitly rather than trusted to abort.
  if ! BODY_FILE="$(mktemp)" || [[ -z "$BODY_FILE" ]]; then
    log "  !! $FM_NAME / $repo — mktemp failed; no session created"
    record error "$FM_NAME" "$repo" "mktemp failed"
    FAILURES=$((FAILURES + 1))
    BODY_FILE=""
    return 1
  fi

  prompt="$(build_prompt "$repo")"
  if ! jq -n --arg prompt "$prompt" --arg title "jules-routine: $FM_NAME ($repo)" \
      --arg source "$source" --arg mode "$JULES_AUTOMATION_MODE" \
      --arg branch "$branch" '
      {prompt: $prompt, title: $title, automationMode: $mode, requirePlanApproval: false,
       sourceContext: {source: $source, githubRepoContext: {startingBranch: $branch}}}' \
      > "$BODY_FILE" || [[ ! -s "$BODY_FILE" ]]; then
    log "  !! $FM_NAME / $repo — could not build the request body; no session created"
    record error "$FM_NAME" "$repo" "request body generation failed"
    FAILURES=$((FAILURES + 1))
    rm -f "$BODY_FILE"; BODY_FILE=""
    return 1
  fi

  # Write-ahead. Nothing has been created yet, so a failure here can stop the run
  # cleanly — the ledger is the only thing preserving idempotency and the cap.
  if ! ledger_append attempted "$attempt" "$repo" "$source" "" ""; then
    log "  !! $FM_NAME / $repo — cannot write $LEDGER; refusing to create a session"
    log "     The ledger is the only thing preserving idempotency and the daily"
    log "     cap, so this run stops here. Fix the ledger, then re-run."
    record error "$FM_NAME" "$repo" "ledger unwritable; no session created"
    FAILURES=$((FAILURES + 1))
    rm -f "$BODY_FILE"; BODY_FILE=""
    # 3 is the caller's signal to abort the whole run, not just this pair.
    return 3
  fi

  if ! response="$(curl_api POST /sessions "$BODY_FILE")"; then
    rm -f "$BODY_FILE"; BODY_FILE=""
    # The request may have reached Jules before the failure — a timeout after the
    # server committed looks exactly like a request that never landed. The
    # attempted record stands, so this pair is not retried today.
    log "  !! $FM_NAME / $repo — POST /sessions failed; outcome UNKNOWN"
    log "     A session may or may not have been created. The pair is recorded as"
    log "     attempted and will not be retried today; reconcile against"
    log "     GET /sessions before forcing it."
    record error "$FM_NAME" "$repo" "POST /sessions failed; outcome unknown"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  rm -f "$BODY_FILE"; BODY_FILE=""

  session="$(jq -r '.name // .id // ""' <<<"$response" 2>/dev/null || true)"
  url="$(jq -r '.url // ""' <<<"$response" 2>/dev/null || true)"
  if [[ -z "$session" ]]; then
    log "  !! $FM_NAME / $repo — session response carried no name or id"
    record error "$FM_NAME" "$repo" "response carried no session name"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  if ! ledger_append created "$attempt" "$repo" "$source" "$session" "$url"; then
    log "  !! $FM_NAME / $repo — created $session but could not record it in $LEDGER"
    log "     The attempted record already bounds the spend, so this is a"
    log "     reconciliation problem rather than a duplicate-dispatch one."
    record error "$FM_NAME" "$repo" "session $session created but not recorded"
    FAILURES=$((FAILURES + 1))
    return 3
  fi

  CREATED=$((CREATED + 1))
  log "  -> $FM_NAME / $repo — created $session"
  record created "$FM_NAME" "$repo" "$session"
}

do_dispatch() {
  read_api_key
  fetch_sources

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    # A dry run needs no lock: it creates nothing and must leave the state dir
    # byte-identical, so a lock file there would itself be a mutation.
    if ! acquire_lock; then
      log "another dispatch already holds $STATE_DIR/dispatch.lock — nothing to do"
      exit 0
    fi
  fi

  # Validated only once this run owns the lock. Before it, an overlapping
  # invocation could read the ledger mid-append and refuse a run that should have
  # been a clean no-op.
  validate_ledger

  local used
  used="$(dispatched_today)"
  SPENT="$used"
  log "═══ jules-dispatch $NOW_ISO ═══"
  local pending
  pending="$(unresolved_attempts)"
  if [[ "$pending" -gt 0 ]]; then
    log "  !! $pending dispatch(es) today are recorded as attempted with no confirmed"
    log "     session. Reconcile against GET /sessions; they are not retried."
  fi
  log "catalog: $ROUTINE_DIR; sources: $(jq -r '.sources | length' <<<"$SOURCES_JSON") over $SOURCES_PAGES page(s); dispatched today: $used/$DAILY_CAP$([[ "$DRY_RUN" -eq 1 ]] && printf ' (DRY-RUN)')"

  # ── Phase 1: which (routine, repository) pairs are eligible today ──
  local candidates file repo source scope interval rc last_run branch
  candidates="$(mktemp)" || die "mktemp failed while collecting candidates"
  [[ -n "$candidates" ]] || die "mktemp produced no candidates file"
  while IFS= read -r file; do
    if ! parse_routine "$file"; then
      log "  !! $(basename "$file") — frontmatter rejected; not dispatched"
      record error "$(basename "$file" .md)" "" "frontmatter rejected"
      FAILURES=$((FAILURES + 1))
      continue
    fi

    if [[ "$FM_PAUSED" == "true" ]]; then
      log "  -- $FM_NAME — paused: true; skipped"
      record skipped "$FM_NAME" "" "paused"
      continue
    fi

    if [[ "${FM_REPOS[0]}" == "all" ]]; then
      scope="$(sources_repos)"
    else
      scope="$(printf '%s\n' "${FM_REPOS[@]}")"
    fi
    interval="$(schedule_interval)"

    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      if [[ -n "$ONLY_REPO" && "$repo" != "$ONLY_REPO" ]]; then continue; fi

      source="$(resolve_source "$repo")"
      if [[ -z "$source" ]]; then
        log "  -- $FM_NAME / $repo — not in GET /sources; skipped (connect the repo in Jules)"
        record skipped "$FM_NAME" "$repo" "repository absent from GET /sources"
        continue
      fi

      if already_dispatched "$FM_NAME" "$repo"; then
        log "  -- $FM_NAME / $repo — already dispatched today; skipped"
        record skipped "$FM_NAME" "$repo" "already dispatched today"
        continue
      fi

      if [[ "$interval" -gt 0 ]] && dispatched_within "$FM_NAME" "$repo" "$interval"; then
        log "  -- $FM_NAME / $repo — schedule: $FM_SCHEDULE, dispatched inside the last $((interval / 86400)) day(s); skipped"
        record skipped "$FM_NAME" "$repo" "inside the $FM_SCHEDULE cadence window"
        continue
      fi

      # startingBranch is REQUIRED in GitHubRepoContext, so a pair with no branch
      # can never make a valid request: it is refused here, in the phase a dry run
      # and a live run both go through. Two reasons this is not left to the POST:
      # a dry run would otherwise promise a dispatch the live run refuses, and the
      # cap is spent in phase two, so a refusal there would defer a valid pair
      # behind it for a session that was never created. The next run retries this
      # pair once JULES_STARTING_BRANCH is set or the source reports a default.
      # GET /sources is read once per run, so nothing re-resolves this in phase two.
      branch="$STARTING_BRANCH"
      [[ -n "$branch" ]] || branch="$(source_default_branch "$source")"
      if [[ -z "$branch" ]]; then
        log "  !! $FM_NAME / $repo — no starting branch: GET /sources reports no default"
        log "     branch for $source and JULES_STARTING_BRANCH is unset; no session created"
        record error "$FM_NAME" "$repo" "no starting branch; no session created"
        FAILURES=$((FAILURES + 1))
        continue
      fi

      if ! last_run="$(last_dispatch_epoch "$FM_NAME" "$repo")"; then
        die "cannot read the dispatch ledger: $LEDGER"
      fi
      # The branch goes last: every field before it is non-empty by construction,
      # and an empty field ahead of the last one would shift the whole line as
      # `read` splits it.
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$last_run" "$FM_NAME" "$repo" "$source" "$file" "$branch" >> "$candidates"
    done <<<"$scope"
  done < <(routine_files)

  # ── Phase 2: dispatch in fairness order, under the cap ────────────
  # Oldest last-dispatch first, then routine and repository for a deterministic
  # order among pairs that have never run (all of which carry 0).
  local sorted line last_epoch day_left
  sorted="$(mktemp)" || die "mktemp failed while ordering candidates"
  [[ -n "$sorted" ]] || die "mktemp produced no ordering file"
  # Deduplicate on (routine, repository) before sorting. The parser already
  # rejects a repeated entry in one routine, and repository identities are
  # lowercased everywhere, so this is a backstop rather than the primary guard —
  # but every eligibility check runs before the first session is created, so a
  # duplicate reaching this queue would dispatch twice.
  awk -F'\t' '!seen[$2 FS $3]++' "$candidates" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2 -k3,3 > "$sorted"
  rm -f "$candidates"

  while IFS="$(printf '\t')" read -r last_epoch FM_NAME repo source file branch; do
    [[ -n "$FM_NAME" ]] || continue

    # TODAY and the day's spend were read once, before the network calls. Two ways
    # this run can end up recording against the wrong day, and both stop it:
    # the day has already rolled over, or too little of it remains for a request
    # to finish inside it. Nothing is lost — ordering is least-recently-dispatched
    # first, so the remaining pairs lead the next run's queue.
    day_left="$(seconds_left_in_utc_day)"
    if [[ "$(epoch_to "$(now_epoch)" '%Y-%m-%d')" != "$TODAY" ]]; then
      log "  -- the UTC day rolled over mid-run; stopping so nothing is recorded"
      log "     against $TODAY. The next run picks up where this one left off."
      record deferred "$FM_NAME" "$repo" "UTC day rolled over mid-run"
      DEFERRED=$((DEFERRED + 1))
      break
    fi
    if [[ "$day_left" -le "$DAY_EDGE_MARGIN" ]]; then
      log "  -- only ${day_left}s of the UTC day remain and a request may take up to"
      log "     ${REQUEST_TIMEOUT}s; stopping rather than risk a session created on one day"
      log "     and recorded against another. The next run continues."
      record deferred "$FM_NAME" "$repo" "too close to the UTC day boundary"
      DEFERRED=$((DEFERRED + 1))
      break
    fi

    if [[ "$SPENT" -ge "$DAILY_CAP" ]]; then
      DEFERRED=$((DEFERRED + 1))
      log "  -- $FM_NAME / $repo — daily cap $DAILY_CAP reached; deferred to a later day"
      record deferred "$FM_NAME" "$repo" "daily cap reached"
      continue
    fi

    # Re-read the routine: phase 2 needs its prompt and limits, and re-parsing
    # keeps the catalog file the single source of those values.
    if ! parse_routine "$file"; then
      log "  !! $(basename "$file") — frontmatter rejected between phases; not dispatched"
      record error "$(basename "$file" .md)" "$repo" "frontmatter rejected"
      FAILURES=$((FAILURES + 1))
      continue
    fi

    # Re-read means re-check, and re-check means the WHOLE eligibility decision,
    # not one field of it. Phase one judged the file as it was then; an operator
    # editing it while earlier requests are in flight expects the queued
    # repositories to honour the edit — pausing the routine, dropping a repository
    # from its list, or slowing it from daily to weekly.
    if ! still_eligible "$repo"; then continue; fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      SPENT=$((SPENT + 1))
      log "  [DRY] would dispatch $FM_NAME / $repo via $source from $branch (last run: $last_epoch)"
      record would-dispatch "$FM_NAME" "$repo" "$source"
      continue
    fi

    SPENT=$((SPENT + 1))
    rc=0
    dispatch_one "$file" "$repo" "$source" "$branch" || rc=$?
    if [[ "$rc" -eq 3 ]]; then
      rm -f "$sorted"
      write_status
      log "═══ jules-dispatch ABORTED: ledger unwritable (created=$CREATED failures=$FAILURES) ═══"
      exit 1
    fi
  done < "$sorted"
  rm -f "$sorted"

  # Every dispatch ends by settling what earlier ones created, including a run
  # that created nothing: the pull requests a routine leaves behind are the
  # reason the lane exists, and a tidy-up nobody remembers to run is not one.
  reconcile_pass || true

  write_status
  log "═══ jules-dispatch done: created=$CREATED deferred=$DEFERRED failures=$FAILURES ═══"
  [[ "$FAILURES" -eq 0 ]] || exit 1
}

# ── Reconcile ────────────────────────────────────────────────────────
# What the platform actually leaves behind, observed on the first two live
# sessions (#479): a COMPLETED session opens a pull request even when its change
# set is empty, the `pullRequest` output carries a `url` and NO number, the title
# is not a conventional subject, no `jules-routine:*` label is applied, and a
# session can complete with `outputs` null — no change set and no pull request at
# all. None of that is fixable from the dispatch side, so it is settled after the
# fact: this pass is the only place a routine pull request's provenance is
# API-confirmed, which is what the custodian's classifier keys off.
#
# One (repo, label) pair is created at most once per run.
RECON_LABELS_ENSURED=" "
# Records for one session, held until the whole session is settled. A retryable
# failure part-way through must leave NO record, or the next run would see the
# session as reconciled and skip the repair. Every action this pass takes is
# idempotent, so re-processing a session it already half-handled is safe.
RECON_PENDING=()

recon_fail() { # message routine repo
  log "  !! $1"
  record error "${2:-}" "${3:-}" "$1"
  FAILURES=$((FAILURES + 1))
  RECON_FAILURES=$((RECON_FAILURES + 1))
}

# gh's stderr is folded into the message rather than dropped, on one line so a
# multi-line git error cannot fake a log record. gh never sees the API key.
one_line() { printf '%s' "$1" | tr '\n\r' '  ' | cut -c1-300; }

# One ledger record per session, built once the whole session is settled. Not
# one per pull request: a record IS the "this session is done" marker, so two
# appends could leave a session marked settled with half its provenance missing
# and every later run skipping the gap. One line is the same unit every other
# ledger append already writes.
RECON_PR_JSON=""
RECON_PR_ACTIONS=""
RECON_FIRST_URL=""
RECON_FIRST_NUM=0
RECON_SUBJECTS_OK=true

recon_reset_session() {
  RECON_PR_JSON=""; RECON_PR_ACTIONS=""; RECON_FIRST_URL=""; RECON_FIRST_NUM=0
  RECON_SUBJECTS_OK=true; RECON_PENDING=()
}

recon_pr_entry() { # url pr-number action
  local entry
  entry="$(jq -nc --arg url "$1" --argjson pr "$2" --arg action "$3" \
    '{url: $url, pr: $pr, action: $action}')" || return 1
  RECON_PR_JSON="${RECON_PR_JSON:+$RECON_PR_JSON,}$entry"
  # Distinct action names in first-seen order: a one-pull-request session, which
  # is what `max_prs_per_run` makes the norm, reads exactly as that request's
  # outcome.
  case " $RECON_PR_ACTIONS " in
    *" $3 "*) ;;
    *) RECON_PR_ACTIONS="${RECON_PR_ACTIONS:+$RECON_PR_ACTIONS }$3" ;;
  esac
  [[ -z "$RECON_FIRST_URL" ]] && { RECON_FIRST_URL="$1"; RECON_FIRST_NUM="$2"; }
  return 0
}

# commit_subjects_ok is true for a session whose pull requests this pass read
# the commits of and found nothing the required check would reject; it is also
# true where there was no pull request to read.
recon_pend() { # session routine repo action detail
  local line action="$4"
  [[ -n "$RECON_PR_ACTIONS" ]] && action="${RECON_PR_ACTIONS// /+}"
  line="$(jq -nc --arg at "$NOW_ISO" --arg date "$TODAY" --arg session "$1" \
    --arg routine "$2" --arg repo "$3" --arg url "$RECON_FIRST_URL" \
    --argjson pr "$RECON_FIRST_NUM" --arg action "$action" \
    --argjson prs "[$RECON_PR_JSON]" \
    --argjson subjects_ok "$RECON_SUBJECTS_OK" \
    --arg detail "$(printf '%s' "$5" | cut -c1-200)" \
    '{kind: "reconcile", reconciled_at: $at, date: $date, session: $session,
      routine: $routine, repo: $repo, pr_url: $url, pr: $pr,
      action: $action, prs: $prs, commit_subjects_ok: $subjects_ok,
      detail: $detail}')" || return 1
  RECON_PENDING=("$line")
}

# The bound is checked rather than assumed, and a record past it is refused
# outright: half a session's provenance is worse than none, because every later
# run skips a session that already has a record.
recon_flush() {
  [[ "${#RECON_PENDING[@]}" -eq 0 ]] && return 0
  local line="${RECON_PENDING[0]}"
  RECON_PENDING=()
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if ! ledger_write_line "$line"; then
    recon_fail "could not append this session's reconcile record to $LEDGER" "" ""
    return 1
  fi
}

# Every `created` session the ledger knows about that has no reconcile record
# yet. The already-reconciled set is computed in the SAME jq pass, so a settled
# session costs no API call at all — that is the idempotency proof. Emitted with
# `-` sentinels because the fields are read back through a tab IFS, where an
# empty field before the last one silently shifts every field after it.
reconcile_candidates() {
  [[ -s "$LEDGER" ]] || return 0
  jq -sr --arg p "$ONLY_REPO" --arg r "$ONLY_ROUTINE" "
    ([.[] | select(.kind == \"reconcile\") | (.session // \"\")] | unique) as \$done
    | [ .[]
        | select($LEDGER_IS_DISPATCH
                 and ((.status // \"created\") == \"created\")
                 and ((.session // \"\") != \"\")
                 and ((\$p == \"\") or (((.repo // \"\") | ascii_downcase) == \$p))
                 and ((\$r == \"\") or ((.routine // \"\") == \$r))
                 and (((.session // \"\") as \$s | \$done | index(\$s)) == null)) ]
    | unique_by(.session)
    | .[]
    | [ .session,
        (if ((.routine // \"\") == \"\") then \"-\" else .routine end),
        (if ((.repo // \"\") == \"\") then \"-\" else .repo end) ]
    | @tsv" "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

# The label does not exist in a repository until a routine pull request lands
# there, so it is created on demand. --force makes a repeat call a no-op update
# rather than an error, and the colour and description are constants so the
# update is byte-identical every time.
ensure_label() { # owner/name label
  local key=" $1|$2 " out
  [[ "$RECON_LABELS_ENSURED" == *"$key"* ]] && return 0
  if ! out="$("$GH_BIN" label create "$2" --repo "$1" --force \
        --color "$RECONCILE_LABEL_COLOR" --description "$RECONCILE_LABEL_DESC" 2>&1)"; then
    log "     gh label create $2 failed on $1: $(one_line "$out")"
    return 1
  fi
  RECON_LABELS_ENSURED="$RECON_LABELS_ENSURED$key"
  return 0
}

# "Routine: <name> - subject" / "Routine: <name>: subject" / "<name>: subject"
# are the shapes the platform has produced; the prefix is dropped so the
# conventional subject carries the routine once, in the scope.
strip_routine_prefix() { # routine title
  local routine="$1" t="$2"
  case "$t" in
    "Routine: $routine - "*) t="${t#"Routine: $routine - "}" ;;
    "Routine: $routine -"*)  t="${t#"Routine: $routine -"}" ;;
    "Routine: $routine: "*)  t="${t#"Routine: $routine: "}" ;;
    "Routine: $routine:"*)   t="${t#"Routine: $routine:"}" ;;
    "$routine: "*)           t="${t#"$routine: "}" ;;
    "$routine:"*)            t="${t#"$routine:"}" ;;
  esac
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [[ -n "$t" ]] || t="$routine changes"
  printf '%s' "$t"
}

# 0 = settled, 1 = retryable failure; settle nothing on a 1.
reconcile_pr() { # session routine repo url
  local session="$1" routine="$2" repo="$3" url="$4"
  local owner name num out out2 commits pr_state changed title label newtitle action
  local bad_subjects
  local -a actions=()

  # Strict, anchored, https-only, github.com only, and matched against the
  # WHOLE field — a value carrying a newline fails `$` and is refused rather
  # than becoming two actionable URLs. Anything else is recorded and acted on by
  # nothing: the URL comes from a remote service, and a dispatcher that closes
  # or relabels whatever it is handed is a write primitive pointed at someone
  # else's repository.
  if [[ ! "$url" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)$ ]]; then
    recon_fail "$routine / $repo — $session reported a pull request URL this dispatcher will not act on: $(one_line "$url")" "$routine" "$repo"
    recon_pr_entry "$(one_line "$url")" 0 error || return 1
    return 0
  fi
  owner="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
  # The session was dispatched to one repository; a pull request anywhere else
  # is not this run's to touch, however the API came to report it.
  if [[ "$(lc "$owner/$name")" != "$(lc "$repo")" ]]; then
    recon_fail "$routine / $repo — $session reported a pull request in $owner/$name, which is not the repository it was dispatched to" "$routine" "$repo"
    recon_pr_entry "$url" "$num" error || return 1
    return 0
  fi

  if ! out="$("$GH_BIN" pr view "$num" --repo "$owner/$name" \
        --json state,changedFiles,title,labels 2>&1)"; then
    recon_fail "$routine / $repo — gh pr view $num failed: $(one_line "$out")" "$routine" "$repo"
    return 1
  fi
  pr_state="$(jq -r '.state // ""' <<<"$out" 2>/dev/null || true)"
  changed="$(jq -r '.changedFiles // "x"' <<<"$out" 2>/dev/null || true)"
  title="$(jq -r '.title // ""' <<<"$out" 2>/dev/null || true)"
  if [[ -z "$pr_state" || ! "$changed" =~ ^(0|[1-9][0-9]*)$ ]]; then
    recon_fail "$routine / $repo — gh pr view $num returned no usable state or changedFiles" "$routine" "$repo"
    return 1
  fi

  if [[ "$pr_state" != "OPEN" ]]; then
    log "  -- $routine / $repo — $owner/$name#$num is $pr_state; nothing to do"
    record reconciled "$routine" "$repo" "PR #$num $pr_state"
    recon_pr_entry "$url" "$num" noop || return 1
    return 0
  fi

  # An empty run is a good run — but an empty pull request is still an open pull
  # request asking for a review, so it is closed with the reason in one line.
  if [[ "$changed" -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [DRY] would close $owner/$name#$num — the session produced no changes"
      recon_pr_entry "$url" "$num" closed-empty || return 1
      return 0
    fi
    if ! out="$("$GH_BIN" pr close "$num" --repo "$owner/$name" \
          --comment "$RECONCILE_EMPTY_COMMENT" 2>&1)"; then
      recon_fail "$routine / $repo — gh pr close failed for #$num: $(one_line "$out")" "$routine" "$repo"
      return 1
    fi
    RECON_CLOSED=$((RECON_CLOSED + 1))
    log "  -> $routine / $repo — closed $owner/$name#$num (0 files changed)"
    record reconciled "$routine" "$repo" "closed empty PR #$num"
    recon_pr_entry "$url" "$num" closed-empty || return 1
    return 0
  fi

  label="jules-routine:$routine"
  if ! jq -e --arg l "$label" '[(.labels // [])[] | (.name // "")] | index($l) != null' \
        >/dev/null 2>&1 <<<"$out"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [DRY] would label $owner/$name#$num $label"
    else
      if ! ensure_label "$owner/$name" "$label"; then
        recon_fail "$routine / $repo — could not ensure the $label label on $owner/$name" "$routine" "$repo"
        return 1
      fi
      if ! out2="$("$GH_BIN" pr edit "$num" --repo "$owner/$name" --add-label "$label" 2>&1)"; then
        recon_fail "$routine / $repo — gh pr edit --add-label failed for #$num: $(one_line "$out2")" "$routine" "$repo"
        return 1
      fi
      RECON_LABELED=$((RECON_LABELED + 1))
    fi
    actions+=(labeled)
  fi

  # chore, because the routine's real change type is not knowable from the API.
  # The squash merger can still edit it; an unmergeable subject cannot be edited
  # by anyone who is not looking at the pull request, which is the failure #479
  # actually hit.
  if [[ ! "$title" =~ $CONVENTIONAL_SUBJECT_RE ]]; then
    newtitle="chore($routine): $(strip_routine_prefix "$routine" "$title")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [DRY] would retitle $owner/$name#$num to: $newtitle"
    else
      if ! out2="$("$GH_BIN" pr edit "$num" --repo "$owner/$name" --title "$newtitle" 2>&1)"; then
        recon_fail "$routine / $repo — gh pr edit --title failed for #$num: $(one_line "$out2")" "$routine" "$repo"
        return 1
      fi
      RECON_RETITLED=$((RECON_RETITLED + 1))
    fi
    actions+=(retitled)
  fi

  # check-commit-format.sh lints the SUBJECTS of the commits a pull request
  # adds, not its title, so retitling does not unblock the required check — it
  # fixes what a squash merge lands on main and nothing more. Rewriting the
  # session's branch is not this dispatcher's to do, so a pull request left
  # unmergeable by its own commit subjects is named and recorded rather than
  # settled in silence. That is what the conventional-subject line the
  # dispatcher injects into every prompt is there to prevent up front (#479).
  #
  # The commits endpoint, not `gh pr view --json commits`: the checker runs
  # `git rev-list --no-merges` and skips the revert auto-message, and only this
  # payload carries each commit's parents. Reporting a merge commit as blocking
  # would be a false alarm on a pull request CI is perfectly happy with.
  if ! commits="$("$GH_BIN" api "repos/$owner/$name/pulls/$num/commits?per_page=100" 2>&1)"; then
    recon_fail "$routine / $repo — gh api pulls/$num/commits failed: $(one_line "$commits")" "$routine" "$repo"
    return 1
  fi
  if ! bad_subjects="$(jq -r --arg re "$CONVENTIONAL_SUBJECT_RE" '
        [ .[]
          | select(((.parents // []) | length) < 2)
          | ((.commit.message // "") | split("\n")[0])
          | select((startswith("Revert ")) | not)
          | select((test($re)) | not) ]
        | length' <<<"$commits" 2>/dev/null)"; then
    recon_fail "$routine / $repo — pulls/$num/commits returned a payload this run cannot read" "$routine" "$repo"
    return 1
  fi
  if [[ "$bad_subjects" =~ ^[1-9][0-9]*$ ]]; then
    RECON_SUBJECTS_OK=false
    RECON_BLOCKED_SUBJECTS=$((RECON_BLOCKED_SUBJECTS + 1))
    log "  -- $routine / $repo — $owner/$name#$num carries $bad_subjects commit subject(s)"
    log "     the required commit-format check rejects; its title is fixed, that check is not."
  fi

  action="unchanged"
  [[ "${#actions[@]}" -gt 0 ]] && action="$(IFS='+'; printf '%s' "${actions[*]}")"
  log "  -> $routine / $repo — $owner/$name#$num $action"
  record reconciled "$routine" "$repo" "PR #$num $action"
  recon_pr_entry "$url" "$num" "$action" || return 1
  return 0
}

reconcile_session() { # session routine repo
  local session="$1" routine="$2" repo="$3"
  local id resp state n i url failed_any=0

  recon_reset_session
  RECON_CHECKED=$((RECON_CHECKED + 1))

  id="${session#sessions/}"
  if [[ "$id" == "$session" || ! "$id" =~ ^[0-9]+$ ]]; then
    recon_fail "$routine / $repo — ledger session '$(one_line "$session")' is not sessions/<digits>; nothing of it reaches a URL" "$routine" "$repo"
    recon_pend "$session" "$routine" "$repo" error "malformed session name" && recon_flush
    return 1
  fi
  if [[ "$routine" == "-" || "$repo" == "-" ]]; then
    recon_fail "$session — the ledger record names no routine or repository, so there is nothing to check its pull request against" "$routine" "$repo"
    recon_pend "$session" "$routine" "$repo" error "ledger record missing routine or repo" && recon_flush
    return 1
  fi
  # Revalidated on the way out of the ledger, which nothing has checked since
  # the catalog parser read it: the name becomes a label and a commit scope, and
  # a scope outside the checker's [a-z0-9._/-] would produce a title the
  # commit-format check still rejects. A ledger is a file an operator can edit.
  if [[ ! "$routine" =~ ^[a-z0-9-]+$ ]]; then
    recon_fail "$session — ledger routine name '$(one_line "$routine")' is not [a-z0-9-]+; it would become a label and a commit scope" "$routine" "$repo"
    recon_pend "$session" "$routine" "$repo" error "ledger routine name rejected" && recon_flush
    return 1
  fi
  if [[ ! "$repo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
    recon_fail "$session — ledger repository '$(one_line "$repo")' is not OWNER/NAME; no pull request URL can be checked against it" "$routine" "$repo"
    recon_pend "$session" "$routine" "$repo" error "ledger repository rejected" && recon_flush
    return 1
  fi

  if ! resp="$(curl_api GET "/sessions/$id")"; then
    recon_fail "$routine / $repo — GET /sessions/$id failed; retried on a later run" "$routine" "$repo"
    return 1
  fi
  state="$(jq -r '.state // ""' <<<"$resp" 2>/dev/null || true)"
  if [[ -z "$state" ]]; then
    recon_fail "$routine / $repo — GET /sessions/$id returned no state" "$routine" "$repo"
    return 1
  fi
  # QUEUED, PLANNING, AWAITING_*, IN_PROGRESS, PAUSED — not a result yet. No
  # record, so the next run looks again; recording one here would freeze the
  # session's outcome at "we looked too early".
  if [[ "$state" != "COMPLETED" && "$state" != "FAILED" ]]; then
    log "  -- $routine / $repo — $session is $state; reconciled once it reaches a terminal state"
    return 0
  fi

  if [[ "$state" == "FAILED" ]]; then
    log "  -- $routine / $repo — $session FAILED; recorded, no pull request to settle"
    record reconciled "$routine" "$repo" "session FAILED"
    recon_pend "$session" "$routine" "$repo" failed "session state FAILED" || return 1
    recon_flush
    return 0
  fi

  # A response whose outputs cannot be read is NOT a session without a pull
  # request: recording no-pr would be terminal and the real outcome would never
  # be looked at again. Counted as a failure and retried instead.
  if ! n="$(jq -r 'if ((.outputs // null) == null) then 0
                   elif (.outputs | type) == "array"
                   then ([.outputs[] | select((type == "object") and has("pullRequest"))] | length)
                   else error("outputs is not an array") end' <<<"$resp" 2>/dev/null)" \
     || [[ ! "$n" =~ ^(0|[1-9][0-9]*)$ ]]; then
    recon_fail "$routine / $repo — GET /sessions/$id returned unreadable outputs; retried on a later run" "$routine" "$repo"
    return 1
  fi

  if [[ "$n" -eq 0 ]]; then
    # Observed live: a COMPLETED session with `outputs` null — no change set, no
    # branch, no pull request. That is a real outcome, not an error.
    log "  -- $routine / $repo — $session COMPLETED with no pull request"
    record reconciled "$routine" "$repo" "completed with no pull request"
    recon_pend "$session" "$routine" "$repo" no-pr "session produced no pull request" || return 1
    recon_flush
    return 0
  fi

  # Read one JSON value at a time rather than a newline-delimited list: a url
  # field carrying an embedded newline would otherwise be split into two URLs,
  # each passing the anchored pattern the whole field must fail.
  for ((i = 0; i < n; i++)); do
    if ! url="$(jq -r --argjson i "$i" \
          '[.outputs[] | select((type == "object") and has("pullRequest"))]
           | .[$i] | (.pullRequest.url // "")' <<<"$resp" 2>/dev/null)"; then
      recon_fail "$routine / $repo — could not read output $i of $session" "$routine" "$repo"
      failed_any=1
      continue
    fi
    reconcile_pr "$session" "$routine" "$repo" "$url" || failed_any=1
  done

  if [[ "$failed_any" -eq 1 ]]; then
    recon_reset_session
    return 1
  fi
  recon_pend "$session" "$routine" "$repo" unchanged "state $state" || return 1
  recon_flush
}

reconcile_pass() {
  local candidates count session routine repo
  if ! candidates="$(reconcile_candidates)"; then
    recon_fail "could not read $LEDGER while collecting the sessions to settle" "" ""
    return 1
  fi
  if [[ -z "$candidates" ]]; then
    log "reconcile: no session is waiting to be settled"
    return 0
  fi
  count="$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')"

  # Standalone runs already died on a missing gh. Inside a dispatch it must not
  # be fatal — the sessions were created and their ledger records are what
  # bounds the spend — but it is still one failure, so the exit code says the
  # run was not clean.
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    log "  !! reconcile skipped: the GitHub CLI (gh) is not on PATH, so $count routine"
    log "     session(s) cannot have their pull requests closed or labeled. The"
    log "     dispatch itself stands; install gh or run --reconcile once it is there."
    record error "" "" "reconcile skipped: gh not on PATH"
    FAILURES=$((FAILURES + 1))
    RECON_FAILURES=$((RECON_FAILURES + 1))
    return 1
  fi

  log "reconcile: settling $count session(s)$([[ "$DRY_RUN" -eq 1 ]] && printf ' (DRY-RUN)')"
  while IFS="$(printf '\t')" read -r session routine repo; do
    [[ -n "$session" ]] || continue
    reconcile_session "$session" "$routine" "$repo" || true
  done <<<"$candidates"
  return 0
}

do_reconcile() {
  # gh is the whole point of a standalone pass, so its absence is fatal here
  # rather than a clean-looking no-op.
  command -v "$GH_BIN" >/dev/null 2>&1 \
    || die "--reconcile needs the GitHub CLI (gh) on PATH"
  read_api_key

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    # A standalone pass writes the ledger, so it takes the same lock a dispatch
    # does. A dry run writes nothing and must leave the state dir byte-identical.
    if ! acquire_lock; then
      log "another dispatch already holds $STATE_DIR/dispatch.lock — nothing to do"
      exit 0
    fi
  fi
  validate_ledger

  log "═══ jules-dispatch --reconcile $NOW_ISO ═══"
  reconcile_pass || true
  write_status
  log "═══ jules-dispatch reconcile done: checked=$RECON_CHECKED closed=$RECON_CLOSED labeled=$RECON_LABELED retitled=$RECON_RETITLED blocked=$RECON_BLOCKED_SUBJECTS failures=$RECON_FAILURES ═══"
  [[ "$FAILURES" -eq 0 ]] || exit 1
}

# ── Report ───────────────────────────────────────────────────────────
# Buckets by whole weeks back from now rather than by calendar week: no
# dependence on strftime %G/%V, which not every jq build supports.
do_report() {
  command -v "$GH_BIN" >/dev/null 2>&1 || die "--report needs the GitHub CLI (gh) on PATH"
  validate_ledger
  local file repo scope label rows="" prs cutoff
  local truncated="" failed_queries="" rejected_routines="" ledger_scope=""
  cutoff=$((NOW_EPOCH - REPORT_DAYS * 86400))

  while IFS= read -r file; do
    if ! parse_routine "$file"; then
      # Same reasoning as a failed query: a routine missing from the table has to
      # be named in the table, not only in an exit code the reader never sees.
      rejected_routines="$rejected_routines$(basename "$file" .md); "
      FAILURES=$((FAILURES + 1))
      continue
    fi
    label="$FM_LABEL"
    # The report's scope is the routine's current repositories UNION the ones the
    # ledger says it was dispatched to. Querying only the current list would
    # delete a removed repository's history from the window and move the merge
    # rate — the number the retirement rule is decided on — with no sign that
    # anything was dropped.
    if ! ledger_scope="$(ledger_repos "$FM_NAME")"; then
      die "cannot read the dispatch ledger while building the report scope: $LEDGER"
    fi
    if [[ "${FM_REPOS[0]}" == "all" ]]; then
      scope="$ledger_scope"
    else
      scope="$(printf '%s\n%s\n' "$(printf '%s\n' "${FM_REPOS[@]}")" "$ledger_scope" \
        | sed '/^$/d' | sort -u)"
    fi
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      [[ -n "$ONLY_REPO" && "$repo" != "$ONLY_REPO" ]] && continue
      if ! prs="$("$GH_BIN" pr list --repo "$repo" --state all --limit "$REPORT_LIMIT" \
            --search "label:$label" --json state,createdAt,mergedAt 2>/dev/null)"; then
        printf 'jules-dispatch: gh pr list failed for %s (label %s)\n' "$repo" "$label" >&2
        # A non-zero exit at the end is no help to someone reading the posted
        # table: the counts would look complete and a routine could be retired on
        # them. Carry the failure into the report body itself.
        failed_queries="$failed_queries$repo ($label); "
        FAILURES=$((FAILURES + 1))
        continue
      fi
      # The fetch is bounded, and the bound is applied BEFORE the date window, so
      # a busy routine could silently report partial counts — and the retirement
      # rule is decided on these numbers. Say so rather than letting a truncated
      # merge rate look authoritative.
      if [[ "$(jq -r 'length' <<<"$prs")" -ge "$REPORT_LIMIT" ]]; then
        truncated="$truncated$repo ($label); "
      fi
      rows="$rows$(jq -r --arg routine "$FM_NAME" --argjson now "$NOW_EPOCH" \
        --argjson cutoff "$cutoff" '
        [ .[]
          | (.createdAt | fromdateiso8601) as $c
          | select($c >= $cutoff)
          | { week: (((($now - $c) / 604800) | floor) + 1),
              merged: (if (.mergedAt // null) != null then 1 else 0 end),
              closed: (if .state == "CLOSED" then 1 else 0 end) } ]
        | group_by(.week) | .[]
        | [$routine, (.[0].week | tostring), (length | tostring),
           (map(.merged) | add | tostring), (map(.closed) | add | tostring)]
        | @tsv' <<<"$prs")"$'\n'
    done <<<"$scope"
  done < <(routine_files)

  local table
  table="$(printf '%s' "$rows" | sed '/^$/d' | awk -F'\t' '
    { o[$1 FS $2] += $3; m[$1 FS $2] += $4; c[$1 FS $2] += $5 }
    END {
      printf "| routine | weeks ago | opened | merged | closed | merge rate |\n"
      printf "|---|---|---|---|---|---|\n"
      for (k in o) {
        split(k, p, FS)
        rate = (o[k] > 0) ? sprintf("%d%%", (m[k] * 100) / o[k]) : "n/a"
        printf "| %s | %s | %d | %d | %d | %s |\n", p[1], p[2], o[k], m[k], c[k], rate
      }
    }' | { read -r h1; read -r h2; printf '%s\n%s\n' "$h1" "$h2"; sort -t'|' -k2,2 -k3,3n; })"

  # Every reason the table can be partial belongs IN the table's body: the
  # retirement rule is decided on these numbers, and a non-zero exit code is
  # invisible to whoever reads the posted comment.
  local caveat=""
  add_caveat() { # heading detail
    [[ -n "$2" ]] || return 0
    caveat="$caveat$(printf '\n- %s: %s' "$1" "${2%; }")"
  }
  add_caveat "pull request fetch hit its $REPORT_LIMIT-item bound (raise JULES_REPORT_LIMIT or narrow --days)" "$truncated"
  add_caveat "pull request query FAILED, so these contribute nothing above" "$failed_queries"
  add_caveat "routine frontmatter was rejected, so these are missing entirely" "$rejected_routines"
  if [[ -n "$caveat" ]]; then
    caveat="$(printf '\n**These counts are incomplete.**%s\n\nDo not retire a routine on these numbers until the gaps above are resolved.\n' "$caveat")"
  fi
  printf 'Jules routine lane — last %s days (generated %s)\n\n%s\n%s\nTuning rule (ADR-0009): a routine whose merge rate stays under 30%% for two\nweeks running gets its prompt rewritten or `paused: true`.\n' \
    "$REPORT_DAYS" "$NOW_ISO" "$table" "$caveat"

  if [[ "$POST" -eq 1 ]]; then
    [[ "$TRACKER" =~ ^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$ ]] \
      || die "JULES_TRACKER must be OWNER/NAME#ISSUE, got: $TRACKER"
    # --dry-run means "write nothing", and a GitHub comment is a remote write.
    # The flag has to hold across every mode or it is not a guarantee.
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '\n[DRY] would comment the table above on %s\n' "$TRACKER"
      [[ "$FAILURES" -eq 0 ]] || exit 1
      return 0
    fi
    printf 'Jules routine lane — last %s days (generated %s)\n\n%s\n%s' \
      "$REPORT_DAYS" "$NOW_ISO" "$table" "$caveat" \
      | "$GH_BIN" issue comment "${BASH_REMATCH[2]}" --repo "${BASH_REMATCH[1]}" --body-file -
  fi

  [[ "$FAILURES" -eq 0 ]] || exit 1
}

case "$MODE" in
  report) do_report ;;
  reconcile) do_reconcile ;;
  *) do_dispatch ;;
esac
