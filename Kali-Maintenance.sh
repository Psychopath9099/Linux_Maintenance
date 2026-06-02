#!/bin/bash

# Kali-Maintenance.sh
# Copyright (C) 2026 psychopath9099
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.


#!/usr/bin/env bash
# =============================================================================
# KALI LINUX MAINTENANCE SCRIPT
# =============================================================================
# Version : 3.0
# Target  : Kali Linux (rolling) / Debian-based systems
# Usage   : sudo bash kali-maintenance.sh [--dry-run] [--clean]
#
# Flags:
#   --dry-run   Simulate all apt operations without making changes
#   --clean     Also run apt clean (full cache wipe) after autoclean
#
# What it does (in order):
#   Pre-flight : root · internet · disk space · repo validation · held pkgs
#   Step  1/13 : snapshot               (snapper / timeshift, if present)
#   Step  2/13 : dpkg --configure -a    (finish interrupted installs)
#   Step  3/13 : apt --fix-broken       (heal broken deps before update)
#   Step  4/13 : apt update             (refresh package lists — fatal on fail)
#   Step  5/13 : apt full-upgrade       (upgrade + handle dep changes)
#   Step  6/13 : dpkg -C + apt-get check (broken package report)
#   Step  7/13 : apt autoremove         (remove unneeded packages)
#   Step  8/13 : apt autoclean          (remove obsolete cached debs)
#   Step  9/13 : apt clean              (full cache wipe — only with --clean)
#   Step 10/13 : snap + flatpak update  (if present)
#   Step 11/13 : journal vacuum         (30 days / 500 MB)
#   Step 12/13 : SMART health check     (if smartmontools present)
#   Step 13/13 : reboot required check
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# FLAGS
# -----------------------------------------------------------------------------
DRY_RUN=false
OPT_CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true  ;;
        --clean)   OPT_CLEAN=true ;;
        --help|-h)
            grep '^#' "$0" | head -22 | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg  (use --dry-run or --clean)" >&2
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
readonly LOG_FILE="/var/log/kali-maintenance.log"
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

# Wrapper: prints command in dry-run mode, executes otherwise.
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
# APT OPTIONS
# --force-confold  : keep existing config files (safest for daily use)
# --force-confdef  : use package default when no local changes exist
# Change --force-confold → --force-confnew to always take upstream configs.
# -----------------------------------------------------------------------------
APT_OPTS=(
    -y
    -o "Dpkg::Options::=--force-confold"
    -o "Dpkg::Options::=--force-confdef"
)
export DEBIAN_FRONTEND=noninteractive

# Simulate flag for dry-run apt calls
apt_simulate() { $DRY_RUN && echo "--simulate" || echo ""; }

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
    if curl -fsSL --max-time 6 https://kali.org >/dev/null 2>&1; then
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

check_repos() {
    log_info "Validating apt repositories..."

    # Confirm kali-rolling is present
    if grep -rqE "kali-rolling" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        log_ok "kali-rolling branch confirmed."
    else
        log_warn "kali-rolling not found in apt sources."
        log_warn "This script is intended for Kali rolling. Proceed with caution."
    fi

    # Warn about third-party repositories — these can conflict with Kali tools
    local third_party
    third_party="$(grep -rh "^deb " /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
        | grep -vE "kali\.org|security\.debian\.org|deb\.debian\.org" || true)"
    if [[ -n "$third_party" ]]; then
        log_warn "Third-party repositories detected — these may conflict with Kali packages:"
        while IFS= read -r line; do log_warn "    $line"; done <<< "$third_party"
    else
        log_ok "No third-party repositories found."
    fi
}

check_held_packages() {
    log_info "Checking for held packages..."
    local held
    held="$(apt-mark showhold 2>/dev/null || true)"
    if [[ -n "$held" ]]; then
        log_warn "Held packages will not be upgraded:"
        while IFS= read -r pkg; do log_warn "    • $pkg"; done <<< "$held"
    else
        log_ok "No held packages."
    fi
}

