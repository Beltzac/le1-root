#!/data/data/com.termux/files/usr/bin/sh
# 20-autotime.sh (Termux:Boot) — keep Android auto-time enabled at boot.
#
# PRIMARY path is now /system/bin/le1-boot.sh, which runs as root at every boot
# via the stock-ramdisk init service `flash_recovery` -> install-recovery.sh.
# It re-enables auto_time and keeps the su daemon alive, with no adb involved.
#
# This Termux:Boot script is only a *fallback* for the case where the root hook
# is not installed yet (or root is broken). It must never hang the head unit:
#   * root path first (su -c) — no adb, no setprop
#   * one bounded adb attempt, one optional adbd nudge, then give up
#   * it always exits; Termux:Boot does not need to babysit it
export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin

LOG="$HOME/.local/state/le1-autotime.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "[$(date '+%F %T')] $*" >>"$LOG" 2>/dev/null; }

apply_root() {
    command -v su >/dev/null 2>&1 || return 1
    su -c true >/dev/null 2>&1 || return 1
    su -c 'settings put global auto_time 1' >/dev/null 2>&1
    su -c 'settings put global ntp_server pool.ntp.org' >/dev/null 2>&1
    return 0
}

# --- 1) preferred: root (no adb, cannot hang) -----------------------------
if apply_root; then
    log "auto_time enforced via su"
    exit 0
fi

# --- 2) fallback: local adb shell (uid 2000) ------------------------------
S="adb -s 127.0.0.1:5555"
adb start-server >/dev/null 2>&1

if [ "$($S get-state 2>/dev/null)" != "device" ]; then
    timeout 5 adb connect 127.0.0.1:5555 >/dev/null 2>&1
fi

# Vendor adbd sometimes ignores persist.adb.tcp.port until it is (re)started.
# Nudge it once — never in a loop; a boot-time restart storm is what froze the
# unit previously.
if [ "$($S get-state 2>/dev/null)" != "device" ]; then
    setprop ctl.restart adbd >/dev/null 2>&1
    sleep 3
    timeout 5 adb connect 127.0.0.1:5555 >/dev/null 2>&1
fi

if [ "$($S get-state 2>/dev/null)" = "device" ]; then
    $S shell "settings put global auto_time 1" >/dev/null 2>&1
    $S shell "settings put global ntp_server pool.ntp.org" >/dev/null 2>&1
    log "auto_time enforced via adb"
else
    log "skipped: no root and adb unreachable (root hook not installed?)"
fi

exit 0
