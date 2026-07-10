#!/bin/bash
# Bootstrap a dev environment with Claude Code config and tools.
# Works on macOS, WSL (Ubuntu), and native Linux.
# Run from the dotfiles repo root: ./setup.sh
#
# Uses symlinks so edits to ~/.claude/* automatically stay in sync
# with this repo.

set -euo pipefail
trap 'echo "[setup.sh] FAILED at line $LINENO" >&2; exit 1' ERR

# Track total setup duration for the completion summary (M5).
SETUP_START=$(date +%s)

# DRY_RUN: when 1, destructive ops are printed instead of executed.
# Set by the --dry-run flag in the arg-parse loop below (M6).
DRY_RUN="${DRY_RUN:-0}"

# ASSUME_YES: when 1 (--yes), every interactive prompt takes a safe default
# instead of blocking on stdin, and browser-login steps are skipped — so the
# installer can run unattended (e.g. the CI dry-run smoke). Set by --yes below.
ASSUME_YES="${ASSUME_YES:-0}"

# ask_yn <default: Y|N> <prompt-text> — sets the global `yn`. Under --yes it
# substitutes <default> without reading stdin; otherwise it prompts as before
# (`|| true` so an EOF on piped stdin doesn't abort under set -e).
ask_yn() {
  local __def="$1" __msg="$2"
  if [ "$ASSUME_YES" = "1" ]; then
    yn="$__def"
    echo "  -> [--yes] $__msg$__def"
  else
    yn=""
    read -rp "$__msg" yn || true
  fi
}

# run(): wrap destructive operations. Prints [DRY] $* when DRY_RUN=1,
# otherwise executes "$@". Use ONLY for destructive ops (installs,
# network downloads, writes outside the repo). Read-only checks
# (command -v, grep, test) should remain bare to avoid noise.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY] $*"
  else
    "$@"
  fi
}

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolved once here; audit_link validates every source path against it, so
# recomputing realpath per-file (once per managed link) would be pure overhead.
DOTFILES_REAL="$(realpath "$DOTFILES_DIR" 2>/dev/null || echo "$DOTFILES_DIR")"
HOME_DIR="$HOME"
# Dev dir: derived from dotfiles repo location (parent of this repo).
# Defined early so it can be used throughout (was previously set mid-script,
# which broke any earlier reference — e.g. safe.directory ending up as "/claude-memory").
DEV_DIR="$(dirname "$DOTFILES_DIR")"
# Private companion repo (settings.json + identity + auto-memory). Optional.
# Derived from DEV_DIR (not hardcoded ~/dev) so a checkout under ~/code etc.
# still finds its sibling claude-memory repo.
BOOTSTRAP_SCRIPT="$DEV_DIR/claude-memory/bootstrap.sh"

# Bootstrap exit code surfaced in final summary. 0 = not run or success.
BOOTSTRAP_RC=0

# Shared symlink enumerator (issue #135): the claude/ tree walk + nolink loading
# live in lib-symlinks.sh, sourced by both setup.sh and check-claude.sh so the
# install linking, the health audit, and the standalone checker can't drift.
# Resolve it from this script's own directory (DOTFILES_DIR), not the cwd.
# shellcheck source=lib-symlinks.sh
source "$DOTFILES_DIR/lib-symlinks.sh"

# Shared link-state classifier (issue #199): check_link_state lives in
# lib-checks.sh, shared with the three check-* scripts so audit_link's state
# machine can't drift from the standalone checkers. Hard-fail with a clear
# message if it's missing (set -e would abort on the failed source anyway,
# but with an opaque error).
if [ ! -f "$DOTFILES_DIR/lib-checks.sh" ]; then
  echo "FATAL: $DOTFILES_DIR/lib-checks.sh is missing (broken checkout — restore it with 'git checkout lib-checks.sh')" >&2
  exit 1
fi
# shellcheck source=lib-checks.sh
source "$DOTFILES_DIR/lib-checks.sh"

# Counters for summary
LINKS_CREATED=0
LINKS_VERIFIED=0
LINKS_BROKEN=0

