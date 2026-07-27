[CmdletBinding()]
param(
    [string]$TaskName = "QuotaWake",
    [string]$InstallRoot,
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "src\QuotaWake.psm1") -Force -DisableNameChecking
Assert-QuotaWakeTaskName -TaskName $TaskName
if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$runtimeDirectory = Join-Path $InstallRoot "runtime"
$workerPath = Join-Path $runtimeDirectory "run-quota-wake.ps1"
$configPath = Join-Path $runtimeDirectory "config.json"
$powershellPath = Resolve-CommandPath "powershell.exe"
$expectedArguments = Get-QuotaWakeScheduledTaskArguments `
    -WorkerPath $workerPath `
    -ConfigPath $configPath

if (
    $RemoveData -and
    (Test-Path -LiteralPath $InstallRoot) -and
    -not (Test-QuotaWakeInstallOwnership `
        -InstallRoot $InstallRoot `
        -TaskName $TaskName)
) {
    throw "Refusing to remove '$InstallRoot' without matching Quota Wake ownership proof."
}

$task = Get-ScheduledTask `
    -TaskPath "\" `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if ($task) {
    if (-not (Test-QuotaWakeScheduledTaskOwnership `
        -Task $task `
        -ExpectedExecute $powershellPath `
        -ExpectedArguments $expectedArguments)) {
        throw "Refusing to remove task '$TaskName' because it is not owned by Quota Wake."
    }
    if ($task.State -eq "Running") {
        Stop-ScheduledTask -InputObject $task
    }
    Unregister-ScheduledTask `
        -InputObject $task `
        -Confirm:$false
}

$dataRemoved = $false
if ($RemoveData -and (Test-Path -LiteralPath $InstallRoot)) {
    $forbiddenRoots = @(
        [IO.Path]::GetPathRoot($InstallRoot),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ) | ForEach-Object {
        if ($_ ) { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    }
    $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if ($forbiddenRoots -contains $resolvedInstallRoot) {
        throw "Refusing to remove unsafe install root '$InstallRoot'."
    }
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    $dataRemoved = $true
}

[pscustomobject]@{
    Uninstalled = $true
    TaskName     = $TaskName
    DataRemoved = $dataRemoved
    InstallRoot = $InstallRoot
}
