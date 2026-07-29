[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),

    [switch]$SuppressNotifications
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
$schemaVersion = 3
$currentSlot = $null
$currentSlotKey = $null
$historyPath = $null
$historyWritable = $true
$preservePreviousResult = $false
$lockStream = $null

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
    $schemaVersion = [int]$config.schemaVersion
    if ($schemaVersion -notin @(3, 4)) {
        throw "Configuration schema version '$($config.schemaVersion)' is unsupported."
    }
    if ([int]$config.timeoutSeconds -le 0) {
        throw "Configuration timeoutSeconds must be positive."
    }

    if ($schemaVersion -eq 4) {
        foreach ($property in @("schedule", "graceSeconds")) {
            if (-not $config.PSObject.Properties[$property]) {
                throw "Configuration is missing '$property'."
            }
        }
        $invocation = Get-QuotaWakeInvocation `
            -Schedule $config.schedule `
            -InvocationTime $startedAt `
            -GraceSeconds ([int]$config.graceSeconds)
        if (-not $invocation.IsLegitimate) {
            exit 0
        }
        $currentSlot = [DateTimeOffset]$invocation.Slot
        $currentSlotKey = [string]$invocation.SlotKey
    }

    $selectedAgents = @(Resolve-AgentSelection -Agents @($config.agents))
    foreach ($agent in $selectedAgents) {
        $propertyName = $agent.ToLowerInvariant()
        if (-not $config.PSObject.Properties[$propertyName]) {
            throw "Configuration is missing '$propertyName'."
        }
    }

    $stateDirectory = [IO.Path]::GetFullPath([string]$config.stateDirectory)
    if ($schemaVersion -eq 4) {
        if (-not (Test-Path -LiteralPath $stateDirectory)) {
            [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
        }
        $historyPath = Join-Path $stateDirectory "run-history.jsonl"
        try {
            $lockStream = [IO.File]::Open(
                (Join-Path $stateDirectory "worker.lock"),
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            exit 0
        }

        $recordedSlotKeys = New-Object `
            "Collections.Generic.HashSet[string]" `
            ([StringComparer]::Ordinal)
        if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $historyPath)) {
                if (-not $line.Trim()) {
                    continue
                }
                try {
                    $record = $line | ConvertFrom-Json
                }
                catch {
                    $historyWritable = $false
                    throw "Run history contains invalid JSON and was not modified."
                }
                if (
                    [int]$record.schemaVersion -eq 4 -and
                    [string]$record.scheduleId -eq [string]$config.schedule.id
                ) {
                    if (
                        [string]$record.recordType -eq "executed" -and
                        $record.slotKey
                    ) {
                        [void]$recordedSlotKeys.Add([string]$record.slotKey)
                    }
                    elseif ([string]$record.recordType -eq "missed") {
                        foreach ($slotText in @($record.scheduledSlots)) {
                            [void]$recordedSlotKeys.Add(
                                (Get-QuotaWakeSlotKey `
                                    -ScheduleId ([string]$config.schedule.id) `
                                    -Slot ([DateTimeOffset]::Parse(
                                        [string]$slotText
                                    )))
                            )
                        }
                    }
                }
            }
        }
        $previousResultPath = Join-Path $stateDirectory "last-result.json"
        if (Test-Path -LiteralPath $previousResultPath -PathType Leaf) {
            try {
                $previousResult = Get-Content `
                    -LiteralPath $previousResultPath `
                    -Raw | ConvertFrom-Json
                if (
                    [int]$previousResult.schemaVersion -eq 4 -and
                    [string]$previousResult.recordType -eq "executed" -and
                    [string]$previousResult.scheduleId -eq
                        [string]$config.schedule.id -and
                    $previousResult.slotKey
                ) {
                    $previousSlotKey = [string]$previousResult.slotKey
                    if (-not $recordedSlotKeys.Contains($previousSlotKey)) {
                        try {
                            [IO.File]::AppendAllText(
                                $historyPath,
                                (
                                    ($previousResult |
                                        ConvertTo-Json -Depth 8 -Compress) +
                                    [Environment]::NewLine
                                ),
                                (New-Object Text.UTF8Encoding($false))
                            )
                        }
                        catch {
                            $historyWritable = $false
                            $preservePreviousResult = $true
                            throw "The prior executed slot could not be recovered into history."
                        }
                        [void]$recordedSlotKeys.Add($previousSlotKey)
                    }
                }
            }
            catch {
            }
        }
        if ($recordedSlotKeys.Contains($currentSlotKey)) {
            $lockStream.Dispose()
            $lockStream = $null
            exit 0
        }

        $priorSlots = @(Get-QuotaWakeExpectedSlots `
            -Schedule $config.schedule `
            -Through $currentSlot.AddTicks(-1))
        $missingSlots = @($priorSlots | Where-Object {
            -not $recordedSlotKeys.Contains(
                (Get-QuotaWakeSlotKey `
                    -ScheduleId ([string]$config.schedule.id) `
                    -Slot $_)
            )
        })
        if ($missingSlots.Count -gt 0) {
            if ($config.PSObject.Properties["evidenceIntervals"]) {
                $evidenceIntervals = @($config.evidenceIntervals)
            }
            else {
                $evidenceIntervals = @(Get-QuotaWakeWindowsEvidenceIntervals `
                    -From ([DateTimeOffset]$missingSlots[0]) `
                    -Through $startedAt)
            }
            $classifiedSlots = @(
                for ($slotIndex = 0; $slotIndex -lt $priorSlots.Count; $slotIndex++) {
                    $slot = [DateTimeOffset]$priorSlots[$slotIndex]
                    $key = Get-QuotaWakeSlotKey `
                        -ScheduleId ([string]$config.schedule.id) `
                        -Slot $slot
                    if (-not $recordedSlotKeys.Contains($key)) {
                        [pscustomobject]@{
                            slot = $slot
                            sequence = $slotIndex
                            reason = Get-QuotaWakeMissReason `
                                -Slot $slot `
                                -EvidenceIntervals $evidenceIntervals
                        }
                    }
                }
            )
            foreach ($group in @(Group-QuotaWakeMissedSlots `
                -ClassifiedSlots $classifiedSlots)) {
                $groupSlots = @($group.Slots)
                $missedRecord = [ordered]@{
                    schemaVersion     = 4
                    recordType        = "missed"
                    scheduleId        = [string]$config.schedule.id
                    scheduledSlots    = @($groupSlots | ForEach-Object {
                        $_.ToString("o")
                    })
                    count             = $groupSlots.Count
                    firstScheduledFor = $groupSlots[0].ToString("o")
                    lastScheduledFor  = $groupSlots[-1].ToString("o")
                    observedAt        = $startedAt.ToString("o")
                    reason            = $group.Reason
                }
                [IO.File]::AppendAllText(
                    $historyPath,
                    (
                        ($missedRecord | ConvertTo-Json -Depth 8 -Compress) +
                        [Environment]::NewLine
                    ),
                    (New-Object Text.UTF8Encoding($false))
                )
            }
        }
    }

    $runDirectory = New-QuotaWakeRunDirectory `
        -BaseDirectory ([string]$config.workingDirectory)
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([int]$config.timeoutSeconds)
    $specifications = @(Get-AgentProcessSpecifications `
        -Agents $selectedAgents `
        -Config $config `
        -WorkingDirectory $runDirectory)
    foreach ($specification in $specifications) {
        try {
            $processPath = Resolve-AgentProcessPath `
                -Agent $specification.Name `
                -ConfiguredPath $specification.FilePath
            $handles += Start-HiddenProcess `
                -Name $specification.Name `
                -FilePath $processPath `
                -ArgumentList $specification.ArgumentList `
                -WorkingDirectory $specification.WorkingDirectory `
                -EnvironmentVariables $specification.EnvironmentVariables `
                -OutputFormat $specification.OutputFormat `
                -Model $specification.Model
        }
        catch {
            $results[$specification.Name] = [pscustomobject]@{
                name = $specification.Name
                success = $false
                exitCode = $null
                error = (
                    "$($specification.Name) failed to start: " +
                    $_.Exception.Message
                )
            }
        }
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
    schemaVersion = $schemaVersion
    agents        = $selectedAgents
    startedAt     = $startedAt.ToString("o")
    finishedAt    = $finishedAt.ToString("o")
    durationMs    = [int][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    success       = $success
    results       = $resultMap
}
if ($schemaVersion -eq 4 -and $currentSlot) {
    $combinedResult["recordType"] = "executed"
    $combinedResult["scheduleId"] = [string]$config.schedule.id
    $combinedResult["slotKey"] = $currentSlotKey
    $combinedResult["scheduledFor"] = $currentSlot.ToString("o")
    $combinedResult["outcome"] = if ($success) { "succeeded" } else { "failed" }
}

$lastResultWriteError = $null
try {
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    }
    $lastResultPath = Join-Path $stateDirectory "last-result.json"
    if (-not $historyPath) {
        $historyPath = Join-Path $stateDirectory "run-history.jsonl"
    }
    try {
        $shouldWriteHistory = (
            $schemaVersion -ne 4 -or
            $null -ne $currentSlot
        )
        if ($shouldWriteHistory) {
            if (-not $historyWritable) {
                throw "Run history contains invalid JSON and was not modified."
            }
            [IO.File]::AppendAllText(
                $historyPath,
                (($combinedResult | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine),
                (New-Object Text.UTF8Encoding($false))
            )
        }
    }
    catch {
        $success = $false
        $combinedResult.success = $false
        if ($combinedResult.Contains("outcome")) {
            $combinedResult.outcome = "failed"
        }
        $combinedResult.results["persistence"] = [pscustomobject]@{
            name = "Persistence"; success = $false; exitCode = $null
            error = "Run history could not be written: $($_.Exception.Message)"
        }
    }
    if (-not $preservePreviousResult) {
        Write-AtomicUtf8File `
            -Path $lastResultPath `
            -Content ($combinedResult | ConvertTo-Json -Depth 6)
    }
}
catch {
    $success = $false
    $combinedResult.success = $false
    if ($combinedResult.Contains("outcome")) {
        $combinedResult.outcome = "failed"
    }
    $lastResultWriteError = $_.Exception.Message
}
finally {
    if ($lockStream) {
        $lockStream.Dispose()
        $lockStream = $null
    }
}

if (-not $success) {
    $failedNames = @($combinedResult.results.Keys | Where-Object {
        -not $combinedResult.results[$_].success
    })
    $notificationsEnabled = -not $SuppressNotifications
    if ($notificationsEnabled -and $config) {
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
