#!/usr/bin/env bash
# handoff-reminder.test.sh — fixture tests for claude/hooks/HandoffReminder.hook.sh.
# The hook names the newest recent handoff note for the current project. Stock
# macOS find has no GNU -maxdepth, and the hook hides find's errors, so a
# -maxdepth lookup silently never fired there (issue #700). Every case runs
# with a find shim on PATH that rejects -maxdepth the way BSD find does.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
HOOK="$SCRIPT_DIR/../../hooks/HandoffReminder.hook.sh"

pass=0
failed=0
check() {
  if [ "$2" -eq 1 ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $1" >&2
    failed=$((failed + 1))
  fi
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# A find that refuses GNU's -maxdepth primary, as stock macOS find does.
SHIM="$FIX/bin"
mkdir -p "$SHIM"
REAL_FIND="$(command -v find)"
cat > "$SHIM/find" <<FAKE
#!/bin/bash
for a in "\$@"; do
  case "\$a" in -maxdepth|-mindepth) echo "find: \$a: unknown primary or operator" >&2; exit 1 ;; esac
done
exec "$REAL_FIND" "\$@"
FAKE
chmod +x "$SHIM/find"

# The project is the basename of the working directory (not a git repo here).
H="$FIX/home"
P="$FIX/work/demo-proj"
D="$H/.claude/handoffs"
mkdir -p "$D" "$P"
run_hook() { (cd "$P" && HOME="$H" PATH="$SHIM:$PATH" GIT_CEILING_DIRECTORIES="$FIX" "$HOOK" 2>&1); }

# No notes: silent, exit 0.
out="$(run_hook)"; rc=$?
check "no handoff: exits 0 and prints nothing" "$([ "$rc" -eq 0 ] && [ -z "$out" ] && echo 1 || echo 0)"

# Two recent notes for this project, one for another project, one too old.
printf 'old\n' > "$D/2026-10-01-demo-proj-handoff.md"
printf 'a\n' > "$D/2026-10-17-demo-proj-handoff.md"
printf 'b\n' > "$D/2026-10-18-demo-proj-handoff.md"
printf 'x\n' > "$D/2026-10-19-other-proj-handoff.md"
touch -t 200001010000 "$D/2026-10-01-demo-proj-handoff.md"
# The two recent notes, oldest first, so the newer name is also newer by mtime.
touch "$D/2026-10-17-demo-proj-handoff.md"
sleep 1
touch "$D/2026-10-18-demo-proj-handoff.md"
out="$(run_hook)"; rc=$?
check "newest handoff named despite a find without -maxdepth" \
  "$([ "$rc" -eq 0 ] && grep -qF "A recent handoff note exists for this project: $D/2026-10-18-demo-proj-handoff.md" <<<"$out" && echo 1 || echo 0)"
check "the read-it line follows" \
  "$(grep -qF 'If this session resumes that work, read the note before starting.' <<<"$out" && echo 1 || echo 0)"
check "another project's note is never named" "$(! grep -q other-proj <<<"$out" && echo 1 || echo 0)"

# Only a note older than the 7-day window: silent.
rm "$D/2026-10-17-demo-proj-handoff.md" "$D/2026-10-18-demo-proj-handoff.md"
out="$(run_hook)"; rc=$?
check "a note older than 7 days is not surfaced" "$([ "$rc" -eq 0 ] && [ -z "$out" ] && echo 1 || echo 0)"

# A note nested one level down is out of scope (one directory only).
mkdir -p "$D/archive"
printf 'n\n' > "$D/archive/2026-10-19-demo-proj-handoff.md"
out="$(run_hook)"
check "a note in a subdirectory is not surfaced" "$([ -z "$out" ] && echo 1 || echo 0)"

echo "handoff-reminder: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
