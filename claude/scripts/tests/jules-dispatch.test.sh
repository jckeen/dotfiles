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

# Checked, because errexit is off in this suite: an empty WORK would make BIN
# "/bin" two lines below, and the suite would then try to overwrite the installed
# /bin/curl with its stub. Observed during review.
WORK="$(mktemp -d)" || { echo "FAIL - mktemp -d failed; cannot run"; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "FAIL - mktemp -d produced no directory"; exit 1; }
trap '[[ -n "${WORK:-}" ]] && rm -rf "$WORK"' EXIT

# Ordinary dispatch cases must not depend on the wall clock, in either of the two
# ways they otherwise would. The margin guard refuses to start a dispatch inside
# the last two minutes of the UTC day; and even with the margin at zero, a test
# invocation spanning UTC midnight would make the run stop mid-catalog, because the
# dispatcher captures the date once and halts when it changes. So the clock is
# pinned as well. Without both, this suite — and the CI job running it — would fail
# on a schedule. The cases that exercise either guard set their own values.
export JULES_DAY_EDGE_MARGIN=0
# Noon UTC on a fixed date: far from any boundary, and stable across runs.
export JULES_NOW_EPOCH=1789041600

# Long enough and inside the allowed charset, so every refusal below is
# attributable to the property under test rather than to the key itself. It is
# deliberately NOT shaped like a real Google API key: the earlier fixture began
# with the usual prefix and gitleaks' generic-api-key rule blocked the push, which
# is the scanner doing its job. A fixture only has to satisfy the dispatcher's own
# rules — regular file, mode 0600, non-empty, at least 20 characters, charset
# [A-Za-z0-9._~+/=-] — and looking like a credential is no part of that.
GOOD_KEY="not-a-real-credential-fixture-0123456789"

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
if [[ -n "${FAKE_CURL_FAIL_POST:-}" && "$method" == "POST" ]]; then exit 28; fi
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
cp "$BIN/curl" "$WORK/curl.default"
# Several cases install a specialised curl; they call this to put the default one
# back so a later case is never silently running on someone else's stub.
restore_fake_curl() { cp "$WORK/curl.default" "$BIN/curl"; chmod +x "$BIN/curl"; }
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

# A dispatch writes two ledger lines (write-ahead "attempted", then "created"),
# so counts are over records. Lines seeded by ledger_below carry no status and
# stand for a completed past dispatch, which is why the default is "created".
# Guard on the file rather than falling back on jq's exit status: jq 1.7 with -s
# on a missing file BOTH prints a result for the empty slurp and exits non-zero,
# so a `|| printf 0` fallback appends a second value and every numeric comparison
# using it becomes a syntax error.
ledger_jq() {
  [[ -s "$STATE/dispatch.jsonl" ]] || { printf '0'; return 0; }
  jq -s "$@" "$STATE/dispatch.jsonl"
}
created_count() { ledger_jq '[.[] | select((.status // "created") == "created")] | length'; }
created_routine() {
  ledger_jq --arg r "$1" '[.[] | select(.routine == $r and ((.status // "created") == "created"))] | length'
}
created_repo() {
  ledger_jq --arg p "$1" '[.[] | select(.repo == $p and ((.status // "created") == "created"))] | length'
}
attempted_count() { ledger_jq '[.[] | select((.status // "") == "attempted")] | length'; }

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

# An inherited export of the same variable name would keep its export attribute
# through the script's own assignment, putting the key in the environment of
# every child process — where /proc/PID/environ exposes it. The fake curl dumps
# its environment so the assertion is on what a child actually received.
new_case
routine alpha false 'repos: all'
cat > "$BIN/curl" <<'ENVFAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
env >> "$FAKE_CURL_ENV"
url=""; method="GET"; prev=""
for a in "$@"; do
  case "$a" in https://*) url="$a" ;; esac
  [[ "$prev" == "-X" ]] && method="$a"
  prev="$a"
