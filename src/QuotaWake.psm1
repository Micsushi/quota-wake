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

function Get-QuotaWakeScheduledTaskArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkerPath,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [switch]$SuppressNotifications
    )

    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $WorkerPath,
        "-ConfigPath",
        $ConfigPath
    )
    if ($SuppressNotifications) {
        $arguments += "-SuppressNotifications"
    }
    return Join-CommandLineArguments -ArgumentList $arguments
}

function Get-QuotaWakeScheduledTaskAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LauncherPath,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkerArguments,

        [string]$WScriptPath = (Join-Path $env:SystemRoot "System32\wscript.exe")
    )

    $prefix = Join-CommandLineArguments -ArgumentList @(
        "//B",
        "//Nologo",
        $LauncherPath,
        $PowerShellPath
    )
    return [pscustomobject]@{
        Execute   = $WScriptPath
        Arguments = "$prefix $WorkerArguments"
    }
}

function Assert-QuotaWakeTaskName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        throw "TaskName cannot be empty."
    }
    if ($TaskName.IndexOfAny([char[]]"*?[]") -ge 0) {
        throw "TaskName cannot contain wildcard characters."
    }
    if ($TaskName.Contains('\') -or $TaskName.Contains('/')) {
        throw "TaskName must identify one task in the root task folder."
    }
}

function Test-QuotaWakeScheduledTaskOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Task,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedExecute,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArguments
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) {
        return $false
    }

    $action = $actions[0]
    try {
        return (
            [string]::Equals(
                [IO.Path]::GetFullPath([string]$action.Execute),
                [IO.Path]::GetFullPath($ExpectedExecute),
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                [string]$action.Arguments,
                $ExpectedArguments,
                [StringComparison]::Ordinal
            )
        )
    }
    catch {
        return $false
    }
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

function Get-QuotaWakeOwnershipMarkerPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    return Join-Path ([IO.Path]::GetFullPath($InstallRoot)) "quota-wake-install.json"
}

function Test-QuotaWakeInstallOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [switch]$AllowLegacyLauncherMissing
    )

    $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $markerPath = Get-QuotaWakeOwnershipMarkerPath -InstallRoot $resolvedInstallRoot
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }

    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    }
    catch {
        return $false
    }
    foreach ($propertyName in @("product", "schemaVersion", "installRoot", "taskName")) {
        if (-not $marker.PSObject.Properties[$propertyName]) {
            return $false
        }
    }
    try {
        if (
            $marker.product -cne "QuotaWake" -or
            [int]$marker.schemaVersion -ne 1 -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath([string]$marker.installRoot),
                $resolvedInstallRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $marker.taskName -cne $TaskName
        ) {
            return $false
        }

        $runtimeDirectory = Join-Path $resolvedInstallRoot "runtime"
        $requiredFiles = @(
            "config.json",
            "QuotaWake.psm1",
            "run-quota-wake.ps1"
        )
        if (-not $AllowLegacyLauncherMissing) {
            $requiredFiles += "run-hidden.vbs"
        }
        foreach ($name in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $runtimeDirectory $name) -PathType Leaf)) {
                return $false
            }
        }
    }
    catch {
        return $false
    }
    return $true
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

function Get-AgentSetupHelp {
    [CmdletBinding()]
    param()

    return @"
Choose at least one agent:
  .\setup.ps1 -Agents Claude
  .\setup.ps1 -Agents Codex
  .\setup.ps1 -Agents Claude,Codex
Run 'Get-Help .\setup.ps1 -Examples' for help.
"@.Trim()
}

function Resolve-AgentSelection {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Agents
    )

    $selection = New-Object Collections.Generic.List[string]
    foreach ($value in @($Agents)) {
        foreach ($part in @($value -split ",")) {
            $name = $part.Trim()
            if (-not $name) {
                continue
            }

            $canonicalName = switch ($name.ToLowerInvariant()) {
                "claude" { "Claude"; break }
                "codex" { "Codex"; break }
                default {
                    throw "Unsupported agent '$name'. $(Get-AgentSetupHelp)"
                }
            }
            if (-not $selection.Contains($canonicalName)) {
                $selection.Add($canonicalName)
            }
        }
    }

    if ($selection.Count -eq 0) {
        throw Get-AgentSetupHelp
    }
    return $selection.ToArray()
}

