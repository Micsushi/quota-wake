[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "QuotaWake.psm1") -Force -DisableNameChecking

$configPath = [IO.Path]::GetFullPath($ConfigPath)
$runtimeDirectory = Split-Path -Parent $configPath
$installRoot = Split-Path -Parent $runtimeDirectory
$stateDirectory = Join-Path $installRoot "state"
$config = $null
$selectedAgents = @()
$handles = @()
$results = @{}
$runDirectory = $null
$cleanupError = $null
$startedAt = [DateTimeOffset]::Now

try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    foreach ($property in @(
        "schemaVersion",
        "agents",
        "timeoutSeconds",
        "workingDirectory",
        "stateDirectory"
    )) {
        if (-not $config.PSObject.Properties[$property]) {
            throw "Configuration is missing '$property'."
        }
    }
    if ([int]$config.schemaVersion -ne 3) {
        throw "Configuration schema version '$($config.schemaVersion)' is unsupported."
    }
    if ([int]$config.timeoutSeconds -le 0) {
        throw "Configuration timeoutSeconds must be positive."
    }

    $selectedAgents = @(Resolve-AgentSelection -Agents @($config.agents))
    foreach ($agent in $selectedAgents) {
        $propertyName = $agent.ToLowerInvariant()
        if (-not $config.PSObject.Properties[$propertyName]) {
            throw "Configuration is missing '$propertyName'."
        }
    }

    $stateDirectory = [IO.Path]::GetFullPath([string]$config.stateDirectory)
    $runDirectory = New-QuotaWakeRunDirectory `
        -BaseDirectory ([string]$config.workingDirectory)
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([int]$config.timeoutSeconds)
    $specifications = @(Get-AgentProcessSpecifications `
        -Agents $selectedAgents `
        -Config $config `
        -WorkingDirectory $runDirectory)
    foreach ($specification in $specifications) {
        $handles += Start-HiddenProcess `
            -Name $specification.Name `
            -FilePath $specification.FilePath `
            -ArgumentList $specification.ArgumentList `
            -WorkingDirectory $specification.WorkingDirectory `
            -OutputFormat $specification.OutputFormat `
            -Model $specification.Model
    }

    foreach ($handle in $handles) {
        $results[$handle.Name] = Complete-HiddenProcess `
            -Handle $handle `
            -DeadlineUtc $deadlineUtc
    }
}
catch {
    $startupError = "Worker configuration or startup failed: $($_.Exception.Message)"
    foreach ($handle in $handles) {
        try {
            if ($handle.Process -and -not $handle.Process.HasExited) {
                Stop-QuotaWakeProcessTree -Process $handle.Process
            }
        }
        catch {
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
                error = $startupError
            }
        }
    }
    if ($selectedAgents.Count -eq 0) {
        $results["Worker"] = [pscustomobject]@{
            name = "Worker"; success = $false; exitCode = $null
            error = $startupError
        }
    }
}
finally {
    if ($runDirectory -and (Test-Path -LiteralPath $runDirectory)) {
        try {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
        }
        catch {
            $cleanupError = $_.Exception.Message
        }
    }
}

$resultMap = [ordered]@{}
$success = $true
if ($selectedAgents.Count -gt 0) {
    foreach ($agent in $selectedAgents) {
        $agentResult = $results[$agent]
        $resultMap[$agent.ToLowerInvariant()] = $agentResult
        if (-not $agentResult.success) {
            $success = $false
        }
    }
}
else {
    $resultMap["worker"] = $results["Worker"]
    $success = $false
}
if ($cleanupError) {
    $resultMap["cleanup"] = [pscustomobject]@{
        name = "Cleanup"; success = $false; exitCode = $null
        error = "Run directory could not be removed: $cleanupError"
    }
    $success = $false
}

$finishedAt = [DateTimeOffset]::Now
$combinedResult = [ordered]@{
    schemaVersion = 3
    agents        = $selectedAgents
    startedAt     = $startedAt.ToString("o")
    finishedAt    = $finishedAt.ToString("o")
    durationMs    = [int][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    success       = $success
    results       = $resultMap
}

$lastResultWriteError = $null
try {
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    }
    $lastResultPath = Join-Path $stateDirectory "last-result.json"
    $historyPath = Join-Path $stateDirectory "run-history.jsonl"
    try {
        [IO.File]::AppendAllText(
            $historyPath,
            (($combinedResult | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine),
            (New-Object Text.UTF8Encoding($false))
        )
    }
    catch {
        $success = $false
        $combinedResult.success = $false
        $combinedResult.results["persistence"] = [pscustomobject]@{
            name = "Persistence"; success = $false; exitCode = $null
            error = "Run history could not be written: $($_.Exception.Message)"
        }
    }
    Write-AtomicUtf8File `
        -Path $lastResultPath `
        -Content ($combinedResult | ConvertTo-Json -Depth 6)
}
catch {
    $success = $false
    $combinedResult.success = $false
    $lastResultWriteError = $_.Exception.Message
}

if (-not $success) {
    $failedNames = @($combinedResult.results.Keys | Where-Object {
        -not $combinedResult.results[$_].success
    })
    $notificationsEnabled = $true
    if ($config) {
        $notificationsEnabled = Test-FailureNotificationEnabled -Config $config
    }
    if ($notificationsEnabled) {
        $message = "$($failedNames -join ' and ') check failed. Run status.ps1 for details."
        if ($lastResultWriteError) {
            $message = "Quota Wake failed and could not write status: $lastResultWriteError"
        }
        Show-QuotaWakeFailureNotification -Message $message
    }
    exit 1
}

Write-Output "hi"