done
cat >/dev/null
case "$method:$url" in
  GET:*/sources*) cat "$FAKE_SOURCES" ;;
  POST:*/sessions)
    n=$(( $(cat "$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$FAKE_SEQ"
    printf '{"name":"sessions/s%s","id":"s%s","url":"u"}\n' "$n" "$n" ;;
  *) exit 1 ;;
esac
ENVFAKE
chmod +x "$BIN/curl"
export FAKE_CURL_ENV="$CASE_DIR/curl-env"
: > "$FAKE_CURL_ENV"
if API_KEY=some-inherited-value JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
     JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" > "$CASE_DIR/out" 2>&1 \
   && [[ -s "$FAKE_CURL_ENV" ]] \
   && ! grep -Fq -- "$GOOD_KEY" "$FAKE_CURL_ENV"; then
  ok "the key is absent from a child process's environment, even when API_KEY was exported in"
else
  fail "the key reached a child process environment"
  grep -F 'API_KEY' "$FAKE_CURL_ENV" | sed 's/^/      | /'
fi
unset FAKE_CURL_ENV
restore_fake_curl

# The clock seam has to actually reach the ledger, or pinning it proves nothing.
new_case
routine alpha false 'repos: all'
if dispatch \
  && [[ "$(ledger_jq -r '.[0].date')" == "2026-09-10" ]] \
  && [[ "$(ledger_jq -r '.[0].dispatched_at')" == "2026-09-10T12:00:00Z" ]]; then
  ok "the pinned clock is what the ledger records, so the suite has no wall-clock dependency"
else
  fail "the clock seam did not reach the ledger"
  sed 's/^/      | /' "$STATE/dispatch.jsonl"
fi

echo "── dispatch behaviour ──"

new_case
routine alpha false 'repos: all'
if dispatch && [[ "$(created_count)" -eq 2 ]]; then
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
before_n="$(created_count)"
dispatch
after_n="$(created_count)"
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
if [[ "$(created_count)" -eq 1 ]] && outgrep "daily cap 1 reached"; then
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
  && [[ "$(created_count)" -eq 1 ]]; then
  ok "a repository absent from GET /sources is skipped with a message"
else
  fail "an unconnected repository was not skipped cleanly"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha true 'repos: all'
routine beta false 'repos: all'
if dispatch && outgrep "alpha — paused: true" \
  && [[ "$(created_routine alpha)" -eq 0 ]] \
  && [[ "$(created_routine beta)" -eq 2 ]]; then
  ok "paused: true skips that routine and leaves the others running"
else
  fail "a paused routine was not skipped"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
if dispatch --repo jckeen/atlas \
  && [[ "$(created_count)" -eq 1 ]] \
  && [[ "$(created_repo jckeen/atlas)" -ge 1 ]]; then
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
  && [[ "$(created_routine beta)" -eq 2 ]] \
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
# Relative to the SAME pinned clock the dispatcher uses, or "days ago" would be
# measured from a different now than the eligibility window is.
ledger_line() { # routine repo days-ago
  local e at
  e=$((JULES_NOW_EPOCH - $3 * 86400))
  at="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"dispatched_at":"%s","date":"%s","routine":"%s","repo":"%s","source":"s","session":"old","url":""}\n' \
    "$at" "${at%%T*}" "$1" "$2"
}

new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
ledger_line weeklyone jckeen/dotfiles 6 > "$STATE/dispatch.jsonl"
if dispatch \
  && outgrep "schedule: weekly, dispatched inside the last 7 day(s); skipped" \
  && [[ "$(created_count)" -eq 1 ]]; then
  ok "a weekly routine dispatched six days ago is skipped, not run again"
else
  fail "a weekly routine ran inside its cadence window"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
ledger_line weeklyone jckeen/dotfiles 8 > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(created_count)" -eq 2 ]]; then
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
if dispatch && [[ "$(created_count)" -eq 2 ]]; then
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

# What the -q guarantee rests on, stated precisely. A fake curl cannot prove that
# the REAL curl ignores a configuration file — only curl can do that — so this
# does not pretend to: it pins the two things that are actually checkable here,
# which are that -q leads the argument list and that -L is never passed. An
# earlier version of this case set a hostile CURLRC and asserted "nothing
# changed", which a stub curl makes true no matter what the dispatcher does.
new_case
routine alpha false 'repos: all'
dispatch
argv="$(cat "$FAKE_CURL_ARGV")"
if [[ "${argv%% *}" == "-q" ]] \
  && ! grep -Eq -- '(^| )(-L|--location)( |$)' "$FAKE_CURL_ARGV" \
  && grep -Fq -- '--proto =https' "$FAKE_CURL_ARGV"; then
  ok "every request leads with -q, passes --proto =https, and never passes -L"
else
  fail "the curl invocation lost one of its transport guarantees"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

# [medium] a manual run overlapping the timer read the same spend and dispatched
# the same routine twice. Serialization is an flock, so the test takes a real one.
new_case
routine alpha false 'repos: all'
: > "$STATE/dispatch.lock"
( flock -x 9 && printf 'held\n' > "$CASE_DIR/held" && sleep 30 ) 9>"$STATE/dispatch.lock" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$CASE_DIR/held" ]] && break; sleep 0.2; done
if [[ -f "$CASE_DIR/held" ]] && dispatch \
  && outgrep "another dispatch already holds" \
  && [[ ! -f "$STATE/dispatch.jsonl" ]]; then
  ok "a held flock makes the run a clean no-op rather than a double dispatch"
else
  fail "a held flock did not stop the run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# The kernel drops the flock when the process exits, so there is no stale lock to
# reclaim — the property that made two rounds of mkdir-based reclamation
# unnecessary. After a normal run the lock must be immediately takeable.
new_case
routine alpha false 'repos: all'
if dispatch && flock -n "$STATE/dispatch.lock" -c true; then
  ok "the flock is released when the run exits, so nothing has to reclaim it"
else
  fail "the lock outlived the run"
fi

# A killed run must not wedge the timer either: SIGKILL releases an flock the
# same way a clean exit does.
new_case
routine alpha false 'repos: all'
: > "$STATE/dispatch.lock"
( flock -x 9 && printf 'held\n' > "$CASE_DIR/held" && sleep 30 ) 9>"$STATE/dispatch.lock" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$CASE_DIR/held" ]] && break; sleep 0.2; done
kill -9 "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
if dispatch && [[ "$(created_count)" -eq 2 ]]; then
  ok "a SIGKILLed holder leaves no stale lock behind"
else
  fail "a killed holder wedged the next run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Where flock is unavailable the run must still be serialized: a warning is not a
# guarantee, and two concurrent runs would read the same ledger and both
# dispatch. The fallback is an atomic mkdir, with no staleness logic — reclaiming
# is the race the flock was adopted to avoid.
noflock() {
  JULES_FLOCK=jules-no-such-flock-binary JULES_API_KEY_FILE="$KEY" \
    JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" JULES_DAILY_CAP="${CAP:-40}" \
    "$DISPATCH" > "$CASE_DIR/out" 2>&1
}

new_case
routine alpha false 'repos: all'
if noflock \
   && outgrep "serialized with a lock directory instead" \
   && [[ "$(jq -r '.serialized' "$STATE/status.json")" == "true" ]] \
   && [[ "$(created_count)" -eq 2 ]] \
   && [[ ! -e "$STATE/dispatch.lock.d" ]]; then
  ok "without flock the run serializes on a lock directory and releases it"
else
  fail "the flock fallback did not serialize"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A held fallback directory must stop a second run, exactly as the flock does.
new_case
routine alpha false 'repos: all'
mkdir -p "$STATE/dispatch.lock.d"
if noflock && outgrep "another dispatch already holds" \
   && [[ "$(created_count)" -eq 0 ]] \
   && [[ -d "$STATE/dispatch.lock.d" ]]; then
  ok "a held fallback lock directory stops the run and is not stolen"
else
  fail "the fallback lock did not exclude a second run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
if dispatch && [[ "$(jq -r '.serialized' "$STATE/status.json")" == "true" ]]; then
  ok "status.json records that a normal run held the lock"
else
  fail "status.json did not record the lock"
fi

# A dry run must not take the lock either — the state dir has to stay
# byte-identical, and a lock file in it is a mutation.
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
  && outgrep "refusing to create a session" \
  && [[ "$(jq -r '.failures' "$STATE/status.json")" -ge 1 ]] \
  && [[ "$(jq -r '.created_this_run' "$STATE/status.json")" == "0" ]]; then
  ok "an unwritable ledger refuses to create a session at all"
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
  && [[ "$(created_count)" -eq 2 ]] \
  && [[ "$(created_repo jckeen/atlas)" -ge 1 ]] \
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

# A page token is opaque and base64 tokens contain '+', '/' and '=', so it is
# percent-encoded rather than restricted to an alphabet — an allowlist would abort
# discovery on a perfectly valid token.
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/p1.json" <<'B64'
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles"}}],
 "nextPageToken":"a+b/c=d"}
B64
cat > "$CASE_DIR/p2.json" <<'B64P2'
{"sources":[{"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas"}}]}
B64P2
if FAKE_SOURCES="$CASE_DIR/p1.json" FAKE_SOURCES_P2="$CASE_DIR/p2.json" dispatch \
  && grep -Fq -- 'pageToken=a%2Bb%2Fc%3Dd' "$FAKE_CURL_ARGV" \
  && [[ "$(created_count)" -eq 2 ]]; then
  ok "a base64 page token is percent-encoded and pagination continues"
