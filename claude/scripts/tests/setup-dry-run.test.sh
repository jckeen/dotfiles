#!/usr/bin/env bash
# setup-dry-run.test.sh — regression test for issue #133: `setup.sh --dry-run`
# must not write ANYTHING under $HOME. Builds a throwaway HOME seeded with
# files that tempt every mutation path (a real .gitconfig for the backup path,
# a .bashrc with a /mnt/c cd for the sed path, a real .bash_profile), snapshots
# it, runs `setup.sh --yes --dry-run` against it, and asserts the snapshot is
# unchanged — paths, contents, and symlink targets. Also asserts the
# `--dry-run --repair` combo previews fixes without applying them. Run
# directly; exit 1 on any failure. Mirrors install-integrity.test.sh
# conventions.
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
SETUP="$REPO_ROOT/setup.sh"
# setup.sh refuses to run from a linked git worktree (#412), and agents work
# in worktrees by default, so without this the whole suite fails on a refusal
# rather than on the no-writes contract it exists to check (#435). Safe here:
# every run below targets a throwaway HOME and the suite asserts a
# byte-identical before/after snapshot, so nothing links to this checkout.
# The refusal itself stays covered by setup-worktree-guard.test.sh.
export DOTFILES_ALLOW_LINKED_WORKTREE=1
# The assertions below expect the all-services migration default; a
# developer's own service selection (issue #425) must not leak in.
unset XDG_CONFIG_HOME DOTFILES_SERVICES

pass=0
failed=0

ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# The snapshot helper is shared with setup-fuzz-layouts.test.sh so both suites
# assert "zero mutations" with the identical comparison; a weaker snapshot in
# either would silently stop catching writes.
# shellcheck source=claude/scripts/tests/lib-snapshot.sh
. "$SCRIPT_DIR/lib-snapshot.sh"

TESTHOME="$(mktemp -d)"
OUT="$(mktemp)"
CHECK_OUT="$(mktemp)"
INSTALL_OUT="$(mktemp)"
SKILLS_OUT="$(mktemp)"
SKILLS_EXTERNAL="$(mktemp -d)"
# dir-link-fixture: planted in the checkout by the issue #274 test below;
# listed here so an aborted run can't leave the working tree dirty.
# setup.sh and cct query a running tmux server (#643). tmux finds its server
# through $TMUX or $TMUX_TMPDIR, not $HOME, so without this a run could reach
# the developer's real server.
unset TMUX
TMUX_ISO="$(mktemp -d)"
export TMUX_TMPDIR="$TMUX_ISO"
trap 'rm -rf "$TESTHOME" "$OUT" "$CHECK_OUT" "$INSTALL_OUT" "$SKILLS_OUT" "$SKILLS_EXTERNAL" "$TMUX_ISO"; rm -f "$REPO_ROOT/agents/skills/orchestrate/dir-link-fixture"' EXIT

# Seed the mutation-tempting fixtures.
git config --file "$TESTHOME/.gitconfig" user.name test
git config --file "$TESTHOME/.gitconfig" user.email test@test.test
printf 'cd /mnt/c/Users/test\n' > "$TESTHOME/.bashrc"
printf '# real profile\n' > "$TESTHOME/.bash_profile"
mkdir -p "$TESTHOME/.codex" "$TESTHOME/external-codex-skills"
mkdir -p "$TESTHOME/codex-memory"
cat > "$TESTHOME/codex-memory/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'invoked\n' > "$HOME/codex-bootstrap-invoked"
EOF
chmod +x "$TESTHOME/codex-memory/bootstrap.sh"
mkdir -p "$TESTHOME/external-codex-skills/orchestrate/agents" \
  "$TESTHOME/external-codex-skills/orchestrate/references"
printf 'stale external skill\n' > "$TESTHOME/external-codex-skills/orchestrate/SKILL.md"
printf 'stale external backup\n' > "$TESTHOME/external-codex-skills/orchestrate/SKILL.md.backup"
ln -s "$REPO_ROOT/agents/skills/orchestrate/agents/openai.yaml" \
  "$TESTHOME/external-codex-skills/orchestrate/agents/openai.yaml"
