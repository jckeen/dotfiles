# Claude Code scripts on PATH
export PATH="$HOME/.claude/scripts:$PATH"

# Claude Code aliases
alias claude-server='claude remote-control --spawn worktree'
alias claude-rc='claude --remote-control'

# Detect dev directory — reads from ~/.claude/dev-dir (written by setup.sh)
_dev_dir() {
  if [ -f "$HOME/.claude/dev-dir" ]; then
    cat "$HOME/.claude/dev-dir"
  else
    echo "$HOME/dev"
  fi
}

# Pull latest for all git repos under dev directory
pull-all() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir" ]; then
    echo "Dev directory not found: $dev_dir"
    return 1
  fi
  for repo in "$dev_dir"/*/; do
    if [ -d "$repo/.git" ]; then
      local name=$(basename "$repo")
      if git -C "$repo" remote -v 2>/dev/null | grep -q .; then
        printf "  %-20s" "$name"
        git -C "$repo" pull --ff-only 2>&1 | tail -1
      fi
    fi
  done
}

# Check Claude config symlinks are healthy
check-claude() {
  "$(_dev_dir)/dotfiles/check-claude.sh" "$@"
}

# Check Codex public config and private/generated state boundaries
check-codex() {
  "$(_dev_dir)/dotfiles/check-codex.sh" "$@"
}

# Commit and push any pending memory changes from last session
sync-memory() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  local mem_repo="$dev_dir/claude-memory"
  if [ -d "$mem_repo/.git" ]; then
    if [ -n "$(git -C "$mem_repo" status --porcelain 2>/dev/null)" ]; then
      echo "  Saving memory..."
      git -C "$mem_repo" add -A
      git -C "$mem_repo" commit -q -m "auto: sync memory $(date +%Y-%m-%d)"
      git -C "$mem_repo" push -q 2>/dev/null && echo "  Memory saved." || echo "  Memory committed locally (push failed)."
    fi
  fi
}

# Copy PAI config from claude-memory (private) into live ~/.claude/
sync-pai-config() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  local mem_repo="$dev_dir/claude-memory"
  if [ -d "$mem_repo/pai-config" ]; then
    cp "$mem_repo/pai-config/"* "$HOME/.claude/" 2>/dev/null
  fi
  if [ -d "$mem_repo/pai-user" ]; then
    # Recursively copy preserving directory structure (PROJECTS/, TELOS/, etc.)
    cp -r "$mem_repo/pai-user/"* "$HOME/.claude/PAI/USER/" 2>/dev/null
  fi
}

# Validate critical claude-memory symlinks before launching Claude
# Fast check: just tests the 4 most important symlinks exist and aren't broken
_check_critical_symlinks() {
  local broken=0
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
    if [ ! -L "$f" ]; then
      echo "WARNING: $f is not a symlink (expected symlink from claude-memory)"
      broken=1
    elif [ ! -e "$f" ]; then
      echo "WARNING: $f is a broken symlink -> $(readlink "$f")"
      broken=1
    fi
  done
  if [ "$broken" -eq 1 ]; then
    echo "Critical symlinks broken — attempting auto-repair..."
    if [ -f "$HOME/dev/claude-memory/bootstrap.sh" ]; then
      bash "$HOME/dev/claude-memory/bootstrap.sh" && echo "Repair complete." || echo "Repair failed — run bootstrap.sh manually."
    elif [ -f "$(_dev_dir)/dotfiles/setup.sh" ]; then
      bash "$(_dev_dir)/dotfiles/setup.sh" --repair && echo "Repair complete." || echo "Repair failed — run setup.sh --repair manually."
    else
      echo "No repair script found. Run setup.sh or bootstrap.sh manually."
    fi
  fi
}

# Launch Claude, syncing everything first
# Usage: cc                — launch from current dir (defaults to ~/dev if outside a git repo)
#        cc <project>       — cd into ~/dev/<project> first, then launch
#        cc --resume        — resume a session in the current dir (skips sync for fast path)
#        cc -c / --continue — continue most recent session in current dir (skips sync)
#        cc --resume <id>   — resume a specific session id (skips sync)
# Any --resume/-r/--continue/-c in the args triggers the quick-resume path:
# no repo sync, no memory sync, no PAI config sync, no claude health check.
cc() {
  local dev_dir
  dev_dir="$(_dev_dir)"

  # Detect resume-style invocation anywhere in the args
  local resuming=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --resume|-r|--continue|-c) resuming=1; break ;;
    esac
  done

  # If a project name was passed, cd into it (honored even when resuming)
  if [ -n "$1" ] && [[ "$1" != -* ]] && [ -d "$dev_dir/$1" ]; then
    cd "$dev_dir/$1"
  elif [ "$resuming" -eq 0 ] && ! git rev-parse --is-inside-work-tree &>/dev/null; then
    # Not resuming and not in a git repo — default to dev directory
    cd "$dev_dir"
  fi

  # Quick critical symlink validation (fast — just 2 stat calls)
  _check_critical_symlinks

  if [ "$resuming" -eq 0 ]; then
    echo "Syncing repos..."
    pull-all
    echo ""
    sync-memory
    sync-pai-config
    "$(_dev_dir)/dotfiles/check-claude.sh"
    echo ""
  fi

  # Preload architecture diagrams if the project has them
  local diagram_args=()
  if [ -d ".ai/diagrams" ] && ls .ai/diagrams/*.md &>/dev/null; then
    local diagrams=""
    for f in .ai/diagrams/*.md; do
      diagrams+="$(cat "$f")"$'\n'
    done
    diagram_args=(--append-system-prompt "$diagrams")
  fi

  # Set terminal tab color from .claude-color if present
  if [ -f ".claude-color" ]; then
    local hex
    hex=$(head -1 .claude-color | tr -d '[:space:]#')
    if [[ "$hex" =~ ^[0-9a-fA-F]{6}$ ]]; then
      local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
      # Windows Terminal tab color (OSC 9;9)
      printf '\033]9;9;rgb(%d,%d,%d)\033\\' "$r" "$g" "$b"
    fi
  fi

  claude --remote-control --chrome "${diagram_args[@]}" "$@"

  # Reset tab color on exit
  printf '\033]9;9;\033\\' 2>/dev/null
}

# Launch Codex with the same project-selection ergonomics as cc, but without
# touching Claude memory, PAI config, or ~/.claude health checks.
# Usage: cx                 — launch from current dir (defaults to ~/dev outside git)
#        cx <project>        — cd into ~/dev/<project> first, then launch
#        cx resume|fork ...  — resume/fork without repo sync
cx() {
  local dev_dir
  dev_dir="$(_dev_dir)"

  local session_cmd=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      resume|fork) session_cmd=1; break ;;
    esac
  done

  if [ -n "$1" ] && [[ "$1" != -* ]] && [ -d "$dev_dir/$1" ]; then
    cd "$dev_dir/$1"
    shift
  elif [ "$session_cmd" -eq 0 ] && ! git rev-parse --is-inside-work-tree &>/dev/null; then
    cd "$dev_dir"
  fi

  if [ "$session_cmd" -eq 0 ]; then
    echo "Syncing repos..."
    pull-all
    echo ""
    "$(_dev_dir)/dotfiles/check-codex.sh"
    echo ""
  fi

  codex "$@"
}

codex-update() {
  codex update
}

# Update dotfiles: pull latest and re-run setup
dotfiles-update() {
  local dotfiles_dir
  dotfiles_dir="$(_dev_dir)/dotfiles"
  if [ ! -d "$dotfiles_dir/.git" ]; then
    echo "Dotfiles repo not found at $dotfiles_dir"
    return 1
  fi
  echo "Pulling latest dotfiles..."
  git -C "$dotfiles_dir" pull --ff-only || { echo "Pull failed — resolve manually."; return 1; }
  echo "Re-running setup..."
  bash "$dotfiles_dir/setup.sh"
}

# ─── Git worktree shortcuts (Boris's #1 productivity tip) ────────────
# Quick jump to worktrees: za, zb, zc, zd, ze
# Create them with: git worktree add ../project-a -b feature-a
alias za='cd ../$(basename "$PWD")-a 2>/dev/null || echo "Worktree -a not found. Create with: git worktree add ../$(basename "$PWD")-a -b branch-name"'
alias zb='cd ../$(basename "$PWD")-b 2>/dev/null || echo "Worktree -b not found. Create with: git worktree add ../$(basename "$PWD")-b -b branch-name"'
alias zc='cd ../$(basename "$PWD")-c 2>/dev/null || echo "Worktree -c not found. Create with: git worktree add ../$(basename "$PWD")-c -b branch-name"'
alias zd='cd ../$(basename "$PWD")-d 2>/dev/null || echo "Worktree -d not found. Create with: git worktree add ../$(basename "$PWD")-d -b branch-name"'
alias ze='cd ../$(basename "$PWD")-e 2>/dev/null || echo "Worktree -e not found. Create with: git worktree add ../$(basename "$PWD")-e -b branch-name"'
alias z0='cd "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Not in a git repo"'

# Worktree management
alias gwl='git worktree list'
alias gwa='git worktree add'
alias gwr='git worktree remove'

# Quick Claude in a new worktree (uses cc for full sync + tab color)
wt-claude() {
  local name="${1:?Usage: wt-claude <name> [branch]}"
  local branch="${2:-$name}"
  local base
  base="$(git rev-parse --show-toplevel)"
  local wt_path="${base}-${name}"
  if [ ! -d "$wt_path" ]; then
    git worktree add "$wt_path" -b "$branch" 2>/dev/null || git worktree add "$wt_path" "$branch"
  fi
  echo "Starting Claude in worktree: $wt_path"
  (cd "$wt_path" && cc)
}

# ─── Multi-session: Windows Terminal integration ───────────────────
# These commands let you spin up Claude sessions in new panes/tabs
# without leaving your current terminal. Requires Windows Terminal (wt.exe).

# List available projects in your dev directory
projects() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  echo "Projects in $dev_dir:"
  for repo in "$dev_dir"/*/; do
    [ -d "$repo/.git" ] && printf "  %s\n" "$(basename "$repo")"
  done
}

