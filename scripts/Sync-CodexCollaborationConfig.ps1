[CmdletBinding()]
param(
    [switch]$Watch,
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

# 本脚本把本机权威 AGENTS.md 按原始字节镜像到当前私有仓库。
# 单次模式完成一次拉取、复制、提交、推送和远端校验；-Watch 模式持续检测源文件变化。
# 设计原则：只处理 SourceMap 中明确列出的文件，遇到分叉、缺失或校验失败时停止，不猜测合并。
$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = Split-Path -Parent $script:RepoRoot
$script:RuntimeDirectory = Join-Path $script:RepoRoot '.runtime'
$script:LogPath = Join-Path $script:RuntimeDirectory 'sync.log'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:GitExe = (Get-Command git -ErrorAction Stop).Source

# 源文件与仓库镜像路径的唯一映射表；新增镜像项时必须先重新评估敏感性和长期保存价值。
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

# 运行日志仅写入被 .gitignore 排除的 .runtime 目录，不作为配置镜像提交。
function Write-RuntimeLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.IO.Directory]::CreateDirectory($script:RuntimeDirectory) | Out-Null
    $line = '{0} {1}{2}' -f ([DateTimeOffset]::Now.ToString('o')), $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8NoBom)
}

# 统一封装 Git 调用：捕获 stdout/stderr，并仅接受调用方明确允许的退出码。
function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int[]]$AcceptedExitCodes = @(0)
    )

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

# 用“逻辑名称=SHA256”组成轻量状态串，监控模式据此判断源文件是否发生变化。
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

# 逐字节复制单个镜像文件，并在写入后再次核对 SHA-256，避免编码/BOM/换行被隐式改写。
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

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Mapping.Source)
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)

        if (Test-Path -LiteralPath $Mapping.Destination -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Mapping.Destination, $null, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Mapping.Destination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    $writtenHash = Get-FileSha256 -Path $Mapping.Destination
    if ($sourceHash -ne $writtenHash) {
        throw "Byte verification failed for $($Mapping.Name)."
    }

    return $true
}

# 执行一次完整同步。命名互斥锁确保同一用户会话内不会并发运行两个同步过程。
function Invoke-OneShotSync {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexCollaborationConfigSync')
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

        # 先验证工作树和远端；若允许拉取，则只接受 fast-forward，避免自动解决分叉。
        $repoCheck = Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')
        if ($repoCheck.Output.Trim() -ne 'true') {
            throw "Not a Git work tree: $script:RepoRoot"
        }

        $remoteCheck = Invoke-Git -Arguments @('remote', 'get-url', 'origin') -AcceptedExitCodes @(0, 2, 128)
        $hasOrigin = $remoteCheck.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteCheck.Output)

        if ($hasOrigin -and -not $NoPull) {
            Invoke-Git -Arguments @('pull', '--ff-only', 'origin', 'main') | Out-Null
        }

        # 只复制并暂存 SourceMap 中的镜像路径，仓库内其他改动不会被夹带提交。
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

        # 推送后对比本地 HEAD 与远端 main，确认远端确实接收到本次提交。
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

# 默认执行一次同步；只有显式传入 -Watch 才进入持续监控循环。
if (-not $Watch) {
    Invoke-OneShotSync
    exit 0
}

Write-RuntimeLog -Message "watch_started poll_seconds=$PollSeconds debounce_seconds=$DebounceSeconds retry_seconds=$RetrySeconds"
$lastSyncedState = $null

# 监控循环采用“变化检测→防抖→一次同步→轮询/失败退避”，不进行高频 Git 操作。
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
