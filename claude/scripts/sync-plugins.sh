#!/usr/bin/env bash
# sync-plugins.sh — Install any plugins listed in the dotfiles plugin manifest
# that are not currently installed, and uninstall any it marks removed.
# Idempotent.
#
# Source of truth: $DOTFILES_DIR/claude/plugins.txt (one
# `<plugin>@<marketplace>` per line). The manifest stays in the dotfiles repo
# (setup.sh excludes it from symlinking; see check-claude.sh NOLINK).
# Triggered manually, or by the warning emitted by PluginDriftCheck.hook.ts.
#
# The manifest's `# [global]` / `# [per-project]` section markers (issue #214)
# are comments for the install loop: this script installs BOTH sections. The
# scoping governs enablement (settings.json `enabledPlugins`), and
# `claude plugin install` enables what it installs, so each [per-project]
# plugin is disabled at user scope right after its install (#720); the drift
# hook (PluginDriftCheck.hook.ts) still checks the result.
#
# INSTALL scope is a separate axis and does matter here: everything installs at
# user scope. A plugin someone installed with `--scope project` for one repo is
# that repo's, is deliberately absent from the manifest, and does not count as
# installed by the fast path below.
#
# Service selection (issue #425): plugins are Claude Code's, so nothing is
# synced when Claude Code is not a selected service, and `*@openai-codex`
# plugins (which drive the Codex CLI) are skipped when Codex is not. This is
# the same rule setup.sh §3b applies; an existing install is left as-is.
#
# Removal: a plugin dropped from the manifest is NOT uninstalled — the operator
# may have installed plugins of their own that the manifest never listed. To
# retire a plugin on every machine, replace its line with a whole-line comment
# `# removed: <plugin>@<marketplace>`; this script then uninstalls its
# USER-scope install. An active manifest line for the same id wins.

set -eo pipefail

# Resolve the dotfiles repo via the real (symlink-resolved) path of this script:
# $DOTFILES_DIR/claude/scripts/sync-plugins.sh. resolve_script_path (from
# checker-lib.sh, beside this script) uses a portable resolution loop because
# BSD readlink (macOS) does not support `-f`.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="$DOTFILES_DIR/claude/plugins.txt"

if [[ ! -f "$MANIFEST" ]]; then
  echo "✘ Manifest not found: $MANIFEST" >&2
  exit 1
fi

# lib-services.sh is code, so it comes from this script's own checkout, not
# from a DOTFILES_DIR override (which only relocates the manifest).
LIB_SERVICES="$SCRIPT_DIR/../../lib-services.sh"
if [[ ! -f "$LIB_SERVICES" ]]; then
  echo "✘ lib-services.sh not found: $LIB_SERVICES" >&2
  exit 1
fi
# shellcheck source=lib-services.sh
. "$LIB_SERVICES"

# manifest_per_project_plugins is shared with setup.sh §3b (#720).
LIB_CHECKS="$SCRIPT_DIR/../../lib-checks.sh"
if [[ ! -f "$LIB_CHECKS" ]]; then
  echo "✘ lib-checks.sh not found: $LIB_CHECKS" >&2
  exit 1
fi
# shellcheck source=lib-checks.sh
. "$LIB_CHECKS"

# The saved selection, or every service when none was saved. A damaged file is
# refused, not guessed at: "all" would reinstall what the operator opted out of.
if ! selected_services="$(services_effective)"; then
  echo "✘ Cannot read the agent service selection; fix it with setup.sh --select-services" >&2
  exit 1
fi

# Parse the manifest once. wanted: active lines whose service is selected
# (services_filter_plugins). removed: ids named by a `# removed:` line.
# active_all: every active line, selected or not, so an active line always
# outranks a `# removed:` one.
removed=()
active_all=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*removed:[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
    removed+=("${BASH_REMATCH[1]}")
    continue
  fi
  p="${line%%#*}"
  # Strip all whitespace (spaces, tabs, and CR from CRLF line endings)
  p="${p//[[:space:]]/}"
  [[ -z "$p" ]] && continue
  active_all+="$p"$'\n'
done < "$MANIFEST"
wanted=()
while IFS= read -r p; do
  [[ -n "$p" ]] && wanted+=("$p")
done < <(printf '%s' "$active_all" | services_filter_plugins "$selected_services")
# Plugins are Claude Code's: with it deselected there is nothing to manage.
case ",$selected_services," in
  *,claude,*) ;;
  *) exit 0 ;;
