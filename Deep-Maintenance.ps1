# =============================================================================
# Deep Maintenance Script - Windows 11
# Tasks: Windows Update Cache, DISM ScanHealth, SFC, DISM Cleanup,
#        Drive Optimisation, SSD Health
# Target runtime: 15-60 minutes depending on drive type
# Run as Administrator - recommended during idle time
# =============================================================================

$startTime = Get-Date

# --- Admin Check --------------------------------------------------------------
# Exits immediately if not running elevated - all tasks below require it.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script as Administrator." -ForegroundColor Red
    Pause
    exit 1
}

# --- Idle Check ---------------------------------------------------------------
# Warns if the system has been active for less than 10 minutes since last input.
# This is a soft warning only - the script will still continue.
# Remove this block if you always run this manually.
$idleThresholdMinutes = 10
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IdleTime {
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    public static double GetIdleMinutes() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        return (Environment.TickCount - info.dwTime) / 60000.0;
    }
}
"@
$idleMinutes = [IdleTime]::GetIdleMinutes()
if ($idleMinutes -lt $idleThresholdMinutes) {
    Write-Host "Warning: System has only been idle for $([math]::Round($idleMinutes, 1)) minutes." -ForegroundColor Yellow
    Write-Host "         Deep maintenance is best run when the machine is not in active use." -ForegroundColor Yellow
    Write-Host "         Press Ctrl+C to cancel, or wait 10 seconds to continue..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

# --- Logging ------------------------------------------------------------------
# Logs are written to C:\ProgramData\MaintenanceLogs\deep_YYYY-MM-DD_HH-mm.log
# Files older than 60 days are pruned automatically.
$LogDir = "$env:ProgramData\MaintenanceLogs"
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Get-ChildItem $LogDir -Filter "deep_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$LogFile = "$LogDir\deep_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').log"
Start-Transcript -Path $LogFile -Append

Write-Host "`n=== Deep Maintenance Started ===" -ForegroundColor Green
Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# --- Helper -------------------------------------------------------------------
# Prints a timestamped section header in cyan.
# Remove this function and all Write-Step calls if you prefer plain output.
function Write-Step {
    param([string]$Message)
    Write-Host "`n[ $(Get-Date -Format 'HH:mm:ss') ] $Message" -ForegroundColor Cyan
}

# --- 1. Windows Update Cache --------------------------------------------------
# Stops the Windows Update service, deletes cached download files, then
# restarts the service. The 'finally' block guarantees the service is always
# restarted even if the stop or delete step fails.
# Safe to run - Windows will re-download any pending updates as needed.
Write-Step "Cleaning Windows Update Cache..."
try {
    Stop-Service wuauserv -Force -ErrorAction Stop
    Write-Host "  Windows Update service stopped."
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" `
        -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Download cache cleared."
}
catch {
    Write-Warning "  Could not stop Windows Update service: $_"
}
finally {
    # Always restart - even if an error occurred above.
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Host "  Windows Update service restarted."
}

# --- 2. DISM Health Check (ScanHealth -> RestoreHealth if needed) -------------
# ScanHealth inspects the component store and reports corruption without making
# any changes or downloading anything. It is fast and safe to run every month.
#
# RestoreHealth is only triggered if ScanHealth finds corruption. It repairs the
# component store by downloading correct files from Windows Update, and must
# complete before SFC runs - SFC uses the component store as its repair source.
#
# Running RestoreHealth unconditionally every month does more work than necessary
# on a healthy system. ScanHealth first is the correct default.
#
# Requires an internet connection only if RestoreHealth is triggered.
# Full DISM log: C:\Windows\Logs\DISM\dism.log
Write-Step "Scanning Windows Component Store (DISM ScanHealth)..."
DISM /Online /Cleanup-Image /ScanHealth
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  Corruption detected (exit code $LASTEXITCODE) - running RestoreHealth..."
    DISM /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  DISM RestoreHealth exited with code $LASTEXITCODE - check C:\Windows\Logs\DISM\dism.log"
        Write-Warning "  SFC will still run but may have limited repair capability."
    }
    else {
        Write-Host "  RestoreHealth completed successfully."
    }
}
else {
    Write-Host "  Component store is healthy - RestoreHealth not needed."
}

# --- 3. System File Check (SFC) -----------------------------------------------
# Scans all protected system files and repairs corrupted ones using the
# component store checked/repaired by DISM in the previous step.
# Full log: C:\Windows\Logs\CBS\CBS.log
Write-Step "Checking System Files with SFC (this may take several minutes)..."
sfc /scannow
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  SFC reported issues (exit code $LASTEXITCODE) - check C:\Windows\Logs\CBS\CBS.log"
}

