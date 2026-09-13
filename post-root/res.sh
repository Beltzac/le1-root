#!/system/bin/sh
# res.sh — resource consumers. Run as root.
echo "=== load ==="; cat /proc/loadavg
echo "=== swaps ==="; cat /proc/swaps 2>&1
echo "=== meminfo ==="; head -8 /proc/meminfo
echo
echo "=== dumpsys cpuinfo (top) ==="
dumpsys cpuinfo 2>/dev/null | head -32
echo
echo "=== top -b (by cpu) ==="
top -b -n 1 -o %CPU 2>/dev/null | head -28
echo
echo "=== top RSS procs ==="
ps -A -o PID,USER,RSS,NAME 2>/dev/null | sort -k3 -n -r | head -18
echo
echo "=== thread count ==="
ps -AT 2>/dev/null | wc -l
echo "=== per-cpu freq / load ==="
for c in 0 1 2 3; do printf "cpu%s: %s kHz\n" "$c" "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)"; done
echo "=== thermal ==="
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head
