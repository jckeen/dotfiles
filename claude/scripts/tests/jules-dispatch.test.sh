#!/usr/bin/env bash
# jules-dispatch.test.sh — pin the dispatcher's credential handling, its
# idempotency ledger, and the no-writes contract of --dry-run.
#
# Nothing here reaches the network: a fake `curl` earlier on PATH answers
# GET /sources and POST /sessions, and records its own argv so the suite can
# prove the API key never becomes a process argument. Every run gets a throwaway
# state dir, key file, and routine catalog.
#
# Also covers claude/systemd/install.sh, which this branch generalised from one
# hardcoded unit pair into a loop: a stubbed systemctl proves both timers still
# install and that git-hygiene's behaviour is unchanged.
#
# Run directly; exit 1 on any failure.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DISPATCH="$REPO_ROOT/claude/scripts/jules-dispatch.sh"

pass=0
failed=0
ok()   { pass=$((pass + 1));     echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A key that is long enough and inside the allowed charset, so every refusal
# below is attributable to the property under test and not to the key itself.
GOOD_KEY="AIzaSyTESTKEYtestkeyTESTKEY0123456789"

# ── Fake curl ────────────────────────────────────────────────────────
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# Fake curl. Records argv, then answers from the fixture files. Consumes stdin
# (the real script pipes its auth header there via -K -), so the writer never
# takes SIGPIPE and pipefail cannot misreport a hit as a miss.
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
url=""; method="GET"; prev=""
for a in "$@"; do
  case "$a" in https://*) url="$a" ;; esac
  [[ "$prev" == "-X" ]] && method="$a"
  prev="$a"
done
cat >/dev/null
if [[ -n "${FAKE_CURL_FAIL:-}" ]]; then exit 22; fi
case "$method:$url" in
  GET:*/sources*)
    # A second fixture file, when present, is served as page 2 — the first is
    # then expected to carry a nextPageToken.
    if [[ -n "${FAKE_SOURCES_P2:-}" && "$url" == *"pageToken="* ]]; then
      cat "$FAKE_SOURCES_P2"
    else
      cat "$FAKE_SOURCES"
    fi ;;
  POST:*/sessions)
    n=$(( $(cat "$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$FAKE_SEQ"
    printf '{"name":"sessions/s%s","id":"s%s","url":"https://jules.google.com/task/s%s"}\n' "$n" "$n" "$n" ;;
  *)
    printf 'fake curl: unexpected %s %s\n' "$method" "$url" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"
export FAKE_CURL_ARGV="$WORK/curl-argv.log"
export FAKE_SEQ="$WORK/curl-seq"
export FAKE_SOURCES="$WORK/sources.json"

cat > "$FAKE_SOURCES" <<'SRC'
{"sources":[
  {"name":"sources/github/jckeen/dotfiles","id":"github/jckeen/dotfiles",
   "githubRepo":{"owner":"jckeen","repo":"dotfiles"}},
  {"name":"sources/github/jckeen/atlas","id":"github/jckeen/atlas",
   "githubRepo":{"owner":"jckeen","repo":"atlas"}}
]}
SRC

# ── Fixture helpers ──────────────────────────────────────────────────
# Each case gets its own state dir, key file, and catalog, so nothing leaks
# between assertions.
CASE=0
new_case() {
  CASE=$((CASE + 1))
  CASE_DIR="$WORK/case$CASE"
  STATE="$CASE_DIR/state"
  KEY="$CASE_DIR/api-key"
  ROUTINES="$CASE_DIR/routines"
  mkdir -p "$STATE" "$ROUTINES"
  printf '%s\n' "$GOOD_KEY" > "$KEY"
  chmod 600 "$KEY"
  : > "$FAKE_CURL_ARGV"
  rm -f "$FAKE_SEQ"
}

routine() { # name paused repos-block [schedule]
  local name="$1" paused="$2" repos="$3" sched="${4:-daily}"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'schedule: %s\n' "$sched"
    printf '%s\n' "$repos"
    printf 'max_prs_per_run: 1\n'
    printf 'max_files: 2\n'
    printf 'label: jules-routine:%s\n' "$name"
    printf 'acceptance: The test command passes.\n'
    printf 'paused: %s\n' "$paused"
    printf -- '---\n\n'
    printf 'Do the %s work.\n' "$name"
  } > "$ROUTINES/$name.md"
}

dispatch() { # extra flags...
  JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
    JULES_DAILY_CAP="${CAP:-40}" "$DISPATCH" "$@" > "$CASE_DIR/out" 2>&1
}

outgrep() { grep -Fq -- "$1" "$CASE_DIR/out"; }

# Full-fidelity snapshot: every path, every file hash, every symlink target.
snapshot() {
  ( cd "$1" || exit 1
    find . -mindepth 1 | sort
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
    find . -type l -print0 | sort -z | while IFS= read -r -d '' l; do
      printf 'link %s -> %s\n' "$l" "$(readlink "$l")"
    done )
}

echo "── credential handling ──"

# The key file's mode is the whole guard: a group-readable key on a shared box
# is already disclosed, so the dispatcher must refuse rather than use it.
new_case
routine alpha false 'repos: all'
chmod 640 "$KEY"
if ! dispatch && outgrep "must be mode 0600"; then
  ok "a key file at mode 0640 is refused, naming the required mode"
else
  fail "a 0640 key file was not refused (exit/message wrong)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
rm -f "$KEY"
if ! dispatch && outgrep "API key file not found"; then
  ok "a missing key file is refused"
else
  fail "a missing key file was not refused"
fi

new_case
routine alpha false 'repos: all'
: > "$KEY"; chmod 600 "$KEY"
if ! dispatch && outgrep "is empty"; then
  ok "an empty key file is refused"
else
  fail "an empty key file was not refused"
fi

new_case
routine alpha false 'repos: all'
printf 'short\n' > "$KEY"; chmod 600 "$KEY"
if ! dispatch && outgrep "shorter than 20 characters"; then
  ok "a key shorter than 20 characters is refused"
else
  fail "a short key was not refused"
fi

# A symlinked key file means the mode check landed on the link's target while
# something else could repoint it: refuse the indirection outright.
new_case
routine alpha false 'repos: all'
printf '%s\n' "$GOOD_KEY" > "$CASE_DIR/real-key"; chmod 600 "$CASE_DIR/real-key"
rm -f "$KEY"; ln -s "$CASE_DIR/real-key" "$KEY"
if ! dispatch && outgrep "must not be a symlink"; then
  ok "a symlinked key file is refused"
else
  fail "a symlinked key file was not refused"
fi

# The point of `curl -K -`: the key reaches curl on stdin, so it is absent from
# argv (readable by any process on the box) and from everything on disk.
new_case
routine alpha false 'repos: all'
if dispatch; then
  leaked=""
  grep -Fq -- "$GOOD_KEY" "$FAKE_CURL_ARGV" && leaked="$leaked argv"
  while IFS= read -r f; do
    grep -Fq -- "$GOOD_KEY" "$f" && leaked="$leaked $f"
  done < <(find "$STATE" -type f)
  grep -Fq -- "$GOOD_KEY" "$CASE_DIR/out" && leaked="$leaked stdout"
  # Negative control: the grep must be able to find the key somewhere, or the
  # three assertions above would pass vacuously.
  if ! grep -Fq -- "$GOOD_KEY" "$KEY"; then
    fail "leak check is vacuous — the key is not even in the key file"
  elif [[ -z "$leaked" ]]; then
    ok "the API key appears in no argv, no state file, and no log line"
  else
    fail "the API key leaked into:$leaked"
  fi
else
  fail "a well-formed run did not exit 0"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

echo "── dispatch behaviour ──"

new_case
routine alpha false 'repos: all'
if dispatch && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]]; then
  ok "repos: all fans out to every repository GET /sources returned"
