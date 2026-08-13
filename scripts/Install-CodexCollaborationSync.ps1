[CmdletBinding()]
param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'Codex-Collaboration-Config-Sync'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$syncScript = Join-Path $PSScriptRoot 'Sync-CodexCollaborationConfig.ps1'

if ($Uninstall) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    [pscustomobject]@{
        TaskName = $taskName
        Status = 'uninstalled'
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    throw "Sync script does not exist: $syncScript"
}

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)) {
    throw "Git repository is not initialized: $repoRoot"
}

& $syncScript | Out-Host

$shellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $shellCommand) {
    $shellCommand = Get-Command powershell.exe -ErrorAction Stop
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$quote = [char]34
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File {0}{1}{0} -Watch' -f $quote, $syncScript
$action = New-ScheduledTaskAction -Execute $shellCommand.Source -Argument $arguments -WorkingDirectory $repoRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settingsParameters = @{
    AllowStartIfOnBatteries = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable = $true
    MultipleInstances = 'IgnoreNew'
    RestartCount = 3
    RestartInterval = New-TimeSpan -Minutes 1
    ExecutionTimeLimit = New-TimeSpan -Days 3650
}
$settings = New-ScheduledTaskSettingsSet @settingsParameters
$registerParameters = @{
    TaskName = $taskName
    Action = $action
    Trigger = $trigger
    Principal = $principal
    Settings = $settings
    Description = 'Near-real-time private GitHub mirror for Codex collaboration AGENTS.md files.'
    Force = $true
}
Register-ScheduledTask @registerParameters | Out-Null

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $taskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $taskName

[pscustomobject]@{
    TaskName = $taskName
    State = $task.State
    LastRunTime = $taskInfo.LastRunTime
    LastTaskResult = $taskInfo.LastTaskResult
    Executable = $shellCommand.Source
}
