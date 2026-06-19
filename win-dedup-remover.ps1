<#
.SYNOPSIS
    Fully unoptimizes (rehydrates) a Data Deduplication volume and reclaims its dedup store.

.DESCRIPTION
    Resets the Deduplication service, then runs a controlled dedup workflow on a target
    volume:
        1. Enable dedup (Backup usage) and run an initial Garbage Collection.
        2. Disable dedup, then loop Unoptimization + Garbage Collection until
           unoptimization is 100% complete (no optimized files remain).
        3. Run a final full Garbage Collection and stop any remaining dedup jobs.
    Progress is logged to the console and optionally to a log file. A final storage
    footprint report is produced and scheduled dedup tasks are re-enabled.

.NOTES
    Requires: Data Deduplication feature (Deduplication PowerShell module), administrator rights.
    Run from an elevated PowerShell 7+ session.

.EXAMPLE
    .\Unoptimize.ps1
    Runs the full unoptimization workflow against the configured target drive.
#>

#Requires -Version 7.0
#Requires -RunAsAdministrator

# ==============================================================================
# CONFIGURATION CONSTANTS & CONTROLS
# ==============================================================================
$TARGET_DRIVE  = "D"                          # Target drive letter (do NOT include a colon)
$LOOP_INTERVAL = 300                          # Status poll interval in seconds (default: 5 minutes)
$MIN_FREE_SPACE_GB = 500                      # Stop unoptimization if free space drops below this threshold
$LOW_SPACE_COOLDOWN_SECONDS = 300             # Cooldown only when unoptimization stops for low free space

# Logging features
$ENABLE_LOGGING = $true                       # $true to write to a log file, $false to skip
$LOG_FILE_PATH  = "C:\DedupRemovalLog.txt"    # Log file destination path

# Derived variables
$DriveVolume   = "$($TARGET_DRIVE):"
$LogicalDiskId = "$($TARGET_DRIVE):"

# ==============================================================================
# 1. HELPER FUNCTIONS
# ==============================================================================

function Write-LogMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Color = "White"
    )

    Write-Host $Message -ForegroundColor $Color

    if ($ENABLE_LOGGING) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $LOG_FILE_PATH -Append -Encoding utf8
    }
}

function Get-BracketedDateTime {
    <#
    .SYNOPSIS
        Returns the current date and time enclosed in square brackets.
    .DESCRIPTION
        By default, returns local time in the format [YYYY-MM-DD HH:MM:SS].
        Use -Utc switch to return UTC time instead.
    .PARAMETER Utc
        If specified, returns the date/time in UTC.
    .EXAMPLE
        Get-BracketedDateTime
        Output: [2026-06-15 14:45:12]
    .EXAMPLE
        Get-BracketedDateTime -Utc
        Output: [2026-06-15 12:45:12]
    #>
    param (
        [switch]$Utc
    )

    try {
        $now = if ($Utc) { Get-Date -AsUTC } else { Get-Date }
        return "[{0}]" -f ($now.ToString("yyyy-MM-dd HH:mm:ss"))
    }
    catch {
        Write-Error "Failed to generate bracketed date/time: $_"
    }
}

function Get-DiskAndDedupStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$DriveId
    )

    $diskFree = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$DriveId'" |
        Select-Object DeviceID,
            @{ Name = "FreeSpace(TB)"; Expression = { [math]::Round($_.FreeSpace / 1TB, 2) } }

    $progress = Get-DedupJob | Select-Object -ExpandProperty Progress -ErrorAction SilentlyContinue
    if ($null -eq $progress) { $progress = "No active job" }

    $statusMsg = "$Prefix | Progress: $progress | $DriveId Free: $($diskFree.'FreeSpace(TB)') TB"
    Write-LogMessage -Message $statusMsg -Color Cyan
}

function Watch-DedupJob {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JobPrefix,

        [Parameter(Mandatory = $true)]
        [string]$Volume,

        [Parameter(Mandatory = $true)]
        [string]$DriveId,

        [int]$IntervalSeconds = 300
    )

    while (Get-DedupJob -Volume $Volume -ErrorAction SilentlyContinue) {
        $dt = Get-BracketedDateTime
        Get-DiskAndDedupStatus -Prefix "$dt | $JobPrefix" -DriveId $DriveId
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Get-FreeSpaceGB {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DriveId
    )

    $diskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$DriveId'"
    if ($null -eq $diskInfo) {
        throw "Unable to read disk info for $DriveId"
    }

    return [math]::Round($diskInfo.FreeSpace / 1GB, 2)
}

