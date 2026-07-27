[CmdletBinding()]
param(
    [string]$TaskName = "QuotaWake",
    [string]$InstallRoot
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "src\QuotaWake.psm1") -Force -DisableNameChecking
Assert-QuotaWakeTaskName -TaskName $TaskName
if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$runtimeDirectory = Join-Path $InstallRoot "runtime"
$configPath = Join-Path $runtimeDirectory "config.json"
$workerPath = Join-Path $runtimeDirectory "run-quota-wake.ps1"
$powershellPath = Resolve-CommandPath "powershell.exe"
$expectedArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath $workerPath `
    -ConfigPath $configPath
$task = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$taskOwned = $false
if ($task) {
    $taskOwned = Test-QuotaWakeScheduledTaskOwnership `
        -Task $task `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $expectedArguments
}

$agents = @()
$scheduleMode = $null
$configError = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($config.scheduleMode) {
            $scheduleMode = $config.scheduleMode
        }
        else {
            $scheduleMode = "Continuous"
        }
        if ($config.agents) {
            $agents = @($config.agents)
        }
        else {
            if ($config.PSObject.Properties["claude"]) { $agents += "Claude" }
            if ($config.PSObject.Properties["codex"]) { $agents += "Codex" }
        }
    }
    catch {
        $configError = $_.Exception.Message
    }
}

$lastResultPath = Join-Path $InstallRoot "state\last-result.json"
$lastResult = $null
$lastResultError = $null
$claudeUsage = $null
$codexUsage = $null
$claudeModel = $null
$codexModel = $null
$claudeActionCount = $null
$codexActionCount = $null
if (Test-Path -LiteralPath $lastResultPath) {
    try {
        $lastResult = Get-Content `
            -LiteralPath $lastResultPath `
            -Raw | ConvertFrom-Json
        if ($lastResult.results) {
            if ($lastResult.results.PSObject.Properties["claude"]) {
                $claudeUsage = $lastResult.results.claude.usage
                $claudeModel = $lastResult.results.claude.model
                $claudeActionCount = $lastResult.results.claude.actionCount
            }
            if ($lastResult.results.PSObject.Properties["codex"]) {
                $codexUsage = $lastResult.results.codex.usage
                $codexModel = $lastResult.results.codex.model
                $codexActionCount = $lastResult.results.codex.actionCount
            }
        }
    }
    catch {
        $lastResultError = $_.Exception.Message
    }
}

$status = [ordered]@{
    Installed         = [bool]($task -and $taskOwned)
    OwnershipConflict = [bool]($task -and -not $taskOwned)
    InstallOwned      = Test-QuotaWakeInstallOwnership `
        -InstallRoot $InstallRoot `
        -TaskName $TaskName
    TaskName          = $TaskName
    Agents            = $agents
    ScheduleMode      = $scheduleMode
    InstallRoot       = $InstallRoot
    ConfigError       = $configError
    LastResult        = $lastResult
    LastResultError   = $lastResultError
    ClaudeModel       = $claudeModel
    ClaudeUsage       = $claudeUsage
    ClaudeActionCount = $claudeActionCount
    CodexModel        = $codexModel
    CodexUsage        = $codexUsage
    CodexActionCount  = $codexActionCount
}
if ($task -and $taskOwned) {
    $taskInfo = Get-ScheduledTaskInfo `
        -TaskPath "\" `
        -TaskName $TaskName
    $status["State"] = $task.State
    $status["LastRunTime"] = $taskInfo.LastRunTime
    $status["LastTaskResult"] = $taskInfo.LastTaskResult
    $status["NextRunTime"] = $taskInfo.NextRunTime
}

[pscustomobject]$status
