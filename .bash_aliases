# Claude Code aliases
alias claude-server='claude remote-control --spawn worktree'
alias claude-rc='claude --remote-control'

# Detect dev directory (WSL uses /mnt/c/Users/jckee/dev, others use ~/dev)
_dev_dir() {
  if [ -d "/mnt/c/Users/jckee/dev" ]; then
    echo "/mnt/c/Users/jckee/dev"
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

# Launch Claude in a persistent tmux session, pulling repos first
cc() {
  echo "Syncing repos..."
  pull-all
  echo ""
  if tmux has-session -t claude 2>/dev/null; then
    tmux attach-session -t claude
  else
    tmux new-session -s claude "claude $*; bash"
  fi
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

# Quick Claude in a new worktree
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
  (cd "$wt_path" && claude)
}