ln -s "$REPO_ROOT/agents/skills/orchestrate/references/runtime-contracts.md" \
  "$TESTHOME/external-codex-skills/orchestrate/references/runtime-contracts.md"
ln -s "$TESTHOME/external-codex-skills" "$TESTHOME/.codex/skills"

# A Jules timer from before the ADR-0009 pause (#678): the update path runs
# setup.sh, so setup.sh must disable it. Under --dry-run that is a preview only.
mkdir -p "$TESTHOME/.config/systemd/user"
printf '[Timer]\nOnCalendar=daily\n' > "$TESTHOME/.config/systemd/user/jules-dispatch.timer"

before="$(snapshot "$TESTHOME")"

# --yes so prompts take safe defaults (no stdin); dry-run must exit 0.
if HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  ok "setup.sh --yes --dry-run exits 0"
else
  fail "setup.sh --yes --dry-run exited $? (output follows)"
  sed 's/^/      | /' "$OUT"
fi

if grep -Fq "[DRY] bash $TESTHOME/codex-memory/bootstrap.sh" "$OUT" \
  && ! grep -Fq "Codex portable private defaults applied" "$OUT" \
  && [ ! -e "$TESTHOME/codex-bootstrap-invoked" ]; then
  ok "Codex private bootstrap is previewed without running in dry-run mode"
else
  fail "Codex private bootstrap dry-run claimed or performed a live apply"
fi

if command -v systemctl >/dev/null 2>&1; then
  if grep -Fq "[DRY] systemctl --user disable --now jules-dispatch.timer" "$OUT"; then
    ok "paused Jules lane: a pre-existing timer's disable is previewed in dry-run"
  else
    fail "paused Jules lane: setup.sh did not disable a pre-existing jules-dispatch.timer"
  fi
else
  if ! grep -Fq "jules-dispatch.timer" "$OUT"; then
    ok "paused Jules lane: no systemctl, so no timer step"
  else
    fail "paused Jules lane: timer step ran without systemctl"
  fi
fi

after="$(snapshot "$TESTHOME")"

if [ "$before" = "$after" ]; then
  ok "dry-run made zero mutations in \$HOME (paths, contents, link targets)"
else
  fail "dry-run mutated \$HOME:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
fi

if grep -q 'Mode: DRY-RUN' "$OUT"; then
  ok "banner reports DRY-RUN mode"
else
  fail "missing 'Mode: DRY-RUN' banner"
fi

if grep -q 'Checking Antigravity public-safe config' "$OUT"; then
  ok "post-setup audit covers the Antigravity installation"
else
  fail "post-setup audit skipped the Antigravity installation"
fi

HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --check > "$CHECK_OUT" 2>&1 || true
if grep -q 'Checking Codex public-safe config' "$CHECK_OUT" \
  && grep -q 'Checking Antigravity public-safe config' "$CHECK_OUT"; then
  ok "setup.sh --check audits Codex and Antigravity as well as Claude"
else
  fail "setup.sh --check is not a three-runtime audit"
fi

PATH="/usr/bin:/bin" HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$INSTALL_OUT" 2>&1 || true
if grep -q 'would download https://antigravity.google/cli/install.sh' "$INSTALL_OUT"; then
  ok "clean-machine dry-run includes the pinned Antigravity installer"
else
  fail "clean-machine setup omits the Antigravity CLI"
fi

mkdir -p "$TESTHOME/.gemini/config"
ln -s "$SKILLS_EXTERNAL" "$TESTHOME/.gemini/config/skills"
skills_before="$(snapshot "$SKILLS_EXTERNAL")"
HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$SKILLS_OUT" 2>&1 || true
skills_after="$(snapshot "$SKILLS_EXTERNAL")"
if grep -Fq "[DRY] would back up $TESTHOME/.gemini/config/skills" "$SKILLS_OUT" \
  && [ "$skills_before" = "$skills_after" ]; then
  ok "Antigravity setup safely prepares a symlinked skills ancestor"
else
  fail "Antigravity setup would traverse a symlinked skills ancestor"
