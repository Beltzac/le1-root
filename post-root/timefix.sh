#!/system/bin/sh
# timefix.sh — LE1 boot clock sync, NETWORK path (NTP, then HTTP-Date fallback).
# Runs as root via init (see timefix.rc). GPS runs separately (gpstime.sh).
LOG_FILE=/data/local/tmp/le1-timefix.log
TAG=LE1-timefix
. /system/bin/le1-common.sh 2>/dev/null || { echo "timefix: le1-common.sh missing" >&2; exit 1; }

banner "timefix: network clock sync"

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
    have busybox || { warn "no busybox — skipping NTP"; return 1; }
    info "NTP via busybox ntpd -q -p pool.ntp.org ..."
    _out="$(busybox ntpd -q -p pool.ntp.org 2>&1)"
    _rc=$?
    [ -n "$_out" ] && echo "$_out" | tail -2
    if [ "$_rc" = 0 ]; then ok "NTP synced"; return 0; fi
    warn "NTP failed (rc=$_rc)"
    return 1
}

http_sync() {
    have curl || { warn "no curl — skipping HTTP-Date"; return 1; }
    info "HTTP-Date fallback (curl -kI https://www.google.com) ..."
    _d="$(curl -k -sI https://www.google.com 2>/dev/null | grep -i '^date:' | head -1 | cut -d' ' -f2-)"
    [ -n "$_d" ] || { warn "no Date header returned"; return 1; }
    info "server date: $_d"
    if have busybox && busybox date -s "$_d" >/dev/null 2>&1; then
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
    if have busybox && busybox hwclock -w 2>/dev/null; then
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
