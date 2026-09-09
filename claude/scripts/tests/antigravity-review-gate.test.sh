#!/usr/bin/env bash
# antigravity-review-gate.test.sh — fixture tests for antigravity-review-gate.sh.
# Builds throwaway git repos under mktemp and stubs `agy` with a PATH shim that
# captures argv + stdin and emits crafted output, so the gate's verdict parsing,
# fail-closed base handling, and no-diff-in-argv delivery (#152/#153/#154) are
# asserted without spending plan quota. Run directly; exit 1 on any failure.
# Mirrors install-integrity.test.sh.
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
GATE="$SCRIPT_DIR/../antigravity-review-gate.sh"

pass=0
failed=0
R=""

# One PATH shim for the whole run; per-test capture dir via AGY_FAKE_DIR.
# The shim replays $AGY_FAKE_DIR/output and records how it was called, so tests
# can assert both the gate's exit behavior and the prompt-delivery channel.
# It emulates agy 1.1.1 prompt semantics (#227): a prompt flag with an EMPTY
# value errors out ("empty prompt") WITHOUT reading stdin, a non-empty prompt
# flag suppresses the stdin read, and stdin is consumed only when no prompt
# flag is present — so a gate that regresses to the pre-1.1.1 `--print ""`
# form fails these tests the same way it fails against the real binary.
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGY_FAKE_DIR/argv"
touch "$AGY_FAKE_DIR/invoked"
[ ! -f "$AGY_FAKE_DIR/mutate" ] || bash "$AGY_FAKE_DIR/mutate"
# Go's flag package treats -print/--print/-p and the =value forms as the same
# flag, so the emulation must too (adversarial review of PR #243: an equals or
# single-dash spelling regression must not pass the suite).
have_prompt_flag=0 prompt_value="" expect_value=0
for a in "$@"; do
  if [ "$expect_value" = 1 ]; then prompt_value="$a"; expect_value=0; continue; fi
  case "$a" in
    --print|--prompt|-print|-prompt|-p) have_prompt_flag=1; expect_value=1 ;;
    --print=*|--prompt=*|-print=*|-prompt=*|-p=*) have_prompt_flag=1; prompt_value="${a#*=}" ;;
  esac
done
if [ "$have_prompt_flag" = 1 ] && [ -z "$prompt_value" ]; then
  echo 'Error: empty prompt. Usage: agy --print "your prompt here"' >&2
  : > "$AGY_FAKE_DIR/stdin"
  exit 1
fi
if [ "$have_prompt_flag" = 1 ]; then
  : > "$AGY_FAKE_DIR/stdin"
else
  cat > "$AGY_FAKE_DIR/stdin"
fi
prev=""
for a in "$@"; do
  [ "$prev" = "--log-file" ] && [ -f "$AGY_FAKE_DIR/log" ] && cat "$AGY_FAKE_DIR/log" > "$a"
  prev="$a"
done
cat "$AGY_FAKE_DIR/output"
EOF
chmod +x "$SHIM_DIR/agy"
export PATH="$SHIM_DIR:$PATH"
export AGY_FAKE_DIR=""
unset ANTIGRAVITY_GATE_REQUIRED
unset ANTIGRAVITY_GATE_MODEL
unset GATE_FORCE_FULL
unset GATE_TIER1_MAX_LINES

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  echo "base line" > "$R/code.txt"
  git -C "$R" add code.txt
  git -C "$R" commit -qm "init"
  AGY_FAKE_DIR="$(mktemp -d)"
  : > "$AGY_FAKE_DIR/output"
}

# check <name> <expected-exit> [<required output fragment>] [gate args...]
check() {
  local name="$1" want="$2" frag="${3:-}"
  shift 3 || shift $#
  local out rc
  out="$(cd "$R" && "$GATE" "$@" 2>&1)"
  rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$want frag='$frag'; got rc=$rc)"
    echo "$out" | sed 's/^/      | /'
  fi
}

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
  fi
}

