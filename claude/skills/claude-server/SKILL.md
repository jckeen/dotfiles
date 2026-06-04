---
name: claude-server
description: Starts a Claude Code remote-control server via `claude remote-control --spawn worktree`, running in an isolated git worktree so remote work doesn't touch local changes, and returns the connection info for claude.ai/code and the Claude mobile app. Use when the user wants to control this project remotely, asks to "start the remote server", "connect from my phone/mobile", "access this from claude.ai", or "spin up claude-server".
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
