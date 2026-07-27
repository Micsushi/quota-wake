$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-Worker {
    param([string]$WorkerPath, [string]$ConfigPath)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $WorkerPath `
        -ConfigPath $ConfigPath `
        -SuppressNotifications 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

function New-TestConfig {
    param(
        [string]$Root,
        [string]$AgentPath,
        [DateTimeOffset]$EffectiveFrom
    )

    $runtime = Join-Path $Root "runtime"
    $state = Join-Path $Root "state"
    $probe = Join-Path $Root "probe"
    [void](New-Item -ItemType Directory -Path $runtime, $state, $probe -Force)
    $schedule = New-QuotaWakeSchedule `
        -Mode Continuous `
        -EffectiveFrom $EffectiveFrom `
        -TimeZoneId ([TimeZoneInfo]::Local.Id) `
        -IntervalHours 5
    $config = [ordered]@{
        schemaVersion = 4
        agents = @("Claude")
        scheduleMode = "Continuous"
        schedule = $schedule
        graceSeconds = 120
        timeoutSeconds = 20
        notificationsEnabled = $false
        workingDirectory = $probe
        stateDirectory = $state
        evidenceIntervals = @()
        claude = [ordered]@{
            path = $AgentPath
            model = "test-model"
            prompt = "Reply with exactly: hi"
        }
    }
    $configPath = Join-Path $runtime "config.json"
    [IO.File]::WriteAllText(
        $configPath,
        ($config | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false))
    )
    return [pscustomobject]@{
        ConfigPath = $configPath
        StateDirectory = $state
        Schedule = $schedule
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "src\QuotaWake.psm1"
$workerPath = Join-Path $repoRoot "src\run-quota-wake.ps1"
Import-Module $modulePath -Force -DisableNameChecking
$testRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Scheduling-$([Guid]::NewGuid().ToString('N'))"

try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)
    $agentPath = Join-Path $testRoot "fake-agent.exe"
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class Probe {
    public static int Main() {
        string marker = Environment.GetEnvironmentVariable("QUOTAWAKE_TEST_MARKER");
        if (!String.IsNullOrEmpty(marker)) {
            File.AppendAllText(marker, "run" + Environment.NewLine);
        }
        int delay;
        if (Int32.TryParse(
            Environment.GetEnvironmentVariable("QUOTAWAKE_TEST_SLEEP_MS"),
            out delay
        )) {
            System.Threading.Thread.Sleep(delay);
        }
        Console.WriteLine("{\"result\":\"hi\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"permission_denials\":[]}");
        return 0;
    }
}
'@ -Language CSharp -OutputAssembly $agentPath -OutputType ConsoleApplication

    $lateRoot = Join-Path $testRoot "late"
    $lateMarker = Join-Path $lateRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $lateMarker
    $lateConfig = New-TestConfig `
        -Root $lateRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddHours(-8))
    $lateResult = Invoke-Worker -WorkerPath $workerPath -ConfigPath $lateConfig.ConfigPath
    Assert-True ($lateResult.ExitCode -eq 0) `
        "late invocation exits successfully"
    Assert-True (-not (Test-Path -LiteralPath $lateMarker)) `
        "late invocation does not start an agent"
    Assert-True (-not (Test-Path `
        -LiteralPath (Join-Path $lateConfig.StateDirectory "run-history.jsonl"))) `
        "late invocation does not write history"

    $onTimeRoot = Join-Path $testRoot "on-time"
    $onTimeMarker = Join-Path $onTimeRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $onTimeMarker
    $onTimeConfig = New-TestConfig `
        -Root $onTimeRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddSeconds(-10))
    $onTimeResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $onTimeConfig.ConfigPath
    Assert-True ($onTimeResult.ExitCode -eq 0) "on-time invocation succeeds"
    Assert-True ($onTimeResult.Output.Trim() -ceq "hi") `
        "on-time invocation returns exact hi"
    $onTimeHistory = @(Get-Content `
        -LiteralPath (Join-Path $onTimeConfig.StateDirectory "run-history.jsonl") |
        ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($onTimeHistory.Count -eq 1) `
        "on-time invocation writes one history record"
    Assert-True ($onTimeHistory[0].recordType -eq "executed") `
        "current slot is recorded as executed"
    Assert-True ($onTimeHistory[0].outcome -eq "succeeded") `
        "successful probe records a successful outcome"
    Assert-True ([bool]$onTimeHistory[0].slotKey) `
        "executed history includes a stable slot key"

    $failureRoot = Join-Path $testRoot "on-time-failure"
    $failureConfig = New-TestConfig `
        -Root $failureRoot `
        -AgentPath (Join-Path $failureRoot "missing-agent.exe") `
        -EffectiveFrom ([DateTimeOffset]::Now.AddSeconds(-10))
    $failureResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $failureConfig.ConfigPath
    Assert-True ($failureResult.ExitCode -ne 0) `
        "on-time agent startup failure exits nonzero"
    $failureHistory = @(Get-Content `
        -LiteralPath (Join-Path $failureConfig.StateDirectory "run-history.jsonl") |
        ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($failureHistory.Count -eq 1) `
        "on-time failure writes one executed record"
    Assert-True ($failureHistory[0].recordType -eq "executed") `
        "an attempted current slot is not classified as missed"
    Assert-True ($failureHistory[0].outcome -eq "failed") `
        "on-time agent failure records failed outcome"

    $corruptRoot = Join-Path $testRoot "corrupt-history"
    $corruptMarker = Join-Path $corruptRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $corruptMarker
    $corruptConfig = New-TestConfig `
        -Root $corruptRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddSeconds(-10))
    $corruptHistoryPath = Join-Path `
        $corruptConfig.StateDirectory `
        "run-history.jsonl"
    [IO.File]::WriteAllText($corruptHistoryPath, "{truncated")
    $corruptResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $corruptConfig.ConfigPath
    Assert-True ($corruptResult.ExitCode -ne 0) `
        "corrupt history fails the legitimate invocation"
    Assert-True (-not (Test-Path -LiteralPath $corruptMarker)) `
        "corrupt history is detected before an agent starts"
    Assert-True (
        (Get-Content -LiteralPath $corruptHistoryPath -Raw) -ceq "{truncated"
    ) "worker preserves corrupt history for diagnosis instead of appending"
    $corruptLastResult = Get-Content `
        -LiteralPath (Join-Path $corruptConfig.StateDirectory "last-result.json") `
        -Raw | ConvertFrom-Json
    Assert-True (-not $corruptLastResult.success) `
        "corrupt history failure is exposed in last result"

    $recoveryRoot = Join-Path $testRoot "last-result-recovery"
    $recoveryMarker = Join-Path $recoveryRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $recoveryMarker
    $recoveryConfig = New-TestConfig `
        -Root $recoveryRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddHours(-5).AddSeconds(-10))
    $recoverySlots = @(Get-QuotaWakeExpectedSlots `
        -Schedule $recoveryConfig.Schedule `
        -Through ([DateTimeOffset]::Now))
    $recoveryFirstSlot = $recoverySlots[0]
    $recoverySlotKey = Get-QuotaWakeSlotKey `
        -ScheduleId $recoveryConfig.Schedule.id `
        -Slot $recoveryFirstSlot
    [IO.File]::WriteAllText(
        (Join-Path $recoveryConfig.StateDirectory "last-result.json"),
        ([ordered]@{
            schemaVersion = 4
            recordType = "executed"
            scheduleId = $recoveryConfig.Schedule.id
            slotKey = $recoverySlotKey
            scheduledFor = $recoveryFirstSlot.ToString("o")
            outcome = "failed"
            success = $false
            results = [ordered]@{
                persistence = [ordered]@{
                    success = $false
                    error = "Run history could not be written."
                }
            }
        } | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false))
    )
    $recoveryResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $recoveryConfig.ConfigPath
    Assert-True ($recoveryResult.ExitCode -eq 0) `
        "next legitimate run succeeds after history storage recovers"
    $recoveryHistory = @(Get-Content `
        -LiteralPath (Join-Path $recoveryConfig.StateDirectory "run-history.jsonl") |
        ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($recoveryHistory.Count -eq 2) `
        "slot-bearing last result is replayed before the current execution"
    Assert-True (
        @($recoveryHistory | Where-Object {
            $_.recordType -eq "missed"
        }).Count -eq 0
    ) "recovered execution is never converted into a missed slot"
    Assert-True ($recoveryHistory[0].slotKey -eq $recoverySlotKey) `
        "recovered execution is durable after last result is overwritten"

    $backfillRoot = Join-Path $testRoot "backfill"
    $backfillMarker = Join-Path $backfillRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $backfillMarker
    $backfillConfig = New-TestConfig `
        -Root $backfillRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddHours(-175).AddSeconds(-10))
    $backfillResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $backfillConfig.ConfigPath
    Assert-True ($backfillResult.ExitCode -eq 0) `
        "legitimate run with a long gap succeeds"
    $backfillHistoryPath = Join-Path `
        $backfillConfig.StateDirectory `
        "run-history.jsonl"
    $backfillHistory = @(Get-Content -LiteralPath $backfillHistoryPath |
        ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($backfillHistory.Count -eq 2) `
        "thirty-five missed slots and one execution use two records"
    Assert-True ($backfillHistory[0].recordType -eq "missed") `
        "backfill writes a missed group before execution"
    Assert-True ($backfillHistory[0].count -eq 35) `
        "one grouped record contains all thirty-five missed slots"
    Assert-True (@($backfillHistory[0].scheduledSlots).Count -eq 35) `
        "grouped history retains every exact scheduled timestamp"
    Assert-True ($backfillHistory[0].reason.code -eq "unknown") `
        "missing evidence remains unknown"
    Assert-True (@(Get-Content -LiteralPath $backfillMarker).Count -eq 1) `
        "backfill invokes the agent only for the current slot"

    $duplicateResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $backfillConfig.ConfigPath
    Assert-True ($duplicateResult.ExitCode -eq 0) `
        "duplicate current-slot invocation exits successfully"
    Assert-True (@(Get-Content -LiteralPath $backfillMarker).Count -eq 1) `
        "duplicate current-slot invocation does not run the agent again"
    Assert-True (@(Get-Content -LiteralPath $backfillHistoryPath).Count -eq 2) `
        "reconciliation is idempotent"

    $lockRoot = Join-Path $testRoot "lock"
    $lockMarker = Join-Path $lockRoot "agent-runs.txt"
    $env:QUOTAWAKE_TEST_MARKER = $lockMarker
    $env:QUOTAWAKE_TEST_SLEEP_MS = "2000"
    $lockConfig = New-TestConfig `
        -Root $lockRoot `
        -AgentPath $agentPath `
        -EffectiveFrom ([DateTimeOffset]::Now.AddSeconds(-10))
    $firstJob = Start-Job -ScriptBlock {
        param($WorkerPath, $ConfigPath)
        $output = & powershell.exe `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $WorkerPath `
            -ConfigPath $ConfigPath `
            -SuppressNotifications 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($output -join "`n")
        }
    } -ArgumentList $workerPath, $lockConfig.ConfigPath
    $markerDeadline = (Get-Date).AddSeconds(10)
    while (
        -not (Test-Path -LiteralPath $lockMarker) -and
        (Get-Date) -lt $markerDeadline
    ) {
        Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $lockMarker) `
        "first worker reaches the agent while holding the lock"
    $overlapResult = Invoke-Worker `
        -WorkerPath $workerPath `
        -ConfigPath $lockConfig.ConfigPath
    Assert-True ($overlapResult.ExitCode -eq 0) `
        "overlapping worker exits successfully"
    [void](Wait-Job -Job $firstJob -Timeout 10)
    $firstJobResult = Receive-Job -Job $firstJob
    Remove-Job -Job $firstJob -Force
    Assert-True ($firstJobResult.ExitCode -eq 0) "first worker succeeds"
    Assert-True (@(Get-Content -LiteralPath $lockMarker).Count -eq 1) `
        "worker lock prevents overlapping agent calls"
    Assert-True (
        @(Get-Content `
            -LiteralPath (Join-Path $lockConfig.StateDirectory "run-history.jsonl")
        ).Count -eq 1
    ) "worker lock prevents duplicate history"
}
finally {
    Remove-Item Env:\QUOTAWAKE_TEST_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\QUOTAWAKE_TEST_SLEEP_MS -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output "Worker scheduling tests passed."
