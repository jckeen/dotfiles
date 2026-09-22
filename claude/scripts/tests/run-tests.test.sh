#!/usr/bin/env bash
# run-tests.test.sh — fixture tests for run-tests.sh.
# Builds throwaway git repos under mktemp, copies the runner in so its
# self-resolved REPO_ROOT (SCRIPT_DIR/../..) lands on the fixture, writes fake
# suites, and asserts exit code + output fragments. Nothing here runs the real
# repo's suites — the runner is driven over fixtures only, so the file stays
# cheap enough to sit in the same CI shard as its subject.
# Mirrors check-tests-wired.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
RUNNER="$SCRIPT_DIR/../run-tests.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""
OUT=""
RC=0

# new_repo — fresh git fixture with the runner copied to claude/scripts/ so it
# resolves REPO_ROOT to the fixture root. One commit on `main` so a --changed
# base ref exists.
new_repo() {
  R="$(mktemp -d)"
  mkdir -p "$R/claude/scripts/tests"
  cp "$RUNNER" "$R/claude/scripts/run-tests.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/run-tests.sh"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
}

# suite <name> <exit code> — a shell suite that prints a marker and exits.
suite() {
  printf '#!/usr/bin/env bash\necho "ran %s"\nexit %s\n' "$1" "$2" \
    > "$R/claude/scripts/tests/$1.test.sh"
  chmod +x "$R/claude/scripts/tests/$1.test.sh"
}

# pysuite <name> <exit code> — a Python suite, so the interpreter choice is
# exercised rather than assumed.
pysuite() {
  printf 'import sys\nprint("ran %s")\nsys.exit(%s)\n' "$1" "$2" \
    > "$R/claude/scripts/tests/$1.test.py"
}

# subject <path> — a tracked file under claude/scripts/ the mapping can find.
subject() {
  mkdir -p "$R/$(dirname "$1")"
  printf '# subject\n' > "$R/$1"
}

commit_all() {
  git -C "$R" add -A
  git -C "$R" commit -qm "fixture"
}

# pyshim <exit code> — put a python3 on PATH whose `import hypothesis` probe
# exits with <exit code> and which delegates every other invocation to the real
# interpreter, so the optional-dependency cases below do not depend on whether
# this machine happens to have Hypothesis installed.
pyshim() {
  local rc="$1" real
  real="$(command -v python3)"
  mkdir -p "$R/bin"
  cat > "$R/bin/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$2" = "import hypothesis" ]; then exit $rc; fi
exec "$real" "\$@"
EOF
  chmod +x "$R/bin/python3"
}

# run [args...] — invoke the fixture's runner from the fixture root, with the
# fixture's own bin/ ahead of PATH so pyshim takes effect when a case set one.
run() {
  OUT="$(cd "$R" && PATH="$R/bin:$PATH" ./claude/scripts/run-tests.sh "$@" 2>&1)"
  RC=$?
}

# want <name> <expected exit> <extended regex>... — exit code plus every pattern.
want() {
  local name="$1" wantrc="$2"
  shift 2
  local ok=1 pat
  [ "$RC" -eq "$wantrc" ] || ok=0
  for pat in "$@"; do
    grep -qE -- "$pat" <<<"$OUT" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$wantrc and $*; got rc=$RC)"
    sed 's/^/      | /' <<<"$OUT"
  fi
}

# want_absent <name> <extended regex> — the output must not match.
want_absent() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" <<<"$OUT"; then
    failed=$((failed + 1))
    echo "FAIL - $name (unexpected match '$pat'; rc=$RC)"
    sed 's/^/      | /' <<<"$OUT"
  else
    pass=$((pass + 1))
    echo "ok   - $name"
  fi
}

# ── Discovery ─────────────────────────────────────────────────────────
new_repo
suite alpha 0
pysuite beta 0
run --list
want "--list names every discovered suite" 0 '^alpha$' '^beta$'
want_absent "--list runs nothing" 'ran alpha'
rm -rf "$R"

# --list is applied after selection, so it is also how the --changed mapping is
# inspected without paying for a run.
new_repo
suite alpha 0
suite gamma 0
subject claude/scripts/alpha.sh
commit_all
echo '# touched' >> "$R/claude/scripts/alpha.sh"
run --list --changed --base main
want "--list --changed prints the selected suites only" 0 '^alpha$'
want_absent "--list --changed omits unselected suites" '^gamma$'
want_absent "--list --changed runs nothing" 'ran alpha'
rm -rf "$R"

