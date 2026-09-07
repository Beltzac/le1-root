#!/data/data/com.termux/files/usr/bin/sh
# 20-autotime.sh (Termux:Boot) — re-apply Android auto-time at every boot.
# The head unit's vendor config resets auto_time/ntp_server to defaults on
# boot, so Android's own NTP sync (which DOES correct the clock) gets disabled.
# Termux (u0_a50) lacks WRITE_SETTINGS, but the local adb shell (uid 2000) has
# it — so we drive `settings` through adb over localhost.
# persist.adb.tcp.port=5555 is already set (survives reboot via /data/property).
export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin
S="adb -s 127.0.0.1:5555"

# Wait for adbd to come up (it listens on 5555 once persist.adb.tcp.port is set)
i=0
while [ $i -lt 40 ]; do
    adb connect 127.0.0.1:5555 >/dev/null 2>&1
    [ "$(adb -s 127.0.0.1:5555 get-state 2>/dev/null)" = "device" ] && break
    i=$((i+1))
    sleep 2
done
[ "$(adb -s 127.0.0.1:5555 get-state 2>/dev/null)" = "device" ] || exit 0

$S shell "settings put global auto_time 1"        >/dev/null 2>&1
$S shell "settings put global ntp_server pool.ntp.org" >/dev/null 2>&1
$S shell "settings put global auto_time_zone 0"   >/dev/null 2>&1
$S shell "settings put global time_12_24 24"      >/dev/null 2>&1
# preserve local timezone (don't let network/NITZ flip it)
$S shell "getprop persist.sys.timezone" >/dev/null 2>&1
