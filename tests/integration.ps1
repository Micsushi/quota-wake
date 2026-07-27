[CmdletBinding()]
param(
    [switch]$Live
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$taskName = "QuotaWake-Test-$suffix"
$installRoot = Join-Path $env:TEMP "Quota Wake Test $suffix"

try {
    $missingSelectionError = $null
    try {
        & (Join-Path $repoRoot "setup.ps1") `
            -TaskName $taskName `
            -InstallRoot $installRoot `
            -SkipLiveTest | Out-Null
    }
    catch {
        $missingSelectionError = $_.Exception.Message
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        & (Join-Path $repoRoot "uninstall.ps1") `
            -TaskName $taskName `
            -InstallRoot $installRoot `
            -RemoveData | Out-Null
    }
    Assert-True ($missingSelectionError -match "-Agents Claude") `
        "setup requires an explicit agent selection with examples"

    $continuousSetupStarted = Get-Date
    $continuousSetup = & (Join-Path $repoRoot "setup.ps1") `
        -Agents Claude `
        -TaskName $taskName `
        -InstallRoot $installRoot `
        -SkipLiveTest

    $configPath = Join-Path $installRoot "runtime\config.json"
    Assert-True (
        Test-Path `
            -LiteralPath (Join-Path $installRoot "quota-wake-install.json") `
            -PathType Leaf
    ) "setup writes install ownership proof"
    $conflictingTaskName = "$taskName-Other"
    $conflictingSetupError = $null
    try {
        & (Join-Path $repoRoot "setup.ps1") `
            -Agents Claude `
            -TaskName $conflictingTaskName `
            -InstallRoot $installRoot `
            -SkipLiveTest | Out-Null
    }
    catch {
        $conflictingSetupError = $_.Exception.Message
    }
    Assert-True ($conflictingSetupError -match "ownership") `
        "one install root cannot be shared by two tasks"
    Assert-True (-not (Get-ScheduledTask `
        -TaskPath "\" `
        -TaskName $conflictingTaskName `
        -ErrorAction SilentlyContinue)) `
        "conflicting setup does not create a second task"
    $singleAgentConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True ($singleAgentConfig.scheduleMode -eq "Continuous") `
        "omitting StartTime selects continuous mode"
    Assert-True (@($singleAgentConfig.agents).Count -eq 1) `
        "single-agent setup stores one selection"
    Assert-True ($singleAgentConfig.agents[0] -eq "Claude") `
        "single-agent setup remembers Claude"
    Assert-True ($null -eq $singleAgentConfig.PSObject.Properties["codex"]) `
        "single-agent setup omits unselected Codex configuration"
    Assert-True (
        (Split-Path -Leaf $singleAgentConfig.workingDirectory) -eq "probe"
    ) "setup uses a dedicated probe working directory"
    Assert-True (
        @(Get-ChildItem -LiteralPath $singleAgentConfig.workingDirectory -Force).Count -eq 0
    ) "the probe working directory is empty"
    Assert-True (
        $singleAgentConfig.claude.prompt -match
        "Do not use tools.*Perform no action.*exactly: hi"
    ) "setup stores an explicit no-action prompt"
    $continuousTask = Get-ScheduledTask -TaskName $taskName
    $continuousInfo = Get-ScheduledTaskInfo -TaskName $taskName
    Assert-True ($continuousTask.Triggers.Count -eq 1) `
        "continuous mode uses one repeating trigger"
    Assert-True ($continuousTask.Triggers[0].Repetition.Interval -eq "PT5H") `
        "continuous mode repeats every five hours across days"
    Assert-True (
        $continuousInfo.NextRunTime -gt $continuousSetupStarted -and
        $continuousInfo.NextRunTime -le $continuousSetupStarted.AddMinutes(2)
    ) "continuous mode starts within the next minute"
    Assert-True ($continuousSetup.Message -match "Next run:") `
        "continuous setup reports the next run"

    if ($Live) {
        $singleAgentConfig.notificationsEnabled = $false
        [IO.File]::WriteAllText(
            $configPath,
            ($singleAgentConfig | ConvertTo-Json -Depth 6),
            (New-Object Text.UTF8Encoding($false))
        )
        $singleOutput = & powershell.exe `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File (Join-Path $installRoot "runtime\run-quota-wake.ps1") `
            -ConfigPath $configPath
        Assert-True ($LASTEXITCODE -eq 0) "single-agent worker exits zero"
        Assert-True (($singleOutput -join "`n").Trim() -ceq "hi") `
            "single-agent worker returns exact hi"

        $singleResult = Get-Content `
            -LiteralPath (Join-Path $installRoot "state\last-result.json") `
            -Raw | ConvertFrom-Json
        Assert-True (@($singleResult.agents).Count -eq 1) `
            "single-agent result contains one agent"
        Assert-True ($singleResult.results.claude.success) `
            "single-agent Claude check succeeds"
        Assert-True ($singleResult.results.claude.usage.totalTokens -gt 0) `
            "single-agent Claude check records token usage"
        Assert-True ([bool]$singleResult.results.claude.model) `
            "single-agent Claude check records its model"
        Assert-True ($singleResult.results.claude.actionCount -eq 0) `
            "single-agent Claude check records zero actions"
        Assert-True ($null -eq $singleResult.results.PSObject.Properties["codex"]) `
            "single-agent result omits Codex"

        $workingConfigHash = (Get-FileHash -LiteralPath $configPath).Hash
        $failedSetupMessage = $null
        try {
            & (Join-Path $repoRoot "setup.ps1") `
                -Agents Claude `
                -ClaudeModel "quota-wake-invalid-model" `
                -TaskName $taskName `
                -InstallRoot $installRoot `
                -TimeoutSeconds 30 | Out-Null
        }
        catch {
            $failedSetupMessage = $_.Exception.Message
        }
        Assert-True ($failedSetupMessage -match "Claude.*sign in.*rerun") `
            "failed verification provides short recovery guidance"
        Assert-True ((Get-FileHash -LiteralPath $configPath).Hash -eq $workingConfigHash) `
            "failed verification preserves the working configuration"
    }

    & (Join-Path $repoRoot "setup.ps1") `
        -Agents Codex `
        -TaskName $taskName `
        -InstallRoot $installRoot `
        -SkipLiveTest | Out-Null
    $codexOnlyConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True (@($codexOnlyConfig.agents).Count -eq 1) `
        "Codex-only setup stores one selection"
    Assert-True ($codexOnlyConfig.agents[0] -eq "Codex") `
        "Codex-only setup remembers Codex"
    Assert-True ($null -eq $codexOnlyConfig.PSObject.Properties["claude"]) `
        "Codex-only setup omits unselected Claude configuration"
    Assert-True (
        [bool]$codexOnlyConfig.codex.PSObject.Properties["instructionsPath"]
    ) "Codex setup records the minimal instruction file path"
    Assert-True (
        Test-Path -LiteralPath $codexOnlyConfig.codex.instructionsPath
    ) "Codex setup installs the minimal instruction file"
    Assert-True (
        (Get-Content -LiteralPath $codexOnlyConfig.codex.instructionsPath -Raw).Trim() -ceq
        "Do not use tools or external context. Reply with exactly: hi"
    ) "Codex instruction override contains only the probe behavior"
    Assert-True (
        (Split-Path -Parent $codexOnlyConfig.codex.instructionsPath) -eq
        (Join-Path $installRoot "runtime")
    ) "Codex instruction override is stored outside the empty probe directory"

    $dailySetup = & (Join-Path $repoRoot "setup.ps1") `
        -Agents Claude,Codex `
        -StartTime 5 `
        -TaskName $taskName `
        -InstallRoot $installRoot `
        -SkipLiveTest

    $installedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True ($installedConfig.scheduleMode -eq "Daily") `
        "providing StartTime selects daily mode"
    Assert-True ([bool]$installedConfig.notificationsEnabled) `
        "installed runs retain failure notifications"
    Assert-True (
        @(Get-ChildItem -LiteralPath $installedConfig.workingDirectory -Force).Count -eq 0
    ) "combined setup leaves the dedicated probe directory empty"
    Assert-True ($dailySetup.Message -match "Next run:") `
        "setup reports the next run"

    $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction Stop)
    Assert-True ($tasks.Count -eq 1) "idempotent setup leaves one task"
    Assert-True ($tasks[0].Triggers.Count -eq 4) `
        "daily mode creates one trigger per same-day slot"
    $triggerTimes = @($tasks[0].Triggers | ForEach-Object {
        ([datetime]$_.StartBoundary).ToString("HH:mm")
    })
    Assert-True (($triggerTimes -join ",") -eq "05:00,10:00,15:00,20:00") `
        "daily triggers reset at the configured start time"

    $action = $tasks[0].Actions[0]
    Assert-True ($action.Arguments -match "-NoProfile") "task skips profiles"
    Assert-True ($action.Arguments -match "-NonInteractive") "task is noninteractive"
    Assert-True ($action.Arguments -match "-WindowStyle Hidden") "task is hidden"
    Assert-True ($action.Arguments -match [regex]::Escape($installRoot)) `
        "task supports install paths with spaces"
    Assert-True (-not $tasks[0].Settings.DisallowStartIfOnBatteries) `
        "task can start on battery"
    Assert-True (-not $tasks[0].Settings.StopIfGoingOnBatteries) `
        "task continues when switching to battery"
    Assert-True (-not $tasks[0].Settings.StartWhenAvailable) `
        "missed daily slots are skipped"

    $statusFixture = [ordered]@{
        schemaVersion = 3
        success = $true
        results = [ordered]@{
            claude = [ordered]@{
                success = $true
                actionCount = 0
                usage = [ordered]@{ totalTokens = 101 }
            }
            codex = [ordered]@{
                success = $true
                actionCount = 0
                usage = [ordered]@{ totalTokens = 202 }
            }
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $installRoot "state\last-result.json"),
        ($statusFixture | ConvertTo-Json -Depth 6),
        (New-Object Text.UTF8Encoding($false))
    )
    $status = & (Join-Path $repoRoot "status.ps1") `
        -TaskName $taskName `
        -InstallRoot $installRoot
    Assert-True ($status.Installed) "status sees installed task"
    Assert-True ($status.InstallOwned) "status verifies install ownership"
    Assert-True (-not $status.OwnershipConflict) `
        "status verifies scheduled task ownership"
    Assert-True (@($status.Agents).Count -eq 2) `
        "status reports the configured agents"
    Assert-True ($status.ScheduleMode -eq "Daily") `
        "status reports daily mode"
    Assert-True ($status.ClaudeUsage.totalTokens -eq 101) `
        "status exposes Claude token usage"
    Assert-True ($status.CodexUsage.totalTokens -eq 202) `
        "status exposes Codex token usage"
    Assert-True ($status.ClaudeActionCount -eq 0) `
        "status exposes Claude action count"
    Assert-True ($status.CodexActionCount -eq 0) `
        "status exposes Codex action count"

    if ($Live) {
        $startedAt = Get-Date
        Start-ScheduledTask -TaskName $taskName

        $sawWorker = $false
        $sawVisibleWindow = $false
        $deadline = (Get-Date).AddSeconds(190)
        do {
            Get-CimInstance Win32_Process | Where-Object {
                $_.CreationDate -ge $startedAt -and
                $_.CommandLine -like "*$installRoot*" -and
                $_.Name -match "powershell|claude|codex"
            } | ForEach-Object {
                $sawWorker = $true
                $process = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
                if ($process -and $process.MainWindowHandle -ne 0) {
                    $sawVisibleWindow = $true
                }
            }

            $task = Get-ScheduledTask -TaskName $taskName
            if ($task.State -ne "Running") {
                break
            }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)

        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        Assert-True ($taskInfo.LastTaskResult -eq 0) "live scheduled run exits zero"
        Assert-True $sawWorker "live worker process was observed"
        Assert-True (-not $sawVisibleWindow) "worker never owns a visible window"

        $lastResultPath = Join-Path $installRoot "state\last-result.json"
        $lastResult = Get-Content -LiteralPath $lastResultPath -Raw | ConvertFrom-Json
        Assert-True $lastResult.success "combined live result succeeds"
        Assert-True (@($lastResult.agents).Count -eq 2) `
            "combined live result contains both selected agents"
        Assert-True $lastResult.results.claude.success "Claude returns exact hi"
        Assert-True $lastResult.results.codex.success "Codex returns exact hi"
        Assert-True ($lastResult.results.claude.usage.totalTokens -gt 0) `
            "Claude records live token usage"
        Assert-True ($lastResult.results.codex.usage.totalTokens -gt 0) `
            "Codex records live token usage"
        Assert-True ($lastResult.results.claude.actionCount -eq 0) `
            "Claude live check records zero actions"
        Assert-True ($lastResult.results.codex.actionCount -eq 0) `
            "Codex live check records zero actions"
        Assert-True (
            @(Get-ChildItem -LiteralPath $installedConfig.workingDirectory -Force).Count -eq 0
        ) "live checks do not write into the probe directory"
    }
}
finally {
    if (Test-Path (Join-Path $repoRoot "uninstall.ps1")) {
        & (Join-Path $repoRoot "uninstall.ps1") `
            -TaskName $taskName `
            -InstallRoot $installRoot `
            -RemoveData | Out-Null
    }
}

Assert-True (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) `
    "uninstall removes task"
Assert-True (-not (Test-Path -LiteralPath $installRoot)) "uninstall removes test data"

Write-Output "Integration tests passed."
