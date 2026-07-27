# Missed-run reconciliation design

## Goal

Record scheduled Quota Wake slots that did not execute while guaranteeing that
Claude and Codex are called only by an on-time scheduled invocation.

Backfilling means writing history. It never means replaying model calls.

## Required behavior

- A production invocation is legitimate only when it starts within two minutes
  after an expected schedule slot.
- A late, startup, resume, or manual invocation outside that window exits
  successfully without running agents or changing run history.
- The next legitimate invocation reconstructs all earlier expected slots that
  have no executed or missed history.
- Contiguous missed slots with the same reason are stored as one JSONL record.
- A failed on-time probe is an executed failure, not a missed slot.
- Reconciliation is idempotent and cannot create duplicate slot records.
- Missing Windows evidence produces an `unknown` reason rather than an
  unsupported claim that the computer was off.

## Schedule identity

Setup writes a versioned schedule object into `config.json`:

```json
{
  "schedule": {
    "id": "generated schedule identifier",
    "mode": "Continuous",
    "effectiveFrom": "2026-07-27T13:39:27-06:00",
    "timeZoneId": "Mountain Standard Time",
    "intervalHours": 5
  }
}
```

Daily mode stores `dailyRunTimes` instead of `intervalHours`.

The schedule identifier changes whenever setup changes the mode, anchor,
interval, daily times, or time zone. Reconciliation never creates missed slots
from a previous schedule generation.

Every expected slot has this stable key:

```text
<schedule id>|<scheduled time in UTC>
```

## Invocation gate

The worker computes the most recent expected slot before doing any other
runtime work.

An invocation may reconcile and run probes only when:

```text
expected slot <= invocation time <= expected slot + 2 minutes
```

If the invocation is outside this window, the worker exits with code zero. It
does not create a run directory, start either CLI, write run history, or send a
failure notification.

The two-minute window permits ordinary Task Scheduler launch jitter without
allowing hours-late catch-up execution.

## Reconciliation

At the start of each legitimate invocation:

1. Acquire an install-scoped worker lock before reading or writing state.
2. Enumerate expected slots from the schedule's `effectiveFrom` through, but
   excluding, the current slot.
3. Read all slot keys represented by executed and missed history.
4. Select expected slots with no existing key.
5. Classify each missing slot using normalized Windows power evidence.
6. Group consecutive missing slots that have the same reason and evidence
   interval.
7. Append one JSONL record per group.
8. Execute the current slot normally and record its slot key.

History is the idempotency source. If the process crashes after appending a
missed group, the next run sees those slot keys and does not append them again.
The worker lock protects this read-check-append sequence independently of Task
Scheduler's `IgnoreNew` setting.

## Grouped missed record

Consecutive misses caused by one hibernation interval produce one JSONL
object. This abbreviated example contains three slots; a thirty-five-slot
outage uses the same object with thirty-five `scheduledSlots` entries:

```json
{
  "schemaVersion": 4,
  "recordType": "missed",
  "scheduleId": "schedule-identifier",
  "scheduledSlots": [
    "2026-07-28T03:39:27-06:00",
    "2026-07-28T08:39:27-06:00",
    "2026-07-28T13:39:27-06:00"
  ],
  "count": 3,
  "firstScheduledFor": "2026-07-28T03:39:27-06:00",
  "lastScheduledFor": "2026-07-28T13:39:27-06:00",
  "observedAt": "2026-07-28T18:39:29-06:00",
  "reason": {
    "code": "system_hibernating",
    "confidence": "confirmed",
    "unavailableFrom": "2026-07-28T01:10:00-06:00",
    "availableAgainAt": "2026-07-28T17:55:00-06:00",
    "evidence": [
      {
        "provider": "Microsoft-Windows-Kernel-Power",
        "eventId": 42,
        "time": "2026-07-28T01:10:00-06:00"
      },
      {
        "provider": "Microsoft-Windows-Power-Troubleshooter",
        "eventId": 1,
        "time": "2026-07-28T17:55:00-06:00"
      }
    ]
  }
}
```

The exact scheduled timestamps remain explicit even when they could be derived
from the first slot and interval. This makes the history self-contained and
avoids ambiguity across daylight-saving transitions.

Separate groups are written when the reason changes. For example, hibernation
followed by an unexplained scheduler failure produces two records.

## Reason classification

Windows events provide explanation, not the source of expected slots.

Normalized reason codes:

- `system_hibernating`: a sleep/hibernate interval contains the slot.
- `system_off`: a shutdown-to-boot interval contains the slot.
- `scheduler_did_not_start`: the machine was available but no execution exists.
- `unknown`: retained evidence cannot establish the cause.

Only event identifiers, normalized times, and provider names are stored. Raw
Windows event messages are not copied into Quota Wake history.

## Executed records

Executed schema-version-4 records add:

```json
{
  "recordType": "executed",
  "scheduleId": "schedule-identifier",
  "slotKey": "schedule-identifier|2026-07-28T19:39:27Z",
  "scheduledFor": "2026-07-28T13:39:27-06:00",
  "startedAt": "2026-07-28T13:39:28-06:00",
  "outcome": "succeeded"
}
```

`outcome` is `succeeded` or `failed`. Existing agent results, usage, timing,
and zero-action evidence remain unchanged.

## Task Scheduler hardening

The production task uses:

- `StartWhenAvailable = false`
- `AllowDemandStart = false`
- `WakeToRun = true`
- `MultipleInstances = IgnoreNew`

Temporary integration tasks remain demand-startable. The production task is
not used for manual live verification.

The worker's invocation gate remains authoritative even if Windows records or
delivers an unexpected late trigger.

## Status

`status.ps1` reports:

- successful executed slots
- failed executed slots
- missed slot count
- missed group count
- pending missing slots not yet persisted
- last missed slot and reason
- last successful slot
- next scheduled slot

Pending misses are calculated without modifying history. They become durable
on the next legitimate run.

## Upgrade behavior

Installing schema version 4 creates a new schedule generation beginning at the
new task's first scheduled slot. Existing schema-version-3 history remains
readable but is not retroactively converted or used to invent earlier missed
slots.

This avoids misclassifying historical manual and integration runs that lack a
stable scheduled-slot identity.

## Verification

Tests must prove:

- zero, one, and thirty-five missed slots are reconstructed correctly
- contiguous same-reason misses create one JSONL object
- reason changes split groups
- repeated reconciliation creates no duplicates
- daylight-saving transitions preserve exact expected timestamps
- schedule changes do not backfill the previous generation
- an on-time invocation runs the selected agents once
- a launch just outside the grace window runs no agents and writes no history
- a startup-hours-late launch runs no agents
- an on-time agent failure is recorded as `executed` and `failed`
- status counts grouped slots rather than counting each group as one miss
- production task XML disables catch-up and demand starts
- temporary live integration tasks remain independently runnable
