# lib-symlinks.sh — shared enumerator for the claude/ symlink tree (issue #135).
#
# SOURCED, never executed: no shebang (so check-install-integrity.sh's exec-bit
# rule doesn't apply) and mode 644. Source it relative to the sourcing script's
# own directory, e.g.:
#   source "$(cd "$(dirname "$0")" && pwd)/lib-symlinks.sh"
#
# Before this, the walk of claude/ (top-level → hooks → skills → agents →
# scripts → chrome, with the nolink filter) was written three times — setup.sh's
# install linking, setup.sh's run_health_audit(), and check-claude.sh — and drifted.
# All three now consume symlink_enumerate() so a new asset category or rename is
# edited once. Bin scripts (repo-root helpers → ~/.local/bin) are NOT part of
# this tree: they land outside ~/.claude and only setup.sh's audit manages them.
#
# The nolink list (files kept in claude/ but deliberately not symlinked) comes
# from claude/nolink.txt ONLY — there is no hardcoded fallback. Callers must
# confirm the manifest exists with symlink_require_manifest() and hard-fail if
# it doesn't, so a broken checkout can't silently link files it shouldn't.
# shellcheck shell=bash

# symlink_require_manifest <claude_src> — 0 if claude/nolink.txt exists, else 1.
# Callers use this to hard-fail loudly (a process-substitution failure inside
# symlink_enumerate would otherwise be swallowed by the reading while-loop).
symlink_require_manifest() {
  [ -f "$1/nolink.txt" ]
}

# symlink_load_nolink <claude_src> — echo space-separated nolink filenames from
# claude/nolink.txt (# comments and blank lines ignored). Returns 1 (echoing
# nothing) if the manifest is missing. Single source of truth; no fallback list.
symlink_load_nolink() {
  local manifest="$1/nolink.txt"
  [ -f "$manifest" ] || return 1
  sed 's/#.*//' "$manifest" | awk 'NF {printf "%s ", $1}'
}

# symlink_enumerate <claude_src> <claude_dst> — emit one TAB-separated record
# per managed link in the claude/ tree:
#     <src> \t <dst> \t <label> \t <flags>
# <flags> is "executable" when the SOURCE file should carry +x (hooks, scripts,
# chrome/top-level *.sh), else empty. Returns 1 without output if the nolink
# manifest is missing (callers should have gated on symlink_require_manifest).
# Order matches the historical audit walk: top-level, hooks, skills, agents,
# scripts, chrome. Repo paths here contain no tabs/newlines, so TAB-splitting is safe.
symlink_enumerate() {
  local claude_src="$1" claude_dst="$2"
  local nolink name f skill_dir skill_name
  nolink="$(symlink_load_nolink "$claude_src")" || return 1

  # 1. Top-level files (nolink-filtered). *.sh sources (e.g. statusline.sh) +x.
  for f in "$claude_src/"*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case " $nolink " in *" $name "*) continue ;; esac
    case "$name" in
      *.sh) printf '%s\t%s\t%s\texecutable\n' "$f" "$claude_dst/$name" "$name" ;;
      *)    printf '%s\t%s\t%s\t\n'           "$f" "$claude_dst/$name" "$name" ;;
    esac
  done

  # 2. Hooks — both .sh and .ts (both run as executables).
  for f in "$claude_src/hooks/"*.sh "$claude_src/hooks/"*.ts; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\texecutable\n' "$f" "$claude_dst/hooks/$name" "hooks/$name"
  done

  # 3. Skills — ONE directory link per bundle (issue #592), so references/,
  # scripts/, assets/ and dot-dirs like .claude-plugin/ all reach the
  # destination. Per-file links dropped every subfolder, and a plugin loaded
  # from a skill dir rejects module symlinks that resolve outside it ("Path
  # escapes plugin directory"); a directory link keeps the whole bundle inside
  # one resolved root. src carries no trailing slash so readlink compares equal.
  for skill_dir in "$claude_src/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_dir="${skill_dir%/}"
    skill_name="$(basename "$skill_dir")"
    printf '%s\t%s\t%s\t\n' "$skill_dir" "$claude_dst/skills/$skill_name" "skills/$skill_name"
  done

  # 4. Agents (*.md).
  for f in "$claude_src/agents/"*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\t\n' "$f" "$claude_dst/agents/$name" "agents/$name"
  done

  # 5. Scripts (*.sh, executable), Python helpers and JSON data (plain). Gate
  # scripts resolve sibling files via plain dirname (no readlink -f), so a
  # schema not linked beside the script symlink is invisible to it —
  # codex-review-gate.sh degraded open for exactly this reason.
  for f in "$claude_src/scripts/"*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\texecutable\n' "$f" "$claude_dst/scripts/$name" "scripts/$name"
  done
  for f in "$claude_src/scripts/"*.json "$claude_src/scripts/"*.py; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\t\n' "$f" "$claude_dst/scripts/$name" "scripts/$name"
  done

  # 6. Chrome — all files except docs (*.md); *.sh sources +x.
  for f in "$claude_src/chrome/"*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in *.md) continue ;; esac
    case "$name" in
      *.sh) printf '%s\t%s\t%s\texecutable\n' "$f" "$claude_dst/chrome/$name" "chrome/$name" ;;
      *)    printf '%s\t%s\t%s\t\n'           "$f" "$claude_dst/chrome/$name" "chrome/$name" ;;
    esac
  done
}