else
  fail "repos: all did not dispatch once per source"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Re-running the same day must create nothing: the timer has Persistent=true, so
# a missed run catching up alongside the scheduled one is the normal case.
new_case
routine alpha false 'repos: all'
dispatch
before_n="$(grep -c . "$STATE/dispatch.jsonl")"
dispatch
after_n="$(grep -c . "$STATE/dispatch.jsonl")"
if [[ "$before_n" -eq 2 && "$after_n" -eq 2 ]] && outgrep "already dispatched today"; then
  ok "a second run the same day creates no new session and says why"
else
  fail "same-day idempotency broken (ledger $before_n -> $after_n)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The cap is the spend guard against a catalog that grows faster than anyone
# notices. One repo of two gets through at cap 1.
new_case
routine alpha false 'repos: all'
CAP=1 dispatch
if [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 1 ]] && outgrep "daily cap 1 reached"; then
  ok "the daily cap stops dispatching and names the cap"
else
  fail "the daily cap did not hold"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
CAP=0 dispatch
if [[ ! -f "$STATE/dispatch.jsonl" ]] && outgrep "daily cap 0 reached"; then
  ok "a cap of 0 dispatches nothing"
else
  fail "a cap of 0 still dispatched"
fi

# A repo named in a routine but not connected in Jules is a configuration gap,
# not an error: report it and carry on with the rest of the catalog.
new_case
routine alpha false 'repos:
  - jckeen/not-connected'