# -----------------------------------------------------------------------------
# MAINTENANCE STEPS
# -----------------------------------------------------------------------------

step_snapshot() {
    log_section "Step  1/13" "Pre-upgrade snapshot"
    # Try snapper first, then timeshift.  Skip silently if neither is present.
    if command -v snapper &>/dev/null; then
        log_info "snapper detected. Creating pre-upgrade snapshot..."
        run_cmd snapper create --description "kali-maintenance pre-upgrade $(date +%F)" \
            2>&1 | tee -a "$LOG_FILE" \
            && log_ok "Snapper snapshot created." \
            || log_warn "Snapper snapshot failed — continuing without snapshot."
    elif command -v timeshift &>/dev/null; then
        log_info "timeshift detected. Creating pre-upgrade snapshot..."
        run_cmd timeshift --create --comments "kali-maintenance pre-upgrade $(date +%F)" \
            2>&1 | tee -a "$LOG_FILE" \
            && log_ok "Timeshift snapshot created." \
            || log_warn "Timeshift snapshot failed — continuing without snapshot."
    else
        log_info "No snapshot tool found (snapper / timeshift) — skipping."
        log_info "Consider installing one for safe rollback after large upgrades."
    fi
}

step_dpkg_configure() {
    log_section "Step  2/13" "dpkg --configure -a"
    log_info "Completing any interrupted package configurations..."
    run_cmd dpkg --configure -a 2>&1 | tee -a "$LOG_FILE"
    log_ok "dpkg configure done."
}

step_fix_broken() {
    log_section "Step  3/13" "apt --fix-broken install"
    log_info "Healing broken package dependencies..."
    apt-get install --fix-broken $(apt_simulate) "${APT_OPTS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    log_ok "Broken packages resolved."
}

step_update() {
    log_section "Step  4/13" "apt update"
    log_info "Refreshing package lists..."
    # Fatal: stale metadata means a broken upgrade — do not continue.
    apt-get update 2>&1 | tee -a "$LOG_FILE" || {
        log_error "apt update failed. Cannot upgrade from stale metadata."
        exit 1
    }
    # Show upgradable package count for awareness
    local count
    count="$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)"
    log_info "Packages available to upgrade: ${count}"
    log_ok "Package lists updated."
}

step_full_upgrade() {
    log_section "Step  5/13" "apt full-upgrade"
    log_info "Upgrading all packages (full-upgrade handles dependency changes)..."
    apt-get full-upgrade $(apt_simulate) "${APT_OPTS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    log_ok "System upgraded."
}

step_check_packages() {
    log_section "Step  6/13" "Broken package check  (dpkg -C + apt-get check)"
    local issues=false

    log_info "Running dpkg -C (half-installed / unpacked packages)..."
    local dpkg_issues
    dpkg_issues="$(dpkg -C 2>/dev/null || true)"
    if [[ -n "$dpkg_issues" ]]; then
        log_warn "dpkg -C reported issues:"
        while IFS= read -r line; do log_warn "    $line"; done <<< "$dpkg_issues"
        issues=true
    else
        log_ok "dpkg -C: no issues."
    fi

    log_info "Running apt-get check (broken dependency consistency)..."
    if ! apt-get check 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "apt-get check reported broken dependencies."
        issues=true
    else
        log_ok "apt-get check: no issues."
    fi

    $issues && log_warn "Package issues detected — consider running step 3 again manually." \
            || log_ok "All package checks passed."
}

step_autoremove() {
    log_section "Step  7/13" "apt autoremove"
    log_info "Removing unneeded packages..."
    apt-get autoremove $(apt_simulate) "${APT_OPTS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    log_ok "Autoremove complete."
}

step_autoclean() {
    log_section "Step  8/13" "apt autoclean"
    log_info "Removing obsolete cached package files..."
    apt-get autoclean -y 2>&1 | tee -a "$LOG_FILE"
    log_ok "Autoclean complete."
}

