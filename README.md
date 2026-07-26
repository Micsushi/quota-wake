# Quota Wake

A hidden Windows task that makes minimal Claude Code and Codex calls every five hours.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1
- Signed-in Claude Code and Codex CLIs

## Install

```powershell
.\setup.ps1
```

Setup verifies both CLIs, installs the runtime under `%LOCALAPPDATA%\QuotaWake`,
and registers one hidden `QuotaWake` task. Rerun it anytime to update or repair
the installation.

Optional settings:

```powershell
.\setup.ps1 -IntervalHours 5 -StartDelayMinutes 1 -TimeoutSeconds 90
```

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
