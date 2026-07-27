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
        [string]$ConfigPath
    )

    return Join-CommandLineArguments -ArgumentList @(
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
        [string]$TaskName
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
        foreach ($name in @("config.json", "QuotaWake.psm1", "run-quota-wake.ps1")) {
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
            [pscustomobject]@{
                Name         = "Claude"
                FilePath     = [string]$Config.claude.path
                Model        = [string]$Config.claude.model
                WorkingDirectory = $WorkingDirectory
                OutputFormat = "ClaudeJson"
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
    "Get-AgentProcessSpecifications",
    "Start-HiddenProcess",
    "Stop-QuotaWakeProcessTree",
    "Complete-HiddenProcess",
    "Write-AtomicUtf8File",
    "New-QuotaWakeRunDirectory",
    "Test-FailureNotificationEnabled",
    "ConvertTo-QuotaWakeTime",
    "Get-QuotaWakeDailyRunTimes",
    "Format-QuotaWakeNextRunMessage",
    "ConvertFrom-ClaudeProbeOutput",
    "ConvertFrom-CodexProbeOutput",
    "Show-QuotaWakeFailureNotification"
)