# A repo with no suites at all is a broken invocation, not a green run: the
# wrapper's step 2 would otherwise report success having tested nothing.
new_repo
run
want "no suites found fails closed" 1 'no test suites found'
rm -rf "$R"

# Two files deriving one name (#518): foo.test.sh and foo.test.py both name
# `foo`, and a first-match lookup would silently run the wrong one for `foo` or
# for a --changed diff touching the second. Discovery refuses, naming both
# files, in every mode — before anything runs.
new_repo
suite foo 0
pysuite foo 0
suite alpha 0
commit_all
run --list
want "a duplicate suite name fails discovery" 1 'duplicate test suite name: foo' \
  'foo\.test\.sh' 'foo\.test\.py'
want_absent "a duplicate suite name lists nothing" '^alpha$'
run foo
want "selecting a duplicated name fails closed" 1 'duplicate test suite name: foo'
want_absent "selecting a duplicated name runs neither file" 'ran foo'
echo '# touched' >> "$R/claude/scripts/tests/foo.test.py"
run --changed --base main
want "--changed on the second duplicate fails closed" 1 'duplicate test suite name: foo'
want_absent "--changed on a duplicate runs nothing" 'ran '
rm -rf "$R"

# ── Running everything ────────────────────────────────────────────────
new_repo
suite alpha 0
suite gamma 1
pysuite beta 0
run
want "a failing suite fails the run and is named in the summary" 1 \
  'PASS[[:space:]]+alpha' 'PASS[[:space:]]+beta' 'FAIL[[:space:]]+gamma' \
  '2 passed, 1 failed' 'ran gamma'
want "the summary reports a wall time" 1 '[0-9]+s'
rm -rf "$R"

# Passing suites' output is withheld unless --verbose, so a green run is a
# readable summary rather than 40 suites of scrollback.
new_repo
suite alpha 0
run
want "a green run exits 0" 0 'PASS[[:space:]]+alpha' '1 passed, 0 failed'
want_absent "a passing suite's output is withheld by default" 'ran alpha'
run --verbose
want "--verbose streams a passing suite's output" 0 'ran alpha'
rm -rf "$R"

# ── Selecting a subset by name ────────────────────────────────────────
new_repo
suite alpha 0
suite gamma 1
run alpha
want "a named subset runs only that suite" 0 'PASS[[:space:]]+alpha'
want_absent "a named subset skips the others" 'gamma'
rm -rf "$R"

new_repo
suite alpha 0
run nosuchsuite
want "an unknown suite name fails closed" 1 'unknown test suite: nosuchsuite'
want_absent "an unknown suite name runs nothing" 'PASS'
rm -rf "$R"

# ── --changed ─────────────────────────────────────────────────────────
# A changed test file selects its own suite and nothing else.
new_repo
suite alpha 0
suite gamma 0
subject claude/scripts/alpha.sh
subject claude/scripts/gamma.sh
commit_all
echo '# touched' >> "$R/claude/scripts/tests/alpha.test.sh"
run --changed --base main
want "--changed selects the suite whose test file changed" 0 \
  'PASS[[:space:]]+alpha'
want_absent "--changed skips untouched suites" 'gamma'
rm -rf "$R"

# A suite may reuse another's fixtures (workflow-shipping-rewrites.test.py
# imports workflow-shipping.test.py), so a changed test file selects the suites
# that reference it too — otherwise a failure confined to the importing suite
# escapes the run.
new_repo
suite alpha 0
suite gamma 0
printf '#!/usr/bin/env bash\n# reuses claude/scripts/tests/alpha.test.sh fixtures\necho "ran beta"\n' \
  > "$R/claude/scripts/tests/beta.test.sh"
chmod +x "$R/claude/scripts/tests/beta.test.sh"
commit_all
echo '# touched' >> "$R/claude/scripts/tests/alpha.test.sh"
run --changed --base main
want "--changed also selects a suite that references the changed test file" 0 \
  'PASS[[:space:]]+alpha' 'PASS[[:space:]]+beta'
want_absent "--changed still skips suites with no reference" 'gamma'
rm -rf "$R"

