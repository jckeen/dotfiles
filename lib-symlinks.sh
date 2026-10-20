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
  # Unreadable (no r): the glob lists nothing, so it would look empty. Not
  # traversable (no x): every -e/-L fails, so entries would look absent.
  # Either way we cannot see its content, so it is not legacy (issue #638).
  [ -r "$dst" ] && [ -x "$dst" ] || return 1
  for entry in "$dst"/* "$dst"/.*; do
    case "${entry##*/}" in .|..) continue ;; esac
    [ -e "$entry" ] || [ -L "$entry" ] || continue  # unmatched glob
    [ -L "$entry" ] || return 1
    [ "$(readlink "$entry")" = "$src/${entry##*/}" ] || return 1
  done
  return 0
}

# symlink_migrate_legacy_skill_dir <src_dir> <dst> — move a legacy per-file
# skill directory (only our own links, checked here) out of the way so a
# directory link can replace it. Returns 1, touching nothing, if <dst> is not
# legacy. Returns 0 once <dst> is gone; the caller then creates the link.
#
# Concurrency (issue #638): it never deletes. Unlinking the links by path
# raced a concurrent --heal: once a rival swapped $dst for the directory link,
# `rm "$dst/x"` resolved through it and deleted the real $src/x, and no shell
# or Node call can unlink "only if still a symlink". So the whole directory is
# renamed (rename(2), atomic) into the archive
#   <claude>/.migrated-skill-dirs/<name>.<UTC timestamp>.<pid>
# beside skills/, where no skill loader looks and no link scan reaches. It is
# kept on purpose. check-claude.sh flags every archived entry that is not
# only old links (KEPT); an entry is safe to delete by hand only if it is not
# flagged. Content that changed during a migration goes to kept/. A run whose rename fails because a rival already
# moved or relinked $dst returns 0 and lets the caller judge the settled state.
symlink_migrate_legacy_skill_dir() {
  local src="$1" dst="$2" name archive dest
  name="${dst##*/}"
  archive="${dst%/*/*}/.migrated-skill-dirs"
  symlink_is_legacy_skill_dir "$src" "$dst" || return 1
  mkdir -p "$archive" || return 1
  # rename(2) cannot cross filesystems; refuse with a clear message rather
  # than let anything fall back to a non-atomic copy.
  if [ "$(_symlink_dev "$dst")" != "$(_symlink_dev "$archive")" ]; then
    echo "symlink_migrate_legacy_skill_dir: $dst and $archive are on different filesystems" >&2
    return 1
  fi
  dest="$archive/$name.$(date -u +%Y%m%dT%H%M%SZ).${BASHPID:-$$}"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "symlink_migrate_legacy_skill_dir: $dest already exists" >&2
    return 1
  fi
  if ! _symlink_rename "$dst" "$dest"; then
    # A rival moved it first: nothing to do. Still a real dir means the
    # rename itself failed (permissions), a real failure.
    [ -d "$dst" ] && [ ! -L "$dst" ] && return 1
    return 0
  fi
  # A rival's directory link, grabbed between the check and the rename, is
  # left in the archive (it is only a link); the caller relinks $dst. Putting
  # it back could overwrite whatever appeared at $dst meanwhile.
  [ -L "$dest" ] && return 0
  symlink_is_legacy_skill_dir "$src" "$dest" && return 0
  # Content appeared mid-flight (a file in the moved dir, or a file that took
  # $dst's place before the rename). It is never renamed back: rename(2) cannot
  # refuse to overwrite, so a check-then-rename could clobber whatever has
  # since appeared at $dst. It goes to kept/, which check-claude.sh reports.
  local kept="$archive/kept/${dest##*/}"
  if mkdir -p "$archive/kept" && _symlink_rename "$dest" "$kept"; then
    dest="$kept"
  fi
  echo "symlink_migrate_legacy_skill_dir: $dst changed during migration; its content is kept at $dest — review it" >&2
  return 1
}

# _symlink_rename <from> <to> — rename(2) only. Unlike mv it never moves <from>
# INTO <to> when <to> is (or links to) a directory, and never falls back to a
# non-atomic copy across filesystems; it just fails. perl ships with macOS and
# every Debian/Ubuntu base system.
_symlink_rename() {
  perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null
}

# _symlink_dev <path> — device number of <path> itself (GNU or BSD stat).
_symlink_dev() {
  stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null
}
