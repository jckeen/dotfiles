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
  local nolink name f skill_dir skill_name skill_file fname
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

  # 3. Skills — every file, preserving each skill's subdirectory.
  for skill_dir in "$claude_src/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    for skill_file in "$skill_dir"*; do
      [ -f "$skill_file" ] || continue
      fname="$(basename "$skill_file")"
      printf '%s\t%s\t%s\t\n' "$skill_file" "$claude_dst/skills/$skill_name/$fname" "skills/$skill_name/$fname"
    done
  done

  # 4. Agents (*.md).
  for f in "$claude_src/agents/"*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\t\n' "$f" "$claude_dst/agents/$name" "agents/$name"
  done

  # 5. Scripts (*.sh, executable) + their data files (*.json, plain). Gate
  # scripts resolve sibling files via plain dirname (no readlink -f), so a
  # schema not linked beside the script symlink is invisible to it —
  # codex-review-gate.sh degraded open for exactly this reason.
  for f in "$claude_src/scripts/"*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    printf '%s\t%s\t%s\texecutable\n' "$f" "$claude_dst/scripts/$name" "scripts/$name"
  done
  for f in "$claude_src/scripts/"*.json; do
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
