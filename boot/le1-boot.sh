#!/system/bin/sh
# le1-boot.sh — LE1 root + clock persistence (runs as root).
#
# Entry point: /system/bin/install-recovery.sh, run by the STOCK init service
#     service flash_recovery /system/bin/install-recovery.sh   (class main, oneshot)
# which init starts on every boot. That service is the ONLY hook this ROM
# honours -- it does NOT parse added /vendor/etc/init/*.rc or
# /system/etc/init/*.rc files (verified on-device via `setprop ctl.start`).
#
# This script is the supervisor. It never exits.
#
# CRITICAL: never probe root with /system/xbin/su. That binary IS the
# CVE-2019-2215 exploit and self-triggers when the daemon is down -- doing that
# inside the boot path races the kernel and hangs the SoC (WDT bootloop).
# Probe the daemon process with pidof instead.
#
# Toybox only. Absolute paths (init's PATH is minimal).
set -u
PATH=/sbin:/system/bin:/system/xbin
HOOK="${1:-unknown}"

D=${LE1_TIME_DIR:-/data/misc/le1-time}
CACHE=$D/last
LOG=$D/boot.log
SUDAEMON=${LE1_SUDAEMON:-/system/bin/sudaemon}
SETTINGS=${LE1_SETTINGS:-/system/bin/settings}
MIN_EPOCH=1600000000          # 2020-09-13 — anything older is useless for TLS
LOOP_SECS=${LE1_LOOP_SECS:-60}

mkdir -p "$D" 2>/dev/null
log() { echo "[$(date '+%F %T')] $*" >>"$LOG" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# --- root daemon ---------------------------------------------------------
# pidof, NOT su (see header). The daemon forks a child, so either pid counts.
daemon_up() { pidof sudaemon >/dev/null 2>&1; }

start_daemon() {
    [ -x "$SUDAEMON" ] || return 0
    daemon_up && return 0
    "$SUDAEMON" --daemon </dev/null >>"$D/sudaemon.log" 2>&1 &
    sleep 1
    if daemon_up; then log "sudaemon started"; else log "sudaemon did not come up"; fi
}

# --- clock ---------------------------------------------------------------
restore_clock() {
    [ -f "$CACHE" ] || return 0
    e=$(cat "$CACHE" 2>/dev/null | tr -d ' \t\r\n')
    num "$e" || return 0
    [ "$e" -ge "$MIN_EPOCH" ] || return 0
    n=$(date +%s 2>/dev/null)
    if num "$n" && [ "$n" -ge "$e" ]; then return 0; fi   # already later — leave it
    if date -u "@$e" >/dev/null 2>&1; then
        log "clock restored from cache: @$e"
    else
        log "clock restore attempt failed: @$e (rc=$?)"
    fi
}

save_clock() {
    n=$(date +%s 2>/dev/null)
    num "$n" || return 0
    [ "$n" -ge "$MIN_EPOCH" ] || return 0
    old=$(cat "$CACHE" 2>/dev/null | tr -d ' \t\r\n')
    # only touch flash when the value actually moved (>30s) — eMMC wear
    if num "$old" && [ "$n" -ge "$old" ] && [ $((n - old)) -lt 30 ]; then return 0; fi
    printf '%s\n' "$n" >"$CACHE.tmp" 2>/dev/null \
        && mv "$CACHE.tmp" "$CACHE" 2>/dev/null \
        && chmod 600 "$CACHE" 2>/dev/null
}

# --- Android auto-time (survives the vendor cold-boot reset) --------------
# Wrapped in timeout: at class-main time system_server may not answer yet and
# a bare `settings` call would block this supervisor.
enforce_autotime() {
    [ -x "$SETTINGS" ] || return 0
    at=$(timeout 5 "$SETTINGS" get global auto_time 2>/dev/null)
    if [ "$at" != "1" ]; then
        timeout 5 "$SETTINGS" put global auto_time 1 >/dev/null 2>&1
        timeout 5 "$SETTINGS" put global ntp_server pool.ntp.org >/dev/null 2>&1
        log "auto_time re-enabled"
    fi
}

# --------------------------------------------------------------------------
log "le1-boot start (pid $$, hook=$HOOK)"
restore_clock
start_daemon

# Supervisor loop. Runs forever. 60s cadence is cheap.
while :; do
    sleep "$LOOP_SECS"
    start_daemon
    enforce_autotime
    save_clock
done