routine beta false 'repos:
  - jckeen/dotfiles'
if dispatch \
  && outgrep "jckeen/not-connected — not in GET /sources" \
  && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 1 ]]; then
  ok "a repository absent from GET /sources is skipped with a message"
else
  fail "an unconnected repository was not skipped cleanly"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha true 'repos: all'
routine beta false 'repos: all'
if dispatch && outgrep "alpha — paused: true" \
  && [[ "$(grep -c '"routine":"alpha"' "$STATE/dispatch.jsonl")" -eq 0 ]] \
  && [[ "$(grep -c '"routine":"beta"' "$STATE/dispatch.jsonl")" -eq 2 ]]; then
  ok "paused: true skips that routine and leaves the others running"
else
  fail "a paused routine was not skipped"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
if dispatch --repo jckeen/atlas \
  && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 1 ]] \
  && grep -Fq '"repo":"jckeen/atlas"' "$STATE/dispatch.jsonl"; then
  ok "--repo narrows the run to one repository"
else
  fail "--repo did not narrow the run"
fi

new_case
routine alpha false 'repos: all'
if ! dispatch --routine nosuch && outgrep "no routine matched"; then
  ok "--routine naming nothing is an error, not a silent empty run"
else
  fail "--routine with no match looked like a successful run"
fi

new_case
routine alpha false 'repos: all'
if ! FAKE_CURL_FAIL=1 dispatch && outgrep "GET /sources failed"; then
  ok "a failing GET /sources aborts the run"
else
  fail "a failing GET /sources did not abort"
fi

new_case
routine alpha false 'repos: all'
if dispatch && [[ -f "$STATE/status.json" ]] \
  && [[ "$(jq -r '.created_this_run' "$STATE/status.json")" == "2" ]] \
  && [[ "$(jq -r '.daily_cap' "$STATE/status.json")" == "40" ]] \
  && [[ "$(jq -r '[.events[] | select(.kind == "created")] | length' "$STATE/status.json")" == "2" ]]; then
  ok "status.json records the run with per-repository events"
else
  fail "status.json is missing or wrong"
  cat "$STATE/status.json" 2>/dev/null | sed 's/^/      | /'
fi

echo "── --dry-run writes nothing ──"

# The state dir is pre-populated, so "unchanged" is a real assertion rather
# than "the directory still does not exist".
new_case
routine alpha false 'repos: all'
routine beta false 'repos: all'
printf '{"dispatched_at":"2026-09-01T00:00:00Z","date":"2026-09-01","routine":"alpha","repo":"jckeen/dotfiles","source":"sources/github/jckeen/dotfiles","session":"sessions/old","url":""}\n' \
  > "$STATE/dispatch.jsonl"
printf 'pre-existing log line\n' > "$STATE/dispatch.log"
printf '{"checked_at":"2026-09-01T00:00:00Z"}\n' > "$STATE/status.json"
before="$(snapshot "$STATE")"
dispatch --dry-run
rc=$?
after="$(snapshot "$STATE")"
if [[ "$rc" -eq 0 && "$before" == "$after" ]]; then
  ok "--dry-run leaves the state dir byte-identical"
else
  fail "--dry-run mutated the state dir (rc=$rc)"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
fi
if grep -Fq 'would dispatch' "$CASE_DIR/out" && ! grep -Fq '"method":"POST"' "$FAKE_CURL_ARGV" \
   && ! grep -Fq '/sessions' "$FAKE_CURL_ARGV"; then
  ok "--dry-run reports what it would do and never calls POST /sessions"
else
  fail "--dry-run either reported nothing or created a session"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

new_case
routine alpha false 'repos: all'
rm -rf "$STATE"
if dispatch --dry-run && [[ ! -e "$STATE" ]]; then
  ok "--dry-run does not create the state dir when it is absent"
else
  fail "--dry-run created the state dir"
fi

echo "── frontmatter parsing fails closed ──"

bad_case() { # label body-of-file expected-message
  new_case
  printf '%s' "$2" > "$ROUTINES/alpha.md"
  if ! dispatch && outgrep "$3"; then
    ok "$1"
  else
    fail "$1 (exit or message wrong)"
    sed 's/^/      | /' "$CASE_DIR/out"
  fi
}

