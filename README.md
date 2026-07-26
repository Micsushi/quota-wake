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
`QuotaWake` task.

Optional settings:

```powershell
.\setup.ps1 -Agents Claude,Codex -IntervalHours 5 -TimeoutSeconds 90
```

If a selected CLI is missing, signed out, times out, or returns an unexpected
response, setup explains what to check and preserves the existing installation.

## Check status

```powershell
.\status.ps1 | Format-List
```

## Uninstall

```powershell
.\uninstall.ps1
```

Add `-RemoveData` to also delete local logs and configuration.

Quota Wake stores no credentials. The computer must be on or asleep; a powered-off
computer cannot run a local scheduled task.
