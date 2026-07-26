Set-StrictMode -Version 2.0

function Quote-CommandLineArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $quoted = New-Object Text.StringBuilder
    [void]$quoted.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$quoted.Append(('\' * (($backslashes * 2) + 1)))
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$quoted.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$quoted.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$quoted.Append(('\' * ($backslashes * 2)))
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Join-CommandLineArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    return (($ArgumentList | ForEach-Object {
        Quote-CommandLineArgument -Value $_
    }) -join ' ')
}

function Resolve-CommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw "Required command '$Name' was not found in PATH."
    }

    $path = $command.Source
    if (-not $path) {
        $path = $command.Path
    }
    if (-not $path -or -not [IO.Path]::IsPathRooted($path)) {
        throw "Command '$Name' did not resolve to an absolute executable path."
    }
    return [IO.Path]::GetFullPath($path)
}

function Get-DefaultInstallRoot {
    [CmdletBinding()]
    param()

    $localApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if (-not $localApplicationData) {
        throw "Windows LocalApplicationData is unavailable."
    }
    return Join-Path $localApplicationData "QuotaWake"
}

function Resolve-CodexCommandPath {
    [CmdletBinding()]
    param()

    $candidates = New-Object Collections.Generic.List[string]
    if ($env:CODEX_CLI_PATH) {
        $candidates.Add($env:CODEX_CLI_PATH)
    }

    $localApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ($localApplicationData) {
        $desktopBin = Join-Path $localApplicationData "OpenAI\Codex\bin"
        if (Test-Path -LiteralPath $desktopBin) {
            Get-ChildItem `
                -LiteralPath $desktopBin `
                -Recurse `
                -Filter "codex.exe" `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    $applicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ApplicationData
    )
    if ($applicationData) {
        $npmModules = Join-Path $applicationData "npm\node_modules"
        if (Test-Path -LiteralPath $npmModules) {
            Get-ChildItem `
                -LiteralPath $npmModules `
                -Recurse `
                -Filter "codex.exe" `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    Get-Command "codex.exe" -CommandType Application -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates.Add($_.Source) }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (
            $candidate -and
            [IO.Path]::IsPathRooted($candidate) -and
            (Test-Path -LiteralPath $candidate) -and
            $candidate -notmatch '\\WindowsApps\\'
        ) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "Codex executable was not found outside the protected WindowsApps directory."
}

function Test-ExactHi {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Output
    )

    if ($null -eq $Output) {
        return $false
    }
    return $Output.Trim() -ceq "hi"
}

function Start-HiddenProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $processInfo = New-Object Diagnostics.ProcessStartInfo
    $processInfo.FileName = $FilePath
    $processInfo.Arguments = Join-CommandLineArguments -ArgumentList $ArgumentList
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $processInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw "$Name did not start."
    }

    $process.StandardInput.Close()
    return [pscustomobject]@{
        Name       = $Name
        Process    = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-HiddenProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Handle,

        [Parameter(Mandatory = $true)]
        [DateTime]$DeadlineUtc
    )

    $process = $Handle.Process
    try {
        $remaining = [int][Math]::Max(
            0,
            [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
        )
        if (-not $process.WaitForExit($remaining)) {
            try {
                $process.Kill()
                $process.WaitForExit()
            }
            catch {
            }
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $null
                error    = "$($Handle.Name) timed out."
            }
        }

        $stdout = $Handle.StdoutTask.GetAwaiter().GetResult()
        [void]$Handle.StderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $process.ExitCode
                error    = "$($Handle.Name) exited with code $($process.ExitCode)."
            }
        }
        if (-not (Test-ExactHi -Output $stdout)) {
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $process.ExitCode
                error    = "$($Handle.Name) returned unexpected output."
            }
        }

        return [pscustomobject]@{
            name     = $Handle.Name
            success  = $true
            exitCode = $process.ExitCode
            output   = "hi"
            error    = $null
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-AtomicUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $Content,
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Show-QuotaWakeFailureNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $notification = New-Object Windows.Forms.NotifyIcon
        try {
            $notification.Icon = [Drawing.SystemIcons]::Warning
            $notification.BalloonTipTitle = "Quota Wake failed"
            $notification.BalloonTipText = $Message
            $notification.Visible = $true
            $notification.ShowBalloonTip(8000)
            Start-Sleep -Milliseconds 800
        }
        finally {
            $notification.Dispose()
        }
    }
    catch {
    }
}

Export-ModuleMember -Function @(
    "Quote-CommandLineArgument",
    "Join-CommandLineArguments",
    "Resolve-CommandPath",
    "Resolve-CodexCommandPath",
    "Get-DefaultInstallRoot",
    "Test-ExactHi",
    "Start-HiddenProcess",
    "Complete-HiddenProcess",
    "Write-AtomicUtf8File",
    "Show-QuotaWakeFailureNotification"
)