else
  fail "a token containing + or / broke pagination"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

# Encoding also neutralises a token that would otherwise break out of the query
# string, so no allowlist is needed for safety either.
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/p1.json" <<'HOSTILE'
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles"}}],
 "nextPageToken":"x&pageSize=1 y"}
HOSTILE
cat > "$CASE_DIR/p2.json" <<'HOSTILEP2'
{"sources":[]}
HOSTILEP2
if FAKE_SOURCES="$CASE_DIR/p1.json" FAKE_SOURCES_P2="$CASE_DIR/p2.json" dispatch \
  && grep -Fq -- 'pageToken=x%26pageSize%3D1%20y' "$FAKE_CURL_ARGV"; then
  ok "a token carrying query-string syntax is encoded, not injected"
else
  fail "a token was interpolated into the URL unencoded"
  sed 's/^/      | /' "$FAKE_CURL_ARGV"
fi

new_case
routine alpha false 'repos: all'
big="$(printf 't%.0s' $(seq 1 5000))"
printf '{"sources":[],"nextPageToken":"%s"}\n' "$big" > "$CASE_DIR/p1.json"
if ! FAKE_SOURCES="$CASE_DIR/p1.json" FAKE_SOURCES_P2="$CASE_DIR/p1.json" dispatch \
  && outgrep "longer than 4096 characters"; then
  ok "an implausibly long page token is refused"
