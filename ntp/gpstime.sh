#!/system/bin/sh
# GPS time fallback: set the clock from the MTK GPS NMEA stream (offline).
# nmea2socket is ON by default on this platform (mnld, 127.0.0.1:7000); YGPS can
# re-enable it from its UI ("Enable nmea2socket"). No internet required, but a
# sky fix is -- so this is the fallback when NTP has no network.
PREFIX=/data/data/com.termux/files/usr
BIN=/data/le1-ntp
[ -x "$PREFIX/bin/python3" ] || { echo "gps: no python"; exit 1; }
# make sure the daemon is up (harmless if already running)
start mnld 2>/dev/null
E=$(LD_LIBRARY_PATH="$PREFIX/lib:/system/lib" "$PREFIX/bin/python3" "$BIN/gps.py" "${1:-20}" 2>/dev/null)
case "$E" in ''|*[!0-9]*) echo "gps: no fix"; exit 1;; esac
[ "$E" -ge 1600000000 ] || { echo "gps: bogus $E"; exit 1; }
NOW=$(date +%s)
DIFF=$((E - NOW)); [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
if [ "$DIFF" -gt 3 ]; then
    date -u "@$E" && echo "clock set from gps @$E (was off ${DIFF}s)"
else
    echo "gps ok (off ${DIFF}s)"
fi
printf '%s\n' "$E" > /data/misc/le1-time/last 2>/dev/null