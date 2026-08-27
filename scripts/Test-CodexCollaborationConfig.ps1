[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$requiredFiles = @(
    'README.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'config/global/AGENTS.md',
    'config/projects/gpt-use-optimization/AGENTS.md',
    'scripts/Sync-CodexCollaborationConfig.ps1',
    'scripts/Install-CodexCollaborationSync.ps1'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot ($relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file is missing: $relativePath"
    }
}

$diffCheck = @(& git -C $repoRoot diff --check 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed: $([string]::Join([Environment]::NewLine, [string[]]$diffCheck))"
}

$repositoryFiles = @(& git -C $repoRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate repository files.'
}

$sensitivePatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '(?i)(ghp_|github_pat_|xox[baprs]-|sk-[a-zA-Z0-9]{20,})',
    '(?i)(aws_access_key_id|aws_secret_access_key)\s*[=:]',
    '(?i)(password|passwd|secret|token)\s*[=:]\s*[^\s<>{}]{12,}'
)

$selfPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
foreach ($relativePath in $repositoryFiles) {
    $path = Join-Path $repoRoot ($relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetFullPath($path) -eq $selfPath -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }

    try {
        $content = [IO.File]::ReadAllText($path)
    }
    catch {
        continue
    }

    foreach ($pattern in $sensitivePatterns) {
        if ($content -match $pattern) {
            throw "Possible sensitive marker found in repository file: $relativePath"
        }
    }
}

[pscustomobject]@{
    Status = 'passed'
    Repository = $repoRoot
    RequiredFiles = $requiredFiles.Count
    ScannedFiles = $repositoryFiles.Count
}