fi
rm "$TESTHOME/.gemini/config/skills"
rmdir "$TESTHOME/.gemini/config" "$TESTHOME/.gemini"

if grep -q '\[DRY\] would link' "$OUT"; then
  ok "link_file dry-run guard engaged (would-link preview printed)"
else
  fail "no '[DRY] would link' lines — link_file guard not exercised"
fi

if grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/agents/openai.yaml ->" "$OUT" &&
  grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/references/runtime-contracts.md ->" "$OUT" &&
  grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/SKILL.md ->" "$OUT"; then
  ok "Codex skill bundles include nested metadata and references"
else
  fail "Codex skill bundle files were not included in the dry-run link plan"
fi

if grep -q "\[DRY\] would link $TESTHOME/.agents/skills/orchestrate ->" "$OUT"; then
  ok "Codex shared skills deploy to the documented user discovery path"
else
  fail "Codex shared skills were not deployed under ~/.agents/skills"
fi

if [ "$(grep -c "would back up $TESTHOME/.codex/skills to $TESTHOME/.codex/skills.backup" "$OUT")" -eq 1 ]; then
  ok "Codex setup refuses to write through a symlinked skill ancestor"
else
  fail "Codex setup did not isolate a symlinked skill ancestor"
fi

mkdir "$TESTHOME/.codex/skills.backup"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted a conflicting ancestor backup"
elif grep -q "refusing to replace $TESTHOME/.codex/skills because $TESTHOME/.codex/skills.backup already exists" "$OUT"; then
  ok "dry-run refuses the same ancestor backup collision as a real run"
else
  fail "dry-run backup collision lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "backup-collision dry-run made zero mutations in \$HOME"
else
  fail "backup-collision dry-run mutated \$HOME"
fi
rm -r "$TESTHOME/.codex/skills.backup"

printf 'conflicting agent rules\n' > "$TESTHOME/.codex/AGENTS.md"
printf 'existing backup\n' > "$TESTHOME/.codex/AGENTS.md.backup"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted a conflicting leaf backup"
elif grep -q "refusing to replace $TESTHOME/.codex/AGENTS.md because $TESTHOME/.codex/AGENTS.md.backup already exists" "$OUT"; then
  ok "dry-run refuses the same leaf backup collision as a real run"
else
  fail "dry-run leaf backup collision lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "leaf-collision dry-run made zero mutations in \$HOME"
else
  fail "leaf-collision dry-run mutated \$HOME"
fi
rm "$TESTHOME/.codex/AGENTS.md" "$TESTHOME/.codex/AGENTS.md.backup"

mkfifo "$TESTHOME/.codex/AGENTS.md"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted an unsupported leaf destination type"
elif grep -q "refusing to replace unsupported destination type: $TESTHOME/.codex/AGENTS.md" "$OUT"; then
  ok "dry-run rejects unsupported leaf destination types"
else
  fail "unsupported leaf destination lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "special-file collision dry-run made zero mutations in \$HOME"
else
  fail "special-file collision dry-run mutated \$HOME"
fi
rm "$TESTHOME/.codex/AGENTS.md"

# --dry-run --repair must preview fixes without applying them (reviewer P3 on
# PR #187: audit_link's repair branches used to rm/mv/ln unconditionally).
# Non-zero exit is expected — the entries are still broken after a preview.
mkdir -p "$TESTHOME/.agents/skills"
ln -s "$REPO_ROOT/agents/skills/reviewer-ghost" \
  "$TESTHOME/.agents/skills/reviewer-ghost"
before="$(snapshot "$TESTHOME")"
HOME="$TESTHOME" "$SETUP" --dry-run --repair > "$OUT" 2>&1
repair_rc=$?
after="$(snapshot "$TESTHOME")"

if [ "$before" = "$after" ]; then
  ok "--dry-run --repair made zero mutations in \$HOME (rc=$repair_rc, non-zero expected)"
else
  fail "--dry-run --repair mutated \$HOME:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
fi

if [ -L "$TESTHOME/.agents/skills/reviewer-ghost" ]; then
  ok "dry-run repair preserves orphan links found by nested runtime checkers"
