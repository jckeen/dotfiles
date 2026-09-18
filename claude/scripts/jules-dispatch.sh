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
#   JULES_LOCK_STALE_SECONDS  age at which an abandoned dispatch lock is
#                       reclaimed (default 7200)
#
# State (all under JULES_STATE_DIR):
#   dispatch.jsonl   one line per created session — the idempotency ledger
#   status.json      last run's outcome, for hooks and the status line
#   dispatch.log     appended run log
#   dispatch.lock    held for the duration of a dispatch (not a dry run)
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

DRY_RUN=0
ONLY_ROUTINE=""
ONLY_REPO=""
MODE="dispatch"
REPORT_DAYS=28
POST=0

API_KEY=""
SOURCES_JSON=""
TODAY="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"
CREATED=0
FAILURES=0
SPENT=0

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

[[ "$REPORT_DAYS" =~ ^[1-9][0-9]*$ ]] || die "--days must be a positive integer"
[[ -n "$ONLY_REPO" && ! "$ONLY_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  && die "--repo must be OWNER/NAME, got: $ONLY_REPO"
[[ "$POST" -eq 1 && "$MODE" != "report" ]] && die "--post only applies to --report"
[[ "$DAILY_CAP" =~ ^[0-9]+$ ]] || die "JULES_DAILY_CAP must be a non-negative integer"
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
          FM_REPOS+=("${BASH_REMATCH[1]}"); continue
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
            if [[ -n "$value" ]]; then FM_REPOS=("$value"); else in_repos=1; fi
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
  [[ "$FM_MAX_PRS" =~ ^[1-9][0-9]*$ ]] || { fm_fail "$file" "max_prs_per_run must be a positive integer"; return 1; }
  [[ "$FM_MAX_FILES" =~ ^[1-9][0-9]*$ ]] || { fm_fail "$file" "max_files must be a positive integer"; return 1; }
  [[ "$FM_LABEL" == "jules-routine:$FM_NAME" ]] \
    || { fm_fail "$file" "label must be 'jules-routine:$FM_NAME', got '$FM_LABEL'"; return 1; }
  [[ -n "$FM_ACCEPTANCE" ]] || { fm_fail "$file" "acceptance must not be empty"; return 1; }
  [[ "$FM_PAUSED" == "true" || "$FM_PAUSED" == "false" ]] \
    || { fm_fail "$file" "paused must be 'true' or 'false', got '$FM_PAUSED'"; return 1; }
  [[ "${#FM_REPOS[@]}" -gt 0 ]] || { fm_fail "$file" "repos must be 'all' or a non-empty list"; return 1; }
  local r
  for r in "${FM_REPOS[@]}"; do
    [[ "$r" == "all" || "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
      || { fm_fail "$file" "repos entry must be 'all' or OWNER/NAME, got '$r'"; return 1; }
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
      end' <<<"$SOURCES_JSON" | sed '/^$/d' | sort -u
}

# ── Ledger ───────────────────────────────────────────────────────────
ledger_query() { # jq-filter -> value
  [[ -s "$LEDGER" ]] || { printf '0\n'; return 0; }
  jq -s "$@" "$LEDGER" 2>/dev/null \
    || die "dispatch ledger is not valid JSON lines: $LEDGER"
}

dispatched_today() { ledger_query --arg d "$TODAY" '[.[] | select(.date == $d)] | length'; }

already_dispatched() { # routine repo
  local n
  n="$(ledger_query --arg d "$TODAY" --arg r "$1" --arg p "$2" \
        '[.[] | select(.date == $d and .routine == $r and .repo == $p)] | length')"
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
LOCK_DIR=""
LOCK_HELD=0
# An abandoned lock must not disable the timer forever, so one older than this is
# reclaimed. Well above any plausible run: the dispatch is a handful of HTTPS
# calls, each capped at 60s.
LOCK_STALE_SECONDS="${JULES_LOCK_STALE_SECONDS:-7200}"
# `exit` stays last so the trap preserves the original exit status. The lock is
# removed only when this process owns it — never another run's.
trap 'rm -f "$EVENTS_FILE"; [[ -n "$BODY_FILE" ]] && rm -f "$BODY_FILE"; [[ "$LOCK_HELD" -eq 1 ]] && rm -rf "$LOCK_DIR"; exit' EXIT

dir_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

# Reading the ledger, deciding eligibility, creating a session and recording it
# is one critical section: a manual run overlapping the 09:00 timer would
# otherwise read the same spend and dispatch the same routine twice, defeating
# both the idempotency check and the daily cap. mkdir is atomic on POSIX, so it
# needs no flock (absent on some systems this script still has to run on).
acquire_lock() {
  LOCK_DIR="$STATE_DIR/dispatch.lock"
  mkdir "$LOCK_DIR" 2>/dev/null && { LOCK_HELD=1; return 0; }
  local mtime age
  mtime="$(dir_mtime "$LOCK_DIR")" || return 1
  age=$((NOW_EPOCH - mtime))
  if [[ "$age" -ge "$LOCK_STALE_SECONDS" ]]; then
    log "  !! reclaiming a stale dispatch lock (${age}s old): $LOCK_DIR"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && { LOCK_HELD=1; return 0; }
  fi
  return 1
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
    '{checked_at: $checked_at, date: $date, daily_cap: $cap,
      created_this_run: $created, dispatched_today: $dispatched_today,
      failures: $failures, events: $events}' > "$tmp"
  mv "$tmp" "$STATUS_FILE"
}

# ── Dispatch ─────────────────────────────────────────────────────────
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
  local repo="$2" source="$3" prompt response session url
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
    log "  !! $FM_NAME / $repo — POST /sessions failed"
    record error "$FM_NAME" "$repo" "POST /sessions failed"
    FAILURES=$((FAILURES + 1))
    rm -f "$BODY_FILE"; BODY_FILE=""
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

  # The session already exists at this point, so a failed ledger append is not a
  # failed dispatch — it is an unrecorded one, which the next run would repeat.
  # `dispatch_one` is called with `|| true`, so errexit is off inside it: the
  # append has to be checked explicitly or the failure passes as a success.
  if ! jq -nc --arg at "$NOW_ISO" --arg date "$TODAY" --arg routine "$FM_NAME" \
      --arg repo "$repo" --arg source "$source" --arg session "$session" --arg url "$url" \
      '{dispatched_at: $at, date: $date, routine: $routine, repo: $repo,
        source: $source, session: $session, url: $url}' >> "$LEDGER"; then
    log "  !! $FM_NAME / $repo — created $session but COULD NOT record it in $LEDGER"
    log "     The next run will dispatch this routine again. Fix the ledger first."
    record error "$FM_NAME" "$repo" "session $session created but not recorded"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  CREATED=$((CREATED + 1))
  log "  -> $FM_NAME / $repo — created $session"
  record created "$FM_NAME" "$repo" "$session"
}

do_dispatch() {
  read_api_key
  if ! SOURCES_JSON="$(curl_api GET /sources)"; then
    die "GET /sources failed — cannot resolve any repository"
  fi
  jq -e 'type == "object"' >/dev/null <<<"$SOURCES_JSON" \
    || die "GET /sources did not return a JSON object"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    # A dry run needs no lock: it creates nothing and must leave the state dir
    # byte-identical, so a lock directory there would itself be a mutation.
    if ! acquire_lock; then
      log "another dispatch already holds $STATE_DIR/dispatch.lock — nothing to do"
      exit 0
    fi
  fi

  # One budget counter for the whole run: seeded from the ledger (what earlier
  # runs already spent today) and incremented per dispatch, so the cap holds in
  # a dry run too — where nothing is appended to the ledger to re-read.
  local used
  used="$(dispatched_today)"
  SPENT="$used"
  log "═══ jules-dispatch $NOW_ISO ═══"
  log "catalog: $ROUTINE_DIR; dispatched today: $used/$DAILY_CAP$([[ "$DRY_RUN" -eq 1 ]] && printf ' (DRY-RUN)')"

  local file repo source scope interval
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

      interval="$(schedule_interval)"
      if [[ "$interval" -gt 0 ]] && dispatched_within "$FM_NAME" "$repo" "$interval"; then
        log "  -- $FM_NAME / $repo — schedule: $FM_SCHEDULE, dispatched inside the last $((interval / 86400)) day(s); skipped"
        record skipped "$FM_NAME" "$repo" "inside the $FM_SCHEDULE cadence window"
        continue
      fi

      if [[ "$SPENT" -ge "$DAILY_CAP" ]]; then
        log "  -- $FM_NAME / $repo — daily cap $DAILY_CAP reached; skipped"
        record skipped "$FM_NAME" "$repo" "daily cap reached"
        continue
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        SPENT=$((SPENT + 1))
        log "  [DRY] would dispatch $FM_NAME / $repo via $source"
        record would-dispatch "$FM_NAME" "$repo" "$source"
        continue
      fi

      SPENT=$((SPENT + 1))
      dispatch_one "$file" "$repo" "$source" || true
    done <<<"$scope"
  done < <(routine_files)

  write_status
  log "═══ jules-dispatch done: created=$CREATED failures=$FAILURES ═══"
  [[ "$FAILURES" -eq 0 ]] || exit 1
}

# ── Report ───────────────────────────────────────────────────────────
# Buckets by whole weeks back from now rather than by calendar week: no
# dependence on strftime %G/%V, which not every jq build supports.
do_report() {
  command -v gh >/dev/null 2>&1 || die "--report needs the GitHub CLI (gh) on PATH"
  local file repo scope label rows="" prs cutoff
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
      if ! prs="$(gh pr list --repo "$repo" --state all --limit 200 \
            --search "label:$label" --json state,createdAt,mergedAt 2>/dev/null)"; then
        printf 'jules-dispatch: gh pr list failed for %s (label %s)\n' "$repo" "$label" >&2
        FAILURES=$((FAILURES + 1))
        continue
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

  printf 'Jules routine lane — last %s days (generated %s)\n\n%s\n\nTuning rule (ADR-0009): a routine whose merge rate stays under 30%% for two\nweeks running gets its prompt rewritten or `paused: true`.\n' \
    "$REPORT_DAYS" "$NOW_ISO" "$table"

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
    printf 'Jules routine lane — last %s days (generated %s)\n\n%s\n' \
      "$REPORT_DAYS" "$NOW_ISO" "$table" \
      | gh issue comment "${BASH_REMATCH[2]}" --repo "${BASH_REMATCH[1]}" --body-file -
  fi

  [[ "$FAILURES" -eq 0 ]] || exit 1
}

case "$MODE" in
  report) do_report ;;
  *) do_dispatch ;;
esac
