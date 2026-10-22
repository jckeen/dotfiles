#!/usr/bin/env bash
# OperatorQueueReminder.hook.sh — surface open operator-action items at session start.
#
# Two sources, one renderer. The handoff skills (claude/ and agents/) record
# USER ACTION items either as "## <slug>" blocks in ~/.claude/operator-queue.md
# (added/project/deadline/verified/action lines; removed only when done) or as
# open issues labelled `operator-action`, which a phone or a cloud session can
# read too. Each issue lives in the private repo it concerns; items for a
# public repo or for several repos live in the private OPERATOR_QUEUE_REPO.
# One search reads them all: OPERATOR_QUEUE_REPO plus every repo of the
# OPERATOR_QUEUE_OWNERS accounts, counting only issues the operator (the gh
# login) wrote in private repos and whose body nobody else last edited. The file stays the source
# until its first lines carry the "> **Historical**" banner; after that the
# hook renders a cache of the issues and never touches the network itself.
# When the cache is missing or older than CACHE_TTL it starts `$0 --refresh`
# detached (stdio to /dev/null, its own session where setsid exists), which
# pages the issues through one GraphQL search per scope (the home repo, then
# each owner; a search that comes back incomplete is retried), turns them into the same blocks
# (see refresh; each heading names its repo, `## <slug> (<repo>#<n>)`) and
# atomically replaces the owner-only cache under
# ${XDG_STATE_HOME:-~/.local/state}/operator-queue/. SessionStart therefore
# costs no network time, however slow gh or jq is; the price is that a
# session may see data one refresh old, and the header says how old.
# Without a surface, queued items rot the way handoff prose did (each
# new handoff buries the last). A SessionStart hook's stdout is added to
# Claude's context, so every session starts knowing what only the operator can
# unblock: open items print with their age, deadline-carrying items first
# (soonest deadline at the top), past-due items flagged.
#
# Project filter (#558): the queue spans every repo, and printing all of it
# into every session buried the few items that concern the session and pushed
# the output past the persisted-output threshold (so the agent saw a preview,
# not the queue). Only items for the session's project print in full, plus
# every item past due or due today whatever its project. Each other project
# collapses to one line — `<project>: N items (oldest Xd, next deadline
# YYYY-MM-DD)` — and a footer names the queue file and the show-all switch.
#   Session project: the basename of the main checkout of the git repo holding
#   $CLAUDE_PROJECT_DIR (else the cwd) — resolved through --git-common-dir so a
#   linked worktree (.claude/worktrees/agent-…) still counts as its repo; the
#   plain directory basename outside git.
#   Item match: case-insensitive, on any word of the item's `project:` value,
#   since the queue names projects by repo basename and sometimes lists several
#   ("keen-media, operator-commons", "dotfiles / Codex Remote"). The summary
#   groups by the value's first word.
#
# Freshness: an item is only as true as its last check against live state.
# `verified: YYYY-MM-DD` records that check; an item whose newest of
# verified/added is more than STALE_DAYS old — or that carries no parseable
# date at all — is marked "[stale — re-verify]" and counted in the header, so
# the output shows which items have gone unchecked longest.
#
# ENV:
#   OPERATOR_QUEUE_SHOW_ALL=1  print every item in full (the pre-#558 view).
#   OPERATOR_QUEUE_FILE=<path> read this queue instead of
#                              ~/.claude/operator-queue.md (test fixtures).
#   OPERATOR_QUEUE_REPO=[host/]owner/name  the home for items with no private
#                              repo of their own (default
#                              github.com/jckeen/claude-memory; a bare
#                              owner/name means github.com). Keep it private —
#                              items name credentials and providers.
#   OPERATOR_QUEUE_OWNERS="a b"  accounts whose repos are searched too, on the
#                              same host (default "jckeen Keen-Media
#                              therealnewsnetwork"); empty = the home repo only.
#   OPERATOR_QUEUE_REFRESH_SYNC=1  refresh inline instead of detached (tests);
#                              =never renders the cache and starts no refresh.
#   OPERATOR_QUEUE_RETRY_SLEEPS="2 5"  seconds to wait before each retry of an
#                              incomplete search (tests set "0 0"); one word
#                              per retry, so "" means a single attempt.
#
# NEEDS: gh, jq and flock(1) (util-linux; `brew install flock` on macOS) for
#   the issue source. Without any of them every refresh fails, and the header
#   says so; the file source needs none of them.
#
# MODES (for the handoff skills; neither reads or writes the cache):
#   --scope        print `host`, `home` and `owners` lines: where it searches.
#   --find <slug>  print the URL of each open item it would list titled <slug>;
#                  exit 0 = conclusive, 2 = cannot tell (see find_item).
#
# TRIGGER: SessionStart (after HandoffReminder)
# EXIT: 0 always (advisory/warn-only, never blocks); --scope/--find/an unknown
#   flag exit 2 when they cannot answer
# FAILURE MODE: open — silent when the file queue is empty or has no parseable
#   item blocks, or when a fresh cache holds no open issues; one warning line
#   if the parse itself fails. A cache that is old, or older than a failed
#   refresh, is named as such in the header; with no cache at all, one line
#   says a refresh is under way or that the last one failed. A refresh in
#   flight (or killed mid-flight) is named in the header too. Nothing reads as
#   "no open items" unless a refresh within CACHE_TTL said so and none has
#   started or failed since. This hook only
#   reads the queue; its writes are the cache and the refresh markers, and
#   a refresh removes the temporaries a killed predecessor left behind.
#   The output is status only (#652): what the queue holds, its source and
#   its freshness, never an instruction to act on an item.
# BOUNDED: a queue over MAX_QUEUE_BYTES prints one warning line and exits
#   (the issue cache is copied at most MAX_QUEUE_BYTES + 1 bytes to find out);
#   at most MAX_ITEMS items (every item under OPERATOR_QUEUE_SHOW_ALL=1) and
#   MAX_ITEMS project summaries are rendered ("…and N more" for the rest),
#   each action is cut at MAX_ACTION_CHARS bytes, each item line at
#   MAX_LINE_CHARS and each summary label at 80, so a grown queue can never
#   flood session context or stall SessionStart. The detached fetch is capped
#   at FETCH_TIMEOUT seconds where timeout(1) exists.
# SELF-TEST: claude/scripts/tests/operator-queue-reminder.test.sh

