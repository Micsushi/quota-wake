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

    [string]$ClaudeConfigDir,

    [ValidateNotNullOrEmpty()]
    [string]$CodexModel = "gpt-5.4-mini",

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = "QuotaWake",

    [string]$InstallRoot,

    [switch]$SkipLiveTest,

    [Parameter(DontShow = $true)]
    [switch]$AllowTestDemandStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ($env:OS -ne "Windows_NT") {
    throw "Quota Wake currently supports Windows only."
}

$modulePath = Join-Path $PSScriptRoot "src\QuotaWake.psm1"
Import-Module $modulePath -Force -DisableNameChecking
Assert-QuotaWakeTaskName -TaskName $TaskName
if ($AllowTestDemandStart -and $TaskName -notlike "QuotaWake-Test-*") {
    throw "Demand starts may be enabled only for isolated QuotaWake-Test-* tasks."
}
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
if ($ClaudeConfigDir) {
    $ClaudeConfigDir = [IO.Path]::GetFullPath($ClaudeConfigDir)
}

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
$installedLauncherPath = Join-Path $runtimeDirectory "run-hidden.vbs"
$installedCodexInstructionsPath = Join-Path `
    $runtimeDirectory `
    "codex-instructions.txt"
$configPath = Join-Path $runtimeDirectory "config.json"
$workerPath = Join-Path $PSScriptRoot "src\run-quota-wake.ps1"
$launcherPath = Join-Path $PSScriptRoot "src\run-hidden.vbs"
$stagingRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Setup-$([Guid]::NewGuid().ToString('N'))"
$stagingRuntimeDirectory = Join-Path $stagingRoot "runtime"
$stagingStateDirectory = Join-Path $stagingRoot "state"
$stagingProbeDirectory = Join-Path $stagingRoot "probe"
$stagingModulePath = Join-Path $stagingRuntimeDirectory "QuotaWake.psm1"
$stagingWorkerPath = Join-Path $stagingRuntimeDirectory "run-quota-wake.ps1"
$stagingLauncherPath = Join-Path $stagingRuntimeDirectory "run-hidden.vbs"
$stagingCodexInstructionsPath = Join-Path `
    $stagingRuntimeDirectory `
    "codex-instructions.txt"
$stagingConfigPath = Join-Path $stagingRuntimeDirectory "config.json"
$ownershipMarkerPath = Get-QuotaWakeOwnershipMarkerPath -InstallRoot $InstallRoot
$pendingConfigPath = "$configPath.pending-$([Guid]::NewGuid().ToString('N'))"
$configExistedBeforeSetup = Test-Path -LiteralPath $configPath -PathType Leaf
$previousConfigContent = if ($configExistedBeforeSetup) {
    Get-Content -LiteralPath $configPath -Raw
}
else {
    $null
}
$markerExistedBeforeSetup = Test-Path `
    -LiteralPath $ownershipMarkerPath `
    -PathType Leaf
$previousMarkerContent = if ($markerExistedBeforeSetup) {
    Get-Content -LiteralPath $ownershipMarkerPath -Raw
}
else {
    $null
}
$taskArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath $installedWorkerPath `
    -ConfigPath $configPath `
    -SuppressNotifications:($TaskName -like "QuotaWake-Test-*")
