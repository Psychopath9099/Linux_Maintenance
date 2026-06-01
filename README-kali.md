# Kali Linux Maintenance Script

A simple, clean, daily-use maintenance script for **Kali Linux (rolling)**. No bloat — just the right commands in the right order with clear output and a full log.

---

## Requirements

- Bash 4+
- `curl`
- Run as root (`sudo`)

### Optional but recommended

| Tool | Purpose | Install |
|---|---|---|
| `smartmontools` | SMART disk health checks | `sudo apt install smartmontools` |
| `snapper` or `timeshift` | Pre-upgrade snapshots for rollback | `sudo apt install snapper` |
| `snap` / `flatpak` | Auto-detected and updated if present | — |

---

## Usage

```bash
# Standard daily run
sudo bash kali-maintenance.sh

# Simulate everything — no changes made
sudo bash kali-maintenance.sh --dry-run

# Also wipe the full apt package cache (frees more disk space)
sudo bash kali-maintenance.sh --clean

# Combine flags
sudo bash kali-maintenance.sh --dry-run --clean
```

---

## What it does

```
Pre-flight   root check · internet · disk space · repo validation · held packages
Step  1/13   Snapshot          snapper or timeshift (if installed)
Step  2/13   dpkg --configure  finish any interrupted package installs
Step  3/13   fix-broken        apt --fix-broken install
Step  4/13   apt update        fatal on failure — no upgrading from stale metadata
Step  5/13   full-upgrade      apt full-upgrade (handles dependency changes)
Step  6/13   package check     dpkg -C and apt-get check post-upgrade report
Step  7/13   autoremove        remove packages no longer needed
Step  8/13   autoclean         remove obsolete cached .deb files
Step  9/13   clean             full cache wipe (only with --clean flag)
Step 10/13   snap + flatpak    update if present
Step 11/13   journal vacuum    keep last 30 days / 500 MB
Step 12/13   SMART health      check all physical disks (if smartctl present)
Step 13/13   reboot check      reads /var/run/reboot-required
```

---

## Flags

| Flag | What it does |
|---|---|
| `--dry-run` | Passes `--simulate` to all apt operations. Nothing is changed. |
| `--clean` | Adds `apt clean` (full cache wipe) after `autoclean`. Off by default to preserve rollback cache. |

---

## Log

Writes to `/var/log/kali-maintenance.log`.

Rotates automatically when it exceeds 50 MB — old log is renamed:
```
/var/log/kali-maintenance.log.20250601_143000.old
```

---

## Notes

### apt clean is opt-in
`apt clean` is not run by default. The cache lets you reinstall or downgrade packages without re-downloading. Pass `--clean` only when disk space is critical.

### Config file handling
Upgrades use `--force-confold` (keep your existing config files) with `--force-confdef` as fallback. Edit the `APT_OPTS` block in the script and change `--force-confold` to `--force-confnew` if you always want fresh upstream configs instead.

### Third-party repository warning
The pre-flight check warns if any repository outside `kali.org` and `debian.org` is found in your apt sources. Third-party repos can conflict with Kali's tool packages.

### Snapshots
If `snapper` or `timeshift` is installed, a snapshot is created before the upgrade runs. If the upgrade breaks something, you have a restore point. If neither tool is present, the step is skipped with a suggestion to install one.

### Held packages
`apt-mark showhold` runs before anything touches packages. If tools like Metasploit or Burp Suite are held, you see them listed upfront so you know why they won't update.

---

## Suggested schedule

| When | Command |
|---|---|
| Daily / after sessions | `sudo bash kali-maintenance.sh` |
| Before a large upgrade | `sudo bash kali-maintenance.sh --dry-run` first |
| Low disk space | `sudo bash kali-maintenance.sh --clean` |
