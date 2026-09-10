#!/system/bin/sh
# verify-boot.sh — report which LE1 boot-persistence hook actually fired.
#
# Run after a reboot. Works from Termux (plain getprop) but `su`/log checks are
# richer as root. No side effects.
set -u
PATH=${LE1_PATH:-/sbin:/system/bin:/system/xbin}
D=${LE1_TIME_DIR:-/data/misc/le1-time}
LOG=$D/boot.log

prop() { getprop "$1" 2>/dev/null; }
yesno() { [ -n "$1" ] && echo "$1" || echo "-"; }

echo "=== LE1 boot persistence check ==="
echo "date:        $(date 2>/dev/null)  (epoch $(date +%s 2>/dev/null))"
echo "init.svc.le1boot:       $(yesno "$(prop init.svc.le1boot)")"
echo "init.svc.sudaemon:      $(yesno "$(prop init.svc.sudaemon)")"
echo "init.svc.flash_recovery:$(yesno "$(prop init.svc.flash_recovery)")"
echo
echo "--- files ---"
for f in /vendor/etc/init/le1-boot.rc \
         /system/etc/init/sudaemon.rc \
         /system/bin/le1-boot.sh \
         /system/bin/install-recovery.sh \
         /system/bin/install-recovery.sh.stock; do
    if [ -e "$f" ]; then echo "present  $f"; else echo "absent   $f"; fi
done
echo
echo "--- root ---"
if [ -x /system/xbin/su ] && /system/xbin/su -c id 2>/dev/null | grep -q 'uid=0'; then
    echo "su: ROOT OK  ($(/system/xbin/su -c id 2>/dev/null))"
else
    echo "su: NOT WORKING"
fi
echo
echo "--- supervisor log (last 10) ---"
if [ -f "$LOG" ]; then tail -10 "$LOG" 2>/dev/null; else echo "(no $LOG — supervisor never ran)"; fi
echo
echo "--- verdict ---"
if [ "$(prop init.svc.le1boot)" = "running" ]; then
    echo "vendor hook (/vendor/etc/init/le1-boot.rc) is LIVE"
elif [ "$(prop init.svc.flash_recovery)" = "running" ] && grep -q 'le1-boot' /system/bin/install-recovery.sh 2>/dev/null; then
    echo "recovery hook (/system/bin/install-recovery.sh) is LIVE"
elif [ "$(prop init.svc.sudaemon)" = "running" ]; then
    echo "only the secondary sudaemon rc is live (no supervisor — clock not managed)"
else
    echo "NO hook is live — check dmesg for init parse errors"
fi