else
  fail "dry-run repair let a nested checker delete an orphan link"
fi

if grep -q '\[DRY\] would fix' "$OUT"; then
  ok "repair dry-run guard engaged (would-fix preview printed)"
else
  fail "no '[DRY] would fix' lines — repair guard not exercised"
  sed 's/^/      | /' "$OUT"
fi

if grep -q '"${checker_args\[@\]}"' "$SETUP"; then
  fail "health audit still expands an empty array under nounset (breaks macOS Bash 3.2)"
else
  ok "health audit avoids Bash 3.2 empty-array nounset expansion"
fi

# A symlinked ~/.codex is live runtime state living elsewhere; replacing it
# with a fresh dir would disconnect auth/sessions from the path Codex uses
# (issue #273). Setup must refuse, in dry-run and real mode alike.
CODEX_REAL="$(mktemp -d)"
mv "$TESTHOME/.codex" "$TESTHOME/.codex.relocated"
ln -s "$CODEX_REAL" "$TESTHOME/.codex"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "setup accepted a symlinked ~/.codex runtime root"
elif grep -q "refusing to replace the Codex runtime root" "$OUT"; then
  ok "setup refuses a symlinked ~/.codex runtime root"
else
  fail "symlinked ~/.codex runtime root lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ] && [ -L "$TESTHOME/.codex" ]; then
  ok "symlinked ~/.codex refusal made zero mutations"
else
  fail "symlinked ~/.codex refusal mutated \$HOME"
fi
rm "$TESTHOME/.codex"
mv "$TESTHOME/.codex.relocated" "$TESTHOME/.codex"
rm -rf "$CODEX_REAL"

# An in-bundle symlink that resolves to a DIRECTORY would deploy a directory
# symlink under ~/.codex/skills, which check-codex.sh flags UNSAFE; setup
# must reject the bundle instead of installing that state (issue #274).
ln -s references "$REPO_ROOT/agents/skills/orchestrate/dir-link-fixture" 2>/dev/null || true
if [ -L "$REPO_ROOT/agents/skills/orchestrate/dir-link-fixture" ]; then
  if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
    fail "setup accepted an in-bundle directory symlink in a Codex skill"
  elif grep -q "Codex skill symlink escapes its bundle, is broken, or targets a non-file" "$OUT"; then
    ok "setup rejects in-bundle directory symlinks in Codex skill bundles"
  else
    fail "in-bundle directory symlink lacked a useful report"
  fi
  rm "$REPO_ROOT/agents/skills/orchestrate/dir-link-fixture"
else
  fail "unable to plant the in-bundle directory symlink fixture"
fi

# Codex review on PR #300: the first npm invocation of a first-time pinned
# Node install (`npm config set prefix`) runs BEFORE the caller's
# `export PATH="$HOME_DIR/.local/bin:$PATH"`, so npm's `#!/usr/bin/env node`
# shebang used to exit 127 — masked by `|| echo` — and Codex npm globals later
# landed outside PATH. Exercise the real install_node_pinned (non-dry) in a
# sandbox: a stub curl serves a fixture tarball whose npm needs the
# freshly-linked node as its shebang interpreter; the stub node records the
# prefix call. Fails on the old ordering (npm never runs → marker never
# written).
NODEHOME="$(mktemp -d)"
NODESTUBS="$(mktemp -d)"
NODEFIX="$(mktemp -d)"
NODEOUT="$(mktemp)"
# shellcheck disable=SC2034  # consumed by the eval'd node_asset_name below
NODE_VERSION="$(sed -n 's/^NODE_VERSION="\(.*\)"/\1/p' "$SETUP" | head -1)"
eval "$(sed -n '/^_sha256()/,/^}/p; /^node_asset_name()/,/^}/p; /^install_node_pinned()/,/^}/p' "$SETUP")"

if asset="$(node_asset_name)"; then
  mkdir -p "$NODEFIX/$asset/bin"
  cat > "$NODEFIX/$asset/bin/node" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$NODEHOME/npm-invocation"
