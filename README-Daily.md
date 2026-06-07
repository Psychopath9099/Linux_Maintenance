# Daily Maintenance — README

A lightweight PowerShell script for Windows 11 that runs in under a minute.
Cleans temp folders and empties the Recycle Bin. Safe to schedule every day.

---

## Requirements

- Windows 11
- PowerShell 5.1 or later (built into Windows 11)
- Administrator privileges

---

## What It Does

| Step | Action | Notes |
|------|--------|-------|
| 1 | Clean User Temp (`%TEMP%`) | Reports MB freed; skips locked files; null-safe if folder is empty |
| 2 | Clean Windows Temp (`C:\Windows\Temp`) | Skips files in use by services |
| 3 | Empty Recycle Bin | All drives |

**Why DNS flush is not included:**
The DNS cache exists to speed up hostname resolution and reduce network requests.
Flushing it daily provides no meaningful benefit on a healthy system and forces
Windows to rebuild the cache from scratch on every run. If you ever need it for
troubleshooting, use a separate network repair script rather than routine maintenance.

---

## How to Run

### Option A — Right-click (easiest)
1. Right-click `Daily-Maintenance.ps1`
2. Select **Run with PowerShell**
3. Click **Yes** on the UAC prompt

### Option B — Elevated terminal
Open PowerShell as Administrator, then:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd "C:\path\to\script"
.\Daily-Maintenance.ps1
```

### Option C — Task Scheduler (recommended)
1. Open **Task Scheduler** → **Create Basic Task**
2. Name it `Daily Maintenance`
3. Trigger: **Daily** — at login, or at a fixed time (e.g. 8:00 AM)
4. Action: **Start a program**
   - Program: `powershell.exe`
   - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\Daily-Maintenance.ps1"`
5. Tick **Open Properties**, then enable **Run with highest privileges**
6. Click **Finish**

---

## Logs

Saved to:
```
C:\ProgramData\MaintenanceLogs\daily_YYYY-MM-DD_HH-mm.log
```
Logs older than **30 days** are pruned automatically on each run.

---

## Customising

Every section is clearly commented. To remove a step, delete the block between
its `# ──` header and the next `# ──` divider.

| Want to skip | Delete block starting with |
|---|---|
| Recycle Bin | `# ── 3. Recycle Bin` |
| Freed MB reporting | The `$before` / `$after` / `$freed` lines (keep the `Remove-Item` line) |

---

## Recommended Maintenance Schedule

| Frequency | Script |
|-----------|--------|
| **Daily** | This script |
| **Weekly** | Storage Sense, SSD TRIM (`Optimize-Volume -ReTrim`) |
| **Monthly** | `Deep-Maintenance.ps1` |
| **Every 6 months** | `chkdsk C: /scan` (NTFS metadata integrity) |

---

## Execution Policy

If PowerShell blocks the script, run this once in an elevated terminal:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Red "run as Administrator" message | Not elevated | Re-run as Administrator |
| Script appears to do nothing | Execution policy blocking it | See Execution Policy section above |
| Freed MB shows 0 | Temp folder was already empty, or all files were locked | Normal — no action needed |
