# Arch Linux Maintenance Script

A simple, clean, daily-use maintenance script for **Arch Linux (rolling)**. No bloat — just the right commands in the right order with clear output and a full log.

> **v3.0** — Tested on Arch Linux with kernel `7.x`. Run via `sudo`, not as bare root.

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
| `snap` / `flatpak` | Auto-detected and updated if present | — |

> `smartmontools` is listed in many guides but is **not used** by this script — removed from the table to avoid confusion.

---

## Installation

```bash
# Download / place the script somewhere sensible
sudo cp Arch-Maintenance.sh /usr/local/bin/arch-maintenance
sudo chmod +x /usr/local/bin/arch-maintenance
```

Or just run it directly from wherever you saved it:

```bash
sudo bash Arch-Maintenance.sh
```

---

## Usage

```bash
# Standard daily run
sudo bash Arch-Maintenance.sh

# Simulate everything — no changes made
sudo bash Arch-Maintenance.sh --dry-run

# Run deep file-integrity check (pacman -Qkk — slow, use monthly)
sudo bash Arch-Maintenance.sh --deep-check

# Combine flags
sudo bash Arch-Maintenance.sh --dry-run --deep-check

# Show help
sudo bash Arch-Maintenance.sh --help
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
| `--dry-run` | Prints all destructive commands without running them. Safe to use any time. |
| `--deep-check` | Adds `pacman -Qkk` (file-level integrity check) after `-Dk`. Slow — recommended monthly rather than daily. |
| `--help` / `-h` | Prints usage information and exits. |

---

## Log

Writes to `/var/log/arch-maintenance.log`.

Rotates automatically when it exceeds 50 MB — old log is renamed:
```
/var/log/arch-maintenance.log.20260601_143000.old
```

---

## Notes

### Run via `sudo`, not as bare root
The script must be invoked with `sudo bash Arch-Maintenance.sh`, not from a bare root shell. This is required for the AUR step — the script reads `$SUDO_USER` to know which user to drop back to. Running as bare root leaves `$SUDO_USER` unset and the AUR step is skipped with a warning.

### `hostname` and sudo PATH
On some Arch setups, `sudo` runs with a restricted `PATH` that doesn't include `/bin`, which causes the external `hostname` command to fail. This script uses the `$HOSTNAME` shell builtin instead, with a fallback to `/etc/hostname` — so it works correctly regardless of your sudo PATH configuration.

### AUR updates run as your user
AUR helpers (`yay`/`paru`) must not run as root. The script reads `$SUDO_USER` and drops privileges for that step only using `su - $SUDO_USER`. The `-Sua` flag limits the AUR helper to AUR-only packages — official repos are already handled by `pacman -Syu` in step 2.

### paccache keeps 2 versions
The cache clean keeps the **2 most recent versions** of each installed package so you can roll back one upgrade if something breaks. If `pacman-contrib` is not installed, the cache step is skipped entirely — no aggressive wipe that would remove your rollback safety net.

### Orphan removal is a soft failure
If `pacman -Rns` can't remove an orphan (e.g. a foreign package depends on it), the script logs a warning and continues rather than aborting. Review flagged packages manually with `pacman -Qi <package>`.

### pacman -Syu and --noconfirm
The script uses `pacman -Syu --noconfirm` as a single atomic transaction. This avoids the partial-upgrade risk of a separate `-Syy` followed by `-Su`. Piping pacman through `tee` for logging is done carefully to avoid interfering with stdin — the script checks `PIPESTATUS[0]` (pacman's own exit code) rather than `tee`'s.

### Reboot detection
Arch has no `/var/run/reboot-required`. The script checks whether the running kernel's module directory (`/usr/lib/modules/$(uname -r)`) still exists on disk. If a new kernel was installed and the old directory is gone, a reboot is recommended.

Known edge case: if the new kernel has the same version string as the running one (e.g. `6.12.5` → `6.12.5.arch2`), the module directory may still exist and the check won't fire. There is no perfect single detector on Arch without extra tooling — this is the most reliable heuristic available.

### reflector
If `reflector` is installed, it updates your mirror list to the 20 fastest HTTPS mirrors before the upgrade runs. The current mirrorlist is backed up to `/etc/pacman.d/mirrorlist.bak` first.

---

## Suggested schedule

| When | Command |
|---|---|
| Daily / after sessions | `sudo bash Arch-Maintenance.sh` |
| Monthly | `sudo bash Arch-Maintenance.sh --deep-check` |
| Before a risky upgrade | `sudo bash Arch-Maintenance.sh --dry-run` first |

---

## Known issues fixed in v3.0

| Issue | Fix |
|---|---|
| `hostname: command not found` under restricted sudo PATH | Replaced with `$HOSTNAME` builtin + `/etc/hostname` fallback |
| `--noconfirm` prompt appearing despite flag | Restructured pacman pipe to avoid stdin interference; exit code now read from `PIPESTATUS[0]` |
| Duplicate `#!/bin/bash` shebang | Merged into single `#!/usr/bin/env bash` |
| Fragile `&& log_ok \|\| log_warn` on pipes | Replaced with proper `if/else` + `PIPESTATUS` checks in snap/flatpak/paccache steps |
| `paccache` ran in dry-run mode | Added explicit `$DRY_RUN` guard for both paccache calls |

---

## License

GPL-3.0 — Copyright (C) 2026 psychopath9099-dot.