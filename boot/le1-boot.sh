#!/system/bin/sh
# le1-boot.sh — LE1 boot persistence (runs as root).
#
# Started by an init service that we install (see post-root/persist.sh). The
# preferred hook is /vendor/etc/init/le1-boot.rc: Android init parses
# /vendor/etc/init unconditionally in second stage, and unlike
# /system/etc/init it is not gated by ro.boot.init_rc. We do NOT overwrite the
# stock /system/bin/install-recovery.sh by default (that hook is opt-in only).
#
# This script is the supervisor. It never exits, so init keeps it running. It:
#   1. restores the last-known clock (dead RTC -> 2009 -> TLS invalid)
#   2. keeps the su daemon (/system/bin/sudaemon) up           [root for su]
#   3. keeps Android auto_time enabled, refreshes the time cache
#
# It takes one optional argument: a hook tag, logged so `verify-boot.sh` can
# tell which autostart path actually fired.
#
# Toybox only (no busybox/curl/date -d). Absolute paths: init's PATH is minimal.
set -u
PATH=${LE1_PATH:-/sbin:/system/bin:/system/xbin}
HOOK="${1:-unknown}"

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

# --- single-instance guard -------------------------------------------------
# Two hooks are installed on purpose (vendor rc + system rc). Only one
# supervisor should run; the others exit and let init restart them (backoff).
LOCK=$D/supervisor.pid
if [ -f "$LOCK" ]; then
    _old=$(cat "$LOCK" 2>/dev/null)
    num "$_old" || _old=""
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        echo "[$(date '+%F %T')] le1-boot: supervisor $_old already running (hook=$HOOK) — exiting" >>"$LOG" 2>/dev/null
        exit 0
    fi
fi
echo $$ >"$LOCK" 2>/dev/null

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
log "le1-boot start (pid $$, hook=$HOOK)"
restore_clock
start_daemon
enforce_autotime

# Supervisor loop. Runs forever. 60s cadence is cheap.
while :; do
    sleep "$LOOP_SECS"
    start_daemon
    enforce_autotime
    save_clock
done
