#!/usr/bin/env bash
# memory-sync.test.sh — automatic Claude memory sync is path-scoped,
# content-scanned, index-preserving, and honest about push failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

ROOT="$(mktemp -d)"
TEST_HOME="$ROOT/home"
SHIM_DIR="$ROOT/bin"
mkdir -p "$TEST_HOME" "$SHIM_DIR"
trap 'rm -rf "$ROOT"' EXIT

# CI does not install gitleaks. This shim models the stdin contract used by
# sync-memory and rejects the synthetic credential in the focused fixture.
cat > "$SHIM_DIR/gitleaks" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" != "stdin" ]; then exit 2; fi
args=" $* "
payload="$(cat)"
if [ -n "${INJECT_INDEX_REPO:-}" ] && [ -n "${INJECT_INDEX_MARKER:-}" ] \
  && [ ! -e "$INJECT_INDEX_MARKER" ]; then
  GIT_INDEX_FILE="$INJECT_INDEX_REPO/.git/index" \
    /usr/bin/git -C "$INJECT_INDEX_REPO" add settings.json || exit 3
  : > "$INJECT_INDEX_MARKER"
fi
if [ -n "${GITLEAKS_CONFIG:-}" ] || [ -n "${GITLEAKS_CONFIG_TOML:-}" ] \
  || [ -f .gitleaks.toml ]; then
  exit 0
fi
if grep -q 'gitleaks:allow' <<< "$payload" \
  && [[ "$args" != *" --ignore-gitleaks-allow "* ]]; then
  exit 0
fi
if grep -q 'AKIAEXAMPLE012345678' <<< "$payload"; then
  echo "synthetic secret detected" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$SHIM_DIR/gitleaks"

export HOME="$TEST_HOME"
export PATH="$SHIM_DIR:/usr/bin:/bin"

# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"

new_fixture() {
  local name="$1"
  TEST_DEV="$ROOT/$name/dev"
  REMOTE="$ROOT/$name/remote.git"
  local seed="$ROOT/$name/seed"
  mkdir -p "$TEST_DEV" "$seed"
  git init -q --bare --initial-branch=main "$REMOTE"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name test
  git -C "$seed" config user.email test@example.invalid
  mkdir -p "$seed/project/memory"
  printf 'initial memory\n' > "$seed/project/memory/MEMORY.md"
  printf 'portable settings\n' > "$seed/settings.json"
  git -C "$seed" add project/memory/MEMORY.md settings.json
  git -C "$seed" commit -q -m 'test: seed memory fixture'
  git -C "$seed" remote add origin "$REMOTE"
  git -C "$seed" push -q -u origin main
  git clone -q "$REMOTE" "$TEST_DEV/claude-memory"
  git -C "$TEST_DEV/claude-memory" config user.name test
  git -C "$TEST_DEV/claude-memory" config user.email test@example.invalid
}

_dev_dir() {
  printf '%s\n' "$TEST_DEV"
}

TEST_DEV="$ROOT/missing/dev"
mkdir -p "$TEST_DEV"
if sync-memory >/dev/null 2>&1; then
  ok "automatic sync treats the setup-optional Claude memory repo as disabled"
else
  fail "automatic sync blocked Claude when the optional memory repo was absent"
fi

new_fixture scoped
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
printf 'machine-local settings\n' > "$TEST_DEV/claude-memory/settings.json"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git --git-dir="$REMOTE" show main:project/memory/MEMORY.md)" = "updated memory" ] \
  && [ "$(git --git-dir="$REMOTE" show main:settings.json)" = "portable settings" ] \
  && [ "$(git -C "$TEST_DEV/claude-memory" status --short)" = ' M settings.json' ]; then
  ok "automatic sync commits only contract-approved memory paths"
else
  fail "automatic sync absorbed unrelated private-repo state"
fi

new_fixture secret
printf 'token=AKIAEXAMPLE012345678\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
before_secret="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync committed secret-like memory content"
elif [ "$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)" = "$before_secret" ] \
  && git -C "$TEST_DEV/claude-memory" diff --cached --quiet; then
  ok "content scanning blocks secret-like memory before commit"
else
  fail "blocked secret scan left a commit or staged residue"
fi