# ─── Symlink health audit (--check / --repair) ──────────────────────
# Checks ALL symlinks: dotfiles AND claude-memory (bootstrap.sh)
run_health_audit() {
  local mode="$1"  # "check" or "repair"
  local errors=0
  local verified=0
  local repaired=0

  echo "=== Symlink Health Audit (mode: $mode) ==="
  echo ""

  # ── Dotfiles symlinks ──
  echo "--- Dotfiles symlinks ---"
  local CLAUDE_SRC="$DOTFILES_DIR/claude"
  local CLAUDE_DST="$HOME_DIR/.claude"
  # The claude/ tree (top-level → hooks → skills → agents → scripts → chrome,
  # nolink-filtered) comes from the shared enumerator (lib-symlinks.sh). CLAUDE.md
  # IS linked, so it's audited. The audit ignores the enumerator's executable
  # flag for tree entries (historical behavior: +x is only enforced on bin
  # scripts below). Hard-fail loudly if the nolink manifest is missing rather
  # than silently auditing nothing.
  if ! symlink_require_manifest "$CLAUDE_SRC"; then
    printf '  \033[31mFATAL\033[0m claude/nolink.txt missing at %s — cannot audit\n' "$CLAUDE_SRC/nolink.txt"
    errors=$((errors + 1))
  else
    local _src _dst _label _flags
    while IFS=$'\t' read -r _src _dst _label _flags; do
      [ -n "$_src" ] || continue
      alink "$_src" "$_dst" "$_label" "$mode"
    done < <(symlink_enumerate "$CLAUDE_SRC" "$CLAUDE_DST")
  fi

  # Bin scripts (top-level dotfiles helpers → ~/.local/bin) — kept separate from
  # the claude/ tree (they land outside ~/.claude). `executable` tells audit_link
  # to also enforce the +x bit so an un-executable source script doesn't pass
  # health checks while still failing at runtime.
  local bin_src
  for bin in gh-bootstrap.sh git-hygiene.sh hygiene-status.sh; do
    bin_src="$DOTFILES_DIR/$bin"
    [ -f "$bin_src" ] || continue
    alink "$bin_src" "$HOME_DIR/.local/bin/$bin" "bin/$bin" "$mode" "executable"
  done

  echo ""

  # ── Claude-memory symlinks (via bootstrap.sh --check) ──
  echo "--- Claude-memory symlinks ---"
  if [ -f "$BOOTSTRAP_SCRIPT" ]; then
    if bash "$BOOTSTRAP_SCRIPT" --check; then
      echo "  All claude-memory symlinks OK"
    else
      errors=$((errors + 1))
      if [ "$mode" = "repair" ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
          echo "  [DRY] would repair claude-memory symlinks via $BOOTSTRAP_SCRIPT"
        else
          echo "  Repairing claude-memory symlinks..."
          bash "$BOOTSTRAP_SCRIPT" && echo "  Repaired." || echo "  Repair failed."
        fi
      fi
    fi
  else
    echo "  (bootstrap.sh not found at $BOOTSTRAP_SCRIPT — skipping claude-memory checks)"
  fi

  echo ""
  echo "=== Audit Summary ==="
  echo "  Verified: $verified"
  [ "$mode" = "repair" ] && echo "  Repaired: $repaired"
  echo "  Broken:   $errors"

  # Expose the audit tallies to the script-level summary block (M5). Note:
  # LINKS_CREATED is owned by link_file (links made during install) — the audit
  # must NOT overwrite it, since the end-of-run audit is check-mode (repaired=0).
  LINKS_VERIFIED="$verified"
  LINKS_BROKEN="$errors"

  [ "$errors" -eq 0 ] && return 0 || return 1
}

# Enforce +x on a bin-script source when require=executable, regardless of
# which audit_link branch (already-linked vs repaired-from-broken/missing)
# detected the link state. Codex P2 on PR #53: the executable check used to
# fire only in the already-linked branch, so `--repair` on a MISSING or
# BROKEN bin entry recreated the link but left the source 644 — first call
# from PATH still hit `Permission denied`.
#
# Returns:
#   0 — source already +x, OR repair-mode chmod just succeeded (drift fixed)
#   1 — drift present AND (check-mode OR chmod failed)
#
# Codex P2 on PR #53 (third pass): the prior revision returned 1 even after
# a successful chmod in repair mode, so `audit_link "$require=executable"
# || return 1` propagated failure and `setup.sh --repair` exited non-zero
# after fixing the bit. Repair-success must read as success at the call
# site; the chmod-failed and check-mode paths remain non-zero so the audit
# summary still reflects unfixed drift.
enforce_executable_bit() {
  local src_real="$1" label="$2" mode="$3"
  if [ -x "$src_real" ]; then
    return 0
  fi
  printf '  \033[31mNOT EXECUTABLE\033[0m  %s (source lacks +x: %s)\n' "$label" "$src_real"
  if [ "$mode" = "repair" ]; then
    # --dry-run --repair: preview only; the bit stays unfixed (#133).
    if [ "${DRY_RUN:-0}" = "1" ]; then
      printf '  [DRY] would chmod +x %s\n' "$src_real"
      return 1
    fi
    # Check chmod's exit status explicitly: audit_link runs under `|| rc=$?`
    # in the alink wrapper, which suppresses set -e for commands inside the
    # function. A silent chmod failure (e.g.
    # EPERM on a read-only checkout) must NOT print FIXED.
    if chmod +x "$src_real" 2>/dev/null; then
      printf '  \033[32mFIXED\033[0m   %s (chmod +x)\n' "$label"
      return 0
    fi
    printf '  \033[31mFAILED\033[0m  %s (chmod +x failed; check ownership/permissions)\n' "$label"
  fi
  return 1
}

# Check a single symlink.
# Returns: 0 = OK (already correct), 2 = repaired (repair mode, fix applied),
#          1 = broken/unfixed (check mode, or a repair that couldn't be applied).
audit_link() {
  local src="$1" dst="$2" label="$3" mode="$4" require="${5:-}"
  local src_real
  src_real="$(realpath "$src" 2>/dev/null)" || {
    printf '  \033[31mINVALID\033[0m %s source cannot be resolved: %s\n' "$label" "$src"
    return 1
  }
  case "$src_real" in
    "$DOTFILES_REAL"/*) ;;
    *)
      printf '  \033[31mINVALID\033[0m %s source outside dotfiles: %s\n' "$label" "$src_real"
      return 1
      ;;
  esac
  # State classification is shared with the check-* scripts (lib-checks.sh,
  # issue #199); the repair/reporting policy below stays audit-specific.
  local state
  state="$(check_link_state "$src" "$dst")"
  case "$state" in
    OK)
      # Symlink resolves to the right file — for executable entrypoints we
      # also enforce the +x bit on the source so a freshly-cloned host with
      # 644-mode bin scripts can't show all-green while `gh-bootstrap`
      # silently returns "Permission denied" when invoked from PATH.
      if [ "$require" = "executable" ]; then
        enforce_executable_bit "$src_real" "$label" "$mode" || return 1
      fi
      return 0  # OK
      ;;
    WRONG|BROKEN)
      printf '  \033[31mBROKEN\033[0m  %s -> %s (expected %s)\n' "$label" "$(readlink "$dst")" "$src"
      if [ "$mode" = "repair" ]; then
        # --dry-run --repair previews fixes without applying them (#133):
        # print the would-fix line and report the entry as still broken.
        if [ "${DRY_RUN:-0}" = "1" ]; then
          printf '  [DRY] would fix %s (rm + relink to %s)\n' "$label" "$src"
          return 1
        fi
        rm "$dst"
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        printf '  \033[32mFIXED\033[0m   %s\n' "$label"
        # Codex P2 on PR #53: repair-path executable enforcement. Without
        # this, a MISSING/BROKEN bin link gets recreated but the source
        # stays 644 and `gh-bootstrap` keeps returning Permission denied.
        if [ "$require" = "executable" ]; then
          enforce_executable_bit "$src_real" "$label" "$mode" || true
        fi
        return 2
      fi
      return 1
      ;;
    NOT_LINKED_FILE)
      printf '  \033[33mNOT LINKED\033[0m  %s (regular file, not symlink)\n' "$label"
      if [ "$mode" = "repair" ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
          printf '  [DRY] would fix %s (back up %s to %s.backup + link to %s)\n' "$label" "$dst" "$dst" "$src"
          return 1
        fi
        mv "$dst" "$dst.backup"
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        printf '  \033[32mFIXED\033[0m   %s (old file backed up to %s.backup)\n' "$label" "$label"
        if [ "$require" = "executable" ]; then
          enforce_executable_bit "$src_real" "$label" "$mode" || true
        fi
        return 2
      fi
      return 1
      ;;
    NOT_LINKED_OTHER)
      # Directory/fifo/… sits where a symlink belongs. Previously this fell
      # through as OK; now it's reported. Never auto-repaired — replacing a
      # populated directory is ambiguous, and relinking into it would drop
      # the symlink *inside* it rather than at $dst.
      printf '  \033[33mNOT LINKED\033[0m  %s (exists but is not a regular file or symlink — resolve manually)\n' "$label"
      return 1
      ;;
    MISSING)
      printf '  \033[33mMISSING\033[0m  %s\n' "$label"
      if [ "$mode" = "repair" ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
          printf '  [DRY] would fix %s (link to %s)\n' "$label" "$src"
          return 1
        fi
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        printf '  \033[32mFIXED\033[0m   %s\n' "$label"
        if [ "$require" = "executable" ]; then
          enforce_executable_bit "$src_real" "$label" "$mode" || true
        fi
        return 2
      fi
      return 1
      ;;
  esac
  return 0
}

# Run audit_link and fold its result into the verified/repaired/errors tallies:
# 0 = already OK, 2 = repaired this run, anything else = broken/unfixed. Relies
# on bash dynamic scope — those three names are locals of run_health_audit, the
# only caller. `|| rc=$?` keeps set -e from aborting on audit_link's non-zero.
alink() {
  local rc=0
  audit_link "$@" || rc=$?
  case "$rc" in
    0) verified=$((verified + 1)) ;;
    2) repaired=$((repaired + 1)) ;;
    *) errors=$((errors + 1)) ;;
  esac
  return 0
}

# Flags. We do TWO passes so flag order doesn't matter: first set DRY_RUN,
# then handle action flags (--check/--repair/--help) which exit.
#
# Supported flags:
#   --dry-run          Print destructive ops via run() instead of executing them
#   --check            Run symlink health audit and exit
#   --repair           Run symlink audit + repair and exit
#   --help / -h        Print this help and exit
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<'HELP'
Usage: ./setup.sh [flags]

Flags:
  --dry-run      Show destructive ops without executing (installs, downloads)
  --yes, -y      Non-interactive: take safe defaults for every prompt and skip
                 the browser-login steps (for unattended/CI runs)
  --check        Run symlink health audit and exit
  --repair       Audit symlinks and recreate broken ones, then exit
                 (combine with --dry-run to preview fixes without applying)
  --help, -h     Show this help

Environment:
  GIT_NAME       Pre-populate git user.name
  GIT_EMAIL      Pre-populate git user.email
HELP
      exit 0
      ;;
    --check)  _rc=0; run_health_audit "check"  || _rc=$?; exit "$_rc" ;;
    --repair) _rc=0; run_health_audit "repair" || _rc=$?; exit "$_rc" ;;
  esac
done

# ─── Platform detection ──────────────────────────────────────────────
detect_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PLATFORM="macos"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl"
  else
    PLATFORM="linux"
  fi
  echo "Detected platform: $PLATFORM"
}

# Helper: create a symlink, backing up any existing file.
# No-op when the link already points at the right source, so re-running setup.sh
# doesn't needlessly rm+recreate every link (churns inodes for zero benefit).
# Increments LINKS_CREATED only when it actually creates a link, so the summary
# reports links made THIS run (0 on a clean re-run, not a constant).
# DRY_RUN is honored HERE, inside the helper, so every call site is covered
# (issue #133: call sites outside the guard used to back up and replace real
# files under --dry-run). An already-correct link is a no-op in both modes.
link_file() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ ! -L "$dst" ] && [ -f "$dst" ]; then
      echo "  [DRY] would back up $dst to $dst.backup"
    fi
    echo "  [DRY] would link $dst -> $src"
    return 0
  fi
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -f "$dst" ]; then
    mv "$dst" "$dst.backup"
    echo "  -> backed up existing $dst to $dst.backup"
  fi
  ln -s "$src" "$dst"
  LINKS_CREATED=$((LINKS_CREATED + 1))
}

detect_platform

echo "=== Dotfiles setup from $DOTFILES_DIR ==="

# ─── 1. System packages ───────────────────────────────────────────────
echo ""
echo "--- Installing system packages ---"
MISSING_PKGS=""
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || MISSING_PKGS="$MISSING_PKGS $cmd"
done

# Modern CLI stack the Claude config mandates (rg/fd/bat/eza — issue #204):
# a fresh machine must not violate the guidance it just installed. Package
# names differ per manager (apt: ripgrep/fd-find/bat/eza; brew: ripgrep/fd/
# bat/eza), and Ubuntu ships the binaries as fdfind/batcat (shimmed below).
MISSING_APT=""
MISSING_BREW=""
command -v rg &>/dev/null || { MISSING_APT="$MISSING_APT ripgrep"; MISSING_BREW="$MISSING_BREW ripgrep"; }
command -v fd &>/dev/null || command -v fdfind &>/dev/null \
  || { MISSING_APT="$MISSING_APT fd-find"; MISSING_BREW="$MISSING_BREW fd"; }
command -v bat &>/dev/null || command -v batcat &>/dev/null \
  || { MISSING_APT="$MISSING_APT bat"; MISSING_BREW="$MISSING_BREW bat"; }
# eza is installed on its own line below: it's absent from older Ubuntu/Debian
# apt archives, and one unknown package fails the whole apt install.
MISSING_EZA=0
command -v eza &>/dev/null || MISSING_EZA=1

if [ -n "$MISSING_PKGS" ] || [ -n "$MISSING_APT" ] || [ "$MISSING_EZA" -eq 1 ]; then
  echo "Missing packages:$MISSING_PKGS$MISSING_BREW$([ "$MISSING_EZA" -eq 1 ] && echo ' eza')"
  if [[ "$PLATFORM" == "macos" ]]; then
    if ! command -v brew &>/dev/null; then
      echo "Homebrew not found. Install it first:"
      echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      exit 1
    fi
    ask_yn "Y" "Install via brew? [Y/n] "
    [[ "${yn:-}" =~ ^[Nn] ]] && { echo "Skipping. Install manually and re-run."; exit 1; }
    [ "$MISSING_EZA" -eq 1 ] && MISSING_BREW="$MISSING_BREW eza"
    # shellcheck disable=SC2086  # word-splitting intentional for pkg list
    run brew install $MISSING_PKGS $MISSING_BREW || true
  else
    ask_yn "Y" "Install via apt? (requires sudo) [Y/n] "
    [[ "${yn:-}" =~ ^[Nn] ]] && { echo "Skipping. Install manually and re-run."; exit 1; }
    # shellcheck disable=SC2086  # word-splitting intentional for pkg list
    run sudo apt update && run sudo apt install -y $MISSING_PKGS $MISSING_APT unzip
    if [ "$MISSING_EZA" -eq 1 ]; then
      run sudo apt install -y eza \
        || echo "  -> eza not in this release's apt archive; install manually (https://eza.rocks)"
    fi
  fi
else
  echo "All required packages already installed."
fi

# Ubuntu/Debian name shims: apt installs the binaries as fdfind (fd-find) and
# batcat (bat), but the config — and muscle memory — call them fd and bat.
# Symlink the canonical names into ~/.local/bin (already on PATH via §7).
# Idempotent (ln -sf) and skipped when the canonical name already resolves.
if [[ "$PLATFORM" != "macos" ]]; then
  for _shim in fd:fdfind bat:batcat; do
    _want="${_shim%%:*}"; _have="${_shim##*:}"
    if ! command -v "$_want" &>/dev/null && command -v "$_have" &>/dev/null; then
      run mkdir -p "$HOME_DIR/.local/bin"
      run ln -sf "$(command -v "$_have")" "$HOME_DIR/.local/bin/$_want"
      echo "  -> shimmed $_want -> $(command -v "$_have") (~/.local/bin/$_want)"
    fi
  done
fi

# ─── 1b. Audio (WSL only — ALSA → PulseAudio for WSLg) ──────────────
if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "--- ALSA → PulseAudio routing (WSL, needed for /voice) ---"
  ask_yn "N" "Set up audio routing for Claude /voice? (requires sudo) [y/N] "
  if [[ "${yn:-}" =~ ^[Yy] ]]; then
    run sudo apt install -y pulseaudio-utils libasound2-plugins alsa-utils
    link_file "$DOTFILES_DIR/.asoundrc" "$HOME_DIR/.asoundrc"
    run sudo cp "$DOTFILES_DIR/.asoundrc" /etc/asound.conf
    echo "  -> .asoundrc linked, /etc/asound.conf written"
  else
    echo "  -> Skipped audio setup"
  fi
fi

# ─── 1c. Dotfiles bin scripts → ~/.local/bin ────────────────────────
# Top-level helper scripts (gh-bootstrap.sh, git-hygiene.sh, hygiene-status.sh)
# ship in $DOTFILES_DIR but aren't on PATH on their own. ~/.local/bin is
# already added to PATH by the shell config in section 7, so symlinking
# there makes them callable as plain commands from any cwd.
echo ""
echo "--- Linking dotfiles bin scripts ---"
# Route every filesystem mutation through `run` so --dry-run actually shows a
# preview without creating ~/.local/bin or replacing existing entries. `chmod
# +x` is defensive — the scripts are committed 100755 (see git log), but a
# user whose checkout dropped the mode bit (e.g. fetched via an archive that
# strips it) would otherwise wind up with PATH entries that fail at
# Permission denied. Skip chmod when the bit is already set, and tolerate
# EPERM on read-only / non-owner checkouts.
run mkdir -p "$HOME_DIR/.local/bin"
for _bin in gh-bootstrap.sh git-hygiene.sh hygiene-status.sh; do
  _src="$DOTFILES_DIR/$_bin"
  if [ ! -f "$_src" ]; then
    echo "  -> $_bin not found in dotfiles, skipping"
    continue
  fi
  if [ ! -x "$_src" ]; then
    if ! run chmod +x "$_src" 2>/dev/null; then
      echo "  -> $_bin: source not executable and chmod failed (read-only checkout?); skipping link"
      continue
    fi
  fi
  # link_file honors DRY_RUN itself (prints the would-link preview).
  link_file "$_src" "$HOME_DIR/.local/bin/$_bin"
  echo "  -> $_bin linked into ~/.local/bin"
done

# ─── 1d. gitleaks + pre-push secret scan ─────────────────────────────
# gitleaks was CI-only, but a secret is public the moment it's pushed — before
# CI ever fails (issue #204). Install it locally and wire githooks/pre-push
# into this repo's hooks dir so the scan blocks the push itself.
#
# Install path mirrors the bun installer above: pin the BINARY RELEASE version
# and verify the download against that release's own checksums manifest — a
# release tag is immutable, so the checksum can't drift under us. To bump:
# set GITLEAKS_VERSION to a newer tag from
# https://github.com/gitleaks/gitleaks/releases — no hash to hand-maintain.
GITLEAKS_VERSION="8.30.1"

# sha256 of a file, portable across Linux (sha256sum) and macOS (shasum).
# Shared by the pinned gitleaks (here) and bun (§2b) installers.
_sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Map this host to a gitleaks release asset basename (tar.gz), e.g.
# gitleaks_8.30.1_linux_x64.tar.gz / gitleaks_8.30.1_darwin_arm64.tar.gz.
gitleaks_asset_name() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) return 1 ;;
  esac
  echo "gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
}

install_gitleaks_pinned() {
  local asset
  asset="$(gitleaks_asset_name)" || {
    echo "  -> Unsupported platform/arch for pinned gitleaks install; skipping"
    return 1
  }
  local base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"

  echo "  -> Installing gitleaks v${GITLEAKS_VERSION} (${asset}) from GitHub release"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would download ${base}/${asset}"
    echo "  [DRY] would verify against gitleaks_${GITLEAKS_VERSION}_checksums.txt and install to ~/.local/bin/gitleaks"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)" || { echo "  -> mktemp failed; skipping gitleaks install"; return 1; }
  trap 'rm -rf "$tmpdir"' RETURN

  if ! curl -fsSL "${base}/${asset}" -o "$tmpdir/$asset"; then
    echo "  -> Download failed (${base}/${asset}); skipping gitleaks install"
    return 1
  fi
  if ! curl -fsSL "${base}/gitleaks_${GITLEAKS_VERSION}_checksums.txt" -o "$tmpdir/checksums.txt"; then
    echo "  -> Checksum manifest download failed; skipping gitleaks install"
    return 1
  fi

  local expected actual
  expected="$(awk -v f="$asset" '$2 == f {print $1}' "$tmpdir/checksums.txt")"
  if [ -z "$expected" ]; then
    echo "  -> ${asset} not listed in the checksums manifest for v${GITLEAKS_VERSION}; skipping"
    return 1
  fi
  actual="$(_sha256 "$tmpdir/$asset")" || {
    echo "  -> No sha256 tool (sha256sum/shasum) available; skipping gitleaks install"
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    echo "  -> SHA-256 mismatch for ${asset} — refusing to install."
    echo "     Expected: $expected"
    echo "     Got:      $actual"
    echo "     Likely a corrupted download; retry. If it persists, verify the"
    echo "     release at https://github.com/gitleaks/gitleaks/releases/tag/v${GITLEAKS_VERSION}"
    return 1
  fi
  echo "  -> SHA-256 verified; extracting"

  if ! tar -xzf "$tmpdir/$asset" -C "$tmpdir" gitleaks; then
    echo "  -> tar extract failed; skipping gitleaks install"
    return 1
  fi
  mkdir -p "$HOME_DIR/.local/bin"
  install -m 755 "$tmpdir/gitleaks" "$HOME_DIR/.local/bin/gitleaks"
  echo "  -> gitleaks installed to ~/.local/bin/gitleaks"
}

echo ""
echo "--- gitleaks (local secret scanning) ---"
if command -v gitleaks &>/dev/null; then
  echo "gitleaks already installed: $(gitleaks version 2>/dev/null || echo 'installed')"
elif [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null; then
  run brew install gitleaks || echo "  -> gitleaks install failed (continuing; pre-push scan will warn+skip)"
else
  # Not in Ubuntu/Debian apt archives, so the pinned release binary is the
  # Linux path (and the macOS fallback when brew is absent).
  install_gitleaks_pinned || echo "  -> gitleaks install skipped; pre-push scan will warn+skip until installed"
fi

# Wire the tracked githooks/pre-push into THIS repo's hooks dir. link_file
# honors --dry-run. The hook blocks a push on findings, with a documented
# escape hatch: GITLEAKS_SKIP=1 git push
#
# Two sharp edges here (PR #226 review, both P2):
#   - core.hooksPath (any scope) redirects hooks to a dir SHARED across
#     repos; installing there would activate the hook everywhere and
#     link_file would back up (i.e. silently disable) any pre-push already
#     in it. Warn + skip instead — the user integrates by hand.
#   - When run from a linked worktree (agents do this routinely), the
#     worktree is temporary but <common-dir>/hooks is shared with the main
#     checkout. Link to the MAIN checkout's copy of the hook (parent of
#     --git-common-dir), never the worktree's — otherwise removing the
#     worktree leaves a dangling symlink that git silently ignores and the
#     secret scan vanishes without warning.
if [ -f "$DOTFILES_DIR/githooks/pre-push" ]; then
  _hooks_path_cfg="$(git -C "$DOTFILES_DIR" config --get core.hooksPath 2>/dev/null || true)"
  _git_common="$(git -C "$DOTFILES_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -z "$_git_common" ]; then
    echo "  -> not a git checkout; pre-push hook not installed"
  elif [ -n "$_hooks_path_cfg" ]; then
    echo "  -> core.hooksPath is set ($_hooks_path_cfg) — that hooks dir is shared across repos,"
    echo "     so not installing there (it would shadow or disable other repos' hooks)."
    echo "     Add a call to githooks/pre-push to your shared pre-push hook manually."
  else
    case "$_git_common" in /*) ;; *) _git_common="$DOTFILES_DIR/$_git_common" ;; esac
    _main_checkout="$(dirname "$_git_common")"
    _hook_src="$_main_checkout/githooks/pre-push"
    if [ ! -f "$_hook_src" ]; then
      # Bare repo, or the main checkout's branch predates githooks/. Never
      # fall back to the worktree copy — it dangles when the worktree goes.
      echo "  -> $_hook_src not found (main checkout lacks githooks/pre-push); hook not installed"
    else
      # Defensive +x on the source (same rationale as the §1c bin scripts).
      if [ ! -x "$_hook_src" ]; then
        run chmod +x "$_hook_src" 2>/dev/null || true
      fi
      run mkdir -p "$_git_common/hooks"
      link_file "$_hook_src" "$_git_common/hooks/pre-push"
      echo "  -> pre-push gitleaks hook linked ($_git_common/hooks/pre-push; skip once with GITLEAKS_SKIP=1 git push)"
    fi
  fi
fi

# ─── 2. Node.js (if not present) ─────────────────────────────────────
# Needed for npm-installed CLIs (Codex, §3c) — Claude Code itself now uses
# the native installer (§3) and no longer requires Node. On Linux/WSL the
# default is a PINNED nodejs.org binary release verified against that
# release's own SHASUMS256.txt — the same immutable-release pattern as bun
# (§2b) and gitleaks (§1d); no remote script is ever piped to bash. (Issue
# #204: this path used to print three options and exit 1 mid-install.)
# To bump: set NODE_VERSION to a newer tag from https://nodejs.org/dist/ —
# there is no hash to hand-maintain; the checksum comes from the release.
# Override with NODE_INSTALL_METHOD:
#   pinned (default) — checksum-verified nodejs.org binary into ~/.local
#   apt              — distro nodejs + npm (older, but fully distro-signed)
#   skip             — don't install Node (npm-dependent steps will skip)
NODE_VERSION="v24.18.0"

# Map this host to a nodejs.org release asset basename (no .tar.gz), e.g.
# node-v24.18.0-linux-x64. Linux only — macOS installs Node via brew.
node_asset_name() {
  local arch
  [ "$(uname -s)" = "Linux" ] || return 1
  case "$(uname -m)" in
    x86_64|amd64)  arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) return 1 ;;
  esac
  echo "node-${NODE_VERSION}-linux-${arch}"
}

install_node_pinned() {
  local asset
  asset="$(node_asset_name)" || {
    echo "  -> Unsupported platform/arch for pinned Node install; skipping"
    return 1
  }
  local base="https://nodejs.org/dist/${NODE_VERSION}"

  echo "  -> Installing Node.js ${NODE_VERSION} (${asset}) from nodejs.org"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would download ${base}/${asset}.tar.gz"
    echo "  [DRY] would verify against SHASUMS256.txt and install to ~/.local/share/${asset}"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)" || { echo "  -> mktemp failed; skipping Node install"; return 1; }
  trap 'rm -rf "$tmpdir"' RETURN

  if ! curl -fsSL "${base}/${asset}.tar.gz" -o "$tmpdir/node.tar.gz"; then
    echo "  -> Download failed (${base}/${asset}.tar.gz); skipping Node install"
    return 1
  fi
  if ! curl -fsSL "${base}/SHASUMS256.txt" -o "$tmpdir/SHASUMS256.txt"; then
    echo "  -> Checksum manifest download failed; skipping Node install"
    return 1
  fi

  local expected actual
  expected="$(awk -v f="${asset}.tar.gz" '$2 == f {print $1}' "$tmpdir/SHASUMS256.txt")"
  if [ -z "$expected" ]; then
    echo "  -> ${asset}.tar.gz not listed in SHASUMS256.txt for ${NODE_VERSION}; skipping"
    return 1
  fi
  actual="$(_sha256 "$tmpdir/node.tar.gz")" || {
    echo "  -> No sha256 tool (sha256sum/shasum) available; skipping Node install"
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    echo "  -> SHA-256 mismatch for ${asset}.tar.gz — refusing to install."
    echo "     Expected: $expected"
    echo "     Got:      $actual"
    echo "     Likely a corrupted download; retry. If it persists, verify the"
    echo "     release at ${base}/"
    return 1
  fi
  echo "  -> SHA-256 verified; extracting"

  if ! tar -xzf "$tmpdir/node.tar.gz" -C "$tmpdir"; then
    echo "  -> tar extract failed; skipping Node install"
    return 1
  fi
  mkdir -p "$HOME_DIR/.local/share" "$HOME_DIR/.local/bin"
  rm -rf "$HOME_DIR/.local/share/${asset}"
  mv "$tmpdir/${asset}" "$HOME_DIR/.local/share/${asset}"
  local tool
  for tool in node npm npx corepack; do
    [ -e "$HOME_DIR/.local/share/${asset}/bin/$tool" ] || continue
    ln -sf "$HOME_DIR/.local/share/${asset}/bin/$tool" "$HOME_DIR/.local/bin/$tool"
  done
  echo "  -> Node installed to ~/.local/share/${asset} (node/npm/npx linked into ~/.local/bin)"
}

if ! command -v node &>/dev/null; then
  echo ""
  echo "--- Installing Node.js ---"
  if [[ "$PLATFORM" == "macos" ]]; then
    run brew install node
  else
    NODE_INSTALL_METHOD="${NODE_INSTALL_METHOD:-pinned}"
    case "$NODE_INSTALL_METHOD" in
      skip)
        echo "  -> NODE_INSTALL_METHOD=skip; not installing Node (Codex npm install will fail until Node exists)"
        ;;
      apt)
        run sudo apt install -y nodejs npm \
          || echo "  -> Node install via apt failed (continuing; npm-dependent steps will be skipped)"
        ;;
      pinned|*)
        install_node_pinned \
          || echo "  -> Node install skipped (continuing; npm-dependent steps will be skipped)"
        ;;
    esac
    # Make the fresh install resolvable for the remainder of this script.
    export PATH="$HOME_DIR/.local/bin:$PATH"
    if [ "${DRY_RUN:-0}" != "1" ] && ! command -v node &>/dev/null && [ "$NODE_INSTALL_METHOD" != "skip" ]; then
      echo "  !! WARNING: node still not found after install attempt; Codex (§3c) will not install"
    fi
  fi
else
  echo "Node.js already installed: $(node -v)"
fi

# ─── 2b. Bun (required by *.hook.ts files — #!/usr/bin/env bun) ───────
# StripProjectPermissions.hook.ts and any future TypeScript hooks run via
# bun at SessionStart. Missing bun = `cc` fails on first launch with a
# confusing "bun: not found" error.
#
# The TypeScript hooks run under bun via a hardcoded %h/.bun/bin/bun shebang
# (no PATH lookup), so we always ensure a symlink at ~/.bun/bin/bun pointing
# at whichever bun is on PATH — regardless of install method
# (brew, npm, curl installer).
# Install bun by pinning the BINARY RELEASE version and verifying the download
# against that release's own SHASUMS256.txt — NOT by pinning a SHA of the
# mutable bun.sh/install script (issue #140). The old approach hashed the
# installer script, which bun edits upstream independently of releases; the day
# it changed, every fresh clone hit a SHA mismatch and fell to "warn + skip,"
# silently disabling the TypeScript hooks. A release tag is immutable and its
# SHASUMS256.txt is generated per-release, so the checksum never drifts under us.
#
# To bump bun: set BUN_VERSION to a newer tag from
# https://github.com/oven-sh/bun/releases — there is NO hash to hand-maintain;
# the checksum is fetched from the release itself and verified at install time.
#
# Escape hatch: set BUN_UNPINNED=1 to skip the pinned path and run the upstream
# bun.sh/install script unverified (supply-chain risk). The default path
# downloads a pinned, checksum-verified binary.
BUN_VERSION="bun-v1.3.14"

# (_sha256 helper is defined in §1d, shared with the gitleaks installer.)

# Map this host to a bun release asset basename (no .zip), mirroring
# bun.sh/install's own os/arch/variant selection: -musl for musl libc,
# -baseline for x64 CPUs without AVX2 (avoids SIGILL on older hardware).
bun_asset_name() {
  local os arch target
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) return 1 ;;
  esac
  target="bun-${os}-${arch}"
  if [ "$os" = "linux" ] && ldd --version 2>&1 | grep -qi musl; then
    target="${target}-musl"
  fi
  if [ "$arch" = "x64" ]; then
    local has_avx2=1
    if [ "$os" = "linux" ]; then
      grep -qi avx2 /proc/cpuinfo 2>/dev/null || has_avx2=0
    else
      [ "$(sysctl -n hw.optional.avx2_0 2>/dev/null)" = "1" ] || has_avx2=0
    fi
    [ "$has_avx2" -eq 0 ] && target="${target}-baseline"
  fi
  echo "$target"
}

install_bun_pinned() {
  # Escape hatch: run the upstream installer unverified (pre-pin behavior).
  if [ "${BUN_UNPINNED:-0}" = "1" ]; then
    echo "  -> WARNING: BUN_UNPINNED=1 set; running unverified bun installer"
    echo "     (supply-chain risk — the pinned+verified path is the default)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would exec unverified bun installer"
      return 0
    fi
    run curl -fsSL https://bun.sh/install | bash
    return
  fi

  local asset
  asset="$(bun_asset_name)" || {
    echo "  -> Unsupported platform/arch for pinned bun install; skipping"
    return 1
  }
  local base="https://github.com/oven-sh/bun/releases/download/${BUN_VERSION}"

  echo "  -> Installing bun ${BUN_VERSION} (${asset}) from GitHub release"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would download ${base}/${asset}.zip"
    echo "  [DRY] would verify against SHASUMS256.txt and extract to ~/.bun/bin/bun"
    return 0
  fi

  command -v unzip &>/dev/null || {
    echo "  -> 'unzip' not found; install it and re-run (skipping bun install)"
    return 1
  }

  local tmpdir
  tmpdir="$(mktemp -d)" || { echo "  -> mktemp failed; skipping bun install"; return 1; }
  trap 'rm -rf "$tmpdir"' RETURN

  if ! curl -fsSL "${base}/${asset}.zip" -o "$tmpdir/bun.zip"; then
    echo "  -> Download failed (${base}/${asset}.zip); skipping bun install"
    return 1
  fi
  if ! curl -fsSL "${base}/SHASUMS256.txt" -o "$tmpdir/SHASUMS256.txt"; then
    echo "  -> Checksum manifest download failed; skipping bun install"
    return 1
  fi

  local expected actual
  expected="$(awk -v f="${asset}.zip" '$2 == f {print $1}' "$tmpdir/SHASUMS256.txt")"
  if [ -z "$expected" ]; then
    echo "  -> ${asset}.zip not listed in SHASUMS256.txt for ${BUN_VERSION}; skipping"
    return 1
  fi
  actual="$(_sha256 "$tmpdir/bun.zip")" || {
    echo "  -> No sha256 tool (sha256sum/shasum) available; skipping bun install"
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    echo "  -> SHA-256 mismatch for ${asset}.zip — refusing to install."
    echo "     Expected: $expected"
    echo "     Got:      $actual"
    echo "     Likely a corrupted download; retry. If it persists, verify the"
    echo "     release at https://github.com/oven-sh/bun/releases/tag/${BUN_VERSION}"
    return 1
  fi
  echo "  -> SHA-256 verified; extracting"

  if ! unzip -q -o "$tmpdir/bun.zip" -d "$tmpdir"; then
    echo "  -> unzip failed; skipping bun install"
    return 1
  fi
  if [ ! -f "$tmpdir/${asset}/bun" ]; then
    echo "  -> Extracted archive missing ${asset}/bun; skipping bun install"
    return 1
  fi
  mkdir -p "$HOME/.bun/bin"
  install -m 755 "$tmpdir/${asset}/bun" "$HOME/.bun/bin/bun"
  echo "  -> bun installed to ~/.bun/bin/bun"
}

if ! command -v bun &>/dev/null && [ ! -x "$HOME/.bun/bin/bun" ]; then
  echo ""
  echo "--- Installing Bun (JS runtime for TypeScript hooks) ---"
  if [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null; then
    run brew install oven-sh/bun/bun
  else
    # Pinned + SHA-256-verified installer (see install_bun_pinned above).
    # Falls back gracefully (warn + skip) if verification fails or the
    # placeholder hash hasn't been filled in.
    install_bun_pinned || echo "  -> Bun install skipped; downstream features (voice hooks) may not work."
  fi
  # Make bun usable for the remainder of this script
  if [ -x "$HOME/.bun/bin/bun" ]; then
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
  fi
  echo "  -> Bun installed: $(bun --version 2>/dev/null || echo 'see installer output')"
else
  # Ensure current shell can find bun if only ~/.bun/bin exists on disk
  if ! command -v bun &>/dev/null && [ -x "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  echo "Bun already installed: $(bun --version 2>/dev/null || echo 'installed')"
fi

# Canonicalize bun at ~/.bun/bin/bun — the systemd unit and other scripts
# hardcode this path. If bun ended up somewhere else (brew, npm), drop a
# symlink so hardcoded paths keep working.
if command -v bun &>/dev/null && [ ! -e "$HOME/.bun/bin/bun" ]; then
  _bun_found="$(command -v bun)"
  run mkdir -p "$HOME/.bun/bin"
  run ln -sf "$_bun_found" "$HOME/.bun/bin/bun"
  echo "  -> bun symlinked: ~/.bun/bin/bun -> $_bun_found"
fi
if [ ! -e "$HOME/.bun/bin/bun" ]; then
  echo "  -> WARNING: ~/.bun/bin/bun is missing; TypeScript hooks may not run until bun is installed"
fi

# ─── 3. Claude Code CLI ──────────────────────────────────────────────
# Official native installer (verified against https://code.claude.com/docs/en/setup
# 2026-07-10): https://claude.ai/install.sh for macOS, Linux, and WSL.
# Replaces the legacy `npm install -g @anthropic-ai/claude-code` path (issue
# #204) — the native install auto-updates in the background and doesn't
# depend on Node. Installs to ~/.local/bin/claude (on PATH via §7).
#
# The remote script is never piped straight into bash: it's downloaded to a
# temp file, verified against the sha256 pinned below, THEN executed. The
# installer script is mutable upstream, so on drift we fail CLOSED with
# update instructions. After reviewing a legitimate upstream change, refresh
# the pin with:  curl -fsSL https://claude.ai/install.sh | sha256sum
# Escape hatch: CLAUDE_INSTALL_UNPINNED=1 runs the current upstream script
# unverified (supply-chain risk — the pinned+verified path is the default).
CLAUDE_INSTALLER_SHA256="b3f79015b54c751440a6488f07b1b64f9088742b9052bc1bd356d13108320d2a"

install_claude_native() {
  if [ "${CLAUDE_INSTALL_UNPINNED:-0}" = "1" ]; then
    echo "  -> WARNING: CLAUDE_INSTALL_UNPINNED=1 set; running unverified Claude installer"
    echo "     (supply-chain risk — the pinned+verified path is the default)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would exec unverified Claude Code installer"
      return 0
    fi
    run bash -c "curl -fsSL https://claude.ai/install.sh | bash"
    return
  fi

  echo "  -> Installing Claude Code via the native installer (pinned sha256)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would download https://claude.ai/install.sh, verify its sha256, and execute it"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)" || { echo "  -> mktemp failed; skipping Claude install"; return 1; }
  trap 'rm -rf "$tmpdir"' RETURN

  if ! curl -fsSL https://claude.ai/install.sh -o "$tmpdir/install.sh"; then
    echo "  -> Download failed (https://claude.ai/install.sh); skipping Claude install"
    return 1
  fi
  local actual
  actual="$(_sha256 "$tmpdir/install.sh")" || {
    echo "  -> No sha256 tool (sha256sum/shasum) available; skipping Claude install"
    return 1
  }
  if [ "$actual" != "$CLAUDE_INSTALLER_SHA256" ]; then
    echo "  -> SHA-256 mismatch for install.sh — refusing to run it."
    echo "     Expected: $CLAUDE_INSTALLER_SHA256"
    echo "     Got:      $actual"
    echo "     The upstream installer changed. Review it (less $tmpdir/install.sh or"
    echo "     https://claude.ai/install.sh), then update CLAUDE_INSTALLER_SHA256 in"
    echo "     setup.sh, or bypass once with CLAUDE_INSTALL_UNPINNED=1."
    return 1
  fi
  echo "  -> SHA-256 verified; running installer"
  bash "$tmpdir/install.sh"
}

if ! command -v claude &>/dev/null; then
  echo ""
  echo "--- Installing Claude Code CLI (native installer) ---"
  install_claude_native \
    || echo "  -> Claude Code native install failed (continuing; see https://code.claude.com/docs/en/setup)"
  # Make claude resolvable for the remainder of this script (§3a/§3b need it).
  if [ -x "$HOME_DIR/.local/bin/claude" ]; then
    export PATH="$HOME_DIR/.local/bin:$PATH"
  fi
else
  echo "Claude Code already installed: $(claude --version 2>/dev/null || echo 'installed')"
fi

# ─── 3a. Claude Code authentication ──────────────────────────────────
# Plugin install and `cc` itself need an authenticated session. Detect
# unauth state via `claude auth status` (exit 0 + "loggedIn": true) and
# offer to run `claude auth login` (browser OAuth) right now.
CLAUDE_AUTHED=0
# Tolerant match for both `"loggedIn":true` (compact) and `"loggedIn": true`
# (spaced). Brittle: this parses the human-readable status output. Switch to
# `claude auth status --json` + jq once/if that flag is supported upstream.
_loggedin_re='"loggedIn"[[:space:]]*:[[:space:]]*true'
if command -v claude &>/dev/null; then
  echo ""
  echo "--- Checking Claude Code authentication ---"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # The claude CLI initializes ~/.claude.json (+ .lock and .claude/backups/)
    # on ANY invocation against a fresh $HOME — even the read-only-looking
    # `auth status`. A dry run must write nothing (issue #133), so skip the
    # probe and treat the session as unauthenticated for preview purposes.
    echo "  [DRY] would check 'claude auth status' (probe skipped: it writes ~/.claude.json state)"
    echo "  [DRY] plugin install preview unavailable without the auth probe"
  elif claude auth status 2>/dev/null | grep -Eq "$_loggedin_re"; then
    echo "  -> Already signed in to Claude"
    CLAUDE_AUTHED=1
  else
    echo "  Claude Code is not authenticated."
    echo "  Plugin install and 'cc' both require a signed-in session."
    # Default N under --yes: browser OAuth can't run unattended, so skip login.
    ask_yn "N" "Run 'claude auth login' now (opens browser)? [Y/n] "
    if [[ ! "${yn:-}" =~ ^[Nn] ]]; then
      run claude auth login || true
      if claude auth status 2>/dev/null | grep -Eq "$_loggedin_re"; then
        CLAUDE_AUTHED=1
      fi
    fi
    if [ "$CLAUDE_AUTHED" -eq 0 ]; then
      echo ""
      echo "  Skipping plugin install. After login, re-run: $0"
    fi
  fi
fi

# ─── 3b. Claude Code plugins ─────────────────────────────────────────
# Installs plugins listed in claude/plugins.txt (format: plugin@marketplace).
# Idempotent: marketplace registration and each plugin install are skipped
# when already present. Requires Claude authentication (§3a).
PLUGIN_LIST="$DOTFILES_DIR/claude/plugins.txt"
if [ -f "$PLUGIN_LIST" ] && command -v claude &>/dev/null && [ "$CLAUDE_AUTHED" -eq 1 ]; then
  echo ""
  echo "--- Installing Claude Code plugins ---"

  # Collect marketplaces referenced by the plugin list.
  # Trim leading/trailing whitespace per line BEFORE awk so trailing spaces
  # on plugins.txt entries don't end up in the marketplace name (M12).
  MARKETPLACES="$(sed 's/[[:space:]]*$//; s/^[[:space:]]*//' "$PLUGIN_LIST" \
    | awk -F'@' '/^[^#[:space:]]/ && NF==2 {print $2}' \
    | sort -u)"

  # Register each marketplace if not already known
  MARKETPLACE_LIST="$(claude plugin marketplace list 2>/dev/null || true)"
  for mp in $MARKETPLACES; do
    # Match header lines like "  ❯ <marketplace-name>" (anchor on word boundaries)
    if echo "$MARKETPLACE_LIST" | grep -Eq "❯[[:space:]]+${mp}([[:space:]]|$)"; then
      echo "  -> Marketplace $mp already registered"
    else
      case "$mp" in
        claude-plugins-official)
          run claude plugin marketplace add github:anthropics/claude-plugins-official \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        anthropic-agent-skills)
          run claude plugin marketplace add github:anthropics/skills \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        openai-codex)
          run claude plugin marketplace add github:openai/codex-plugin-cc \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        soundcheck)
          run claude plugin marketplace add github:thejefflarson/soundcheck \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        *)
          echo "  -> Unknown marketplace $mp — add registration logic to setup.sh or register manually"
          ;;
      esac
    fi
  done

  # Cache installed plugin list once to avoid spawning claude per-plugin
  INSTALLED_PLUGINS="$(claude plugin list 2>/dev/null || true)"

  # Install each plugin if not already installed
  while IFS= read -r line; do
    # Strip comments/whitespace
    plugin="${line%%#*}"
    plugin="$(echo "$plugin" | tr -d '[:space:]')"
    [ -z "$plugin" ] && continue

    # Match "❯ <plugin>@<marketplace>" exactly at a word boundary so e.g.
    # "code-review@x" cannot false-match "code-review-2@x".
    if echo "$INSTALLED_PLUGINS" | grep -qE "❯[[:space:]]+${plugin}([[:space:]]|$)"; then
      echo "  -> $plugin already installed"
    else
      echo "  -> Installing $plugin"
      run claude plugin install "$plugin" || echo "     (install failed — continuing)"
    fi
  done < "$PLUGIN_LIST"
