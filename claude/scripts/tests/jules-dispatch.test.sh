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
  GET:*/sources)
    cat "$FAKE_SOURCES" ;;
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

routine() { # name paused repos-block max_files
  local name="$1" paused="$2" repos="$3"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'schedule: daily\n'
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
unset GH_ARGV GH_COMMENT_BODY

echo "── systemd installer (generalised unit loop) ──"

# install.sh grew from one hardcoded pair to a table. Prove both pairs install
# and that git-hygiene — the pair that already worked — is untouched.
SYSHOME="$WORK/syshome"
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSHOME" "$SYSBIN"
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

SYSTEMCTL_LOG="$WORK/systemctl.log"
: > "$SYSTEMCTL_LOG"
if PATH="$SYSBIN:$PATH" HOME="$SYSHOME" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
   bash "$REPO_ROOT/claude/systemd/install.sh" > "$WORK/install.out" 2>&1; then
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
  if grep -Fq 'enable --now git-hygiene.timer' "$SYSTEMCTL_LOG" \
     && grep -Fq 'enable --now jules-dispatch.timer' "$SYSTEMCTL_LOG"; then
    ok "install.sh enables both timers"
  else
    fail "install.sh did not enable both timers"
    sed 's/^/      | /' "$SYSTEMCTL_LOG"
  fi
else
  fail "install.sh exited non-zero under the systemctl stub"
  sed 's/^/      | /' "$WORK/install.out"
fi

# A unit whose script is missing must fail loudly rather than install a timer
# that fires into nothing.
rm -rf "$SYSHOME"; mkdir -p "$SYSHOME"
FAKEREPO="$WORK/fakerepo"
mkdir -p "$FAKEREPO/claude/systemd" "$FAKEREPO/claude/scripts"
cp "$REPO_ROOT/claude/systemd/install.sh" "$FAKEREPO/claude/systemd/"
cp "$REPO_ROOT/claude/systemd"/*.service "$REPO_ROOT/claude/systemd"/*.timer \
   "$FAKEREPO/claude/systemd/"
printf '#!/usr/bin/env bash\n' > "$FAKEREPO/claude/scripts/hygiene-cron.sh"
chmod +x "$FAKEREPO/claude/scripts/hygiene-cron.sh"
if ! PATH="$SYSBIN:$PATH" HOME="$SYSHOME" SYSTEMCTL_LOG="$WORK/systemctl2.log" \
     bash "$FAKEREPO/claude/systemd/install.sh" > "$WORK/install2.out" 2>&1 \
   && grep -Fq 'jules-dispatch.timer install' "$WORK/install2.out"; then
  ok "a unit whose script is missing is reported and fails the install"
else
  fail "a missing unit script did not fail the install"
  sed 's/^/      | /' "$WORK/install2.out"
fi

echo
echo "── $pass passed, $failed failed ──"
[[ "$failed" -eq 0 ]] || exit 1