new_fixture staged
printf 'user-staged settings\n' > "$TEST_DEV/claude-memory/settings.json"
git -C "$TEST_DEV/claude-memory" add settings.json
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync consumed a pre-existing user index"
elif [ "$(git -C "$TEST_DEV/claude-memory" diff --cached --name-only)" = 'settings.json' ] \
  && [ "$(git -C "$TEST_DEV/claude-memory" status --short project/memory/MEMORY.md)" = ' M project/memory/MEMORY.md' ]; then
  ok "automatic sync preserves staged user work and leaves memory unstaged"
else
  fail "automatic sync changed the user's staged state"
fi

new_fixture retry
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" remote set-url origin "$ROOT/missing-remote.git"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync reported success after push failure"
else
  ok "automatic sync reports push failure"
fi
git -C "$TEST_DEV/claude-memory" remote set-url origin "$REMOTE"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git -C "$TEST_DEV/claude-memory" rev-list --count origin/main..HEAD)" -eq 0 ]; then
  ok "automatic sync retries a clean but unpushed memory commit"
else
  fail "automatic sync did not retry its pending memory commit"
fi

new_fixture user_ahead
printf 'intentional user settings\n' > "$TEST_DEV/claude-memory/settings.json"
git -C "$TEST_DEV/claude-memory" add settings.json
git -C "$TEST_DEV/claude-memory" commit -q -m 'docs: intentional private settings change'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync pushed an unrelated user-authored commit"
elif [ "$(git --git-dir="$REMOTE" show main:settings.json)" = 'portable settings' ]; then
  ok "automatic sync refuses to publish non-memory commits"
else
  fail "automatic sync changed the remote while rejecting a user commit"
fi

new_fixture hidden_history
printf 'token=AKIAEXAMPLE012345678\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: secret in intermediate history'
printf 'initial memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: revert visible secret'
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'auto: sync memory fixture'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a secret hidden in intermediate history"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync validates every pending commit before push"
else
  fail "automatic sync changed the remote while rejecting unsafe history"
fi

new_fixture nested_memory
mkdir -p "$TEST_DEV/claude-memory/project/nested/memory"
printf 'NESTED_SECRET\n' > "$TEST_DEV/claude-memory/project/nested/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/nested/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: nested memory bypass'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a nested path outside its scan contract"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync rejects nested paths outside immediate project memory"
else
  fail "automatic sync changed the remote while rejecting nested memory"
fi

new_fixture scoped_push
git -C "$TEST_DEV/claude-memory" branch extra HEAD
git -C "$TEST_DEV/claude-memory" config --add remote.origin.push refs/heads/main:refs/heads/main
git -C "$TEST_DEV/claude-memory" config --add remote.origin.push refs/heads/extra:refs/heads/extra
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
if sync-memory >/dev/null 2>&1 \
  && ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/extra; then
  ok "automatic sync publishes only the validated upstream branch"
else
  fail "automatic sync published an unvalidated ref through push configuration"
fi

new_fixture status_failure
printf 'corrupt index\n' > "$TEST_DEV/claude-memory/.git/index"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync treated a failed status check as a clean tree"
else
  ok "automatic sync fails closed when repository status cannot be read"
fi

new_fixture binary_secret
printf 'binary\000token=AKIAEXAMPLE012345678\000payload\n' \
  > "$TEST_DEV/claude-memory/project/memory/state.bin"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a secret-like binary memory blob"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync scans staged binary blob contents before publishing"
else
  fail "binary blob rejection changed the remote"
fi

new_fixture pending_sensitive_path
mkdir -p "$TEST_DEV/claude-memory/project/memory/auth"
printf '{"session":"synthetic"}\n' \
  > "$TEST_DEV/claude-memory/project/memory/auth/session.json"
git -C "$TEST_DEV/claude-memory" add project/memory/auth/session.json
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: pending auth state'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a sensitive path from pending history"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync applies the sensitive-path policy to pending commits"
else
  fail "pending sensitive-path rejection changed the remote"
fi

new_fixture pending_binary_secret
printf 'binary\000token=AKIAEXAMPLE012345678\000payload\n' \
  > "$TEST_DEV/claude-memory/project/memory/state.bin"
git -C "$TEST_DEV/claude-memory" add project/memory/state.bin
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: pending binary memory'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a secret-like binary blob from pending history"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync scans binary blobs in every pending commit"
else
  fail "pending binary blob rejection changed the remote"
fi

new_fixture casefold_sensitive_path
mkdir -p "$TEST_DEV/claude-memory/project/memory/Auth"
printf '{"session":"synthetic"}\n' \
  > "$TEST_DEV/claude-memory/project/memory/Auth/session.json"
