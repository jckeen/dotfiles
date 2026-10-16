# Keep the selected WSL distribution available for its enabled Codex user service.
# Run in a normal PowerShell session for the Windows user who owns the distro.
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$Distribution
)

$ErrorActionPreference = 'Stop'
$wsl = "$env:SystemRoot\System32\wsl.exe"
& $wsl --distribution $Distribution --exec systemctl --user is-enabled --quiet codex-remote-control.service
if ($LASTEXITCODE -ne 0) {
    throw "Enable codex-remote-control.service in '$Distribution' before installing its Windows startup task."
}
$taskName = "Codex Remote Control - $Distribution"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# A headless console host keeps the client attached without opening a window.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless -- `"$wsl`" --distribution $Distribution --exec /bin/sleep infinity"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew

# Avoid touching an already-running keepalive during an installer rerun.
# Explicit WSL shutdown stays stopped until the next login or manual task start.
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Actions.Count -ne 1 -or
        $existing.Actions[0].Execute -ne $action.Execute -or
        $existing.Actions[0].Arguments -ne $action.Arguments) {
        throw "Task '$taskName' already exists with a different action; inspect it before replacing it."
    }
    Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
} else {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Start WSL at login and keep Codex Remote Control available while Windows is awake.' | Out-Null
}
Start-ScheduledTask -TaskName $taskName
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State
