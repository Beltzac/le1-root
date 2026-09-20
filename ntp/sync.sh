#!/system/bin/sh
# Accurate clock via our own NTP: Android's built-in NTP is crippled on this ROM
# (and auto_time=1 re-syncs the dead RTC and reverts the clock).
PREFIX=/data/data/com.termux/files/usr
BIN=/data/le1-ntp
[ -x "$PREFIX/bin/python3" ] || { echo "ntp: no python"; exit 1; }
E=$(LD_LIBRARY_PATH="$PREFIX/lib:/system/lib" "$PREFIX/bin/python3" "$BIN/sync.py" 2>/dev/null)
case "$E" in ''|*[!0-9]*) echo "ntp: no answer"; exit 1;; esac
[ "$E" -ge 1600000000 ] || { echo "ntp: bogus $E"; exit 1; }
NOW=$(date +%s)
DIFF=$((E - NOW)); [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
if [ "$DIFF" -gt 3 ]; then
    date -u "@$E" && echo "clock set from ntp @$E (was off ${DIFF}s)"
else
    echo "clock ok (off ${DIFF}s)"
fi
printf '%s\n' "$E" > /data/misc/le1-time/last 2>/dev/null
