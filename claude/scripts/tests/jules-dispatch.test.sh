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
  case "$a" in
    https://*) url="$a" ;;
    # --data-binary @file: keep a copy so a case can assert the request body.
    @*) [[ -n "${FAKE_BODY:-}" ]] && cp "${a#@}" "$FAKE_BODY" ;;
  esac
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
  # Session ids are numeric in the real API, and jules-dispatch.sh refuses a
  # non-numeric one before it can reach a URL — so the stub has to mint numeric
  # ones or every reconcile pass would be asserting on a refusal.
  GET:*/sessions/*)
    sid="${url##*/sessions/}"
    if [[ -f "${FAKE_SESSION_DIR:-}/session-$sid.json" ]]; then
      cat "${FAKE_SESSION_DIR}/session-$sid.json"
    elif [[ -n "${FAKE_SESSION_STRICT:-}" ]]; then
      printf 'fake curl: no session fixture for %s\n' "$sid" >&2; exit 1
    else
      # The default: a session the platform is still working on. A reconcile
      # pass over one of these writes nothing and calls no gh, which is what
      # keeps the dispatch cases that are not about reconcile unchanged.
      printf '{"name":"sessions/%s","state":"IN_PROGRESS"}\n' "$sid"
    fi ;;
  POST:*/sessions)
    n=$(( $(cat "$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$FAKE_SEQ"
    printf '{"name":"sessions/%s","id":"%s","url":"https://jules.google.com/task/%s"}\n' "$n" "$n" "$n" ;;
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
export FAKE_BODY="$WORK/curl-body.json"

# ── Fake gh ──────────────────────────────────────────────────────────
# The reconcile pass is the only caller. Records argv, answers `pr view` from a
# per-PR fixture the case writes, accepts the writes, and can be told to fail
# one subcommand pair through FAKE_GH_FAIL ("pr close", "pr edit", ...). The
# --report cases keep their own richer stub earlier on PATH.
cat > "$BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_ARGV:-/dev/null}"
sub="${1:-} ${2:-}"
[[ "${1:-}" == "api" ]] && sub="api"
if [[ -n "${FAKE_GH_FAIL:-}" && "$sub" == "${FAKE_GH_FAIL}" ]]; then
  printf 'fake gh: forced failure for %s\n' "$sub" >&2
  exit 1
fi
case "$sub" in
  # repos/OWNER/NAME/pulls/<n>/commits?per_page=100 — the exact source the
  # commit-subject check needs, because it carries each commit's parents.
  "api")
    # The endpoint path is whichever argument starts with repos/, since flags
    # such as --paginate may sit in front of it.
    p=""
    for a in "$@"; do case "$a" in repos/*) p="$a"; break ;; esac; done
    p="${p%%\?*}"; p="${p%/commits}"; p="${p##*/}"
    f="${FAKE_GH_DIR:-}/commits-$p.json"
    if [[ -f "$f" ]]; then cat "$f"; else printf '[]\n'; fi
    # gh --paginate emits one JSON document per page, concatenated.
    if [[ "$*" == *--paginate* && -f "${FAKE_GH_DIR:-}/commits2-$p.json" ]]; then
      cat "${FAKE_GH_DIR}/commits2-$p.json"
    fi ;;
  "pr view")
    f="${FAKE_GH_DIR:-}/pr-$3.json"
    [[ -f "$f" ]] || { printf 'fake gh: no fixture for PR %s\n' "$3" >&2; exit 1; }
    cat "$f" ;;
  "pr close"|"pr edit"|"label create") : ;;
  "label list") printf '[]\n' ;;
  *) printf 'fake gh: unexpected %s\n' "$sub" >&2; exit 1 ;;
esac
FAKEGH
chmod +x "$BIN/gh"
export FAKE_GH_ARGV="$WORK/gh-argv.log"

