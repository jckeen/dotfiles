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
    [CmdletBinding()]
    param()
    if (-not (Test-WtAvailable)) { return }

    $wsl = @('wsl.exe', '-d', $script:WslDistro, '--cd', $script:Wsl6Cd)

    # Top-down split for an even 3x2 grid:
    #   1. Split horizontally into top + bottom halves (50/50).
    #   2. Inside the bottom half, split into thirds (1/3 left, then split the
    #      remaining 2/3 in half).
    #   3. Move focus up to the top half, repeat the thirds split.
    # This keeps every pane bound to the same parent geometry, so rounding
    # doesn't accumulate into one runt column the way a flat L-to-R split chain
    # did in the previous version.
    $wtArgs  = @('-w', '0', 'new-tab') + $wsl
    $wtArgs += @(';', 'split-pane', '-H', '-s', '0.5')    + $wsl   # bottom half
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.6667') + $wsl   # bottom: 1/3 | 2/3
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.5')    + $wsl   # bottom: 1/3 | 1/3 | 1/3
    $wtArgs += @(';', 'move-focus', 'up')
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.6667') + $wsl   # top: 1/3 | 2/3
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.5')    + $wsl   # top: 1/3 | 1/3 | 1/3

    # Land in the top-left pane so the user starts at a predictable position.
    $wtArgs += @(';', 'move-focus', 'first')

    & wt.exe @wtArgs
}
