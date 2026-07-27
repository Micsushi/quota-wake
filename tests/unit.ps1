$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "src\QuotaWake.psm1"
Import-Module $modulePath -Force -DisableNameChecking

Assert-Equal '"C:\Program Files\Quota Wake\worker.ps1"' `
    (Quote-CommandLineArgument 'C:\Program Files\Quota Wake\worker.ps1') `
    "paths with spaces are quoted"
Assert-Equal 'plain' (Quote-CommandLineArgument 'plain') "plain values stay plain"
Assert-Equal '""' (Quote-CommandLineArgument '') "empty values are quoted"

Assert-True (Test-ExactHi "hi") "exact hi succeeds"
Assert-True (Test-ExactHi "  hi`r`n") "surrounding whitespace is ignored"
Assert-True (-not (Test-ExactHi "Hi")) "case changes fail"
Assert-True (-not (Test-ExactHi "hi there")) "extra output fails"

$agents = @(Resolve-AgentSelection @("claude", "Codex", "CLAUDE"))
Assert-Equal 2 $agents.Count "agent selection removes duplicates"
Assert-Equal "Claude" $agents[0] "Claude selection is canonical"
Assert-Equal "Codex" $agents[1] "Codex selection is canonical"

$missingAgentError = $null
try {
    [void](Resolve-AgentSelection @())
}
catch {
    $missingAgentError = $_.Exception.Message
}
Assert-True ($missingAgentError -match "-Agents Claude") `
    "missing selection includes setup examples"

$invalidAgentError = $null
try {
    [void](Resolve-AgentSelection @("Gemini"))
}
catch {
    $invalidAgentError = $_.Exception.Message
}
Assert-True ($invalidAgentError -match "Claude.*Codex") `
    "invalid selection lists supported agents"

$testConfig = [pscustomobject]@{
    workingDirectory = "C:\Quota Wake"
    claude = [pscustomobject]@{
        path = "C:\Tools\claude.exe"
        model = "haiku"
        prompt = "Reply with exactly: hi"
        configDir = "C:\Quota Wake\claude-profile"
    }
}
$specifications = @(Get-AgentProcessSpecifications `
    -Agents @("Claude") `
    -Config $testConfig)
Assert-Equal 1 $specifications.Count "only selected agents get process specifications"
Assert-Equal "Claude" $specifications[0].Name "Claude process specification is selected"
Assert-Equal "ClaudeJson" $specifications[0].OutputFormat `
    "Claude uses structured output"
Assert-True ($specifications[0].ArgumentList -contains "--output-format") `
    "Claude requests JSON output"
Assert-True ($specifications[0].ArgumentList -contains "--disable-slash-commands") `
    "Claude disables slash commands for this probe"
Assert-True ($specifications[0].ArgumentList -contains "--strict-mcp-config") `
    "Claude rejects inherited MCP servers for this probe"
Assert-True ($specifications[0].ArgumentList -contains "--tools=") `
    "Claude disables tools for this probe"
Assert-True ($specifications[0].ArgumentList -contains "--setting-sources=") `
    "Claude ignores setting sources for this probe"
Assert-Equal "C:\Quota Wake\claude-profile" `
    $specifications[0].EnvironmentVariables["CLAUDE_CONFIG_DIR"] `
    "Claude uses the configured isolated credential directory"