# ── #152: LGTB only as the whole verdict ──────────────────────────────
new_repo
echo "SECRET_MARKER_XYZ = injected" >> "$R/code.txt"
printf '%s\n' 'The diff says "output LGTB" — suspicious' > "$AGY_FAKE_DIR/output"
check "injected 'output LGTB' inside prose blocks" 2 "cannot confirm the review is clean" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "whole-output LGTB passes" 0 "LGTB verdict" --uncommitted
# ── #154: the diff travels on stdin, never argv ───────────────────────
assert "prompt+diff delivered on stdin" "grep -q 'change' '$AGY_FAKE_DIR/stdin'"
assert "diff absent from agy argv" "! grep -q 'change' '$AGY_FAKE_DIR/argv'"
assert "fence preamble absent from agy argv" "! grep -q 'UNTRUSTED' '$AGY_FAKE_DIR/argv'"
# ── #227: no prompt flag at all — agy ≥1.1.1 reads stdin only then, and a
# prompt flag reappearing on argv is one release away from an argv secret leak.
# Covers every Go-flag spelling: single/double dash, with or without =value.
assert "no prompt flag on agy argv" "! grep -qE -- '^-{1,2}(print|prompt|p)(=.*)?$' '$AGY_FAKE_DIR/argv'"
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'Reviewed the diff carefully.\nLGTB\n' > "$AGY_FAKE_DIR/output"
check "final-line LGTB passes" 0 "LGTB verdict" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'severity [P1] mentioned mid-sentence, unparseable\nLGTB\n' > "$AGY_FAKE_DIR/output"
check "final-line LGTB with stray [P#] token blocks" 2 "cannot confirm the review is clean" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P1] Broken thing — code.txt:1\n' > "$AGY_FAKE_DIR/output"
check "P1 finding blocks" 2 "BLOCKING findings" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P3] Nit — code.txt:1\n' > "$AGY_FAKE_DIR/output"
check "P3-only does not block" 0 "clean of blocking findings" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P3] minor nit — code.txt:1\nthis is really a [P1] in disguise\n' > "$AGY_FAKE_DIR/output"
check "prose [P1] alongside a valid P3 line blocks" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

# ── #205: post-dispatch model-pin verification ────────────────────────
# The propagation line format matches agy 1.1.1's model_config_manager log.
# The fake conversation records are plain text files — `strings` reads them.
PROP_OK='I0710 model_config_manager.go:157] Propagating selected model override to backend: label="Gemini 3.1 Pro (High)"'
PROP_BAD='I0710 model_config_manager.go:157] Propagating selected model override to backend: label="Gemini 3.5 Flash (Low)"'

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
AGY_DB_DIR="$(mktemp -d)"
printf 'gen_metadata: Gemini 3.1 Pro (High) gemini-pro-agent\n' > "$AGY_DB_DIR/conv.db"
export AGY_CONVERSATIONS_DIR="$AGY_DB_DIR"
check "propagated label matches the default pin" 0 "model pin verified" --uncommitted
assert "pinned label forwarded on agy argv" "grep -q 'Gemini 3.1 Pro (High)' '$AGY_FAKE_DIR/argv'"
assert "log capture requested on agy argv" "grep -q -- '--log-file' '$AGY_FAKE_DIR/argv'"
check "DB spot-check finds the label in the records" 0 "records the requested label" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R" "$AGY_DB_DIR"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_BAD" > "$AGY_FAKE_DIR/log"
check "propagated-label mismatch fails hard WITHOUT --require" 2 "MODEL PIN FAILED" --uncommitted
check "propagated-label mismatch fails hard with an explicit --model" 2 "MODEL PIN FAILED" --uncommitted --model "Gemini 3.1 Pro (High)"
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s session=42 retry=false\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "trailing fields after the quoted label still verify" 0 "model pin verified" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export AGY_CONVERSATIONS_DIR="$R/does-not-exist"
check "missing propagation line degrades to a warning" 0 "MODEL PIN UNVERIFIED" --uncommitted
check "missing propagation line fails hard with --require" 3 "MODEL PIN UNVERIFIED" --uncommitted --require
unset AGY_CONVERSATIONS_DIR
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
export AGY_CONVERSATIONS_DIR="$R/does-not-exist"
check "absent conversation records degrade to a warning" 0 "cannot confirm the recorded model" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
AGY_DB_DIR="$(mktemp -d)"
printf 'gen_metadata: gemini-default flash only\n' > "$AGY_DB_DIR/conv.db"
export AGY_CONVERSATIONS_DIR="$AGY_DB_DIR"
check "DB spot-check miss is a warning, never a block" 0 "DB spot-check is best-effort" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R" "$AGY_DB_DIR"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export ANTIGRAVITY_GATE_MODEL=""
check "empty ANTIGRAVITY_GATE_MODEL disables pinning" 0 "LGTB verdict" --uncommitted
unset ANTIGRAVITY_GATE_MODEL
assert "no --model on agy argv when pinning is disabled" "! grep -q -- '--model' '$AGY_FAKE_DIR/argv'"
rm -rf "$R"

