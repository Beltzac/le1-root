#!/system/bin/sh
# Set the RTC from the (already corrected) system clock.
PREFIX=/data/data/com.termux/files/usr
E=$(date +%s 2>/dev/null)
case "$E" in ''|*[!0-9]*) echo "rtcset: no clock"; exit 1;; esac
[ "$E" -ge 1600000000 ] || { echo "rtcset: clock invalid ($E)"; exit 1; }
[ -x "$PREFIX/bin/python3" ] || { echo "rtcset: no python"; exit 1; }
LD_LIBRARY_PATH="$PREFIX/lib:/system/lib" "$PREFIX/bin/python3" /data/le1-ntp/rtcset.py
