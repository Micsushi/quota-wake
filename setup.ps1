<#
.SYNOPSIS
Installs or updates the Quota Wake scheduled task.

.PARAMETER Agents
One or more agents to verify and call: Claude, Codex, or both.

.PARAMETER StartTime
Optional local start time for daily mode. Omit it for continuous five-hour mode.

.EXAMPLE
.\setup.ps1 -Agents Claude

.EXAMPLE
.\setup.ps1 -Agents Codex

.EXAMPLE
.\setup.ps1 -Agents Claude,Codex -StartTime 5
#>
[CmdletBinding()]
param(
    [string[]]$Agents,

    [ValidateRange(1, 168)]
    [int]$IntervalHours = 5,

    [string]$StartTime,

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
Assert-QuotaWakeTaskName -TaskName $TaskName
$selectedAgents = @(Resolve-AgentSelection -Agents $Agents)
$scheduleMode = "Continuous"
$dailyRunTimes = @()
if ($PSBoundParameters.ContainsKey("StartTime")) {
    $scheduleMode = "Daily"
    $parsedStartTime = ConvertTo-QuotaWakeTime -Value $StartTime
    $dailyRunTimes = @(Get-QuotaWakeDailyRunTimes `
        -StartTime $parsedStartTime `
        -IntervalHours $IntervalHours)
}

if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$powershellPath = Resolve-CommandPath "powershell.exe"
$resolvedPaths = @{}
foreach ($agent in $selectedAgents) {
    try {
        if ($agent -eq "Claude") {
            $resolvedPaths[$agent] = Resolve-CommandPath "claude.exe"
        }
        else {
            $resolvedPaths[$agent] = Resolve-CodexCommandPath
        }
    }
    catch {
        throw Get-AgentFailureGuidance `
            -Agent $agent `
            -Problem $_.Exception.Message
    }
}

$runtimeDirectory = Join-Path $InstallRoot "runtime"
$stateDirectory = Join-Path $InstallRoot "state"
$probeDirectory = Join-Path $InstallRoot "probe"
$installedModulePath = Join-Path $runtimeDirectory "QuotaWake.psm1"
$installedWorkerPath = Join-Path $runtimeDirectory "run-quota-wake.ps1"
$installedCodexInstructionsPath = Join-Path `
    $runtimeDirectory `
    "codex-instructions.txt"
$configPath = Join-Path $runtimeDirectory "config.json"
$workerPath = Join-Path $PSScriptRoot "src\run-quota-wake.ps1"
$stagingRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Setup-$([Guid]::NewGuid().ToString('N'))"
$stagingRuntimeDirectory = Join-Path $stagingRoot "runtime"
$stagingStateDirectory = Join-Path $stagingRoot "state"
$stagingProbeDirectory = Join-Path $stagingRoot "probe"
$stagingModulePath = Join-Path $stagingRuntimeDirectory "QuotaWake.psm1"
$stagingWorkerPath = Join-Path $stagingRuntimeDirectory "run-quota-wake.ps1"
$stagingCodexInstructionsPath = Join-Path `
    $stagingRuntimeDirectory `
    "codex-instructions.txt"
$stagingConfigPath = Join-Path $stagingRuntimeDirectory "config.json"
$ownershipMarkerPath = Get-QuotaWakeOwnershipMarkerPath -InstallRoot $InstallRoot
$taskArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath $installedWorkerPath `
    -ConfigPath $configPath
$existingTask = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if (
    $existingTask -and
    -not (Test-QuotaWakeScheduledTaskOwnership `
        -Task $existingTask `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $taskArguments)
) {
    throw "Task '$TaskName' already exists and is not owned by Quota Wake."
}
if (Test-Path -LiteralPath $ownershipMarkerPath -PathType Leaf) {
    if (-not (Test-QuotaWakeInstallOwnership `
        -InstallRoot $InstallRoot `
        -TaskName $TaskName)) {
        throw "Install root '$InstallRoot' has conflicting or invalid ownership."
    }
}
elseif (Test-Path -LiteralPath $InstallRoot) {
    $installRootItems = @(Get-ChildItem -LiteralPath $InstallRoot -Force)
    if ($installRootItems.Count -gt 0 -and -not $existingTask) {
        $legacyFiles = @(
            $installedModulePath,
            $installedWorkerPath,
            $configPath
        )
        if (@($legacyFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -gt 0) {
            throw "Install root '$InstallRoot' contains unrelated data and has no ownership proof."
        }
    }
}
$prompt = (
    "Do not use tools, commands, files, network access, plugins, skills, " +
    "or external context. Perform no action other than replying with exactly: hi"
)
$codexInstructions = (
    "Do not use tools or external context. Reply with exactly: hi"
)
$config = [ordered]@{
    schemaVersion    = 3
    agents           = $selectedAgents
    scheduleMode     = $scheduleMode
    timeoutSeconds   = $TimeoutSeconds
    notificationsEnabled = $false
    workingDirectory = $stagingProbeDirectory
    stateDirectory   = $stagingStateDirectory
}
if ($selectedAgents -contains "Claude") {
    $config["claude"] = [ordered]@{
        path   = $resolvedPaths["Claude"]
        model  = $ClaudeModel
        prompt = $prompt
    }
}
if ($selectedAgents -contains "Codex") {
    $config["codex"] = [ordered]@{
        path             = $resolvedPaths["Codex"]
        model            = $CodexModel
        prompt           = $prompt
        instructionsPath = $stagingCodexInstructionsPath
    }
}

try {
    [void](New-Item -ItemType Directory -Path $stagingRuntimeDirectory -Force)
    [void](New-Item -ItemType Directory -Path $stagingStateDirectory -Force)
    [void](New-Item -ItemType Directory -Path $stagingProbeDirectory -Force)
    Copy-Item -LiteralPath $modulePath -Destination $stagingModulePath -Force
    Copy-Item -LiteralPath $workerPath -Destination $stagingWorkerPath -Force
    if ($selectedAgents -contains "Codex") {
        Write-AtomicUtf8File `
            -Path $stagingCodexInstructionsPath `
            -Content $codexInstructions
    }
    Write-AtomicUtf8File `
        -Path $stagingConfigPath `
        -Content ($config | ConvertTo-Json -Depth 5)

    if (-not $SkipLiveTest) {
        $liveOutput = & $powershellPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $stagingWorkerPath `
            -ConfigPath $stagingConfigPath
        if (
            $LASTEXITCODE -ne 0 -or
            -not (Test-ExactHi -Output ($liveOutput -join "`n"))
        ) {
            $lastResultPath = Join-Path $stagingStateDirectory "last-result.json"
            $lastResult = $null
            if (Test-Path -LiteralPath $lastResultPath) {
                $lastResult = Get-Content `
                    -LiteralPath $lastResultPath `
                    -Raw | ConvertFrom-Json
            }

            $guidance = foreach ($agent in $selectedAgents) {
                $problem = "verification did not complete successfully."
                $resultProperty = $null
                if ($lastResult -and $lastResult.results) {
                    $resultProperty = $lastResult.results.PSObject.Properties[
                        $agent.ToLowerInvariant()
                    ]
                    if ($resultProperty -and -not $resultProperty.Value.success) {
                        $problem = $resultProperty.Value.error
                    }
                }
                if (
                    -not $lastResult -or
                    -not $resultProperty -or
                    -not $resultProperty.Value.success
                ) {
                    Get-AgentFailureGuidance -Agent $agent -Problem $problem
                }
            }
            throw ($guidance -join [Environment]::NewLine)
        }
    }

    [void](New-Item -ItemType Directory -Path $runtimeDirectory -Force)
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    [void](New-Item -ItemType Directory -Path $probeDirectory -Force)
    Copy-Item -LiteralPath $stagingModulePath -Destination $installedModulePath -Force
    Copy-Item -LiteralPath $stagingWorkerPath -Destination $installedWorkerPath -Force
    if ($selectedAgents -contains "Codex") {
        Copy-Item `
            -LiteralPath $stagingCodexInstructionsPath `
            -Destination $installedCodexInstructionsPath `
            -Force
        $config["codex"]["instructionsPath"] = $installedCodexInstructionsPath
    }
    $config["notificationsEnabled"] = $true
    $config["workingDirectory"] = $probeDirectory
    $config["stateDirectory"] = $stateDirectory
    Write-AtomicUtf8File `
        -Path $configPath `
        -Content ($config | ConvertTo-Json -Depth 5)
    Write-AtomicUtf8File `
        -Path $ownershipMarkerPath `
        -Content ([ordered]@{
            product       = "QuotaWake"
            schemaVersion = 1
            installRoot   = $InstallRoot
            taskName      = $TaskName
        } | ConvertTo-Json)
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$triggers = @()
if ($scheduleMode -eq "Daily") {
    foreach ($runTime in $dailyRunTimes) {
        $triggers += New-ScheduledTaskTrigger `
            -Daily `
            -At ((Get-Date).Date.Add($runTime))
    }
}
else {
    $triggers += New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
}

$action = New-ScheduledTaskAction `
    -Execute $powershellPath `
    -Argument $taskArguments
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 30)) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun

$taskBeforeRegister = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if (
    $taskBeforeRegister -and
    -not (Test-QuotaWakeScheduledTaskOwnership `
        -Task $taskBeforeRegister `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $taskArguments)
) {
    throw "Task '$TaskName' changed during setup and is not owned by Quota Wake."
}
$registrationParameters = @{
    TaskPath   = "\"
    TaskName   = $TaskName
    Description = "Starts minimal $($selectedAgents -join ' and ') usage-window calls."
    Action     = $action
    Trigger    = $triggers
    Principal  = $principal
    Settings   = $settings
}
if ($taskBeforeRegister) {
    $registrationParameters["Force"] = $true
}
Register-ScheduledTask @registrationParameters | Out-Null

$taskInfo = Get-ScheduledTaskInfo -TaskPath "\" -TaskName $TaskName
[pscustomobject]@{
    Installed      = $true
    TaskName       = $TaskName
    ScheduleMode   = $scheduleMode
    InstallRoot    = $InstallRoot
    NextRunTime    = $taskInfo.NextRunTime
    IntervalHours  = $IntervalHours
    Agents         = $selectedAgents
    Hidden         = $true
    LiveTestPassed = -not $SkipLiveTest
    Message        = Format-QuotaWakeNextRunMessage `
        -NextRunTime $taskInfo.NextRunTime
}