cat > "$FAKE_SOURCES" <<'SRC'
{"sources":[
  {"name":"sources/github/jckeen/dotfiles","id":"github/jckeen/dotfiles",
   "githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}},
  {"name":"sources/github/jckeen/atlas","id":"github/jckeen/atlas",
   "githubRepo":{"owner":"jckeen","repo":"atlas","defaultBranch":{"displayName":"develop"}}}
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
  : > "$FAKE_GH_ARGV"
  export FAKE_GH_DIR="$CASE_DIR"
  export FAKE_SESSION_DIR="$CASE_DIR"
  rm -f "$FAKE_SEQ" "$FAKE_BODY"
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
# The ledger now also carries reconcile records, which have no .status — so
# every dispatch count below has to exclude them by kind or a reconcile pass
# would read as a dispatch. Same guard the dispatcher applies internally.
dispatch_jq() {
  [[ -s "$STATE/dispatch.jsonl" ]] || { printf '0'; return 0; }
  jq -s '[.[] | select((.kind // "dispatch") == "dispatch")]' "$STATE/dispatch.jsonl" \
    | jq "$@"
}
reconcile_jq() {
  [[ -s "$STATE/dispatch.jsonl" ]] || { printf '0'; return 0; }
  jq -s '[.[] | select(.kind == "reconcile")]' "$STATE/dispatch.jsonl" | jq "$@"
}
reconcile_count() { reconcile_jq 'length'; }
reconcile_action() { reconcile_jq --arg a "$1" '[.[] | select(.action == $a)] | length'; }
created_count() { dispatch_jq '[.[] | select((.status // "created") == "created")] | length'; }
created_routine() {
  dispatch_jq --arg r "$1" '[.[] | select(.routine == $r and ((.status // "created") == "created"))] | length'
}
created_repo() {
  dispatch_jq --arg p "$1" '[.[] | select(.repo == $p and ((.status // "created") == "created"))] | length'
}
attempted_count() { dispatch_jq '[.[] | select((.status // "") == "attempted")] | length'; }

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
  GET:*/sessions/*) printf '{"state":"IN_PROGRESS"}\n' ;;
  POST:*/sessions)
    n=$(( $(cat "$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$FAKE_SEQ"
    printf '{"name":"sessions/%s","id":"%s","url":"u"}\n' "$n" "$n" ;;
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

# GitHubRepoContext.startingBranch is REQUIRED (sessions reference, and the API
# answered INVALID_ARGUMENT to a body without it on 2026-09-19). GET /sources
# reports each repository's default branch, so the dispatcher derives it per
# repository rather than needing an operator-set value for every session.
new_case
routine alpha false 'repos:
  - jckeen/atlas'
if dispatch && [[ "$(jq -r '.sourceContext.githubRepoContext.startingBranch' "$FAKE_BODY")" == "develop" ]]; then
  ok "startingBranch is the source's default branch when JULES_STARTING_BRANCH is unset"
else
  fail "the request body did not carry the source's default branch"
  jq -c '.sourceContext' "$FAKE_BODY" 2>/dev/null | sed 's/^/      | /'
fi

new_case
routine alpha false 'repos:
  - jckeen/atlas'
if JULES_STARTING_BRANCH=release dispatch \
  && [[ "$(jq -r '.sourceContext.githubRepoContext.startingBranch' "$FAKE_BODY")" == "release" ]]; then
  ok "JULES_STARTING_BRANCH overrides the source's default branch"
else
  fail "JULES_STARTING_BRANCH did not override the default branch"
  jq -c '.sourceContext' "$FAKE_BODY" 2>/dev/null | sed 's/^/      | /'
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A source with no default branch and no override cannot make a valid request:
# the pair fails locally BEFORE the write-ahead record, so nothing is charged
# against the cap and the other repository still dispatches.
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/sources-nobranch.json" <<'NB'
{"sources":[
  {"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}},
  {"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas"}}
]}
NB
FAKE_SOURCES="$CASE_DIR/sources-nobranch.json" dispatch; rc=$?
if [[ "$rc" -ne 0 ]] && outgrep "jckeen/atlas — no starting branch" \
  && [[ "$(created_count)" -eq 1 ]] && [[ "$(created_repo jckeen/dotfiles)" -eq 1 ]] \
  && [[ "$(ledger_jq '[.[] | select(.repo == "jckeen/atlas")] | length')" -eq 0 ]]; then
  ok "a source without a default branch is refused locally and leaves no ledger record"
else
  fail "a source without a default branch was not refused before the write-ahead record (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The refusal is a LOCAL one, so it must not consume a slot of the daily cap
# either: at cap 1 the branchless pair is refused and the valid pair behind it
# still gets the day's one session, rather than meeting "daily cap reached".
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/sources-nobranch.json" <<'NB'
{"sources":[
  {"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}},
  {"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas"}}
]}
NB
# atlas sorts before dotfiles and both have never run, so the branchless pair is
# first in the fairness order — the position that spent the cap before the fix.
CAP=1 FAKE_SOURCES="$CASE_DIR/sources-nobranch.json" dispatch; rc=$?
if [[ "$rc" -ne 0 ]] && outgrep "jckeen/atlas — no starting branch" \
  && [[ "$(created_count)" -eq 1 ]] && [[ "$(created_repo jckeen/dotfiles)" -eq 1 ]] \
  && ! outgrep "daily cap"; then
  ok "a branchless pair spends no cap slot, so the next valid pair still dispatches"
else
  fail "the branchless pair consumed the daily cap (rc=$rc, created=$(created_count))"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A dry run has to name the same dispatchable pairs a live run would: the branch
# is resolved in the shared eligibility phase, so the preview reports the refusal
# instead of promising a dispatch that the live run then refuses.
new_case
routine alpha false 'repos: all'
cat > "$CASE_DIR/sources-nobranch.json" <<'NB'
{"sources":[
  {"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}},
  {"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas"}}
]}
NB
before="$(snapshot "$STATE")"
FAKE_SOURCES="$CASE_DIR/sources-nobranch.json" dispatch --dry-run; rc=$?
if [[ "$rc" -ne 0 ]] && outgrep "jckeen/atlas — no starting branch" \
  && ! outgrep "would dispatch alpha / jckeen/atlas" \
  && outgrep "would dispatch alpha / jckeen/dotfiles" \
  && [[ "$before" == "$(snapshot "$STATE")" ]]; then
  ok "--dry-run reports the branchless pair's refusal rather than a dispatch, and writes nothing"
else
  fail "--dry-run previewed a dispatch the live run would refuse (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# #479 gap 1: the first live run's bot commit subject was "No changes needed:
# doc drift checkers pass", which the required commit-format check rejects. The
# catalog files already asked for conventional subjects and the bot ignored it,
# so the requirement belongs in the header the dispatcher injects — the first
# thing the session reads. Asserted against the checker's own type set, so the
# prompt cannot drift away from what CI enforces.
new_case
routine alpha false 'repos:
  - jckeen/atlas'
expected_types="$(sed -n "s/^TYPES='\(.*\)'\$/\1/p" "$REPO_ROOT/claude/scripts/check-commit-format.sh")"
if dispatch; then
  hard_limits="$(jq -r '.prompt' "$FAKE_BODY" | grep -F 'Hard limits:' || true)"
  if [[ -z "$expected_types" ]]; then
    fail "could not read TYPES from check-commit-format.sh — the drift assertion is vacuous"
  elif [[ "$hard_limits" == *"type: short description"* \
    && "$hard_limits" == *"$expected_types"* ]]; then
    ok "the injected Hard limits line demands conventional commit subjects, with the checker's type set"
  else
    fail "the Hard limits line does not carry the conventional-subject requirement"
    printf '      | %s\n' "$hard_limits"
  fi
else
  fail "the run that should have built a prompt did not exit 0"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

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
printf '{"dispatched_at":"2026-09-01T00:00:00Z","date":"2026-09-01","routine":"alpha","repo":"jckeen/dotfiles","source":"sources/github/jckeen/dotfiles","session":"sessions/900001","url":""}\n' \
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
# The reconcile pass a dry run also performs is read-only and GETs
# /sessions/{id}, so the assertion is on the method rather than on the path.
if grep -Fq 'would dispatch' "$CASE_DIR/out" && ! grep -Fq '"method":"POST"' "$FAKE_CURL_ARGV" \
   && ! grep -Fq -- '-X POST' "$FAKE_CURL_ARGV"; then
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
SEEDED_SESSION=700000
ledger_line() { # routine repo days-ago
  local e at
  e=$((JULES_NOW_EPOCH - $3 * 86400))
  at="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ)"
  # A real session name, because every dispatch now ends with a reconcile pass
  # and a malformed one in the ledger is a refusal, not a past dispatch. The
  # fake curl answers an unknown id with IN_PROGRESS, so these settle nothing.
  SEEDED_SESSION=$((SEEDED_SESSION + 1))
  printf '{"dispatched_at":"%s","date":"%s","routine":"%s","repo":"%s","source":"s","session":"sessions/%s","url":""}\n' \
    "$at" "${at%%T*}" "$1" "$2" "$SEEDED_SESSION"
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

# The boundary itself. With an inclusive comparison a daily timer firing at the
# same time each day finds the seven-day-old record still inside the cooldown and
# skips the seventh day — so "weekly" would mean every eighth day.
new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
ledger_line weeklyone jckeen/dotfiles 7 > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(created_count)" -eq 2 ]]; then
  ok "a weekly routine runs on the seventh day, not the eighth"
else
  fail "the cadence window is inclusive, delaying every weekly run by a day"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# One second inside the window must still be held back, or the check is off by a
# whole day in the other direction.
new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
e=$((JULES_NOW_EPOCH - 7 * 86400 + 1))
at="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"dispatched_at":"%s","date":"%s","routine":"weeklyone","repo":"jckeen/dotfiles","source":"s","session":"sessions/700900","url":""}\n' \
  "$at" "${at%%T*}" > "$STATE/dispatch.jsonl"
if dispatch && outgrep "dispatched inside the last 7 day(s); skipped" \
  && [[ "$(created_count)" -eq 1 ]]; then
  ok "a dispatch one second inside the seven-day window is still held back"
else
  fail "the cadence window is exclusive by more than it should be"
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
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}}],
 "nextPageToken":"tok-page-2"}
P1
cat > "$CASE_DIR/sources-p2.json" <<'P2'
{"sources":[{"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas","defaultBranch":{"displayName":"main"}}}]}
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
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}}],
 "nextPageToken":"a+b/c=d"}