STUB
  chmod +x "$NODEFIX/$asset/bin/node"
  printf '#!/usr/bin/env node\n// stub npm; the stub node above records the argv\n' \
    > "$NODEFIX/$asset/bin/npm"
  chmod +x "$NODEFIX/$asset/bin/npm"
  tar -czf "$NODEFIX/$asset.tar.gz" -C "$NODEFIX" "$asset"
  (cd "$NODEFIX" && sha256sum "$asset.tar.gz" > SHASUMS256.txt)

  cat > "$NODESTUBS/curl" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *)  url="\$1"; shift ;;
  esac
done
case "\$url" in
  *.tar.gz)        cp "$NODEFIX/$asset.tar.gz" "\$out" ;;
  *SHASUMS256.txt) cp "$NODEFIX/SHASUMS256.txt" "\$out" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$NODESTUBS/curl"

  (
    export HOME="$NODEHOME"
    # shellcheck disable=SC2034  # consumed by the eval'd install_node_pinned
    HOME_DIR="$NODEHOME"
    # shellcheck disable=SC2034  # consumed by the eval'd install_node_pinned
    DRY_RUN=0
    # Deliberately excludes any preexisting node install dir — a first-time
    # machine has no node on PATH when install_node_pinned runs.
    PATH="$NODESTUBS:/usr/bin:/bin"
    install_node_pinned
  ) > "$NODEOUT" 2>&1
  node_rc=$?

  if [ "$node_rc" -eq 0 ] \
    && grep -q "config set prefix $NODEHOME/.local" "$NODEHOME/npm-invocation" 2>/dev/null; then
    ok "first-time pinned install runs npm with the fresh node on PATH (prefix set)"
  else
    fail "first-time pinned install could not run npm — shebang node off PATH? (rc=$node_rc)"
    sed 's/^/      | /' "$NODEOUT"
  fi
  if grep -qi 'WARNING: could not set npm global prefix' "$NODEOUT"; then
    fail "npm prefix failure was masked as a soft warning instead of surfacing"
  else
    ok "npm prefix failure is not masked by a soft-warning path"
  fi
else
  ok "pinned-Node ordering test skipped (non-Linux or unsupported arch) # SKIP"
fi
rm -rf "$NODEHOME" "$NODESTUBS" "$NODEFIX" "$NODEOUT"

# Issue #621: any real codex invocation — even `--version` — writes
# $HOME/.codex/tmp/arg0-linux helper links unless $HOME sits under /tmp, so a
# dry-run passed with a /tmp HOME and mutated one anywhere else. A stub that
# records every call makes the contract independent of where mktemp put HOME
# and of whether the host has Codex installed at all.
CODEXSTUBS="$(mktemp -d)"
CODEXOUT="$(mktemp)"
cat > "$CODEXSTUBS/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/codex-cli-invoked"
EOF
chmod +x "$CODEXSTUBS/codex"
PATH="$CODEXSTUBS:$PATH" HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$CODEXOUT" 2>&1 || true
if [ ! -e "$TESTHOME/codex-cli-invoked" ] && grep -q 'Codex CLI already installed' "$CODEXOUT"; then
  ok "dry-run never invokes the codex CLI (not even --version)"
else
  fail "dry-run invoked codex: $(tr '\n' ';' < "$TESTHOME/codex-cli-invoked" 2>/dev/null)"
fi
rm -f "$TESTHOME/codex-cli-invoked"
rm -rf "$CODEXSTUBS" "$CODEXOUT"
# CLI stack install/shim (issue #636): every CLI_STACK_TOOLS entry, read from
# lib-checks.sh rather than restated here, must be apt-installed when absent
# and shimmed when only its Debian binary is present. The PATH is a symlink
# farm of /usr/bin and /bin minus every name the list mentions, so the result
# does not depend on what this machine has installed. The farm's tmux is a
# fake that logs its argv (issue #643): the first run has a server socket and
# answers `tmux list-sessions`, the second has no socket, so setup must not
# invoke tmux at all (a client creates its socket dir, which may sit under
# $HOME). apt is Linux-only, so macOS skips.
# shellcheck source=lib-checks.sh
. "$REPO_ROOT/lib-checks.sh"
if [ "$(uname -s)" = "Darwin" ]; then
  ok "CLI stack apt install/shim test skipped on macOS # SKIP"
