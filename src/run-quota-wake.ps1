[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "QuotaWake.psm1") -Force -DisableNameChecking

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
foreach ($property in @(
    "schemaVersion",
    "timeoutSeconds",
    "workingDirectory",
    "stateDirectory",
    "claude",
    "codex"
)) {
    if ($null -eq $config.$property) {
        throw "Configuration is missing '$property'."
    }
}

$stateDirectory = [IO.Path]::GetFullPath([string]$config.stateDirectory)
$lastResultPath = Join-Path $stateDirectory "last-result.json"
$historyPath = Join-Path $stateDirectory "run-history.jsonl"
if (-not (Test-Path -LiteralPath $stateDirectory)) {
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
}

$startedAt = [DateTimeOffset]::Now
$deadlineUtc = [DateTime]::UtcNow.AddSeconds([int]$config.timeoutSeconds)
$handles = @()
$results = @{}

try {
    $claudeArguments = @(
        "-p",
        [string]$config.claude.prompt,
        "--model",
        [string]$config.claude.model,
        "--max-turns",
        "1",
        "--no-session-persistence"
    )
    $codexArguments = @(
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--ignore-user-config",
        "--ignore-rules",
        "--color",
        "never",
        "-m",
        [string]$config.codex.model,
        "-s",
        "read-only",
        "-C",
        [string]$config.workingDirectory,
        [string]$config.codex.prompt
    )

    $handles += Start-HiddenProcess `
        -Name "Claude" `
        -FilePath ([string]$config.claude.path) `
        -ArgumentList $claudeArguments `
        -WorkingDirectory ([string]$config.workingDirectory)
    $handles += Start-HiddenProcess `
        -Name "Codex" `
        -FilePath ([string]$config.codex.path) `
        -ArgumentList $codexArguments `
        -WorkingDirectory ([string]$config.workingDirectory)

    foreach ($handle in $handles) {
        $results[$handle.Name] = Complete-HiddenProcess `
            -Handle $handle `
            -DeadlineUtc $deadlineUtc
    }
}
catch {
    $startupError = $_.Exception.Message
    foreach ($handle in $handles) {
        if ($handle.Process -and -not $handle.Process.HasExited) {
            try {
                $handle.Process.Kill()
                $handle.Process.WaitForExit()
            }
            catch {
            }
        }
        try {
            $handle.Process.Dispose()
        }
        catch {
        }
    }

    if (-not $results.ContainsKey("Claude")) {
        $results["Claude"] = [pscustomobject]@{
            name = "Claude"; success = $false; exitCode = $null
            error = "Claude check did not start: $startupError"
        }
    }
    if (-not $results.ContainsKey("Codex")) {
        $results["Codex"] = [pscustomobject]@{
            name = "Codex"; success = $false; exitCode = $null
            error = "Codex check did not start: $startupError"
        }
    }
}

$claudeResult = $results["Claude"]
$codexResult = $results["Codex"]
$success = [bool]($claudeResult.success -and $codexResult.success)
$finishedAt = [DateTimeOffset]::Now
$combinedResult = [ordered]@{
    schemaVersion = 1
    startedAt     = $startedAt.ToString("o")
    finishedAt    = $finishedAt.ToString("o")
    durationMs    = [int][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    success       = $success
    claude        = $claudeResult
    codex         = $codexResult
}
$resultJson = $combinedResult | ConvertTo-Json -Depth 6
Write-AtomicUtf8File -Path $lastResultPath -Content $resultJson
[IO.File]::AppendAllText(
    $historyPath,
    (($combinedResult | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine),
    (New-Object Text.UTF8Encoding($false))
)

if (-not $success) {
    $failedNames = @()
    if (-not $claudeResult.success) { $failedNames += "Claude" }
    if (-not $codexResult.success) { $failedNames += "Codex" }
    Show-QuotaWakeFailureNotification -Message (
        "$($failedNames -join ' and ') check failed. Run status.ps1 for details."
    )
    exit 1
}

Write-Output "hi"
