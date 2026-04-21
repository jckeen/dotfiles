# cc-functions.ps1 — PowerShell launchers for Claude Code across multiple repos.
#
# Mirrors the bash cc-pane / cc-tab / cc-multi helpers, but callable directly
# from PowerShell on Windows. Each pane/tab runs `cc <project>` inside WSL,
# which pulls the repo and launches Claude.
#
# This file is intended to be COPIED to a local Windows path (not dot-sourced
# directly from \\wsl.localhost\...). The RemoteSigned execution policy blocks
# scripts loaded over UNC/network paths with a "not digitally signed" error,
# so a local copy is required. See README for the install snippet.
#
# Commands:
#   ccprojects                               List available projects
#   cctab <project> [<project> ...]          One tab per project
#   ccpane <project> [-Horizontal]           Split current WT window
#   ccgrid <project> <project> ...           New tab, split into a grid of panes
#   ccupdate                                 Refresh local copy from WSL source

$script:WslDistro  = $env:CC_WSL_DISTRO
if (-not $script:WslDistro) { $script:WslDistro = 'Ubuntu' }

$script:DevDir     = $env:CC_DEV_DIR
if (-not $script:DevDir) { $script:DevDir = '~/dev' }

function Test-WtAvailable {
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        Write-Error 'wt.exe not found — install Windows Terminal first.'
        return $false
    }
    return $true
}

function Test-WslProject {
    param([string]$Project)
    $check = wsl.exe -d $script:WslDistro -- bash -ic "[ -d $script:DevDir/$Project ] && echo ok" 2>$null
    return ($check -match 'ok')
}

function ccprojects {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Error 'wsl.exe not found.'
        return
    }
    wsl.exe -d $script:WslDistro -- bash -ic 'projects'
}

function cctab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Projects
    )
    if (-not (Test-WtAvailable)) { return }
    foreach ($p in $Projects) {
        if (-not (Test-WslProject $p)) {
            Write-Warning "Skipping unknown project: $p"
            continue
        }
        wt.exe -w 0 new-tab --title $p wsl.exe -d $script:WslDistro -- bash -ic "cc $p"
    }
}

function ccpane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Project,
        [switch]$Horizontal
    )
    if (-not (Test-WtAvailable)) { return }
    if (-not (Test-WslProject $Project)) {
        Write-Error "Project not found: $Project"
        return
    }
    $splitFlag = if ($Horizontal) { '-H' } else { '-V' }
    wt.exe -w 0 split-pane $splitFlag wsl.exe -d $script:WslDistro -- bash -ic "cc $Project"
}

function ccupdate {
    [CmdletBinding()]
    param(
        [string]$Source,
        [string]$Destination
    )
    if (-not $Destination) {
        $Destination = $MyInvocation.MyCommand.ScriptBlock.File
    }
    if (-not $Destination) {
        Write-Error 'ccupdate: cannot determine local script path. Pass -Destination <path>.'
        return
    }
    if (-not $Source) {
        $wslUser = (wsl.exe -d $script:WslDistro -- bash -c 'echo $USER' 2>$null | ForEach-Object { $_.Trim() }) -join ''
        if (-not $wslUser) {
            Write-Error 'ccupdate: could not resolve WSL username. Pass -Source <path>.'
            return
        }
        $Source = "\\wsl.localhost\$($script:WslDistro)\home\$wslUser\dev\dotfiles\windows\cc-functions.ps1"
    }
    if (-not (Test-Path $Source)) {
        Write-Error "ccupdate: source not found: $Source"
        return
    }
    Copy-Item $Source $Destination -Force
    Write-Host "Updated $Destination from $Source. Re-run '. `$PROFILE' to reload."
}

function ccgrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Projects
    )
    if (-not (Test-WtAvailable)) { return }

    $valid = @()
    foreach ($p in $Projects) {
        if (Test-WslProject $p) { $valid += $p }
        else { Write-Warning "Skipping unknown project: $p" }
    }
    if ($valid.Count -eq 0) {
        Write-Error 'No valid projects to open.'
        return
    }

    # wt.exe arg-chain with `;` as subcommand separator. In PowerShell we pass
    # `';'` as its own argument so wt interprets it instead of the shell.
    $first = $valid[0]
    $wtArgs = @('-w', '0', 'new-tab', '--title', $first,
                'wsl.exe', '-d', $script:WslDistro, '--', 'bash', '-ic', "cc $first")

    # Alternate vertical / horizontal splits for an even-ish grid.
    for ($i = 1; $i -lt $valid.Count; $i++) {
        $p = $valid[$i]
        $splitFlag = if ($i % 2 -eq 1) { '-V' } else { '-H' }
        $wtArgs += @(';', 'split-pane', $splitFlag, '--title', $p,
                     'wsl.exe', '-d', $script:WslDistro, '--', 'bash', '-ic', "cc $p")
    }

    # Tile evenly once all panes exist so none get starved.
    $wtArgs += @(';', 'move-focus', 'first')

    & wt.exe @wtArgs
}
