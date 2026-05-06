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

$script:WslDistro = $env:CC_WSL_DISTRO
if (-not $script:WslDistro) { $script:WslDistro = 'Ubuntu' }

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

    $wsl = @('wsl.exe', '-d', $script:WslDistro)

    # Build 3 even-width columns: first split gives the right-hand pane 2/3 of
    # the width, then split that 2/3 region in half so all three columns are 1/3.
    $wtArgs  = @('-w', '0', 'new-tab') + $wsl
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.6667') + $wsl
    $wtArgs += @(';', 'split-pane', '-V', '-s', '0.5')    + $wsl

    # Focus is on the rightmost column. Split it horizontally, walk left, repeat.
    $wtArgs += @(';', 'split-pane', '-H') + $wsl
    $wtArgs += @(';', 'move-focus', 'left')
    $wtArgs += @(';', 'split-pane', '-H') + $wsl
    $wtArgs += @(';', 'move-focus', 'left')
    $wtArgs += @(';', 'split-pane', '-H') + $wsl

    # Land in the top-left pane so the user starts at a predictable position.
    $wtArgs += @(';', 'move-focus', 'first')

    & wt.exe @wtArgs
}