git -C "$TEST_DEV/claude-memory" add project/memory/Auth/session.json
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: case-folded auth state'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a case-variant sensitive path"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync matches sensitive path names case-insensitively"
else
  fail "case-variant path rejection changed the remote"
fi

new_fixture env_variant
printf 'synthetic=true\n' > "$TEST_DEV/claude-memory/project/memory/.env.local"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published an environment-file variant"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync blocks .env variants from automatic publishing"
else
  fail "environment-file rejection changed the remote"
fi

new_fixture immutable_push
validated_head="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
printf 'unreviewed memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: concurrent unreviewed commit'
if _memory_push_upstream "$TEST_DEV/claude-memory" "$validated_head" origin refs/heads/main "$validated_head" \
  && [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$validated_head" ]; then
  ok "memory push publishes the exact validated commit instead of mutable HEAD"
else
  fail "memory push substituted a later HEAD for the validated commit"
fi

new_fixture hostile_gitleaks_config
printf 'token=AKIAEXAMPLE012345678\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
printf 'synthetic hostile config\n' > "$TEST_DEV/claude-memory/.gitleaks.toml"
if (cd "$TEST_DEV/claude-memory" && sync-memory >/dev/null 2>&1); then
  fail "automatic sync trusted a project-controlled gitleaks configuration"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync isolates secret scanning from project gitleaks config"
else
  fail "hostile scanner-config rejection changed the remote"
fi

new_fixture inline_allow
printf 'token=AKIAEXAMPLE012345678 # gitleaks:allow\n' \
  > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync honored an inline gitleaks allow directive"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync ignores content-controlled gitleaks allow directives"
else
  fail "inline-allow rejection changed the remote"
fi

new_fixture sensitive_filename_extension
printf '{"session":"synthetic"}\n' > "$TEST_DEV/claude-memory/project/memory/Auth.json"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a sensitive filename with an extension"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync blocks sensitive filename stems with extensions"
else
  fail "sensitive filename rejection changed the remote"
fi

new_fixture sensitive_backup_separator
printf '{"session":"synthetic"}\n' \
  > "$TEST_DEV/claude-memory/project/memory/Auth (copy).json"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a sensitive backup-style filename"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync blocks sensitive stems followed by unusual separators"
else
  fail "backup-style sensitive filename rejection changed the remote"
fi

new_fixture replacement_ref
printf 'unreviewed settings\n' > "$TEST_DEV/claude-memory/settings.json"
git -C "$TEST_DEV/claude-memory" add settings.json
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: unsafe original commit'
unsafe_oid="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
git -C "$TEST_DEV/claude-memory" switch -q -c safe-replacement origin/main
printf 'review-shaped memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: safe replacement view'
safe_oid="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
git -C "$TEST_DEV/claude-memory" switch -q main
git -C "$TEST_DEV/claude-memory" replace "$unsafe_oid" "$safe_oid"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync trusted replacement history instead of the pushed OID"
elif [ "$(git --git-dir="$REMOTE" show main:settings.json)" = 'portable settings' ]; then
  ok "automatic sync ignores Git replacement refs during validation"
else
  fail "replacement-ref rejection still changed the remote"
fi

new_fixture follow_tags
validated_head="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
git -C "$TEST_DEV/claude-memory" tag -a leak-tag -m 'unreviewed tag metadata' "$validated_head"
git -C "$TEST_DEV/claude-memory" config push.followTags true
if _memory_push_upstream "$TEST_DEV/claude-memory" "$validated_head" origin refs/heads/main "$validated_head" \
  && ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/tags/leak-tag; then
  ok "memory push suppresses configured tag following"
else
  fail "memory push published an unreviewed annotated tag"
fi

new_fixture leading_sensitive_stem
mkdir -p "$TEST_DEV/claude-memory/project/memory/.Auth"
printf '{"session":"synthetic"}\n' \
  > "$TEST_DEV/claude-memory/project/memory/.Auth/data.json"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published a leading-punctuation sensitive path"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync blocks leading and embedded authentication stems"
else
  fail "leading sensitive-stem rejection changed the remote"
fi

new_fixture commit_metadata
git -C "$TEST_DEV/claude-memory" commit -q --allow-empty \
  -m 'credential=AKIAEXAMPLE012345678'
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync published secret-like commit metadata"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "automatic sync scans commit metadata as well as paths and blobs"
else
  fail "commit-metadata rejection changed the remote"
fi

new_fixture hidden_untracked
git -C "$TEST_DEV/claude-memory" config status.showUntrackedFiles no
printf 'new fact\n' > "$TEST_DEV/claude-memory/project/memory/new-fact.md"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git --git-dir="$REMOTE" show main:project/memory/new-fact.md)" = 'new fact' ]; then
  ok "automatic sync forces untracked memory discovery despite Git config"