# ── #153: unresolvable base fails closed, without invoking agy ────────
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
check "unresolvable --base fails closed" 2 "could not be resolved" --base does-not-exist
assert "agy not invoked on unresolvable base" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# ── #212: proportionality valve ────────────────────────────────────────
new_repo
printf '# Title\n\nDocs only.\n' > "$R/README.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "docs-only small diff takes the tier-1 skip" 0 "tier-1 skip" --uncommitted
assert "agy not invoked on a tier-1 skip" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf '# Title\n' > "$R/README.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export GATE_FORCE_FULL=1
check "GATE_FORCE_FULL=1 forces the full pass on a docs-only diff" 0 "LGTB verdict" --uncommitted
unset GATE_FORCE_FULL
assert "agy invoked under GATE_FORCE_FULL" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf 'notes about rotation\n' > "$R/token-rotation.md"
printf -- '- [P1] Broken thing — token-rotation.md:1\n' > "$AGY_FAKE_DIR/output"
check "risk-surface filename escalates to the full pass (and still blocks)" 2 "BLOCKING findings" --uncommitted
rm -rf "$R"

new_repo
printf 'small change\n' > "$R/widget.xyz"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "unclassified file escalates to the full pass" 0 "LGTB verdict" --uncommitted
assert "agy invoked for the unclassified diff" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# Rename laundering: `git mv risk.sh notes.md` must NOT classify as docs-only —
# --no-renames lists both sides, and the source path escalates.
new_repo
mkdir -p "$R/claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$R/claude/hooks/pre-push-guard.sh"
git -C "$R" add claude/hooks/pre-push-guard.sh
git -C "$R" commit -qm "add guard"
git -C "$R" mv claude/hooks/pre-push-guard.sh notes.md
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "renaming a risk surface to .md still takes the full pass" 0 "LGTB verdict" --uncommitted
assert "agy invoked for the rename-laundered diff" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

echo ""
new_repo
echo change >> "$R/code.txt"
printf '%s\n' '- [P3] nit; [P1] auth bypass — code.txt:1' > "$AGY_FAKE_DIR/output"
awk 'BEGIN { for (i=0; i<2000; i++) printf "- [P3] %0200d — code.txt:1\n", i }' >> "$AGY_FAKE_DIR/output"
check "long output cannot SIGPIPE away an embedded priority" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

new_repo
echo change >> "$R/code.txt"
printf '%s\n' '- [P3] nit; [P1] authentication bypass — code.txt:1' > "$AGY_FAKE_DIR/output"
check "embedded P1 on a recognized P3 line blocks" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
echo steer > "$R/GEMINI.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "dirty Gemini instructions block committed review" 2 "instruction surface"
assert "dirty Gemini instructions never dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
printf 'git commit --allow-empty -qm concurrent\n' > "$AGY_FAKE_DIR/mutate"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "Antigravity rejects concurrent HEAD change" 2 "changed during review" --require
rm -rf "$R"

# The alternate lane must receive instruction bytes even with passive suffixes.
for active_path in .codex/policy.lock .claude/hooks/check.lock LICENSE.py; do
  for scope in committed uncommitted; do
    new_repo
    git -C "$R" checkout -qb feature
    mkdir -p "$R/$(dirname "$active_path")"
    printf '#!/usr/bin/env python3\nprint("ACTIVE_REVIEW_MARKER")\n' > "$R/$active_path"
    chmod +x "$R/$active_path"
    if [[ "$scope" == committed ]]; then
      git -C "$R" add "$active_path"
      git -C "$R" commit -qm 'active change with exempt filename'
    fi
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    check "$scope $active_path requires alternate review" 0 "LGTB verdict" "--$scope" --require
    assert "active content reaches alternate reviewer" "grep -q 'ACTIVE_REVIEW_MARKER' '$AGY_FAKE_DIR/stdin'"
    assert "active receipt records actual alternate review" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
    rm -rf "$R"
  done