fi

# The typescript-lsp plugin (plugins.txt) shells out to this binary; without
# it the plugin errors with "Executable not found in $PATH" every session.
if ! command -v typescript-language-server &>/dev/null; then
  echo "  -> Installing typescript-language-server (required by typescript-lsp plugin)"
  run bun add -g typescript-language-server typescript || echo "     (install failed — continuing)"
fi

# ─── 3c. Codex CLI ───────────────────────────────────────────────────
# Codex is configured in parallel with Claude. This public repo must never
# import live ~/.codex state wholesale: auth, sessions, sqlite files, logs,
# caches, and project trust entries are private/generated.
CODEX_AUTHED=0
if ! command -v codex &>/dev/null; then
  echo ""
  echo "--- Installing Codex CLI ---"
  run npm install -g @openai/codex || echo "  -> Codex install failed (continuing; install manually and re-run setup.sh)"
else
  echo "Codex CLI already installed: $(codex --version 2>/dev/null || echo 'installed')"
fi

if command -v codex &>/dev/null; then
  echo ""
  echo "--- Checking Codex authentication ---"
  # Same state-writing-probe class as `claude auth status` / `gh auth status`
  # (issue #189): don't let a stateful CLI initialize $HOME during a dry run.
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would check 'codex login status' (probe skipped: stateful-CLI probes can initialize \$HOME)"
  elif codex login status &>/dev/null; then
    echo "  -> Already signed in to Codex"
    CODEX_AUTHED=1
  else
    echo "  Codex is not authenticated."
    # Default N under --yes: login is interactive, so skip it unattended.
    ask_yn "N" "Run 'codex login' now? [Y/n] "
    if [[ ! "${yn:-}" =~ ^[Nn] ]]; then
      run codex login || true
      if codex login status &>/dev/null; then
        CODEX_AUTHED=1
      fi
    fi
    if [ "$CODEX_AUTHED" -eq 0 ]; then
      echo "  After login, run: codex login"
    fi
  fi