function Watch-UnoptimizationWithFreeSpaceGuard {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JobPrefix,

        [Parameter(Mandatory = $true)]
        [string]$Volume,

        [Parameter(Mandatory = $true)]
        [string]$DriveId,

        [Parameter(Mandatory = $true)]
        [double]$MinimumFreeSpaceGB,

        [int]$IntervalSeconds = 300
    )

    $stoppedForLowSpace = $false

    while (Get-DedupJob -Volume $Volume -ErrorAction SilentlyContinue) {
        $currentFreeGB = Get-FreeSpaceGB -DriveId $DriveId
        $dt = Get-BracketedDateTime
        Get-DiskAndDedupStatus -Prefix "$dt | $JobPrefix | Free: $currentFreeGB GB" -DriveId $DriveId

        if ($currentFreeGB -lt $MinimumFreeSpaceGB) {
            Write-LogMessage -Message "Free space dropped below threshold ($currentFreeGB GB < $MinimumFreeSpaceGB GB). Stopping unoptimization job." -Color Red
            Stop-DedupJob -Volume $Volume -ErrorAction SilentlyContinue
            $stoppedForLowSpace = $true
            break
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    return $stoppedForLowSpace
}

function Get-UnoptimizationComplete {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Volume
    )

    # Unoptimization is considered 100% complete when no optimized files
    # remain on the volume (nothing left to expand).
    $status = Get-DedupStatus -Volume $Volume -ErrorAction SilentlyContinue
    if ($null -eq $status) {
        # No dedup status reported -> nothing optimized on the volume.
        return $true
    }

    $optimizedFiles = [int64]($status.OptimizedFilesCount)
    Write-LogMessage -Message "Dedup status for ${Volume}: OptimizedFilesCount = $optimizedFiles, SavedSpace = $([math]::Round($status.SavedSpace / 1GB, 2)) GB" -Color Gray

    return ($optimizedFiles -le 0)
}

# ==============================================================================
# 2. INITIALIZATION, CAPTURE INITIAL STATE & SERVICE RESET
# ==============================================================================

if ($ENABLE_LOGGING) {
    "--- DEDUP REMOVAL EXECUTION STARTED ---" | Out-File -FilePath $LOG_FILE_PATH -Create -Encoding utf8
    Write-LogMessage -Message "Logging enabled. Outputting to: $LOG_FILE_PATH" -Color Gray
}

$initialDiskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$LogicalDiskId'"
$initialFreeTB   = [math]::Round($initialDiskInfo.FreeSpace / 1TB, 4)
$initialUsedTB   = [math]::Round(($initialDiskInfo.Size - $initialDiskInfo.FreeSpace) / 1TB, 4)

Write-LogMessage -Message "Step 1: Disabling scheduled deduplication tasks..." -Color Yellow
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Deduplication\" | Disable-ScheduledTask

Write-LogMessage -Message "Step 2: Resetting Deduplication service and killing frozen tasks..." -Color Yellow
Stop-Process -Name fsdmhost -Force -ErrorAction SilentlyContinue
taskkill /f /fi "SERVICES eq ddpsvc" 2>$null
Start-Sleep -Seconds 5

Start-Service -Name ddpsvc

# ==============================================================================
# 3. DEDUP UNOPTIMIZATION WORKFLOW
# ==============================================================================

Write-LogMessage -Message "Step 3: Enabling dedup volume on $DriveVolume using Backup usage type..." -Color Yellow
Enable-DedupVolume -Volume $DriveVolume -UsageType Backup

Write-LogMessage -Message "Step 4: Running initial high-priority Garbage Collection (memory cap 75)..." -Color Yellow
Start-DedupJob -Volume $DriveVolume -Type GarbageCollection -Priority High -Memory 75
Watch-DedupJob -JobPrefix "GarbageCollection" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL

Write-LogMessage -Message "Sleeping 5 minutes..." -Color Gray
Start-Sleep -Seconds 300

Write-LogMessage -Message "Step 5: Disabling dedup on $DriveVolume before unoptimization loop..." -Color Yellow
Disable-DedupVolume -Volume $DriveVolume

Write-LogMessage -Message "Sleeping 5 minutes..." -Color Gray
Start-Sleep -Seconds 300

