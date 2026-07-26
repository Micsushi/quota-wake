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
    }
}
$specifications = @(Get-AgentProcessSpecifications `
    -Agents @("Claude") `
    -Config $testConfig)
Assert-Equal 1 $specifications.Count "only selected agents get process specifications"
Assert-Equal "Claude" $specifications[0].Name "Claude process specification is selected"

$codexConfig = [pscustomobject]@{
    workingDirectory = "C:\Quota Wake"
    codex = [pscustomobject]@{
        path = "C:\Tools\codex.exe"
        model = "gpt-5.4-mini"
        prompt = "Reply with exactly: hi"
    }
}
$codexSpecifications = @(Get-AgentProcessSpecifications `
    -Agents @("Codex") `
    -Config $codexConfig)
Assert-Equal 1 $codexSpecifications.Count "Codex can be selected by itself"
Assert-Equal "Codex" $codexSpecifications[0].Name `
    "Codex process specification is selected"

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

$morning = [datetime]"2026-07-26T08:00:00"
$evening = [datetime]"2026-07-26T20:01:00"
Assert-Equal ([datetime]"2026-07-26T10:00:00") `
    (Get-QuotaWakeNextDailyRun -RunTimes $dailyRunTimes -Now $morning) `
    "daily mode chooses the next remaining slot today"
Assert-Equal ([datetime]"2026-07-27T05:00:00") `
    (Get-QuotaWakeNextDailyRun -RunTimes $dailyRunTimes -Now $evening) `
    "daily mode returns to its start time tomorrow"

$nextRunMessage = Format-QuotaWakeNextRunMessage `
    -NextRunTime ([datetime]"2026-07-27T05:00:00") `
    -Now ([datetime]"2026-07-26T20:01:00")
Assert-True ($nextRunMessage -match "tomorrow at 5:00 AM") `
    "setup message describes a next-day run"

$powershellPath = Resolve-CommandPath "powershell.exe"
Assert-True ([IO.Path]::IsPathRooted($powershellPath)) "resolved executable is absolute"
Assert-True (Test-Path -LiteralPath $powershellPath) "resolved executable exists"

$codexPath = Resolve-CodexCommandPath
Assert-True ([IO.Path]::IsPathRooted($codexPath)) "Codex executable is absolute"
Assert-True (Test-Path -LiteralPath $codexPath) "Codex executable exists"
Assert-True ($codexPath -notmatch '\\WindowsApps\\') `
    "Codex executable avoids protected WindowsApps paths"

$defaultRoot = Get-DefaultInstallRoot
Assert-True ([IO.Path]::IsPathRooted($defaultRoot)) "default install root is absolute"
Assert-True ($defaultRoot.EndsWith("QuotaWake")) "default install root is product-scoped"

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