else
  fail "an unbounded page token was accepted"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# [medium] with more eligible pairs than the cap allows, a fixed alphabetical
# order starved the tail permanently: the first routines would eat the whole
# budget every day and the last ones would never run once. Candidates are now
# ordered by how long it has been since that pair last ran.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
routine zeta false 'repos:
  - jckeen/dotfiles'
# alpha ran yesterday; zeta has never run. Alphabetically alpha wins, so fairness
# ordering is the only thing that can pick zeta.
ledger_line alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
if CAP=1 dispatch \
  && [[ "$(created_routine zeta)" -ge 1 ]] \
  && [[ "$(created_routine alpha)" -eq 1 ]] \
  && outgrep "alpha / jckeen/dotfiles — daily cap 1 reached; deferred to a later day"; then
  ok "the never-dispatched routine wins the last slot, and the other is deferred"
else
  fail "the cap starved the never-dispatched routine"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

if [[ "$(jq -r '.deferred_to_a_later_day' "$STATE/status.json")" == "1" ]] \
   && [[ "$(jq -r '[.events[] | select(.kind == "deferred")] | length' "$STATE/status.json")" == "1" ]]; then
  ok "status.json counts the work the cap pushed to a later day"
else
  fail "deferred work is not reported"
  sed 's/^/      | /' "$STATE/status.json"
fi

# Among pairs that have never run, the order has to be deterministic.
new_case
routine alpha false 'repos: all'
if CAP=1 dispatch && [[ "$(created_repo jckeen/atlas)" -ge 1 ]]; then
  ok "never-dispatched pairs break ties deterministically by routine then repository"
else
  fail "tie-breaking is not deterministic"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The oldest pair goes first when several have run before.
new_case
routine alpha false 'repos: all'
{ ledger_line alpha jckeen/atlas 3; ledger_line alpha jckeen/dotfiles 9; } > "$STATE/dispatch.jsonl"
CAP=1 dispatch
if [[ "$(created_repo jckeen/dotfiles)" -eq 2 ]] \
  && [[ "$(created_repo jckeen/atlas)" -eq 1 ]]; then
  ok "the least-recently-dispatched repository takes the slot"
else
  fail "ordering ignored the last-dispatch time"
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
  && [[ "$(grep -c '/sessions' "$FAKE_CURL_ARGV")" -eq 0 ]]; then
  ok "an unwritable ledger aborts before any session is created, not after each pair"
else
  fail "an unwritable ledger kept creating unrecorded sessions"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
chmod 600 "$STATE/dispatch.jsonl" 2>/dev/null || true

echo "── fourth review round ──"

# [medium] a POST can create a session remotely and then time out, and a process
# killed between the POST and the ledger append looks the same. Without a
# write-ahead record the pair vanished from the ledger entirely: the next run
# dispatched it again and the original session never counted against the cap.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
if FAKE_CURL_FAIL_POST=1 dispatch; then
  fail "a failed POST did not fail the run"