done

for pathspec_setting in literal conflicting; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/.codex"
  printf 'PATHSPEC_ALTERNATE_MARKER\n' > "$R/.codex/config.toml"
  git -C "$R" add .codex/config.toml
  git -C "$R" commit -qm 'pathspec environment fixture'
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  if [[ "$pathspec_setting" == literal ]]; then
    export GIT_LITERAL_PATHSPECS=1
  else
    export GIT_GLOB_PATHSPECS=1 GIT_NOGLOB_PATHSPECS=1
  fi
  check "$pathspec_setting environment still dispatches alternate review" 0 "LGTB verdict" --committed --require
  assert "pathspec environment preserves alternate prompt bytes" "grep -q 'PATHSPEC_ALTERNATE_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "pathspec environment cannot exempt alternate review" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
  rm -rf "$R"
done

for suffix in ' ' $'\n'; do
  new_repo
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam 'twin repository fixture'
  sibling="$R"
  R="$R$suffix"
  cp -a "$sibling" "$R"
  printf 'TWIN_ALTERNATE_MARKER\n' > "$R/code.txt"
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "whitespace twin reviews its own alternate workspace" 0 "LGTB verdict" --uncommitted --require
  assert "whitespace twin bytes reach alternate reviewer" "grep -q 'TWIN_ALTERNATE_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "whitespace twin cannot create sibling alternate receipt" "[ ! -e '$sibling/.git/review-receipts/antigravity.json' ]"
  printf 'dirty twin instructions\n' > "$R/AGENTS.md"
  rm -f "$AGY_FAKE_DIR/invoked"
  check "whitespace twin blocks alternate committed review" 2 "dirty instruction surface" --committed --require
  assert "whitespace twin dirty instructions prevent alternate dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
  rm -rf "$R" "$sibling"
done

new_repo
echo source-directory >> "$R/code.txt"
copied_scripts="$SHIM_DIR/scripts"$'\n'
mkdir -p "$copied_scripts"
cp "$SCRIPT_DIR/../antigravity-review-gate.sh" "$SCRIPT_DIR/../gate-lib.sh" "$SCRIPT_DIR/../review-receipt.py" "$copied_scripts/"
original_gate="$GATE"
GATE="$copied_scripts/antigravity-review-gate.sh"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "alternate gate source directory preserves trailing newline" 0 "LGTB verdict" --uncommitted --require
assert "alternate gate from newline directory dispatches" "grep -q 'source-directory' '$AGY_FAKE_DIR/stdin'"
GATE="$original_gate"
rm -rf "$R"

for checkout_state in staged-mode crlf sparse; do
  new_repo
  args=(--committed --require)
  case "$checkout_state" in
    staged-mode)
      printf 'before\n' > "$R/image.png"
      git -C "$R" add image.png
      git -C "$R" commit -qm 'regular file'
      git -C "$R" config core.filemode false
      git -C "$R" update-index --chmod=+x image.png
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/image.png"
      git -C "$R" add image.png
      args=(--uncommitted --require)
      ;;
    crlf)
      printf 'Known instructions.\n' > "$R/AGENTS.md"
      git -C "$R" add AGENTS.md
      git -C "$R" commit -qm 'instructions'
      git -C "$R" config core.autocrlf true
      rm "$R/AGENTS.md"
      git -C "$R" checkout -- AGENTS.md
      git -C "$R" checkout -qb feature
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/code.txt"
      git -C "$R" commit -qam 'code change'
      ;;
    sparse)
      mkdir -p "$R/docs" "$R/src"
      printf 'Known instructions.\n' > "$R/docs/AGENTS.md"
      printf 'before\n' > "$R/src/code.txt"
      git -C "$R" add docs src
      git -C "$R" commit -qm 'sparse fixture'
      git -C "$R" sparse-checkout init --cone --sparse-index
      git -C "$R" sparse-checkout set src
      git -C "$R" checkout -qb feature
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/src/code.txt"
      git -C "$R" commit -qam 'code change'
      ;;
  esac
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$checkout_state reaches required alternate review" 0 "LGTB verdict" "${args[@]}"
  assert "native checkout state preserves alternate bytes" "grep -q 'NATIVE_STATE_REVIEW_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "native checkout state gets full alternate receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  rm -rf "$R"