function Get-AgentFailureGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Claude", "Codex")]
        [string]$Agent,

        [Parameter(Mandatory = $true)]
        [string]$Problem
    )

    if ($Agent -eq "Claude") {
        return (
            "Claude is not ready: $Problem " +
            "Confirm Claude Code is installed and claude.exe is in PATH, " +
            "run 'claude' to sign in, then rerun setup with -Agents Claude."
        )
    }
    return (
        "Codex is not ready: $Problem " +
        "Confirm Codex CLI is installed and codex.exe is available, " +
        "run 'codex' to sign in, then rerun setup with -Agents Codex."
    )
}

function Resolve-AgentProcessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Claude", "Codex")]
        [string]$Agent,

        [string]$ConfiguredPath
    )

    if (
        -not [string]::IsNullOrWhiteSpace($ConfiguredPath) -and
        (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)
    ) {
        return [IO.Path]::GetFullPath($ConfiguredPath)
    }
    if ($Agent -eq "Codex") {
        return Resolve-CodexCommandPath
    }
    return Resolve-CommandPath "claude.exe"
}

function Get-AgentProcessSpecifications {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Agents,

        [Parameter(Mandatory = $true)]
        $Config,

        [string]$WorkingDirectory
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = [string]$Config.workingDirectory
    }
    foreach ($agent in $Agents) {
        if ($agent -eq "Claude") {
            $environmentVariables = @{}
            $configDirProperty = $Config.claude.PSObject.Properties["configDir"]
            if (
                $configDirProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$configDirProperty.Value)
            ) {
                $environmentVariables["CLAUDE_CONFIG_DIR"] = (
                    [string]$configDirProperty.Value
                )
            }
            [pscustomobject]@{
                Name         = "Claude"
                FilePath     = [string]$Config.claude.path
                Model        = [string]$Config.claude.model
                WorkingDirectory = $WorkingDirectory
                OutputFormat = "ClaudeJson"
                EnvironmentVariables = $environmentVariables
                ArgumentList = @(
                    "-p",
                    [string]$Config.claude.prompt,
                    "--model",
                    [string]$Config.claude.model,
                    "--max-turns",
                    "1",
                    "--no-session-persistence",
                    "--no-chrome",
                    "--tools=",
                    "--disable-slash-commands",
                    "--strict-mcp-config",
                    "--setting-sources=",
                    "--system-prompt",
                    (
                        "You are a connectivity probe. Do not use tools or " +
                        "external context. Return only the requested literal text."
                    ),
                    "--output-format",
                    "json"
                )
            }
            continue
        }

        [pscustomobject]@{
            Name         = "Codex"
            FilePath     = [string]$Config.codex.path
            Model        = [string]$Config.codex.model
            WorkingDirectory = $WorkingDirectory
            OutputFormat = "CodexJson"
            EnvironmentVariables = @{}
            ArgumentList = @(
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
                "--disable",
                "shell_tool",
                "--disable",
                "plugins",
                "--disable",
                "apps",
                "--disable",
                "browser_use",
                "--disable",
                "browser_use_external",
                "--disable",
                "browser_use_full_cdp_access",
                "--disable",
                "computer_use",
                "--disable",
                "goals",
                "--disable",
                "hooks",
                "--disable",
                "skill_search",
                "--disable",
                "multi_agent",
                "--disable",
                "image_generation",
                "--disable",
                "in_app_browser",
                "--disable",
                "tool_suggest",
                "--disable",
                "workspace_dependencies",
                "-c",
                "project_doc_max_bytes=0",
                "-c",
                (
                    'model_instructions_file="{0}"' -f
                    ([string]$Config.codex.instructionsPath).Replace('\', '/')
                ),
                "--color",
                "never",
                "--json",
                "-m",
                [string]$Config.codex.model,
                "-s",
                "read-only",
                "-C",
                $WorkingDirectory,
                [string]$Config.codex.prompt
            )
        }
    }
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
        [string]$WorkingDirectory,

        [hashtable]$EnvironmentVariables = @{},

        [ValidateSet("Text", "ClaudeJson", "CodexJson")]
        [string]$OutputFormat = "Text",

        [string]$Model
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
    foreach ($entry in $EnvironmentVariables.GetEnumerator()) {
        $processInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }

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
        OutputFormat = $OutputFormat
        Model        = $Model
    }
}

