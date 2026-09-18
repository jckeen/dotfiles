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
#   jules-dispatch.sh --report [--days N] [--post]
#
# Flags:
#   --dry-run          resolve and print what would be dispatched; write nothing
#   --routine NAME     only this routine (the catalog file's basename)
#   --repo OWNER/NAME  only this repository
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
#   JULES_STARTING_BRANCH  optional starting branch for every session; omitted
#                       from the request when unset, letting the API choose
#   JULES_TRACKER       owner/name#issue for --post (default jckeen/dotfiles#446)
#   JULES_FLOCK         flock(1) to use (default flock); a test seam for the
#                       branch taken when flock is unavailable
#   JULES_REPORT_LIMIT  --report pull-request fetch bound (default 1000); the
#                       report says so when a repository hits it
#
# State (all under JULES_STATE_DIR):
#   dispatch.jsonl   one line per created session — the idempotency ledger
#   status.json      last run's outcome, for hooks and the status line
#   dispatch.log     appended run log
#   dispatch.lock    flock'd for the duration of a dispatch (not a dry run)
#
# Requires: bash, curl, jq. --report additionally requires gh.

set -euo pipefail

# The API host is a constant, never read from configuration or from a routine
# file: an ambient credential must never be attachable to an attacker-chosen
# host. `curl` is also called without -L, so a redirect cannot carry the key
# somewhere else.
readonly JULES_API_HOST="jules.googleapis.com"
readonly JULES_API_BASE="https://${JULES_API_HOST}/v1alpha"
readonly JULES_AUTOMATION_MODE="AUTO_CREATE_PR"
# A bound on paging, so a server that keeps handing back a token cannot spin
# here forever. 100 sources per page, so this is 5000 repositories.
readonly SOURCES_PAGE_LIMIT=50

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

DRY_RUN=0
ONLY_ROUTINE=""
ONLY_REPO=""
MODE="dispatch"
REPORT_DAYS=28
POST=0

API_KEY=""
SOURCES_JSON=""
SOURCES_PAGES=0
TODAY="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"
CREATED=0
FAILURES=0
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
    --report) MODE="report" ;;
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

[[ "$REPORT_DAYS" =~ ^[1-9][0-9]*$ ]] \
  || die "--days must be a positive integer with no leading zeros, got: $REPORT_DAYS"
