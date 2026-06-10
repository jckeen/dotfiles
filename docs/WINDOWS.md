# Windows / PowerShell helpers

Deep-dive reference for the Windows side of this setup: multi-session Claude
across Windows Terminal panes/tabs, driven from PowerShell or from inside WSL.
For first-time setup, see the [README Quick Start](../README.md#quick-start);
for daily commands, see [CLAUDE-GUIDE](../CLAUDE-GUIDE.md).

**Use PowerShell 7** (`pwsh.exe`) if at all possible — it's the modern,
cross-platform PowerShell and what these helpers are designed for. Windows
ships with PowerShell 5.1 (`powershell.exe`) which still works (we wire both
profiles), but PS 7 is faster and is what you should default to. Install PS 7
with `winget install --id Microsoft.PowerShell` if you don't have it.

## The two helper files

| File | Scope | Functions |
|------|-------|----------|
| `windows/wsl-helpers.ps1` | **Agent-neutral** — no Claude/Codex required | `wsl6` |
| `windows/cc-functions.ps1` | **Claude-specific** — wraps `cc <project>` inside WSL | `ccgrid`, `cctab`, `ccpane`, `ccprojects`, `ccupdate` |

`setup.sh` installs **both** files into **both PowerShell hosts** (5.1 and 7)
automatically on WSL — they have different `$PROFILE` paths
(`Documents\WindowsPowerShell\` vs `Documents\PowerShell\`), so wiring only one
would leave the other broken. If you want only the agent-neutral piece on a
machine that doesn't run Claude, copy just `wsl-helpers.ps1` and skip
`cc-functions.ps1`.

| Command | File | What it does |
|---------|------|-------------|
| `wsl6` | wsl-helpers | New tab with a **3×2 grid of plain WSL shells** (no agent) |
| `ccgrid <p1> <p2> ...` | cc-functions | One new tab, each project in its own **split pane** (auto-tiled grid) |
| `ccpane <project> [-Horizontal]` | cc-functions | Split the current WT window with one project |
| `cctab <p1> <p2> ...` | cc-functions | One **tab** per project |
| `ccprojects` | cc-functions | List available projects (from WSL) |
| `ccupdate` | cc-functions | Refresh the local copy from the WSL source |

## Install

**`setup.sh` does this for you on WSL.** Section 7b detects WSL, calls **both**
`powershell.exe` (PS 5.1) and `pwsh.exe` (PS 7) when present, copies both
helper files to `$env:USERPROFILE\.<name>.ps1`, and dot-sources each from each
host's `$PROFILE` — idempotent, so re-running setup just refreshes the local
copies. Open a new PowerShell window (5.1 or 7 — both work) and `wsl6` /
`ccgrid` are ready.

> **Missed the prompt or installed before this split?** Just run
> `dotfiles-update` from WSL — it pulls the latest and re-runs setup. The
> PowerShell prompt fires again and both files are installed/refreshed in both
> PS profiles.

**Manual install** (if you skipped the setup.sh prompt or are on a machine that
didn't run setup) — run these in PowerShell, replacing `<you>` with your WSL
username:

```powershell
# 1. Allow local scripts (one time, per-user)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 2. Copy both helper files from the WSL dotfiles checkout to LOCAL Windows paths.
#    (RemoteSigned blocks scripts loaded directly from \\wsl.localhost\... with a
#    "not digitally signed" error, so dot-sourcing local copies is required.)
$base = '\\wsl.localhost\Ubuntu\home\<you>\dev\dotfiles\windows'
foreach ($f in @('wsl-helpers.ps1', 'cc-functions.ps1')) {
  Copy-Item "$base\$f" "$env:USERPROFILE\.$f" -Force
}

# 3. Wire both into your PowerShell profile
if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force }
foreach ($f in @('wsl-helpers.ps1', 'cc-functions.ps1')) {
  Add-Content $PROFILE (". '" + "$env:USERPROFILE\.$f" + "'")
}

# 4. Reload
. $PROFILE
```

**Running from bash/WSL?** Bridge into PowerShell with this one-liner — it
auto-resolves your WSL username and distro via env vars, so paste it verbatim.
**`WSLENV` is required**: WSL→Windows interop does *not* propagate env vars to
`powershell.exe` by default.

```bash
WSL_USER="$(whoami)" WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}" \
WSLENV="WSL_USER:WSL_DISTRO" \
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
  if (-not (Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force | Out-Null }
  $base = "\\wsl.localhost\$env:WSL_DISTRO\home\$env:WSL_USER\dev\dotfiles\windows"
  foreach ($f in @("wsl-helpers.ps1", "cc-functions.ps1")) {
    Copy-Item "$base\$f" "$env:USERPROFILE\.$f" -Force
    $pattern = [regex]::Escape($f)
    if (-not (Select-String -Path $PROFILE -Pattern $pattern -Quiet)) {
      Add-Content $PROFILE (". `"$env:USERPROFILE\.$f`"")
    }
  }
'
```

Then open a new PowerShell window and `wsl6` / `ccgrid` / `cctab` / etc. will
be defined.

## Updating

After dotfiles updates, run `ccupdate` in PowerShell to refresh the local copy
of `cc-functions.ps1` (then `. $PROFILE` to reload). For `wsl-helpers.ps1`,
re-run `setup.sh` (or `dotfiles-update` from WSL).

## Overrides

Override the WSL distro or dev dir in your profile **before** the dot-source
line if yours differ:

```powershell
$env:CC_WSL_DISTRO = 'Ubuntu-22.04'   # default: Ubuntu
$env:CC_DEV_DIR    = '~/code'         # default: ~/dev
. "$env:USERPROFILE\.cc-functions.ps1"
```

## Example

Five repos in a split-pane grid, one command:

```powershell
ccgrid dotfiles atlas stringer beacon trnn
```

That opens a new Windows Terminal tab with five panes (alternating
vertical/horizontal splits), each running `cc <project>` inside WSL.