VALID='---
name: alpha
schedule: daily
repos: all
max_prs_per_run: 1
max_files: 2
label: jules-routine:alpha
acceptance: The test command passes.
paused: false
---

Do the alpha work.
'

bad_case "an unknown frontmatter key is rejected" \
  "${VALID/paused: false/paused: false
budget: unlimited}" "unknown frontmatter key 'budget'"

bad_case "a missing required key is rejected" \
  "${VALID/max_files: 2
/}" "missing required key 'max_files'"

bad_case "a label that does not match the name is rejected" \
  "${VALID/label: jules-routine:alpha/label: jules-routine:other}" \
  "label must be 'jules-routine:alpha'"

bad_case "a non-integer max_files is rejected" \
  "${VALID/max_files: 2/max_files: lots}" "max_files must be a positive integer"

bad_case "a non-boolean paused is rejected" \
  "${VALID/paused: false/paused: maybe}" "paused must be 'true' or 'false'"

bad_case "an unrecognised schedule is rejected" \
  "${VALID/schedule: daily/schedule: hourly}" "schedule must be 'daily' or 'weekly'"

bad_case "a malformed repos entry is rejected" \
  "${VALID/repos: all/repos: not-a-repo}" "repos entry must be 'all' or OWNER/NAME"

bad_case "an unclosed frontmatter fence is rejected" \
  "${VALID/---

Do the alpha work.
/}" "frontmatter fence is never closed"

bad_case "a file that does not open with a fence is rejected" \
  "# alpha
$VALID" "must open with a '---' frontmatter fence"

bad_case "an empty prompt body is rejected" \
  "${VALID/Do the alpha work.
/}" "prompt body is empty"

# A name that disagrees with its filename would make the label, the ledger key,
# and the PR label disagree with the catalog file people edit.
new_case
printf '%s' "${VALID/name: alpha/name: beta}" > "$ROUTINES/alpha.md"
if ! dispatch && outgrep "does not match the filename"; then
  ok "a name that disagrees with the filename is rejected"
else
  fail "a name/filename mismatch was accepted"
fi

# One rejected routine must not silently reduce the run to the rest of the
# catalog: the others still dispatch, and the exit code is non-zero.
new_case
printf 'name: broken\n' > "$ROUTINES/broken.md"
routine beta false 'repos: all'
if ! dispatch \
  && outgrep "broken.md — frontmatter rejected; not dispatched" \
  && [[ "$(grep -c '"routine":"beta"' "$STATE/dispatch.jsonl")" -eq 2 ]] \
  && [[ "$(jq -r '.failures' "$STATE/status.json")" == "1" ]]; then
  ok "a rejected routine fails the run while the valid ones still dispatch"
else
  fail "a rejected routine did not fail closed"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

echo "── the shipped catalog ──"

# Every routine this repo ships must satisfy the parser it is dispatched by —
# otherwise the first timer firing is the thing that discovers a typo.
new_case
rm -rf "$ROUTINES"
if JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
   JULES_ROUTINE_DIR="$REPO_ROOT/agents/routines" \
   "$DISPATCH" --dry-run > "$CASE_DIR/out" 2>&1; then
  ok "every routine in agents/routines/ parses and resolves"
else
  fail "the shipped routine catalog does not parse"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

shipped=$(find "$REPO_ROOT/agents/routines" -name '*.md' | wc -l)
if [[ "$shipped" -gt 0 ]]; then
  ok "the catalog is non-empty ($shipped routine file(s))"
else
  fail "agents/routines/ holds no routine files"
fi

echo "── review findings from the Codex gate ──"

# [high] schedule was parsed, validated, and then never consulted: a weekly
# routine ran every day under the daily timer. Six days ago is inside the
# window, eight days ago is outside it.
ledger_line() { # routine repo days-ago
  local at
  at="$(date -u -d "@$(( $(date -u +%s) - $3 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - $3 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"dispatched_at":"%s","date":"%s","routine":"%s","repo":"%s","source":"s","session":"old","url":""}\n' \
    "$at" "${at%%T*}" "$1" "$2"
}

new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
ledger_line weeklyone jckeen/dotfiles 6 > "$STATE/dispatch.jsonl"
if dispatch \
  && outgrep "schedule: weekly, dispatched inside the last 7 day(s); skipped" \
  && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 1 ]]; then
  ok "a weekly routine dispatched six days ago is skipped, not run again"
