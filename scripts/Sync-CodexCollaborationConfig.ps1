[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$HealthCheck,
    [ValidateRange(2, 3600)]
    [int]$PollSeconds = 5,
    [ValidateRange(1, 3600)]
    [int]$DebounceSeconds = 2,
    [ValidateRange(30, 86400)]
    [int]$RetrySeconds = 300,
    [switch]$NoPull,
    [switch]$NoPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = Split-Path -Parent $script:RepoRoot
$script:RuntimeDirectory = Join-Path $script:RepoRoot '.runtime'
$script:LogPath = Join-Path $script:RuntimeDirectory 'sync.log'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:GitExe = $null

$script:SourceMap = @(
    [pscustomobject]@{
        Name = 'global'
        Source = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
        Destination = Join-Path $script:RepoRoot 'config\global\AGENTS.md'
        GitPath = 'config/global/AGENTS.md'
    },
    [pscustomobject]@{
        Name = 'gpt-use-optimization'
        Source = Join-Path $workspaceRoot 'AGENTS.md'
        Destination = Join-Path $script:RepoRoot 'config\projects\gpt-use-optimization\AGENTS.md'
        GitPath = 'config/projects/gpt-use-optimization/AGENTS.md'
    }
)

function Write-RuntimeLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.IO.Directory]::CreateDirectory($script:RuntimeDirectory) | Out-Null
    $line = '{0} {1}{2}' -f ([DateTimeOffset]::Now.ToString('o')), $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8NoBom)
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int[]]$AcceptedExitCodes = @(0)
    )

    if ($null -eq $script:GitExe) {
        $script:GitExe = (Get-Command git -ErrorAction Stop).Source
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns redirected native stderr into an ErrorRecord.
        # Capture it without allowing an expected non-zero Git probe to terminate.
        $ErrorActionPreference = 'Continue'
        $rawOutput = @(& $script:GitExe -C $script:RepoRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $outputText = [string]::Join([Environment]::NewLine, [string[]]$rawOutput)

    if ($AcceptedExitCodes -notcontains $exitCode) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode. $outputText"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-SourceState {
    $items = foreach ($mapping in $script:SourceMap) {
        if (Test-Path -LiteralPath $mapping.Source -PathType Leaf) {
            '{0}={1}' -f $mapping.Name, (Get-FileSha256 -Path $mapping.Source)
        }
        else {
            '{0}=MISSING' -f $mapping.Name
        }
    }

    return [string]::Join('|', [string[]]$items)
}

function Invoke-HealthCheck {
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($mapping in $script:SourceMap) {
        if (-not (Test-Path -LiteralPath $mapping.Source -PathType Leaf)) {
            $null = $issues.Add("缺少源文件：$($mapping.Name)")
            continue
        }

        if (-not (Test-Path -LiteralPath $mapping.Destination -PathType Leaf)) {
            $null = $issues.Add("缺少镜像文件：$($mapping.Name)")
            continue
        }

        if ((Get-FileSha256 -Path $mapping.Source) -ne (Get-FileSha256 -Path $mapping.Destination)) {
            $null = $issues.Add("源文件与镜像不一致：$($mapping.Name)")
        }
    }

    try {
        $watchMutex = [System.Threading.Mutex]::OpenExisting('Global\CodexCollaborationConfigWatch')
        $watchMutex.Dispose()
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $null = $issues.Add('同步守护进程未运行')
    }
    catch {
        $null = $issues.Add('无法读取同步守护进程状态')
    }

    if ($issues.Count -eq 0) {
        return
    }

    $payload = @{
        hookSpecificOutput = @{
            hookEventName = 'SessionStart'
            additionalContext = 'AGENTS 自动同步健康检查异常：{0}。请先检查计划任务和镜像状态。' -f ([string]::Join('；', $issues))
        }
    }

    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $payload | ConvertTo-Json -Depth 4 -Compress
}

function Copy-ExactFile {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Mapping
    )

    if (-not (Test-Path -LiteralPath $Mapping.Source -PathType Leaf)) {
        throw "Required source file does not exist: $($Mapping.Source)"
    }

    $sourceHash = Get-FileSha256 -Path $Mapping.Source
    if (Test-Path -LiteralPath $Mapping.Destination -PathType Leaf) {
        $destinationHash = Get-FileSha256 -Path $Mapping.Destination
        if ($sourceHash -eq $destinationHash) {
            return $false
        }
    }

    $destinationDirectory = Split-Path -Parent $Mapping.Destination
    [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    $temporaryPath = '{0}.sync-{1}.tmp' -f $Mapping.Destination, $PID
    $backupPath = '{0}.sync-{1}.bak' -f $Mapping.Destination, $PID

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Mapping.Source)
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)

        if (Test-Path -LiteralPath $Mapping.Destination -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Mapping.Destination, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Mapping.Destination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }

    $writtenHash = Get-FileSha256 -Path $Mapping.Destination
    if ($sourceHash -ne $writtenHash) {
        throw "Byte verification failed for $($Mapping.Name)."
    }

    return $true
}