function Stop-QuotaWakeProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process
    )

    if ($Process.HasExited) {
        return
    }

    $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
    if (Test-Path -LiteralPath $taskkillPath -PathType Leaf) {
        try {
            & $taskkillPath `
                /PID $Process.Id `
                /T `
                /F 2>$null | Out-Null
        }
        catch {
        }
    }
    if (-not $Process.HasExited) {
        $Process.Kill()
    }
    if (-not $Process.WaitForExit(5000)) {
        throw "Process tree did not stop within five seconds."
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
                Stop-QuotaWakeProcessTree -Process $process
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
        try {
            if ($Handle.OutputFormat -eq "ClaudeJson") {
                $probe = ConvertFrom-ClaudeProbeOutput -Output $stdout
            }
            elseif ($Handle.OutputFormat -eq "CodexJson") {
                $probe = ConvertFrom-CodexProbeOutput `
                    -Output $stdout `
                    -Model $Handle.Model
            }
            else {
                $probe = [pscustomobject]@{
                    text = $stdout
                    model = $Handle.Model
                    usage = $null
                    actionCount = $null
                }
            }
        }
        catch {
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $process.ExitCode
                error    = "$($Handle.Name) returned invalid structured output."
            }
        }
        if (-not (Test-ExactHi -Output $probe.text)) {
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $process.ExitCode
                error    = "$($Handle.Name) returned unexpected output."
            }
        }
        if (-not $probe.usage -or $probe.usage.totalTokens -le 0) {
            return [pscustomobject]@{
                name     = $Handle.Name
                success  = $false
                exitCode = $process.ExitCode
                error    = "$($Handle.Name) did not report token usage."
            }
        }

        return [pscustomobject]@{
            name     = $Handle.Name
            success  = $true
            exitCode = $process.ExitCode
            output   = "hi"
            model    = $probe.model
            usage    = $probe.usage
            actionCount = $probe.actionCount
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

function New-QuotaWakeRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $resolvedBaseDirectory = [IO.Path]::GetFullPath($BaseDirectory)
    if (-not (Test-Path -LiteralPath $resolvedBaseDirectory)) {
        [void](New-Item -ItemType Directory -Path $resolvedBaseDirectory -Force)
    }
    $runDirectory = Join-Path `
        $resolvedBaseDirectory `
        "run-$([Guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $runDirectory)
    return $runDirectory
}

function Test-FailureNotificationEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $property = $Config.PSObject.Properties["notificationsEnabled"]
    if (-not $property) {
        return $true
    }
    return [bool]$property.Value
}

function ConvertTo-QuotaWakeTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $normalized = $Value.Trim().ToLowerInvariant() -replace "\s", ""
    if ($normalized -notmatch "^(?<hour>\d{1,2})(?::(?<minute>\d{2}))?(?<suffix>am|pm)?$") {
        throw "Invalid start time '$Value'. Use a value such as 5, 5am, 17, or 17:30."
    }

    $hour = [int]$Matches["hour"]
    $minute = 0
    if ($Matches["minute"]) {
        $minute = [int]$Matches["minute"]
    }
    $suffix = $Matches["suffix"]
    if ($minute -gt 59) {
        throw "Invalid start time '$Value'. Use a value such as 5, 5am, 17, or 17:30."
    }

    if ($suffix) {
        if ($hour -lt 1 -or $hour -gt 12) {
            throw "Invalid start time '$Value'. Use a value such as 5, 5am, 17, or 17:30."
        }
        if ($hour -eq 12) {
            $hour = 0
        }
        if ($suffix -eq "pm") {
            $hour += 12
        }
    }
    elseif ($hour -gt 23) {
        throw "Invalid start time '$Value'. Use a value such as 5, 5am, 17, or 17:30."
    }

    return New-TimeSpan -Hours $hour -Minutes $minute
}

function Get-QuotaWakeDailyRunTimes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$StartTime,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 168)]
        [int]$IntervalHours
    )

    if ($StartTime -lt [TimeSpan]::Zero -or $StartTime -ge [TimeSpan]::FromDays(1)) {
        throw "StartTime must be within one day."
    }

    $runTimes = New-Object Collections.Generic.List[TimeSpan]
    $time = $StartTime
    while ($time -lt [TimeSpan]::FromDays(1)) {
        $runTimes.Add($time)
        $time = $time.Add([TimeSpan]::FromHours($IntervalHours))
    }
    return $runTimes.ToArray()
}

function New-QuotaWakeSchedule {
    [CmdletBinding(DefaultParameterSetName = "Continuous")]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Continuous", "Daily")]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$EffectiveFrom,

        [Parameter(Mandatory = $true)]
        [string]$TimeZoneId,

        [Parameter(Mandatory = $true, ParameterSetName = "Continuous")]
        [ValidateRange(1, 168)]
        [int]$IntervalHours,

        [Parameter(Mandatory = $true, ParameterSetName = "Daily")]
        [string[]]$DailyRunTimes
    )

    if ($Mode -ne $PSCmdlet.ParameterSetName) {
        throw "Schedule mode and schedule parameters do not match."
    }
    [void][TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)

    $normalizedTimes = @()
    if ($Mode -eq "Daily") {
        foreach ($value in $DailyRunTimes) {
            $parsed = [TimeSpan]::Zero
            if (-not [TimeSpan]::TryParse(
                $value,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )) {
                throw "Daily run time '$value' is invalid."
            }
            if ($parsed -lt [TimeSpan]::Zero -or $parsed.TotalDays -ge 1) {
                throw "Daily run time '$value' must be within one day."
            }
            $normalizedTimes += $parsed.ToString("hh\:mm\:ss")
        }
        $normalizedTimes = @($normalizedTimes | Sort-Object -Unique)
        if ($normalizedTimes.Count -eq 0) {
            throw "A daily schedule requires at least one run time."
        }
    }

    $canonical = @(
        $Mode
        $EffectiveFrom.ToUniversalTime().ToString("o")
        $TimeZoneId
        if ($Mode -eq "Continuous") {
            $IntervalHours.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
        else {
            $normalizedTimes -join ","
        }
    ) -join "|"
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))
    }
    finally {
        $sha256.Dispose()
    }
    $id = "schedule-" + (($hash | ForEach-Object {
        $_.ToString("x2")
    }) -join "").Substring(0, 24)

    $schedule = [ordered]@{
        id            = $id
        mode          = $Mode
        effectiveFrom = $EffectiveFrom.ToString("o")
        timeZoneId    = $TimeZoneId
    }
    if ($Mode -eq "Continuous") {
        $schedule.intervalHours = $IntervalHours
    }
    else {
        $schedule.dailyRunTimes = $normalizedTimes
    }
    return [pscustomobject]$schedule
}

function Get-QuotaWakeExpectedSlots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Schedule,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Through
    )

    $effectiveFrom = [DateTimeOffset]::Parse(
        [string]$Schedule.effectiveFrom,
        [Globalization.CultureInfo]::InvariantCulture
    )
    if ($Through -lt $effectiveFrom) {
        return
    }

    if ([string]$Schedule.mode -eq "Continuous") {
        $interval = [TimeSpan]::FromHours([int]$Schedule.intervalHours)
        $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById(
            [string]$Schedule.timeZoneId
        )
        for (
            $slot = $effectiveFrom;
            $slot -le $Through;
            $slot = $slot.Add($interval)
        ) {
            Write-Output ([TimeZoneInfo]::ConvertTime($slot, $timeZone))
        }
        return
    }
    if ([string]$Schedule.mode -ne "Daily") {
        throw "Unsupported schedule mode '$($Schedule.mode)'."
    }

    $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById(
        [string]$Schedule.timeZoneId
    )
    $firstLocal = [TimeZoneInfo]::ConvertTime($effectiveFrom, $timeZone)
    $throughLocal = [TimeZoneInfo]::ConvertTime($Through, $timeZone)
    for (
        $date = $firstLocal.Date;
        $date -le $throughLocal.Date;
        $date = $date.AddDays(1)
    ) {
        foreach ($timeText in @($Schedule.dailyRunTimes)) {
            $time = [TimeSpan]::ParseExact(
                [string]$timeText,
                "hh\:mm\:ss",
                [Globalization.CultureInfo]::InvariantCulture
            )
            $local = [DateTime]::SpecifyKind(
                $date.Add($time),
                [DateTimeKind]::Unspecified
            )
            if ($timeZone.IsInvalidTime($local)) {
                continue
            }
            $offset = $timeZone.GetUtcOffset($local)
            $slot = [DateTimeOffset]::new($local, $offset)
            if ($slot -ge $effectiveFrom -and $slot -le $Through) {
                Write-Output $slot
            }
        }
    }
}

function Get-QuotaWakeSlotKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScheduleId,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Slot
    )

    return (
        "$ScheduleId|$($Slot.UtcDateTime.ToString('o'))"
    )
}

function Get-QuotaWakeNextExpectedSlot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Schedule,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$NotBefore,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Through
    )

    return @(Get-QuotaWakeExpectedSlots `
        -Schedule $Schedule `
        -Through $Through |
        Where-Object { $_ -ge $NotBefore } |
        Select-Object -First 1)[0]
}

function Get-QuotaWakeInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Schedule,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$InvocationTime,

        [ValidateRange(0, 3600)]
        [int]$GraceSeconds = 120
    )

    $slots = @(Get-QuotaWakeExpectedSlots `
        -Schedule $Schedule `
        -Through $InvocationTime)
    if ($slots.Count -eq 0) {
        return [pscustomobject]@{
            IsLegitimate = $false
            Slot          = $null
            SlotKey       = $null
        }
    }
    $slot = [DateTimeOffset]$slots[-1]
    $isLegitimate = (
        $InvocationTime -ge $slot -and
        $InvocationTime -le $slot.AddSeconds($GraceSeconds)
    )
    return [pscustomobject]@{
        IsLegitimate = $isLegitimate
        Slot          = $slot
        SlotKey       = Get-QuotaWakeSlotKey `
            -ScheduleId ([string]$Schedule.id) `
            -Slot $slot
    }
}

function Get-QuotaWakeMissReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Slot,

        [AllowEmptyCollection()]
        [object[]]$EvidenceIntervals = @()
    )

    foreach ($interval in @($EvidenceIntervals)) {
        if (
            [string]$interval.kind -in @(
                "system_hibernating",
                "system_off"
            ) -and
            $Slot -ge [DateTimeOffset]::Parse([string]$interval.unavailableFrom) -and
            $Slot -lt [DateTimeOffset]::Parse([string]$interval.availableAgainAt)
        ) {
            return [pscustomobject]@{
                code             = [string]$interval.kind
                confidence       = "confirmed"
                unavailableFrom  = [string]$interval.unavailableFrom
                availableAgainAt = [string]$interval.availableAgainAt
                availableFrom    = $null
                availableUntil   = $null
                evidence         = @($interval.evidence)
            }
        }
    }
    foreach ($interval in @($EvidenceIntervals)) {
        if (
            [string]$interval.kind -eq "available" -and
            $Slot -ge [DateTimeOffset]::Parse([string]$interval.availableFrom) -and
            $Slot -lt [DateTimeOffset]::Parse([string]$interval.availableUntil)
        ) {
            return [pscustomobject]@{
                code             = "scheduler_did_not_start"
                confidence       = "confirmed"
                unavailableFrom  = $null
                availableAgainAt = $null
                availableFrom    = [string]$interval.availableFrom
                availableUntil   = [string]$interval.availableUntil
                evidence         = @($interval.evidence)
            }
        }
    }
    return [pscustomobject]@{
        code             = "unknown"
        confidence       = "unknown"
        unavailableFrom  = $null
        availableAgainAt = $null
        availableFrom    = $null
        availableUntil   = $null
        evidence         = @()
    }
}

function ConvertTo-QuotaWakeEvidenceIntervals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Transitions,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Through
    )

    $availableFrom = $null
    $availableEvidence = $null
    $unavailable = $null
    foreach ($transition in @($Transitions | Sort-Object {
        [DateTimeOffset]::Parse([string]$_.time)
    })) {
        $time = [DateTimeOffset]::Parse([string]$transition.time)
        if ($time -gt $Through) {
            break
        }
        if ([string]$transition.kind -eq "available") {
            if ($unavailable) {
                [pscustomobject]@{
                    kind             = [string]$unavailable.kind
                    unavailableFrom  = (
                        [DateTimeOffset]::Parse(
                            [string]$unavailable.time
                        ).ToString("o")
                    )
                    availableAgainAt = $time.ToString("o")
                    evidence         = @(
                        $unavailable.evidence
                        $transition.evidence
                    )
                }
                $unavailable = $null
            }
            $availableFrom = $time
            $availableEvidence = $transition.evidence
            continue
        }

        if ($availableFrom -and $time -gt $availableFrom) {
            [pscustomobject]@{
                kind           = "available"
                availableFrom  = $availableFrom.ToString("o")
                availableUntil = $time.ToString("o")
                evidence       = @(
                    $availableEvidence
                    $transition.evidence
                )
            }
        }
        $availableFrom = $null
        $availableEvidence = $null
        if (-not $unavailable) {
            $unavailable = $transition
        }
    }
    if ($availableFrom -and $Through -gt $availableFrom) {
        [pscustomobject]@{
            kind           = "available"
            availableFrom  = $availableFrom.ToString("o")
            availableUntil = $Through.ToString("o")
            evidence       = @($availableEvidence)
        }
    }
}

function ConvertFrom-QuotaWakePowerTroubleshooterXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Xml
    )

    $eventXml = [xml]$Xml
    $eventData = @{}
    foreach ($dataNode in @($eventXml.Event.EventData.Data)) {
        $eventData[[string]$dataNode.Name] = [string]$dataNode.InnerText
    }
    $sleepTime = [DateTimeOffset]::Parse(
        [string]$eventData["SleepTime"]
    )
    $wakeTime = [DateTimeOffset]::Parse(
        [string]$eventData["WakeTime"]
    )
    if ($wakeTime -gt $sleepTime) {
        [pscustomobject]@{
            kind = "system_hibernating"
            time = $sleepTime.ToString("o")
            evidence = [pscustomobject]@{
                provider = "Microsoft-Windows-Power-Troubleshooter"
                eventId  = 1
                time     = $sleepTime.ToString("o")
            }
        }
    }
    [pscustomobject]@{
        kind = "available"
        time = $wakeTime.ToString("o")
        evidence = [pscustomobject]@{
            provider = "Microsoft-Windows-Power-Troubleshooter"
            eventId  = 1
            time     = $wakeTime.ToString("o")
        }
    }
}

function Get-QuotaWakeWindowsEvidenceIntervals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$From,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Through
    )

    $transitions = New-Object Collections.Generic.List[object]
    $bootTime = $null
    try {
        $operatingSystem = Get-CimInstance `
            Win32_OperatingSystem `
            -ErrorAction Stop
        $bootTime = [DateTimeOffset]$operatingSystem.LastBootUpTime
    }
    catch {
    }

    try {
        $oldestEvent = Get-WinEvent `
            -LogName "System" `
            -Oldest `
            -MaxEvents 1 `
            -ErrorAction Stop
        $coverageStart = [DateTimeOffset]$oldestEvent.TimeCreated
        if ($bootTime -and $bootTime -gt $coverageStart) {
            $coverageStart = $bootTime
        }
        if ($coverageStart -le $Through) {
            $transitions.Add([pscustomobject]@{
                kind = "available"
                time = $coverageStart.ToString("o")
                evidence = [pscustomobject]@{
                    provider = "SystemEventLog"
                    eventId  = 0
                    time     = $coverageStart.ToString("o")
                }
            })
        }
        $eventErrors = @()
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = "System"
            StartTime = $From.LocalDateTime.AddDays(-1)
            EndTime   = $Through.LocalDateTime.AddMinutes(1)
            Id        = @(1, 12, 13, 42, 107, 6005, 6006)
        } -ErrorAction SilentlyContinue -ErrorVariable +eventErrors)
        $unexpectedEventErrors = @($eventErrors | Where-Object {
            $_.FullyQualifiedErrorId -notlike "NoMatchingEventsFound,*"
        })
        if ($unexpectedEventErrors.Count -gt 0) {
            throw "Windows System power events could not be read."
        }
        foreach ($event in $events) {
            $provider = [string]$event.ProviderName
            $kind = $null
            if (
                $event.Id -eq 1 -and
                $provider -eq "Microsoft-Windows-Power-Troubleshooter"
            ) {
                try {
                    foreach ($transition in @(
                        ConvertFrom-QuotaWakePowerTroubleshooterXml `
                            -Xml $event.ToXml()
                    )) {
                        $transitions.Add($transition)
                    }
                }
                catch {
                    throw "Windows power interval evidence could not be parsed."
                }
                continue
            }
            if (
                $event.Id -eq 42 -and
                $provider -eq "Microsoft-Windows-Kernel-Power"
            ) {
                $kind = "system_hibernating"
            }
            elseif (
                ($event.Id -eq 13 -and
                    $provider -eq "Microsoft-Windows-Kernel-General") -or
                ($event.Id -eq 6006 -and $provider -eq "EventLog")
            ) {
                $kind = "system_off"
            }
            elseif (
                ($event.Id -eq 12 -and
                    $provider -eq "Microsoft-Windows-Kernel-General") -or
                ($event.Id -eq 6005 -and $provider -eq "EventLog")
            ) {
                $kind = "available"
            }
            if (-not $kind) {
                continue
            }
            $eventTime = [DateTimeOffset]$event.TimeCreated
            $transitions.Add([pscustomobject]@{
                kind = $kind
                time = $eventTime.ToString("o")
                evidence = [pscustomobject]@{
                    provider = $provider
                    eventId  = [int]$event.Id
                    time     = $eventTime.ToString("o")
                }
            })
        }
    }
    catch {
        $transitions.Clear()
    }

    return @(ConvertTo-QuotaWakeEvidenceIntervals `
        -Transitions $transitions.ToArray() `
        -Through $Through)
}

