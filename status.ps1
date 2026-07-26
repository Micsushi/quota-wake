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
$lastResultPath = Join-Path $InstallRoot "state\last-result.json"
$lastResult = $null
if (Test-Path -LiteralPath $lastResultPath) {
    $lastResult = Get-Content -LiteralPath $lastResultPath -Raw | ConvertFrom-Json
}

if (-not $task) {
    return [pscustomobject]@{
        Installed   = $false
        TaskName    = $TaskName
        InstallRoot = $InstallRoot
        LastResult  = $lastResult
    }
}

$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Installed      = $true
    TaskName       = $TaskName
    State          = $task.State
    InstallRoot    = $InstallRoot
    LastRunTime    = $taskInfo.LastRunTime
    LastTaskResult = $taskInfo.LastTaskResult
    NextRunTime    = $taskInfo.NextRunTime
    LastResult     = $lastResult
}
