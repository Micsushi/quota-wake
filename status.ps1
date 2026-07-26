[CmdletBinding()]
param(
    [string]$TaskName = "QuotaWake",
    [string]$InstallRoot
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "src\QuotaWake.psm1") -Force -DisableNameChecking
if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$configPath = Join-Path $InstallRoot "runtime\config.json"
$agents = @()
$scheduleMode = $null
if (Test-Path -LiteralPath $configPath) {
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
$lastResultPath = Join-Path $InstallRoot "state\last-result.json"
$lastResult = $null
if (Test-Path -LiteralPath $lastResultPath) {
    $lastResult = Get-Content -LiteralPath $lastResultPath -Raw | ConvertFrom-Json
}

if (-not $task) {
    return [pscustomobject]@{
        Installed   = $false
        TaskName    = $TaskName
        Agents      = $agents
        ScheduleMode = $scheduleMode
        InstallRoot = $InstallRoot
        LastResult  = $lastResult
    }
}

$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Installed      = $true
    TaskName       = $TaskName
    Agents         = $agents
    ScheduleMode   = $scheduleMode
    State          = $task.State
    InstallRoot    = $InstallRoot
    LastRunTime    = $taskInfo.LastRunTime
    LastTaskResult = $taskInfo.LastTaskResult
    NextRunTime    = $taskInfo.NextRunTime
    LastResult     = $lastResult
}