function Group-QuotaWakeMissedSlots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ClassifiedSlots
    )

    $current = $null
    $previousSequence = $null
    foreach ($item in @($ClassifiedSlots)) {
        $reason = $item.reason
        $key = @(
            [string]$reason.code
            [string]$reason.confidence
            [string]$reason.unavailableFrom
            [string]$reason.availableAgainAt
            [string]$reason.availableFrom
            [string]$reason.availableUntil
        ) -join "|"
        $sequence = if ($item.PSObject.Properties["sequence"]) {
            [long]$item.sequence
        }
        elseif ($null -eq $previousSequence) {
            0
        }
        else {
            $previousSequence + 1
        }
        if (
            $null -eq $current -or
            $current.Key -cne $key -or
            ($null -ne $previousSequence -and
                $sequence -ne ($previousSequence + 1))
        ) {
            if ($null -ne $current) {
                Write-Output ([pscustomobject]@{
                    Slots  = $current.Slots.ToArray()
                    Reason = $current.Reason
                })
            }
            $current = [pscustomobject]@{
                Key    = $key
                Slots  = New-Object Collections.Generic.List[DateTimeOffset]
                Reason = $reason
            }
        }
        $current.Slots.Add([DateTimeOffset]$item.slot)
        $previousSequence = $sequence
    }
    if ($null -ne $current) {
        Write-Output ([pscustomobject]@{
            Slots  = $current.Slots.ToArray()
            Reason = $current.Reason
        })
    }
}

