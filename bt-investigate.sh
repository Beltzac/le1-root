#!/data/data/com.termux/files/usr/bin/bash
# bt-investigate.sh — READ-ONLY Bluetooth / tethering capability probe for the LE1 head unit.
#
# Run from the helper phone (Termux) while LE1 is powered on:
#     bash ~/le1-root/bt-investigate.sh
#     bash ~/le1-root/bt-investigate.sh > ~/le1-bt-report.txt 2>&1
#
# It makes NO changes on the device. `su` is only used when the sudaemon is confirmed
# running (the /system/xbin/su binary doubles as the CVE-2019-2215 exploit and
# self-triggers when the daemon is down — so we hard-gate on `pidof sudaemon`).
set -u

HOST="${LE1_HOST:-u0_a50@100.124.251.81}"
PORT="${LE1_PORT:-8022}"

SSH=(ssh -p "$PORT" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no "$HOST")

echo "### LE1 Bluetooth investigation — $(date -u +%FT%TZ)"
echo "### target: $HOST:$PORT"

exec 3>&1
"${SSH[@]}" 'bash -s' >&3 <<'REMOTE'
PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin:/system/sbin:/vendor/bin
export PATH

SAY(){ printf '\n=================== %s ===================\n' "$1"; }
SUB(){ printf '\n----- %s -----\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

SAY "0. identity / environment"
echo "model      : $(getprop ro.product.model 2>/dev/null)"
echo "build      : $(getprop ro.build.version.release 2>/dev/null) / $(getprop ro.build.id 2>/dev/null)"
echo "fingerprint: $(getprop ro.build.fingerprint 2>/dev/null)"
echo "platform   : $(getprop ro.board.platform 2>/dev/null) / $(getprop ro.hardware 2>/dev/null)"
echo "selinux    : $(getenforce 2>/dev/null)"
echo "date       : $(date 2>/dev/null)"

if pidof sudaemon >/dev/null 2>&1; then SU=1; echo "sudaemon   : RUNNING (su is safe to call)"; else SU=0; echo "sudaemon   : NOT running (skipping all su)"; fi

# R <command>  -> run as root when safe, otherwise as the Termux user
R(){ if [ "$SU" = 1 ]; then su -c "$1" 2>/dev/null; else sh -c "$1" 2>/dev/null; fi; }

SAY "1. Bluetooth device nodes / kernel modules"
SUB "char devices"
for n in /dev/stpbt /dev/stp /dev/tun /dev/rfkill /dev/vhci; do
    if [ -e "$n" ]; then ls -lZ "$n" 2>/dev/null || ls -l "$n"; else echo "$n : absent"; fi
done
SUB "stp / combo nodes"
ls -l /dev/stp* /dev/wmt* 2>/dev/null || echo "(none)"
SUB "lsmod"
lsmod 2>/dev/null | grep -iE 'bt|wlan|wmt|combo|conn' || lsmod 2>/dev/null || echo "(lsmod unavailable)"
SUB "/proc/modules bt-ish"
grep -iE 'bt|wmt|combo' /proc/modules 2>/dev/null || echo "(none)"

SAY "2. AUTHORITATIVE kernel config (/proc/config.gz via su)"
if [ "$SU" = 1 ]; then
    KC=$(R "zcat /proc/config.gz" 2>/dev/null)
    if [ -n "$KC" ]; then
        KCG(){ printf '%s\n' "$KC" | grep -E "$1" || echo "(none)"; }
        SUB "Bluetooth core + profiles"
        KCG 'CONFIG_BT=|CONFIG_BT_|CONFIG_BLUETOOTH'
        SUB "TUN / PPP / bridge (needed for PAN tethering)"
        KCG 'CONFIG_TUN=|CONFIG_PPP|CONFIG_BRIDGE=|CONFIG_VETH=|CONFIG_DUMMY='
        SUB "netfilter (NAT for tethering)"
        KCG 'CONFIG_NF_CONNTRACK=|CONFIG_IP_NF_|CONFIG_NETFILTER_XT_TARGET_(MASQUERADE|NAT)'
    else
        echo "/proc/config.gz not readable even via su"
    fi
else
    echo "skipped (no su)"
fi

SAY "3. Bluetooth stack presence (property / service / package)"
SUB "props"
getprop 2>/dev/null | grep -iE 'blue|bluetooth|\.bt\.|stpbt' || echo "(none)"
SUB "init services"
getprop 2>/dev/null | grep -iE 'init\.svc\..*(bt|blue)' || echo "(none)"
SUB "binder services"
service list 2>/dev/null | grep -iE 'blue|bluetooth|teth' || (R "service list" | grep -iE 'blue|bluetooth|teth')
SUB "packages (all)"
(R "pm list packages" | grep -iE 'blue|bt|wwc2|reglink' ) || echo "(none)"
SUB "system app dirs"
ls /system/app 2>/dev/null | grep -iE 'blue|bt' || echo "(none in /system/app)"
ls /system/priv-app 2>/dev/null | grep -iE 'blue|bt' || echo "(none in /system/priv-app)"
ls /system/preinstall_apks 2>/dev/null || true
SUB "BT HAL / libs"
ls -l /system/lib/hw/*bluetooth* /system/lib64/hw/*bluetooth* /vendor/lib/hw/*bluetooth* 2>/dev/null || echo "(no bluetooth HAL shim found)"
ls /system/etc/bluetooth* -d 2>/dev/null && ls -l /system/etc/bluetooth/ 2>/dev/null

SAY "4. Live Bluetooth state (dumpsys bluetooth_manager)"
D=$(R "dumpsys bluetooth_manager" 2>/dev/null)
if [ -n "$D" ]; then
    echo "$D" | head -60
    SUB "profile keywords"
    echo "$D" | grep -iE 'Pan|Nap|PANU|profile|A2dp|Hfp|enabled|address|name|version' | head -40
else
    echo "dumpsys bluetooth_manager empty / not permitted"
fi

SAY "5. Tethering support (framework + services)"
SUB "framework-res bt-pan regex (this decides if Bluetooth tethering UI exists)"
FR=/system/framework/framework-res.apk
if [ -e "$FR" ]; then
    echo "framework-res: $FR ($(stat -c %s "$FR" 2>/dev/null || echo '?') bytes)"
    if grep -a -q 'config_tether_bluetooth_regexs' "$FR" 2>/dev/null; then
        echo "  resource config_tether_bluetooth_regexs : PRESENT"
    else
        echo "  resource config_tether_bluetooth_regexs : not found as raw string (may be compressed in resources.arsc)"
    fi
    if grep -a -q 'bt-pan' "$FR" 2>/dev/null; then
        echo "  value \"bt-pan\"                         : PRESENT  <-- Bluetooth tethering ENABLED"
    else
        echo "  value \"bt-pan\"                         : ABSENT   <-- Bluetooth tethering likely HIDDEN"
    fi
else
    echo "framework-res.apk not found"
fi
SUB "tethering services / commands"
service list 2>/dev/null | grep -iE 'teth|connectivity|netd|netpolicy'
(R "cmd -l" | grep -iE 'teth|connect') || true
SUB "settings keys"
(R "settings list global" | grep -iE 'teth|blue|pan') || echo "(none)"
(R "settings list secure" | grep -iE 'blue|teth') || echo "(none)"
SUB "settings app tether activities"
(R "dumpsys package com.android.settings" | grep -iE 'Tether' ) | head -20 || echo "(none)"
SUB "connectivity tether state"
(R "dumpsys connectivity" | grep -iE 'tether|pan|bt-' ) | head -40 || echo "(none)"

SAY "6. Network interfaces (is there a bt-pan / tun?)"
SUB "ip link"
(R "ip link" || ifconfig -a) 2>/dev/null | head -40
SUB "addresses"
(R "ip -4 addr" || ifconfig -a) 2>/dev/null | grep -E 'inet |bt-pan|tun|wlan|eth' | head -30
SUB "/proc/net/dev"
cat /proc/net/dev 2>/dev/null

SAY "7. Upstream internet path (what would be shared)"
(R "ip route" || R "netstat -rn") 2>/dev/null | head -20
(R "getprop" | grep -iE 'dhcp\.|net\.dns|wifi\.' ) | head -20

SAY "8. ADB status"
echo "persist.adb.tcp.port = $(getprop persist.adb.tcp.port 2>/dev/null)"
echo "init.svc.adbd         = $(getprop init.svc.adbd 2>/dev/null)"
echo "ro.secure             = $(getprop ro.secure 2>/dev/null)"

SAY "9. Termux-side tools usable for a bridge (on the LE1)"
for t in socat rfcomm bluetoothctl hciconfig nc ncat netcat python3 clang ssh sshd dropbear busybox; do
    p=$(command -v "$t" 2>/dev/null)
    printf '%-12s %s\n' "$t" "${p:-MISSING}"
done
python3 -c 'import bluetooth; print("python bluetooth module: present")' 2>/dev/null \
  || echo "python bluetooth module: absent"

SAY "10. MARKERS (machine-readable summary)"
echo "MARKER stpbt=$([ -c /dev/stpbt ] && echo yes || echo no)"
echo "MARKER bth_package=$(R "pm list packages" | grep -ciE 'bluetooth')"
echo "MARKER bt_pan_regex=$(grep -a -q 'bt-pan' /system/framework/framework-res.apk 2>/dev/null && echo yes || echo no)"
echo "MARKER tether_service=$(service list 2>/dev/null | grep -ciE 'teth')"
echo "MARKER tun_dev=$([ -c /dev/tun ] && echo yes || echo no)"
echo "MARKER sudaemon=$SU"
echo "=================== END ==================="
REMOTE

echo
echo "### report complete."