else
  if outgrep "outcome UNKNOWN" \
    && [[ "$(attempted_count)" -eq 1 ]] && [[ "$(created_count)" -eq 0 ]]; then
    ok "a POST whose outcome is unknown leaves an attempted record, not nothing"
  else
    fail "an ambiguous POST left no ledger trace"
    sed 's/^/      | /' "$CASE_DIR/out"
  fi
fi

# That record must make the pair count as dispatched, so the next run does not
# create a second session for work that may already be running.
if dispatch && outgrep "already dispatched today" && [[ "$(created_count)" -eq 0 ]]; then
  ok "an unresolved attempt is not retried the same day"
else
  fail "an unresolved attempt was dispatched again"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

if outgrep "recorded as attempted with no confirmed"; then
  ok "the run reports unresolved attempts for reconciliation"
else
  fail "unresolved attempts are invisible"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A completed dispatch pairs its two records under one attempt id, so the cap
# counts it once rather than twice.
new_case
routine alpha false 'repos: all'
dispatch
if [[ "$(created_count)" -eq 2 ]] && [[ "$(attempted_count)" -eq 2 ]] \
  && [[ "$(jq -r '.dispatched_today' "$STATE/status.json")" == "2" ]]; then
  ok "the two records of one dispatch count as one unit of spend"
else
  fail "the write-ahead record double-counted the spend"
  sed 's/^/      | /' "$STATE/status.json"
fi

# [medium] a repeated repository passed every eligibility check before the first
# session was created, so both copies dispatched.
new_case
printf '%s' "${VALID/repos: all/repos:
  - jckeen/dotfiles
  - jckeen/dotfiles}" > "$ROUTINES/alpha.md"
if ! dispatch && outgrep "lists 'jckeen/dotfiles' more than once"; then
  ok "a repository listed twice is rejected"
else
  fail "a duplicate repository entry was accepted"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Case variants resolve to the same source but were two different ledger keys.
new_case
printf '%s' "${VALID/repos: all/repos:
  - jckeen/dotfiles
  - jckeen/DotFiles}" > "$ROUTINES/alpha.md"
if ! dispatch && outgrep "more than once (comparison ignores case)"; then
  ok "a case variant of the same repository is rejected"
else
  fail "a case variant was treated as a second repository"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# And a single mixed-case entry still resolves and records one canonical spelling.
new_case
printf '%s' "${VALID/repos: all/repos:
  - JCKeen/DotFiles}" > "$ROUTINES/alpha.md"
if dispatch && [[ "$(created_repo jckeen/dotfiles)" -eq 1 ]]; then
  ok "a mixed-case entry resolves and is recorded in one canonical spelling"
else
  fail "a mixed-case entry did not resolve"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

echo "── fifth review round ──"

# [medium] bash reads "08" as octal inside [[ -ge ]], the test errors, and an
# errored test is a false one — so the cap stopped applying entirely.
new_case
routine alpha false 'repos: all'
if ! CAP=08 dispatch && outgrep "no leading zeros"; then
  ok "a cap with a leading zero is refused instead of silently disabling the cap"
else
  fail "a leading-zero cap was accepted"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
if CAP=08 dispatch; then
  fail "a leading-zero cap still dispatched"
elif [[ "$(created_count)" -eq 0 ]]; then
  ok "a refused cap creates nothing at all"
else
  fail "a refused cap still created sessions"
fi

# The same class in the frontmatter, which also reaches an arithmetic comparison.
bad_case "a max_files with a leading zero is rejected" \
  "${VALID/max_files: 2/max_files: 08}" "no leading zeros"

new_case
routine alpha false 'repos: all'
if ! JULES_REPORT_LIMIT=0 JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
       "$DISPATCH" --report > "$CASE_DIR/out" 2>&1 \
   && outgrep "JULES_REPORT_LIMIT must be a positive integer"; then
  ok "a zero report limit is refused"
else
  fail "a zero report limit was accepted"
fi

echo "── eighth review round ──"

