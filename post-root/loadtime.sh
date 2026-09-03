#!/system/bin/sh
# loadtime.sh — restore the last-known time at boot (early, once /data is up).
#
# Without this: dead RTC -> clock is 2009 -> every TLS cert "not yet valid".
# With this:    clock starts from the last save (hours/days stale) -> most certs
#               validate immediately, then timefix.sh / gpstime.sh correct it.
LOG_FILE=/data/local/tmp/le1-loadtime.log
TAG=LE1-loadtime
. /system/bin/le1-common.sh 2>/dev/null || { echo "loadtime: le1-common.sh missing" >&2; exit 1; }

CACHE="${CACHE:-/data/misc/le1-time/last}"
# sanity floor: a cached time older than this is too stale to help TLS anyway
MIN_EPOCH=1600000000      # 2020-09-13

require_root

[ -f "$CACHE" ] || { warn "no cached time ($CACHE) — nothing to restore yet"; exit 0; }

_epoch="$(cat "$CACHE" 2>/dev/null | tr -d '[:space:]')"
case "$_epoch" in
    ''|*[!0-9]*) err "cache corrupted ('$_epoch') — ignoring"; exit 1 ;;
esac

if [ "$_epoch" -lt "$MIN_EPOCH" ]; then
    warn "cached epoch $_epoch is pre-2020 (too stale to help TLS) — skipping"
    exit 0
fi

_now="$(date +%s 2>/dev/null)"
# only restore when the running clock is BEHIND the cache (the dead-RTC case)
if [ -n "$_now" ] && [ "$_now" -ge "$_epoch" ]; then
    info "clock already >= cached ($_now >= $_epoch) — leaving it alone"
    exit 0
fi

info "restoring cached time: epoch $_epoch (clock was: ${_now:-unknown} = $(date '+%F %T' 2>/dev/null))"

if have busybox; then
    _ts="$(busybox date -d "@$_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
else
    # toybox date on Android 8.1 lacks -d @epoch (GNU ext) — busybox is REQUIRED here.
    # loadtime runs from /system post-root, so busybox must be deployed first (post-root.sh deploy).
    warn "no busybox (need date -d) — cannot restore cached time; skipping"
    exit 1
fi
[ -n "$_ts" ] || { warn "could not format epoch $_epoch — skipping restore"; exit 1; }

if have busybox && busybox date -s "$_ts" >/dev/null 2>&1; then
    ok "clock restored to $_ts (cached epoch $_epoch)"
elif date -s "$_ts" >/dev/null 2>&1; then
    ok "clock restored to $_ts (toybox date)"
else
    warn "date -s failed"
    exit 1
fi
