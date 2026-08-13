[CmdletBinding()]
param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 本脚本负责安装或移除当前用户的登录时同步任务。
# 它不会直接维护镜像内容；实际同步逻辑由 Sync-CodexCollaborationConfig.ps1 执行。
$taskName = 'Codex-Collaboration-Config-Sync'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$syncScript = Join-Path $PSScriptRoot 'Sync-CodexCollaborationConfig.ps1'

# 卸载模式只停止并删除本脚本创建的同名计划任务，不删除仓库或配置文件。
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

# 安装前先验证同步脚本和 Git 工作区存在，避免注册一个必然失败的任务。
if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    throw "Sync script does not exist: $syncScript"
}

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)) {
    throw "Git repository is not initialized: $repoRoot"
}

# 先执行一次前台同步；只有基础同步链路可用时才继续安装常驻监控任务。
& $syncScript | Out-Host

# 优先使用 PowerShell 7；不可用时回退到 Windows PowerShell。
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

# 计划任务以当前用户、受限权限运行；允许长期常驻并在异常退出后有限次数重启。
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

# 注册后立即启动一次，并读取任务状态用于安装结果回显。
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