function Format-QuotaWakeNextRunMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$NextRunTime,

        [DateTime]$Now = (Get-Date)
    )

    if ($NextRunTime.Date -eq $Now.Date) {
        $day = "today"
    }
    elseif ($NextRunTime.Date -eq $Now.Date.AddDays(1)) {
        $day = "tomorrow"
    }
    else {
        $day = $NextRunTime.ToString("dddd, MMMM d")
    }
    return "Quota Wake is ready. Next run: $day at $($NextRunTime.ToString('h:mm tt'))."
}

function Get-OptionalInt64Property {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) {
        return [long]0
    }
    return [long]$property.Value
}

function ConvertFrom-ClaudeProbeOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output
    )

    try {
        $data = $Output | ConvertFrom-Json
    }
    catch {
        throw "Claude returned invalid structured output."
    }
    if (
        -not $data.PSObject.Properties["result"] -or
        -not $data.PSObject.Properties["usage"]
    ) {
        throw "Claude structured output did not include result and usage data."
    }
    $permissionDenials = @()
    if ($data.PSObject.Properties["permission_denials"]) {
        $permissionDenials = @($data.permission_denials)
    }
    if ($permissionDenials.Count -gt 0) {
        throw "Claude attempted an action during the no-action probe."
    }

    $modelProperty = $null
    if ($data.PSObject.Properties["modelUsage"]) {
        $modelProperty = $data.modelUsage.PSObject.Properties |
            Select-Object -First 1
    }
    $inputTokens = [long]$data.usage.input_tokens
    $cacheCreationTokens = Get-OptionalInt64Property `
        -InputObject $data.usage `
        -Name "cache_creation_input_tokens"
    $cacheReadTokens = Get-OptionalInt64Property `
        -InputObject $data.usage `
        -Name "cache_read_input_tokens"
    $outputTokens = [long]$data.usage.output_tokens
    [pscustomobject]@{
        text  = [string]$data.result
        model = if ($modelProperty) { $modelProperty.Name } else { $null }
        actionCount = 0
        usage = [pscustomobject]@{
            inputTokens              = $inputTokens
            cacheCreationInputTokens = $cacheCreationTokens
            cacheReadInputTokens     = $cacheReadTokens
            outputTokens             = $outputTokens
            totalTokens              = (
                $inputTokens +
                $cacheCreationTokens +
                $cacheReadTokens +
                $outputTokens
            )
            costUsd                  = if (
                $data.PSObject.Properties["total_cost_usd"]
            ) {
                [double]$data.total_cost_usd
            }
            else {
                $null
            }
        }
    }
}