B64
cat > "$CASE_DIR/p2.json" <<'B64P2'
{"sources":[{"name":"sources/github/jckeen/atlas","githubRepo":{"owner":"jckeen","repo":"atlas","defaultBranch":{"displayName":"main"}}}]}
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
{"sources":[{"name":"sources/github/jckeen/dotfiles","githubRepo":{"owner":"jckeen","repo":"dotfiles","defaultBranch":{"displayName":"main"}}}],
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

echo "── fifteenth review round ──"

# [medium] the jq that builds the request body was unchecked, and errexit is off
# inside dispatch_one (its caller uses `|| rc=$?`), so a failure still POSTed an
# empty body — while the write-ahead record blocked the retry and consumed a slot
# for a session that provably never existed. A jq stub that fails on the body
# build (three -n arguments) but works everywhere else drives it.
new_case
routine alpha false 'repos: all'
cat > "$BIN/jq" <<JQFAKE
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == *automationMode* ]]; then exit 9; fi
done
exec $(command -v jq) "\$@"
JQFAKE
chmod +x "$BIN/jq"
if ! dispatch \
  && outgrep "could not build the request body; no session created" \
  && [[ "$(grep -c '/sessions' "$FAKE_CURL_ARGV")" -eq 0 ]]; then
  ok "a failed request-body build never reaches POST"
else
  fail "an unbuildable request body was still POSTed"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# And it must leave NOTHING in the ledger: the failure is local and certain, so
# the pair has to stay retryable rather than be marked attempted.
if [[ ! -s "$STATE/dispatch.jsonl" ]]; then
  ok "a local build failure records no attempt, so the pair stays retryable"
else
  fail "a local failure consumed a slot for a session that never existed"
  sed 's/^/      | /' "$STATE/dispatch.jsonl"
