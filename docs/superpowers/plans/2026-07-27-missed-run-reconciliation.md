# Missed-Run Reconciliation Implementation Plan

> REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Record grouped evidence-backed history for scheduled slots missed while the computer was unavailable, while ensuring late or manually started invocations never run quota probes.

**Architecture:** Store an explicit versioned schedule in the installed configuration. Pure scheduling helpers derive stable slot identities and classify invocations. The worker gates every invocation against the current slot, serializes valid runs with an install-scoped lock, reconciles earlier absent slots from Windows power evidence, appends grouped JSONL records, and then runs probes. Status reads both legacy and current history and exposes executed, missed, and pending counts.

**Tech Stack:** Windows PowerShell 5.1, Task Scheduler cmdlets, Windows System event log, JSON/JSONL, script-based tests.

---

### Task 1: Add schedule and invocation primitives

**Files:**
- Modify: `src/QuotaWake.psm1`
- Test: `tests/unit.ps1`

1. Add failing unit tests for stable schedule IDs and slot keys.
2. Add failing unit tests for continuous and daily slot enumeration, including multiple-day gaps.
3. Add failing unit tests for on-time, early, late, and manual invocation classification with the two-minute grace window.
4. Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests/unit.ps1` and confirm the new assertions fail for missing functions.
5. Implement the smallest pure helpers required by the tests.
6. Re-run the unit suite and confirm it passes.

### Task 2: Add missed-slot grouping and evidence classification

**Files:**
- Modify: `src/QuotaWake.psm1`
- Test: `tests/unit.ps1`

1. Add failing tests for history slot extraction and exclusion of already recorded slots.
2. Add failing tests that classify normalized hibernation, shutdown, scheduler-no-start, and unknown evidence.
3. Add failing tests that group consecutive missed slots only when reason and evidence interval match.
4. Run the unit suite and observe the expected failures.
5. Implement pure classification and grouping helpers plus a Windows System-event adapter that returns normalized evidence without persisting event messages.
6. Re-run the unit suite and confirm it passes.

### Task 3: Install schema v4 schedules and strict task settings

**Files:**
- Modify: `setup.ps1`
- Modify: `tests/integration.ps1`
- Modify: `tests/safety.ps1`

1. Add failing integration assertions for schema version 4, schedule metadata, stable generation reuse, and a new generation when the schedule changes.
2. Add failing assertions that production tasks explicitly disable demand starts, missed-start replay, and overlapping instances.
3. Add a test-only setup switch that permits demand starts for temporary integration tasks.
4. Run the non-live integration and safety suites and observe the expected failures.
5. Update setup to build and persist the schedule, reuse an unchanged v4 generation, and configure the task settings.
6. Re-run the integration and safety suites and confirm they pass.

### Task 4: Gate worker runs and reconcile missed history

**Files:**
- Modify: `src/run-quota-wake.ps1`
- Modify: `tests/worker-failures.ps1`
- Add: `tests/worker-scheduling.ps1`

1. Add worker tests proving late/manual invocations exit zero without launching an agent or writing history.
2. Add worker tests proving an on-time run records schema-v4 execution fields.
3. Add worker tests proving one legitimate run backfills many absent slots into one grouped missed record and never invokes probes for missed slots.
4. Add a concurrency test proving a second valid invocation exits without overlapping the first.
5. Run the new worker suite and observe the expected failures.
6. Refactor worker startup so valid configuration and invocation gating happen before runtime work.
7. Acquire an install-scoped exclusive lock, reconcile earlier slots, append grouped missed records, execute only the current slot, and persist the v4 executed record.
8. Preserve deterministic preflight failure reporting and legacy schema-v3 compatibility.
9. Re-run worker scheduling and failure suites and confirm they pass.

### Task 5: Extend status and documentation

**Files:**
- Modify: `status.ps1`
- Modify: `README.md`
- Modify: `tests/integration.ps1`

1. Add failing status assertions for executed success/failure counts, missed slot/group counts, latest missed reason/time, pending missed slots, last successful slot, and next scheduled slot.
2. Run the integration suite and observe the expected failures.
3. Implement mixed schema-v3/v4 history parsing and schedule-derived status fields.
4. Document skip semantics, grouped backfill, reason confidence, strict task settings, and upgrade behavior.
5. Re-run integration tests and confirm they pass.

### Task 6: Full verification and final review

**Files:**
- Review: all changed files

1. Run all non-live suites:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/unit.ps1`
   - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/worker-failures.ps1`
   - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/worker-scheduling.ps1`
   - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/safety.ps1`
   - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/integration.ps1`
2. Run a temporary Task Scheduler verification with demand starts enabled only for the temporary test task.
3. Do not update the real installed task or run live model probes without separate deployment authorization.
4. Inspect `git diff --check`, the full diff, final HEAD, and status.
5. Re-review for races, DST behavior, mixed-history compatibility, unnecessary abstractions, and accidental tracked artifacts.