fi

# ─── 4. Git config ───────────────────────────────────────────────────
echo ""
echo "--- Setting up Git config ---"

# Prompt for git identity (written to .gitconfig.local, not committed)
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
if git config user.name &>/dev/null; then
  GIT_NAME="$(git config user.name)"
  GIT_EMAIL="$(git config user.email || true)"
  echo "  Using existing git identity: $GIT_NAME <$GIT_EMAIL>"
else
  # `|| true` matches every other prompt in this script: under `set -e` a read
  # that hits EOF (non-interactive/piped stdin) returns non-zero and would
  # otherwise abort the whole install.
  if [ "$ASSUME_YES" = "1" ]; then
    echo "  -> [--yes] using git identity from GIT_NAME/GIT_EMAIL env (may be empty)"
  else
    read -rp "Git user name: " GIT_NAME || true
    read -rp "Git email: " GIT_EMAIL || true
  fi
fi

# Preserve any safe.directory entries a prior run (or the user) added before we
# rewrite the file from scratch below — the closing instructions tell users to
# add project repos here by hand, and a naive `cat >` would silently wipe them
# on the next run (issue #122).
_preserved_safe_dirs=()
if [ -f "$DOTFILES_DIR/.gitconfig.local" ]; then
  while IFS= read -r _sd; do
    [ -n "$_sd" ] && _preserved_safe_dirs+=("$_sd")
  done < <(git config --file "$DOTFILES_DIR/.gitconfig.local" --get-all safe.directory 2>/dev/null)
