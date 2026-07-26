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
    "agents",
    "timeoutSeconds",
    "workingDirectory",
    "stateDirectory"
)) {
    if ($null -eq $config.$property) {
        throw "Configuration is missing '$property'."
    }
}
$selectedAgents = @(Resolve-AgentSelection -Agents @($config.agents))
foreach ($agent in $selectedAgents) {
    $propertyName = $agent.ToLowerInvariant()
    if ($null -eq $config.PSObject.Properties[$propertyName]) {
        throw "Configuration is missing '$propertyName'."
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
    $specifications = @(Get-AgentProcessSpecifications `
        -Agents $selectedAgents `
        -Config $config)
    foreach ($specification in $specifications) {
        $handles += Start-HiddenProcess `
            -Name $specification.Name `
            -FilePath $specification.FilePath `
            -ArgumentList $specification.ArgumentList `
            -WorkingDirectory ([string]$config.workingDirectory)
    }

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

    foreach ($agent in $selectedAgents) {
        if (-not $results.ContainsKey($agent)) {
            $results[$agent] = [pscustomobject]@{
                name = $agent; success = $false; exitCode = $null
                error = "$agent check did not start: $startupError"
            }
        }
    }
}

$resultMap = [ordered]@{}
$success = $true
foreach ($agent in $selectedAgents) {
    $agentResult = $results[$agent]
    $resultMap[$agent.ToLowerInvariant()] = $agentResult
    if (-not $agentResult.success) {
        $success = $false
    }
}
$finishedAt = [DateTimeOffset]::Now
$combinedResult = [ordered]@{
    schemaVersion = 2
    agents        = $selectedAgents
    startedAt     = $startedAt.ToString("o")
    finishedAt    = $finishedAt.ToString("o")
    durationMs    = [int][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    success       = $success
    results       = $resultMap
}
$resultJson = $combinedResult | ConvertTo-Json -Depth 6
Write-AtomicUtf8File -Path $lastResultPath -Content $resultJson
[IO.File]::AppendAllText(
    $historyPath,
    (($combinedResult | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine),
    (New-Object Text.UTF8Encoding($false))
)

if (-not $success) {
    $failedNames = @($selectedAgents | Where-Object {
        -not $results[$_].success
    })
    Show-QuotaWakeFailureNotification -Message (
        "$($failedNames -join ' and ') check failed. Run status.ps1 for details."
    )
    exit 1
}

Write-Output "hi"
