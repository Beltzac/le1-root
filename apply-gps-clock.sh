#!/data/data/com.termux/files/usr/bin/bash
# apply-gps-clock.sh — deploy the GPS clock fallback + updated supervisor to the
# LE1, then test the NMEA stream. Idempotent; safe to re-run.
#
#   WAIT=0 bash apply-gps-clock.sh                 # apply now if online
#   H=u0_a50@100.122.21.101 WAIT=0 bash apply-gps-clock.sh   # via Tailscale
#
# (The background watcher that normally does this can die -- e.g. Termux closed --
#  so this script is the committed, re-runnable source of truth.)
set -u
H=${H:-u0_a50@172.26.39.132}
P=${P:-8022}
cd "$(dirname "$0")"
SSH() { timeout 25 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 -p "$P" "$H" "$@"; }

WAIT=${WAIT:-1}
if [ "$WAIT" = 1 ]; then
  echo "waiting for $H ..."
  ok=0
  for i in $(seq 1 240); do
    if SSH true 2>/dev/null; then ok=1; break; fi
    printf '.'; sleep 15
  done
  [ "$ok" = 1 ] || { echo; echo "OFFLINE — aborting"; exit 1; }
  echo " online"
fi
SSH true 2>/dev/null || { echo "OFFLINE — aborting"; exit 1; }

echo "== staging =="
cat ntp/gps.py       | SSH 'cat > /data/data/com.termux/files/home/gps.py'
cat ntp/gpstime.sh   | SSH 'cat > /data/data/com.termux/files/home/gpstime.sh'
cat boot/le1-boot.sh | SSH 'cat > /data/data/com.termux/files/home/le1-boot.sh'

echo "== install + test (root) =="
SSH "su -c 'mkdir -p /data/le1-ntp
cp -f /data/data/com.termux/files/home/gps.py /data/data/com.termux/files/home/gpstime.sh /data/le1-ntp/
chmod 755 /data/le1-ntp/*.sh /data/le1-ntp/*.py
mount -o rw,remount /system
cp -f /data/data/com.termux/files/home/le1-boot.sh /system/bin/le1-boot.sh
chmod 755 /system/bin/le1-boot.sh
mount -o ro,remount /system
sh -n /system/bin/le1-boot.sh && echo SUP_OK
echo ==gps stream test==; /data/data/com.termux/files/usr/bin/python3 /data/le1-ntp/gps.py 18 2>&1 | head -2
echo ==gpstime.sh==; sh /data/le1-ntp/gpstime.sh 18
echo ==now==; date \"+%F %T\"'"

echo
echo "logs: on device /data/misc/le1-time/boot.log ; NMEA port 7000 (mnld nmea2socket)"