# symlink_is_legacy_skill_dir <src_dir> <dst> — 0 when <dst> is a real
# directory in the pre-#592 per-file layout: every entry (dotfiles included) is
# a symlink whose target is exactly <src_dir>/<same name>, live or dangling. An
# empty directory also qualifies. Anything else — a regular file, a
# subdirectory, a foreign link — means someone put content there, so it is NOT
# legacy and the caller must back it up (setup.sh) or report it (checkers).
symlink_is_legacy_skill_dir() {
  local src="$1" dst="$2" entry
  [ -d "$dst" ] && [ ! -L "$dst" ] || return 1
  for entry in "$dst"/* "$dst"/.*; do
    case "${entry##*/}" in .|..) continue ;; esac
    [ -e "$entry" ] || [ -L "$entry" ] || continue  # unmatched glob
    [ -L "$entry" ] || return 1
    [ "$(readlink "$entry")" = "$src/${entry##*/}" ] || return 1
  done
  return 0
}

# symlink_migrate_legacy_skill_dir <src_dir> <dst> — remove a legacy per-file
# skill directory (only our own links, re-checked here) so a directory link can
# replace it. Removes nothing and returns 1 if <dst> is not legacy. The links
# carry no data: each points into the dotfiles bundle that the directory link
# restores, so this is a conversion, not a deletion.
#
# Concurrency (issue #638): two --heal runs may migrate the same dir. Draining
# $dst in place is a TOCTOU — once a rival swaps $dst for the directory link,
# `rm "$dst/x"` resolves through it and deletes the real $src/x. So the run
# first renames $dst to a private sibling, .<name>.migrating.<pid>, and drains
# only that path, which no rival can swap. Rename is atomic, so one run owns
# the dir; a run whose rename fails (a rival took it) returns 0 without action
# and the caller judges the settled state. The sibling is dot-prefixed so a
# skill loader does not pick up the half-drained copy.
symlink_migrate_legacy_skill_dir() {
  local src="$1" dst="$2" parent name pid priv
  parent="${dst%/*}"
  name="${dst##*/}"
  pid="${BASHPID:-$$}"
  priv="$parent/.$name.migrating.$pid"
  _symlink_reap_stale_migrations "$src" "$parent" "$name"
  symlink_is_legacy_skill_dir "$src" "$dst" || return 1
  # The target must not exist: mv onto an existing directory moves INTO it.
  # Only this process creates its own pid's name, so a leftover here is a
  # dead process with a recycled pid; leave it for a later run to reap.
  if [ -e "$priv" ] || [ -L "$priv" ]; then
    echo "symlink_migrate_legacy_skill_dir: $priv already exists" >&2
    return 1
  fi
  # $parent/$name and $priv share a parent, so this is a same-filesystem
  # rename(2) unless $dst is itself a mount point; refuse that, since mv would
  # fall back to a non-atomic copy-and-delete.
  if [ "$(_symlink_dev "$dst")" != "$(_symlink_dev "$parent")" ]; then
    echo "symlink_migrate_legacy_skill_dir: $dst is a mount point" >&2
    return 1
  fi
  if ! mv "$dst" "$priv" 2>/dev/null; then
    # A rival renamed it first: nothing to do. Still a real dir means the
    # rename itself failed (permissions), which is a real failure.
    [ -d "$dst" ] && [ ! -L "$dst" ] && return 1
    return 0
  fi
  if [ -L "$priv" ]; then
    # A rival finished between the legacy check and the rename, and we moved
    # its directory link. Put it back (or drop our copy if $dst was relinked
    # meanwhile); removing a symlink path never touches its target.
    mv "$priv" "$dst" 2>/dev/null || rm -f "$priv"
    return 0
  fi
  _symlink_drain_legacy "$src" "$priv" && return 0
  # Not legacy after all (content appeared mid-flight): restore it untouched.
  mv "$priv" "$dst" 2>/dev/null \
    || echo "symlink_migrate_legacy_skill_dir: left non-legacy content at $priv" >&2
  return 1
}

# _symlink_drain_legacy <src_dir> <dir> — remove a private, legacy-only dir:
# re-check that it holds only our links, unlink them, rmdir it. Returns 1 and
# removes nothing when it is not legacy. <dir> must be a path no rival renames.
_symlink_drain_legacy() {
  local src="$1" dir="$2" entry
  symlink_is_legacy_skill_dir "$src" "$dir" || return 1
  for entry in "$dir"/* "$dir"/.*; do
    case "${entry##*/}" in .|..) continue ;; esac
    [ -L "$entry" ] || continue
    rm "$entry" || return 1
  done
  rmdir "$dir"
}

# _symlink_reap_stale_migrations <src_dir> <parent> <name> — a migrator that
# died mid-drain leaves .<name>.migrating.<pid> behind. Reap each one whose
# owner is gone and which still holds only our links; the reaper first renames
# it to its own pid's name so two reapers never drain the same path. Anything
# holding other content is left in place and reported, never deleted.
_symlink_reap_stale_migrations() {
  local src="$1" parent="$2" name="$3" stale owner mine
  mine="$parent/.$name.migrating.${BASHPID:-$$}"
  for stale in "$parent/.$name.migrating."*; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    owner="${stale##*.migrating.}"
    case "$owner" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$owner" 2>/dev/null && continue  # owner alive (or not ours to signal)
    [ -e "$mine" ] || [ -L "$mine" ] && continue
    mv "$stale" "$mine" 2>/dev/null || continue  # another reaper took it
    if ! _symlink_drain_legacy "$src" "$mine"; then
      mv "$mine" "$stale" 2>/dev/null || stale="$mine"
      echo "symlink_migrate_legacy_skill_dir: stale $stale holds non-link content; left in place" >&2
    fi
  done
}

# _symlink_dev <path> — device number of <path> itself (GNU or BSD stat).
_symlink_dev() {
  stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null
}