function ConvertFrom-CodexProbeOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output,

        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    $events = New-Object Collections.Generic.List[object]
    foreach ($line in @($Output -split "\r?\n")) {
        if (-not $line.Trim()) {
            continue
        }
        try {
            $events.Add(($line | ConvertFrom-Json))
        }
        catch {
            throw "Codex returned invalid structured output."
        }
    }
    $messageEvents = @($events |
        Where-Object {
            $_.type -eq "item.completed" -and
            $_.item.type -eq "agent_message"
        })
    $usageEvents = @($events |
        Where-Object { $_.type -eq "turn.completed" })
    if ($messageEvents.Count -ne 1 -or $usageEvents.Count -ne 1) {
        throw "Codex structured output must contain exactly one result and usage event."
    }
    $messageEvent = $messageEvents[0]
    $usageEvent = $usageEvents[0]
    if (-not $usageEvent.usage) {
        throw "Codex structured output did not include result and usage data."
    }
    $actionEvents = @($events | Where-Object {
        (
            $_.type -eq "item.started" -or
            $_.type -eq "item.completed"
        ) -and
        $_.item -and
        $_.item.type -notin @("agent_message", "reasoning")
    })
    if ($actionEvents.Count -gt 0) {
        throw "Codex attempted an action during the no-action probe."
    }

    $inputTokens = [long]$usageEvent.usage.input_tokens
    $outputTokens = [long]$usageEvent.usage.output_tokens
    $cachedInputTokens = Get-OptionalInt64Property `
        -InputObject $usageEvent.usage `
        -Name "cached_input_tokens"
    $cacheWriteInputTokens = Get-OptionalInt64Property `
        -InputObject $usageEvent.usage `
        -Name "cache_write_input_tokens"
    $reasoningOutputTokens = Get-OptionalInt64Property `
        -InputObject $usageEvent.usage `
        -Name "reasoning_output_tokens"
    [pscustomobject]@{
        text  = [string]$messageEvent.item.text
        model = $Model
        actionCount = 0
        usage = [pscustomobject]@{
            inputTokens          = $inputTokens
            cachedInputTokens    = $cachedInputTokens
            cacheWriteInputTokens = $cacheWriteInputTokens
            outputTokens         = $outputTokens
            reasoningOutputTokens = $reasoningOutputTokens
            totalTokens          = $inputTokens + $outputTokens
            costUsd              = $null
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
    "Get-QuotaWakeScheduledTaskArguments",
    "Get-QuotaWakeScheduledTaskAction",
    "Assert-QuotaWakeTaskName",
    "Test-QuotaWakeScheduledTaskOwnership",
    "Resolve-CommandPath",
    "Resolve-CodexCommandPath",
    "Get-DefaultInstallRoot",
    "Get-QuotaWakeOwnershipMarkerPath",
    "Test-QuotaWakeInstallOwnership",
    "Test-ExactHi",
    "Get-AgentSetupHelp",
    "Resolve-AgentSelection",
    "Get-AgentFailureGuidance",
    "Resolve-AgentProcessPath",
    "Get-AgentProcessSpecifications",
    "Start-HiddenProcess",
    "Stop-QuotaWakeProcessTree",
    "Complete-HiddenProcess",
    "Write-AtomicUtf8File",
    "New-QuotaWakeRunDirectory",
    "Test-FailureNotificationEnabled",
    "ConvertTo-QuotaWakeTime",
    "Get-QuotaWakeDailyRunTimes",
    "New-QuotaWakeSchedule",
    "Get-QuotaWakeExpectedSlots",
    "Get-QuotaWakeNextExpectedSlot",
    "Get-QuotaWakeSlotKey",
    "Get-QuotaWakeInvocation",
    "Get-QuotaWakeMissReason",
    "ConvertTo-QuotaWakeEvidenceIntervals",
    "ConvertFrom-QuotaWakePowerTroubleshooterXml",
    "Get-QuotaWakeWindowsEvidenceIntervals",
    "Group-QuotaWakeMissedSlots",
    "Format-QuotaWakeNextRunMessage",
    "ConvertFrom-ClaudeProbeOutput",
    "ConvertFrom-CodexProbeOutput",
    "Show-QuotaWakeFailureNotification"
)
