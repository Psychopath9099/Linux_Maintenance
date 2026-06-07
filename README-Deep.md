# Deep Maintenance — README

A thorough PowerShell maintenance script for Windows 11. Repairs the Windows
component store, checks system file integrity, optimises drives, and reports
SSD health. Designed to run monthly during idle time.

**Expected runtime: 15–60 minutes** depending on drive type and system state.

---

## Requirements

- Windows 11
- PowerShell 5.1 or later (built into Windows 11)
- Administrator privileges
- Internet connection (required for DISM RestoreHealth)
- Recommended: run when the machine is idle

---

## What It Does

| Step | Action | Typical duration |
|------|--------|-----------------|
| 1 | Windows Update cache cleanup | < 1 min |
| 2 | DISM ScanHealth (+ RestoreHealth if corruption found) | 1–2 min healthy · 5–15 min if repair needed |
| 3 | System File Check (SFC) | 5–20 min |
| 4 | DISM StartComponentCleanup | 2–10 min |
| 5 | Drive optimisation (TRIM or Defrag) | < 1 min (SSD) · 10–60 min (HDD) |
| 6 | SSD health check | < 1 min |

### Why this order matters for DISM and SFC

The script uses a scan-first approach rather than running a full repair unconditionally:

```
1. DISM /ScanHealth        — inspects the component store; no changes, no downloads
   → if corruption found:
     DISM /RestoreHealth   — repairs the store by downloading correct files
2. sfc /scannow            — repairs system files using the now-healthy store
3. DISM /StartComponentCleanup — shrinks WinSxS now that repair is complete
```

**Why ScanHealth first?** `RestoreHealth` does active repair work and can download
components from Windows Update every time it runs — even on a perfectly healthy
system. On most monthly runs there is nothing to fix, so running a full repair
unconditionally wastes time and bandwidth. `ScanHealth` takes 1–2 minutes, finds
nothing on a healthy system, and the script moves on. `RestoreHealth` is only
triggered when it is actually needed.

Running `StartComponentCleanup` last ensures rollback components are not stripped
before any repair has completed.

---

## Idle Check

The script checks how long the system has been idle before running. If the
machine has been active within the last 10 minutes it prints a warning and
waits 10 seconds — giving you time to press **Ctrl+C** and reschedule.

This is a soft warning only. The script continues regardless.
To remove it, delete the `# ── Idle Check` block at the top of the script.

---

## SSD Health Check

Step 6 queries SMART data from all detected SSDs and reports:

| Status | Meaning |
|--------|---------|
| `Healthy` | Drive is operating normally |
| `Warning` | Drive is degraded — back up your data now |
| `Unhealthy` | Drive is failing — back up immediately and replace |
| `Unknown` | Driver not reporting SMART data (common on some NVMe controllers) |

`Unknown` does not mean the drive is failing. It means the storage driver is
not exposing SMART data to Windows — a driver limitation, not a hardware fault.
If you see this consistently, use your drive manufacturer's own diagnostic tool
(Samsung Magician, Crucial Storage Executive, WD Dashboard, etc.).

To remove the health check entirely, delete the `# ── 6. SSD Health Check` block.

---

## Drive Detection

The script maps drive C: to its physical disk to decide between TRIM (SSD) and
Defrag (HDD). This is reliable on most single-disk systems. On systems with
Storage Spaces, NVMe RAID, or multiple physical disks, detection may fall back
to HDD mode. Check the log output after your first run to confirm the correct
drive type was detected.

---

## How to Run

### Option A — Right-click (easiest)
1. Right-click `Deep-Maintenance.ps1`
2. Select **Run with PowerShell**
3. Click **Yes** on the UAC prompt

### Option B — Elevated terminal
Open PowerShell as Administrator, then:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd "C:\path\to\script"
.\Deep-Maintenance.ps1
```

### Option C — Task Scheduler (recommended)
1. Open **Task Scheduler** → **Create Basic Task**
2. Name it `Deep Maintenance`
3. Trigger: **Monthly** — first Sunday, at a time the machine is typically idle
4. Action: **Start a program**
   - Program: `powershell.exe`
   - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\Deep-Maintenance.ps1"`
5. Tick **Open Properties**, then:
   - Enable **Run with highest privileges**
   - Under **Conditions** → tick **Start only if the computer is idle for: 10 minutes**
   - Set **Wait for idle for: 1 hour** (retries if machine is busy at trigger time)
6. Click **OK**

---

## Logs

Saved to:
```
C:\ProgramData\MaintenanceLogs\deep_YYYY-MM-DD_HH-mm.log
```
Logs older than **60 days** are pruned automatically on each run.

For deeper diagnostic logs from individual tools:

| Tool | Log location |
|------|-------------|
| DISM | `C:\Windows\Logs\DISM\dism.log` |
| SFC  | `C:\Windows\Logs\CBS\CBS.log` |

---

## Recommended Maintenance Schedule

| Frequency | Task |
|-----------|------|
| **Daily** | `Daily-Maintenance.ps1` |
| **Weekly** | Storage Sense, SSD TRIM (`Optimize-Volume -ReTrim`) |
| **Monthly** | This script |
| **Every 6 months** | `chkdsk C: /scan` (NTFS metadata integrity) |

---

## Customising

Every section is clearly commented. To remove a step, delete the block between
its `# ──` header and the next `# ──` divider.

| Want to skip | Delete block starting with |
|---|---|
| Idle warning | `# ── Idle Check` |
| Windows Update cache | `# ── 1. Windows Update Cache` |
| DISM scan / repair | `# ── 2. DISM Health Check` |
| SFC | `# ── 3. System File Check` |
| DISM Cleanup | `# ── 4. DISM Component Store Cleanup` |
| Drive optimisation | `# ── 5. Drive Optimisation` |
| SSD health check | `# ── 6. SSD Health Check` |

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
| DISM ScanHealth reports corruption | Component store has an issue | RestoreHealth will trigger automatically; check `C:\Windows\Logs\DISM\dism.log` |
| DISM RestoreHealth fails | No internet, or Windows Update service issue | Check connection; DISM log at `C:\Windows\Logs\DISM\dism.log` |
| SFC says it found files it could not fix | DISM RestoreHealth did not complete cleanly | Re-run the script; check DISM log first |
| Drive optimisation skipped | Disk detection could not map C: to a physical disk | See Drive Detection note above |
| SSD health shows Unknown | NVMe driver not exposing SMART data | Use manufacturer's diagnostic tool |
| Windows Update service fails to stop | An update is actively installing | Wait for the update to finish, then re-run |
| Script takes over an hour | HDD defrag on a large or heavily fragmented drive | Normal — let it finish; schedule overnight |
