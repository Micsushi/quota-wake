# Quota Wake

A hidden Windows task that makes minimal Claude Code or Codex calls every five hours.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1
- At least one signed-in Claude Code or Codex CLI

## Install

```powershell
.\setup.ps1 -Agents Claude
.\setup.ps1 -Agents Codex
.\setup.ps1 -Agents Claude,Codex
```

`-Agents` is required. Setup verifies only the selected agents, remembers the
selection, installs under `%LOCALAPPDATA%\QuotaWake`, and registers one hidden
`QuotaWake` task. Defaults are Claude Haiku and GPT-5.4 mini.

## Schedule modes

Without a start time, the first run is in one minute and repeats continuously:

```powershell
.\setup.ps1 -Agents Claude,Codex -IntervalHours 5 -TimeoutSeconds 90
```

With a local start time, runs reset each day and stop before midnight:

```powershell
.\setup.ps1 -Agents Claude,Codex -StartTime 5
```

For `-StartTime 5`, runs are 5 AM, 10 AM, 3 PM, and 8 PM. Missed slots
are skipped. Setup always reports the next scheduled run.

If a selected CLI is missing, signed out, times out, or returns an unexpected
response, setup explains what to check and preserves the existing installation.

## Check status

```powershell
$status = .\status.ps1
$status | Format-List
$status.ClaudeUsage
$status.CodexUsage
```

Successful runs require exact `hi` output and token-usage metadata. Normalized
usage, model, timing, and zero-action proof are saved locally; raw CLI payloads
are not. Each probe runs from an empty directory with tools and project/user
instructions disabled for that call only. Claude's system prompt and Codex's
base instructions are replaced with probe-only instructions.

## Uninstall

```powershell
.\uninstall.ps1
```

Add `-RemoveData` to also delete local logs and configuration.

Quota Wake stores no credentials. Sleeping computers may wake for a scheduled
run. Powered-off computers skip missed slots.