else
  fail "a weekly routine ran inside its cadence window"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
ledger_line weeklyone jckeen/dotfiles 8 > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]]; then
  ok "a weekly routine dispatched eight days ago runs again"
else
  fail "a weekly routine past its window did not run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A daily routine must be unaffected by the cadence check: six days ago is far
# outside its window, so the only thing stopping it is the same-day check.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
ledger_line alpha jckeen/dotfiles 6 > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]]; then
  ok "a daily routine is not held back by the weekly cadence check"
else
  fail "the cadence check leaked into daily routines"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# [medium] curl reads $CURLRC / ~/.curlrc unless -q is the FIRST argument; a
# `location` or `trace` line there would leak the key past every other guard.
new_case
routine alpha false 'repos: all'
dispatch
if [[ "$(head -1 "$FAKE_CURL_ARGV" | cut -d' ' -f1)" == "-q" ]]; then
  ok "curl is invoked with -q first, so it reads no default configuration"
else
  fail "curl did not receive -q as its first argument"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

# The end-to-end version of the same guarantee: a hostile ~/.curlrc must not
# change what the dispatcher sends.
new_case
routine alpha false 'repos: all'
printf 'location\ntrace = %s/curl-trace.txt\n' "$CASE_DIR" > "$CASE_DIR/curlrc"
if CURL_HOME="$CASE_DIR" CURLRC="$CASE_DIR/curlrc" dispatch \
  && [[ ! -e "$CASE_DIR/curl-trace.txt" ]] \
  && ! grep -Fq -- "$GOOD_KEY" "$FAKE_CURL_ARGV"; then
  ok "a CURLRC enabling redirects and tracing changes nothing"
else
  fail "a hostile CURLRC affected the request"
fi

# [medium] a manual run overlapping the timer read the same spend and dispatched
# the same routine twice. The lock is a directory, so mkdir is the whole test.
new_case
routine alpha false 'repos: all'
mkdir -p "$STATE/dispatch.lock"
if dispatch && outgrep "another dispatch already holds" \
  && [[ ! -f "$STATE/dispatch.jsonl" ]]; then
  ok "a held lock makes the run a clean no-op rather than a double dispatch"
else
  fail "a held lock did not stop the run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
if dispatch && [[ ! -e "$STATE/dispatch.lock" ]]; then
  ok "the lock is released when the run finishes"
else
  fail "the lock outlived the run"
fi

# An abandoned lock (a killed run, a reboot mid-dispatch) must not disable the
# timer forever.
new_case
routine alpha false 'repos: all'
mkdir -p "$STATE/dispatch.lock"
if JULES_LOCK_STALE_SECONDS=0 JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
     JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" > "$CASE_DIR/out" 2>&1 \
   && outgrep "reclaiming a stale dispatch lock" \
   && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]]; then
  ok "a stale lock is reclaimed loudly and the run proceeds"
else
  fail "a stale lock was not reclaimed"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A dry run must not create the lock either — the state dir has to stay
# byte-identical, and a lock directory in it is a mutation.
new_case
routine alpha false 'repos: all'
before="$(snapshot "$STATE")"
dispatch --dry-run
if [[ "$before" == "$(snapshot "$STATE")" ]] && [[ ! -e "$STATE/dispatch.lock" ]]; then
  ok "--dry-run takes no lock and still writes nothing"
else
  fail "--dry-run created a lock"
fi

# [medium] the session exists by the time the ledger is appended, so a failed
# append is an UNRECORDED dispatch, not a failed one. errexit is off inside
# dispatch_one (it is called with `|| true`), so the append must be checked.
new_case
routine alpha false 'repos: all'
printf '' > "$STATE/dispatch.jsonl"
chmod 400 "$STATE/dispatch.jsonl"
if ! dispatch \
  && outgrep "COULD NOT record it in" \
  && [[ "$(jq -r '.failures' "$STATE/status.json")" -ge 1 ]] \
  && [[ "$(jq -r '.created_this_run' "$STATE/status.json")" == "0" ]]; then
  ok "an unwritable ledger fails the run instead of reporting a dispatch"
else
  fail "a failed ledger append passed as a successful dispatch"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
chmod 600 "$STATE/dispatch.jsonl" 2>/dev/null || true

echo "── second review round ──"

# [medium] GET /sources is paginated (pageSize defaults to 30). A single request
# dropped every repository past the first page and reported them as unconnected,
# which reads exactly like a configuration problem.
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/sources-p1.json" <<'P1'
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles"}}],
 "nextPageToken":"tok-page-2"}