[[ -n "$ONLY_REPO" && ! "$ONLY_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  && die "--repo must be OWNER/NAME, got: $ONLY_REPO"
[[ "$POST" -eq 1 && "$MODE" != "report" ]] && die "--post only applies to --report"
# No leading zeros: bash reads "08" as octal inside [[ -ge ]], the comparison
# errors out, and an errored test is a false one — so the cap silently stopped
# applying and every candidate dispatched. Verified: `[[ 100 -ge 08 ]]` exits 1
# with "value too great for base".
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
[[ "$MODE" == "dispatch" ]] && { command -v curl >/dev/null 2>&1 || die "curl is required"; }

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
  local args=(--proto '=https' --fail -sS --max-time 60 -X "$method"
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
      # The token goes into a URL, so it is never interpolated unvalidated.
      [[ "$token" =~ ^[A-Za-z0-9._~=-]+$ ]] \
        || die "GET /sources returned a nextPageToken outside [A-Za-z0-9._~=-]"
      path="$path&pageToken=$token"
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

ledger_append() { # status attempt repo source session url
  jq -nc --arg at "$NOW_ISO" --arg date "$TODAY" --arg routine "$FM_NAME" \
    --arg repo "$3" --arg source "$4" --arg status "$1" --arg attempt "$2" \
    --arg session "$5" --arg url "$6" \
    '{dispatched_at: $at, date: $date, routine: $routine, repo: $repo,
      source: $source, status: $status, attempt: $attempt,
      session: $session, url: $url}' >> "$LEDGER"
}

ledger_query() { # jq-filter -> value
  [[ -s "$LEDGER" ]] || { printf '0\n'; return 0; }
  jq -s "$@" "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

dispatched_today() {
  ledger_query --arg d "$TODAY" \
    "[.[] | select(.date == \$d) | $LEDGER_KEY] | unique | length"
}

# Attempts today with no matching "created" record: a session may or may not
# exist for each one. Surfaced rather than retried, because a duplicate cloud
# session is the one outcome this script must never produce on its own.
unresolved_attempts() {
  ledger_query --arg d "$TODAY" \
    "[.[] | select(.date == \$d)] as \$t
     | (\$t | map(select((.status // \"created\") == \"attempted\") | $LEDGER_KEY) | unique) as \$a
     | (\$t | map(select((.status // \"created\") == \"created\") | $LEDGER_KEY) | unique) as \$c
     | (\$a - \$c) | length"
}

already_dispatched() { # routine repo
  local n
  n="$(ledger_query --arg d "$TODAY" --arg r "$1" --arg p "$2" \
        "[.[] | select(.date == \$d and .routine == \$r and .repo == \$p) | $LEDGER_KEY] | unique | length")"
  [[ "$n" -gt 0 ]]
}

# A weekly routine needs a cadence check, not just the same-day one: the timer
# fires daily, so without this `schedule: weekly` would be decoration and a
# weekly routine would run seven times a week. Compared on the recorded
# timestamp rather than the date string, so the window is exact and needs no
# non-portable date arithmetic.
dispatched_within() { # routine repo seconds
  [[ -s "$LEDGER" ]] || return 1
  local n cutoff=$((NOW_EPOCH - $3))
  n="$(ledger_query --arg r "$1" --arg p "$2" --argjson cutoff "$cutoff" \
        '[.[] | select(.routine == $r and .repo == $p
           and ((.dispatched_at // "") | (try fromdateiso8601 catch 0)) >= $cutoff)] | length')"
  [[ "$n" -gt 0 ]]
}

# Seconds a routine must leave between dispatches for the same repository.
schedule_interval() {
  case "$FM_SCHEDULE" in
    weekly) printf '%s' $((7 * 86400)) ;;
    *) printf '0' ;;
  esac
}

ledger_repos() { # distinct repos ever dispatched to
  [[ -s "$LEDGER" ]] || return 0
  jq -sr '[.[] | .repo // empty] | unique | .[]' "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

# ── Run events (for status.json) ─────────────────────────────────────
EVENTS_FILE="$(mktemp)"
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
    '{checked_at: $checked_at, date: $date, daily_cap: $cap,
      created_this_run: $created, dispatched_today: $dispatched_today,
      deferred_to_a_later_day: $deferred, serialized: $serialized,
      failures: $failures, events: $events}' > "$tmp"
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
    '[.[] | select(.routine == $r and .repo == $p)
          | ((.dispatched_at // "") | (try fromdateiso8601 catch 0))]
     | max // 0'
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

build_prompt() { # repo
  printf 'Repository: %s\nRoutine: %s\nHard limits: at most %s pull request(s) this run; at most %s file(s) changed per pull request.\nRequired PR label: %s\nAcceptance: %s\n\n%s' \
    "$1" "$FM_NAME" "$FM_MAX_PRS" "$FM_MAX_FILES" "$FM_LABEL" "$FM_ACCEPTANCE" "$FM_PROMPT"
}

dispatch_one() { # routine-file repo source
  local repo="$2" source="$3" prompt response session url attempt
  ATTEMPT_SEQ=$((ATTEMPT_SEQ + 1))
  attempt="$RUN_ID.$ATTEMPT_SEQ"

  # Write-ahead. If this fails, nothing has been created yet, so the run can stop
  # cleanly — the ledger is the only thing preserving idempotency and the cap.
  if ! ledger_append attempted "$attempt" "$repo" "$source" "" ""; then
    log "  !! $FM_NAME / $repo — cannot write $LEDGER; refusing to create a session"
    log "     The ledger is the only thing preserving idempotency and the daily"
    log "     cap, so this run stops here. Fix the ledger, then re-run."
    record error "$FM_NAME" "$repo" "ledger unwritable; no session created"
    FAILURES=$((FAILURES + 1))
    # 3 is the caller's signal to abort the whole run, not just this pair.
    return 3
  fi

  prompt="$(build_prompt "$repo")"
  BODY_FILE="$(mktemp)"
  jq -n --arg prompt "$prompt" --arg title "jules-routine: $FM_NAME ($repo)" \
    --arg source "$source" --arg mode "$JULES_AUTOMATION_MODE" \
    --arg branch "$STARTING_BRANCH" '
    {prompt: $prompt, title: $title, automationMode: $mode, requirePlanApproval: false,
     sourceContext: ({source: $source}
       + (if $branch == "" then {} else {githubRepoContext: {startingBranch: $branch}} end))}' \
    > "$BODY_FILE"

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
  local candidates file repo source scope interval rc
  candidates="$(mktemp)"
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

      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(last_dispatch_epoch "$FM_NAME" "$repo")" "$FM_NAME" "$repo" "$source" "$file" \
        >> "$candidates"
    done <<<"$scope"
  done < <(routine_files)

  # ── Phase 2: dispatch in fairness order, under the cap ────────────
  # Oldest last-dispatch first, then routine and repository for a deterministic
  # order among pairs that have never run (all of which carry 0).
  local sorted line last_epoch
  sorted="$(mktemp)"
  # Deduplicate on (routine, repository) before sorting. The parser already
  # rejects a repeated entry in one routine, and repository identities are
  # lowercased everywhere, so this is a backstop rather than the primary guard —
  # but every eligibility check runs before the first session is created, so a
  # duplicate reaching this queue would dispatch twice.
  awk -F'\t' '!seen[$2 FS $3]++' "$candidates" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2 -k3,3 > "$sorted"
  rm -f "$candidates"

  while IFS="$(printf '\t')" read -r last_epoch FM_NAME repo source file; do
    [[ -n "$FM_NAME" ]] || continue

    # TODAY and the spend were read once, before the network calls. A run that
    # crosses UTC midnight would keep recording against yesterday and spending
    # yesterday's budget, and another run that day could then redispatch those
    # pairs. Stop instead: the remaining work leads tomorrow's queue anyway,
    # because ordering is least-recently-dispatched first.
    if [[ "$(date -u +%Y-%m-%d)" != "$TODAY" ]]; then
      log "  -- the UTC day rolled over mid-run; stopping so nothing is recorded"
      log "     against $TODAY. The next run picks up where this one left off."
      record deferred "$FM_NAME" "$repo" "UTC day rolled over mid-run"
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

    if [[ "$DRY_RUN" -eq 1 ]]; then
      SPENT=$((SPENT + 1))
      log "  [DRY] would dispatch $FM_NAME / $repo via $source (last run: $last_epoch)"
      record would-dispatch "$FM_NAME" "$repo" "$source"
      continue
    fi

    SPENT=$((SPENT + 1))
    rc=0
    dispatch_one "$file" "$repo" "$source" || rc=$?
    if [[ "$rc" -eq 3 ]]; then
      rm -f "$sorted"
      write_status
      log "═══ jules-dispatch ABORTED: ledger unwritable (created=$CREATED failures=$FAILURES) ═══"
      exit 1
    fi
  done < "$sorted"
  rm -f "$sorted"

  write_status
  log "═══ jules-dispatch done: created=$CREATED deferred=$DEFERRED failures=$FAILURES ═══"
  [[ "$FAILURES" -eq 0 ]] || exit 1
}

# ── Report ───────────────────────────────────────────────────────────
# Buckets by whole weeks back from now rather than by calendar week: no
# dependence on strftime %G/%V, which not every jq build supports.
do_report() {
  command -v gh >/dev/null 2>&1 || die "--report needs the GitHub CLI (gh) on PATH"
  local file repo scope label rows="" prs cutoff truncated=""
  cutoff=$((NOW_EPOCH - REPORT_DAYS * 86400))

  while IFS= read -r file; do
    if ! parse_routine "$file"; then
      FAILURES=$((FAILURES + 1))
      continue
    fi
    label="$FM_LABEL"
    if [[ "${FM_REPOS[0]}" == "all" ]]; then
      scope="$(ledger_repos)"
    else
      scope="$(printf '%s\n' "${FM_REPOS[@]}")"
    fi
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      [[ -n "$ONLY_REPO" && "$repo" != "$ONLY_REPO" ]] && continue
      if ! prs="$(gh pr list --repo "$repo" --state all --limit "$REPORT_LIMIT" \
            --search "label:$label" --json state,createdAt,mergedAt 2>/dev/null)"; then
        printf 'jules-dispatch: gh pr list failed for %s (label %s)\n' "$repo" "$label" >&2
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

  local caveat=""
  if [[ -n "$truncated" ]]; then
    caveat="$(printf '\n**These counts are incomplete.** The pull request fetch hit its %s-item bound for: %s\nRaise JULES_REPORT_LIMIT or narrow --days before acting on the merge rates.\n' \
      "$REPORT_LIMIT" "${truncated%; }")"
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
      | gh issue comment "${BASH_REMATCH[2]}" --repo "${BASH_REMATCH[1]}" --body-file -
  fi

  [[ "$FAILURES" -eq 0 ]] || exit 1
}

case "$MODE" in
  report) do_report ;;
  *) do_dispatch ;;
esac
