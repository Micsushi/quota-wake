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

$historyPath = Join-Path $InstallRoot "state\run-history.jsonl"
$historyError = $null
$successfulExecutedSlots = 0
$failedExecutedSlots = 0
$missedSlots = 0
$missedGroups = 0
$lastMissedSlot = $null
$lastMissedReason = $null
$lastSuccessfulSlot = $null
$recordedCurrentScheduleKeys = New-Object `
    "Collections.Generic.HashSet[string]" `
    ([StringComparer]::Ordinal)
if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
    try {
        foreach ($line in @(Get-Content -LiteralPath $historyPath)) {
            if (-not $line.Trim()) {
                continue
            }
            $record = $line | ConvertFrom-Json
            $recordSchema = 3
            if ($record.PSObject.Properties["schemaVersion"]) {
                $recordSchema = [int]$record.schemaVersion
            }
            if (
                $recordSchema -eq 4 -and
                [string]$record.recordType -eq "missed"
            ) {
                $slots = @($record.scheduledSlots)
                $missedGroups++
                $missedSlots += $slots.Count
                if ($slots.Count -gt 0) {
                    $candidate = [DateTimeOffset]::Parse(
                        [string]$slots[-1]
                    )
                    if (
                        $null -eq $lastMissedSlot -or
                        $candidate -gt $lastMissedSlot
                    ) {
                        $lastMissedSlot = $candidate
                        $lastMissedReason = [string]$record.reason.code
                    }
                }
                if (
                    $config -and
                    $config.PSObject.Properties["schedule"] -and
                    [string]$record.scheduleId -eq [string]$config.schedule.id
                ) {
                    foreach ($slotText in $slots) {
                        [void]$recordedCurrentScheduleKeys.Add(
                            (Get-QuotaWakeSlotKey `
                                -ScheduleId ([string]$config.schedule.id) `
                                -Slot ([DateTimeOffset]::Parse(
                                    [string]$slotText
                                )))
                        )
                    }
                }
                continue
            }

            $isExecuted = (
                $recordSchema -eq 3 -or
                [string]$record.recordType -eq "executed"
            )
            if (-not $isExecuted) {
                continue
            }
            $recordSucceeded = [bool]$record.success
            if (
                $recordSchema -eq 4 -and
                $record.PSObject.Properties["outcome"]
            ) {
                $recordSucceeded = (
                    [string]$record.outcome -eq "succeeded"
                )
            }
            if ($recordSucceeded) {
                $successfulExecutedSlots++
                if ($record.PSObject.Properties["scheduledFor"]) {
                    $candidate = [DateTimeOffset]::Parse(
                        [string]$record.scheduledFor
                    )
                    if (
                        $null -eq $lastSuccessfulSlot -or
                        $candidate -gt $lastSuccessfulSlot
                    ) {
                        $lastSuccessfulSlot = $candidate
                    }
                }
            }
            else {
                $failedExecutedSlots++
            }
            if (
                $recordSchema -eq 4 -and
                $config -and
                $config.PSObject.Properties["schedule"] -and
                [string]$record.scheduleId -eq [string]$config.schedule.id -and
                $record.slotKey
            ) {
                [void]$recordedCurrentScheduleKeys.Add(
                    [string]$record.slotKey
                )
            }
        }
    }
    catch {
        $historyError = $_.Exception.Message
    }
}

$pendingMissedSlots = $null
$nextScheduledSlot = $null
if (
    $config -and
    [int]$config.schemaVersion -eq 4 -and
    $config.PSObject.Properties["schedule"]
) {
    try {
        $now = [DateTimeOffset]::Now
        $graceSeconds = 120
        if ($config.PSObject.Properties["graceSeconds"]) {
            $graceSeconds = [int]$config.graceSeconds
        }
        $overdueSlots = @(Get-QuotaWakeExpectedSlots `
            -Schedule $config.schedule `
            -Through $now.AddSeconds(-$graceSeconds))
        $pendingMissedSlots = @($overdueSlots | Where-Object {
            -not $recordedCurrentScheduleKeys.Contains(
                (Get-QuotaWakeSlotKey `
                    -ScheduleId ([string]$config.schedule.id) `
                    -Slot $_)
            )
        }).Count

        $lookAhead = if ([string]$config.schedule.mode -eq "Continuous") {
            [TimeSpan]::FromHours([int]$config.schedule.intervalHours + 1)
        }
        else {
            [TimeSpan]::FromDays(2)
        }
        $nextScheduledSlot = @(Get-QuotaWakeExpectedSlots `
            -Schedule $config.schedule `
            -Through $now.Add($lookAhead) |
            Where-Object { $_ -gt $now } |
            Select-Object -First 1)
        if (@($nextScheduledSlot).Count -gt 0) {
            $nextScheduledSlot = [DateTimeOffset]@($nextScheduledSlot)[0]
        }
        else {
            $nextScheduledSlot = $null
        }
    }
    catch {
        if (-not $historyError) {
            $historyError = $_.Exception.Message
        }
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
    HistoryError      = $historyError
    SuccessfulExecutedSlots = $successfulExecutedSlots
    FailedExecutedSlots = $failedExecutedSlots
    MissedSlots       = $missedSlots
    MissedGroups      = $missedGroups
    PendingMissedSlots = $pendingMissedSlots
    LastMissedSlot    = $lastMissedSlot
    LastMissedReason  = $lastMissedReason
    LastSuccessfulSlot = $lastSuccessfulSlot
    NextScheduledSlot = $nextScheduledSlot
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
