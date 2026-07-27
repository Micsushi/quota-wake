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
        -ConfigPath $configPath 2>&1
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
        -ConfigPath $persistenceConfigPath 2>&1
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
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output "Worker failure tests passed."
