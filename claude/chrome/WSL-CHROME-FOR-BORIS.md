# Claude in Chrome: WSL2 Support

We got `claude --chrome` fully working on WSL2 with Windows Chrome. Navigation, screenshots, tool calls all work end-to-end through a native messaging bridge. Here's what the codebase needs to support it natively.

## Architecture (proven working)

```
Windows Chrome + Extension
    ↓ native messaging (stdin/stdout, 4-byte length prefix)
chrome-native-host.bat (Windows side)
    ↓ wsl.exe -d <distro> -- claude --chrome-native-host
claude --chrome-native-host (Linux/WSL side)
    ↓ unix domain socket
claude --chrome (MCP client)
```

We confirmed `wsl.exe` preserves binary stdin/stdout integrity — the 4-byte length-prefixed native messaging protocol works through `wsl.exe` without corruption.

## What needs to change

### 1. Remove the WSL hard-block in the `/chrome` UI

The `/chrome` slash command component gates all options behind `isWSL || !isSubscriber`. Drop the `isWSL` part so WSL users see the same UI as everyone else (still gated on subscription). Remove or soften the "not supported in WSL" error message.

### 2. Add WSL to the Chrome auto-enable logic

When `isWslEnvironment()` is true and `--chrome` is passed (or `claudeInChromeDefaultEnabled` is set), Chrome integration should initialize normally. Currently it's blocked by feature gates that exclude WSL. The existing `CLAUDE_CODE_ENABLE_CFC=1` env var works as a bypass, but WSL should be a first-class path in the enable check.

### 3. Auto-create the native messaging bridge on WSL

When `isWslEnvironment()` is true and Chrome integration initializes, Claude Code should set up the Windows-side bridge automatically. Four pieces:

**a) `.bat` bridge** at `C:\Users\<user>\.claude\chrome\chrome-native-host.bat`:
```bat
@echo off
wsl.exe -d <distro> -- <claude-path> --chrome-native-host
```

**b) Native messaging manifest** at `C:\Users\<user>\.claude\chrome\com.anthropic.claude_code_browser_extension.json`:
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

**c) Windows registry key** so Chrome discovers the native host:
```
HKCU\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension
  (Default) = C:\Users\<user>\.claude\chrome\com.anthropic.claude_code_browser_extension.json
```
Via: `reg.exe add "<key>" /ve /t REG_SZ /d "<manifest-path>" /f`

**d) Extension detection symlink** — Claude Code checks `~/.config/google-chrome/<Profile>/Extensions/` to detect the extension. On WSL, symlink this to the Windows Chrome extensions directory:
```
mkdir -p ~/.config/google-chrome/Default
ln -s "/mnt/c/Users/<user>/AppData/Local/Google/Chrome/User Data/Default/Extensions" \
      ~/.config/google-chrome/Default/Extensions
```

### 4. Fix the URL opener for WSL

The browser-open function in the `/chrome` UI handles `"wsl"` and `"linux"` identically — it loops through Linux Chrome binaries. On WSL this opens URLs in WSLg Chrome instead of Windows Chrome.

Fix: in the `"wsl"` case, use the Windows Chrome executable path directly, or respect `process.env.BROWSER`.

## Reference implementation

Working setup script (idempotent, auto-detects everything):
https://github.com/jckeen/dotfiles/blob/main/claude/chrome/setup-wsl-chrome-bridge.sh

## Known issue: `document_idle` detection broken over WSL bridge

**Status**: Upstream bug — affects all WSL bridge configurations (`.bat` and compiled `.exe` shims).

**Symptom**: Tools that depend on `chrome.scripting.executeScript()` with `document_idle` timing hang for 45 seconds then timeout. The extension's tab icon shows an hourglass during the wait.

**What works**: `navigate`, `tabs_create`, `tabs_context`, `javascript_tool`

**What fails**: `read_page`, `get_page_text`, `screenshot` — anything that injects a content script and waits for idle

**Root cause**: The extension's `mcpPermissions-zxU6uxCu.js` races `executeScript()` against a 45-second timeout. Chrome's internal `document_idle` event never fires when the native host runs through the `wsl.exe` stdio bridge. This is **not** a cmd.exe buffering issue — a compiled Go `.exe` shim that directly pipes stdio to `wsl.exe` has the same behavior. `document.readyState` reports `"complete"` via `javascript_tool`, confirming the page is loaded — Chrome's idle detection just doesn't trigger.

**Workaround**: Use `javascript_tool` to read page content directly:
```js
// Instead of read_page / get_page_text:
document.body.innerText
```

**Potential upstream fix**: Use `document_end` instead of `document_idle` as the script injection timing, or add a fallback that checks `document.readyState` directly when `document_idle` times out.

**Connection stability note**: Repeated timeouts can cause the bridge connection to drop entirely ("Browser extension is not connected"). When this happens, restart both Chrome (fully quit from system tray) and Claude Code — restarting Chrome alone is not sufficient.

## Gotchas

1. **JSON backslash escaping**: The manifest `path` must have escaped backslashes (`C:\\Users\\...`). If generating from bash, heredocs with variable expansion will collapse `\\` to `\`, producing invalid JSON that Chrome silently ignores.

2. **Chrome caches native host registrations**: Chrome must be fully restarted (quit from system tray, not just close window) after creating the registry key and manifest.

3. **Binary data through `.bat` works**: Despite `cmd.exe` defaulting to text mode, `wsl.exe` takes over the raw stdin/stdout handles, so the 4-byte length prefix passes through uncorrupted. A compiled `.exe` shim would be more robust if this ever breaks.

4. **No conflict with Claude Desktop**: Desktop registers `com.anthropic.claude_browser_extension`, Code uses `com.anthropic.claude_code_browser_extension`. The extension tries both sequentially — no conflict.

5. **Extension detection symlink quirk**: The parent directory (`~/.config/google-chrome/Default/`) must be a real `mkdir`'d directory. If you symlink the profile directory itself, Node's `readdir` with `withFileTypes` doesn't follow it correctly.

6. **First-run UX**: User needs the Chrome extension installed before the bridge works. The "Install Chrome extension" link in `/chrome` needs to open in Windows Chrome (see #4 above), not WSLg Chrome.
