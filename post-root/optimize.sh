#!/system/bin/sh
# optimize.sh — LE1 performance + stability. EVERY action is reversible.
# Undo everything with: restore.sh  (reads the manifest).
_self_dir="$(cd "$(dirname "$0")" && pwd)"
. "$_self_dir/common.sh"

banner "optimize: loggers + DuraSpeed + fstrim + logd + governor"

require_root

# ---- 1. Disable MTK logging daemons (rename .rc -> .disabled, reversible) ---
info "disabling MTK logging daemons (rename to .disabled)"
sys_rw
for _rc in \
    /system/etc/init/mtklogger.rc \
    /system/etc/init/mobile_log_d.rc \
    /system/etc/init/emdlogger1.rc \
    /system/etc/init/emdlogger5.rc \
    /system/etc/init/mdlogger.rc \
    /system/etc/init/aee_aed.rc \
    /system/etc/init/aee_aedv.rc \
    /system/etc/init/atcid.rc \
    /system/etc/init/netdiag.rc \
    /system/etc/init/cmddumper.rc \
    /system/etc/init/bootlogoupdater.rc \
; do
    disable_rc "$_rc"
done
sys_ro

# ---- 2. DuraSpeed: kills background apps (why Termux sshd dies) -------------
# TODO: confirm exact package on-device: pm list packages | grep -i duraspeed
DURASPEED_PKG="${DURASPEED_PKG:-com.mediatek.duraspeed}"
if pm list packages 2>/dev/null | grep -qi duraspeed; then
    disable_app "$DURASPEED_PKG"
else
    warn "DuraSpeed pkg not found ($DURASPEED_PKG) — TODO: confirm + freeze manually"
fi

# ---- 3. fstrim eMMC (safe, not a config change) -----------------------------
run vdc fstrim dotrim

# ---- 4. shrink logd buffers (record old value for restore) ------------------
_old="$(getprop persist.log.size)"
setprop persist.log.size 256k
record "setprop" "persist.log.size" "${_old:-<unset>}"
ok "logd size -> 256k (was: ${_old:-<unset>})"

# ---- 5. CPU governor -> interactive if laggy (record old value) -------------
_gov="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
_oldg="$(cat "$_gov" 2>/dev/null)"
if [ -n "$_oldg" ] && [ "$_oldg" != "interactive" ]; then
    if echo interactive > "$_gov" 2>/dev/null; then
        ok "governor -> interactive (was: $_oldg)"
        record "governor" "$_oldg"
    else
        warn "governor write failed (kept: $_oldg)"
    fi
else
    info "governor already $_oldg — unchanged"
fi

# ---- 6. zRAM/swap report (no change) ----------------------------------------
info "swap: $(cat /proc/swaps 2>/dev/null | tail -n +2 | wc -l) active swap line(s)"

banner "optimize done — reboot recommended (restore.sh to undo)"
