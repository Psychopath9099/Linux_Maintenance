# Arch Linux Maintenance Script

A simple, clean, daily-use maintenance script for **Arch Linux (rolling)**. No bloat — just the right commands in the right order with clear output and a full log.

---

## Requirements

- Bash 4+
- `curl`
- Run as root (`sudo`)

### Optional but recommended

| Tool | Purpose | Install |
|---|---|---|
| `pacman-contrib` | Safe cache cleanup via `paccache` | `sudo pacman -S pacman-contrib` |
| `reflector` | Mirror ranking before updates | `sudo pacman -S reflector` |
| `yay` or `paru` | AUR package updates | AUR |
| `smartmontools` | SMART disk health checks | `sudo pacman -S smartmontools` |
| `snap` / `flatpak` | Auto-detected and updated if present | — |

---

## Usage

```bash
# Standard daily run
sudo bash arch-maintenance.sh

# Simulate everything — no changes made
sudo bash arch-maintenance.sh --dry-run

# Run deep file-integrity check (pacman -Qkk — slow, use monthly)
sudo bash arch-maintenance.sh --deep-check

# Combine flags
sudo bash arch-maintenance.sh --dry-run --deep-check
```

---

## What it does

```
Pre-flight   root check · internet · disk space · pacman lock check
Step  1/11   reflector         refresh mirror list (if installed)
Step  2/11   pacman -Syu       sync databases + full upgrade in one transaction
Step  3/11   orphan removal    pacman -Qtdq / -Rns (soft failure — warns, continues)
Step  4/11   foreign packages  pacman -Qm report (AUR / manual installs)
Step  5/11   orphan confirm    pacman -Qdt post-removal check
Step  6/11   cache clean       paccache -rk2 (keeps 2 versions) + -ruk0 (skip if missing)
Step  7/11   database check    pacman -Dk daily; pacman -Qkk with --deep-check
Step  8/11   journal vacuum    keep last 30 days / 500 MB
Step  9/11   AUR update        yay or paru as invoking user (skips if SUDO_USER unset)
Step 10/11   snap + flatpak    update if present
Step 11/11   health checks     failed services · df -h · kernel reboot detection
```

---

## Flags

| Flag | What it does |
|---|---|
| `--dry-run` | Prints all destructive commands without running them. |
| `--deep-check` | Adds `pacman -Qkk` (file-level integrity check) after `-Dk`. Slow — recommended monthly rather than daily. |

---

## Log

Writes to `/var/log/arch-maintenance.log`.

Rotates automatically when it exceeds 50 MB — old log is renamed:
```
/var/log/arch-maintenance.log.20250601_143000.old
```

---

## Notes

### AUR updates run as your user
AUR helpers (`yay`/`paru`) must not run as root. The script reads `$SUDO_USER` and drops privileges for that step only. If you run the script directly as root without `sudo`, `$SUDO_USER` is unset and the AUR step is skipped safely with a warning.

### paccache keeps 2 versions
The cache clean keeps the **2 most recent versions** of each installed package so you can roll back one upgrade if something breaks. If `pacman-contrib` is not installed, the cache step is skipped entirely — no aggressive wipe that would remove your rollback safety net.

### Orphan removal is a soft failure
If `pacman -Rns` can't remove an orphan (e.g. a foreign package depends on it), the script logs a warning and continues rather than aborting. Review flagged packages manually with `pacman -Qi <package>`.

### Reboot detection
Arch has no `/var/run/reboot-required`. The script checks whether the running kernel's module directory (`/usr/lib/modules/$(uname -r)`) still exists on disk. If a new kernel was installed and the old directory is gone, a reboot is recommended.

Known edge case: if the new kernel has the same version string as the running one (e.g. `6.12.5` → `6.12.5.arch2`), the module directory may still exist and the check won't fire. There is no perfect detector on Arch without extra tooling — this is the most reliable single check available.

### reflector
If `reflector` is installed, it updates your mirror list to the 20 fastest HTTPS mirrors before the upgrade runs. The current mirrorlist is backed up to `/etc/pacman.d/mirrorlist.bak` first.

---

## Suggested schedule

| When | Command |
|---|---|
| Daily / after sessions | `sudo bash arch-maintenance.sh` |
| Monthly | `sudo bash arch-maintenance.sh --deep-check` |
| Before a risky upgrade | `sudo bash arch-maintenance.sh --dry-run` first |