# [medium] the day check ran before the POST, but a request can take up to the
# request timeout — so one started just before midnight could create its session
# on the next day while both ledger records carried this one, and the next run
# would dispatch the pair again without that session counting against the new
# day's cap. A margin of a whole day makes every moment "too close", which is the
# guard under test.
new_case
routine alpha false 'repos: all'
if JULES_DAY_EDGE_MARGIN=86400 JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
     JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" > "$CASE_DIR/out" 2>&1 \
   && outgrep "of the UTC day remain and a request may take up to" \
   && [[ "$(created_count)" -eq 0 ]] \
   && [[ "$(grep -c '/sessions' "$FAKE_CURL_ARGV")" -eq 0 ]] \
   && [[ "$(jq -r '.deferred_to_a_later_day' "$STATE/status.json")" -ge 1 ]]; then
  ok "a dispatch too close to the UTC day boundary is deferred, not started"
else
  fail "a dispatch was started with no room to finish inside the day"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The margin must not stop an ordinary run, or the guard would simply disable the
# lane. Zero is the explicit "no margin" setting, and it is also what the suite
# exports, so every other dispatch case is independent of the wall clock.
new_case
routine alpha false 'repos: all'
if JULES_DAY_EDGE_MARGIN=0 JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
     JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" > "$CASE_DIR/out" 2>&1 \
   && [[ "$(created_count)" -eq 2 ]]; then
  ok "a margin of zero dispatches normally"
else
  fail "the day-edge guard blocked an ordinary run"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# No case here asserts the DEFAULT margin: at an ordinary time of day a default of
# 120 and a default of 0 both dispatch, so any such test would pass whatever the
# default is. The two cases above bracket the behaviour instead — a whole-day
# margin defers, a zero margin dispatches — and the guard's own message pins the
# request timeout the default is derived from.

new_case
routine alpha false 'repos: all'
if ! JULES_DAY_EDGE_MARGIN=060 JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" \
       JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" > "$CASE_DIR/out" 2>&1 \
   && outgrep "JULES_DAY_EDGE_MARGIN must be a non-negative integer"; then
  ok "a leading-zero margin is refused like every other arithmetic input"
else
  fail "a leading-zero margin was accepted"
fi

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
now() { printf '%s' "${JULES_NOW_EPOCH:-$(date -u +%s)}"; }
case "$1" in
  "issue")
    cat > "$GH_COMMENT_BODY"
    exit 0 ;;
esac
if [[ -n "${GH_FAIL_LIST:-}" && "$1" == "pr" ]]; then exit 1; fi
now=$(now)
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

# [medium] the fetch bound is applied before the date window, so a busy routine
# reported partial counts — and the retirement rule is decided on these numbers.
# The stub returns three PRs, so a bound of three is a hit.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     JULES_REPORT_LIMIT=3 "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && outgrep "These counts are incomplete." \
   && outgrep "jckeen/dotfiles (jules-routine:alpha)"; then
  ok "a report that hit its fetch bound says the counts are incomplete"
else
  fail "a truncated report looked authoritative"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && ! outgrep "These counts are incomplete."; then
  ok "a report inside its bound carries no truncation warning"
else
  fail "an untruncated report warned anyway"
  sed 's/^/      | /' "$CASE_DIR/out"
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

echo "── sixth review round ──"

# [medium] a failed query incremented FAILURES and skipped the repository, but the
# posted table carried no note — and a non-zero exit code afterwards is no help to
# someone reading the comment. A routine could be retired on counts that silently
# omit a repository.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if ! PATH="$GHBIN:$PATH" GH_FAIL_LIST=1 JULES_STATE_DIR="$STATE" \
       JULES_ROUTINE_DIR="$ROUTINES" "$DISPATCH" --report --days 14 \
       > "$CASE_DIR/out" 2>&1 \
   && outgrep "query FAILED, so these contribute nothing above: jckeen/dotfiles (jules-routine:alpha)"; then
  ok "a failed pull request query caveats the report instead of only the exit code"
else
  fail "a failed query produced a table that looked complete"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The caveat has to reach the posted comment, which is what people actually read.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
PATH="$GHBIN:$PATH" GH_FAIL_LIST=1 JULES_STATE_DIR="$STATE" \
  JULES_ROUTINE_DIR="$ROUTINES" JULES_TRACKER="jckeen/dotfiles#446" \
  "$DISPATCH" --report --days 14 --post > "$CASE_DIR/out" 2>&1 || true
if [[ -f "$CASE_DIR/gh-comment" ]] && grep -Fq 'query FAILED' "$CASE_DIR/gh-comment" \
   && grep -Fq 'These counts are incomplete.' "$CASE_DIR/gh-comment"; then
  ok "the posted comment carries the failure caveat"
else
  fail "the posted comment omitted the failure caveat"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
unset GH_ARGV GH_COMMENT_BODY

