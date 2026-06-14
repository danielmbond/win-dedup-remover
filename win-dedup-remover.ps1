# ==============================================================================
# CONFIGURATION CONSTANTS & CONTROLS
# ==============================================================================
$TARGET_DRIVE     = "D"              # Target drive letter (Do not include a colon)
$LOOP_INTERVAL    = 300              # Loop wait time in seconds (Default: 5 minutes)

# Safety & Logging Features
$ENABLE_LOGGING   = $true            # Set to $true to output to a file, $false to skip
$LOG_FILE_PATH    = "C:\DedupRemovalLog.txt" # Log file destination path
$FORCE_UNOPT      = $false           # Set to $true to bypass the 50% free space warning

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
            @{Name="FreeSpace(TB)"; Expression={[math]::Round($_.FreeSpace / 1TB, 2)}}
    
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
        Get-DiskAndDedupStatus -Prefix $JobPrefix -DriveId $DriveId
        Start-Sleep -Seconds $IntervalSeconds
    }
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
# 3. PRE-CLEANUP QUEUE PURGE (SCRUBBING & INITIAL GC)
# ==============================================================================

Write-LogMessage -Message "Step 3: Running a high-priority structural integrity Scrubbing job on $DriveVolume..." -Color Yellow
Start-DedupJob -Volume $DriveVolume -Type Scrubbing -Priority High

Write-LogMessage -Message "Allowing scrubbing job to initialize, then stopping it to flush queue..." -Color Gray
Start-Sleep -Seconds 60
Stop-DedupJob -Volume $DriveVolume -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

Write-LogMessage -Message "Step 4: Launching standard Garbage Collection to clear easily reclaimable blocks..." -Color Yellow
Start-DedupJob -Volume $DriveVolume -Type GarbageCollection -Priority High
Watch-DedupJob -JobPrefix "GarbageCollection" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL

# ==============================================================================
# 4. DIAGNOSTIC PERFORMANCE CHECKS & SAFETY CHECKS
# ==============================================================================

Write-LogMessage -Message "`n--- Current Queue & Disk Health State ---" -Color Magenta
if ($ENABLE_LOGGING) { Get-DedupJob | Out-String | Out-File -FilePath $LOG_FILE_PATH -Append }
Get-DedupJob

$DiskNum = (Get-Partition -DriveLetter $TARGET_DRIVE).DiskNumber
$reliability = Get-Disk | Where-Object Number -eq $DiskNum | Get-StorageReliabilityCounter | Select-Object ReadErrorsTotal, WriteErrorsTotal
if ($ENABLE_LOGGING) { $reliability | Out-String | Out-File -FilePath $LOG_FILE_PATH -Append }
$reliability

Get-Counter -Counter "\LogicalDisk($LogicalDiskId)\Disk Reads/sec", "\LogicalDisk($LogicalDiskId)\Disk Writes/sec" -MaxSamples 2
Write-LogMessage -Message "----------------------------------------`n" -Color Magenta

$totalSpace = $initialDiskInfo.Size
$freeSpace  = $initialDiskInfo.FreeSpace

if ($null -ne $totalSpace -and $totalSpace -gt 0) {
    $freePercent = ($freeSpace / $totalSpace) * 100
    Write-LogMessage -Message "Drive $LogicalDiskId calculations: Total Space: $([math]::Round($totalSpace/1TB,2)) TB, Free Space: $([math]::Round($freeSpace/1TB,2)) TB ($([math]::Round($freePercent,2))% free)" -Color Gray
    
    if ($freePercent -lt 50) {
        Write-LogMessage -Message "⚠️ WARNING: Drive $LogicalDiskId has less than 50% free space ($([math]::Round($freePercent,2))% free)." -Color Red
        Write-LogMessage -Message "Expanding deduplicated files back to full size might consume all remaining storage!" -Color Red
        
        if ($FORCE_UNOPT) {
            Write-LogMessage -Message "Bypassing warning because `$FORCE_UNOPT is set to `$true." -Color DarkYellow
        } else {
            Write-LogMessage -Message "Prompting user for manual verification..." -Color Yellow
            $confirmation = Read-Host "Do you want to proceed with unoptimization anyway? (Type 'YES' to continue)"
            if ($confirmation -ne "YES") {
                Write-LogMessage -Message "❌ Execution aborted by user due to low free space thresholds." -Color Red
				Get-ScheduledTask -TaskPath "\Microsoft\Windows\Deduplication\" | Enable-ScheduledTask
				Disable-DedupVolume -Volume $DriveVolume
                Exit
            }
            Write-LogMessage -Message "User explicitly authorized unoptimization via console confirmation." -Color DarkYellow
        }
    }
}

# ==============================================================================
# 5. UNOPTIMIZATION & DE-PROVISIONING
# ==============================================================================

Write-LogMessage -Message "Step 5: Starting full Unoptimization on $DriveVolume (Expanding files)..." -Color Yellow
Start-DedupJob -Volume $DriveVolume -Type Unoptimization
Watch-DedupJob -JobPrefix "Unoptimization" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL
Write-LogMessage -Message "Unoptimization complete." -Color Green

Write-LogMessage -Message "Step 6: Running deep final Garbage Collection..." -Color Yellow
Start-DedupJob -Volume $DriveVolume -Type GarbageCollection -Full
Watch-DedupJob -JobPrefix "GarbageCollection -Full" -Volume $DriveVolume -DriveId $LogicalDiskId -IntervalSeconds $LOOP_INTERVAL
Write-LogMessage -Message "Deep Garbage Collection complete." -Color Green

Write-LogMessage -Message "Step 7: Disabling deduplication engine for volume $DriveVolume..." -Color Yellow
Disable-DedupVolume -Volume $DriveVolume

Write-LogMessage -Message "Step 8: Completely uninstalling Data Deduplication server role..." -Color Red
Uninstall-WindowsFeature -Name FS-Data-Deduplication -Remove

# ==============================================================================
# 6. FINAL STORAGE FOOTPRINT REPORT
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
} else {
    $absDiff = [math]::Abs($spaceDifference)
    Write-LogMessage -Message "Storage Footprint Increased By: $absDiff TB (Expected due to unoptimization expansion)" -Color Yellow
}
Write-LogMessage -Message "==================================================`n" -Color Green

# ==============================================================================
# 7. SERVER REBOOT SCHEDULE
# ==============================================================================

Write-LogMessage -Message "Step 9: Process finished. Server will restart in 5 minutes. Save your work." -Color Red
Start-Sleep -Seconds 300
Restart-Computer -Force



<#
Get-DedupStatus -Volume "D:" | Select-Object -Property *
Get-ChildItem -Path "D:\System Volume Information\Dedup\State" -Recurse -Force | Measure-Object -Property Length -Sum
Get-Counter -ListSet *Dedup* | Select-Object CounterSetName, Paths
#>
