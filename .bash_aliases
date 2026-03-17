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
