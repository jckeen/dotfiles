# Claude in Chrome: WSL2 Support

We got `claude --chrome` fully working on WSL2 with Windows Chrome. Everything works — navigation, screenshots, tool calls — through the native messaging bridge. Here's what the codebase needs to support it natively.

## Architecture (already works)

```
Windows Chrome + Extension
    ↓ native messaging (stdin/stdout, 4-byte length prefix)
chrome-native-host.bat (Windows side)
    ↓ wsl.exe -d <distro> -- claude --chrome-native-host
claude --chrome-native-host (Linux side)
    ↓ unix domain socket
claude --chrome (MCP client)
```

We confirmed `wsl.exe` preserves binary stdin/stdout integrity. The ping/pong handshake works. Tool calls work end-to-end.

## What needs to change in Claude Code

### 1. Remove the WSL hard-block in the `/chrome` UI

**File**: `src/utils/claudeInChrome/setup.ts` (or wherever `lz9` component lives)

The `/chrome` slash command has a WSL gate that blocks the entire UI:

```js
// Current: blocks options if WSL OR not subscriber
let u = z || !f   // z = isWSL, f = isClaudeAISubscriber

// Fix: only block if not subscriber
let u = !f
```

And the error message `"Claude in Chrome is not supported in WSL at this time."` should be removed or changed to a warning that says setup is required.

### 2. Auto-create the native messaging bridge on WSL

When `isWslEnvironment()` is true and `--chrome` is used, Claude Code should:

**a) Create the Windows-side `.bat` bridge:**
```bat
@echo off
wsl.exe -d <distro> -- <claude-path> --chrome-native-host
```
At: `C:\Users\<user>\.claude\chrome\chrome-native-host.bat`

**b) Create the native messaging manifest:**
```json
{
  "name": "com.anthropic.claude_code_browser_extension",
  "description": "Claude Code Browser Extension Native Host",
  "path": "C:\\Users\\<user>\\.claude\\chrome\\chrome-native-host.bat",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"
  ]
}
```
At: `C:\Users\<user>\.claude\chrome\com.anthropic.claude_code_browser_extension.json`

**Important**: The `path` field must have escaped backslashes (`\\`) — this is JSON, not a filesystem path.

**c) Set the Windows registry key:**
```
HKCU\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension
  (Default) = C:\Users\<user>\.claude\chrome\com.anthropic.claude_code_browser_extension.json
```

Using: `reg.exe add "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension" /ve /t REG_SZ /d "<path>" /f`

**d) Symlink Windows Chrome Extensions into WSL for detection:**

Claude Code checks `~/.config/google-chrome/<Profile>/Extensions/` to detect the extension. On WSL, symlink it to the Windows Chrome extensions directory:

```
~/.config/google-chrome/Default/Extensions → /mnt/c/Users/<user>/AppData/Local/Google/Chrome/User Data/Default/Extensions
```

Note: The parent directory (`~/.config/google-chrome/Default/`) must be a real directory, not a symlink — Node's `readdir` doesn't follow symlinked parent dirs properly.

### 3. Fix the URL opener for WSL

The `jS$` function (opens URLs from `/chrome` menu) handles `"wsl"` and `"linux"` identically — it loops through `K.linux.binaries` and runs them. On WSL this opens URLs in the WSLg Chrome instead of Windows Chrome.

Fix: In the `"wsl"` case, use the Windows Chrome path or `BROWSER` env var:
```js
case "wsl": {
  // Use Windows Chrome directly
  const winChrome = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";
  const { code } = await K8(winChrome, [H]);
  return code === 0;
}
```

Or respect `process.env.BROWSER` as the `open` package already does for the general URL opener.

### 4. `CLAUDE_CODE_ENABLE_CFC` already works

This undocumented env var bypasses all feature gates and enables Chrome integration. It's the only thing that makes WSL work today (along with the binary patch). Consider documenting it or making the WSL path just work without it.

## Setup script (reference implementation)

We have a working setup script at:
https://github.com/jckeen/dotfiles/blob/main/claude/chrome/setup-wsl-chrome-bridge.sh

It's idempotent, auto-detects Windows username/WSL distro/Chrome profile, and handles all the pieces above. Could be adapted into Claude Code's own WSL setup path.

## Gotchas we hit

1. **JSON backslash escaping**: Bash heredocs with `${VAR}` containing `\\` reduce to single `\`, producing invalid JSON. The manifest `path` must be `C:\\Users\\...` in the actual file.

2. **Chrome caches native host registrations**: Chrome must be fully restarted (not just new tab) after creating the registry key and manifest.

3. **Binary data through `.bat`**: `cmd.exe` defaults to text mode, but `wsl.exe` takes over the raw stdin/stdout handles so binary data (the 4-byte length prefix) passes through uncorrupted.

4. **Competing native hosts**: Claude Desktop registers `com.anthropic.claude_browser_extension` while Claude Code uses `com.anthropic.claude_code_browser_extension`. The extension tries both — no conflict.

5. **Extension detection needs a real parent dir**: Symlinking `~/.config/google-chrome/Default/` directly doesn't work. Must `mkdir -p` the directory and symlink only `Extensions/` inside it.