# --- 4. DISM Component Store Cleanup ------------------------------------------
# Shrinks the WinSxS folder by removing superseded component versions.
# Runs after ScanHealth/RestoreHealth and SFC to ensure rollback components
# are not removed before any repair has completed.
# Can reclaim 1-5 GB on older systems.
# IMPORTANT: Do NOT add /ResetBase - it permanently prevents future rollback.
Write-Step "Cleaning Windows Component Store (DISM StartComponentCleanup)..."
DISM /Online /Cleanup-Image /StartComponentCleanup
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  DISM StartComponentCleanup exited with code $LASTEXITCODE - check C:\Windows\Logs\DISM\dism.log"
}

# --- 5. Drive Optimisation ----------------------------------------------------
# Detects whether drive C: is an SSD or HDD and runs the appropriate operation.
#
# SSD  -> TRIM  (-ReTrim) : marks deleted blocks as free so the firmware can
#                           reclaim them. Fast, recommended monthly.
# HDD  -> Defrag (-Defrag): rewrites fragmented files contiguously.
#                           Can take 10-60 minutes on large/full drives.
#
# The detection maps C:'s partition to its physical disk number. This works
# correctly on most single-disk systems. On Storage Spaces, NVMe RAID, or
# unusual configurations it may fall back to HDD mode - check the log output
# after your first run to confirm.
Write-Step "Optimizing Drive C..."
try {
    $partition  = Get-Partition -DriveLetter C -ErrorAction Stop
    $diskNumber = $partition.DiskNumber
    $disk       = Get-PhysicalDisk |
                  Where-Object { $_.DeviceId -eq $diskNumber } |
                  Select-Object -First 1

    if (-not $disk) {
        Write-Warning "  Could not identify physical disk for C: - skipping optimisation."
    }
    elseif ($disk.MediaType -eq "SSD") {
        Write-Host "  SSD detected - running TRIM..."
        Optimize-Volume -DriveLetter C -ReTrim -Verbose
    }
    else {
        Write-Host "  HDD detected - running Defrag..."
        Optimize-Volume -DriveLetter C -Defrag -Verbose
    }
}
catch {
    Write-Warning "  Drive optimisation failed: $_"
}

# --- 6. SSD Health Check ------------------------------------------------------
# OPTIONAL - Remove this entire block if you do not have an SSD or do not
# want health reporting.
#
# Queries SMART data via Get-PhysicalDisk to report drive health status.
# Statuses: Healthy, Warning, Unhealthy, Unknown
# A 'Warning' or 'Unhealthy' result means you should back up your data
# immediately and consider replacing the drive.
#
# Note: OperationalStatus and HealthStatus rely on the storage driver reporting
# SMART data correctly. NVMe drives on some systems report 'Unknown' even when
# healthy - this is a driver limitation, not a fault.
Write-Step "Checking SSD Health..."
try {
    $ssds = Get-PhysicalDisk | Where-Object { $_.MediaType -eq "SSD" }

    if (-not $ssds) {
        Write-Host "  No SSD detected - skipping health check."
    }
    else {
        foreach ($ssd in $ssds) {
            $health = $ssd.HealthStatus
            $status = $ssd.OperationalStatus
            $size   = [math]::Round($ssd.Size / 1GB, 1)
            $color  = switch ($health) {
                "Healthy"   { "Green"  }
                "Warning"   { "Yellow" }
                "Unhealthy" { "Red"    }
                default     { "Gray"   }
            }
            Write-Host "  Drive  : $($ssd.FriendlyName) ($size GB)" -ForegroundColor $color
            Write-Host "  Health : $health" -ForegroundColor $color
            Write-Host "  Status : $status" -ForegroundColor $color

            if ($health -eq "Warning") {
                Write-Warning "  ATTENTION: Drive health is degraded. Back up your data."
            }
            elseif ($health -eq "Unhealthy") {
                Write-Warning "  CRITICAL: Drive is unhealthy. Back up immediately and replace the drive."
            }
        }
    }
}
catch {
    Write-Warning "  SSD health check failed: $_"
}

# --- Done ---------------------------------------------------------------------
$elapsed = (Get-Date) - $startTime
Write-Host "`n=== Deep Maintenance Complete ===" -ForegroundColor Green
Write-Host "Completed at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Total time   : $([math]::Round($elapsed.TotalMinutes, 2)) minutes"
Write-Host "Log saved to : $LogFile`n"

Stop-Transcript