---
name: claude-server
description: Start a Claude Code remote control server in an isolated worktree for remote access from claude.ai or mobile
user_invocable: true
---

When the user runs /claude-server, do the following:

1. Confirm the user wants to start a remote control server for this project.
2. Run the following command via Bash:

```bash
claude remote-control --spawn worktree
```

3. This will:
   - Start a Claude Code server that can be accessed from claude.ai/code or the Claude mobile app
   - Create an isolated git worktree so remote work doesn't interfere with local changes
4. Display the connection info returned by the command.
5. Remind the user they can also run `claude-server` directly from their terminal (shell alias).
