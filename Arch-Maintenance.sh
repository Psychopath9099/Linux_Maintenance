#!/bin/bash

# Kali-Maintenance.sh
# Copyright (C) 2026 psychopath9099-dot
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.


#!/usr/bin/env bash
# =============================================================================
# ARCH LINUX MAINTENANCE SCRIPT
# =============================================================================
# Version : 3.0
# Target  : Arch Linux (rolling release)
# Usage   : sudo bash arch-maintenance.sh [--dry-run] [--deep-check]
#
# Flags:
#   --dry-run     Print destructive commands without running them
#   --deep-check  Run pacman -Qkk (file-level integrity, slow) after -Dk
#
# What it does (in order):
#   Pre-flight : root · internet · disk space · pacman lock
#   Step  1/11 : reflector mirror refresh    (if reflector present)
#   Step  2/11 : pacman -Syu                 (sync + full upgrade)
#   Step  3/11 : remove orphans              (pacman -Qtdq / -Rns)
#   Step  4/11 : list foreign packages       (pacman -Qm, informational)
#   Step  5/11 : confirm no orphans remain   (pacman -Qdt post-check)
#   Step  6/11 : package cache clean         (paccache -rk2; skip if missing)
#   Step  7/11 : pacman -Dk [+ -Qkk]        (dependency + optional file check)
#   Step  8/11 : journal vacuum              (30 days / 500 MB)
#   Step  9/11 : AUR helper update           (yay / paru, non-root)
#   Step 10/11 : snap / flatpak update       (if present)
#   Step 11/11 : failed services · df · reboot check
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# FLAGS  (parsed early so helpers can honour DRY_RUN)
# -----------------------------------------------------------------------------
DRY_RUN=false
DEEP_CHECK=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true   ;;
        --deep-check) DEEP_CHECK=true ;;
        --help|-h)
            grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg  (use --dry-run or --deep-check)" >&2
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# TIMING
# -----------------------------------------------------------------------------
SCRIPT_START=$SECONDS

# -----------------------------------------------------------------------------
# COLORS  (only when stdout is a real terminal)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; DIM=''; RESET=''
fi

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
readonly LOG_FILE="/var/log/arch-maintenance.log"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

_init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    if [[ -f "$LOG_FILE" ]]; then
        local size_mb
        size_mb=$(( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) / 1024 / 1024 ))
        if (( size_mb > 50 )); then
            mv "$LOG_FILE" "${LOG_FILE}.${TIMESTAMP}.old"
            log_info "Log rotated → ${LOG_FILE}.${TIMESTAMP}.old"
        fi
    fi
    touch "$LOG_FILE"
}

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*";  echo "[$(date '+%F %T')] [INFO]  $*" >> "$LOG_FILE"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*";  echo "[$(date '+%F %T')] [OK]    $*" >> "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*";  echo "[$(date '+%F %T')] [WARN]  $*" >> "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; echo "[$(date '+%F %T')] [ERROR] $*" >> "$LOG_FILE"; }

log_section() {
    local step="$1"; shift
    echo ""
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}  ${step}  —  $*${RESET}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "[$(date '+%F %T')] [STEP] ${step} $*" >> "$LOG_FILE"
}

# Wrapper for destructive commands — prints in dry-run, executes otherwise.
run_cmd() {
    if $DRY_RUN; then
        log_info "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# ERROR TRAP
# -----------------------------------------------------------------------------
_on_error() {
    log_error "Unexpected error on line $1 (exit code $2)"
    log_error "Review the log for details: $LOG_FILE"
}
trap '_on_error "$LINENO" "$?"' ERR

# -----------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# -----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must be run as root.  Try:  sudo bash $0"
        exit 1
    fi
    log_ok "Running as root."
}

check_internet() {
    log_info "Checking internet connectivity..."
    if curl -fsSL --max-time 6 https://archlinux.org >/dev/null 2>&1; then
        log_ok "Internet is available."
        return
    fi
    if ping -c 1 -W 4 1.1.1.1 >/dev/null 2>&1; then
        log_ok "Internet is available (via ping fallback)."
        return
    fi
    log_warn "Internet appears unavailable — update steps may fail."
    log_warn "Continuing in case this is a temporary issue."
}

