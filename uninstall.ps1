[CmdletBinding()]
param(
    [string]$TaskName = "QuotaWake",
    [string]$InstallRoot,
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "src\QuotaWake.psm1") -Force -DisableNameChecking
if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

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
}

[pscustomobject]@{
    Uninstalled = $true
    TaskName     = $TaskName
    DataRemoved = [bool]$RemoveData
    InstallRoot = $InstallRoot
}