else
  FARM="$(mktemp -d)"
  FARM_LOG="$(mktemp)"
  FARM_OUT="$(mktemp)"
  _hide=" tmux "
  for _entry in "${CLI_STACK_TOOLS[@]}"; do
    cli_stack_entry "$_entry"
    _hide="$_hide$CLI_NAME $CLI_BIN "
  done
  for _f in /usr/bin/* /bin/*; do
    _b="${_f##*/}"
    case "$_hide" in *" $_b "*) continue ;; esac
    [ -e "$FARM/$_b" ] || ln -s "$_f" "$FARM/$_b"
  done
  cat > "$FARM/tmux" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$FARM_LOG"
[ "\$1" = list-sessions ] && exit "\${FAKE_TMUX_LS_RC:-0}"
[ "\$1" = has-session ] && exit 1
exit 0
STUB
  chmod +x "$FARM/tmux"
  # A socket file where tmux would put the default server's, inside the
  # isolated TMUX_TMPDIR; the fake tmux stands in for the server behind it.
  TMUX_SOCK="$TMUX_ISO/tmux-$(id -u)/default"
  mkdir -p "${TMUX_SOCK%/*}"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_SOCK"

  before="$(snapshot "$TESTHOME")"
  PATH="$FARM" FAKE_TMUX_LS_RC=0 HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$FARM_OUT" 2>&1
  farm_rc=$?
  after="$(snapshot "$TESTHOME")"
  [ "$farm_rc" -eq 0 ] && [ "$before" = "$after" ] \
    && ok "clean-PATH dry-run exits 0 with zero mutations" \
    || fail "clean-PATH dry-run exited $farm_rc or mutated \$HOME"
  missed=""
  for _entry in "${CLI_STACK_TOOLS[@]}"; do
    cli_stack_entry "$_entry"
    case "$CLI_APT" in
      \?*) grep -Fxq "[DRY] sudo apt install -y ${CLI_APT#\?}" "$FARM_OUT" || missed="$missed $CLI_NAME" ;;
      *) grep -F '[DRY] sudo apt install -y ' "$FARM_OUT" | tr ' ' '\n' | grep -Fxq "$CLI_APT" \
        || missed="$missed $CLI_NAME" ;;
    esac
  done
  if [ -z "$missed" ]; then
    ok "every CLI_STACK_TOOLS entry is apt-installed when absent"
  else
    fail "CLI_STACK_TOOLS entries not installed:$missed"
    sed 's/^/      | /' "$FARM_OUT"
  fi
  if grep -Fq "[DRY] would reload $TESTHOME/.tmux.conf into the running tmux server" "$FARM_OUT" \
    && grep -qx list-sessions "$FARM_LOG" && ! grep -q '^source-file' "$FARM_LOG"; then
    ok "dry-run previews the reload into a running tmux server without sourcing"
  else
    fail "dry-run tmux reload preview missing, or it sourced the config"
    sed 's/^/      | log: /' "$FARM_LOG"
  fi

  # Second run: only the Debian binaries are present, and no server socket.
  _renamed=""
  for _entry in "${CLI_STACK_TOOLS[@]}"; do
    cli_stack_entry "$_entry"
    [ "$CLI_BIN" = "$CLI_NAME" ] && continue
    printf '#!/bin/sh\n' > "$FARM/$CLI_BIN"
    chmod +x "$FARM/$CLI_BIN"
    _renamed="$_renamed $CLI_NAME:$CLI_BIN:$CLI_APT"
  done
  : > "$FARM_LOG"
  rm "$TMUX_SOCK"
  PATH="$FARM" HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$FARM_OUT" 2>&1
  missed=""
  for _r in $_renamed; do
    IFS=: read -r _name _bin _apt <<<"$_r"
    grep -Fxq "[DRY] ln -sf $FARM/$_bin $TESTHOME/.local/bin/$_name" "$FARM_OUT" \
      || missed="$missed $_name(no shim)"
    grep -F '[DRY] sudo apt install -y ' "$FARM_OUT" | tr ' ' '\n' | grep -Fxq "$_apt" \
      && missed="$missed $_name(reinstalled)"
  done
  if [ -n "$_renamed" ] && [ -z "$missed" ]; then
    ok "every renamed CLI_STACK_TOOLS binary is shimmed, not reinstalled"
  else
    fail "CLI_STACK_TOOLS shim plan wrong:${missed:- no renamed entries}"
    sed 's/^/      | /' "$FARM_OUT"
  fi
  if ! grep -q 'would reload' "$FARM_OUT" && [ ! -s "$FARM_LOG" ]; then
    ok "no server socket: setup never invokes tmux (no probe, no reload)"
  else
    fail "setup invoked tmux with no server socket"
    sed 's/^/      | log: /' "$FARM_LOG"
  fi

  # Live path of setup.sh's reload_tmux_config, and cct's own reload, against
  # the same fake tmux (never a real server).
  eval "$(sed -n '/^reload_tmux_config()/,/^}/p' "$SETUP")"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_SOCK"
  : > "$FARM_LOG"
  (PATH="$FARM:$PATH" FAKE_TMUX_LS_RC=0 HOME_DIR="$TESTHOME" DRY_RUN=0 reload_tmux_config) >/dev/null 2>&1
  if grep -Fxq "source-file $TESTHOME/.tmux.conf" "$FARM_LOG"; then
    ok "setup.sh sources the managed .tmux.conf into a running tmux server"
  else
    fail "setup.sh did not source .tmux.conf into the running server"
  fi
  : > "$FARM_LOG"
  (PATH="$FARM:$PATH" FAKE_TMUX_LS_RC=1 HOME_DIR="$TESTHOME" DRY_RUN=0 reload_tmux_config) >/dev/null 2>&1
  if ! grep -q '^source-file' "$FARM_LOG"; then
    ok "setup.sh skips the reload on a stale socket with no live server"
  else
    fail "setup.sh sourced .tmux.conf with no live server behind the socket"
  fi
  rm "$TMUX_SOCK"

  # A real tmux whose only session is detached — the reconnect case, where
  # `tmux info` fails — on a private socket dir, never the developer's server.
  if command -v tmux >/dev/null 2>&1; then
    REAL_TMUX_HOME="$(mktemp -d)"
    REAL_TMUX_DIR="$(mktemp -d)"
    printf 'set -g @dotfiles_reload_probe yes\n' > "$REAL_TMUX_HOME/.tmux.conf"
    (
      export TMUX_TMPDIR="$REAL_TMUX_DIR" HOME="$REAL_TMUX_HOME"
      # An explicit command, not the default login shell, so no startup file
      # (the developer's or the throwaway HOME's) ever runs.
      tmux -f /dev/null new-session -d -s probe 'sleep 60' || exit 1
      HOME_DIR="$REAL_TMUX_HOME" DRY_RUN=0 reload_tmux_config >/dev/null 2>&1
      _probe="$(tmux show-options -gv @dotfiles_reload_probe 2>/dev/null)"
      tmux kill-server 2>/dev/null
      [ "$_probe" = yes ]
    )
    if [ $? -eq 0 ]; then
      ok "setup.sh reloads a real tmux server whose sessions are all detached"
    else
      fail "setup.sh did not reload a real server with only detached sessions"
    fi
    rm -rf "$REAL_TMUX_HOME" "$REAL_TMUX_DIR"

    # setup.sh and cct re-source the managed .tmux.conf into a long-lived
    # server, so sourcing it repeatedly must not grow its array options (#673).
    # Same private socket dir pattern; only the server started here is killed,
    # by its own PID.
    REAL_TMUX_DIR="$(mktemp -d)"
    _reload_out="$(
      export TMUX_TMPDIR="$REAL_TMUX_DIR"
      tmux -f /dev/null new-session -d -s idem 'sleep 60' || exit 1
      _pid="$(tmux display-message -p '#{pid}')"
      for _i in 1 2 3; do
        tmux source-file "$REPO_ROOT/.tmux.conf" || echo "source-failed"
      done
      for _opt in terminal-features terminal-overrides; do
        tmux show-options -sv "$_opt" | sort | uniq -d | sed "s/^/dup $_opt: /"
      done
      tmux show-options -sv terminal-features | grep -Fxq 'xterm*:extkeys' \
        || echo "missing terminal-features xterm*:extkeys"
      tmux show-options -sv terminal-overrides | grep -Eq '^,?xterm-256color:Tc$' \
        || echo "missing terminal-overrides xterm-256color:Tc"
      [ -n "$_pid" ] && kill "$_pid"
    )"
    if [ $? -eq 0 ] && [ -z "$_reload_out" ]; then
      ok "sourcing .tmux.conf three times leaves no duplicate array entries"
    else
      fail "re-sourcing .tmux.conf duplicates or drops array entries"
      printf '%s\n' "$_reload_out" | sed 's/^/      | /'
    fi
    rm -rf "$REAL_TMUX_DIR"
  else
    ok "real-tmux detached-session reload skipped (tmux not installed) # SKIP"
  fi
  CCT_HOME="$(mktemp -d)"
  : > "$CCT_HOME/.tmux.conf"
  mkdir -p "$CCT_HOME/proj"
  for _rc in 0 1; do
    : > "$FARM_LOG"
    (cd "$CCT_HOME/proj" && PATH="$FARM:$PATH" FAKE_TMUX_LS_RC=$_rc HOME="$CCT_HOME" \
      bash -c '. "$1" && cct' _ "$REPO_ROOT/.bash_aliases") >/dev/null 2>&1
    _src="$(grep -n '^source-file' "$FARM_LOG" | cut -d: -f1)"
    _new="$(grep -n '^new-session' "$FARM_LOG" | cut -d: -f1)"
    if [ "$_rc" -eq 0 ]; then
      if [ "$(sed -n "${_src:-0}p" "$FARM_LOG" 2>/dev/null)" = "source-file $CCT_HOME/.tmux.conf" ] \
        && [ -n "$_new" ] && [ "$_src" -lt "$_new" ]; then
        ok "cct sources ~/.tmux.conf into a running server before launching"
      else
        fail "cct did not reload ~/.tmux.conf before launching"
        sed 's/^/      | log: /' "$FARM_LOG"
      fi
    elif [ -z "$_src" ] && [ -n "$_new" ]; then
      ok "cct skips the reload when no tmux server is running"
    else
      fail "cct reload behaviour wrong with no running server"
      sed 's/^/      | log: /' "$FARM_LOG"
    fi
  done
  rm -rf "$FARM" "$FARM_LOG" "$FARM_OUT" "$CCT_HOME"