fi

# Preserve any url.<base>.insteadOf rewrites the user added — same rationale as
# safe.directory: the rewrite below wipes the file, and we must NOT force these
# on anyone (only keep what's already present). The known use case: an SSH->HTTPS
# rewrite (url."https://github.com/".insteadOf git@github.com:) so `claude plugin
# install` can clone github-sourced plugins over HTTPS on a machine with no
# GitHub SSH key. Each line is "url.<base>.insteadof <value>".
_preserved_url_rewrites=()
if [ -f "$DOTFILES_DIR/.gitconfig.local" ]; then
  while IFS= read -r _ur; do
    [ -n "$_ur" ] && _preserved_url_rewrites+=("$_ur")
  done < <(git config --file "$DOTFILES_DIR/.gitconfig.local" --get-regexp '^url\..*\.insteadof$' 2>/dev/null)
fi

# Fall back to the identity already in .gitconfig.local when we don't have one
# from `git config` or env. Without this, an unattended run (--yes with no
# GIT_NAME/GIT_EMAIL and no effective git identity — e.g. a fresh $HOME) would
# rewrite the file with an EMPTY [user] block and wipe a real identity.
if [ -f "$DOTFILES_DIR/.gitconfig.local" ]; then
  [ -z "$GIT_NAME" ]  && GIT_NAME="$(git config --file "$DOTFILES_DIR/.gitconfig.local" user.name 2>/dev/null || true)"
  [ -z "$GIT_EMAIL" ] && GIT_EMAIL="$(git config --file "$DOTFILES_DIR/.gitconfig.local" user.email 2>/dev/null || true)"