# A changed subject script selects the suite that exercises it.
new_repo
suite alpha 0
suite gamma 0
subject claude/scripts/alpha.sh
subject claude/scripts/gamma.sh
commit_all
echo '# touched' >> "$R/claude/scripts/alpha.sh"
run --changed --base main
want "--changed maps a changed subject script to its suite" 0 \
  'PASS[[:space:]]+alpha'
want_absent "--changed does not select unrelated suites for a subject" 'gamma'
rm -rf "$R"

# A shared library is reached through its callers: no suite mentions gate-lib.sh
# directly, so the name scan follows non-test scripts too. Here alpha reaches
# helper.sh only via tool.sh, and gamma is unrelated.
new_repo
suite gamma 0
printf '#!/usr/bin/env bash\n# drives claude/scripts/tool.sh\necho "ran alpha"\n' \
  > "$R/claude/scripts/tests/alpha.test.sh"
chmod +x "$R/claude/scripts/tests/alpha.test.sh"
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/helper.sh"\n' > "$R/claude/scripts/tool.sh"
printf '# helper\n' > "$R/claude/scripts/helper.sh"
commit_all
echo '# touched' >> "$R/claude/scripts/helper.sh"
run --changed --base main
want "--changed follows a shared library through its callers" 0 \
  'PASS[[:space:]]+alpha'
want_absent "the transitive scan does not select everything" 'gamma'
rm -rf "$R"

# The traversal corpus is every tracked non-test file, not a curated glob: the
# installer lives at the repo ROOT and sources a root-level library, so a
# corpus of claude/scripts/ alone left the installer suites out of an
# installer-library change.
new_repo
suite gamma 0
printf '#!/usr/bin/env bash\n# drives installer.sh\necho "ran alpha"\n' \
  > "$R/claude/scripts/tests/alpha.test.sh"
chmod +x "$R/claude/scripts/tests/alpha.test.sh"
printf '#!/usr/bin/env bash\nsource "$DOTFILES_DIR/helper-lib.sh"\n' > "$R/installer.sh"
printf '# helper\n' > "$R/helper-lib.sh"
commit_all
echo '# touched' >> "$R/helper-lib.sh"
run --changed --base main
want "--changed traverses root-level scripts too" 0 'PASS[[:space:]]+alpha'
want_absent "root-level traversal does not select everything" 'gamma'
rm -rf "$R"

# The walk runs to a fixpoint, not to a depth limit: a chain longer than any
# fixed bound still reaches the suite at its end, and a truncated walk would
# have narrowed the run silently because other suites had already matched.
new_repo
suite gamma 0
printf '#!/usr/bin/env bash\n# drives d.sh\necho "ran alpha"\n' \
  > "$R/claude/scripts/tests/alpha.test.sh"
chmod +x "$R/claude/scripts/tests/alpha.test.sh"
printf '# uses helper.sh\n' > "$R/claude/scripts/a.sh"
printf '# uses a.sh\n' > "$R/claude/scripts/b.sh"
printf '# uses b.sh\n' > "$R/claude/scripts/c.sh"
printf '# uses c.sh\n' > "$R/claude/scripts/d.sh"
printf '# helper\n' > "$R/claude/scripts/helper.sh"
commit_all
echo '# touched' >> "$R/claude/scripts/helper.sh"
run --changed --base main
want "--changed follows a dependency chain past any fixed depth" 0 \
  'PASS[[:space:]]+alpha'
want_absent "the fixpoint walk still does not select everything" 'gamma'
rm -rf "$R"

# A matched suite hands its own filename on, so a suite that imports ANOTHER
# suite is reached through it — not only when the imported suite is itself the
# changed file.
new_repo
suite gamma 0
printf '#!/usr/bin/env bash\n# drives helper.sh\necho "ran alpha"\n' \
  > "$R/claude/scripts/tests/alpha.test.sh"
printf '#!/usr/bin/env bash\n# reuses claude/scripts/tests/alpha.test.sh fixtures\necho "ran beta"\n' \
  > "$R/claude/scripts/tests/beta.test.sh"
chmod +x "$R/claude/scripts/tests/alpha.test.sh" "$R/claude/scripts/tests/beta.test.sh"
printf '# helper\n' > "$R/claude/scripts/helper.sh"
commit_all
echo '# touched' >> "$R/claude/scripts/helper.sh"
run --changed --base main
want "a suite that imports a matched suite is selected too" 0 \
  'PASS[[:space:]]+alpha' 'PASS[[:space:]]+beta'
