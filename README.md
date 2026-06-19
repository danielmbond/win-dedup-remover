# win-dedup-remover.ps1

## Purpose
:\System Volume Information\Dedup is huge.
`win-dedup-remover.ps1` runs a controlled Data Deduplication removal workflow for a target volume.

It is designed to:
- stop scheduled dedup tasks during execution,
- run unoptimization in passes,
- stop unoptimization if free space drops below a threshold,
- run garbage collection to completion between unoptimization passes,         
- run a final full garbage collection,
- report before/after storage usage,
- re-enable scheduled dedup tasks when finished.

## File
- `PowerShell/Disk/Unoptimize.ps1`

## Requirements
- Windows Server with Data Deduplication feature installed.
- PowerShell 7.0+.
- Elevated session (Run as Administrator).
- Permissions to run dedup cmdlets and manage scheduled tasks/services.

The script also declares:
- `#Requires -Version 7.0`
- `#Requires -RunAsAdministrator`

## Configuration
Edit these values at the top of the script:

- `$TARGET_DRIVE`
  - Drive letter only (for example: `D`)
- `$LOOP_INTERVAL`
  - Polling interval in seconds while watching dedup jobs
- `$MIN_FREE_SPACE_GB`
  - Unoptimization is stopped when free space is below this value
- `$LOW_SPACE_COOLDOWN_SECONDS`
  - Delay applied only when unoptimization was stopped due to low free space
- `$ENABLE_LOGGING`
  - Enables/disables file logging
- `$LOG_FILE_PATH`
  - Output log file path

## What The Script Does
1. Disables scheduled deduplication tasks.
2. Resets dedup service state.
3. Enables dedup for the target volume (`Backup` usage type).
4. Runs initial garbage collection.
5. Disables dedup before entering the unoptimization loop.
6. Loop:
   - disables dedup,
   - starts unoptimization,
   - stops unoptimization if free space drops below `$MIN_FREE_SPACE_GB`,
   - optional cooldown,
   - enables dedup,
   - runs garbage collection to completion,
   - checks dedup status and repeats until unoptimization is complete.
7. Enables dedup and runs final full garbage collection.
8. Stops any remaining dedup job handles.
9. Disables dedup volume.
10. Prints final storage footprint report.
11. Re-enables scheduled deduplication tasks.

## Completion Logic
Unoptimization completion is determined by `Get-DedupStatus`:
- `OptimizedFilesCount <= 0` means no optimized files remain.

## Run
From an elevated PowerShell session:

```powershell
.\win-dedup-remover.ps1
```

## Output
- Console progress messages.
- Optional log file entries at `$LOG_FILE_PATH`.
- Final report values:
  - initial free/used TB,
  - final free/used TB,
  - net reclaimed (or increased) footprint.

## Notes
- The script intentionally toggles dedup state:
  - dedup is disabled before each unoptimization run,
  - dedup is enabled before each garbage collection run.
- If no dedup status is returned for the volume, the script treats unoptimization as complete.