function Invoke-OneShotSync {
    $mutex = [System.Threading.Mutex]::new($false, 'Global\CodexCollaborationConfigSync')
    $lockTaken = $false

    try {
        try {
            $lockTaken = $mutex.WaitOne(30000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            throw 'Another synchronization process is still running.'
        }

        $repoCheck = Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')
        if ($repoCheck.Output.Trim() -ne 'true') {
            throw "Not a Git work tree: $script:RepoRoot"
        }

        $remoteCheck = Invoke-Git -Arguments @('remote', 'get-url', 'origin') -AcceptedExitCodes @(0, 2, 128)
        $hasOrigin = $remoteCheck.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteCheck.Output)

        if ($hasOrigin -and -not $NoPull) {
            Invoke-Git -Arguments @('pull', '--ff-only', 'origin', 'main') | Out-Null
        }

        $copied = @()
        foreach ($mapping in $script:SourceMap) {
            if (Copy-ExactFile -Mapping $mapping) {
                $copied += $mapping.Name
            }
        }

        $gitPaths = [string[]]($script:SourceMap | ForEach-Object { $_.GitPath })
        Invoke-Git -Arguments (@('add', '--') + $gitPaths) | Out-Null
        $diffCheck = Invoke-Git -Arguments (@('diff', '--cached', '--quiet', '--') + $gitPaths) -AcceptedExitCodes @(0, 1)
        $committed = $false

        if ($diffCheck.ExitCode -eq 1) {
            $message = 'sync: update collaboration configuration {0}' -f ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))
            Invoke-Git -Arguments (@('commit', '--only', '-m', $message, '--') + $gitPaths) | Out-Null
            $committed = $true
        }

        $pushed = $false
        if (-not $NoPush) {
            if (-not $hasOrigin) {
                throw 'Remote origin is not configured. Use -NoPush for local-only bootstrap.'
            }

            Invoke-Git -Arguments @('push', 'origin', 'HEAD:main') | Out-Null
            $pushed = $true
        }

        $head = (Invoke-Git -Arguments @('rev-parse', 'HEAD')).Output.Trim()
        if ($pushed) {
            $remoteHeadOutput = (Invoke-Git -Arguments @('ls-remote', '--exit-code', 'origin', 'refs/heads/main')).Output
            $remoteHead = ($remoteHeadOutput -split '\s+')[0]
            if ($head -ne $remoteHead) {
                throw "Remote verification failed. Local HEAD is $head and remote main is $remoteHead."
            }
        }

        $copiedText = [string]::Join(',', [string[]]$copied)
        Write-RuntimeLog -Message "sync_ok copied=$copiedText committed=$committed pushed=$pushed head=$head"

        return [pscustomobject]@{
            Status = 'synced'
            Copied = $copiedText
            Committed = $committed
            Pushed = $pushed
            Head = $head
        }
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($HealthCheck) {
    Invoke-HealthCheck
    exit 0
}

if (-not $Watch) {
    Invoke-OneShotSync
    exit 0
}

$createdNew = $false
$watchMutex = [System.Threading.Mutex]::new($true, 'Global\CodexCollaborationConfigWatch', [ref]$createdNew)
if (-not $createdNew) {
    $watchMutex.Dispose()
    throw 'Another synchronization watcher is already running.'
}

try {
    Write-RuntimeLog -Message "watch_started poll_seconds=$PollSeconds debounce_seconds=$DebounceSeconds retry_seconds=$RetrySeconds"
    $lastSyncedState = $null

    while ($true) {
        $currentState = Get-SourceState
        if ($currentState -eq $lastSyncedState) {
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        Start-Sleep -Seconds $DebounceSeconds
        $stableState = Get-SourceState
        if ($stableState -ne $currentState) {
            continue
        }

        try {
            Invoke-OneShotSync | Out-Null
            $lastSyncedState = $stableState
            Start-Sleep -Seconds $PollSeconds
        }
        catch {
            Write-RuntimeLog -Message "sync_failed message=$($_.Exception.Message)"
            Start-Sleep -Seconds $RetrySeconds
        }
    }
}
finally {
    $watchMutex.ReleaseMutex()
    $watchMutex.Dispose()
}