want_absent "suite-to-suite traversal does not select everything" 'gamma'
rm -rf "$R"

# EVERY changed path must reach a suite on its own: one mappable path must not
# speak for an unmapped sibling.
new_repo
suite alpha 0
suite gamma 0
subject claude/scripts/alpha.sh
printf 'see thing.conf for details\n' > "$R/NOTES.md"
printf 'setting = 1\n' > "$R/thing.conf"
commit_all
echo '# touched' >> "$R/claude/scripts/alpha.sh"
echo 'setting = 2' >> "$R/thing.conf"
run --changed --base main
want "an unmapped sibling path widens the whole run" 0 \
  'cannot attribute' 'PASS[[:space:]]+alpha' 'PASS[[:space:]]+gamma'
rm -rf "$R"

# The mapping is a heuristic, so anything it cannot attribute runs everything:
# a narrowed selection must never be the silent consequence of an unknown path.
new_repo
suite alpha 0
suite gamma 0
commit_all
mkdir -p "$R/some/other"
printf 'x\n' > "$R/some/other/thing.conf"
run --changed --base main
want "an unmappable change falls back to every suite" 0 \
  'cannot attribute' 'PASS[[:space:]]+alpha' 'PASS[[:space:]]+gamma'
rm -rf "$R"

# A DELETED suite is an unmappable path, not a path that maps to nothing: a
# branch that removes one suite while touching another mappable file would
# otherwise narrow the run to the survivor.
new_repo
suite alpha 0
suite gamma 0
subject claude/scripts/alpha.sh
commit_all
rm "$R/claude/scripts/tests/gamma.test.sh"
echo '# touched' >> "$R/claude/scripts/alpha.sh"
run --changed --base main
want "a deleted suite widens the run instead of narrowing it" 0 \
  'cannot attribute' 'PASS[[:space:]]+alpha' '1 of 1 test suites'
rm -rf "$R"

# A RENAMED suite must widen too: with Git's rename detection on, the diff would
# name only the destination, and a suite still referencing the old filename would
# be left out of the run with its import already broken.
new_repo
suite alpha 0
suite gamma 0
commit_all
git -C "$R" mv claude/scripts/tests/gamma.test.sh claude/scripts/tests/delta.test.sh
run --changed --base main
want "a renamed suite widens the run" 0 \
  'cannot attribute' 'PASS[[:space:]]+alpha' 'PASS[[:space:]]+delta'
rm -rf "$R"

# Nothing changed is not "nothing to run".
new_repo
suite alpha 0
suite gamma 0
commit_all
run --changed --base main
want "no changes falls back to every suite" 0 \
  'PASS[[:space:]]+alpha' 'PASS[[:space:]]+gamma'
rm -rf "$R"

# An unresolvable base (no origin/main in a fresh clone, no network) must widen
# the run rather than quietly narrow it.
new_repo
suite alpha 0
suite gamma 0
commit_all
run --changed --base no/such/ref
want "an unresolvable base falls back to every suite" 0 \
  'cannot resolve' 'PASS[[:space:]]+alpha' 'PASS[[:space:]]+gamma'
rm -rf "$R"

# ── Optional dependency ───────────────────────────────────────────────
# The *.property.test.py suites import Hypothesis unconditionally and exit with
# an install command rather than skipping. A fresh clone has no Hypothesis, and
# a runner that reported that as a failure would make every local push red; the
# runner probes for the module instead and reports a named SKIP.
new_repo
pysuite delta.property 0
pyshim 1
run
want "a missing property-suite dependency is a named skip, not a failure" 0 \
  'SKIP[[:space:]]+delta\.property' '0 passed, 0 failed, 1 skipped' \
  'requirements-property\.txt'
want_absent "a skipped property suite is not executed" 'ran delta.property'
rm -rf "$R"

# With the module present the suite runs, and a failure is a failure.
new_repo
pysuite epsilon.property 1
pyshim 0
run
want "a property suite whose dependency is present still fails on failure" 1 \
  'FAIL[[:space:]]+epsilon\.property' '0 passed, 1 failed' 'ran epsilon.property'
rm -rf "$R"

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
