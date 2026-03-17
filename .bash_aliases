# Claude Code aliases
alias claude-server='claude remote-control --spawn worktree'
alias claude-rc='claude --remote-control'

# Pull latest for all git repos under /dev
pull-all() {
  local dev_dir="/mnt/c/Users/jckee/dev"
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