esac

# Fast path: if every manifest plugin already has a USER-scope install, there is
# nothing to do — exit silently without touching the network. Keys in
# installed_plugins.json are the same `<plugin>@<marketplace>` strings as the
# manifest lines. This keeps the every-fresh-launch sync in cc() near-instant
# and quiet when there's no drift.
#
# Scope matters, and the rule mirrors PluginDriftCheck.hook.ts exactly: only a
# `--scope user` record satisfies the manifest, because this script installs at
# user scope and a fresh clone reproduces user scope only. `project` and
# `local` records belong to a checkout. Matching on the bare key would let the
# fast path exit 0 on a plugin the hook reports as missing — a warning whose
# suggested remedy (run this script) does nothing, every session.
#
# `user` is an allowlist, so an unrecognised scope asks for a redundant
# idempotent install rather than silently satisfying the manifest. Records
# whose shape we don't recognise (non-array value, or no string `scope`) count
# as installed, so an older installed_plugins.json behaves as before.
# Without python3 the fast path is skipped entirely rather than guessed at: the
# install loop below is idempotent, so the cost is launch latency, not
# correctness. python3 is already required by the pre-push receipt checker.
# Both interpreter calls run with -I so a json.py planted in the current
# directory (sync-plugins runs from wherever the operator is) cannot hijack
# the import.
#
# installed_state says whether $user_scoped can be trusted: "known" (read, or
# no file at all — nothing installed yet) or the reason it could not be read.
# An unreadable state is never treated as "nothing installed": installs fall
# back to the idempotent slow path, and removals fail loudly below.
INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"
user_scoped=""
installed_state="known"
#
# Present means it exists or is a symlink. Only a regular file (after following
# links) is read: a dangling link, directory, device or FIFO is unreadable — a
# FIFO would block open() and hang cc's launch. The timeout covers a file
# swapped for a FIFO after the check, where timeout(1) exists.
py_timeout=()
command -v timeout >/dev/null 2>&1 && py_timeout=(timeout 5)
if [[ ! -e "$INSTALLED_JSON" && ! -L "$INSTALLED_JSON" ]]; then
  :
elif [[ ! -f "$INSTALLED_JSON" ]]; then
  installed_state="$INSTALLED_JSON is not a regular file"
elif ! command -v python3 >/dev/null 2>&1; then
  installed_state="python3 is not on PATH, so $INSTALLED_JSON cannot be read"
elif ! user_scoped="$(${py_timeout[@]+"${py_timeout[@]}"} python3 -I -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
plugins = data.get("plugins")
if not isinstance(plugins, dict):
    sys.exit(1)
for name, records in plugins.items():
    if not isinstance(records, list) or any(
        (not isinstance(r, dict)) or not isinstance(r.get("scope"), str)
        or r.get("scope") == "user"
        for r in records
    ):
        print(name)
' "$INSTALLED_JSON" 2>/dev/null)"; then
  user_scoped=""
  installed_state="$INSTALLED_JSON is unreadable or not the expected JSON shape"
fi
if [[ "$installed_state" != "known" ]]; then
  echo "⚠ $installed_state; installing every manifest plugin instead of checking" >&2
fi

# Removals need to know what is installed at user scope. When that state could
# not be read, each pending removal is reported as a failure (exit 1) instead
# of being skipped: guessing "installed" could uninstall at the wrong scope.
to_remove=()
unevaluated=()
for p in ${removed[@]+"${removed[@]}"}; do
  grep -qxF "$p" <<<"$active_all" && continue
  if [[ "$installed_state" != "known" ]]; then
    unevaluated+=("$p")
  elif grep -qxF "$p" <<<"$user_scoped"; then
    to_remove+=("$p")
  fi
done

