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

### Isolated Claude login

Use a separate Claude profile so scheduled probes do not share OAuth refresh
tokens with Claude Code in VS Code:

```powershell
$profile = "$env:LOCALAPPDATA\QuotaWake\claude-profile"
$env:CLAUDE_CONFIG_DIR = $profile
claude auth login
.\setup.ps1 -Agents Claude,Codex -ClaudeConfigDir $profile
Remove-Item Env:\CLAUDE_CONFIG_DIR
```

This can use the same Claude account, but the second login creates a separate
OAuth token pair. Setup stores only the profile path and injects
`CLAUDE_CONFIG_DIR` into Claude probes. It does not copy or store credentials.

## Schedule modes

Without a start time, the first run is within two minutes and repeats continuously:

```powershell
.\setup.ps1 -Agents Claude,Codex -IntervalHours 5 -TimeoutSeconds 90
```

With a local start time, runs reset each day and stop before midnight:

```powershell
.\setup.ps1 -Agents Claude,Codex -StartTime 5
```

For `-StartTime 5`, runs are 5 AM, 10 AM, 3 PM, and 8 PM. Missed slots
are never replayed. Setup always reports the next scheduled run.

A production launch is accepted only during the two minutes after its exact
scheduled slot. Delayed startup/resume launches and manual demand starts do not
call either agent and do not write run history. The next legitimate scheduled
run compares the persisted schedule with history and records any earlier
missing slots.

Consecutive misses with the same evidence-backed cause are stored together in
one JSONL record, including every exact scheduled timestamp. Causes are
`system_hibernating`, `system_off`, `scheduler_did_not_start`, or `unknown`.
Missing Windows evidence remains `unknown`; it is not reported as proof that
the computer was off. Backfill is history-only and never makes model calls for
past slots.

If a selected CLI is missing, signed out, times out, or returns an unexpected
response, setup explains what to check and preserves the existing installation.

## Check status

```powershell
$status = .\status.ps1
$status | Format-List
$status.ClaudeUsage
$status.CodexUsage
$status | Select-Object SuccessfulExecutedSlots,FailedExecutedSlots,MissedSlots,MissedGroups,PendingMissedSlots,LastMissedSlot,LastMissedReason,LastSuccessfulSlot,NextScheduledSlot
```

Successful runs require exact `hi` output and token-usage metadata. Normalized
usage, model, timing, and zero-action proof are saved locally; raw CLI payloads
are not. Each probe runs from an empty directory with tools and project/user
instructions disabled for that call only. Claude's system prompt and Codex's
base instructions are replaced with probe-only instructions.

`OwnershipConflict` reports a same-named Scheduled Task that Quota Wake will
not replace or remove. `InstallOwned` confirms the local files carry matching
ownership proof.

Re-running setup with the same schedule preserves its schedule generation.
Changing the mode, interval, daily times, or local time zone begins a new
generation. A rerun within 30 seconds of an expected slot also begins a new
generation at the next safe slot, preventing setup itself from manufacturing a
miss. Older schedule definitions cannot invent new missed slots.
Schema-version-3 run history remains readable but is not retroactively
converted.

## Uninstall

```powershell
.\uninstall.ps1
```

Add `-RemoveData` to also delete local logs and configuration.

Recursive removal requires the ownership file written by current setup
versions. Rerun setup once before using `-RemoveData` on an older installation.

## Tests

```powershell
.\tests\unit.ps1
.\tests\worker-failures.ps1
.\tests\worker-scheduling.ps1
.\tests\safety.ps1
.\tests\integration.ps1
```

Unit and worker tests do not call either model. Safety and non-live integration
tests create uniquely named temporary Scheduled Tasks and remove them. The
integration suite requires both CLIs to cover every supported selection.
`.\tests\integration.ps1 -Live` additionally makes real Claude and Codex calls
and verifies the hidden scheduled execution. Test runs suppress desktop failure
notifications, including tests that deliberately use malformed configuration.

Quota Wake stores no credentials. Sleeping computers may wake for a scheduled
run. A powered-off or hibernating computer skips the model call; the missed
time is recorded during a later legitimate run when retained Windows evidence
supports the cause.