step_clean() {
    log_section "Step  9/13" "apt clean  (full cache wipe)"
    if $OPT_CLEAN; then
        log_info "Purging full package cache (--clean flag set)..."
        run_cmd apt-get clean 2>&1 | tee -a "$LOG_FILE"
        log_ok "Package cache cleared."
    else
        log_info "Skipping full cache wipe.  Run with --clean to enable."
        log_info "Keeping cache allows reinstalls and downgrades without re-downloading."
    fi
}

step_optional_managers() {
    log_section "Step 10/13" "snap + flatpak update"
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

step_journal_vacuum() {
    log_section "Step 11/13" "systemd journal vacuum"
    log_info "Vacuuming journal: keeping last 30 days, max 500 MB..."
    run_cmd journalctl --vacuum-time=30d  2>&1 | tee -a "$LOG_FILE"
    run_cmd journalctl --vacuum-size=500M 2>&1 | tee -a "$LOG_FILE"
    log_ok "Journal vacuumed."
}

step_smart() {
    log_section "Step 12/13" "SMART disk health check"
    if ! command -v smartctl &>/dev/null; then
        log_info "smartmontools not installed — skipping SMART check."
        log_info "Install it with:  sudo apt install smartmontools"
        return
    fi

    local found_disk=false
    # Iterate over all block devices that look like physical disks
    while IFS= read -r disk; do
        local dev="/dev/${disk}"
        [[ -b "$dev" ]] || continue
        found_disk=true
        log_info "SMART check: $dev"
        local result
        result="$(smartctl -H "$dev" 2>/dev/null | grep -i "overall-health\|result" || true)"
        if [[ -n "$result" ]]; then
            if echo "$result" | grep -qi "PASSED\|OK"; then
                log_ok "$dev — $result"
            else
                log_warn "$dev — $result"
            fi
        else
            log_warn "$dev — could not read SMART health (may not be supported)"
        fi
    done < <(lsblk -d -o NAME,TYPE 2>/dev/null | awk '/disk/{print $1}')

    $found_disk || log_warn "No physical disks detected for SMART check."
}

step_reboot_check() {
    log_section "Step 13/13" "Reboot required check"
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "*** A system reboot is required to complete updates. ***"
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log_info "Triggered by:"
            while IFS= read -r pkg; do
                log_info "    • $pkg"
            done < /var/run/reboot-required.pkgs
        fi
    else
        log_ok "No reboot required."
    fi
}

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------

print_summary() {
    local elapsed
    elapsed=$(( SECONDS - SCRIPT_START ))

    echo ""
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}  MAINTENANCE COMPLETE${RESET}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Host:"      "$(hostname)"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Kernel:"    "$(uname -r)"
    printf "  ${DIM}%-12s${RESET} %ds\n" "Duration:"  "${elapsed}"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Dry-run:"   "$DRY_RUN"
    printf "  ${DIM}%-12s${RESET} %s\n"  "Log:"       "$LOG_FILE"
    echo ""
    # Disk usage for all real filesystems (exclude tmpfs/devtmpfs noise)
    log_info "Disk usage:"
    df -h --exclude-type=tmpfs --exclude-type=devtmpfs 2>/dev/null \
        | while IFS= read -r line; do log_info "  $line"; done
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# BANNER  (printf-based — width never drifts)
# -----------------------------------------------------------------------------

print_banner() {
    local title="KALI LINUX MAINTENANCE SCRIPT"
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
    check_repos
    check_held_packages

    # Maintenance — safe order: snapshot → repair → update → upgrade → clean
    step_snapshot
    step_dpkg_configure
    step_fix_broken
    step_update
    step_full_upgrade
    step_check_packages
    step_autoremove
    step_autoclean
    step_clean

    # Optional package managers
    step_optional_managers

    # Health checks
    step_journal_vacuum
    step_smart

    # Final
    step_reboot_check
    print_summary
}

main "$@"
