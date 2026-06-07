# =============================================================================
# Daily Maintenance Script - Windows 11
# Tasks: User Temp, Windows Temp, Recycle Bin
# Target runtime: under 1 minute
# Run as Administrator
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

# --- Logging ------------------------------------------------------------------
# Logs are written to C:\ProgramData\MaintenanceLogs\daily_YYYY-MM-DD_HH-mm.log
# Files older than 30 days are pruned automatically.
$LogDir = "$env:ProgramData\MaintenanceLogs"
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Get-ChildItem $LogDir -Filter "daily_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$LogFile = "$LogDir\daily_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').log"
Start-Transcript -Path $LogFile -Append

Write-Host "`n=== Daily Maintenance Started ===" -ForegroundColor Green
Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# --- Helper -------------------------------------------------------------------
# Prints a timestamped section header in cyan.
# Remove this function and all Write-Step calls if you prefer plain output.
function Write-Step {
    param([string]$Message)
    Write-Host "`n[ $(Get-Date -Format 'HH:mm:ss') ] $Message" -ForegroundColor Cyan
}

# --- 1. User Temp -------------------------------------------------------------
# Cleans the current user's temp folder (%TEMP%).
# Measures size before and after to report how much was freed.
# -ErrorAction SilentlyContinue skips files locked by running processes.
Write-Step "Cleaning User Temp Files..."
# Null-safe: if the folder is empty, Measure-Object returns $null for Sum.
# Defaulting to 0 prevents a type error in the subtraction below.
$before = (Get-ChildItem "$env:TEMP" -Recurse -ErrorAction SilentlyContinue |
           Measure-Object -Property Length -Sum).Sum
if (-not $before) { $before = 0 }
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
$after  = (Get-ChildItem "$env:TEMP" -Recurse -ErrorAction SilentlyContinue |
           Measure-Object -Property Length -Sum).Sum
if (-not $after)  { $after  = 0 }
# [math]::Max(0, ...) prevents a negative result if background processes
# wrote new files to %TEMP% while the cleanup was running.
$freed  = [math]::Max(0, [math]::Round(($before - $after) / 1MB, 2))
Write-Host "  Freed approx $freed MB"

# --- 2. Windows Temp ----------------------------------------------------------
# Cleans the system-wide temp folder (C:\Windows\Temp).
# Files in use by running services are silently skipped.
Write-Step "Cleaning Windows Temp Files..."
Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# --- 3. Recycle Bin -----------------------------------------------------------
# Permanently deletes all items in the Recycle Bin across all drives.
# Remove this step if you prefer to manage the Recycle Bin manually.
Write-Step "Emptying Recycle Bin..."
Clear-RecycleBin -Force -ErrorAction SilentlyContinue

# --- Done ---------------------------------------------------------------------
$elapsed = (Get-Date) - $startTime
Write-Host "`n=== Daily Maintenance Complete ===" -ForegroundColor Green
Write-Host "Completed at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Total time   : $([math]::Round($elapsed.TotalSeconds, 1)) seconds"
Write-Host "Log saved to : $LogFile`n"

Stop-Transcript