$taskAction = Get-QuotaWakeScheduledTaskAction `
    -LauncherPath $installedLauncherPath `
    -PowerShellPath $powershellPath `
    -WorkerArguments $taskArguments
$existingTask = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$existingTaskOwned = $existingTask -and (
    (Test-QuotaWakeScheduledTaskOwnership `
        -Task $existingTask `
        -ExpectedExecute $taskAction.Execute `
        -ExpectedArguments $taskAction.Arguments) -or
    (Test-QuotaWakeScheduledTaskOwnership `
        -Task $existingTask `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $taskArguments)
)
if (
    $existingTask -and
    -not $existingTaskOwned
) {
    throw "Task '$TaskName' already exists and is not owned by Quota Wake."
}
if (Test-Path -LiteralPath $ownershipMarkerPath -PathType Leaf) {
    if (-not (Test-QuotaWakeInstallOwnership `
        -InstallRoot $InstallRoot `
        -TaskName $TaskName `
        -AllowLegacyLauncherMissing)) {
        throw "Install root '$InstallRoot' has conflicting or invalid ownership."
    }
}
elseif (Test-Path -LiteralPath $InstallRoot) {
    $installRootItems = @(Get-ChildItem -LiteralPath $InstallRoot -Force)
    if ($installRootItems.Count -gt 0 -and -not $existingTask) {
        $legacyFiles = @(
            $installedModulePath,
            $installedWorkerPath,
            $installedLauncherPath,
            $configPath
        )
        if (@($legacyFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -gt 0) {
            throw "Install root '$InstallRoot' contains unrelated data and has no ownership proof."
        }
    }
}

$timeZoneId = [TimeZoneInfo]::Local.Id
$localTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId)
$existingConfig = $null
$existingSchedule = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $existingConfig = Get-Content -LiteralPath $configPath -Raw |
            ConvertFrom-Json
        if (
            [int]$existingConfig.schemaVersion -eq 4 -and
            $existingConfig.PSObject.Properties["schedule"]
        ) {
            $candidate = $existingConfig.schedule
            $sameSchedule = (
                [string]$candidate.mode -eq $scheduleMode -and
                [string]$candidate.timeZoneId -eq $timeZoneId
            )
            if ($sameSchedule -and $scheduleMode -eq "Continuous") {
                $sameSchedule = (
                    [int]$candidate.intervalHours -eq $IntervalHours
                )
            }
            elseif ($sameSchedule) {
                $candidateTimes = @($candidate.dailyRunTimes | ForEach-Object {
                    [TimeSpan]::Parse([string]$_).ToString("hh\:mm\:ss")
                })
                $requestedTimes = @($dailyRunTimes | ForEach-Object {
                    $_.ToString("hh\:mm\:ss")
                })
                $sameSchedule = (
                    ($candidateTimes -join ",") -ceq
                    ($requestedTimes -join ",")
                )
            }
            if ($sameSchedule) {
                $existingSchedule = $candidate
            }
        }
    }
    catch {
        $existingSchedule = $null
    }
}

if (
    -not $PSBoundParameters.ContainsKey("ClaudeConfigDir") -and
    $existingConfig -and
    $existingConfig.PSObject.Properties["claude"] -and
    $existingConfig.claude.PSObject.Properties["configDir"] -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$existingConfig.claude.configDir
    )
) {
    $ClaudeConfigDir = [IO.Path]::GetFullPath(
        [string]$existingConfig.claude.configDir
    )
}

if ($existingSchedule) {
    $schedule = $existingSchedule
}
else {
    $now = [DateTimeOffset]::Now
    if ($scheduleMode -eq "Continuous") {
        $nextMinute = $now.LocalDateTime.AddMinutes(2)
        $firstLocalSlot = [DateTime]::new(
            $nextMinute.Year,
            $nextMinute.Month,
            $nextMinute.Day,
            $nextMinute.Hour,
            $nextMinute.Minute,
            0,
            [DateTimeKind]::Unspecified
        )
        $firstSlot = [DateTimeOffset]::new(
            $firstLocalSlot,
            $localTimeZone.GetUtcOffset($firstLocalSlot)
        )
        $schedule = New-QuotaWakeSchedule `
            -Mode Continuous `
            -EffectiveFrom $firstSlot `
            -TimeZoneId $timeZoneId `
            -IntervalHours $IntervalHours
    }
    else {
        $nextDailySlot = $null
        foreach ($runTime in $dailyRunTimes) {
            $candidateLocal = [DateTime]::SpecifyKind(
                $now.Date.Add($runTime),
                [DateTimeKind]::Unspecified
            )
            $candidate = [DateTimeOffset]::new(
                $candidateLocal,
                $localTimeZone.GetUtcOffset($candidateLocal)
            )
            if ($candidate -lt $now) {
                $candidateLocal = $candidateLocal.AddDays(1)
                $candidate = [DateTimeOffset]::new(
                    $candidateLocal,
                    $localTimeZone.GetUtcOffset($candidateLocal)
                )
            }
            if ($null -eq $nextDailySlot -or $candidate -lt $nextDailySlot) {
                $nextDailySlot = $candidate
            }
        }
        $schedule = New-QuotaWakeSchedule `
            -Mode Daily `
            -EffectiveFrom $nextDailySlot `
            -TimeZoneId $timeZoneId `
            -DailyRunTimes @($dailyRunTimes | ForEach-Object {
                $_.ToString("hh\:mm\:ss")
            })
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
    schemaVersion    = 4
    agents           = $selectedAgents
    scheduleMode     = $scheduleMode
    schedule         = $schedule
    graceSeconds     = 120
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
    if ($ClaudeConfigDir) {
        $config["claude"]["configDir"] = $ClaudeConfigDir
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
    Copy-Item -LiteralPath $launcherPath -Destination $stagingLauncherPath -Force
    if ($selectedAgents -contains "Codex") {
        Write-AtomicUtf8File `
            -Path $stagingCodexInstructionsPath `
            -Content $codexInstructions
    }
    $deploymentSchedule = $config["schedule"]
    if (-not $SkipLiveTest) {
        $config["schedule"] = New-QuotaWakeSchedule `
            -Mode Continuous `
            -EffectiveFrom ([DateTimeOffset]::Now.AddSeconds(-1)) `
            -TimeZoneId $timeZoneId `
            -IntervalHours 1
    }
    Write-AtomicUtf8File `
        -Path $stagingConfigPath `
        -Content ($config | ConvertTo-Json -Depth 8)
    if (-not $SkipLiveTest) {
        $liveOutput = & $powershellPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $stagingWorkerPath `
            -ConfigPath $stagingConfigPath `
            -SuppressNotifications
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
        $config["schedule"] = $deploymentSchedule
    }

    [void](New-Item -ItemType Directory -Path $runtimeDirectory -Force)
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    [void](New-Item -ItemType Directory -Path $probeDirectory -Force)
    Copy-Item -LiteralPath $stagingModulePath -Destination $installedModulePath -Force
    Copy-Item -LiteralPath $stagingWorkerPath -Destination $installedWorkerPath -Force
    Copy-Item -LiteralPath $stagingLauncherPath -Destination $installedLauncherPath -Force
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
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$triggers = @()
$registrationSafetySeconds = 30
$nowForTrigger = [DateTimeOffset]::Now
if ($existingSchedule) {
    $imminentExistingSlot = Get-QuotaWakeNextExpectedSlot `
        -Schedule $schedule `
        -NotBefore $nowForTrigger `
        -Through $nowForTrigger.AddSeconds($registrationSafetySeconds)
    if ($null -ne $imminentExistingSlot) {
        $existingSchedule = $null
    }
}
if ($scheduleMode -eq "Daily") {
    $nextDailySlot = Get-QuotaWakeNextExpectedSlot `
        -Schedule $schedule `
        -NotBefore $nowForTrigger.AddSeconds($registrationSafetySeconds) `
        -Through $nowForTrigger.AddDays(2)
    if ($null -eq $nextDailySlot) {
        throw "The next daily schedule slot could not be determined."
    }
    foreach ($runTime in $dailyRunTimes) {
        $triggers += New-ScheduledTaskTrigger `
            -Daily `
            -At ($nowForTrigger.LocalDateTime.Date.Add($runTime))
    }
    if (-not $existingSchedule) {
        $schedule = New-QuotaWakeSchedule `
            -Mode Daily `
            -EffectiveFrom $nextDailySlot `
            -TimeZoneId $timeZoneId `
            -DailyRunTimes @($dailyRunTimes | ForEach-Object {
                $_.ToString("hh\:mm\:ss")
            })
        $config["schedule"] = $schedule
    }
}
else {
    $nextContinuousSlot = Get-QuotaWakeNextExpectedSlot `
        -Schedule $schedule `
        -NotBefore $nowForTrigger.AddSeconds($registrationSafetySeconds) `
        -Through $nowForTrigger.AddHours(($IntervalHours * 2) + 1)
    if ($null -eq $nextContinuousSlot) {
        throw "The next continuous schedule slot could not be determined."
    }
    if (-not $existingSchedule) {
        $schedule = New-QuotaWakeSchedule `
            -Mode Continuous `
            -EffectiveFrom ([DateTimeOffset]$nextContinuousSlot) `
            -TimeZoneId $timeZoneId `
            -IntervalHours $IntervalHours
        $config["schedule"] = $schedule
    }
    $triggers += New-ScheduledTaskTrigger `
        -Once `
        -At ([DateTimeOffset]$nextContinuousSlot).LocalDateTime `
        -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
}

$action = New-ScheduledTaskAction `
    -Execute $taskAction.Execute `
    -Argument $taskAction.Arguments
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
$settings.StartWhenAvailable = $false
$settings.AllowDemandStart = [bool]$AllowTestDemandStart

$taskBeforeRegister = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$taskBeforeRegisterOwned = $taskBeforeRegister -and (
    (Test-QuotaWakeScheduledTaskOwnership `
        -Task $taskBeforeRegister `
        -ExpectedExecute $taskAction.Execute `
        -ExpectedArguments $taskAction.Arguments) -or
    (Test-QuotaWakeScheduledTaskOwnership `
        -Task $taskBeforeRegister `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $taskArguments)
)
if (
    $taskBeforeRegister -and
    -not $taskBeforeRegisterOwned
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
$taskBeforeRegisterXml = if ($taskBeforeRegister) {
    Export-ScheduledTask -TaskPath "\" -TaskName $TaskName
}
else {
    $null
}
$ownershipMarkerContent = [ordered]@{
    product       = "QuotaWake"
    schemaVersion = 1
    installRoot   = $InstallRoot
    taskName      = $TaskName
} | ConvertTo-Json
try {
    Write-AtomicUtf8File `
        -Path $pendingConfigPath `
        -Content ($config | ConvertTo-Json -Depth 8)
    Register-ScheduledTask @registrationParameters | Out-Null
    Move-Item `
        -LiteralPath $pendingConfigPath `
        -Destination $configPath `
        -Force
    Write-AtomicUtf8File `
        -Path $ownershipMarkerPath `
        -Content $ownershipMarkerContent
}
catch {
    $setupFailure = $_
    $rollbackErrors = New-Object Collections.Generic.List[string]
    try {
        if ($configExistedBeforeSetup) {
            Write-AtomicUtf8File `
                -Path $configPath `
                -Content $previousConfigContent
        }
        elseif (Test-Path -LiteralPath $configPath -PathType Leaf) {
            Remove-Item -LiteralPath $configPath -Force
        }
    }
    catch {
        $rollbackErrors.Add("configuration: $($_.Exception.Message)")
    }
    try {
        if ($markerExistedBeforeSetup) {
            Write-AtomicUtf8File `
                -Path $ownershipMarkerPath `
                -Content $previousMarkerContent
        }
        elseif (Test-Path -LiteralPath $ownershipMarkerPath -PathType Leaf) {
            Remove-Item -LiteralPath $ownershipMarkerPath -Force
        }
    }
    catch {
        $rollbackErrors.Add("ownership marker: $($_.Exception.Message)")
    }
    try {
        if ($taskBeforeRegisterXml) {
            Register-ScheduledTask `
                -TaskPath "\" `
                -TaskName $TaskName `
                -Xml $taskBeforeRegisterXml `
                -Force | Out-Null
        }
        else {
            $partialTask = Get-ScheduledTask `
                -TaskPath "\" `
                -TaskName $TaskName `
                -ErrorAction SilentlyContinue
            if (
                $partialTask -and
                (Test-QuotaWakeScheduledTaskOwnership `
                    -Task $partialTask `
                    -ExpectedExecute $taskAction.Execute `
                    -ExpectedArguments $taskAction.Arguments)
            ) {
                Unregister-ScheduledTask `
                    -TaskPath "\" `
                    -TaskName $TaskName `
                    -Confirm:$false
            }
        }
    }
    catch {
        $rollbackErrors.Add("scheduled task: $($_.Exception.Message)")
    }
    if ($rollbackErrors.Count -gt 0) {
        throw (
            "$($setupFailure.Exception.Message) Rollback also failed for " +
            "$($rollbackErrors -join '; ')."
        )
    }
    throw $setupFailure
}
finally {
    if (Test-Path -LiteralPath $pendingConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $pendingConfigPath -Force
    }
}

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
