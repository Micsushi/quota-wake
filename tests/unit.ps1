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
