#!/usr/bin/env bash
# check-no-personal-data.sh — deterministic public-repo leak guard.
#
# Fails (exit 1) when a *tracked* file contains a machine-specific home path that
# embeds a real local username — `/home/<name>/dev/...`, `/Users/<name>/...`, or
# `C:\Users\<name>\...`. These leak whoever ran setup.sh into a public repo and
# are never portable — real paths belong in the untracked, per-machine
# .gitconfig.local (and other *.local files), not in committed dotfiles.
#
# Root cause this guards against: `git config --global` writes to ~/.gitconfig,
# which setup.sh symlinks to the tracked .gitconfig — so a stray --global write
# can commit `/home/<you>/...` into the public repo. setup.sh now writes such
# config to .gitconfig.local instead; this check is the backstop.
#
# What is allowed (NOT flagged):
#   - Placeholder usernames in docs/examples: /home/you, /home/user, etc.
#   - The public GitHub handle in URLs/CODEOWNERS (e.g. github.com/jckeen/...) —
#     this guard only matches *filesystem* home paths, not handles or URLs.
#   - `$HOME`, `${HOME}`, `~`, `$USER` — the portable forms we want people to use.
#
# Usage:  claude/scripts/check-no-personal-data.sh
# Run from anywhere; resolves its own repo root (it is symlinked into ~/.claude).

set -euo pipefail

# --- Locate repo root via the real (symlink-resolved) path -----
# Mirrors check-doc-refs.sh: this script is symlinked into ~/.claude/scripts, so
# BASH_SOURCE may be a symlink; resolve it before walking up to the checkout.
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Placeholder usernames that are fine to ship in docs/examples.
PLACEHOLDERS='you|<you>|user|username|youruser|your-user|name|me|USER|\$USER|\$\{USER\}|\$\{?HOME\}?'

# Matches a real home path: /home/<name>/ , /Users/<name>/ , or C:\Users\<name>\
# followed by something (a bare /home/you with no trailing slash is left alone).
HOME_PATH_RE='(/home/|/Users/)[A-Za-z0-9._-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+'

found=0
while IFS= read -r -d '' file; do
  # Skip binary files; grep -I excludes them from output anyway.
  while IFS=: read -r lineno line; do
    [[ -z "$lineno" ]] && continue
    # Allow placeholder usernames.
    if printf '%s' "$line" | grep -qE "(/home/|/Users/)(${PLACEHOLDERS})/"; then
      continue
    fi
    if [[ $found -eq 0 ]]; then
      echo "✖ Tracked files contain machine-specific home paths (public-repo leak):"
      echo "  These embed a real local username. Move them to an untracked *.local"
      echo "  file, or use \$HOME / ~ / a placeholder like /home/you/."
      echo ""
    fi
    found=1
    echo "  $file:$lineno: $line"
  done < <(grep -InE "$HOME_PATH_RE" "$file" 2>/dev/null || true)
done < <(git ls-files -z)

if [[ $found -ne 0 ]]; then
  echo ""
  echo "If a match is an intentional example, rewrite it with a placeholder"
  echo "username (e.g. /home/you/) so the guard stays meaningful."
  exit 1
fi

echo "✓ No machine-specific home paths in tracked files."