# Open project in a new split pane
# Usage: cc-pane <project>        (vertical split, default)
#        cc-pane <project> -H     (horizontal split)
cc-pane() {
  if ! command -v wt.exe &>/dev/null; then
    echo "wt.exe not found — requires Windows Terminal on WSL"
    return 1
  fi
  local project="$1"
  local split_flag="${2:--V}"
  if [ -z "$project" ]; then
    echo "Usage: cc-pane <project> [-H|-V]"
    echo ""
    projects
    return 1
  fi
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir/$project" ]; then
    echo "Project not found: $dev_dir/$project"
    echo ""
    projects
    return 1
  fi
  wt.exe -w 0 sp "$split_flag" -- wsl.exe bash -ic "cc $project"
}

# Open project in a new Windows Terminal tab
cc-tab() {
  if ! command -v wt.exe &>/dev/null; then
    echo "wt.exe not found — requires Windows Terminal on WSL"
    return 1
  fi
  local project="$1"
  if [ -z "$project" ]; then
    echo "Usage: cc-tab <project>"
    echo ""
    projects
    return 1
  fi
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir/$project" ]; then
    echo "Project not found: $dev_dir/$project"
    echo ""
    projects
    return 1
  fi
  wt.exe -w 0 nt -- wsl.exe bash -ic "cc $project"
}

# Open multiple projects, each in its own tab
# Usage: cc-multi dotfiles pai stringer
cc-multi() {
  if [ $# -eq 0 ]; then
    echo "Usage: cc-multi <project1> <project2> ..."
    echo ""
    projects
    return 1
  fi
  for project in "$@"; do
    cc-tab "$project"
  done
}

# Show active Claude sessions and their working directories
sessions() {
  local found=0
  while IFS= read -r pid; do
    local cwd
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
    if [ $found -eq 0 ]; then
      echo "Active Claude sessions:"
      echo "────────────────────────────────────────"
      found=1
    fi
    printf "  PID %-7s  %s\n" "$pid" "$cwd"
  done < <(pgrep -f "node.*claude" 2>/dev/null)
  [ $found -eq 0 ] && echo "No active Claude sessions"
}

# WSL: open URLs in Windows Chrome
export BROWSER="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
# WSL: force-enable Claude in Chrome
export CLAUDE_CODE_ENABLE_CFC=1
# Extend prompt cache TTL from 5m to 1h (v2.1.108+) for long Algorithm sessions
export ENABLE_PROMPT_CACHING_1H=1