else
  fail "automatic sync silently missed an untracked memory file"
fi

new_fixture concurrent_index
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
printf 'concurrently staged settings\n' > "$TEST_DEV/claude-memory/settings.json"
export INJECT_INDEX_REPO="$TEST_DEV/claude-memory"
export INJECT_INDEX_MARKER="$ROOT/concurrent-index.injected"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git --git-dir="$REMOTE" show main:project/memory/MEMORY.md)" = 'updated memory' ] \
  && [ "$(git --git-dir="$REMOTE" show main:settings.json)" = 'portable settings' ] \
  && [ "$(git -C "$TEST_DEV/claude-memory" diff --cached --name-only)" = 'settings.json' ]; then
  ok "automatic commit excludes work staged concurrently after its index check"
else
  fail "automatic commit absorbed or disturbed concurrently staged user work"
fi
unset INJECT_INDEX_REPO INJECT_INDEX_MARKER

new_fixture stale_upstream
safe_base="$(git -C "$TEST_DEV/claude-memory" rev-parse HEAD)"
printf 'unsafe settings\n' > "$TEST_DEV/claude-memory/settings.json"
git -C "$TEST_DEV/claude-memory" add settings.json
git -C "$TEST_DEV/claude-memory" commit -q -m 'test: remote commit outside memory contract'
git -C "$TEST_DEV/claude-memory" push -q origin main
printf 'updated memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
git -C "$TEST_DEV/claude-memory" add project/memory/MEMORY.md
git -C "$TEST_DEV/claude-memory" commit -q -m 'auto: later safe memory commit'
git --git-dir="$REMOTE" update-ref refs/heads/main "$safe_base"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync republished history excluded by a stale upstream boundary"
elif [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$safe_base" ] \
  && [ "$(git --git-dir="$REMOTE" show main:settings.json)" = 'portable settings' ]; then
  ok "automatic push leases the exact scanned upstream boundary"
else
  fail "stale-upstream rejection changed the rewound remote"
fi

new_fixture linked_memory_repo
primary_repo="$TEST_DEV/claude-memory"
linked_dev="$ROOT/linked-memory-worktree/dev"
mkdir -p "$linked_dev"
git -C "$primary_repo" worktree add -q -b linked-sync \
  "$linked_dev/claude-memory" main
git -C "$linked_dev/claude-memory" branch --set-upstream-to=origin/main linked-sync >/dev/null
TEST_DEV="$linked_dev"
printf 'linked memory\n' > "$TEST_DEV/claude-memory/project/memory/MEMORY.md"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git --git-dir="$REMOTE" show main:project/memory/MEMORY.md)" = 'linked memory' ]; then
  ok "automatic sync recognizes a linked-worktree memory checkout"
else
  fail "automatic sync treated a linked Git worktree as disabled"
fi

new_fixture author_document
printf 'Ada Lovelace\n' > "$TEST_DEV/claude-memory/project/memory/authors.md"
if sync-memory >/dev/null 2>&1 \
  && [ "$(git --git-dir="$REMOTE" show main:project/memory/authors.md)" = 'Ada Lovelace' ]; then
  ok "automatic sync allows explicit author-document components"
else
  fail "sensitive path matching rejected a legitimate authors document"
fi

new_fixture author_sensitive_suffix
printf 'synthetic\n' > "$TEST_DEV/claude-memory/project/memory/authors.session.json"
printf 'synthetic\n' > "$TEST_DEV/claude-memory/project/memory/author.auth.json"
printf 'synthetic\n' > "$TEST_DEV/claude-memory/project/memory/authors.cache"
printf 'synthetic\n' > "$TEST_DEV/claude-memory/project/memory/author.oauth"
if sync-memory >/dev/null 2>&1; then
  fail "automatic sync stripped sensitive suffixes from author documents"
elif [ "$(git --git-dir="$REMOTE" rev-list --count main)" -eq 1 ]; then
  ok "author-document exception preserves sensitive suffixes for denial"
else
  fail "author sensitive-suffix rejection changed the remote"
fi

echo ""
echo "memory-sync: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