check_disk_space() {
    local free_mb
    free_mb="$(df --output=avail -m / | tail -1 | tr -d ' ')"
    log_info "Free disk space on /: ${free_mb} MB"
    if (( free_mb < 500 )); then
        log_warn "Low disk space (${free_mb} MB free). Cleanup steps should help."
    fi
}

check_pacman_lock() {
    local lock="/var/lib/pacman/db.lck"
    if [[ -f "$lock" ]]; then
        log_warn "pacman lock file exists: $lock"
        log_warn "If no pacman process is running, remove it with:"
        log_warn "    sudo rm $lock"
        log_error "Cannot continue while pacman database is locked."
        exit 1
    fi
    log_ok "No pacman lock found."
}

# -----------------------------------------------------------------------------
# DETECT AUR HELPER  (yay preferred, paru fallback)
# Must NOT run as root — only trust $SUDO_USER, never guess.
# -----------------------------------------------------------------------------
AUR_HELPER=""
AUR_USER=""

detect_aur_helper() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        AUR_USER="$SUDO_USER"
    else
        log_warn "SUDO_USER not set — AUR step will be skipped."
        log_warn "Run the script via sudo to enable AUR updates."
        return
    fi
    for helper in yay paru; do
        if command -v "$helper" &>/dev/null; then
            AUR_HELPER="$helper"
            log_info "AUR helper detected: $AUR_HELPER (will run as: $AUR_USER)"
            return
        fi
    done
    log_info "No AUR helper (yay/paru) found — AUR step will be skipped."
}

# -----------------------------------------------------------------------------
# MAINTENANCE STEPS
# -----------------------------------------------------------------------------

step_reflector() {
    log_section "Step  1/11" "Mirror refresh (reflector)"
    if ! command -v reflector &>/dev/null; then
        log_info "reflector not installed — skipping mirror refresh."
        log_info "Install it with:  sudo pacman -S reflector"
        return
    fi
    log_info "Updating mirror list (20 fastest HTTPS mirrors)..."
    # Backs up the current list before overwriting.
    run_cmd cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
    run_cmd reflector \
        --latest 20 \
        --protocol https \
        --sort rate \
        --save /etc/pacman.d/mirrorlist \
        2>&1 | tee -a "$LOG_FILE"
    log_ok "Mirror list updated."
}

step_syu() {
    log_section "Step  2/11" "pacman -Syu  (sync + full system upgrade)"
    log_info "Synchronising databases and upgrading all packages..."
    # Single atomic transaction — avoids the partial-upgrade risk of
    # a separate -Syy followed by -Su.
    # Fatal on failure: a half-upgraded Arch system is unsafe.
    run_cmd pacman -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE" || {
        log_error "pacman -Syu failed. Resolve conflicts manually before re-running."
        exit 1
    }
    log_ok "System upgraded."
}

step_remove_orphans() {
    log_section "Step  3/11" "Remove orphaned packages"
    log_info "Checking for orphans (installed but required by nothing)..."
    local orphans
    orphans="$(pacman -Qtdq 2>/dev/null || true)"
    if [[ -n "$orphans" ]]; then
        log_info "Orphans found:"
        while IFS= read -r pkg; do log_info "    • $pkg"; done <<< "$orphans"
        # Soft failure: warn if removal fails rather than aborting the whole run.
        if $DRY_RUN; then
            log_info "[DRY-RUN] pacman -Rns --noconfirm <orphans>"
        else
            if ! echo "$orphans" | pacman -Rns --noconfirm - 2>&1 | tee -a "$LOG_FILE"; then
                log_warn "Some orphan removals failed — they may be required by a foreign package."
                log_warn "Review with:  pacman -Qi <package>"
            fi
        fi
        log_ok "Orphan removal step complete."
    else
        log_ok "No orphaned packages found."
    fi
}

