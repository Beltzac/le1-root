#!/system/bin/sh
# le1-boot.sh — LE1 boot persistence (runs as root).
#
# Installed to /system/bin/le1-boot.sh and started by /system/bin/install-recovery.sh,
# which is defined in the *stock ramdisk* init.rc as:
#
#     service flash_recovery /system/bin/install-recovery.sh
#         class main
#         oneshot
#
# The ramdisk init.rc is always parsed, unlike /system/etc/init/*.rc on this MTK
# build (verified 2026-09: init.svc.* empty, stale loadtime logs), so this is the
# only reliable root-autostart hook on the unit.
#
# CRITICAL: init SIGKILLs the process group of a `oneshot` service as soon as its
# main process exits. This script therefore NEVER exits — it is the supervisor.
# That is also why the sudaemon/time children survive: they are in the cgroup of
# a service that stays alive.
#
# Toybox only (no busybox/curl/date -d). Absolute paths: init's PATH is minimal.
set -u
PATH=${LE1_PATH:-/sbin:/system/bin:/system/xbin}

D=${LE1_TIME_DIR:-/data/misc/le1-time}
CACHE=$D/last
LOG=$D/boot.log
SU=${LE1_SU:-/system/xbin/su}
SUDAEMON=${LE1_SUDAEMON:-/system/bin/sudaemon}
SETTINGS=${LE1_SETTINGS:-/system/bin/settings}
MIN_EPOCH=1600000000          # 2020-09-13 — anything older is useless for TLS
LOOP_SECS=${LE1_LOOP_SECS:-60}

mkdir -p "$D" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" >>"$LOG" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# --- clock ---------------------------------------------------------------
restore_clock() {
    [ -f "$CACHE" ] || return 0
    e=$(cat "$CACHE" 2>/dev/null)
    e=$(echo "$e" | tr -d ' \t\r\n')
    num "$e" || return 0
    [ "$e" -ge "$MIN_EPOCH" ] || return 0
    n=$(date +%s 2>/dev/null)
    if num "$n" && [ "$n" -ge "$e" ]; then return 0; fi   # already later — leave it
    if date -u "@$e" >/dev/null 2>&1; then
        log "clock restored from cache: @$e ($(date '+%F %T'))"
    fi
}

save_clock() {
    n=$(date +%s 2>/dev/null)
    num "$n" || return 0
    [ "$n" -ge "$MIN_EPOCH" ] || return 0
    printf '%s\n' "$n" >"$CACHE.tmp" 2>/dev/null \
        && mv "$CACHE.tmp" "$CACHE" 2>/dev/null \
        && chmod 600 "$CACHE" 2>/dev/null
}

# --- root daemon ---------------------------------------------------------
su_ok() { [ -x "$SU" ] && "$SU" -c true >/dev/null 2>&1; }

start_daemon() {
    [ -x "$SUDAEMON" ] || return 0
    su_ok && return 0
    "$SUDAEMON" --daemon </dev/null >>"$D/sudaemon.log" 2>&1 &
    sleep 1
    if su_ok; then log "sudaemon started"; else log "sudaemon did not come up"; fi
}

# --- Android auto-time (survives the vendor cold-boot reset) --------------
enforce_autotime() {
    [ -x "$SETTINGS" ] || return 0
    at=$("$SETTINGS" get global auto_time 2>/dev/null)
    if [ "$at" != "1" ]; then
        "$SETTINGS" put global auto_time 1 >/dev/null 2>&1
        "$SETTINGS" put global ntp_server pool.ntp.org >/dev/null 2>&1
        log "auto_time re-enabled"
    fi
}

# --------------------------------------------------------------------------
log "le1-boot start (pid $$)"
restore_clock
start_daemon
enforce_autotime

# Supervisor loop. Runs forever (see note at top). 60s cadence is cheap.
while :; do
    sleep "$LOOP_SECS"
    start_daemon
    enforce_autotime
    save_clock
done
