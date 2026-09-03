#!/system/bin/sh
# timefix.sh — LE1 boot clock sync, NETWORK path (NTP, then HTTP-Date fallback).
# Runs as root via init (see timefix.rc). GPS runs separately (gpstime.sh).
LOG_FILE=/data/local/tmp/le1-timefix.log
TAG=LE1-timefix
. /system/bin/le1-common.sh 2>/dev/null || { echo "timefix: le1-common.sh missing" >&2; exit 1; }

banner "timefix: network clock sync"

# init-service PATH is minimal (/sbin:/system/bin:/system/xbin) — resolve busybox/curl absolutely.
# busybox lives at /system/xbin/busybox on most MTK 8.1 builds, /system/bin/busybox on others.
BB=""
for _b in /system/xbin/busybox /system/bin/busybox busybox; do
    if command -v "$_b" >/dev/null 2>&1 || [ -x "$_b" ]; then BB="$_b"; break; fi
done
[ -n "$BB" ] && info "busybox: $BB" || warn "no busybox found — NTP/hwclock/date -d unavailable"
CURL=""
for _c in /system/bin/curl /system/xbin/curl curl; do
    if command -v "$_c" >/dev/null 2>&1 || [ -x "$_c" ]; then CURL="$_c"; break; fi
done

NET_TIMEOUT=180   # seconds to wait for connectivity

wait_network() {
    info "waiting for network (max ${NET_TIMEOUT}s)..."
    _i=0
    until ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
        _i=$((_i+2))
        [ "$_i" -gt "$NET_TIMEOUT" ] && { warn "no network after ${NET_TIMEOUT}s"; return 1; }
        sleep 2
    done
    ok "network up (~${_i}s)"
    return 0
}

ntp_sync() {
    [ -n "$BB" ] || { warn "no busybox — skipping NTP"; return 1; }
    info "NTP via $BB ntpd -q -p pool.ntp.org ..."
    _out="$($BB ntpd -q -p pool.ntp.org 2>&1)"
    _rc=$?
    [ -n "$_out" ] && echo "$_out" | tail -2
    if [ "$_rc" = 0 ]; then ok "NTP synced"; return 0; fi
    warn "NTP failed (rc=$_rc)"
    return 1
}

http_sync() {
    [ -n "$CURL" ] || { warn "no curl — skipping HTTP-Date"; return 1; }
    info "HTTP-Date fallback ($CURL -kI https://www.google.com) ..."
    _d="$($CURL -k -sI https://www.google.com 2>/dev/null | grep -i '^date:' | head -1 | cut -d' ' -f2-)"
    [ -n "$_d" ] || { warn "no Date header returned"; return 1; }
    info "server date: $_d"
    if [ -n "$BB" ] && $BB date -s "$_d" >/dev/null 2>&1; then
        ok "time set from HTTP-Date"
        return 0
    fi
    if date -s "$_d" >/dev/null 2>&1; then   # toybox date fallback
        ok "time set from HTTP-Date (toybox date)"
        return 0
    fi
    warn "date -s failed"
    return 1
}

persist_rtc() {
    if [ -n "$BB" ] && $BB hwclock -w 2>/dev/null; then
        ok "hwclock -w ok"
    else
        warn "hwclock -w failed (no RTC backup cell? boot sync is the real fix)"
    fi
    # update the last-known-time cache so the NEXT boot starts from a good time
    if [ -x /system/bin/savetime.sh ]; then
        /system/bin/savetime.sh
    fi
}

if wait_network; then
    ntp_sync || http_sync
fi
persist_rtc
banner "timefix done"
