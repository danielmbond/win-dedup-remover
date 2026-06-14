# Windows Data Deduplication Decommissioning Tool

PowerShell script designed to clean up D:\System Volume Information\Dedup and uninstall the Windows Data Deduplication (`FS-Data-Deduplication`) feature from a targeted storage volume.

Expanding deduplicated data back to its original footprint is a high-risk operational task. If structural queues jam or a volume runs out of space, it can result in catastrophic data data corruption or frozen volumes. This script mitigates those risks by introducing a rigid, multi-step safety pipeline that handles pre-cleanup, diagnostic health monitoring, storage boundary calculations, and post-removal reporting.

---

## 🛠️ Features & Execution Pipeline

The script safely offloads and uninstalls deduplication by executing the following strict phase pipeline:

1. **Service & Task Isolation:** Disables scheduled Windows deduplication tasks and force-resets the `ddpsvc` service to clear out any frozen host tasks (`fsdmhost`).
2. **Pre-Cleanup Queue Purge:** Runs a high-priority structural integrity `Scrubbing` job and an initial `GarbageCollection` pass to clear easily reclaimable chunks and optimize the database *before* expansion.
3. **Hardware & Capacity Guardrails:** * Queries storage reliability counters for active disk read/write errors.
    * Enforces a **50% free space safety threshold check** to prevent catastrophic out-of-space lockups during re-inflation.
4. **Unoptimization Engine:** Runs a full volume `Unoptimization` job to expand files, executes a deep final garbage collection, and disables the deduplication volume configuration.
5. **Role De-provisioning:** Completely uninstalls the `FS-Data-Deduplication` Windows Server role.
6. **Delta Reporting:** Generates a definitive final storage footprint report comparing initial vs. final space.
7. **Graceful Reboot:** Schedules a forced 5-minute system restart to cleanly flush the storage stack and finalize role removal.

---

## ⚙️ Configuration

Before executing, open the script and adjust the configuration constants at the top of the file to fit your environment:

| Constant | Default Value | Description |
| :--- | :--- | :--- |
| `$TARGET_DRIVE` | `"D"` | Target drive letter (do **not** include a colon). |
| `$LOOP_INTERVAL` | `300` | Loop wait time in seconds (5 minutes) used to poll active job statuses. |
| `$ENABLE_LOGGING`| `$true` | Set to `$true` to output a persistent log file; `$false` to skip. |
| `$LOG_FILE_PATH` | `"C:\DedupRemovalLog.txt"` | Full destination path for the timestamped execution log. |
| `$FORCE_UNOPT` | `$false` | Set to `$true` to bypass the 50% free space safety warning. |

---

## 🚀 Usage Instructions

### Prerequisites
* **Windows Server** with an active Data Deduplication volume.
* **Administrator Privileges:** PowerShell must be opened via "Run as Administrator".

### Execution
1. Download or clone this repository.
2. Configure your `$TARGET_DRIVE` and preferences at the top of the script.
3. Open an elevated PowerShell terminal and execute the script:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\Unoptimize-DedupVolume.ps1