# [medium] phase two rereads the catalog file, so it must recheck paused: an
# operator pausing a routine while earlier requests are in flight expects the
# queued ones to stop too.
new_case
routine alpha false 'repos: all'
cat > "$BIN/curl" <<PAUSEFAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_CURL_ARGV"
url=""; method="GET"; prev=""
for a in "\$@"; do
  case "\$a" in https://*) url="\$a" ;; esac
  [[ "\$prev" == "-X" ]] && method="\$a"
  prev="\$a"
done
cat >/dev/null
case "\$method:\$url" in
  GET:*/sources*) cat "\$FAKE_SOURCES" ;;
  POST:*/sessions)
    # Pause the routine mid-run, the moment the first session is created.
    sed -i 's/^paused: false/paused: true/' "$ROUTINES/alpha.md"
    n=\$(( \$(cat "\$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$FAKE_SEQ"
    printf '{"name":"sessions/s%s","id":"s%s","url":"u"}\n' "\$n" "\$n" ;;
  *) exit 1 ;;
esac
PAUSEFAKE
chmod +x "$BIN/curl"
if dispatch && outgrep "paused between phases; skipped" \
  && [[ "$(created_count)" -eq 1 ]]; then
  ok "a routine paused mid-run stops dispatching its queued repositories"
else
  fail "a routine paused mid-run kept dispatching"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

echo "── seventh review round ──"

# [medium] phase two rechecked paused but nothing else, so an operator removing a
# repository from a routine mid-run still had it dispatched. The fake curl edits
# the catalog the moment the first session is created.
mutating_curl() { # sed-expression applied to the routine on the first POST
  cat > "$BIN/curl" <<MUTFAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_CURL_ARGV"
url=""; method="GET"; prev=""
for a in "\$@"; do
  case "\$a" in https://*) url="\$a" ;; esac
  [[ "\$prev" == "-X" ]] && method="\$a"
  prev="\$a"
done
cat >/dev/null
case "\$method:\$url" in
  GET:*/sources*) cat "\$FAKE_SOURCES" ;;
  POST:*/sessions)
    sed -i '$1' "$ROUTINES/alpha.md"
    n=\$(( \$(cat "\$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$FAKE_SEQ"
    printf '{"name":"sessions/s%s","id":"s%s","url":"u"}\n' "\$n" "\$n" ;;
  *) exit 1 ;;
esac
MUTFAKE
  chmod +x "$BIN/curl"
}

new_case
routine alpha false 'repos:
  - jckeen/atlas
  - jckeen/dotfiles'
# Drop jckeen/dotfiles from the list as soon as the first session is created.
mutating_curl '/- jckeen\/dotfiles/d'
if dispatch && outgrep "removed from the routine's repos between phases; skipped" \
  && [[ "$(created_count)" -eq 1 ]] \
  && [[ "$(created_repo jckeen/dotfiles)" -eq 0 ]]; then
  ok "a repository dropped from a routine mid-run is not dispatched"
else
  fail "a repository removed mid-run was still dispatched"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Slowing a routine from daily to weekly mid-run must take effect too. The
# cadence window is per (routine, repository), so the pair this can change the
# answer for is one that ran inside the last seven days but not today: eligible
# under daily, not under weekly. atlas has never run and goes first, which is
# what triggers the edit.
new_case
routine alpha false 'repos:
  - jckeen/atlas
  - jckeen/dotfiles'
ledger_line alpha jckeen/dotfiles 3 > "$STATE/dispatch.jsonl"
mutating_curl 's/^schedule: daily/schedule: weekly/'
if dispatch && outgrep "schedule became weekly between phases; skipped" \
  && [[ "$(created_repo jckeen/atlas)" -eq 1 ]] \
  && [[ "$(created_repo jckeen/dotfiles)" -eq 1 ]]; then
  ok "a routine slowed to weekly mid-run stops a pair inside the new window"
else
  fail "a schedule change mid-run was ignored"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# [medium] a routine whose frontmatter is rejected contributes nothing to the
# report, so it has to be named in the report body rather than only in the exit
# code nobody sees.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
printf 'name: broken\n' > "$ROUTINES/broken.md"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if ! PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
       "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && outgrep "frontmatter was rejected, so these are missing entirely: broken" \
   && outgrep "These counts are incomplete."; then
  ok "a rejected routine is named in the report's incompleteness caveat"
else
  fail "a rejected routine was silently missing from the report"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && ! outgrep "These counts are incomplete."; then
  ok "a complete report carries no incompleteness caveat at all"
else
  fail "a complete report claimed to be incomplete"
  sed 's/^/      | /' "$CASE_DIR/out"
fi
unset GH_ARGV GH_COMMENT_BODY

echo "── ninth review round ──"

# [medium] the report queried only a routine's CURRENT repositories, so removing
# one deleted its pull request history from the window and moved the merge rate —
# the number the retirement rule is decided on — with nothing to say a repository
# had been dropped. The scope is now the current list union the ledger's.
new_case
routine alpha false 'repos:
  - jckeen/atlas'
ledger_line alpha jckeen/dotfiles 4 > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && grep -Fq -- '--repo jckeen/atlas' "$GH_ARGV" \
   && grep -Fq -- '--repo jckeen/dotfiles' "$GH_ARGV"; then
  ok "the report covers a repository the routine no longer lists but was dispatched to"
else
  fail "the report dropped a removed repository's history"
  sed 's/^/      | /' "$GH_ARGV"
fi

# A repository named in both places must be queried once, not twice.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
ledger_line alpha jckeen/dotfiles 4 > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && [[ "$(grep -c -- '--repo jckeen/dotfiles' "$GH_ARGV")" -eq 1 ]]; then
  ok "a repository in both the list and the ledger is queried once"
else
  fail "the report double-counted a repository"
  sed 's/^/      | /' "$GH_ARGV"
fi

# And a repos: all routine's report is scoped to ITS dispatches, not every
# routine's.
new_case
routine alpha false 'repos: all'
{ ledger_line alpha jckeen/atlas 2; ledger_line other jckeen/dotfiles 2; } > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
     "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && grep -Fq -- '--repo jckeen/atlas' "$GH_ARGV" \
   && ! grep -Fq -- '--repo jckeen/dotfiles' "$GH_ARGV"; then
  ok "a repos: all report covers that routine's own dispatches only"
else
  fail "the report pulled in another routine's repositories"
  sed 's/^/      | /' "$GH_ARGV"
fi
unset GH_ARGV GH_COMMENT_BODY

echo "── tenth review round ──"

# [medium] the ledger read that builds the report scope sat inside a printf
# argument, so its failure was swallowed by the surrounding pipeline: a malformed
# ledger produced a report over current repositories only, with no caveat and a
# zero exit. The ledger is now validated once from the main shell, where die()
# can actually stop the run.
new_case
routine alpha false 'repos:
  - jckeen/atlas'
printf 'this is not json\n' > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if ! PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
       "$DISPATCH" --report --days 14 > "$CASE_DIR/out" 2>&1 \
   && outgrep "not valid JSON lines" \
   && [[ ! -s "$GH_ARGV" ]]; then
  ok "a malformed ledger stops the report before it queries anything"
else
  fail "a malformed ledger produced a report anyway"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# --post must not publish a table built on a ledger that could not be read.
new_case
routine alpha false 'repos:
  - jckeen/atlas'
printf '{"routine":"alpha"}\nnot json at all\n' > "$STATE/dispatch.jsonl"
export GH_ARGV="$CASE_DIR/gh-argv"
export GH_COMMENT_BODY="$CASE_DIR/gh-comment"
if ! PATH="$GHBIN:$PATH" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
       JULES_TRACKER="jckeen/dotfiles#446" \
       "$DISPATCH" --report --days 14 --post > "$CASE_DIR/out" 2>&1 \
   && [[ ! -e "$CASE_DIR/gh-comment" ]]; then
  ok "a malformed ledger posts nothing to the tracker issue"
else
  fail "a report built on an unreadable ledger was posted"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The dispatch path fails the same way, before any session is created.
new_case
routine alpha false 'repos: all'
printf '[1,2,3]\n' > "$STATE/dispatch.jsonl"
if ! dispatch && outgrep "not valid JSON lines" \
  && [[ "$(grep -c '/sessions' "$FAKE_CURL_ARGV")" -eq 0 ]]; then
  ok "a malformed ledger stops a dispatch before any session is created"
else
  fail "a malformed ledger still dispatched"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A ledger of well-formed objects, including the legacy shape with no status
# field, must still be accepted.
new_case
routine alpha false 'repos: all'
ledger_line alpha jckeen/atlas 5 > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(created_count)" -eq 3 ]]; then
  ok "a well-formed ledger, legacy records included, is accepted"
else
  fail "validation rejected a valid ledger"
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
