#!/usr/bin/env bash
# install-integrity.test.sh — fixture tests for check-install-integrity.sh.
# Builds throwaway git repos under mktemp, forces index modes with
# `git update-index --chmod`, runs the checker, asserts exit code + an output
# fragment. Run directly; exit 1 on any failure. Mirrors doc-truth.test.sh.
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
CHECKER="$SCRIPT_DIR/../check-install-integrity.sh"

pass=0
failed=0
R=""

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
}

# check <name> <expected-exit> [<required output fragment>]
# Assumes files are already staged with the intended index modes.
check() {
  local name="$1" want="$2" frag="${3:-}"
  local out rc
  out="$(cd "$R" && "$CHECKER" 2>&1)"
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
  rm -rf "$R"
}

# Minimal setup.sh whose marketplace case knows exactly one marketplace.
setup_with_arm() {
  cat > "$R/setup.sh" <<'EOF'
#!/usr/bin/env bash
case "$mp" in
  known-mp)
    claude plugin marketplace add github:x/y ;;
  *)
    echo "Unknown marketplace $mp" ;;
esac
EOF
}

# --- Check 1: exec bits ------------------------------------------------------

# 1a: shebanged *.sh executable → OK
new_repo
printf '#!/usr/bin/env bash\necho hi\n' > "$R/tool.sh"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=+x tool.sh
check "exec-bit: shebanged +x passes" 0 "OK"

# 1b: shebanged *.sh NOT executable → FAIL
new_repo
printf '#!/usr/bin/env bash\necho hi\n' > "$R/tool.sh"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=-x tool.sh
check "exec-bit: shebanged non-exec fails" 1 "FAIL(exec-bit)"

# 1c: *.sh WITHOUT shebang, non-exec → OK (not a runnable script)
new_repo
printf 'name = value\n' > "$R/config.sh"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=-x config.sh
check "exec-bit: no-shebang non-exec is ignored" 0 "OK"

# --- Check 2: marketplace arms ----------------------------------------------

# 2a: plugin whose marketplace has an arm → OK
# Stage everything first, THEN set the exec bit — a later `git add` re-stages
# from disk and would reset the mode (core.fileMode=false hides the disk bit).
new_repo
setup_with_arm
mkdir -p "$R/claude"
printf 'someplugin@known-mp\n' > "$R/claude/plugins.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=+x setup.sh
check "marketplace: referenced arm present passes" 0 "OK"

# 2b: plugin whose marketplace has NO arm → FAIL
new_repo
setup_with_arm
mkdir -p "$R/claude"
printf 'someplugin@known-mp\notherplugin@missing-mp\n' > "$R/claude/plugins.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=+x setup.sh
check "marketplace: missing arm fails" 1 "FAIL(marketplace)"

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
