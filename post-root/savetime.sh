#!/system/bin/sh
# savetime.sh — persist the current time so the next boot can restore it.
# Fixes the dead-RTC boot (clock resets to 2009) by letting loadtime.sh start
# from the last known time instead of 16 years stale, so TLS certs validate
# immediately while GPS/NTP correct the clock precisely.
LOG_FILE=/data/local/tmp/le1-savetime.log
TAG=LE1-savetime
. /system/bin/le1-common.sh 2>/dev/null || { echo "savetime: le1-common.sh missing" >&2; exit 1; }

CACHE_DIR="${CACHE_DIR:-/data/misc/le1-time}"
CACHE="$CACHE_DIR/last"

require_root

mkdir -p "$CACHE_DIR" 2>/dev/null || die "mkdir failed: $CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null

if have busybox; then
    _epoch="$(busybox date +%s 2>/dev/null)"
else
    _epoch="$(date +%s 2>/dev/null)"
fi
case "$_epoch" in
    ''|*[!0-9]*) err "could not read epoch ('$_epoch')"; exit 1 ;;
esac

# atomic write (write temp, then rename) so a power cut never corrupts the cache
echo "$_epoch" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE" || die "write failed: $CACHE"
chmod 600 "$CACHE"
ok "saved time: epoch $_epoch ($(date '+%F %T'))"
