#!/system/bin/sh
# apply-fix.sh — run as root on LE1.
# Installs the robust supervisor and removes the rc hooks this ROM ignores.
set -u
SRC=/data/data/com.termux/files/home/.le1

cp "$SRC/le1-boot.sh" /system/bin/le1-boot.sh || { echo FAIL_COPY; exit 1; }
chmod 0755 /system/bin/le1-boot.sh
chcon u:object_r:system_file:s0 /system/bin/le1-boot.sh 2>/dev/null

# Remove the two rc files this ROM does not parse (keep .bak — reversible).
[ -f /vendor/etc/init/le1-boot.rc ] && mv -f /vendor/etc/init/le1-boot.rc /vendor/etc/init/le1-boot.rc.bak
[ -f /system/etc/init/sudaemon.rc ] && mv -f /system/etc/init/sudaemon.rc /system/etc/init/sudaemon.rc.bak

# Stop any old supervisor.
pkill -f 'le1-boot.sh' 2>/dev/null
sleep 1

echo "--- install-recovery.sh (must exec le1-boot.sh) ---"
cat /system/bin/install-recovery.sh

echo "--- boot-scenario test: daemon down -> hook brings it back without su ---"
pkill -f 'sudaemon' 2>/dev/null
sleep 1
echo "daemon_after_kill=$(pidof sudaemon)"

setsid /system/bin/install-recovery.sh verify >/dev/null 2>&1 &
sleep 3
echo "daemon_after_hook=$(pidof sudaemon)"
echo "su_test=$(/system/xbin/su -c id 2>&1 | head -1)"
echo "--- boot.log tail ---"
tail -6 /data/misc/le1-time/boot.log

# Safety net: if the test left us without a daemon, start it directly.
if ! pidof sudaemon >/dev/null 2>&1; then
    echo "SAFETY: starting daemon directly"
    /system/bin/sudaemon --daemon </dev/null >/dev/null 2>&1 &
    sleep 1
    echo "daemon_now=$(pidof sudaemon)"
fi
