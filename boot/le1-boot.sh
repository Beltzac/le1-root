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
    if [ "$at" != "0" ]; then
        # auto_time=1 makes Android re-sync the clock from the (dead) RTC, which
        # slams it back to 2007 a few minutes after boot -> every TLS handshake
        # fails ("certificate not yet valid"). There is no working NTP here, so
        # keep auto_time OFF and let restore_clock own the clock.
        timeout 5 "$SETTINGS" put global auto_time 0 >/dev/null 2>&1
        timeout 5 "$SETTINGS" put global auto_time_zone 0 >/dev/null 2>&1
        log "auto_time disabled (dead RTC would revert the clock)"
    fi
}

# --- app-free services (no Termux app, no Tailscale app) ------------------
# Wrappers live in /data/le1-ssh and /data/le1-tailscale; each backgrounds its own
# daemon. The supervisor only checks liveness and restarts. Never uses su.
ensure_sshd() {
    pidof sshd >/dev/null 2>&1 && return 0
    [ -x /data/le1-ssh/start-sshd.sh ] || return 0
    /data/le1-ssh/start-sshd.sh >/dev/null 2>&1 &
    sleep 1
    if pidof sshd >/dev/null 2>&1; then log "sshd (re)started"; else log "sshd did not start"; fi
}

# Enabled (2026-09-20). start.sh mirrors the active network's default route into
# the main table on every call (idempotent) and exits early if tailscaled already
# runs, so calling it each loop keeps the marked control path routable after
# network changes. Needs tailscale >= 1.103 for DNS (see TAILSCALED-ROOT.md).
ensure_tailscale() {
    [ -x /data/le1-tailscale/start.sh ] || return 0
    /data/le1-tailscale/start.sh >/dev/null 2>&1 &
    sleep 2
    if pidof tailscaled >/dev/null 2>&1; then log "tailscaled (re)started"; else log "tailscaled did not start"; fi
}

# Accurate clock from our own NTP client. Android's built-in NTP does not work on
# this vendor ROM (and auto_time=1 re-syncs the dead RTC and reverts the clock).
# Uses Termux's python3 (present on this unit). Runs at startup and at most every
# 30 min; no-ops until the network is up, so the loop retries it for free.
CLOCK_LAST=$D/clock.last
clock_sync() {
    now=$(date +%s 2>/dev/null); num "$now" || now=0
    last=$(cat "$CLOCK_LAST" 2>/dev/null | tr -d ' \t\r\n'); num "$last" || last=0
    if [ "$last" -gt 0 ] && [ $((now - last)) -lt 1800 ]; then return 0; fi
    # 1. NTP (needs network)
    if [ -x /data/le1-ntp/sync.sh ] && /data/le1-ntp/sync.sh >>"$LOG" 2>&1; then
        printf '%s' "$now" > "$CLOCK_LAST" 2>/dev/null
        return 0
    fi
    # 2. GPS fallback (offline; needs a sky fix). Don't hammer it: every 5 min.
    GPS_LAST=$D/gps.last
    gl=$(cat "$GPS_LAST" 2>/dev/null | tr -d ' \t\r\n'); num "$gl" || gl=0
    if [ $((now - gl)) -ge 300 ] && [ -x /data/le1-ntp/gpstime.sh ]; then
        printf '%s' "$now" > "$GPS_LAST" 2>/dev/null
        if /data/le1-ntp/gpstime.sh >>"$LOG" 2>&1; then
            printf '%s' "$now" > "$CLOCK_LAST" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

# --------------------------------------------------------------------------
log "le1-boot start (pid $$, hook=$HOOK)"
restore_clock
clock_sync
start_daemon
ensure_sshd
ensure_tailscale

# Supervisor loop. Runs forever. 60s cadence is cheap.
while :; do
    sleep "$LOOP_SECS"
    # Android's auto_time/RTC can slam the clock back to the dead-RTC default
    # (~2007) a few minutes after boot, which kills every TLS handshake. Re-assert
    # the cached time every loop so tailscaled keeps working.
    restore_clock
    clock_sync
    start_daemon
    ensure_sshd
    ensure_tailscale
    enforce_autotime
    save_clock
done