set -uo pipefail

LEGACY="$HOME/.claude/operator-queue.md"
ISSUE_REPO="${OPERATOR_QUEUE_REPO:-github.com/jckeen/claude-memory}"
# The host is always explicit, so the cache key is exactly what gh queries
# (gh's own default host can come from its config, which the key cannot see).
case "$ISSUE_REPO" in */*/*) ;; *) ISSUE_REPO="github.com/$ISSUE_REPO" ;; esac
GH_HOSTNAME="${ISSUE_REPO%%/*}"
REPO_PATH="${ISSUE_REPO#*/}"
# The repo goes into a search query and every status line, so it must be a
# plain host/owner/name: no space, colon or other character can add a
# qualifier. Anything else leaves the issue source refused (see below).
# A bash match covers the whole value (grep -x would pass a valid first line).
REPO_OK=0
REPO_RE='^[A-Za-z0-9.-]{1,253}/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,255}$'
LC_ALL=C; [[ "$ISSUE_REPO" =~ $REPO_RE ]] && REPO_OK=1; unset LC_ALL
# Each item lives as an issue in the repo it concerns; ISSUE_REPO holds only
# the items with no private home of their own (public repos, multi-repo work).
# One search covers ISSUE_REPO plus every repo of each owner below (GitHub ORs
# repo:/user: qualifiers). Only GitHub login characters are kept, so a value
# can never smuggle another qualifier into the query. Empty = ISSUE_REPO only.
# At most MAX_OWNERS are kept (the first, sorted), so the scope printed in
# status lines stays bounded however long the value is.
MAX_OWNERS=10
OWNERS="$(printf '%s' "${OPERATOR_QUEUE_OWNERS-jckeen Keen-Media therealnewsnetwork}" |
  tr -s ' ,\t' '\n\n\n' | LC_ALL=C grep -xE '[A-Za-z0-9][A-Za-z0-9-]{0,38}' | tr '[:upper:]' '[:lower:]' |
  LC_ALL=C sort -u | sed -n "1,${MAX_OWNERS}p" | tr '\n' ' ')"
OWNERS="${OWNERS% }"
# The rendered items enter every session's context, so only issues the
# operator wrote (author:@me, the gh login) in private repos count: anyone can
# open an issue in a public repo, and a collaborator can label one.
SEARCH_BASE="is:issue is:open is:private author:@me label:operator-action"
SEARCH_Q="$SEARCH_BASE repo:$REPO_PATH"
# The refresh searches one scope at a time (see search_complete) and merges
# the results by node id; SEARCH_Q is the same search in one query, for
# --find and the printed command.
SCOPES=("repo:$REPO_PATH")
SCOPE="$ISSUE_REPO"
if [ -n "$OWNERS" ]; then
  for o in $OWNERS; do SEARCH_Q="$SEARCH_Q user:$o"; SCOPES+=("user:$o"); done
  SCOPE="$ISSUE_REPO and every repo of ${OWNERS// /, } on $GH_HOSTNAME"
fi
# The hook's own query, verbatim, so the printed command lists exactly what
# the hook searched (`gh search issues --repo X --owner Y` would AND them on gh
# versions using advanced search, and `gh issue list` drops the filters).
LIST_CMD="gh api graphql --hostname $GH_HOSTNAME --paginate -f q='$SEARCH_Q' -f query='query(\$q: String!, \$endCursor: String) { search(query: \$q, type: ISSUE, first: 100, after: \$endCursor) { pageInfo { hasNextPage endCursor } nodes { ... on Issue { url title } } } }' --jq '.data.search.nodes[] | .url + \"  \" + .title'"
# The fetch, shared by the refresh and --find so both see the same issues.
GQL='query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor } issueCount
    nodes { ... on Issue { id number url title body createdAt viewerDidAuthor
      author { login } editor { login } lastEditedAt
      timelineItems(itemTypes: [RENAMED_TITLE_EVENT], last: 1) {
        nodes { ... on RenamedTitleEvent { actor { login } } } }
      repository { nameWithOwner isPrivate }
      labels(first: 100) { nodes { name } }
      comments(last: 1) { nodes { createdAt } } } } } }'