step_list_foreign() {
    log_section "Step  4/11" "Foreign / AUR package report  (informational)"
    log_info "Packages not in any sync database (AUR / manual installs):"
    local foreign
    foreign="$(pacman -Qm 2>/dev/null || true)"
    if [[ -n "$foreign" ]]; then
        while IFS= read -r line; do log_info "    • $line"; done <<< "$foreign"
        log_warn "Foreign packages are not managed by pacman — keep them updated via your AUR helper."
    else
        log_ok "No foreign packages found."
    fi
}

step_confirm_no_orphans() {
    log_section "Step  5/11" "Post-removal orphan confirmation  (pacman -Qdt)"
    local remaining
    remaining="$(pacman -Qdt 2>/dev/null || true)"
    if [[ -n "$remaining" ]]; then
        log_warn "Orphans still present after removal step:"
        while IFS= read -r line; do log_warn "    • $line"; done <<< "$remaining"
    else
        log_ok "No orphans remain."
    fi
}

step_clean_cache() {
    log_section "Step  6/11" "Package cache clean"
    if command -v paccache &>/dev/null; then
        log_info "Keeping 2 most recent versions per package (allows one rollback)..."
        run_cmd paccache -rk2  2>&1 | tee -a "$LOG_FILE"
        log_info "Removing all cached versions of uninstalled packages..."
        run_cmd paccache -ruk0 2>&1 | tee -a "$LOG_FILE"
        log_ok "Package cache cleaned."
    else
        log_warn "paccache not found — skipping cache cleanup."
        log_warn "Install pacman-contrib for safe cache management:"
        log_warn "    sudo pacman -S pacman-contrib"
    fi
}

step_check_db() {
    log_section "Step  7/11" "Database integrity check"
    log_info "Checking dependency consistency (pacman -Dk)..."
    if pacman -Dk 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Dependency check passed."
    else
        log_warn "Dependency issues found — check log for details."
        log_warn "Reinstall affected packages:  sudo pacman -S \$(pacman -Qdkq)"
    fi

    if $DEEP_CHECK; then
        log_info "Deep file-integrity check (pacman -Qkk) — this may take a while..."
        if pacman -Qkk 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "File integrity check passed."
        else
            log_warn "File integrity issues found — review log for affected packages."
        fi
    else
        log_info "Skipping deep file check (-Qkk).  Run with --deep-check to enable."
    fi
}

step_journal_vacuum() {
    log_section "Step  8/11" "systemd journal vacuum"
    log_info "Vacuuming journal: keeping last 30 days, max 500 MB..."
    run_cmd journalctl --vacuum-time=30d  2>&1 | tee -a "$LOG_FILE"
    run_cmd journalctl --vacuum-size=500M 2>&1 | tee -a "$LOG_FILE"
    log_ok "Journal vacuumed."
}

step_aur_update() {
    local label="${AUR_HELPER:-skipped}"
    log_section "Step  9/11" "AUR update  ($label)"
    if [[ -z "$AUR_HELPER" ]] || [[ -z "$AUR_USER" ]]; then
        log_info "AUR step skipped — see pre-flight output above."
        return
    fi
    log_info "Upgrading AUR packages as user '$AUR_USER'..."
    # -Sua: AUR-only; official repos already handled by pacman -Syu above.
    if $DRY_RUN; then
        log_info "[DRY-RUN] su - $AUR_USER -c '$AUR_HELPER -Sua --noconfirm'"
    else
        su - "$AUR_USER" -c "$AUR_HELPER -Sua --noconfirm" 2>&1 | tee -a "$LOG_FILE" \
            && log_ok "AUR packages updated." \
            || log_warn "AUR update encountered an issue — check log."
    fi
}

step_snap() {
    log_section "Step 10/11" "snap + flatpak update"
    if command -v snap &>/dev/null; then
        log_info "Snap detected. Refreshing all snaps..."
        run_cmd snap refresh 2>&1 | tee -a "$LOG_FILE" \
            && log_ok "Snap packages updated." \
            || log_warn "Snap refresh encountered an issue — check log."
    else
        log_info "Snap not installed — skipping."
    fi

    if command -v flatpak &>/dev/null; then
        log_info "Flatpak detected. Updating all apps..."
        run_cmd flatpak update -y 2>&1 | tee -a "$LOG_FILE" \
            && log_ok "Flatpak apps updated." \
            || log_warn "Flatpak update encountered an issue — check log."
    else
        log_info "Flatpak not installed — skipping."
    fi
}