fi

# Generate a platform-appropriate .gitconfig.local (identity + platform config).
# The four platform branches differ only in the [core] editor and [credential]
# helper lines — everything else ([user], the safe.directory block restored
# below) is identical, so we compute those two values per-platform and emit a
# single heredoc (issue #139). GIT_EDITOR/GIT_HELPER hold the FINAL literal text
# (backslashes already doubled for git-config syntax); the unquoted heredoc
# inserts each value verbatim without re-processing it.
if [[ "$PLATFORM" == "macos" ]]; then
  GIT_EDITOR='code --wait'
  GIT_HELPER='osxkeychain'
elif [[ "$PLATFORM" == "wsl" ]]; then
  WIN_USER=$(/mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)
  if [[ ! "$WIN_USER" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    echo "  Warning: Windows username contains unsupported characters; using PATH-based code lookup for editor."
    WIN_USER=""
  fi
  # NOTE: this VS Code editor path only handles a PER-USER install
  # (%LOCALAPPDATA%\Programs\Microsoft VS Code). A system-wide install under
  # "C:\Program Files\Microsoft VS Code" yields a broken core.editor; those
  # users should edit core.editor in ~/.gitconfig.local by hand.
  if [ -n "$WIN_USER" ]; then
    GIT_EDITOR="\"C:\\\\Users\\\\${WIN_USER}\\\\AppData\\\\Local\\\\Programs\\\\Microsoft VS Code\\\\bin\\\\code\" --wait"
  else
    GIT_EDITOR='code --wait'
  fi
  GIT_HELPER='/mnt/c/Program\\ Files/Git/mingw64/bin/git-credential-manager.exe'
else
  GIT_EDITOR='code --wait'
  GIT_HELPER='store'
fi

# The .gitconfig.local rewrite is a destructive op — skip it under --dry-run
# (it overwrites the user's real identity + credential helper). The link_file
# calls below honor DRY_RUN internally, so under --dry-run they only print
# the would-link preview (issue #133: they used to back up and replace the
# user's real ~/.gitconfig).
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "  [DRY] would write $DOTFILES_DIR/.gitconfig.local (user='${GIT_NAME} <${GIT_EMAIL}>', editor=${GIT_EDITOR}), preserving ${#_preserved_safe_dirs[@]} safe.directory entr(ies)"
else
  cat > "$DOTFILES_DIR/.gitconfig.local" <<GITCONF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[core]
	editor = ${GIT_EDITOR}
[credential]
	helper = ${GIT_HELPER}
GITCONF
  chmod 600 "$DOTFILES_DIR/.gitconfig.local"

  # Restore preserved safe.directory entries (issue #122) — idempotent; runs on
  # every platform. The WSL block below re-adds the managed dotfiles/claude-memory
  # entries; this loop keeps the user's own project entries the rewrite dropped.
  if [ "${#_preserved_safe_dirs[@]}" -gt 0 ]; then
    for _safe_dir in "${_preserved_safe_dirs[@]}"; do
      git config --file "$DOTFILES_DIR/.gitconfig.local" --get-all safe.directory 2>/dev/null \
        | grep -Fxq "$_safe_dir" \
        || git config --file "$DOTFILES_DIR/.gitconfig.local" --add safe.directory "$_safe_dir"
    done
  fi

  # WSL-specific: mark dev repos as safe (idempotent — skip if already present).
  # DEV_DIR is defined at the top of this script (C1 fix); reusing it here.
  # Write to .gitconfig.local, NOT --global: ~/.gitconfig is symlinked to this
  # repo's tracked .gitconfig, so `git config --global` would commit machine paths
  # (e.g. /home/<you>/dev/dotfiles) into the public repo. Same reasoning as the
  # gh credential-helper block below.
  if [[ "$PLATFORM" == "wsl" ]]; then
    for _safe_dir in "$DOTFILES_DIR" "$DEV_DIR/claude-memory"; do
      git config --file "$DOTFILES_DIR/.gitconfig.local" --get-all safe.directory 2>/dev/null \
        | grep -Fxq "$_safe_dir" \
        || git config --file "$DOTFILES_DIR/.gitconfig.local" --add safe.directory "$_safe_dir"
    done
  fi

  # Restore preserved url.*.insteadOf rewrites (see capture above). Each entry is
  # "url.<base>.insteadof <value>": split on the first space into key and value.
  if [ "${#_preserved_url_rewrites[@]}" -gt 0 ]; then
    for _ur in "${_preserved_url_rewrites[@]}"; do
      git config --file "$DOTFILES_DIR/.gitconfig.local" "${_ur%% *}" "${_ur#* }"
    done
  fi
fi

link_file "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"
link_file "$DOTFILES_DIR/.gitconfig.local" "$HOME_DIR/.gitconfig.local"

echo "  -> .gitconfig linked"

# ─── 5. Claude Code config ───────────────────────────────────────────
echo ""
echo "--- Setting up Claude Code config ---"
run mkdir -p "$HOME_DIR/.claude/skills"
run mkdir -p "$HOME_DIR/.claude/agents"

# Link the whole claude/ tree from the shared enumerator (lib-symlinks.sh,
# issue #135): one walk, shared with the health audit and check-claude.sh. Each
# record is <src> \t <dst> \t <label> \t <flags>; we create the parent dir,
# link, and chmod +x the source when flagged executable (hooks, scripts,
# chrome/top-level *.sh) — replacing the per-category loops + bulk chmods.
# Hard-fail if the nolink manifest is missing rather than link files we shouldn't.
if ! symlink_require_manifest "$DOTFILES_DIR/claude"; then
  echo "  !! FATAL: claude/nolink.txt is missing — cannot determine which files to skip." >&2
  exit 1
fi
_tree_links=0
while IFS=$'\t' read -r _src _dst _label _flags; do
  [ -n "$_src" ] || continue
  # mkdir/chmod are silently skipped under --dry-run (link_file prints the
  # per-entry preview; a [DRY] line per mkdir would just triple the noise).
  if [ "${DRY_RUN:-0}" != "1" ]; then
    mkdir -p "$(dirname "$_dst")"
  fi
  link_file "$_src" "$_dst"
  if [ "$_flags" = "executable" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    chmod +x "$_src" 2>/dev/null || true
  fi
  _tree_links=$((_tree_links + 1))
done < <(symlink_enumerate "$DOTFILES_DIR/claude" "$HOME_DIR/.claude")
echo "  -> Claude tree linked ($_tree_links entries: config, hooks, skills, agents, scripts, chrome)"

# Dev dir already derived at top of script (C1) — write it out so all scripts
# have a single source of truth.
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "  [DRY] would write $HOME_DIR/.claude/dev-dir ($DEV_DIR)"
else
  echo "$DEV_DIR" > "$HOME_DIR/.claude/dev-dir"
  echo "  -> dev-dir set to $DEV_DIR"
fi

# Memory (optional private repo for persistent Claude memory)
#
# Claude Code keeps per-project auto-memory under
# ~/.claude/projects/-<munged-cwd>/memory/ (MEMORY.md + fact files), alongside
# the session .jsonl transcripts. That dir is machine-local and gitignored —
# lose the machine and the facts are gone, and they never reach your other
# machines. We fix that by symlinking each project's memory/ (and ONLY memory/,
# never the transcripts) into the private claude-memory repo at
# claude-memory/<project-basename>/memory, so durable facts are version-
# controlled and synced. The source of truth lives in the repo; the symlink
# points Claude at it.
MEMORY_REPO="$DEV_DIR/claude-memory"
if [ -d "$MEMORY_REPO" ]; then
  # Link one project's memory dir. $1 = claude-memory subdir (project basename),
  # $2 = the dash-munged project key Claude uses under ~/.claude/projects/.
  link_project_memory() {
    local name="$1" munged="$2"
    local src="$MEMORY_REPO/$name/memory"
    local dst="$HOME_DIR/.claude/projects/-${munged}/memory"
    # Skip projects with no memory on either side — don't create empty dirs.
    [ -e "$src" ] || [ -d "$dst" ] || return 0
    # Honor --dry-run: these are destructive (rm/cp/ln), so a preview must not
    # actually move or relink anyone's memory dirs.
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY] link project memory: $dst -> $src"
      return 0
    fi
    mkdir -p "$src" "$(dirname "$dst")"
    if [ -L "$dst" ]; then
      rm "$dst"
    elif [ -d "$dst" ]; then
      # Promote any local-only facts into the repo before replacing the dir.
      # cp -n never clobbers a newer repo copy; we only move *.md memory files,
      # never the sibling .jsonl session transcripts.
      cp -n "$dst"/*.md "$src/" 2>/dev/null || true
      rm -r "$dst"
    fi
    ln -s "$src" "$dst"
  }
  # The dev root itself (basename "dev"), then every immediate project under it.
  link_project_memory "dev" "$(echo "$DEV_DIR" | sed 's|^/||; s|/|-|g')"
  for _proj in "$DEV_DIR"/*/; do
    [ -d "$_proj" ] || continue
    [ "$(basename "$_proj")" = "claude-memory" ] && continue  # the repo itself
    link_project_memory "$(basename "$_proj")" \
      "$(echo "${_proj%/}" | sed 's|^/||; s|/|-|g')"
  done
  echo "  -> Claude memory linked for dev + project dirs (private repo)"
else
  echo "  -> Claude memory repo not found at $MEMORY_REPO"
  echo "     For auto-memory persistence: mkdir -p ~/dev/claude-memory/dev/memory,"
  echo "     then 'gh repo create claude-memory --private --source=. --push' and re-run setup.sh."
fi

# ─── 5b. Codex config ────────────────────────────────────────────────
echo ""
echo "--- Setting up Codex config ---"
run mkdir -p "$HOME_DIR/.codex"

if [ -f "$DOTFILES_DIR/codex/AGENTS.md" ]; then
  link_file "$DOTFILES_DIR/codex/AGENTS.md" "$HOME_DIR/.codex/AGENTS.md"
  echo "  -> Codex AGENTS.md linked"
fi

if [ -d "$DOTFILES_DIR/agents/skills" ]; then
  run mkdir -p "$HOME_DIR/.codex/skills"
  for skill_dir in "$DOTFILES_DIR/agents/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    run mkdir -p "$HOME_DIR/.codex/skills/$skill_name"
    for skill_file in "$skill_dir"*; do
      [ -f "$skill_file" ] && link_file "$skill_file" "$HOME_DIR/.codex/skills/$skill_name/$(basename "$skill_file")"
    done
  done
  echo "  -> Codex skills linked (source: agents/skills)"
fi

if [ -L "$HOME_DIR/.codex/config.toml" ]; then
  echo "  -> WARNING: ~/.codex/config.toml is a symlink."
  echo "     Codex writes machine-specific project trust there; replace it with a local file before committing changes."
elif [ -f "$HOME_DIR/.codex/config.toml" ]; then
  echo "  -> Codex config.toml left local (public-safe)"
elif [ -f "$DOTFILES_DIR/codex/config.toml.example" ]; then
  echo "  -> No local Codex config.toml found."
  echo "     Review $DOTFILES_DIR/codex/config.toml.example before creating one."
fi

CODEX_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/codex-memory"
if [ -d "$CODEX_MEMORY_REPO" ]; then
  echo "  -> codex-memory private repo detected at $CODEX_MEMORY_REPO"
  for f in AGENTS.local.md MEMORY.md; do
    if [ -f "$CODEX_MEMORY_REPO/$f" ]; then
      link_file "$CODEX_MEMORY_REPO/$f" "$HOME_DIR/.codex/$f"
      echo "  -> Codex private $f linked"
    fi
  done
  echo "     Keep personal Codex memory there, not in public dotfiles."
else
  echo "  -> Optional private Codex memory repo not found at $CODEX_MEMORY_REPO"
  echo "     Create it only if you want portable private Codex memory."
fi

# ─── 5c. Antigravity (agy) config ────────────────────────────────────
# Global customization root is ~/.gemini/config/ (rules load from GEMINI.md
# there; skills from skills/). Live runtime state stays untouched under
# ~/.gemini/antigravity-cli/.
echo ""
echo "--- Setting up Antigravity config ---"
AGY_CONFIG_DIR="$HOME_DIR/.gemini/config"
run mkdir -p "$AGY_CONFIG_DIR"

if [ -f "$DOTFILES_DIR/antigravity/GEMINI.md" ]; then
  link_file "$DOTFILES_DIR/antigravity/GEMINI.md" "$AGY_CONFIG_DIR/GEMINI.md"
  echo "  -> Antigravity global GEMINI.md linked"
fi

# Shared workflow skills: the agent-neutral set in agents/skills is the single
# source for both Codex and Antigravity. Antigravity discovers per-skill dirs
# under ~/.gemini/config/skills/; symlink each one (dir-level, unlike the
# per-file Codex links, since agy resolves rule/skill paths through the link).
if [ -d "$DOTFILES_DIR/agents/skills" ]; then
  run mkdir -p "$AGY_CONFIG_DIR/skills"
  for skill_dir in "$DOTFILES_DIR/agents/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    if [ -d "$AGY_CONFIG_DIR/skills/$skill_name" ] && [ ! -L "$AGY_CONFIG_DIR/skills/$skill_name" ]; then
      echo "  -> WARNING: $AGY_CONFIG_DIR/skills/$skill_name is a real directory; not replacing it"
      continue
    fi
    link_file "${skill_dir%/}" "$AGY_CONFIG_DIR/skills/$skill_name"
  done
  echo "  -> Antigravity shared skills linked (source: agents/skills)"
fi

# Antigravity-only skills (e.g. browser-verify) live in antigravity/skills;
# same dir-level symlink treatment as the shared set.
if [ -d "$DOTFILES_DIR/antigravity/skills" ]; then
  run mkdir -p "$AGY_CONFIG_DIR/skills"
  for skill_dir in "$DOTFILES_DIR/antigravity/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    if [ -d "$AGY_CONFIG_DIR/skills/$skill_name" ] && [ ! -L "$AGY_CONFIG_DIR/skills/$skill_name" ]; then
      echo "  -> WARNING: $AGY_CONFIG_DIR/skills/$skill_name is a real directory; not replacing it"
      continue
    fi
    link_file "${skill_dir%/}" "$AGY_CONFIG_DIR/skills/$skill_name"
  done
  echo "  -> Antigravity-only skills linked"
fi

# Lifecycle hooks: hooks.json is small and public-safe — symlink it. The hook
# script itself ships in claude/scripts (already linked into ~/.claude/scripts).
if [ -f "$DOTFILES_DIR/antigravity/hooks.json" ]; then
  link_file "$DOTFILES_DIR/antigravity/hooks.json" "$AGY_CONFIG_DIR/hooks.json"
  echo "  -> Antigravity hooks.json linked"
fi

# MCP servers: the live mcp_config.json stays LOCAL (machines add private
# servers), so seed it from the template only when absent or empty — never
# overwrite an existing non-empty config.
if [ -f "$DOTFILES_DIR/antigravity/mcp_config.json.example" ]; then
  if [ ! -s "$AGY_CONFIG_DIR/mcp_config.json" ]; then
    run cp "$DOTFILES_DIR/antigravity/mcp_config.json.example" "$AGY_CONFIG_DIR/mcp_config.json"
    echo "  -> Antigravity mcp_config.json seeded from template (playwright + github)"
  else
    echo "  -> Antigravity mcp_config.json exists; left untouched (compare with antigravity/mcp_config.json.example)"
  fi
fi

AGY_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/agy-memory"
if [ -d "$AGY_MEMORY_REPO" ]; then
  echo "  -> agy-memory private repo detected at $AGY_MEMORY_REPO"
  for f in GEMINI.local.md MEMORY.md; do
    if [ -f "$AGY_MEMORY_REPO/$f" ]; then
      link_file "$AGY_MEMORY_REPO/$f" "$AGY_CONFIG_DIR/$f"
      echo "  -> Antigravity private $f linked"
    fi
  done
  echo "     Keep personal Antigravity memory there, not in public dotfiles."
else
  echo "  -> Optional private Antigravity memory repo not found at $AGY_MEMORY_REPO"
  echo "     Create it only if you want portable private Antigravity memory."
fi

# ─── 6. GitHub CLI auth ──────────────────────────────────────────────
# The gh CLI (≥ ~2.5x) writes ~/.local/state/gh/device-id on ANY invocation —
# even `gh auth status` — so a dry run must not probe it (same class as the
# gated `claude auth status` probe; broke the CI no-writes assertion on a
# pristine runner HOME, issue #189).
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo ""
  echo "  [DRY] would check 'gh auth status' (probe skipped: gh writes ~/.local/state/gh/device-id)"
elif ! gh auth status &>/dev/null; then
  echo ""
  echo "--- GitHub CLI not authenticated ---"
  echo "Run: gh auth login"
  echo "(Choose HTTPS and browser-based login)"
else
  echo "GitHub CLI already authenticated"
  # Wire gh as git's credential helper for github.com so `git pull` /
  # `git clone` in every repo (e.g., `pull-all` inside cc) uses the
  # existing gh token instead of prompting for username/password.
  #
  # We write directly to ~/.gitconfig.local instead of running
  # `gh auth setup-git`, because the latter edits ~/.gitconfig — which
  # is symlinked to this repo's tracked .gitconfig and would pollute
  # the shared dotfile with machine-specific helper paths.
  GH_BIN="$(command -v gh)"
  LOCAL_GITCONFIG="$HOME_DIR/.gitconfig.local"
  if [ -n "$GH_BIN" ] && ! git config --file "$LOCAL_GITCONFIG" --get-all credential.https://github.com.helper 2>/dev/null | grep -q "gh auth git-credential"; then
    echo "  -> Wiring gh as git credential helper (→ $LOCAL_GITCONFIG)..."
    for host in github.com gist.github.com; do
      run git config --file "$LOCAL_GITCONFIG" --add "credential.https://${host}.helper" ""
      run git config --file "$LOCAL_GITCONFIG" --add "credential.https://${host}.helper" "!${GH_BIN} auth git-credential"
    done
  else
    echo "  -> git credential helper already wired to gh"
  fi
fi

# ─── 7. Shell config ─────────────────────────────────────────────────
echo ""
echo "--- Setting up shell config ---"

if [[ "$PLATFORM" == "macos" ]]; then
  # macOS uses zsh by default
  SHELL_RC="$HOME_DIR/.zshrc"
  link_file "$DOTFILES_DIR/.bash_aliases" "$HOME_DIR/.bash_aliases"
  if [ -f "$SHELL_RC" ] && ! grep -q '\.bash_aliases' "$SHELL_RC"; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would append .bash_aliases sourcing to $SHELL_RC"
    else
      echo '' >> "$SHELL_RC"
      echo '# Load aliases (shared with bash)' >> "$SHELL_RC"
      echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$SHELL_RC"
      echo "  -> Added .bash_aliases sourcing to .zshrc"
    fi
  elif [ ! -f "$SHELL_RC" ]; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would create $SHELL_RC with .bash_aliases sourcing"
    else
      echo '# Load aliases (shared with bash)' > "$SHELL_RC"
      echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$SHELL_RC"
      echo "  -> Created .zshrc with .bash_aliases sourcing"
    fi
  fi
  echo "  -> .bash_aliases linked (sourced from .zshrc)"
else
  link_file "$DOTFILES_DIR/.bash_aliases" "$HOME_DIR/.bash_aliases"
  if [ -f "$HOME_DIR/.bashrc" ] && ! grep -q '\.bash_aliases' "$HOME_DIR/.bashrc"; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would append .bash_aliases sourcing to $HOME_DIR/.bashrc"
    else
      echo '' >> "$HOME_DIR/.bashrc"
      echo '# Load custom aliases' >> "$HOME_DIR/.bashrc"
      echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$HOME_DIR/.bashrc"
      echo "  -> Added .bash_aliases sourcing to .bashrc"
    fi
  elif [ ! -f "$HOME_DIR/.bashrc" ]; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "  [DRY] would create $HOME_DIR/.bashrc with .bash_aliases sourcing"
    else
      echo '# Load custom aliases' > "$HOME_DIR/.bashrc"
      echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$HOME_DIR/.bashrc"
      echo "  -> Created .bashrc with .bash_aliases sourcing"
    fi
  fi
  echo "  -> .bash_aliases linked"

  # WSL: auto-cd into Linux-native dev directory for better I/O performance
  if [[ "$PLATFORM" == "wsl" ]]; then
    if grep -q 'cd /mnt/c/' "$HOME_DIR/.bashrc" 2>/dev/null; then
      # Replace any existing cd to Windows mount with Linux-native path
      run sed -i "s|cd /mnt/c/.*|# Start in Linux-native dev directory for better WSL performance\ncd ~/dev|" "$HOME_DIR/.bashrc"
      echo "  -> Updated .bashrc: cd ~/dev (was pointing to /mnt/c/)"
    elif ! grep -q 'cd ~/dev' "$HOME_DIR/.bashrc" 2>/dev/null; then
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "  [DRY] would append auto-cd to ~/dev in $HOME_DIR/.bashrc"
      else
        echo '' >> "$HOME_DIR/.bashrc"
        echo '# Start in Linux-native dev directory for better WSL performance' >> "$HOME_DIR/.bashrc"
        echo 'cd ~/dev' >> "$HOME_DIR/.bashrc"
        echo "  -> Added auto-cd to ~/dev in .bashrc"
      fi
    fi
  fi

  # .bash_profile is symlinked from dotfiles. Login shells (wsl.exe, `bash -l`,
  # ssh, fresh Terminal.app on a bash account) skip .bashrc by design; without
  # a .bash_profile that sources .bashrc, every login pane starts without
  # `cc`, NVM, cargo, aliases, or auto-cd. The bun-PATH line is a no-op when
  # bun isn't installed.
  # link_file backs up any pre-existing ~/.bash_profile to ~/.bash_profile.backup.
  link_file "$DOTFILES_DIR/.bash_profile" "$HOME_DIR/.bash_profile"
  echo "  -> .bash_profile linked (login shells now source .bashrc)"
fi

# ─── 7c. Verification — login shell can resolve cc ───────────────────
# Catches regressions before the user hits them. If `bash -li -c 'type cc'`
# does not report `function`, something downstream of .bash_profile/.bashrc
# is broken: a stray local override, a missing symlink, a third-party
# installer that overwrote .bash_profile, etc. Non-fatal — we report and
# move on so other steps still run. Skipped on macOS (zsh-default path
# above handles the equivalent).
if [[ "$PLATFORM" != "macos" ]]; then
  echo ""
  echo "--- Verifying login-shell environment ---"
  # Skip the probe under --dry-run (issue #189): login-shell startup hooks
  # (mise, pyenv, nvm, …) write their own state into $HOME, and dry-run
  # hasn't linked anything for the probe to verify anyway.
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would verify 'bash -li' resolves cc (probe skipped: login startup hooks may write into \$HOME)"
  else
    cc_type="$(bash -li -c 'type -t cc 2>/dev/null' 2>/dev/null | tail -1 || true)"
    if [ "$cc_type" = "function" ]; then
      echo "  -> bash -li resolves cc as function (login shells healthy)"
    else
      echo "  !! WARNING: bash -li does not see cc (got: '$cc_type')"
      echo "     Login shells will need 'source ~/.bashrc' before cc works."
      echo "     Check ~/.bash_profile, ~/.bashrc, ~/.bash_aliases symlinks."
    fi
  fi
fi

# ─── 7b. PowerShell helpers (WSL only) ───────────────────────────────
# Installs Windows-side PowerShell launchers from windows/. Two files:
#   wsl-helpers.ps1  — agent-neutral (currently: wsl6)
#   cc-functions.ps1 — Claude-specific (cctab, ccpane, ccgrid, ccprojects, ccupdate)
# Both are copied to $env:USERPROFILE\.<name>.ps1 and dot-sourced from $PROFILE
# so PowerShell users can drive WSL panes without copy-pasting the README block.
#
# Installs into BOTH Windows PowerShell 5.1 ($PROFILE under
# Documents\WindowsPowerShell\) and PowerShell 7 ($PROFILE under
# Documents\PowerShell\) when each host is available — they have different
# profile paths, so wiring only powershell.exe leaves pwsh.exe broken.
install_ps_helpers_for_host() {
  local host_exe="$1"  # "powershell.exe" or "pwsh.exe"
  # Build the UNC path to THIS dotfiles checkout so the helper resolves
  # regardless of where the repo was cloned (~/dev/dotfiles, ~/dotfiles, …).
  local WSL_DISTRO_NAME_EFFECTIVE="${WSL_DISTRO_NAME:-Ubuntu}"
  local DOTFILES_UNC="\\\\wsl.localhost\\${WSL_DISTRO_NAME_EFFECTIVE}${DOTFILES_DIR//\//\\}"
  # WSLENV is required for env vars to cross the WSL → Windows boundary.
  # Without it, $env:DOTFILES_UNC arrives empty in PowerShell.
  DOTFILES_UNC="$DOTFILES_UNC" WSLENV="DOTFILES_UNC" \
    "$host_exe" -NoProfile -ExecutionPolicy Bypass -Command '
      # Set RemoteSigned so dot-sourced profile scripts run in fresh sessions.
      # Suppress noise: PS 5.1 may complain the module cannot autoload here;
      # PS 7 may complain a more-specific scope overrides it. Both are benign:
      # the policy ends up correct and the install succeeds either way.
      try { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force *>$null } catch {}
      $profileDir = Split-Path $PROFILE -Parent
      if (-not (Test-Path $profileDir)) { New-Item -Type Directory -Path $profileDir -Force | Out-Null }
      if (-not (Test-Path $PROFILE))    { New-Item -Type File      -Path $PROFILE    -Force | Out-Null }
      Write-Host "  Host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)  PROFILE: $PROFILE"
      $files = @("wsl-helpers.ps1", "cc-functions.ps1")
      $failed = 0
      foreach ($f in $files) {
        $src  = "$env:DOTFILES_UNC\windows\$f"
        $dest = "$env:USERPROFILE\.$f"
        if (-not (Test-Path $src)) {
          Write-Error "Source not found: $src"
          $failed = 1
          continue
        }
        Copy-Item $src $dest -Force
        $pattern = [regex]::Escape($f)
        if (-not (Select-String -Path $PROFILE -Pattern $pattern -Quiet)) {
          Add-Content $PROFILE (". `"$dest`"")
          Write-Host "    -> Added $f to PROFILE"
        } else {
          Write-Host "    -> $f already wired into PROFILE (refreshed local copy)"
        }
      }
      if ($failed -ne 0) { exit 1 }
    ' 2>&1 | sed 's/^/  /'
  # Capture exit status before sed pipe masks it (sed always succeeds).
  return ${PIPESTATUS[0]}
}

if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "--- PowerShell helpers (wsl-helpers.ps1 + cc-functions.ps1) ---"
  if ! command -v powershell.exe &>/dev/null && ! command -v pwsh.exe &>/dev/null; then
    echo "  -> Neither powershell.exe nor pwsh.exe found in WSL PATH; skipping."
  else
    echo "  Installs:"
    echo "    wsl-helpers.ps1  → wsl6 (agent-neutral 3×2 WSL grid)"
    echo "    cc-functions.ps1 → ccgrid, cctab, ccpane, ccprojects (Claude launchers)"
    echo "  Wires into BOTH Windows PowerShell 5.1 and PowerShell 7 profiles when present."
    # Default N under --yes: don't modify Windows PowerShell profiles unattended.
    ask_yn "N" "Install into your PowerShell profile(s)? [Y/n] "
    if [[ ! "${yn:-}" =~ ^[Nn] ]]; then
      ps_overall=0
      installed_any=0
      for host_exe in powershell.exe pwsh.exe; do
        if command -v "$host_exe" &>/dev/null; then
          installed_any=1
          # run-gated: writes Windows-side PowerShell profiles (issue #133).
          run install_ps_helpers_for_host "$host_exe" || ps_overall=1
        fi
      done
      if [ "$installed_any" -eq 0 ]; then
        echo "  -> No PowerShell host found; nothing installed."
      elif [ "$ps_overall" -eq 0 ]; then
        echo "  -> Open a new PowerShell window: try 'wsl6' (no agent) or 'ccprojects' (Claude)"
      else
        echo "  -> One or more PowerShell installs FAILED; check messages above."
      fi
    else
      echo "  -> Skipped"
    fi
  fi
fi

# ─── 8. Bootstrap claude-memory (private repo) ───────────────────────
# Links the private settings.json (and any identity files) into ~/.claude.
# The private memory layer is optional, so we never `exit 1` from here — the
# primary dotfiles+Claude install must still succeed if it fails to wire up.
if [ -f "$BOOTSTRAP_SCRIPT" ]; then
  echo ""
  echo "--- Running claude-memory bootstrap ---"
  # Gated: bootstrap.sh links private settings/identity into ~/.claude and has
  # no dry-run mode of its own, so a preview run must not invoke it (issue #133).
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "  [DRY] would run claude-memory bootstrap: $BOOTSTRAP_SCRIPT"
  elif bash "$BOOTSTRAP_SCRIPT"; then
    BOOTSTRAP_RC=0
  else
    BOOTSTRAP_RC=$?
    echo "  !! WARNING: claude-memory bootstrap exited $BOOTSTRAP_RC."
    echo "     Setup will continue; re-run '$BOOTSTRAP_SCRIPT' manually to debug."
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ($PLATFORM) ==="
echo ""
echo "Running post-setup health audit..."
echo ""
run_health_audit "check" || true
if [ -x "$DOTFILES_DIR/check-codex.sh" ]; then
  echo ""
  "$DOTFILES_DIR/check-codex.sh" || true
fi
echo ""
echo "Claude config files are symlinked — edits in ~/.claude/"
echo "will automatically be reflected in your dotfiles repo."
echo "Codex auth, sessions, logs, sqlite state, caches, and live config.toml stay local/private."
echo ""
echo "Manual steps remaining:"
echo "  1. Run 'gh auth login' if not already authenticated"
if [ "${CLAUDE_AUTHED:-0}" -eq 0 ]; then
  echo "  2. Run 'claude auth login' to sign in to Claude (required for plugins)"
  echo "  3. Re-run this setup.sh to install plugins"
  _launch_step=4
else
  _launch_step=2
fi
echo "  ${_launch_step}. Run 'cc' to pull repos and start Claude (or 'claude' to skip repo sync)"
if [ "${CODEX_AUTHED:-0}" -eq 0 ]; then
  echo "  Next Codex step: run 'codex login', then use 'cx' to launch Codex"
else
  echo "  Codex: run 'cx' to pull repos and start Codex"
fi
if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "  WSL Chrome bridge:"
  echo "    Run 'bash ~/.claude/chrome/setup-wsl-chrome-bridge.sh' to enable claude --chrome"
  echo "    (bridges Windows Chrome to WSL2 Claude Code via native messaging)"
  echo ""
  echo "  WSL performance tip:"
  echo "    Keep your repos under ~/dev (Linux filesystem), NOT /mnt/c/ (Windows mount)."
  echo "    File I/O on the Linux filesystem is ~10x faster than the Windows mount."
  echo "    Your shell will auto-cd to ~/dev on startup."
  echo ""
  echo "  3. Add project repos to git safe.directory as needed (write to"
  echo "     .gitconfig.local, NOT --global: ~/.gitconfig is symlinked to the"
  echo "     public dotfiles repo, so --global would commit your machine path):"
  echo "     git config --file ~/.gitconfig.local --add safe.directory $DEV_DIR/<repo>"
fi

# ─── Final completion summary (M5) ───────────────────────────────────
# Bash-portable elapsed time (no `bc`): plain integer arithmetic on epoch seconds.
SETUP_END=$(date +%s)
ELAPSED=$(( SETUP_END - SETUP_START ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))
echo ""
echo "─────────────────────────────────────────────"
echo "  Completed in ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo "  Symlinks: created=${LINKS_CREATED:-0}  verified=${LINKS_VERIFIED:-0}  broken=${LINKS_BROKEN:-0}"
if [ "${BOOTSTRAP_RC:-0}" -ne 0 ]; then
  echo "  claude-memory bootstrap: FAILED — re-run manually: $BOOTSTRAP_SCRIPT"
fi
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "  Mode: DRY-RUN (no destructive ops were executed)"
fi
echo "  Try next: cc to launch Claude"
echo "─────────────────────────────────────────────"