# [per-project] plugins must never be enabled in the user settings.json. A
# disable that failed right after an install (or an install from before #720)
# would otherwise be masked by the installed-only fast path below on every
# later run, so each run re-reads the map and disables what it finds; a
# failure here fails the run, before anything can report success.
# Only the selected services' plugins: a deselected service's plugins are
# left exactly as they are, enabled or not, like everywhere else in this
# script.
per_project="$(manifest_per_project_plugins < "$MANIFEST" | services_filter_plugins "$selected_services")"
SETTINGS_JSON="$HOME/.claude/settings.json"
enabled_per_project=""
if [[ -n "$per_project" && -e "$SETTINGS_JSON" ]]; then
  # Only a regular file (through a symlink: settings.json is one) is opened;
  # a FIFO or socket there would hang the read, and a directory is not a
  # settings file. Either is a failure, not "nothing enabled".
  if [[ ! -f "$SETTINGS_JSON" ]]; then
    echo "✘ $SETTINGS_JSON is not a regular file; cannot confirm [per-project] plugins are disabled" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "✘ python3 is not on PATH, so $SETTINGS_JSON cannot be checked for enabled [per-project] plugins" >&2
    exit 1
  fi
  # A settings file that exists but cannot be read or parsed is a failure,
  # not "nothing enabled": the fast path below would otherwise report success
  # without having checked enablement at all.
  if ! enabled_all="$(${py_timeout[@]+"${py_timeout[@]}"} python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
enabled = data.get("enabledPlugins") if isinstance(data, dict) else None
if enabled is None:
    sys.exit(0)
if not isinstance(enabled, dict):
    sys.exit(1)
for name, val in enabled.items():
    if val is True and isinstance(name, str):
        print(name)
' "$SETTINGS_JSON" 2>/dev/null)"; then
    echo "✘ $SETTINGS_JSON is unreadable or not the expected JSON shape; cannot confirm [per-project] plugins are disabled" >&2
    exit 1
  fi
  enabled_per_project="$(grep -xF -f <(printf '%s\n' "$per_project") <<<"$enabled_all" || true)"
fi
if [[ -n "$enabled_per_project" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "✘ claude CLI not on PATH; cannot disable [per-project] plugins enabled at user scope" >&2
    exit 1
  fi
  disable_failed=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    echo "── $p is enabled at user scope but listed [per-project]; disabling"
    if ! claude plugin disable --scope user "$p" 2>&1 | tail -1; then
      echo "  ✘ could not disable $p at user scope" >&2
      disable_failed=1
    fi
  done <<<"$enabled_per_project"
  (( disable_failed == 0 )) || exit 1
fi

if [[ -n "$user_scoped" ]] && (( ${#to_remove[@]} == 0 )) \
  && (( ${#unevaluated[@]} == 0 )); then
  missing=0
  for p in ${wanted[@]+"${wanted[@]}"}; do
    if ! grep -qxF "$p" <<<"$user_scoped"; then
      missing=1
      break
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    exit 0
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "✘ claude CLI not on PATH" >&2
  exit 1
fi

installed=()
uninstalled=()
failed=()

for p in ${wanted[@]+"${wanted[@]}"}; do
  echo "── $p"
  if claude plugin install "$p" 2>&1 | tail -1; then
    # Install enables the plugin in the user enabledPlugins map; a
    # [per-project] one must be enabled only by a project's settings (#720).
    # A failed disable leaves the plugin globally enabled, so it fails the run.
    if grep -qxF "$p" <<<"$per_project" \
      && ! claude plugin disable --scope user "$p" 2>&1 | tail -1; then
      failed+=("$p")
      continue
    fi
    installed+=("$p")
  else
    failed+=("$p")
  fi
done

for p in ${to_remove[@]+"${to_remove[@]}"}; do
  echo "── $p (removed from the manifest)"
  if claude plugin uninstall --scope user "$p" 2>&1 | tail -1; then
    uninstalled+=("$p")
  else
    failed+=("$p")
  fi
done

for p in ${unevaluated[@]+"${unevaluated[@]}"}; do
  echo "✘ $p is marked removed but was not checked: $installed_state" >&2
  failed+=("$p")
done

echo
echo "═══ DONE ═══"
echo "Processed: ${#installed[@]} installed, ${#uninstalled[@]} uninstalled, ${#failed[@]} failed"
if (( ${#failed[@]} > 0 )); then
  printf '  ✘ %s\n' "${failed[@]}"
  exit 1
fi
echo "Restart Claude Code to load the plugin changes."