fi

# Agent-service selection (issue #425) exercises the same dry-run contract per
# selection; it runs from here so the existing CI step covers it.
if "$REPO_ROOT/claude/scripts/tests/setup-services.test.sh"; then
  ok "setup-services suite passed"
else
  fail "setup-services suite failed (output above)"
fi

# The public settings template and setup.sh's seed of it (issue #588) run
# from here too, so the existing CI step covers them.
if "$REPO_ROOT/claude/scripts/tests/settings-example.test.sh"; then
  ok "settings-example suite passed"
else
  fail "settings-example suite failed (output above)"
fi
# The template runs statusline.sh with `bash`; its renderer suite rides here
# too. The bash 3.2 case runs only when STATUSLINE_BASH3 names one.
if "$REPO_ROOT/claude/scripts/tests/statusline.test.sh"; then
  ok "statusline suite passed"
else
  fail "statusline suite failed (output above)"
fi
# Command parsing in the PreToolUse Bash hooks (worktree-guard,
# conventional-commit, PreMergeCodexHarvest) rides here too, so the existing
# CI step covers it.
if "$REPO_ROOT/claude/scripts/tests/hook-guards.test.sh"; then
  ok "hook-guards suite passed"
else
  fail "hook-guards suite failed (output above)"
fi

echo ""
echo "setup-dry-run: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