fi
rm -f "$BIN/jq"

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
  GET:*/sessions/*) printf '{"state":"IN_PROGRESS"}\n' ;;
  POST:*/sessions)
    # Pause the routine mid-run, the moment the first session is created.
    sed -i 's/^paused: false/paused: true/' "$ROUTINES/alpha.md"
    n=\$(( \$(cat "\$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$FAKE_SEQ"
    printf '{"name":"sessions/%s","id":"%s","url":"u"}\n' "\$n" "\$n" ;;
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
restore_fake_curl

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
  GET:*/sessions/*) printf '{"state":"IN_PROGRESS"}\n' ;;
  POST:*/sessions)
    sed -i '$1' "$ROUTINES/alpha.md"
    n=\$(( \$(cat "\$FAKE_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$FAKE_SEQ"
    printf '{"name":"sessions/%s","id":"%s","url":"u"}\n' "\$n" "\$n" ;;
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
restore_fake_curl

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

echo "── --reconcile ──"

# The platform opens a pull request for EVERY completed session, including one
# that changed nothing: the first live run (#479) produced PR #477 with zero
# changed files, the non-conventional title "Routine: doc-drift-fixer - clean
# run", and no label. A second live session came back COMPLETED with `outputs`
# null — no change set, no pull request at all. Reconcile is the pass that turns
# both into a recorded outcome, and the ledger is the only place a routine PR's
# provenance is API-confirmed.
recon_run() { # extra flags...
  JULES_API_KEY_FILE="$KEY" JULES_STATE_DIR="$STATE" JULES_ROUTINE_DIR="$ROUTINES" \
    "$DISPATCH" --reconcile "$@" > "$CASE_DIR/out" 2>&1
}

# A "created" dispatch record — the only kind reconcile looks at.
session_line() { # session-id routine repo days-ago
  local e at
  e=$((JULES_NOW_EPOCH - $4 * 86400))
  at="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"dispatched_at":"%s","date":"%s","routine":"%s","repo":"%s","source":"s","status":"created","attempt":"a%s","session":"sessions/%s","url":""}\n' \
    "$at" "${at%%T*}" "$2" "$3" "$1" "$1"
}

# Shaped like the live record: outputs is an array whose pullRequest entry
# carries a url and NO number field, which is why the dispatcher parses the url.
completed_with_pr() { # session-id pr-url
  printf '{"name":"sessions/%s","state":"COMPLETED","outputs":[{"changeSet":{"source":"sources/github/jckeen/dotfiles"}},{"pullRequest":{"url":"%s","title":"t","baseRef":"main","headRef":"jules-x"}}]}\n' \
    "$1" "$2" > "$CASE_DIR/session-$1.json"
}
session_state() { # session-id raw-json
  printf '%s\n' "$2" > "$CASE_DIR/session-$1.json"
}
pr_fixture() { # number json
  printf '%s\n' "$2" > "$CASE_DIR/pr-$1.json"
}
commits_fixture() { # number json-array
  printf '%s\n' "$2" > "$CASE_DIR/commits-$1.json"
}
commits_page2() { # number json-array
  printf '%s\n' "$2" > "$CASE_DIR/commits2-$1.json"
}
ghgrep() { grep -Fq -- "$1" "$FAKE_GH_ARGV"; }

# An empty run is a good run, but an empty PR is still an open PR asking for a
# review. Reconcile closes it and says why in one line.
new_case
routine alpha false 'repos: all'
session_line 901 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 901 https://github.com/jckeen/dotfiles/pull/901
pr_fixture 901 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
if recon_run && ghgrep 'pr close 901' && ghgrep '--comment' \
  && [[ "$(reconcile_action closed-empty)" -eq 1 ]] && ! ghgrep '--add-label'; then
  ok "an open routine PR with zero changed files is closed with a one-line comment"
else
  fail "the empty routine PR was not closed"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# The platform applies no label and writes a non-conventional title, so a
# routine PR arrives both unclassifiable and unmergeable. Reconcile fixes both.
new_case
routine alpha false 'repos: all'
session_line 902 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 902 https://github.com/jckeen/dotfiles/pull/902
pr_fixture 902 '{"state":"OPEN","changedFiles":3,"title":"Routine: alpha - drop the dead link","labels":[]}'
if recon_run \
  && ghgrep 'label create jules-routine:alpha' \
  && ghgrep '--add-label jules-routine:alpha' \
  && ghgrep '--title chore(alpha): drop the dead link' \
  && [[ "$(reconcile_action labeled+retitled)" -eq 1 ]] \
  && [[ "$(reconcile_count)" -eq 1 ]]; then
  ok "a non-empty routine PR is labeled and its title normalised to a conventional subject"
else
  fail "the non-empty routine PR was not labeled and retitled"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# Retitling a subject the commit-format check already accepts would be churn,
# and would bury whatever the session actually said it did.
new_case
routine alpha false 'repos: all'
session_line 903 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 903 https://github.com/jckeen/dotfiles/pull/903
pr_fixture 903 '{"state":"OPEN","changedFiles":2,"title":"fix(docs): repair the broken anchor","labels":[]}'
if recon_run && ghgrep '--add-label jules-routine:alpha' && ! ghgrep '--title' \
  && [[ "$(reconcile_action labeled)" -eq 1 ]]; then
  ok "a routine PR whose title is already conventional is labeled but not retitled"
else
  fail "a conventional title was rewritten"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# A merged or closed PR is somebody's decision. Record it and touch nothing.
new_case
routine alpha false 'repos: all'
session_line 904 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 904 https://github.com/jckeen/dotfiles/pull/904
pr_fixture 904 '{"state":"MERGED","changedFiles":4,"title":"Routine: alpha - done","labels":[]}'
if recon_run && [[ "$(reconcile_action noop)" -eq 1 ]] \
  && ! ghgrep 'pr close' && ! ghgrep 'pr edit' && ! ghgrep 'label create'; then
  ok "a merged routine PR is recorded as a no-op and never written to"
else
  fail "a merged routine PR was written to"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# Idempotency is the whole contract: a session with a terminal record is skipped
# WITHOUT an API call, so a daily timer cannot re-close or re-label anything.
new_case
routine alpha false 'repos: all'
session_line 905 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 905 https://github.com/jckeen/dotfiles/pull/905
pr_fixture 905 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
recon_run
: > "$FAKE_GH_ARGV"; : > "$FAKE_CURL_ARGV"
if recon_run && [[ ! -s "$FAKE_GH_ARGV" ]] && [[ ! -s "$FAKE_CURL_ARGV" ]] \
  && [[ "$(reconcile_count)" -eq 1 ]]; then
  ok "a session already reconciled is skipped without one API or gh call"
else
  fail "a reconciled session was processed again"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# A session still running is not a result. No record, so the next run retries it
# — recording one would freeze the session's outcome at "we looked too early".
new_case
routine alpha false 'repos: all'
session_line 906 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
session_state 906 '{"name":"sessions/906","state":"IN_PROGRESS"}'
recon_run; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
  completed_with_pr 906 https://github.com/jckeen/dotfiles/pull/906
  pr_fixture 906 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
  if recon_run && [[ "$(reconcile_action closed-empty)" -eq 1 ]]; then
    ok "an unfinished session is skipped with no record, and reconciles once it completes"
  else
    fail "the session did not reconcile after completing"
    sed 's/^/      | /' "$CASE_DIR/out"
  fi
else
  fail "an unfinished session was recorded or acted on (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Two outcomes that produce no pull request at all. The second is the observed
# one: a COMPLETED session whose `outputs` is null.
new_case
routine alpha false 'repos: all'
{ session_line 907 alpha jckeen/dotfiles 1; session_line 908 alpha jckeen/dotfiles 1; } \
  > "$STATE/dispatch.jsonl"
session_state 907 '{"name":"sessions/907","state":"FAILED"}'
session_state 908 '{"name":"sessions/908","state":"COMPLETED","outputs":null}'
if recon_run && [[ "$(reconcile_action failed)" -eq 1 ]] \
  && [[ "$(reconcile_action no-pr)" -eq 1 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
  ok "a FAILED session and a COMPLETED one with no pull request are both recorded"
else
  fail "the no-pull-request outcomes were not recorded"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The dispatcher must never act on a URL the API hands it without checking where
# it points: a PR url on another host, on http, or in a repository the session
# was not dispatched to is refused before any gh call.
bad_pr_url() { # label session-id url
  new_case
  routine alpha false 'repos: all'
  session_line "$2" alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
  completed_with_pr "$2" "$3"
  recon_run; local rc=$?
  if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_action error)" -eq 1 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
    ok "$1"
  else
    fail "$1 (rc=$rc)"
    sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
  fi
}
bad_pr_url "a pull-request URL on another host is refused, not acted on" \
  909 'https://github.com.evil.example/jckeen/dotfiles/pull/9'
bad_pr_url "a pull-request URL on http is refused, not acted on" \
  910 'http://github.com/jckeen/dotfiles/pull/9'
bad_pr_url "a pull-request URL in a repository the session was not dispatched to is refused" \
  911 'https://github.com/someone-else/dotfiles/pull/9'
bad_pr_url "a pull-request URL with an extra path segment is refused" \
  912 'https://github.com/jckeen/dotfiles/pull/9/files'

# A failed gh write is a failure, never a silent one — and it must not leave a
# record claiming the PR was handled, or the next run would skip the repair.
new_case
routine alpha false 'repos: all'
session_line 913 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 913 https://github.com/jckeen/dotfiles/pull/913
pr_fixture 913 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
FAKE_GH_FAIL="pr close" recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && outgrep "gh pr close failed"; then
  ok "a failed gh write is counted as a failure and records no success"
else
  fail "a failed gh write was swallowed (rc=$rc, records=$(reconcile_count))"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# The trap: every ledger query keys off .date/.routine/.repo, so a reconcile
# record written today would have counted as a dispatch — eating the cap and
# suppressing the very routine it belongs to.
new_case
routine alpha false 'repos: all'
printf '{"kind":"reconcile","reconciled_at":"2026-09-10T11:00:00Z","date":"2026-09-10","routine":"alpha","repo":"jckeen/dotfiles","session":"sessions/920","pr_url":"","pr":0,"action":"no-pr","detail":""}\n' \
  > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(created_count)" -eq 2 ]] && ! outgrep "already dispatched today"; then
  ok "a reconcile record dated today is not counted as a dispatch"
else
  fail "a reconcile record suppressed today's dispatch"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Same trap against the weekly cadence window, which compares .dispatched_at.
new_case
routine weeklyone false 'repos:
  - jckeen/dotfiles' weekly
printf '{"kind":"reconcile","reconciled_at":"2026-09-09T11:00:00Z","dispatched_at":"2026-09-09T11:00:00Z","date":"2026-09-09","routine":"weeklyone","repo":"jckeen/dotfiles","session":"sessions/921","pr_url":"","pr":0,"action":"no-pr","detail":""}\n' \
  > "$STATE/dispatch.jsonl"
if dispatch && [[ "$(created_count)" -eq 1 ]] \
  && ! outgrep "inside the weekly cadence window" \
  && ! outgrep "dispatched inside the last 7 day(s)"; then
  ok "a reconcile record does not hold a weekly routine inside its cadence window"
else
  fail "a reconcile record was read as a dispatch by the cadence check"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# "Writes nothing" has to hold in every mode. A dry run may read the API and
# gh, and says what it would do, but the state dir comes out byte-identical.
new_case
routine alpha false 'repos: all'
session_line 922 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 922 https://github.com/jckeen/dotfiles/pull/922
pr_fixture 922 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
printf 'pre-existing log line\n' > "$STATE/dispatch.log"
before="$(snapshot "$STATE")"
recon_run --dry-run; rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$before" == "$(snapshot "$STATE")" ]] \
  && outgrep "[DRY] would close" && ! ghgrep 'pr close'; then
  ok "--dry-run --reconcile reports what it would do and leaves the state dir byte-identical"
else
  fail "--dry-run --reconcile wrote something (rc=$rc)"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$(snapshot "$STATE")") | sed 's/^/      | /'
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Reconcile is not a separate chore to remember: every dispatch run ends with
# one, after the sessions it just created are in the ledger.
new_case
routine alpha false 'repos:
  - jckeen/dotfiles'
if dispatch; then
  post_ln="$(grep -n -- '-X POST' "$FAKE_CURL_ARGV" | head -1 | cut -d: -f1)"
  get_ln="$(grep -n -- '/sessions/1' "$FAKE_CURL_ARGV" | head -1 | cut -d: -f1)"
  if [[ -n "$post_ln" && -n "$get_ln" && "$post_ln" -lt "$get_ln" ]]; then
    ok "a dispatch run ends with a reconcile pass over the sessions it just created"
  else
    fail "the dispatch run did not reconcile after creating (post=$post_ln get=$get_ln)"
    sed 's/^/      | /' "$FAKE_CURL_ARGV"
  fi
else
  fail "the dispatch run that should have reconciled did not exit 0"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# --report tallies; --reconcile acts. Asking for both is a mistake, not a
# composition, so it is refused rather than silently resolved one way.
new_case
routine alpha false 'repos: all'
if ! recon_run --report && outgrep "--reconcile cannot be combined with --report"; then
  ok "--reconcile with --report is refused"
else
  fail "--reconcile --report was accepted"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Standalone, gh is the whole point of the pass, so its absence is fatal.
new_case
routine alpha false 'repos: all'
session_line 930 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 930 https://github.com/jckeen/dotfiles/pull/930
if ! JULES_GH=gh-not-installed-here recon_run && outgrep "needs the GitHub CLI"; then
  ok "a standalone --reconcile with no gh on PATH dies rather than reporting a clean pass"
else
  fail "a standalone --reconcile without gh did not die"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Inside a dispatch it must not be fatal: the sessions were created and their
# ledger records matter more than the tidy-up. One failure, so the exit code
# still says the run was not clean.
new_case
routine alpha false 'repos: all'
session_line 931 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 931 https://github.com/jckeen/dotfiles/pull/931
JULES_GH=gh-not-installed-here dispatch; rc=$?
if [[ "$rc" -ne 0 ]] && outgrep "reconcile skipped" && [[ "$(created_count)" -eq 3 ]]; then
  ok "a dispatch whose reconcile pass has no gh still dispatches, and says the pass was skipped"
else
  fail "a missing gh broke the dispatch itself (rc=$rc created=$(created_count))"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# --repo narrows the pass the same way it narrows a dispatch.
new_case
routine alpha false 'repos: all'
{ session_line 940 alpha jckeen/dotfiles 1; session_line 941 alpha jckeen/atlas 1; } \
  > "$STATE/dispatch.jsonl"
completed_with_pr 940 https://github.com/jckeen/dotfiles/pull/940
completed_with_pr 941 https://github.com/jckeen/atlas/pull/941
pr_fixture 940 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
pr_fixture 941 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
if recon_run --repo jckeen/atlas && ghgrep 'pr close 941' && ! ghgrep '940' \
  && [[ "$(reconcile_count)" -eq 1 ]]; then
  ok "--reconcile --repo touches only that repository's sessions"
else
  fail "--reconcile --repo reached another repository"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# A PR that already carries the label and a conventional subject needs no write
# at all, but is still a terminal outcome and must be recorded as one.
new_case
routine alpha false 'repos: all'
session_line 942 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 942 https://github.com/jckeen/dotfiles/pull/942
pr_fixture 942 '{"state":"OPEN","changedFiles":2,"title":"fix(docs): repair the anchor","labels":[{"name":"jules-routine:alpha"}]}'
if recon_run && [[ "$(reconcile_action unchanged)" -eq 1 ]] \
  && ! ghgrep 'pr edit' && ! ghgrep 'label create'; then
  ok "a routine PR already labeled with a conventional title is recorded without a write"
else
  fail "an already-correct routine PR was written to"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# Codex gate, [high]: the required commit-format check lints COMMIT SUBJECTS in
# the pull request's range, not the pull request's title. Retitling fixes what a
# squash merge lands on main and nothing else, so a routine PR whose bot commit
# subject is "No changes needed: ..." stays blocked. Nothing here can rewrite
# someone else's branch, so the condition has to be named rather than settled in
# silence.
new_case
routine alpha false 'repos: all'
session_line 945 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 945 https://github.com/jckeen/dotfiles/pull/945
pr_fixture 945 '{"state":"OPEN","changedFiles":2,"title":"Routine: alpha - fix the anchor","labels":[]}'
commits_fixture 945 '[{"parents":[{"sha":"a"}],"commit":{"message":"No changes needed: doc drift checkers pass\n\nbody"}}]'
if recon_run && outgrep "the required commit-format check rejects" \
  && [[ "$(reconcile_jq '[.[] | select(.commit_subjects_ok == false)] | length')" -eq 1 ]] \
  && [[ "$(jq -r '.reconcile.blocked_subjects' "$STATE/status.json")" == "1" ]]; then
  ok "a retitled PR whose commit subjects still fail the format check is named, not silently settled"
else
  fail "a PR left unmergeable by its commit subjects was recorded as fully settled"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

new_case
routine alpha false 'repos: all'
session_line 947 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 947 https://github.com/jckeen/dotfiles/pull/947
pr_fixture 947 '{"state":"OPEN","changedFiles":2,"title":"Routine: alpha - fix the anchor","labels":[]}'
# The checker excludes merge commits (git rev-list --no-merges) and skips the
# revert auto-message, so reporting either as blocking would be a false alarm
# on a pull request CI is perfectly happy with.
commits_fixture 947 '[{"parents":[{"sha":"a"}],"commit":{"message":"docs: fix the anchor"}},
 {"parents":[{"sha":"a"},{"sha":"b"}],"commit":{"message":"Merge branch main into jules-x"}},
 {"parents":[{"sha":"a"}],"commit":{"message":"Revert \"docs: fix the anchor\""}}]'
if recon_run && ! outgrep "the required commit-format check rejects" \
  && [[ "$(reconcile_jq '[.[] | select(.commit_subjects_ok == true)] | length')" -eq 1 ]]; then
  ok "merge commits and revert auto-messages are skipped, exactly as the checker skips them"
else
  fail "conventional commit subjects were reported as blocking"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# #508: commit_subjects_ok is provenance, not a summary — a record whose commits
# this pass never listed has to say so. A pull request that was already CLOSED
# when reconcile ran is a noop: it is never read for commits, so the flag is
# JSON null (present, so a consumer sees "not examined" rather than a missing
# key) and never true. This one's single commit subject is exactly the shape
# check-commit-format.sh rejects, so a true here would be false provenance.
new_case
routine alpha false 'repos: all'
session_line 954 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 954 https://github.com/jckeen/dotfiles/pull/954
pr_fixture 954 '{"state":"CLOSED","changedFiles":2,"title":"Routine: alpha - fix the anchor","labels":[]}'
commits_fixture 954 '[{"parents":[{"sha":"a"}],"commit":{"message":"No changes needed: doc drift checkers pass"}}]'
if recon_run && [[ "$(reconcile_action noop)" -eq 1 ]] \
  && [[ "$(reconcile_jq -r '.[0] | has("commit_subjects_ok")')" == "true" ]] \
  && [[ "$(reconcile_jq -r '.[0].commit_subjects_ok')" == "null" ]] \
  && ! ghgrep 'pulls/954/commits'; then
  ok "a closed PR whose commits were never read records commit_subjects_ok: null"
else
  fail "a closed PR whose commits were never read claimed its subjects were checked"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      | /' "$STATE/dispatch.jsonl"
fi

# Codex gate, [medium]: a session's records are settled together or not at all.
# Appending them one at a time meant a failure after the first line left the
# session looking reconciled while the rest of its pull-request provenance was
# never written — and every later run skipped it.
new_case
routine alpha false 'repos: all'
session_line 946 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
printf '{"name":"sessions/946","state":"COMPLETED","outputs":[{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9461"}},{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9462"}}]}\n' \
  > "$CASE_DIR/session-946.json"
pr_fixture 9461 '{"state":"OPEN","changedFiles":2,"title":"fix(docs): one","labels":[]}'
pr_fixture 9462 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
FAKE_GH_FAIL="pr close" recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && ghgrep '--add-label'; then
  ok "a multi-PR session whose last gh write fails records none of its outcomes"
else
  fail "a partly-failed session left a record that would make later runs skip it (rc=$rc records=$(reconcile_count))"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# ...and the same rule at the write boundary: a session's records go into the
# ledger in ONE append of less than PIPE_BUF bytes, or none of them do. Fifteen
# long-titled pull requests are past that bound, so the session is refused and
# retried rather than half-recorded and skipped for ever.
new_case
routine alpha false 'repos: all'
session_line 948 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
outputs=""
for n in $(seq 9480 9539); do
  outputs="$outputs{\"pullRequest\":{\"url\":\"https://github.com/jckeen/dotfiles/pull/$n\"}},"
  printf '{"state":"OPEN","changedFiles":2,"title":"fix(docs): one","labels":[{"name":"jules-routine:alpha"}]}\n' \
    > "$CASE_DIR/pr-$n.json"
done
printf '{"name":"sessions/948","state":"COMPLETED","outputs":[%s]}\n' "${outputs%,}" \
  > "$CASE_DIR/session-948.json"
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && outgrep "atomically"; then
  ok "a session whose record will not fit one atomic append is refused, not truncated"
else
  fail "an oversized session was half-recorded (rc=$rc records=$(reconcile_count))"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Codex gate, [medium]: the commits endpoint pages at 100. A rejected subject
# on page two was missed, and the terminal record meant nothing looked again.
new_case
routine alpha false 'repos: all'
session_line 952 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 952 https://github.com/jckeen/dotfiles/pull/952
pr_fixture 952 '{"state":"OPEN","changedFiles":2,"title":"fix(docs): one","labels":[{"name":"jules-routine:alpha"}]}'
commits_fixture 952 '[{"parents":[{"sha":"a"}],"commit":{"message":"docs: page one is fine"}}]'
commits_page2 952 '[{"parents":[{"sha":"a"}],"commit":{"message":"No changes needed: page two is not"}}]'
if recon_run && outgrep "the required commit-format check rejects" \
  && [[ "$(reconcile_jq '[.[] | select(.commit_subjects_ok == false)] | length')" -eq 1 ]]; then
  ok "a rejected commit subject on the second page of commits is still found"
else
  fail "commit-subject checking stopped after the first page"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Codex gate, [medium]: jq's // replaces false as well as null, so an
# `outputs: false` response counted as zero pull requests and was recorded
# terminally as no-pr instead of being retried.
new_case
routine alpha false 'repos: all'
session_line 953 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
session_state 953 '{"name":"sessions/953","state":"COMPLETED","outputs":false}'
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && outgrep "unreadable outputs"; then
  ok "an outputs value of false is unreadable, not an absence of pull requests"
else
  fail "outputs: false was recorded as 'no pull request' (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# Codex gate, [medium]: a pullRequest.url carrying an embedded newline was
# split into two URLs before the anchored pattern ever saw it, so a single
# malformed field could drive writes to two pull requests. Outputs are read one
# JSON value at a time, and the anchored match rejects a value with a newline in
# it whole.
new_case
routine alpha false 'repos: all'
session_line 949 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
printf '{"name":"sessions/949","state":"COMPLETED","outputs":[{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9491\\nhttps://github.com/jckeen/dotfiles/pull/9492"}}]}\n' \
  > "$CASE_DIR/session-949.json"
pr_fixture 9491 '{"state":"OPEN","changedFiles":0,"title":"x","labels":[]}'
pr_fixture 9492 '{"state":"OPEN","changedFiles":0,"title":"x","labels":[]}'
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_action error)" -eq 1 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
  ok "a pull-request URL field carrying two URLs on separate lines is refused whole"
else
  fail "an embedded newline split one URL field into two actionable URLs (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# Codex gate, [low] / #505: command substitution strips TRAILING newlines, so a
# url field ending in "\n" reached the anchored pattern already trimmed and
# passed the whole-field check it must fail — turning a value the contract
# refuses into a write against a real pull request. The value now leaves jq with
# a sentinel appended, so the trailing newline is still on it when the pattern
# sees it.
new_case
routine alpha false 'repos: all'
session_line 955 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
printf '{"name":"sessions/955","state":"COMPLETED","outputs":[{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9\\n"}}]}\n' \
  > "$CASE_DIR/session-955.json"
pr_fixture 9 '{"state":"OPEN","changedFiles":0,"title":"x","labels":[]}'
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_action error)" -eq 1 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
  ok "a pull-request URL ending in a newline is refused, not trimmed into a valid one"
else
  fail "a trailing newline was stripped before the whole-field check saw it (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# Codex gate, [medium]: a session whose outputs cannot be read is not a session
# with no pull request. Recording no-pr would be terminal, and the real outcome
# would never be looked at again.
new_case
routine alpha false 'repos: all'
session_line 950 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
session_state 950 '{"name":"sessions/950","state":"COMPLETED","outputs":"not-an-array"}'
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_count)" -eq 0 ]] && outgrep "unreadable outputs"; then
  ok "a COMPLETED session with unreadable outputs is a retryable failure, not a no-pr record"
else
  fail "an unreadable outputs value was recorded as 'no pull request' (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"
fi

# A session with more than one pull request gets ONE ledger record carrying all
# of them, so "settled" is a single atomic fact rather than a line per PR.
new_case
routine alpha false 'repos: all'
session_line 951 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
printf '{"name":"sessions/951","state":"COMPLETED","outputs":[{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9511"}},{"pullRequest":{"url":"https://github.com/jckeen/dotfiles/pull/9512"}}]}\n' \
  > "$CASE_DIR/session-951.json"
pr_fixture 9511 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
pr_fixture 9512 '{"state":"MERGED","changedFiles":3,"title":"fix(docs): two","labels":[]}'
if recon_run && [[ "$(reconcile_count)" -eq 1 ]] \
  && [[ "$(reconcile_jq -r '.[0].prs | length')" -eq 2 ]] \
  && [[ "$(reconcile_jq -r '.[0].action')" == "closed-empty+noop" ]]; then
  ok "a session with two pull requests is settled by one ledger record naming both"
else
  fail "a multi-PR session was not settled by a single record"
  sed 's/^/      | /' "$CASE_DIR/out"
  cat "$STATE/dispatch.jsonl" | sed 's/^/      | /'
fi

# The routine name comes back out of the ledger, where nothing has revalidated
# it since the catalog parser saw it. It becomes a label and a commit scope, so
# it is checked again rather than trusted — a ledger is a file an operator can
# edit, and a scope outside [a-z0-9._/-] would produce a title the commit-format
# check still rejects.
new_case
routine alpha false 'repos: all'
printf '{"dispatched_at":"2026-09-09T12:00:00Z","date":"2026-09-09","routine":"Bad Name","repo":"jckeen/dotfiles","source":"s","status":"created","attempt":"a944","session":"sessions/944","url":""}\n' \
  > "$STATE/dispatch.jsonl"
completed_with_pr 944 https://github.com/jckeen/dotfiles/pull/944
recon_run; rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(reconcile_action error)" -eq 1 ]] && [[ ! -s "$FAKE_GH_ARGV" ]]; then
  ok "a ledger routine name outside [a-z0-9-] is refused before it becomes a label or a scope"
else
  fail "an unvalidated routine name reached gh (rc=$rc)"
  sed 's/^/      | /' "$CASE_DIR/out"; sed 's/^/      > /' "$FAKE_GH_ARGV"
fi

# status.json is what the hooks and the status line read, so the pass has to
# show up there too.
new_case
routine alpha false 'repos: all'
session_line 943 alpha jckeen/dotfiles 1 > "$STATE/dispatch.jsonl"
completed_with_pr 943 https://github.com/jckeen/dotfiles/pull/943
pr_fixture 943 '{"state":"OPEN","changedFiles":0,"title":"Routine: alpha - clean run","labels":[]}'
if recon_run \
  && [[ "$(jq -r '.reconcile.checked' "$STATE/status.json")" == "1" ]] \
  && [[ "$(jq -r '.reconcile.closed_empty' "$STATE/status.json")" == "1" ]] \
  && [[ "$(jq -r '.reconcile.failures' "$STATE/status.json")" == "0" ]]; then
  ok "status.json carries the reconcile counts"
else
  fail "status.json has no reconcile counts"
  cat "$STATE/status.json" 2>/dev/null | sed 's/^/      | /'
fi

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