P1
cat > "$CASE_DIR/sources-p2.json" <<'P2'
{"sources":[{"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas"}}]}
P2
if FAKE_SOURCES="$CASE_DIR/sources-p1.json" FAKE_SOURCES_P2="$CASE_DIR/sources-p2.json" dispatch \
  && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]] \
  && grep -Fq '"repo":"jckeen/atlas"' "$STATE/dispatch.jsonl" \
  && outgrep "sources: 2 over 2 page(s)"; then
  ok "a second page of GET /sources is followed and its repositories dispatched"
else
  fail "pagination was not followed"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

if grep -Fq -- 'pageSize=100' "$FAKE_CURL_ARGV" \
   && grep -Fq -- 'pageToken=tok-page-2' "$FAKE_CURL_ARGV"; then
  ok "the source listing asks for the maximum page size and passes the token back"
else
  fail "pageSize/pageToken were not sent"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

# A token is interpolated into a URL, so it is validated first.
new_case
routine alpha false 'repos: all'
printf '{"sources":[],"nextPageToken":"bad token; rm -rf /"}\n' > "$CASE_DIR/p1.json"
if ! FAKE_SOURCES="$CASE_DIR/p1.json" FAKE_SOURCES_P2="$CASE_DIR/p1.json" dispatch \
  && outgrep "nextPageToken outside"; then
  ok "a nextPageToken outside the safe charset is refused"
else
  fail "a hostile nextPageToken was interpolated into a URL"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# [medium] the stale-lock reclaim is a read-check-replace sequence and is not
# atomic on its own: two runs could both see the stale lock, and the loser would
# delete the winner's fresh one. The reclaim now runs under its own lock, so a
# held reclaim lock must stop a second run from reclaiming at all.
# The main lock is aged past the window while the reclaim lock is fresh — the
# state a losing process sees when the winner is mid-reclaim. It must stand down
# rather than delete the lock the winner just created.
new_case
routine alpha false 'repos: all'
mkdir -p "$STATE/dispatch.lock" "$STATE/dispatch.lock.reclaim"
touch -d '1970-01-02' "$STATE/dispatch.lock" 2>/dev/null \
  || touch -t 197001020000 "$STATE/dispatch.lock"
if dispatch \
   && outgrep "another dispatch already holds" \
   && [[ ! -f "$STATE/dispatch.jsonl" ]] \
   && [[ -d "$STATE/dispatch.lock" ]]; then
  ok "a held reclaim lock stops a stale lock being reclaimed twice"
else
  fail "the reclaim critical section is not exclusive"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# An abandoned reclaim lock must not wedge reclamation forever either.
new_case
routine alpha false 'repos: all'
mkdir -p "$STATE/dispatch.lock" "$STATE/dispatch.lock.reclaim"
touch -d '1970-01-02' "$STATE/dispatch.lock" "$STATE/dispatch.lock.reclaim" 2>/dev/null \
  || touch -t 197001020000 "$STATE/dispatch.lock" "$STATE/dispatch.lock.reclaim"
if dispatch && outgrep "reclaiming a stale dispatch lock" \
  && [[ "$(grep -c . "$STATE/dispatch.jsonl")" -eq 2 ]] \
  && [[ ! -e "$STATE/dispatch.lock.reclaim" ]]; then
  ok "an abandoned reclaim lock is itself reclaimed and then released"
else
  fail "an abandoned reclaim lock wedged the run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# [medium] returning from a failed ledger append left the loop dispatching: with
# an unwritable ledger every eligible pair created an unrecorded session, and the
# next run repeated all of them. The run must stop at the first failure.
new_case
routine alpha false 'repos: all'
: > "$STATE/dispatch.jsonl"
chmod 400 "$STATE/dispatch.jsonl"
if ! dispatch && outgrep "ABORTED: ledger unwritable" \
  && [[ "$(grep -c '/sessions' "$FAKE_CURL_ARGV")" -eq 1 ]]; then
  ok "an unwritable ledger aborts the run after one session, not after every pair"
else
  fail "an unwritable ledger kept creating unrecorded sessions"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
chmod 600 "$STATE/dispatch.jsonl" 2>/dev/null || true

echo "── --report ──"

# gh is stubbed, so the assertion is on the bucketing and the arithmetic, not on
# GitHub. Two PRs in the last week (one merged, one closed) and one nine days
# back must land in separate week buckets with separate rates.
GHBIN="$WORK/ghbin"
mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
case "$1" in
  "issue")
    cat > "$GH_COMMENT_BODY"
    exit 0 ;;
