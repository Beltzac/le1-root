#!/system/bin/sh
# loadtime.sh — restore the last-known time at boot (early, once /data is up).
# Toybox-compatible: uses date -u @EPOCH (no busybox date -d needed).
#
# Without this: dead RTC -> clock is 2009 -> every TLS cert "not yet valid".
# With this:    clock starts from the last save (hours/days stale) -> most certs
#               validate immediately, then the Termux time-bootstrap corrects it.
LOG_FILE=/data/local/tmp/le1-loadtime.log
TAG=LE1-loadtime
. /system/bin/le1-common.sh 2>/dev/null || { echo "loadtime: le1-common.sh missing" >&2; exit 1; }

CACHE="${CACHE:-/data/misc/le1-time/last}"
MIN_EPOCH=1600000000      # 2020-09-13 (older than this is too stale to help TLS)

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
if [ -n "$_now" ] && [ "$_now" -ge "$_epoch" ]; then
    info "clock already >= cached ($_now >= $_epoch) — leaving it alone"
    exit 0
fi

info "restoring cached time: epoch $_epoch (clock was: ${_now:-unknown})"

# toybox + busybox both accept date -u @EPOCH
if date -u "@$_epoch" >/dev/null 2>&1; then
    ok "clock restored to epoch $_epoch ($(date '+%F %T'))"
    exit 0
fi
warn "date -u @epoch failed"
exit 1
