#!/data/data/com.termux/files/usr/bin/sh
# 20-autotime.sh (Termux:Boot) — re-apply Android auto-time at every boot.
# Vendor config resets auto_time on a full (dead-RTC) boot; Termux app lacks
# WRITE_SETTINGS, but local adb shell (uid 2000) has it. Vendor adbd does NOT
# auto-listen on the TCP port after boot, so we must ctl.restart it first.
export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin

# Force adbd to pick up the TCP port (persist.adb.tcp.port=5555).
setprop persist.adb.tcp.port 5555 2>/dev/null
setprop ctl.restart adbd 2>/dev/null

i=0
while [ $i -lt 40 ]; do
    adb connect 127.0.0.1:5555 >/dev/null 2>&1
    [ "$(adb -s 127.0.0.1:5555 get-state 2>/dev/null)" = "device" ] && break
    i=$((i+1))
    sleep 2
done
[ "$(adb -s 127.0.0.1:5555 get-state 2>/dev/null)" = "device" ] || exit 0

S="adb -s 127.0.0.1:5555"
$S shell "settings put global auto_time 1"         >/dev/null 2>&1
$S shell "settings put global ntp_server pool.ntp.org" >/dev/null 2>&1
$S shell "settings put global auto_time_zone 0"    >/dev/null 2>&1
$S shell "settings put global time_12_24 24"       >/dev/null 2>&1