Write-LogMessage -Message "Step 6: Looping Unoptimization + Garbage Collection until unoptimization reaches 100%..." -Color Yellow
$unoptPass = 0
do {
    $unoptPass++

    Write-LogMessage -Message "Pass $unoptPass - Starting Unoptimization run..." -Color Yellow
    Disable-DedupVolume -Volume $DriveVolume
    Start-Sleep -Seconds 60
    Start-DedupJob -Volume $DriveVolume -Type Unoptimization -Preempt
    $stoppedForLowSpace = Watch-UnoptimizationWithFreeSpaceGuard -JobPrefix "Unoptimization (Pass $unoptPass)" -Volume $DriveVolume -DriveId $LogicalDiskId -MinimumFreeSpaceGB $MIN_FREE_SPACE_GB -IntervalSeconds $LOOP_INTERVAL

    if ($stoppedForLowSpace) {
        Write-LogMessage -Message "Pass $unoptPass - Unoptimization was paused because free space is below $MIN_FREE_SPACE_GB GB." -Color Yellow
        Write-LogMessage -Message "Pass $unoptPass - Cooling down for $LOW_SPACE_COOLDOWN_SECONDS seconds before Garbage Collection..." -Color Gray
        Start-Sleep -Seconds $LOW_SPACE_COOLDOWN_SECONDS
    }

    Write-LogMessage -Message "Pass $unoptPass - Running Garbage Collection..." -Color Yellow
    Enable-DedupVolume -Volume $DriveVolume -UsageType Backup
    Start-DedupJob -Volume $DriveVolume -Type GarbageCollection -Priority High -Memory 75
    Watch-DedupJob -JobPrefix "GarbageCollection (Pass $unoptPass)" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL

    $isComplete = Get-UnoptimizationComplete -Volume $DriveVolume
    if ($isComplete) {
        Write-LogMessage -Message "Unoptimization reached 100% (no optimized files remain) after $unoptPass pass(es)." -Color Green
    }
    else {
        Write-LogMessage -Message "Unoptimization not yet complete. Starting another Unoptimization + GC pass..." -Color Yellow
    }
} while (-not $isComplete)

Write-LogMessage -Message "Step 7: Running final full Garbage Collection..." -Color Yellow
Enable-DedupVolume -Volume $DriveVolume -UsageType Backup
Start-DedupJob -Volume $DriveVolume -Type GarbageCollection -Full -Priority High -Memory 75
Watch-DedupJob -JobPrefix "GarbageCollection (Full Final)" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL

Write-LogMessage -Message "Step 8: Stopping any remaining dedup job handles..." -Color Yellow
Stop-DedupJob -Volume $DriveVolume -ErrorAction SilentlyContinue
Disable-DedupVolume -Volume $DriveVolume

# ==============================================================================
# 4. FINAL STORAGE FOOTPRINT REPORT
# ==============================================================================

$finalDiskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$LogicalDiskId'"
$finalFreeTB   = [math]::Round($finalDiskInfo.FreeSpace / 1TB, 4)
$finalUsedTB   = [math]::Round(($finalDiskInfo.Size - $finalDiskInfo.FreeSpace) / 1TB, 4)

$spaceDifference = [math]::Round($finalFreeTB - $initialFreeTB, 4)

Write-LogMessage -Message "`n==================================================" -Color Green
Write-LogMessage -Message "     FINAL STORAGE RECLAIM REPORT ($LogicalDiskId Volume)" -Color Green
Write-LogMessage -Message "==================================================" -Color Green
Write-LogMessage -Message "Initial Free Space : $initialFreeTB TB" -Color Gray
Write-LogMessage -Message "Final Free Space   : $finalFreeTB TB" -Color Gray
Write-LogMessage -Message "Initial Used Space : $initialUsedTB TB" -Color Gray
Write-LogMessage -Message "Final Used Space   : $finalUsedTB TB" -Color Gray
Write-LogMessage -Message "--------------------------------------------------" -Color Green

if ($spaceDifference -ge 0) {
    Write-LogMessage -Message "Storage Reclaimed: $spaceDifference TB" -Color Green
}
else {
    $absDiff = [math]::Abs($spaceDifference)
    Write-LogMessage -Message "Storage Footprint Increased By: $absDiff TB (Expected due to unoptimization expansion)" -Color Yellow
}
Write-LogMessage -Message "==================================================`n" -Color Green

# ==============================================================================
# 5. WRAP-UP
# ==============================================================================

Write-LogMessage -Message "Process finished. Re-enabling scheduled deduplication tasks." -Color Green
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Deduplication\" | Enable-ScheduledTask

<#
# Useful diagnostics:
Get-DedupStatus -Volume "D:" | Select-Object -Property *
Get-ChildItem -Path "D:\System Volume Information\Dedup\State" -Recurse -Force | Measure-Object -Property Length -Sum
Get-Counter -ListSet *Dedup* | Select-Object CounterSetName, Paths
#>
