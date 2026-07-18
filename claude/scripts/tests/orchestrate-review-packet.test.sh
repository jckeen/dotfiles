#!/usr/bin/env bash
# orchestrate-review-packet.test.sh — raw review packets stay scoped and safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REPO_ROOT/agents/skills/orchestrate/scripts/build_review_packet.py"

R="$(mktemp -d)" || exit 1
OUT="$(mktemp)" || exit 1
trap 'rm -rf "$R" "$OUT"' EXIT
pass=0
failed=0

ok() {
  pass=$((pass + 1))
  echo "ok   - $1"
}

fail() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  sed 's/^/      | /' "$OUT"
}

git -C "$R" init -q
git -C "$R" config user.email t@t.test
git -C "$R" config user.name test
printf 'before\n' > "$R/tracked.txt"
printf 'other before\n' > "$R/other.txt"
printf '*.dat diff=secret\n' > "$R/.gitattributes"
printf 'raw before\n' > "$R/converted.dat"
printf 'literal before\n' > "$R/[ab].txt"
printf 'a before\n' > "$R/a.txt"
printf 'b before\n' > "$R/b.txt"
printf '\000binary before\n' > "$R/asset.bin"
git -C "$R" add .gitattributes tracked.txt other.txt converted.dat \
  '[ab].txt' a.txt b.txt asset.bin
git -C "$R" commit -qm base
base="$(git -C "$R" rev-parse HEAD)"

printf 'after\n' >> "$R/tracked.txt"
printf 'other after\n' >> "$R/other.txt"
printf 'raw after\n' >> "$R/converted.dat"
printf 'literal after\n' >> "$R/[ab].txt"
printf 'a after\n' >> "$R/a.txt"
printf 'b after\n' >> "$R/b.txt"
printf '\000binary after\n' >> "$R/asset.bin"
printf 'never include me\n' > "$R/private-token.txt"
printf '#!/usr/bin/env bash\nprintf "TEXTCONV_SECRET\\n"\n' > "$R/textconv.sh"
chmod +x "$R/textconv.sh"
git -C "$R" config diff.secret.textconv "$R/textconv.sh"
git -C "$R" config color.ui always

if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'The tracked change preserves behavior.' \
  --repro 'git diff --check' \
  --verify 'bash tests/focused.test.sh' > "$OUT" 2>&1 \
  && grep -qF '# Adversarial Review Packet' "$OUT" \
  && grep -qF "$base" "$OUT" \
  && grep -qF 'The tracked change preserves behavior.' "$OUT" \
  && grep -qF 'git diff --check' "$OUT" \
  && grep -qF '+after' "$OUT" \
  && ! grep -qF 'private-token.txt' "$OUT" \
  && ! grep -qF 'never include me' "$OUT" \
  && ! grep -qF 'TEXTCONV_SECRET' "$OUT" \
  && ! grep -qF $'\033[' "$OUT"; then
  ok 'packet contains the tracked raw artifact without untracked data'
else
  fail 'packet did not preserve the scoped raw-evidence contract'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Only the requested path is in scope.' \
  --repro 'git diff -- tracked.txt' \
  --path tracked.txt > "$OUT" 2>&1 \
  && grep -qF '## Path scope' "$OUT" \
  && grep -qF 'tracked.txt' "$OUT" \
  && ! grep -qF 'other.txt' "$OUT"; then
  ok 'path filters keep unrelated tracked changes out of the packet'
else
  fail 'path filters did not bound the review artifact'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Bracketed route filenames remain literal scope.' \
  --repro 'git diff -- [ab].txt' \
  --path '[ab].txt' > "$OUT" 2>&1 \
  && grep -qF 'diff --git a/[ab].txt b/[ab].txt' "$OUT" \
  && ! grep -qF 'diff --git a/a.txt b/a.txt' "$OUT" \
  && ! grep -qF 'diff --git a/b.txt b/b.txt' "$OUT"; then
  ok 'path filters treat Git pathspec characters literally'
else
  fail 'Git pathspec characters expanded the requested path scope'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Binary changes contain bounded review evidence.' \
  --repro 'git diff --binary -- asset.bin' \
  --path asset.bin > "$OUT" 2>&1 \
  && grep -qF 'GIT binary patch' "$OUT" \
  && ! grep -qF 'Binary files a/asset.bin and b/asset.bin differ' "$OUT"; then
  ok 'binary changes include bounded patch evidence'
else
  fail 'binary changes were accepted without reviewable patch evidence'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'The packet stays inside the repository.' \
  --repro 'git diff -- ../outside' \
  --path ../outside > "$OUT" 2>&1; then
  fail 'a repository-escaping path was accepted'
elif grep -qF -- '--path values must stay inside the repository' "$OUT"; then
  ok 'path filters reject repository traversal'
else
  fail 'repository traversal lacked a useful diagnostic'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'The review artifact remains bounded.' \
  --repro 'git diff --check' \
  --max-bytes 32 > "$OUT" 2>&1; then
  fail 'oversized diffs were accepted'
elif grep -qF 'tracked diff exceeds --max-bytes (32)' "$OUT" \
  && ! grep -qF '+after' "$OUT"; then
  ok 'oversized diffs fail closed without emitting partial evidence'
else
  fail 'oversized diffs lacked a safe diagnostic'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim '   ' \
  --repro 'git diff --check' > "$OUT" 2>&1; then
  fail 'a blank claim was accepted'
elif grep -qF 'must not be blank' "$OUT"; then
  ok 'claim and repro contracts reject blank values'
else
  fail 'a blank claim lacked a useful diagnostic'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'The scoped change is correct.' \
  --repro 'git diff -- unchanged.txt' \
  --path unchanged.txt > "$OUT" 2>&1; then
  fail 'an empty review scope was accepted'
elif grep -qF 'tracked diff is empty' "$OUT"; then
  ok 'empty review scopes fail before dispatch'
else
  fail 'an empty review scope lacked a useful diagnostic'
fi

printf '```\n' >> "$R/tracked.txt"
: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Markdown-shaped source cannot escape the raw diff fence.' \
  --repro 'git diff -- tracked.txt' \
  --path tracked.txt > "$OUT" 2>&1 \
  && grep -qF '````diff' "$OUT" \
  && [ "$(tail -n 1 "$OUT")" = '````' ]; then
  ok 'diff fences expand around Markdown-shaped source content'
else
  fail 'Markdown-shaped source content escaped or broke the diff fence'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Shell syntax remains literal review evidence.' \
  --repro 'printf `uname`' \
  --path tracked.txt > "$OUT" 2>&1 \
  && grep -qF '```text' "$OUT" \
  && grep -qF 'printf `uname`' "$OUT"; then
  ok 'repro commands use a literal block instead of fragile inline Markdown'
else
  fail 'repro commands were not preserved as literal evidence'
fi

: > "$OUT"
if python3 "$TOOL" \
  --repo "$R" \
  --base HEAD \
  --claim 'Verification commands remain literal review evidence.' \
  --repro 'git diff -- tracked.txt' \
  --verify 'printf `uname`' \
  --path tracked.txt > "$OUT" 2>&1 \
  && grep -qF 'printf `uname`' "$OUT" \
  && [ "$(grep -cF '```text' "$OUT")" -eq 3 ]; then
  ok 'verification commands use literal blocks instead of fragile inline Markdown'
else
  fail 'verification commands were not preserved as literal evidence'
fi

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