esac
now=$(date -u +%s)
recent=$(iso $((now - 2 * 86400)))
older=$(iso $((now - 9 * 86400)))
printf '[{"state":"MERGED","createdAt":"%s","mergedAt":"%s"},{"state":"CLOSED","createdAt":"%s","mergedAt":null},{"state":"OPEN","createdAt":"%s","mergedAt":null}]\n' \
  "$recent" "$recent" "$recent" "$older"
GHSTUB
chmod +x "$GHBIN/gh"

new_case
routine alpha false 'repos: all'
printf '{"dispatched_at":"2026-09-17T00:00:00Z","date":"2026-09-17","routine":"alpha","repo":"jckeen/dotfiles","source":"s","session":"x","url":""}\n' \
  > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && outgrep "| alpha | 1 | 2 | 1 | 1 | 50% |" \
   && outgrep "| alpha | 2 | 1 | 0 | 0 | 0% |"; then
  ok "--report buckets PRs by week and computes a merge rate per bucket"
else
  fail "--report table is wrong"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# repos: all in a report means the repos actually dispatched to, read from the
# ledger — so --report needs no API key and no network.
if grep -Fq -- '--repo jckeen/dotfiles' "$GH_ARGV" \
   && grep -Fq -- '--search label:jules-routine:alpha' "$GH_ARGV"; then
  ok "--report queries the ledger's repositories by the routine's label"
else
  fail "--report queried the wrong repository or label"
  sed 's/^/      | /' "$GH_ARGV"
fi

# The report path must not reach the API at all: it needs no key, so it can run
# on a machine that has never had one. The fake curl records every invocation,
# and the run above passed no JULES_API_KEY_FILE.
if [[ ! -s "$FAKE_CURL_ARGV" ]]; then
  ok "--report calls no API endpoint and needs no key"
else
  fail "--report called the API"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     JULES_TRACKER="jckeen/dotfiles#446" \
     "$DISPATCH" --report --days 14 --post > "$CASE_DIR/out" 2>&1 \
   && grep -Fq -- 'issue comment 446 --repo jckeen/dotfiles' "$GH_ARGV" \
   && grep -Fq '| alpha |' "$GH_COMMENT_BODY"; then
  ok "--post comments the table on the tracker issue"
else
  fail "--post did not comment the table"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if ! PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
       JULES_TRACKER="not-a-tracker" \
       "$DISPATCH" --report --post > "$CASE_DIR/out" 2>&1 \
   && outgrep "JULES_TRACKER must be OWNER/NAME#ISSUE"; then
  ok "a malformed tracker reference is refused before posting"
else
  fail "a malformed tracker reference was not refused"
fi

new_case
routine alpha false 'repos: all'
if ! dispatch --post && outgrep "--post only applies to --report"; then
  ok "--post outside --report is an error"
else
  fail "--post outside --report was accepted"
fi

# --dry-run has to mean "writes nothing" in every mode; a GitHub comment is a
# remote write, and this combination used to make one.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --post --dry-run > "$CASE_DIR/out" 2>&1 \
   && outgrep "[DRY] would comment the table above on" \
   && ! grep -Fq -- 'issue comment' "$GH_ARGV" \
   && [[ ! -e "$CASE_DIR/gh-comment" ]]; then
  ok "--dry-run --report --post prints the table and posts nothing"
else
  fail "--dry-run still commented on the tracker issue"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
unset GH_ARGV GH_COMMENT_BODY

echo "── systemd installer (generalised unit loop) ──"

# install.sh grew from one hardcoded pair to a table, and the script it validates
# is now read out of the unit's own ExecStart — the path systemd will actually
# run. The units point at $HOME/dev/dotfiles, so each fixture home links that at
# a checkout of its own choosing.
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN"
cat > "$SYSBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"is-enabled"*) exit 0 ;;
  *"list-timers"*) printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\n' ;;
esac
exit 0
STUB
cat > "$SYSBIN/loginctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$SYSBIN/sudo" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$SYSBIN/systemctl" "$SYSBIN/loginctl" "$SYSBIN/sudo"

# sys_home <name> <checkout to link at dev/dotfiles>
sys_home() {
  local h="$WORK/$1"
  rm -rf "$h"
  mkdir -p "$h/dev"
  ln -s "$2" "$h/dev/dotfiles"
  printf '%s' "$h"
}

