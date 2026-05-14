# wsl-helpers.ps1 — Agent-neutral PowerShell helpers for WSL on Windows Terminal.
#
# These helpers do NOT call Claude Code, Codex, or any AI agent. They are pure
# WSL+WindowsTerminal conveniences. Companion file `cc-functions.ps1` adds
# Claude-specific launchers (cctab/ccpane/ccgrid). Future `cx-functions.ps1`
# could add Codex equivalents.
#
# Like its siblings, this file is intended to be COPIED to a local Windows path
# (not dot-sourced directly from \\wsl.localhost\...). RemoteSigned execution
# policy blocks scripts loaded over UNC paths with a "not digitally signed"
# error, so a local copy is required. setup.sh handles the install.
#
# Commands:
#   wsl6                                     New WT tab, 3x2 grid of plain WSL shells
#
# Each pane opens at $env:WSL6_CD (default `~/dev`) inside the WSL distro,
# not at WT's launching cwd — otherwise PowerShell sitting in C:\Users\<user>
# pushes every pane to /mnt/c/... which is the wrong filesystem for dev work.

$script:WslDistro = $env:CC_WSL_DISTRO
if (-not $script:WslDistro) { $script:WslDistro = 'Ubuntu' }

$script:Wsl6Cd = $env:WSL6_CD
if (-not $script:Wsl6Cd) {
    # wsl.exe --cd does NOT expand ~ — pass an absolute Linux path.
    # Default: $HOME/dev for the WSL user, resolved via wslvar/wslpath fallback.
    $linuxHome = $null
    try { $linuxHome = (& wsl.exe -d $script:WslDistro -- printf '%s' "`$HOME") } catch {}
    if (-not $linuxHome) { $linuxHome = "/home/$env:USERNAME" }
    $script:Wsl6Cd = "$linuxHome/dev"
}

function Test-WtAvailable {
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        Write-Error 'wt.exe not found — install Windows Terminal first.'
        return $false
    }
    return $true
}

function wsl6 {
    # Open a new Windows Terminal tab with 6 plain WSL shells in a 3-column x
    # 2-row grid (3 across the top, 3 across the bottom). No project launching,
    # no agent invocation — each pane is just `wsl.exe -d <distro>` at its
    # default cwd. Use it for ad-hoc multi-shell work, not for spawning Claude
    # or Codex sessions (see cctab/ccpane/cxtab/cxpane for those).
    #
    # Reliability on slower hardware (Surface ARM, low-spec laptops):
    # Six `wsl.exe` spawns chained through a single `wt.exe` call all race
    # the WSL2 VM cold-start in parallel. Pre-warming the distro before the
    # tab spawns means each pane attaches to an already-running VM and
    # connects ConPTY fast. If you still see a stuck pane after this, set
    # $env:WSL6_PANE_DELAY_MS to a non-zero value (e.g. 200) to serialize
    # the split-pane calls — each pane is then fully attached before the
    # next is created. Default 0 preserves the all-at-once visual.
    [CmdletBinding()]
    param()
    if (-not (Test-WtAvailable)) { return }

    # Pre-warm. Idempotent — no-op if the distro is already running.
    try { & wsl.exe -d $script:WslDistro --cd $script:Wsl6Cd -- true 2>&1 | Out-Null } catch {}

    $wsl = @('wsl.exe', '-d', $script:WslDistro, '--cd', $script:Wsl6Cd)

    $delayMs = 0
    if ($env:WSL6_PANE_DELAY_MS) {
        try { $delayMs = [int]$env:WSL6_PANE_DELAY_MS } catch {}
    }

    if ($delayMs -le 0) {
        # Fast path — single chained wt.exe invocation. Same structure as
        # before: top-down split for an even 3x2 grid.
        $wtArgs  = @('-w', '0', 'new-tab') + $wsl
        $wtArgs += @(';', 'split-pane', '-H', '-s', '0.5')    + $wsl   # bottom half
        $wtArgs += @(';', 'split-pane', '-V', '-s', '0.6667') + $wsl   # bottom: 1/3 | 2/3
        $wtArgs += @(';', 'split-pane', '-V', '-s', '0.5')    + $wsl   # bottom: 1/3 | 1/3 | 1/3
        $wtArgs += @(';', 'move-focus', 'up')
        $wtArgs += @(';', 'split-pane', '-V', '-s', '0.6667') + $wsl   # top: 1/3 | 2/3
        $wtArgs += @(';', 'split-pane', '-V', '-s', '0.5')    + $wsl   # top: 1/3 | 1/3 | 1/3
        $wtArgs += @(';', 'move-focus', 'first')
        & wt.exe @wtArgs
        return
    }

    # Slow path — serialize split-pane calls. Each `wt.exe` call is a
    # separate IPC round-trip; the delay lets the prior pane finish ConPTY
    # attach + bash startup before the next split-pane targets the focused
    # pane. Costs ~$delayMs * 7 of visible tab assembly, in exchange for
    # eliminating any spawn race on very slow machines.
    & wt.exe -w 0 new-tab @wsl
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 split-pane -H -s 0.5 @wsl   # bottom half
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 split-pane -V -s 0.6667 @wsl   # bottom: 1/3 | 2/3
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 split-pane -V -s 0.5 @wsl   # bottom: 1/3 | 1/3 | 1/3
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 move-focus up
    Start-Sleep -Milliseconds ([Math]::Max(100, [int]($delayMs / 2)))

    & wt.exe -w 0 split-pane -V -s 0.6667 @wsl   # top: 1/3 | 2/3
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 split-pane -V -s 0.5 @wsl   # top: 1/3 | 1/3 | 1/3
    Start-Sleep -Milliseconds $delayMs

    & wt.exe -w 0 move-focus first
}
