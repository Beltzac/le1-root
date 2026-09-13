#!/system/bin/sh
# diag.sh — boot-reliability diagnostics. Run as root.
echo "=== bootreason ==="; getprop ro.boot.bootreason; getprop sys.boot.reason
echo "=== uptime ==="; cut -d. -f1 /proc/uptime
echo "=== dmesg reset/watchdog/hang ==="
dmesg 2>/dev/null | grep -iE "wdt|watchdog|hang|panic|thermal|reboot|reset|aee|LOWMEM|lmk" | tail -30
echo "=== MTK logger / logd services ==="
for s in mtklogger mobile_log_d emdlogger aee_aed atcid logd; do echo "$s=$(getprop init.svc.$s)"; done
echo "=== AEE / crash dirs ==="
ls -la /data/aee_exp /data/misc/aee 2>&1 | head
ls -la /data/misc/le1-time/ 2>&1
echo "=== Termux boot scripts ==="
ls -la /data/data/com.termux/files/home/.termux/boot/ 2>&1
echo "--- start-sshd.sh ---"; cat /data/data/com.termux/files/home/.termux/boot/start-sshd.sh 2>&1
echo "=== adb-ish persist props ==="
getprop persist.adb.tcp.port; getprop persist.adb.root; getprop debug.adb.root
echo "=== zram/swap ==="
cat /proc/swaps 2>&1; ls /sys/block/zram0 2>&1 | head -3
free 2>/dev/null | head -3
echo "=== lmk params ==="
cat /sys/module/lowmemorykiller/parameters/minfree 2>&1
getprop | grep -iE "ro.lmk|persist.*lmk" 2>/dev/null
echo "=== cpu gov ==="
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>&1
echo "=== i/o sched ==="
cat /sys/block/mmcblk0/queue/scheduler 2>&1
echo "=== tail /data/misc/le1-time/boot.log ==="
tail -6 /data/misc/le1-time/boot.log 2>&1