$codexConfig = [pscustomobject]@{
    workingDirectory = "C:\Quota Wake"
    codex = [pscustomobject]@{
        path = "C:\Tools\codex.exe"
        model = "gpt-5.4-mini"
        prompt = "Reply with exactly: hi"
        instructionsPath = "C:\Quota Wake\runtime\codex-instructions.txt"
    }
}
$codexSpecifications = @(Get-AgentProcessSpecifications `
    -Agents @("Codex") `
    -Config $codexConfig `
    -WorkingDirectory "C:\Quota Wake\probe\run-test")
Assert-Equal 1 $codexSpecifications.Count "Codex can be selected by itself"
Assert-Equal "Codex" $codexSpecifications[0].Name `
    "Codex process specification is selected"
Assert-Equal "CodexJson" $codexSpecifications[0].OutputFormat `
    "Codex uses structured output"
Assert-True ($codexSpecifications[0].ArgumentList -contains "--json") `
    "Codex requests JSONL output"
Assert-True (
    $codexSpecifications[0].ArgumentList -contains "C:\Quota Wake\probe\run-test"
) "Codex receives the unique per-run working directory"
foreach ($feature in @(
    "shell_tool",
    "plugins",
    "apps",
    "browser_use",
    "browser_use_external",
    "browser_use_full_cdp_access",
    "computer_use",
    "hooks",
    "skill_search",
    "multi_agent",
    "image_generation",
    "tool_suggest",
    "workspace_dependencies"
)) {
    $featureIndex = [Array]::IndexOf(
        [object[]]$codexSpecifications[0].ArgumentList,
        $feature
    )
    Assert-True (
        $featureIndex -gt 0 -and
        $codexSpecifications[0].ArgumentList[$featureIndex - 1] -eq "--disable"
    ) "Codex disables $feature for this probe"
}
Assert-True (
    $codexSpecifications[0].ArgumentList -contains "project_doc_max_bytes=0"
) "Codex disables project instruction loading for this probe"
$instructionOverride = @(
    $codexSpecifications[0].ArgumentList |
        Where-Object { $_ -like "model_instructions_file=*" }
)
Assert-Equal 1 $instructionOverride.Count `
    "Codex receives one base-instruction override"
Assert-True (
    $instructionOverride[0] -match
    [regex]::Escape("C:/Quota Wake/runtime/codex-instructions.txt")
) "Codex receives the configured minimal instruction file"

$guidance = Get-AgentFailureGuidance `
    -Agent "Claude" `
    -Problem "exited with code 1"
Assert-True ($guidance -match "sign in") "failure guidance mentions authentication"
Assert-True ($guidance -match "rerun") "failure guidance explains the next step"

$notificationsDisabled = [pscustomobject]@{ notificationsEnabled = $false }
$notificationsEnabled = [pscustomobject]@{ notificationsEnabled = $true }
$legacyNotificationConfig = [pscustomobject]@{}
Assert-True (-not (Test-FailureNotificationEnabled $notificationsDisabled)) `
    "setup verification can suppress failure notifications"
Assert-True (Test-FailureNotificationEnabled $notificationsEnabled) `
    "installed runs can enable failure notifications"
Assert-True (Test-FailureNotificationEnabled $legacyNotificationConfig) `
    "legacy configurations retain failure notifications"

$expectedTaskArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath "C:\Quota Wake\runtime\run-quota-wake.ps1" `
    -ConfigPath "C:\Quota Wake\runtime\config.json"
Assert-True ($expectedTaskArguments -match '-WindowStyle Hidden') `
    "scheduled task arguments keep the worker hidden"
Assert-True ($expectedTaskArguments -notmatch '-SuppressNotifications') `
    "production task arguments retain failure notifications"
$testTaskArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath "C:\Quota Wake\runtime\run-quota-wake.ps1" `
    -ConfigPath "C:\Quota Wake\runtime\config.json" `
    -SuppressNotifications
Assert-True ($testTaskArguments -match '-SuppressNotifications') `
    "test task arguments suppress failure notifications"
$ownedTask = [pscustomobject]@{
    Actions = @([pscustomobject]@{
        Execute = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        Arguments = $expectedTaskArguments
    })
}
$foreignTask = [pscustomobject]@{
    Actions = @([pscustomobject]@{
        Execute = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        Arguments = "-File C:\Other\worker.ps1"
    })
}
Assert-True (Test-QuotaWakeScheduledTaskOwnership `
    -Task $ownedTask `
    -ExpectedExecute $ownedTask.Actions[0].Execute `
    -ExpectedArguments $expectedTaskArguments) `
    "matching task action is recognized as Quota Wake"
Assert-True (-not (Test-QuotaWakeScheduledTaskOwnership `
    -Task $foreignTask `
    -ExpectedExecute $ownedTask.Actions[0].Execute `
    -ExpectedArguments $expectedTaskArguments)) `
    "a task with the same name but different action is not owned"

$unsafeTaskNameError = $null
try {
    Assert-QuotaWakeTaskName -TaskName "Quota*"
}
catch {
    $unsafeTaskNameError = $_.Exception.Message
}
Assert-True ($unsafeTaskNameError -match "wildcard") `
    "task names reject wildcard characters before ScheduledTasks cmdlets"

$ownershipRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Ownership-$([Guid]::NewGuid().ToString('N'))"
try {
    $ownershipRuntime = Join-Path $ownershipRoot "runtime"
    [void](New-Item -ItemType Directory -Path $ownershipRuntime -Force)
    foreach ($name in @("config.json", "QuotaWake.psm1", "run-quota-wake.ps1")) {
        [IO.File]::WriteAllText((Join-Path $ownershipRuntime $name), "")
    }
    $ownershipMarkerPath = Get-QuotaWakeOwnershipMarkerPath `
        -InstallRoot $ownershipRoot
    [IO.File]::WriteAllText(
        $ownershipMarkerPath,
        ([ordered]@{
            product = "QuotaWake"
            schemaVersion = 1
            installRoot = [IO.Path]::GetFullPath($ownershipRoot)
            taskName = "QuotaWake-Test"
        } | ConvertTo-Json)
    )
    Assert-True (Test-QuotaWakeInstallOwnership `
        -InstallRoot $ownershipRoot `
        -TaskName "QuotaWake-Test") `
        "matching marker and runtime identify an owned install root"
    Assert-True (-not (Test-QuotaWakeInstallOwnership `
        -InstallRoot $ownershipRoot `
        -TaskName "Different-Task")) `
        "one install root cannot be shared by a different task"
    [IO.File]::WriteAllText(
        $ownershipMarkerPath,
        '{"product":"QuotaWake","schemaVersion":"invalid","installRoot":"bad","taskName":"QuotaWake-Test"}'
    )
    Assert-True (-not (Test-QuotaWakeInstallOwnership `
        -InstallRoot $ownershipRoot `
        -TaskName "QuotaWake-Test")) `
        "corrupt ownership proof is rejected without crashing status or uninstall"
}
finally {
    if (Test-Path -LiteralPath $ownershipRoot) {
        Remove-Item -LiteralPath $ownershipRoot -Recurse -Force
    }
}

$probeRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Probe-$([Guid]::NewGuid().ToString('N'))"
try {
    [void](New-Item -ItemType Directory -Path $probeRoot -Force)
    [IO.File]::WriteAllText((Join-Path $probeRoot "old-residue.txt"), "old")
    $runDirectory = New-QuotaWakeRunDirectory -BaseDirectory $probeRoot
    Assert-Equal ([IO.Path]::GetFullPath($probeRoot)) `
        (Split-Path -Parent $runDirectory) `
        "per-run probe directory is created under the configured root"
    Assert-Equal 0 `
        @(Get-ChildItem -LiteralPath $runDirectory -Force).Count `
        "each run starts in an empty directory despite old root residue"
}
finally {
    if (Test-Path -LiteralPath $probeRoot) {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force
    }
}

$fiveAm = ConvertTo-QuotaWakeTime "5"
Assert-Equal ([TimeSpan]::FromHours(5)) $fiveAm "bare hour means local 24-hour time"
Assert-Equal ([TimeSpan]::FromHours(5)) `
    (ConvertTo-QuotaWakeTime "5am") `
    "AM input is accepted"
Assert-Equal ([TimeSpan]::FromMinutes((17 * 60) + 30)) `
    (ConvertTo-QuotaWakeTime "17:30") `
    "24-hour time with minutes is accepted"
Assert-Equal ([TimeSpan]::FromHours(18)) `
    (ConvertTo-QuotaWakeTime "6 PM") `
    "PM input is accepted"

$invalidTimeError = $null
try {
    [void](ConvertTo-QuotaWakeTime "25:00")
}
catch {
    $invalidTimeError = $_.Exception.Message
}
Assert-True ($invalidTimeError -match "5.*17:30") `
    "invalid start time includes accepted examples"

$dailyRunTimes = @(Get-QuotaWakeDailyRunTimes `
    -StartTime $fiveAm `
    -IntervalHours 5)
Assert-Equal 4 $dailyRunTimes.Count "daily mode stops before crossing midnight"
Assert-Equal "05:00,10:00,15:00,20:00" `
    (($dailyRunTimes | ForEach-Object { $_.ToString("hh\:mm") }) -join ",") `
    "daily mode resets at the start time each day"

$nextRunMessage = Format-QuotaWakeNextRunMessage `
    -NextRunTime ([datetime]"2026-07-27T05:00:00") `
    -Now ([datetime]"2026-07-26T20:01:00")
Assert-True ($nextRunMessage -match "tomorrow at 5:00 AM") `
    "setup message describes a next-day run"

$claudeFixture = @'
{
  "result": "hi",
  "total_cost_usd": 0.0012,
  "usage": {
    "input_tokens": 10,
    "cache_creation_input_tokens": 120,
    "cache_read_input_tokens": 80,
    "output_tokens": 4
  },
  "modelUsage": {
    "claude-haiku-test": {
      "inputTokens": 10,
      "outputTokens": 4
    }
  },
  "permission_denials": []
}
'@
$claudeProbe = ConvertFrom-ClaudeProbeOutput -Output $claudeFixture
Assert-Equal "hi" $claudeProbe.text "Claude structured result is extracted"
Assert-Equal "claude-haiku-test" $claudeProbe.model "Claude actual model is recorded"
Assert-Equal 0 $claudeProbe.actionCount "Claude reports no attempted actions"
Assert-Equal 10 $claudeProbe.usage.inputTokens "Claude input tokens are recorded"
Assert-Equal 120 $claudeProbe.usage.cacheCreationInputTokens `
    "Claude cache creation tokens are recorded"
Assert-Equal 80 $claudeProbe.usage.cacheReadInputTokens `
    "Claude cache read tokens are recorded"
Assert-Equal 4 $claudeProbe.usage.outputTokens "Claude output tokens are recorded"
Assert-Equal 214 $claudeProbe.usage.totalTokens "Claude total tokens are normalized"
Assert-Equal 0.0012 $claudeProbe.usage.costUsd "Claude reported cost is recorded"

$minimalClaudeProbe = ConvertFrom-ClaudeProbeOutput -Output @'
{
  "result": "hi",
  "usage": {
    "input_tokens": 10,
    "output_tokens": 4
  },
  "permission_denials": []
}
'@
Assert-Equal 0 $minimalClaudeProbe.usage.cacheCreationInputTokens `
    "missing optional Claude cache-creation tokens default to zero"
Assert-Equal 0 $minimalClaudeProbe.usage.cacheReadInputTokens `
    "missing optional Claude cache-read tokens default to zero"

$codexFixture = @'
{"type":"thread.started","thread_id":"redacted"}
{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}
{"type":"turn.completed","usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":12}}
'@
$codexProbe = ConvertFrom-CodexProbeOutput `
    -Output $codexFixture `
    -Model "gpt-test-mini"
Assert-Equal "hi" $codexProbe.text "Codex structured result is extracted"
Assert-Equal "gpt-test-mini" $codexProbe.model "Codex requested model is recorded"
Assert-Equal 0 $codexProbe.actionCount "Codex reports no attempted actions"
Assert-Equal 140 $codexProbe.usage.inputTokens "Codex input tokens are recorded"
Assert-Equal 40 $codexProbe.usage.cachedInputTokens `
    "Codex cached input tokens are recorded"
Assert-Equal 12 $codexProbe.usage.outputTokens "Codex output tokens are recorded"
Assert-Equal 0 $codexProbe.usage.reasoningOutputTokens `
    "missing optional Codex reasoning tokens default to zero"
Assert-Equal 152 $codexProbe.usage.totalTokens "Codex total tokens are normalized"

$multipleCodexMessagesError = $null
try {
    [void](ConvertFrom-CodexProbeOutput -Model "gpt-test-mini" -Output @'
{"type":"item.completed","item":{"type":"agent_message","text":"unexpected"}}
{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}
'@)
}
catch {
    $multipleCodexMessagesError = $_.Exception.Message
}
Assert-True ($multipleCodexMessagesError -match "exactly one") `
    "multiple Codex messages invalidate an exact-output probe"

$missingUsageError = $null
try {
    [void](ConvertFrom-ClaudeProbeOutput -Output '{"result":"hi"}')
}
catch {
    $missingUsageError = $_.Exception.Message
}
Assert-True ($missingUsageError -match "usage") `
    "missing token usage invalidates a probe"

$claudeActionError = $null
try {
    [void](ConvertFrom-ClaudeProbeOutput -Output @'
{
  "result": "hi",
  "usage": {"input_tokens":1,"output_tokens":1},
  "permission_denials": [{"tool_name":"Read"}]
}
'@)
}
catch {
    $claudeActionError = $_.Exception.Message
}
Assert-True ($claudeActionError -match "action") `
    "Claude permission denials invalidate a no-action probe"

$codexActionError = $null
try {
    [void](ConvertFrom-CodexProbeOutput -Model "gpt-test-mini" -Output @'
{"type":"thread.started","thread_id":"redacted"}
{"type":"item.completed","item":{"type":"command_execution","command":"Get-ChildItem"}}
{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
'@)
}
catch {
    $codexActionError = $_.Exception.Message
}
Assert-True ($codexActionError -match "action") `
    "Codex tool events invalidate a no-action probe"

$powershellPath = Resolve-CommandPath "powershell.exe"
Assert-True ([IO.Path]::IsPathRooted($powershellPath)) "resolved executable is absolute"
Assert-True (Test-Path -LiteralPath $powershellPath) "resolved executable exists"

$sleepProcessInfo = New-Object Diagnostics.ProcessStartInfo
$sleepProcessInfo.FileName = $powershellPath
$sleepProcessInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 30"
$sleepProcessInfo.UseShellExecute = $false
$sleepProcessInfo.CreateNoWindow = $true
$sleepProcess = [Diagnostics.Process]::Start($sleepProcessInfo)
try {
    Stop-QuotaWakeProcessTree -Process $sleepProcess
    Assert-True $sleepProcess.HasExited `
        "bounded probes terminate their process tree"
}
finally {
    if (-not $sleepProcess.HasExited) {
        $sleepProcess.Kill()
        $sleepProcess.WaitForExit()
    }
    $sleepProcess.Dispose()
}

$codexFixtureRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Codex-$([Guid]::NewGuid().ToString('N'))"
$previousCodexCliPath = $env:CODEX_CLI_PATH
try {
    [void](New-Item -ItemType Directory -Path $codexFixtureRoot -Force)
    $expectedCodexPath = Join-Path $codexFixtureRoot "codex.exe"
    [IO.File]::WriteAllText($expectedCodexPath, "")
    $env:CODEX_CLI_PATH = $expectedCodexPath

    $codexPath = Resolve-CodexCommandPath
    Assert-Equal ([IO.Path]::GetFullPath($expectedCodexPath)) `
        $codexPath `
        "Codex path override resolves without requiring a real installation"
}
finally {
    $env:CODEX_CLI_PATH = $previousCodexCliPath
    if (Test-Path -LiteralPath $codexFixtureRoot) {
        Remove-Item -LiteralPath $codexFixtureRoot -Recurse -Force
    }
}

$defaultRoot = Get-DefaultInstallRoot
Assert-True ([IO.Path]::IsPathRooted($defaultRoot)) "default install root is absolute"
Assert-True ($defaultRoot.EndsWith("QuotaWake")) "default install root is product-scoped"

$continuousSchedule = New-QuotaWakeSchedule `
    -Mode Continuous `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-07-27T03:39:27-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -IntervalHours 5
$sameContinuousSchedule = New-QuotaWakeSchedule `
    -Mode Continuous `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-07-27T03:39:27-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -IntervalHours 5
$changedContinuousSchedule = New-QuotaWakeSchedule `
    -Mode Continuous `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-07-27T03:39:27-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -IntervalHours 4
Assert-Equal $continuousSchedule.id $sameContinuousSchedule.id `
    "identical schedules have stable identifiers"
Assert-True ($continuousSchedule.id -ne $changedContinuousSchedule.id) `
    "schedule identifiers change with scheduling inputs"

$continuousSlots = @(Get-QuotaWakeExpectedSlots `
    -Schedule $continuousSchedule `
    -Through ([DateTimeOffset]::Parse("2026-07-28T05:00:00-06:00")))
Assert-Equal 6 $continuousSlots.Count "continuous slots span multiple days"
Assert-Equal "2026-07-28T04:39:27.0000000-06:00" `
    $continuousSlots[-1].ToString("o") `
    "continuous slots retain their local offset"
Assert-Equal (
    "$($continuousSchedule.id)|2026-07-28T10:39:27.0000000Z"
) (Get-QuotaWakeSlotKey -ScheduleId $continuousSchedule.id -Slot $continuousSlots[-1]) `
    "slot keys use schedule identity and UTC"

$continuousDstSchedule = New-QuotaWakeSchedule `
    -Mode Continuous `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-10-31T23:39:27-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -IntervalHours 5
$continuousDstSlots = @(Get-QuotaWakeExpectedSlots `
    -Schedule $continuousDstSchedule `
    -Through ([DateTimeOffset]::Parse("2026-11-01T04:00:00-07:00")))
Assert-Equal "2026-11-01T03:39:27.0000000-07:00" `
    $continuousDstSlots[1].ToString("o") `
    "continuous slots expose the offset effective after daylight saving ends"

$imminentSchedule = New-QuotaWakeSchedule `
    -Mode Continuous `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-07-27T10:00:00-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -IntervalHours 5
$safeNextSlot = Get-QuotaWakeNextExpectedSlot `
    -Schedule $imminentSchedule `
    -NotBefore ([DateTimeOffset]::Parse("2026-07-27T10:00:10-06:00")) `
    -Through ([DateTimeOffset]::Parse("2026-07-27T16:00:00-06:00"))
Assert-Equal "2026-07-27T15:00:00.0000000-06:00" `
    $safeNextSlot.ToString("o") `
    "registration safety lead skips an imminent first slot"

$onTime = Get-QuotaWakeInvocation `
    -Schedule $continuousSchedule `
    -InvocationTime ([DateTimeOffset]::Parse("2026-07-27T08:40:30-06:00")) `
    -GraceSeconds 120
$late = Get-QuotaWakeInvocation `
    -Schedule $continuousSchedule `
    -InvocationTime ([DateTimeOffset]::Parse("2026-07-27T08:41:28-06:00")) `
    -GraceSeconds 120
$early = Get-QuotaWakeInvocation `
    -Schedule $continuousSchedule `
    -InvocationTime ([DateTimeOffset]::Parse("2026-07-27T03:30:00-06:00")) `
    -GraceSeconds 120
Assert-True $onTime.IsLegitimate "launch inside grace is legitimate"
Assert-True (-not $late.IsLegitimate) "launch after grace is rejected"
Assert-True (-not $early.IsLegitimate) "launch before first slot is rejected"

$dailySchedule = New-QuotaWakeSchedule `
    -Mode Daily `
    -EffectiveFrom ([DateTimeOffset]::Parse("2026-10-31T05:00:00-06:00")) `
    -TimeZoneId "Mountain Standard Time" `
    -DailyRunTimes @("01:30", "05:00")
$dailySlots = @(Get-QuotaWakeExpectedSlots `
    -Schedule $dailySchedule `
    -Through ([DateTimeOffset]::Parse("2026-11-02T06:00:00-07:00")))
Assert-Equal 5 $dailySlots.Count "daily slots span the daylight-saving transition"
Assert-Equal "2026-11-01T05:00:00.0000000-07:00" `
    $dailySlots[2].ToString("o") `
    "daily slots use the offset effective on each local date"

$hibernateReason = Get-QuotaWakeMissReason `
    -Slot ([DateTimeOffset]::Parse("2026-07-27T08:39:27-06:00")) `
    -EvidenceIntervals @([pscustomobject]@{
        kind = "system_hibernating"
        unavailableFrom = "2026-07-27T06:49:00-06:00"
        availableAgainAt = "2026-07-27T11:44:00-06:00"
        evidence = @()
    })
Assert-Equal "system_hibernating" $hibernateReason.code `
    "hibernation evidence classifies a contained slot"
Assert-Equal "confirmed" $hibernateReason.confidence `
    "bounded hibernation evidence is confirmed"
$offReason = Get-QuotaWakeMissReason `
    -Slot ([DateTimeOffset]::Parse("2026-07-27T02:00:00-06:00")) `
    -EvidenceIntervals @([pscustomobject]@{
        kind = "system_off"
        unavailableFrom = "2026-07-26T22:00:00-06:00"
        availableAgainAt = "2026-07-27T05:00:00-06:00"
        evidence = @()
    })
Assert-Equal "system_off" $offReason.code `
    "shutdown-to-boot evidence classifies a contained slot"

$availableReason = Get-QuotaWakeMissReason `
    -Slot ([DateTimeOffset]::Parse("2026-07-27T13:39:27-06:00")) `
    -EvidenceIntervals @([pscustomobject]@{
        kind = "available"
        availableFrom = "2026-07-27T11:44:00-06:00"
        availableUntil = "2026-07-27T15:00:00-06:00"
        evidence = @()
    })
Assert-Equal "scheduler_did_not_start" $availableReason.code `
    "explicit availability evidence classifies scheduler failure"
$laterAvailableReason = Get-QuotaWakeMissReason `
    -Slot ([DateTimeOffset]::Parse("2026-07-27T16:39:27-06:00")) `
    -EvidenceIntervals @([pscustomobject]@{
        kind = "available"
        availableFrom = "2026-07-27T15:00:00-06:00"
        availableUntil = "2026-07-27T18:00:00-06:00"
        evidence = @()
    })
$availabilityGroups = @(Group-QuotaWakeMissedSlots -ClassifiedSlots @(
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T13:39:27-06:00")
        sequence = 0
        reason = $availableReason
    },
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T16:39:27-06:00")
        sequence = 1
        reason = $laterAvailableReason
    }
))
Assert-Equal 2 $availabilityGroups.Count `
    "distinct availability evidence intervals produce separate missed groups"
$unknownReason = Get-QuotaWakeMissReason `
    -Slot ([DateTimeOffset]::Parse("2026-07-20T13:39:27-06:00")) `
    -EvidenceIntervals @()
Assert-Equal "unknown" $unknownReason.code `
    "missing evidence does not claim the system was off"

$normalizedEvidence = @(ConvertTo-QuotaWakeEvidenceIntervals `
    -Transitions @(
        [pscustomobject]@{
            kind = "available"
            time = "2026-07-27T05:00:00-06:00"
            evidence = [pscustomobject]@{
                provider = "Microsoft-Windows-Kernel-General"
                eventId = 12
                time = "2026-07-27T05:00:00-06:00"
            }
        },
        [pscustomobject]@{
            kind = "system_hibernating"
            time = "2026-07-27T06:49:00-06:00"
            evidence = [pscustomobject]@{
                provider = "Microsoft-Windows-Kernel-Power"
                eventId = 42
                time = "2026-07-27T06:49:00-06:00"
            }
        },
        [pscustomobject]@{
            kind = "available"
            time = "2026-07-27T11:44:00-06:00"
            evidence = [pscustomobject]@{
                provider = "Microsoft-Windows-Power-Troubleshooter"
                eventId = 1
                time = "2026-07-27T11:44:00-06:00"
            }
        }
    ) `
    -Through ([DateTimeOffset]::Parse("2026-07-27T15:00:00-06:00")))
Assert-Equal 3 $normalizedEvidence.Count `
    "power transitions produce availability and unavailability intervals"
Assert-Equal "system_hibernating" $normalizedEvidence[1].kind `
    "sleep-to-resume becomes a hibernation interval"
Assert-Equal 2 @($normalizedEvidence[1].evidence).Count `
    "bounded unavailable interval retains both event identifiers"

$powerTransitions = @(ConvertFrom-QuotaWakePowerTroubleshooterXml -Xml @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
  <EventData>
    <Data Name="SleepTime">2026-07-27T12:49:49.1659930Z</Data>
    <Data Name="WakeTime">2026-07-27T17:44:43.2828613Z</Data>
    <Data Name="TargetState">5</Data>
  </EventData>
</Event>
'@)
Assert-Equal 2 $powerTransitions.Count `
    "power troubleshooter payload yields sleep and wake transitions"
Assert-Equal "system_hibernating" $powerTransitions[0].kind `
    "embedded sleep time starts the unavailable interval"
Assert-Equal "2026-07-27T17:44:43.2828613+00:00" `
    $powerTransitions[1].time `
    "embedded wake time survives strict-mode XML parsing"

$classifiedMisses = @(
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T03:39:27-06:00")
        sequence = 0
        reason = $hibernateReason
    },
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T08:39:27-06:00")
        sequence = 1
        reason = $hibernateReason
    },
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T13:39:27-06:00")
        sequence = 2
        reason = $availableReason
    },
    [pscustomobject]@{
        slot = [DateTimeOffset]::Parse("2026-07-27T23:39:27-06:00")
        sequence = 4
        reason = $availableReason
    }
)
$missGroups = @(Group-QuotaWakeMissedSlots -ClassifiedSlots $classifiedMisses)
Assert-Equal 3 $missGroups.Count `
    "reason changes and recorded gaps split missed groups"
Assert-Equal 2 @($missGroups[0].Slots).Count `
    "same-cause consecutive misses share one group"

$parseFailures = @()
Get-ChildItem -Path $repoRoot -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        $parseFailures += "$($_.FullName): $($errors -join '; ')"
    }
}
Assert-Equal 0 $parseFailures.Count "all PowerShell files parse"

Write-Output "Unit tests passed."
