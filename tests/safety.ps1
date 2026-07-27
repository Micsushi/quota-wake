$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$suffix = [Guid]::NewGuid().ToString("N")
$unownedRoot = Join-Path ([IO.Path]::GetTempPath()) "QuotaWake-Unowned-$suffix"
$taskName = "QuotaWake-Safety-$($suffix.Substring(0, 8))"

try {
    [void](New-Item -ItemType Directory -Path $unownedRoot -Force)
    $sentinelPath = Join-Path $unownedRoot "keep-me.txt"
    [IO.File]::WriteAllText($sentinelPath, "unrelated data")

    $uninstallError = $null
    try {
        & (Join-Path $repoRoot "uninstall.ps1") `
            -TaskName $taskName `
            -InstallRoot $unownedRoot `
            -RemoveData | Out-Null
    }
    catch {
        $uninstallError = $_.Exception.Message
    }

    Assert-True ($uninstallError -match "ownership") `
        "uninstall refuses a root without Quota Wake ownership proof"
    Assert-True (Test-Path -LiteralPath $sentinelPath -PathType Leaf) `
        "uninstall preserves unrelated data"
}
finally {
    if (Test-Path -LiteralPath $unownedRoot) {
        Remove-Item -LiteralPath $unownedRoot -Recurse -Force
    }
}

$corruptStatusRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Corrupt-$suffix"
try {
    [void](New-Item `
        -ItemType Directory `
        -Path (Join-Path $corruptStatusRoot "runtime") `
        -Force)
    [void](New-Item `
        -ItemType Directory `
        -Path (Join-Path $corruptStatusRoot "state") `
        -Force)
    [IO.File]::WriteAllText(
        (Join-Path $corruptStatusRoot "runtime\config.json"),
        "{invalid"
    )
    [IO.File]::WriteAllText(
        (Join-Path $corruptStatusRoot "state\last-result.json"),
        "{invalid"
    )
    $corruptStatus = & (Join-Path $repoRoot "status.ps1") `
        -TaskName $taskName `
        -InstallRoot $corruptStatusRoot
    Assert-True (-not $corruptStatus.Installed) `
        "corrupt local files do not imply an installed task"
    Assert-True ([bool]$corruptStatus.ConfigError) `
        "status reports corrupt configuration"
    Assert-True ([bool]$corruptStatus.LastResultError) `
        "status reports corrupt result data"
}
finally {
    if (Test-Path -LiteralPath $corruptStatusRoot) {
        Remove-Item -LiteralPath $corruptStatusRoot -Recurse -Force
    }
}

$foreignTaskName = "QuotaWake-Foreign-$($suffix.Substring(0, 8))"
$foreignInstallRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "QuotaWake-Foreign-Install-$suffix"
$previousPath = $env:PATH
try {
    $fakeBin = Join-Path $foreignInstallRoot "fake-bin"
    [void](New-Item -ItemType Directory -Path $fakeBin -Force)
    [IO.File]::WriteAllText((Join-Path $fakeBin "claude.exe"), "")
    $env:PATH = "$fakeBin;$previousPath"

    $foreignAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoLogo -NoProfile -Command exit"
    $foreignTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddDays(1))
    Register-ScheduledTask `
        -TaskPath "\" `
        -TaskName $foreignTaskName `
        -Action $foreignAction `
        -Trigger $foreignTrigger `
        -Force | Out-Null

    $setupError = $null
    try {
        & (Join-Path $repoRoot "setup.ps1") `
            -Agents Claude `
            -TaskName $foreignTaskName `
            -InstallRoot $foreignInstallRoot `
            -SkipLiveTest | Out-Null
    }
    catch {
        $setupError = $_.Exception.Message
    }
    Assert-True ($setupError -match "not owned") `
        "setup refuses to replace a foreign task"

    $uninstallError = $null
    try {
        & (Join-Path $repoRoot "uninstall.ps1") `
            -TaskName $foreignTaskName `
            -InstallRoot $foreignInstallRoot | Out-Null
    }
    catch {
        $uninstallError = $_.Exception.Message
    }
    Assert-True ($uninstallError -match "not owned") `
        "uninstall refuses to remove a foreign task"
    Assert-True ([bool](Get-ScheduledTask `
        -TaskPath "\" `
        -TaskName $foreignTaskName `
        -ErrorAction SilentlyContinue)) `
        "foreign task remains registered"
}
finally {
    $env:PATH = $previousPath
    if (Get-ScheduledTask `
        -TaskPath "\" `
        -TaskName $foreignTaskName `
        -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask `
            -TaskPath "\" `
            -TaskName $foreignTaskName `
            -Confirm:$false
    }
    if (Test-Path -LiteralPath $foreignInstallRoot) {
        Remove-Item -LiteralPath $foreignInstallRoot -Recurse -Force
    }
}

Write-Output "Safety tests passed."