run_installer() { # <home> <installer's repo> <log>
  PATH="$SYSBIN:$PATH" HOME="$1" SYSTEMCTL_LOG="$3" \
    bash "$2/claude/systemd/install.sh" > "$WORK/install.out" 2>&1
}

SYSHOME="$(sys_home syshome "$REPO_ROOT")"
: > "$WORK/systemctl.log"
if run_installer "$SYSHOME" "$REPO_ROOT" "$WORK/systemctl.log"; then
  missing=""
  for u in git-hygiene.service git-hygiene.timer jules-dispatch.service jules-dispatch.timer; do
    [[ -f "$SYSHOME/.config/systemd/user/$u" ]] || missing="$missing $u"
  done
  for d in .local/state/hygiene .local/state/jules; do
    [[ -d "$SYSHOME/$d" ]] || missing="$missing $d"
  done
  if [[ -z "$missing" ]]; then
    ok "install.sh installs both unit pairs and both state dirs"
  else
    fail "install.sh left these missing:$missing"
  fi
  if grep -Fq 'enable --now git-hygiene.timer' "$WORK/systemctl.log" \
     && grep -Fq 'enable --now jules-dispatch.timer' "$WORK/systemctl.log"; then
    ok "install.sh enables both timers"
  else
    fail "install.sh did not enable both timers"
    sed 's/^/      | /' "$WORK/systemctl.log"
  fi
else
  fail "install.sh exited non-zero with both scripts reachable"
  sed 's/^/      | /' "$WORK/install.out"
fi

# The script a unit runs must be checked at the path the unit names, not at a
# path derived from wherever the installer happens to live: otherwise the
# installer reports success while enabling a service whose script is missing.
PARTIAL="$WORK/partial-checkout"
mkdir -p "$PARTIAL/claude/scripts" "$PARTIAL/claude/systemd"
cp "$REPO_ROOT/claude/scripts/hygiene-cron.sh" "$PARTIAL/claude/scripts/"
chmod +x "$PARTIAL/claude/scripts/hygiene-cron.sh"
SYSHOME2="$(sys_home syshome2 "$PARTIAL")"
if ! run_installer "$SYSHOME2" "$REPO_ROOT" "$WORK/systemctl2.log" \
   && grep -Fq 'jules-dispatch.service runs' "$WORK/install.out" \
   && grep -Fq "$SYSHOME2/dev/dotfiles/claude/scripts/jules-dispatch.sh" "$WORK/install.out" \
   && [[ ! -f "$SYSHOME2/.config/systemd/user/jules-dispatch.timer" ]]; then
  ok "a unit whose ExecStart target is missing is named and fails the install"
else
  fail "a missing ExecStart target did not fail the install"
  sed 's/^/      | /' "$WORK/install.out"
fi

# A present-but-not-executable script is the core.fileMode regression: the old
# `[ -x ]` guard skipped silently, which is how a timer gets enabled with nothing
# to run.
NOEXEC="$WORK/noexec-checkout"
mkdir -p "$NOEXEC/claude/scripts"
cp "$REPO_ROOT/claude/scripts/hygiene-cron.sh" "$NOEXEC/claude/scripts/"
cp "$REPO_ROOT/claude/scripts/jules-dispatch.sh" "$NOEXEC/claude/scripts/"
chmod +x "$NOEXEC/claude/scripts/hygiene-cron.sh"
chmod 644 "$NOEXEC/claude/scripts/jules-dispatch.sh"
SYSHOME3="$(sys_home syshome3 "$NOEXEC")"
if ! run_installer "$SYSHOME3" "$REPO_ROOT" "$WORK/systemctl3.log" \
   && grep -Fq 'missing or not executable' "$WORK/install.out"; then
  ok "a non-executable ExecStart target fails the install rather than skipping quietly"
else
  fail "a non-executable script did not fail the install"
  sed 's/^/      | /' "$WORK/install.out"
fi

# Installing from a checkout other than the one the units point at is legal but
# must be said out loud.
SYSHOME4="$(sys_home syshome4 "$REPO_ROOT")"
if run_installer "$SYSHOME4" "$REPO_ROOT" "$WORK/systemctl4.log" \
   && grep -Fq 'OUTSIDE this checkout' "$WORK/install.out"; then
  ok "a unit pointing outside the installer's checkout is warned about"
else
  fail "installing units that run another checkout was silent"
  sed 's/^/      | /' "$WORK/install.out"
fi

echo
echo "── $pass passed, $failed failed ──"
[[ "$failed" -eq 0 ]] || exit 1
