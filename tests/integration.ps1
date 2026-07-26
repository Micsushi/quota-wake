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
            -StartDelayMinutes 10 `
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

    & (Join-Path $repoRoot "setup.ps1") `
        -Agents Claude `
        -TaskName $taskName `
        -InstallRoot $installRoot `
        -StartDelayMinutes 10 `
        -SkipLiveTest | Out-Null

    $configPath = Join-Path $installRoot "runtime\config.json"
    $singleAgentConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True (@($singleAgentConfig.agents).Count -eq 1) `
        "single-agent setup stores one selection"
    Assert-True ($singleAgentConfig.agents[0] -eq "Claude") `
        "single-agent setup remembers Claude"
    Assert-True ($null -eq $singleAgentConfig.PSObject.Properties["codex"]) `
        "single-agent setup omits unselected Codex configuration"

    if ($Live) {
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
                -StartDelayMinutes 10 `
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
        -StartDelayMinutes 10 `
        -SkipLiveTest | Out-Null
    $codexOnlyConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True (@($codexOnlyConfig.agents).Count -eq 1) `
        "Codex-only setup stores one selection"
    Assert-True ($codexOnlyConfig.agents[0] -eq "Codex") `
        "Codex-only setup remembers Codex"
    Assert-True ($null -eq $codexOnlyConfig.PSObject.Properties["claude"]) `
        "Codex-only setup omits unselected Claude configuration"

    & (Join-Path $repoRoot "setup.ps1") `
        -Agents Claude,Codex `
        -TaskName $taskName `
        -InstallRoot $installRoot `
        -StartDelayMinutes 10 `
        -SkipLiveTest | Out-Null

    $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction Stop)
    Assert-True ($tasks.Count -eq 1) "idempotent setup leaves one task"

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

    $status = & (Join-Path $repoRoot "status.ps1") `
        -TaskName $taskName `
        -InstallRoot $installRoot
    Assert-True ($status.Installed) "status sees installed task"
    Assert-True (@($status.Agents).Count -eq 2) `
        "status reports the configured agents"

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