# What counts as an item, shared by the refresh and --find (jq -s over the
# pages of one search).
# complete: a search that timed out partway, or hit GitHub's 1000-result
# cap, returns fewer nodes than it counts; a cut list would drop items
# silently, so it errors instead (search_complete then retries). Distinct issues are
# counted by node id (a rename or transfer mid-paging changes repo and number,
# never id): pages that overlap while results shift must not let a repeat
# stand in for a missing item.
# counted: only text the operator wrote counts: their issue, in a private
# repo, with the body last edited and the title last renamed by them (editor
# does not track renames). A null editor on an edited body is a deleted
# account, so it counts only when the body was never edited.
JQ_DEFS='
  def complete:
    if length == 0 or any(.[]; (.data.search.issueCount | type) != "number") then error("no result count")
    elif ([ .[].data.search.nodes[] | select(.number != null) | .id ] | unique | length)
       < ([ .[].data.search.issueCount ] | max // 0)
    then error("search truncated") else empty end;
  def counted:
    [ .[].data.search.nodes[] | select(.number != null and .viewerDidAuthor == true and .repository.isPrivate == true
      and (if .editor == null then .lastEditedAt == null else .editor.login == .author.login end)
      and (.author.login as $a | (.timelineItems.nodes // []) | all(.actor.login? == $a))) ] | unique_by(.id) | .[];
'
CACHE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/operator-queue"
# SHA-256 of the full host/owner/repo: a fixed-length name (any repo string
# fits NAME_MAX) that no two repos share in practice. A character-class
# substitution or an od dump is neither: od folds repeated rows into "*".
# Lowercased first: GitHub names are case-insensitive, so O/R and o/r are one
# repo and share one cache.
# No digest tool means no cache name; that is refused, never defaulted to a
# name every repo would share.
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi 2>/dev/null | cut -c1-64; }
# The owners are part of the key: a different search scope is a different
# cache. "v2" marks caches written under the author/private/editor filter, so a
# cache from before it is never rendered.
# author:@me makes the result depend on the gh identity, so the key also
# carries a digest of everything gh picks it from: the token variables and the
# hosts file naming the active account. Read locally, never through gh, so
# SessionStart still makes no call; a token refresh only costs one fetch.
GH_HOSTS_FILE="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
gh_ident() { { printf '%s\0' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}"
  cat "$GH_HOSTS_FILE" 2>/dev/null; } | sha256; }
IDENT="$(gh_ident)"
KEY="$(printf 'v2 %s%s @%s' "$ISSUE_REPO" "${OWNERS:+ +$OWNERS}" "$IDENT" | tr '[:upper:]' '[:lower:]' | sha256)"
case "$KEY" in *[!0-9a-f]*) KEY="" ;; esac
[ "${#KEY}" -eq 64 ] || KEY=""
CACHE="$CACHE_DIR/issues-$KEY.md"
FAILED="$CACHE.failed"   # exists = the latest refresh failed (a success removes it)
INFLIGHT="$CACHE.inflight"  # exists while a refresh runs; left behind if it dies
LOCK="$CACHE.lock"       # flock target; the file itself is never removed
CACHE_TTL=600
MAX_QUEUE_BYTES=65536
FETCH_TIMEOUT=120
# GitHub search may time out partway and still answer: REST flags it
# (incomplete_results), GraphQL only returns fewer nodes than issueCount. The
# one query over every owner came back short most of the time (#716), so each
# search is checked against its own count and retried after each wait below;
# only digits count, so the value can never become a sleep(1) argument.
RETRY_SLEEPS="$(printf '%s' "${OPERATOR_QUEUE_RETRY_SLEEPS-2 5}" | tr -s ' \t' '\n\n' | LC_ALL=C grep -xE '[0-9]{1,3}' | tr '\n' ' ')"
SOURCE="file"
CACHE_NOTE=""

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# refresh — page every open operator-action issue in scope through one
# GraphQL search
# (comments(last: 1) is the newest comment however many there are) and
# replace the cache with the rendered blocks; on any failure leave the cache
# alone and touch FAILED. added is the body's `- added:` line (migrated items
# keep their real age), else the creation date. verified is the newer of the
# body's `- verified:` date and the newest comment, so a re-verify comment
# bumps it but a label edit does not; only real calendar dates count. project
# is the body's full `- project:` value (a migrated "keen-media,
# operator-commons" item still matches either session), else a
# `project:<name>` label, else the issue's repo name; deadline and action come from the body's
# `- deadline:` / `- action:` lines (the action falls back to the first
# non-empty body line that is not a field).
refresh() {
  local raw tmp rc=1
  [ -n "$KEY" ] && [ "$REPO_OK" -eq 1 ] || return 1
  mkdir -p "$CACHE_DIR" || return 1
  # One refresh at a time, under flock(1): the kernel grants the lock
  # atomically and drops it when the holder exits, however it dies, so there
  # is no pid file to race and no stale lock to steal. A refresh that finds
  # the lock still held after five seconds returns: the running one started
  # earlier and writes the cache itself. Because refreshes never overlap, the
  # last write is always the newest fetch. No flock (stock macOS) counts as
  # a failed refresh, which the header reports, rather than an unserialised
  # one.
  command -v flock >/dev/null 2>&1 || { touch "$FAILED"; return 1; }
  exec 9>> "$LOCK" || { touch "$FAILED"; return 1; }
  flock -w 5 9 || { exec 9>&-; return 0; }
  # Fetch only while the cache is missing or older than CACHE_TTL, judged
  # under the lock (a queued refresh finds its predecessor's fresh cache and
  # stops). So whenever a fetch is under way, every reader already names the
  # cache as old, and a fresh cache is never one a fetch is replacing: no
  # window between taking the lock and marking INFLIGHT can make a reader
  # present a superseded cache as settled.
  local age
  if [ -f "$CACHE" ]; then
    age=$(( $(date +%s) - $(mtime "$CACHE") ))
    [ "$age" -le "$CACHE_TTL" ] && { exec 9>&-; return 0; }
  fi
  # Marked before the fetch and cleared only after FAILED is settled, so a
  # refresh killed at any point leaves INFLIGHT behind (see refresh_state).
  # An INFLIGHT already here is a killed predecessor's: record its failure
  # first, so readers keep reporting it while this fetch runs.
  # Its temporaries (this cache's own mktemp names, below) are stale too:
  # every fetch worker inherits fd 9, so while this refresh holds the lock no
  # other process can still be writing one.
  if [ -f "$INFLIGHT" ]; then
    touch "$FAILED"
    find "$CACHE_DIR" -maxdepth 1 -type f -user "$(id -u)" \
      \( -name "issues-$KEY.md.raw.??????" -o -name "issues-$KEY.md.new.??????" \) \
      -exec rm -f {} + 2>/dev/null
  fi
  touch "$INFLIGHT" || { touch "$FAILED"; exec 9>&-; return 1; }
  # A refresh shell that is signalled (TERM, INT, HUP) removes its own
  # temporaries on the way out; bash runs the trap once the foreground fetch
  # returns. Only SIGKILL skips it, and the recovery above covers that.
  # INFLIGHT stays: the outcome was never recorded.
  OQ_RAW="" OQ_TMP=""
  trap 'rm -f "${OQ_RAW:-}" "${OQ_TMP:-}"' EXIT
  trap 'exit 1' INT TERM HUP
  # gh and jq inherit fd 9, so the lock lives as long as any fetch worker
  # does: a refresh shell killed mid-fetch cannot free it while its gh still
  # runs. A hung gh would then hold it for good, so search_complete caps
  # each fetch (killed, and the refresh fails) at FETCH_TIMEOUT.
  raw="$(mktemp "$CACHE.raw.XXXXXX")" && OQ_RAW="$raw" &&
  tmp="$(mktemp "$CACHE.new.XXXXXX")" && OQ_TMP="$tmp" &&
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
  fetch_scopes "$raw" &&
  jq -rs --arg home "$(printf '%s' "$REPO_PATH" | tr '[:upper:]' '[:lower:]')" "$JQ_DEFS"'
    # A real calendar date: the shape alone would let 2026-99-99 outrank a valid comment.
    def isdate: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch "") == .);
    def field($k): [ .[] | select(startswith("- " + $k + ":")) | sub("^- " + $k + ":[ \t]*"; "") ][0] // "";
    "# Operator-action issues",
    ( counted
      | (.body // "" | gsub("\r"; "") | split("\n")) as $lines
      | ((.repository.nameWithOwner // "") | split("/") | .[-1]) as $repo
      # The home repo holds items for other repos, so its name names no project.
      | (((.repository.nameWithOwner // "") | ascii_downcase) == $home) as $in_home
      # Labels are not text the operator wrote: any collaborator can create and
      # apply one. Only a home-repo `project:<slug>` label counts, and only a
      # plain slug; elsewhere the repo name is the fallback.
      | (if $in_home
         then ([ .labels.nodes[].name | select(test("^project:[A-Za-z0-9._-]{1,40}$")) | sub("^project:"; "") ][0] // "")
         else $repo end) as $fallback
      | (($lines | field("project")) as $p | if $p != "" then $p else $fallback end) as $project
      | ($lines | field("deadline")) as $deadline
      | (($lines | field("added")) as $a | if $a != "" then $a else .createdAt[0:10] end) as $added
      | ([ ($lines | field("verified") | .[0:10]), (.comments.nodes[].createdAt[0:10]) ]
          | map(select(isdate)) | max // "") as $verified
      | (($lines | field("action")) as $a
          | if $a != "" then $a else ([ $lines[] | select(test("\\S") and (test("^- [a-z]+:") | not)) ][0] // "") end) as $action
      | "", "## \(.title) (\($repo)#\(.number))",
        "- added: \($added)",
        (if $verified != "" then "- verified: \($verified)" else empty end),
        (if $project != "" then "- project: \($project)" else empty end),
        (if $deadline != "" then "- deadline: \($deadline)" else empty end),
        "- action: \($action)" )' "$raw" > "$tmp" &&
  # The key names the identity read before the fetch; an account switched while
  # gh ran would file one account's items under another's key.
  [ "$(gh_ident)" = "$IDENT" ] &&
  chmod 600 "$tmp" && mv -f "$tmp" "$CACHE" && rc=0
  rm -f "${raw:-}" "${tmp:-}"
  # The inline refresh (OPERATOR_QUEUE_REFRESH_SYNC=1) returns to the hook,
  # which sets its own EXIT trap; leave it no stale one.
  trap - EXIT INT TERM HUP
  # INFLIGHT goes only once the outcome is recorded: if FAILED cannot be
  # written (disk or inodes full) the in-flight marker stays as the signal.
  if [ "$rc" -eq 0 ]; then rm -f "$FAILED" && rm -f "$INFLIGHT"
  else touch "$FAILED" && rm -f "$INFLIGHT"; fi
  exec 9>&-
  return "$rc"
}

# search_complete <q> — the pages of one search of <q>, on stdout, once a
# run comes back complete (every page carries its count and the distinct
# nodes add up to it); nothing and exit 1 when none does. Where timeout(1)
# exists each run is capped at FETCH_TIMEOUT.
search_complete() {
  local q="$1" s pages tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout -k 10 "$FETCH_TIMEOUT")
  for s in $RETRY_SLEEPS end; do
    if pages="$(${tmo[@]+"${tmo[@]}"} gh api graphql --hostname "$GH_HOSTNAME" --paginate \
         -f q="$q" -f query="$GQL" 2>/dev/null)" &&
       printf '%s' "$pages" | jq -es "$JQ_DEFS"'complete, true' > /dev/null 2>&1; then
      printf '%s\n' "$pages"; return 0
    fi
    [ "$s" = end ] || sleep "$s"
  done
  return 1
}

# fetch_scopes <file> — every scope's complete search appended to <file>;
# exit 1 at the first scope that stays incomplete (the cache is all or
# nothing: a missing scope would hide its items as done).
fetch_scopes() {
  local sc
  for sc in "${SCOPES[@]}"; do
    search_complete "$SEARCH_BASE $sc" >> "$1" || return 1
  done
}

# refresh_state — "failed" (the latest refresh failed), "inflight" (a
# refresh is running or was killed before it could record its outcome; the
# hook cannot tell which, and does not try) or "" (the cache is the latest
# outcome). INFLIGHT is read before FAILED and a refresh writes FAILED before
# it removes INFLIGHT, so a refresh settling between the two reads is seen
# either in flight or as failed, never as neither. No lock is taken.
refresh_state() {
  local inflight=""
  [ -f "$INFLIGHT" ] && inflight=inflight
  if [ -f "$FAILED" ]; then echo failed; else echo "$inflight"; fi
}

# --scope and --find are for the handoff skills, so they file items where this
# hook looks and never file one it already lists. Neither touches the cache.
# --scope prints where the search looks: `host <h>`, `home <owner/name>` and
# `owners <o>...` (empty = the home repo only).
# --find <slug> prints the URL of each open item titled exactly <slug> that
# this hook would list (titles compare case-insensitively), and exits 0 when the search was complete (no URL =
# no such item). Exit 2 = it could not tell: GitHub unreachable, gh or jq
# missing, the search still incomplete after retries, a bad slug or repo, or a live queue file
# (that file, not the issues, is the queue until it carries the banner).
find_item() {
  local slug="${1:-}" raw
  if ! [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; then
    echo "--find: the slug must be letters, digits, '.', '_' or '-'" >&2; return 2
  fi
  # No digest tool leaves IDENT empty, and the account-switch check below
  # would then compare two empty strings.
  [ -n "$KEY" ] || { echo "--find: no sha256sum or shasum, so an account switch cannot be detected" >&2; return 2; }
  [ -z "${OPERATOR_QUEUE_FILE:-}" ] || { echo "--find: OPERATOR_QUEUE_FILE is set, so that file is the queue" >&2; return 2; }
  [ "$REPO_OK" -eq 1 ] || { echo "--find: OPERATOR_QUEUE_REPO is not a plain [host/]owner/name" >&2; return 2; }
  if [ -f "$LEGACY" ] && ! head -n 5 "$LEGACY" | grep -q '^> \*\*Historical\*\*'; then
    echo "--find: $LEGACY is still the live queue; move its items into issues and add the historical banner first" >&2; return 2
  fi
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "--find: needs gh and jq" >&2; return 2; }
  # One query over every scope: narrowed to the title it is small, and
  # search_complete retries it if GitHub still cuts it short.
  raw="$(search_complete "$SEARCH_Q in:title \"$slug\"")" ||
    { echo "--find: the search failed or came back cut short after retries" >&2; return 2; }
  # author:@me depends on the gh account: one switched mid-search answered
  # for someone else (refresh() makes the same check before writing).
  [ "$(gh_ident)" = "$IDENT" ] || { echo "--find: the gh account changed mid-search" >&2; return 2; }
  printf '%s' "$raw" | jq -rs --arg slug "$slug" "$JQ_DEFS"'counted | select((.title | ascii_downcase) == ($slug | ascii_downcase)) | .url' ||
    { echo "--find: the search result was unreadable" >&2; return 2; }
}

# SessionStart runs the hook with no arguments; that alone renders the
# queue. Anything else must be exactly one mode with its argument count, so
# no mistyped, empty or extra argument can fall through to the rendered
# queue, which a caller could misread as an answer.
if [ "$#" -gt 0 ]; then
  case "$1:$#" in
    --refresh:1) refresh; exit ;;
    --scope:1)
      [ "$REPO_OK" -eq 1 ] || { echo "--scope: OPERATOR_QUEUE_REPO is not a plain [host/]owner/name" >&2; exit 2; }
      printf 'host %s\nhome %s\nowners %s\n' "$GH_HOSTNAME" "$REPO_PATH" "$OWNERS"; exit 0 ;;
    --find:2) find_item "$2"; exit ;;
    *) echo "usage: $0 [--refresh | --scope | --find SLUG] (got: $*)" >&2; exit 2 ;;
  esac
fi

# Source: the file queue is migrating to operator-action issues in the private
# ISSUE_REPO, which the phone and cloud sessions can read. A queue file that
# exists — even empty — stays authoritative until a line of its first five
# STARTS with the historical banner (an action merely mentioning the banner
# does not count), so no item goes dark mid-migration. OPERATOR_QUEUE_FILE
# (test fixtures) always wins.
if [ -n "${OPERATOR_QUEUE_FILE:-}" ]; then
  QUEUE="$OPERATOR_QUEUE_FILE"
elif [ -f "$LEGACY" ] && ! head -n 5 "$LEGACY" | grep -q '^> \*\*Historical\*\*'; then
  QUEUE="$LEGACY"
else
  SOURCE="issues"
  if [ "$REPO_OK" -ne 1 ]; then
    echo "Operator action queue: OPERATOR_QUEUE_REPO is not a plain [host/]owner/name, so the operator-action issues are not listed."
    exit 0
  fi
  if [ -z "$KEY" ]; then
    echo "Operator action queue: cannot name the operator-action cache for $SCOPE (no sha256sum or shasum) — \`$LIST_CMD\` lists them."
    exit 0
  fi
  QUEUE="$CACHE"
  now="$(date +%s)"
  # Presence decides, never an age: a refresh running alongside this hook
  # can stamp the cache or the failure marker after `now` was read, and a
  # negative age must not read as "no cache" or "no failure". Ages only
  # pick the wording, clamped at zero.
  age_of() { local a=$(( now - $(mtime "$1") )); [ "$a" -lt 0 ] && a=0; echo "$a"; }
  if [ ! -f "$CACHE" ] || [ "$(age_of "$CACHE")" -gt "$CACHE_TTL" ]; then
    if [ "${OPERATOR_QUEUE_REFRESH_SYNC:-}" = "never" ]; then
      :
    elif [ "${OPERATOR_QUEUE_REFRESH_SYNC:-}" = "1" ]; then
      refresh
    elif command -v setsid >/dev/null 2>&1; then
      setsid bash "$0" --refresh < /dev/null > /dev/null 2>&1 &
    else
      nohup bash "$0" --refresh < /dev/null > /dev/null 2>&1 &
    fi
    now="$(date +%s)"
  fi
  # Everything below reads one snapshot: a refresh replaces the cache by
  # rename, so this copy is one whole cache, and a replacement mid-render
  # cannot split the check from the output. The copy is bounded at one byte
  # over MAX_QUEUE_BYTES, so an oversized cache costs no more temp space or
  # time than a renderable one (the size guard below then refuses it). The
  # cache is opened once, on fd 8: the bytes and the mtime (taken through
  # /dev/fd/8 for the age) come from that one file even if a refresh renames
  # a new cache over it mid-copy. The state is read AFTER the copy: a
  # refresh writes the cache before it settles, so one that replaced the cache before the copy is still in
  # flight (or failed) when the state is read, and its content is never
  # shown as settled. One that settles after the copy only makes the copy
  # moments old.
  # Design limit (accepted, gate round 14): the output is the state as of
  # these reads. A refresh that STARTS after them is not reflected in this
  # session's output; no reader can foresee it, the copy shown is still the
  # latest settled cache, and the next session sees the new state.
  if ! SNAP="$(mktemp 2>/dev/null)"; then
    echo "Operator action queue: could not snapshot the operator-action cache for $SCOPE (no writable temp dir) — \`$LIST_CMD\` lists them."
    exit 0
  fi
  trap 'rm -f "$SNAP"' EXIT
  { head -c "$((MAX_QUEUE_BYTES + 1))" <&8 > "$SNAP" && touch -r /dev/fd/8 "$SNAP"; } 2>/dev/null 8< "$CACHE"
  copied=$?
  state="$(refresh_state)"
  # The clock is read after the copy and the state, so a refresh that
  # started before these reads judged the cache stale at a time no later
  # than this one, and this reader judges it stale too.
  now="$(date +%s)"
  if [ "$copied" -ne 0 ] && [ -f "$CACHE" ]; then
    echo "Operator action queue: could not snapshot the operator-action cache for $SCOPE (temp dir full or unreadable cache) — \`$LIST_CMD\` lists them."
    exit 0
  fi
  if [ "$copied" -ne 0 ]; then
    if [ "$state" = failed ]; then
      echo "Operator action queue: could not list operator-action issues in $SCOPE (offline, gh unauthenticated, or gh/jq/flock missing; or the gh account changed mid-fetch, or the search stayed incomplete after retries — timed out, or over 1000 matches) and no cache exists — \`$LIST_CMD\` lists them."
    else
      echo "Operator action queue: no cache of operator-action issues in $SCOPE yet — a refresh is running in the background (or was interrupted); \`$LIST_CMD\` lists them."
    fi
    exit 0
  fi
  QUEUE="$SNAP"
  cache_age="$(age_of "$SNAP")"
  # Refreshes are serialised and a success removes FAILED, so its existence
  # alone means the latest refresh failed: GitHub unreachable, or a tool
  # missing. A refresh in flight may yet fail, so the cache is named as
  # possibly superseded, never as current. An old cache without either is
  # simply being refreshed.
  if [ "$state" = failed ]; then
    CACHE_NOTE=" (cached $((cache_age / 60)) min ago; the last refresh failed — GitHub unreachable, gh unauthenticated, or gh/jq/flock missing; or the gh account changed mid-fetch, or the search stayed incomplete after retries — timed out, or over 1000 matches)"
  elif [ "$state" = inflight ]; then
    CACHE_NOTE=" (cached $((cache_age / 60)) min ago; a refresh is running or was interrupted)"
  elif [ "$cache_age" -gt "$CACHE_TTL" ]; then
    CACHE_NOTE=" (cached $((cache_age / 60)) min ago; refreshing in the background)"
  fi
  # An oversized (cut) snapshot is never read as empty; the size guard below
  # reports it.
  if [ "$(wc -c < "$SNAP")" -le "$MAX_QUEUE_BYTES" ] && ! grep -q '^## ' "$SNAP" 2>/dev/null; then
    # An empty answer is only "nothing open" when it is fresh.
    [ -n "$CACHE_NOTE" ] && echo "Operator action queue: no open operator-action issues in $SCOPE as of the last good fetch$CACHE_NOTE."
    exit 0
  fi
fi
[ -s "$QUEUE" ] || exit 0
if [ "$SOURCE" = issues ]; then
  QUEUE_SHOWN="operator-action issues in $SCOPE$CACHE_NOTE"
  FULL_REF="the issue"
elif [ "$QUEUE" = "$LEGACY" ]; then
  # shellcheck disable=SC2088 # a display string, deliberately unexpanded
  QUEUE_SHOWN="~/.claude/operator-queue.md"
  FULL_REF="the queue file"
else
  QUEUE_SHOWN="$QUEUE"
  FULL_REF="the queue file"
fi

MAX_ITEMS=20
MAX_ACTION_CHARS=600
MAX_LINE_CHARS=1000
STALE_DAYS=30
STALE_MARK="[stale — re-verify]"
SHOW_ALL=0
[ "${OPERATOR_QUEUE_SHOW_ALL:-}" = "1" ] && SHOW_ALL=1

# The issue snapshot is cut at MAX_QUEUE_BYTES + 1, so the size is named
# only as over the limit.
queue_bytes="$(wc -c < "$QUEUE")"
if [ "$queue_bytes" -gt "$MAX_QUEUE_BYTES" ]; then
  echo "Operator action queue: $QUEUE_SHOWN exceeds ${MAX_QUEUE_BYTES} bytes — not rendered."
  exit 0
fi

# Session project (see header). A bare repo or a submodule has no "<repo>/.git"
# common dir; those fall back to the toplevel basename.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
repo=""
if common="$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  case "$common" in
    */.git) repo="$(basename "$(dirname "$common")")" ;;
  esac
  if [ -z "$repo" ]; then
    top="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" && repo="$(basename "$top")"
  fi
fi
[ -n "$repo" ] || repo="$(basename "$project_dir")"

today="$(date +%Y-%m-%d)"

# Single awk pass: flatten each "## <slug>" block, compute age/deadline/stale
# flags (civil-date arithmetic, no per-item forks), and emit one record per item:
#   sortkey TAB full TAB project TAB age_days TAB next_deadline TAB line
# full=1 marks an item printed in full (session project, past due / due today,
# or show-all). Empty fields carry the "-" sentinel so no field is ever empty.
# Deadline items key "0|<deadline>" (soonest first), the rest "1|<added>"
# (oldest first). ISO dates sort lexically, so `sort` finishes the ordering.
records="$(OQ_REPO="$repo" LC_ALL=C awk -v today="$today" -v stale_days="$STALE_DAYS" -v stale_mark="$STALE_MARK" \
  -v show_all="$SHOW_ALL" -v full_ref="$FULL_REF" -v max_action="$MAX_ACTION_CHARS" -v max_line="$MAX_LINE_CHARS" '
  # days_from_civil — days since 1970-01-01 (Howard Hinnant era algorithm).
  function days_from_civil(y, m, d,    era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  # iso_days — day number of the ISO date that STARTS s; "" when there is
  # none. Prefix, not whole-line: handoffs annotate dates in place
  # ("added: 2026-07-13 (re-verified 2026-09-02)"), and the leading date is
  # still the date.
  function iso_days(s,    p, y, m, d, last_day) {
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
    split(substr(s, 1, 10), p, "-")
    y = p[1] + 0; m = p[2] + 0; d = p[3] + 0
    if (m < 1 || m > 12 || d < 1) return ""
    last_day = (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
    if (m == 2) last_day = 28 + (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))
    if (d > last_day) return ""
    return days_from_civil(y, m, d)
  }
  # utf8_trim — drop the incomplete UTF-8 sequence a byte cut left at the end
  # of s, if any; complete characters stay. Byte-wise under LC_ALL=C.
  function utf8_trim(s,    n, k, c, need) {
    n = length(s); k = 0
    while (k < 3 && k < n && substr(s, n - k, 1) ~ /[\200-\277]/) k++
    if (k == n) return s
    c = substr(s, n - k, 1)
    if (c ~ /[\300-\337]/)      need = 2
    else if (c ~ /[\340-\357]/) need = 3
    else if (c ~ /[\360-\367]/) need = 4
    else return s
    return (k + 1 < need) ? substr(s, 1, n - k - 1) : s
  }
  # project_matches — any word of the project value equals the session repo.
  function project_matches(p,    n, w, i) {
    if (repo == "") return 0
    n = split(tolower(p), w, /[^a-z0-9._-]+/)
    for (i = 1; i <= n; i++) if (w[i] == tolower(repo)) return 1
    return 0
  }
  function flush(    key, flag, age, detail, d, v, dd, fresh, is_stale, full, age_days, next_dl, line, group) {
    if (slug == "") return
    age = ""
    d = iso_days(added)
    v = iso_days(verified)
    dd = iso_days(deadline)
    if (added != "") age = (d != "") ? "added " (today_days - d) "d ago" : "added " added
    if (v != "") age = ((age != "") ? age ", " : "") "verified " (today_days - v) "d ago"
    # Freshness is the newest parseable date; none at all is stale by definition.
    fresh = (d != "" && (v == "" || d > v)) ? d : v
    is_stale = (fresh == "" || today_days - fresh > stale_days)
    if (deadline != "") {
      key = "0|" deadline
      if (deadline < today)       flag = "[PAST DUE " deadline "] "
      else if (deadline == today) flag = "[DUE TODAY] "
      else                        flag = "[due " deadline "] "
    } else {
      key = "1|" ((added != "") ? added : "9999-99-99")
      flag = ""
    }
    if (is_stale) flag = flag stale_mark " "
    if (action == "") action = "(no action line)"
    if (length(action) > max_action) {
      action = utf8_trim(substr(action, 1, max_action)) "… [truncated; full text in " full_ref "]"
    }
    detail = (project != "") ? "project: " project : ""
    if (age != "") detail = (detail != "") ? detail ", " age : age
    line = "  " flag slug " — " action ((detail != "") ? " (" detail ")" : "")
    # Backstop for the other fields (slug, project): no line exceeds the cap.
    if (length(line) > max_line) line = utf8_trim(substr(line, 1, max_line)) "… [truncated]"
    full = (show_all == 1 || project_matches(project) || (dd != "" && dd <= today_days)) ? 1 : 0
    age_days = (d != "") ? today_days - d : "-"
    next_dl = (dd != "" && dd >= today_days) ? substr(deadline, 1, 10) : "-"
    # Summary groups by the first word of the value ("dotfiles / Codex Remote" and
    # "dotfiles" are one project), so the summary stays one line per project.
    group = (match(project, /[A-Za-z0-9._-]+/)) ? substr(project, RSTART, (RLENGTH < 80) ? RLENGTH : 80) : "(no project)"
    print key "\t" full "\t" group "\t" age_days "\t" next_dl "\t" line
    slug = added = project = deadline = verified = action = ""
  }
  # Free-form strings via ENVIRON: awk -v would interpret backslash escapes.
  BEGIN { today_days = iso_days(today); repo = ENVIRON["OQ_REPO"] }
  # Tolerate CRLF queue files; a tab in any value would shift the TAB-separated
  # record columns (hiding the item), so tabs become spaces on input.
  { sub(/\r$/, ""); gsub(/\t/, " ") }
  /^## /                       { flush(); slug = substr($0, 4) }
  slug != "" && /^- added:/    { added = $0;    sub(/^- added:[ \t]*/, "", added) }
  slug != "" && /^- project:/  { project = $0;  sub(/^- project:[ \t]*/, "", project) }
  slug != "" && /^- deadline:/ { deadline = $0; sub(/^- deadline:[ \t]*/, "", deadline) }
  slug != "" && /^- verified:/ { verified = $0; sub(/^- verified:[ \t]*/, "", verified) }
  slug != "" && /^- action:/   { action = $0;   sub(/^- action:[ \t]*/, "", action) }
  END { flush() }
' "$QUEUE" | LC_ALL=C sort)"
parse_rc=$?
if [ "$parse_rc" -ne 0 ]; then
  echo "Operator action queue: could not parse $QUEUE_SHOWN (rc $parse_rc) — not rendered."
  exit 0
fi

[ -n "$records" ] || exit 0

total="$(printf '%s\n' "$records" | wc -l)"
stale="$(printf '%s\n' "$records" | grep -cF -- "$STALE_MARK")"
full_lines="$(printf '%s\n' "$records" | awk -F'\t' '$2 == 1' | cut -f6-)"
full_count=0
[ -n "$full_lines" ] && full_count="$(printf '%s\n' "$full_lines" | wc -l)"

echo "Operator action queue — $total open item(s), $stale stale (>${STALE_DAYS}d since added/verified) in $QUEUE_SHOWN:"
if [ "$SHOW_ALL" -ne 1 ]; then
  echo "Items for $repo, plus any past due or due today:"
  [ "$full_count" -gt 0 ] || echo "  (none for $repo)"
fi
if [ "$full_count" -gt 0 ]; then
  # Show-all is the explicit opt-out of the item cap; each line stays bounded.
  if [ "$SHOW_ALL" -eq 1 ]; then
    printf '%s\n' "$full_lines"
  else
    printf '%s\n' "$full_lines" | head -n "$MAX_ITEMS"
  fi
  if [ "$SHOW_ALL" -ne 1 ] && [ "$full_count" -gt "$MAX_ITEMS" ]; then
    echo "  …and $((full_count - MAX_ITEMS)) more — see $QUEUE_SHOWN"
  fi
fi
if [ "$SHOW_ALL" -ne 1 ] && [ "$full_count" -lt "$total" ]; then
  echo "Other projects (summary):"
  # One line per project: count, oldest added age, soonest upcoming deadline.
  printf '%s\n' "$records" | LC_ALL=C awk -F'\t' '
    $2 == 0 {
      p = $3; n[p]++
      if ($4 != "-" && (!(p in oldest) || $4 + 0 > oldest[p])) oldest[p] = $4 + 0
      if ($5 != "-" && (!(p in next_dl) || $5 < next_dl[p])) next_dl[p] = $5
    }
    END {
      for (p in n) {
        extra = (p in oldest) ? "oldest " oldest[p] "d" : ""
        if (p in next_dl) extra = ((extra != "") ? extra ", " : "") "next deadline " next_dl[p]
        print "  " p ": " n[p] " item" ((n[p] == 1) ? "" : "s") ((extra != "") ? " (" extra ")" : "")
      }
    }' | LC_ALL=C sort | OQ_SRC="$QUEUE_SHOWN" awk -v max="$MAX_ITEMS" '
      # The summary is bounded like the item list: many distinct projects must
      # not flood session context either.
      NR <= max { print; next }
      { extra++ }
      END { if (extra) print "  …and " extra " more projects — see " ENVIRON["OQ_SRC"] }'
  if [ "$SOURCE" = issues ]; then
    echo "Full queue: \`$LIST_CMD\`; a session started with OPERATOR_QUEUE_SHOW_ALL=1 renders every item."
  else
    echo "Full queue: $QUEUE_SHOWN; a session started with OPERATOR_QUEUE_SHOW_ALL=1 renders every item."
  fi
fi
# Status only (#652): what the items are and where their dates come from.
# How a session acts on an item is the handoff skill's rule, not this hook's.
if [ "$SOURCE" = issues ]; then
  echo "Each item is an action only the operator can take; its verified date is the newer of the issue body's \`verified:\` line and its newest comment."
else
  echo "Each item is an action only the operator can take; its verified date is its \`verified:\` line."
fi
exit 0