step_final_checks() {
    log_section "Step 11/11" "Health checks + reboot detection"

    # --- Failed systemd services ---
    log_info "Checking for failed systemd services..."
    local failed
    failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)"
    if [[ -n "$failed" ]]; then
        log_warn "Failed services detected:"
        while IFS= read -r line; do log_warn "    • $line"; done <<< "$failed"
        log_warn "Investigate with:  journalctl -xe"
    else
        log_ok "No failed services."
    fi

    # --- Disk usage (all mounted filesystems) ---
    log_info "Disk usage:"
    df -h 2>/dev/null | while IFS= read -r line; do log_info "  $line"; done

    # --- Kernel reboot check ---
    # Arch has no /var/run/reboot-required.
    # Best available heuristic: if the running kernel's module directory no
    # longer exists, a new kernel was installed and a reboot is needed.
    # Known edge case: same version string (e.g. 6.12.5 → 6.12.5.arch2) won't
    # be caught — there is no perfect detector on Arch without extra tooling.
    local running
    running="$(uname -r)"
    log_info "Running kernel: $running"

    if [[ ! -d "/usr/lib/modules/${running}" ]]; then
        log_warn "*** Kernel module directory for '$running' not found. ***"
        log_warn "*** A new kernel was likely installed — reboot recommended. ***"
    else
        log_ok "No reboot required."
    fi
    # Note: microcode (intel-ucode / amd-ucode) presence is NOT used as a
    # reboot indicator — a package being installed doesn't mean it was updated
    # today.  If you want to track microcode updates, compare pacman log
    # timestamps manually:  grep ucode /var/log/pacman.log
}

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------

print_summary() {
    local free_after elapsed
    free_after="$(df -h / | awk 'NR==2{print $4}')"
    elapsed=$(( SECONDS - SCRIPT_START ))

    echo ""
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}  MAINTENANCE COMPLETE${RESET}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Host:"       "$(hostname)"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Kernel:"     "$(uname -r)"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Free /:"     "${free_after}"
    printf "  ${DIM}%-12s${RESET} %ds\n" "Duration:"   "${elapsed}"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Dry-run:"    "$DRY_RUN"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Deep check:" "$DEEP_CHECK"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Log:"        "$LOG_FILE"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# BANNER  (printf-based — width never drifts)
# -----------------------------------------------------------------------------

print_banner() {
    local title="ARCH LINUX MAINTENANCE SCRIPT"
    local ts; ts="$(date '+%Y-%m-%d  %H:%M:%S')"
    local width=44
    local bar; printf -v bar '%*s' "$width" ''; bar="${bar// /━}"

    echo ""
    printf "${WHITE}  ╔%s╗${RESET}\n" "$bar"
    printf "${WHITE}  ║  %-*s  ║${RESET}\n" $(( width - 4 )) "$title"
    printf "${WHITE}  ║  %-*s  ║${RESET}\n" $(( width - 4 )) "$ts"
    $DRY_RUN && printf "${WHITE}  ║  %-*s  ║${RESET}\n" $(( width - 4 )) "⚠  DRY-RUN MODE — no changes will be made"
    printf "${WHITE}  ╚%s╝${RESET}\n" "$bar"
    echo ""
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

main() {
    _init_log
    print_banner
    log_info "Log: $LOG_FILE"

    # Pre-flight
    check_root
    check_internet
    check_disk_space
    check_pacman_lock
    detect_aur_helper

    # Maintenance
    step_reflector
    step_syu
    step_remove_orphans
    step_list_foreign
    step_confirm_no_orphans
    step_clean_cache
    step_check_db
    step_journal_vacuum

    # AUR
    step_aur_update

    # Optional package managers
    step_snap

    # Health + reboot
    step_final_checks

    print_summary
}

main "$@"
