$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Worker-$([Guid]::NewGuid().ToString('N'))"

try {
    $runtimeDirectory = Join-Path $testRoot "runtime"
    [void](New-Item -ItemType Directory -Path $runtimeDirectory -Force)
    $configPath = Join-Path $runtimeDirectory "config.json"
    [IO.File]::WriteAllText($configPath, "{not valid json")

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot "src\run-quota-wake.ps1") `
        -ConfigPath $configPath `
        -SuppressNotifications 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    Assert-True ($exitCode -ne 0) "invalid configuration exits nonzero"
    $lastResultPath = Join-Path $testRoot "state\last-result.json"
    Assert-True (Test-Path -LiteralPath $lastResultPath -PathType Leaf) `
        "preflight failure writes a deterministic last result"
    $lastResult = Get-Content -LiteralPath $lastResultPath -Raw | ConvertFrom-Json
    Assert-True (-not $lastResult.success) `
        "preflight failure cannot leave a stale success result"
    Assert-True ($lastResult.results.worker.error -match "configuration") `
        "preflight result explains the configuration failure"

    $invalidV4Root = Join-Path $testRoot "invalid-v4"
    $invalidV4Runtime = Join-Path $invalidV4Root "runtime"
    $invalidV4State = Join-Path $invalidV4Root "state"
    $invalidV4Probe = Join-Path $invalidV4Root "probe"
    [void](New-Item -ItemType Directory -Path $invalidV4Runtime -Force)
    $invalidV4ConfigPath = Join-Path $invalidV4Runtime "config.json"
    [IO.File]::WriteAllText(
        $invalidV4ConfigPath,
        ([ordered]@{
            schemaVersion = 4
            agents = @("Claude")
            graceSeconds = 120
            timeoutSeconds = 10
            notificationsEnabled = $false
            workingDirectory = $invalidV4Probe
            stateDirectory = $invalidV4State
            claude = [ordered]@{
                path = Join-Path $invalidV4Root "missing-claude.exe"
                model = "haiku"
                prompt = "Reply with exactly: hi"
            }
        } | ConvertTo-Json -Depth 5)
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot "src\run-quota-wake.ps1") `
        -ConfigPath $invalidV4ConfigPath `
        -SuppressNotifications 2>&1
    $invalidV4ExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    Assert-True ($invalidV4ExitCode -ne 0) `
        "invalid version-four configuration exits nonzero"
    Assert-True (
        Test-Path `
            -LiteralPath (Join-Path $invalidV4State "last-result.json") `
            -PathType Leaf
    ) "invalid version-four configuration writes last result"
    Assert-True (-not (Test-Path `
        -LiteralPath (Join-Path $invalidV4State "run-history.jsonl"))) `
        "invalid version-four configuration does not pollute slot history"

    $persistenceRoot = Join-Path $testRoot "persistence-case"
    $persistenceRuntime = Join-Path $persistenceRoot "runtime"
    $persistenceState = Join-Path $persistenceRoot "state"
    $persistenceProbe = Join-Path $persistenceRoot "probe"
    [void](New-Item -ItemType Directory -Path $persistenceRuntime -Force)
    [void](New-Item -ItemType Directory -Path $persistenceState -Force)
    [void](New-Item -ItemType Directory -Path $persistenceProbe -Force)
    [void](New-Item `
        -ItemType Directory `
        -Path (Join-Path $persistenceState "run-history.jsonl") `
        -Force)
    [IO.File]::WriteAllText(
        (Join-Path $persistenceProbe "old-residue.txt"),
        "old"
    )
    $persistenceConfigPath = Join-Path $persistenceRuntime "config.json"
    [IO.File]::WriteAllText(
        $persistenceConfigPath,
        ([ordered]@{
            schemaVersion = 3
            agents = @("Claude")
            timeoutSeconds = 10
            notificationsEnabled = $false
            workingDirectory = $persistenceProbe
            stateDirectory = $persistenceState
            claude = [ordered]@{
                path = Join-Path $persistenceRoot "missing-claude.exe"
                model = "haiku"
                prompt = "Reply with exactly: hi"
            }
        } | ConvertTo-Json -Depth 5)
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot "src\run-quota-wake.ps1") `
        -ConfigPath $persistenceConfigPath `
        -SuppressNotifications 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    Assert-True ($exitCode -ne 0) "startup and persistence failures exit nonzero"
    $persistenceLastResult = Get-Content `
        -LiteralPath (Join-Path $persistenceState "last-result.json") `
        -Raw | ConvertFrom-Json
    Assert-True (-not $persistenceLastResult.success) `
        "persistence failure cannot be recorded as success"
    Assert-True ([bool]$persistenceLastResult.results.persistence) `
        "history failure is exposed in the last result"
    Assert-True (
        @(
            Get-ChildItem `
                -LiteralPath $persistenceProbe `
                -Directory `
                -Filter "run-*"
        ).Count -eq 0
    ) "unique run directory is removed after startup failure"
    Assert-True (
        Test-Path `
            -LiteralPath (Join-Path $persistenceProbe "old-residue.txt") `
            -PathType Leaf
    ) "worker does not delete unrelated probe-root residue"

    $partialStartupRoot = Join-Path $testRoot "partial-startup-case"
    $partialStartupRuntime = Join-Path $partialStartupRoot "runtime"
    $partialStartupState = Join-Path $partialStartupRoot "state"
    $partialStartupProbe = Join-Path $partialStartupRoot "probe"
    [void](New-Item -ItemType Directory -Path $partialStartupRuntime -Force)
    [void](New-Item -ItemType Directory -Path $partialStartupState -Force)
    [void](New-Item -ItemType Directory -Path $partialStartupProbe -Force)
    $partialStartupInstructions = Join-Path `
        $partialStartupRuntime `
        "codex-instructions.txt"
    [IO.File]::WriteAllText($partialStartupInstructions, "Reply with exactly: hi")
    $partialStartupConfigPath = Join-Path `
        $partialStartupRuntime `
        "config.json"
    [IO.File]::WriteAllText(
        $partialStartupConfigPath,
        ([ordered]@{
            schemaVersion = 3
            agents = @("Claude", "Codex")
            timeoutSeconds = 10
            notificationsEnabled = $false
            workingDirectory = $partialStartupProbe
            stateDirectory = $partialStartupState
            claude = [ordered]@{
                path = $partialStartupInstructions
                model = "haiku"
                prompt = "Reply with exactly: hi"
            }
            codex = [ordered]@{
                path = Join-Path $env:SystemRoot "System32\where.exe"
                model = "gpt-test-mini"
                prompt = "Reply with exactly: hi"
                instructionsPath = $partialStartupInstructions
            }
        } | ConvertTo-Json -Depth 5)
    )

    $previousCodexCliPath = $env:CODEX_CLI_PATH
    try {
        $env:CODEX_CLI_PATH = Join-Path `
            $partialStartupRoot `
            "also-missing-codex.exe"
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File (Join-Path $repoRoot "src\run-quota-wake.ps1") `
            -ConfigPath $partialStartupConfigPath `
            -SuppressNotifications 2>&1
        $partialStartupExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
    }
    finally {
        $env:CODEX_CLI_PATH = $previousCodexCliPath
    }

    Assert-True ($partialStartupExitCode -ne 0) `
        "one failed agent startup exits nonzero"
    $partialStartupResult = Get-Content `
        -LiteralPath (Join-Path $partialStartupState "last-result.json") `
        -Raw | ConvertFrom-Json
    Assert-True ($null -ne $partialStartupResult.results.codex.exitCode) `
        "Codex retains its own completed process result"
    Assert-True (
        $partialStartupResult.results.claude.error -match "Claude.*start"
    ) "Claude alone reports its startup failure"
    Assert-True (
        $partialStartupResult.results.codex.error -notmatch
            "configuration or startup"
    ) "Claude startup failure is not copied onto Codex"

    # Multiple CODEX_HOME accounts must each get their own probe and their own
    # result entry, so one signed-out account cannot hide behind another.
    $multiAccountRoot = Join-Path $testRoot "codex-multi-account"
    $multiAccountRuntime = Join-Path $multiAccountRoot "runtime"
    $multiAccountState = Join-Path $multiAccountRoot "state"
    $multiAccountProbe = Join-Path $multiAccountRoot "probe"
    $multiAccountWorkHome = Join-Path $multiAccountRoot "codex-work"
    $multiAccountPersonalHome = Join-Path $multiAccountRoot "codex-personal"
    foreach ($directory in @(
        $multiAccountRuntime,
        $multiAccountState,
        $multiAccountProbe,
        $multiAccountWorkHome,
        $multiAccountPersonalHome
    )) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $multiAccountInstructions = Join-Path `
        $multiAccountRuntime `
        "codex-instructions.txt"
    [IO.File]::WriteAllText($multiAccountInstructions, "Reply with exactly: hi")
    $multiAccountConfigPath = Join-Path $multiAccountRuntime "config.json"
    [IO.File]::WriteAllText(
        $multiAccountConfigPath,
        ([ordered]@{
            schemaVersion = 3
            agents = @("Codex")
            timeoutSeconds = 10
            notificationsEnabled = $false
            workingDirectory = $multiAccountProbe
            stateDirectory = $multiAccountState
            codex = [ordered]@{
                path = Join-Path $env:SystemRoot "System32\where.exe"
                model = "gpt-test-mini"
                prompt = "Reply with exactly: hi"
                instructionsPath = $multiAccountInstructions
                homes = @(
                    [ordered]@{ name = "work"; home = $multiAccountWorkHome }
                    [ordered]@{
                        name = "personal"
                        home = $multiAccountPersonalHome
                    }
                )
            }
        } | ConvertTo-Json -Depth 6)
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    [void](& powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot "src\run-quota-wake.ps1") `
        -ConfigPath $multiAccountConfigPath `
        -SuppressNotifications 2>&1)
    $ErrorActionPreference = $previousErrorActionPreference

    $multiAccountResult = Get-Content `
        -LiteralPath (Join-Path $multiAccountState "last-result.json") `
        -Raw | ConvertFrom-Json
    Assert-True (
        [bool]$multiAccountResult.results.PSObject.Properties["codex:work"]
    ) "each Codex account gets its own result entry"
    Assert-True (
        [bool]$multiAccountResult.results.PSObject.Properties["codex:personal"]
    ) "the second Codex account is probed too"
    Assert-True (
        -not $multiAccountResult.results.PSObject.Properties["codex"]
    ) "named Codex accounts replace the ambient result key"
    Assert-True (
        $multiAccountResult.results."codex:work".name -eq "Codex:work"
    ) "Codex account results carry their account name"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output "Worker failure tests passed."
