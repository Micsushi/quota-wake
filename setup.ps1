[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$IntervalHours = 5,

    [ValidateRange(0, 1440)]
    [int]$StartDelayMinutes = 1,

    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 90,

    [ValidateNotNullOrEmpty()]
    [string]$ClaudeModel = "haiku",

    [ValidateNotNullOrEmpty()]
    [string]$CodexModel = "gpt-5.4-mini",

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = "QuotaWake",

    [string]$InstallRoot,

    [switch]$SkipLiveTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ($env:OS -ne "Windows_NT") {
    throw "Quota Wake currently supports Windows only."
}

$modulePath = Join-Path $PSScriptRoot "src\QuotaWake.psm1"
Import-Module $modulePath -Force -DisableNameChecking

if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$claudePath = Resolve-CommandPath "claude.exe"
$codexPath = Resolve-CodexCommandPath
$powershellPath = Resolve-CommandPath "powershell.exe"

$runtimeDirectory = Join-Path $InstallRoot "runtime"
$stateDirectory = Join-Path $InstallRoot "state"
$installedModulePath = Join-Path $runtimeDirectory "QuotaWake.psm1"
$installedWorkerPath = Join-Path $runtimeDirectory "run-quota-wake.ps1"
$configPath = Join-Path $runtimeDirectory "config.json"

[void](New-Item -ItemType Directory -Path $runtimeDirectory -Force)
[void](New-Item -ItemType Directory -Path $stateDirectory -Force)
Copy-Item -LiteralPath $modulePath -Destination $installedModulePath -Force
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "src\run-quota-wake.ps1") `
    -Destination $installedWorkerPath `
    -Force

$prompt = "Reply with exactly: hi"
$config = [ordered]@{
    schemaVersion    = 1
    taskName         = $TaskName
    intervalHours    = $IntervalHours
    timeoutSeconds   = $TimeoutSeconds
    workingDirectory = $InstallRoot
    stateDirectory   = $stateDirectory
    claude            = [ordered]@{
        path   = $claudePath
        model  = $ClaudeModel
        prompt = $prompt
    }
    codex             = [ordered]@{
        path   = $codexPath
        model  = $CodexModel
        prompt = $prompt
    }
}
Write-AtomicUtf8File `
    -Path $configPath `
    -Content ($config | ConvertTo-Json -Depth 5)

if (-not $SkipLiveTest) {
    $liveOutput = & $powershellPath `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $installedWorkerPath `
        -ConfigPath $configPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-ExactHi -Output ($liveOutput -join "`n"))) {
        throw "Live Claude/Codex verification failed. Run status.ps1 for details."
    }
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$startAt = (Get-Date).AddMinutes($StartDelayMinutes)
if ($existingTask) {
    $existingInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    if ($existingInfo.NextRunTime -gt (Get-Date)) {
        $startAt = $existingInfo.NextRunTime
    }
}

$taskArguments = @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle",
    "Hidden",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $installedWorkerPath,
    "-ConfigPath",
    $configPath
)
$action = New-ScheduledTaskAction `
    -Execute $powershellPath `
    -Argument (Join-CommandLineArguments -ArgumentList $taskArguments)
$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startAt `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 30)) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description "Starts minimal Claude Code and Codex usage-window calls." `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Installed      = $true
    TaskName       = $TaskName
    InstallRoot    = $InstallRoot
    NextRunTime    = $taskInfo.NextRunTime
    IntervalHours  = $IntervalHours
    Hidden         = $true
    LiveTestPassed = -not $SkipLiveTest
}