done

for instruction in AGENTS.md .codex/config.toml .codex/cache/AGENTS.md; do
  for scope in explicit auto; do
    new_repo
    mkdir -p "$R/$(dirname "$instruction")"
    printf '%s\n' "$instruction" > "$R/.git/info/exclude"
    printf 'IGNORED_INSTRUCTION_MARKER\n' > "$R/$instruction"
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    args=(--require)
    [[ "$scope" != explicit ]] || args+=(--uncommitted)
    check "ignored $instruction receives $scope alternate review" 0 "LGTB verdict" "${args[@]}"
    assert "ignored instruction bytes reach alternate review" "grep -q 'IGNORED_INSTRUCTION_MARKER' '$AGY_FAKE_DIR/stdin'"
    rm -rf "$R"
  done
done

for instruction in .claude/commands/check.md .gemini/commands/check.md .agents/example/guide.md; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$instruction")"
  printf 'AGENT_DOCUMENT_MARKER\n' > "$R/$instruction"
  git -C "$R" add "$instruction"
  git -C "$R" commit -qm 'agent command documentation'
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "committed $instruction dispatches alternate review" 0 "LGTB verdict" --committed --require
  assert "agent document reaches alternate reviewer" "grep -q 'AGENT_DOCUMENT_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "agent document receives valid alternate receipt" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
  rm -rf "$R"
done

new_repo
echo change >> "$R/code.txt"
for private_path in .codex/auth.json .claude/.credentials.json .gemini/oauth_creds.json; do
  mkdir -p "$R/$(dirname "$private_path")"
  printf '%s\n' "$private_path" >> "$R/.git/info/exclude"
  printf '{"access_token":"SYNTHETIC_PRIVATE_CREDENTIAL_MARKER"}\n' > "$R/$private_path"
done
for instruction in .claude/settings.json .agents/example/SKILL.md .codex/cache/AGENTS.md; do
  mkdir -p "$R/$(dirname "$instruction")"
  printf '%s\n' "$instruction" >> "$R/.git/info/exclude"
  printf 'REVIEW_AGENT_CONFIG_MARKER\n' > "$R/$instruction"
done
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "ignored runtime credentials allow alternate review" 0 "LGTB verdict" --uncommitted --require
assert "ignored runtime credentials stay out of Antigravity stdin" "[ -s '$AGY_FAKE_DIR/stdin' ] && ! grep -q 'SYNTHETIC_PRIVATE_CREDENTIAL_MARKER' '$AGY_FAKE_DIR/stdin'"
assert "ignored agent config and skills still reach Antigravity" "grep -q 'REVIEW_AGENT_CONFIG_MARKER' '$AGY_FAKE_DIR/stdin' && grep -q '.claude/settings.json' '$AGY_FAKE_DIR/stdin' && grep -q '.agents/example/SKILL.md' '$AGY_FAKE_DIR/stdin' && grep -q '.codex/cache/AGENTS.md' '$AGY_FAKE_DIR/stdin'"
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
seq 1 250 > "$R/notes.md"
git -C "$R" add notes.md
git -C "$R" commit -qm docs
export GATE_TIER1_MAX_LINES=0500
check "configured docs cap issues alternate receipt" 0 "tier-1 skip" --require
assert "configured docs cap avoids alternate dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
assert "shipping accepts captured alternate cap" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
export GATE_TIER1_MAX_LINES=2
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "same committed docs above custom cap dispatch alternate review" 0 "LGTB verdict" --committed --require
assert "small custom cap invokes Antigravity" "[ -e '$AGY_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
rm -rf "$R"

R="$(mktemp -d)"
check "outside Git keeps advisory warning" 0 "not inside a git work tree"
check "outside Git blocks required review" 3 "treating as a hard failure" --require
rm -rf "$R"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
