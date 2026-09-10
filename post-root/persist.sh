#!/system/bin/sh
# persist.sh — install LE1 root + clock boot persistence. MUST RUN AS ROOT.
#
# Why this exists
# ---------------
# /system/etc/init/*.rc is silently ignored by this MediaTek init: after a
# reboot `init.svc.sudaemon` is empty and the loadtime log is stale, even though
# the .rc was written correctly (verified on-device). So sudaemon never
# auto-starts and root is effectively gone on every boot.
#
# The only rc that is *always* parsed is the ramdisk's own init.rc, which defines
#     service flash_recovery /system/bin/install-recovery.sh   (class main, oneshot)
# Replacing that script with our launcher therefore gives root at every boot.
#
# Files installed:
#   /system/bin/le1-boot.sh          supervisor (restore clock, keep sudaemon,
#                                    keep Android auto_time on) — never exits
#   /system/bin/install-recovery.sh  exec's le1-boot.sh
#   /system/bin/install-recovery.sh.stock  original, backed up once
#
# Idempotent: safe to re-run.
set -u
PATH=/sbin:/system/bin:/system/xbin

SRC="${1:-$(dirname "$0")}"          # dir holding le1-boot.sh + install-recovery.sh
BOOT_SRC="$SRC/le1-boot.sh"
HOOK_SRC="$SRC/install-recovery.sh"

log() { echo "persist: $*"; }
die() { echo "persist: ERROR: $*" >&2; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || die "must run as root (got uid $(id -u 2>/dev/null))"

# --- locate sources (repo dir, then /sdcard fallback) ---------------------
[ -f "$BOOT_SRC" ]  || BOOT_SRC=/sdcard/le1/le1-boot.sh
[ -f "$HOOK_SRC" ]  || HOOK_SRC=/sdcard/le1/install-recovery.sh
[ -f "$BOOT_SRC" ]  || die "le1-boot.sh not found (looked in $SRC and /sdcard/le1)"
[ -f "$HOOK_SRC" ]  || die "install-recovery.sh not found (looked in $SRC and /sdcard/le1)"

# --- /system read-write ---------------------------------------------------
rw=0
for m in 1 2 3; do
    mount -o rw,remount /system        >/dev/null 2>&1
    mount -o rw,remount /system /system >/dev/null 2>&1
    if touch /system/xbin/.rw 2>/dev/null; then rm -f /system/xbin/.rw; rw=1; break; fi
    sleep 1
done
[ "$rw" = 1 ] || die "could not remount /system rw"

sudaemon_ok=0
[ -x /system/bin/sudaemon ] && sudaemon_ok=1
[ -x /system/xbin/su ]      || log "WARNING: /system/xbin/su missing (client)"
[ "$sudaemon_ok" = 1 ]      || log "WARNING: /system/bin/sudaemon missing (root will not persist)"

# --- back up stock install-recovery.sh exactly once -----------------------
if [ -f /system/bin/install-recovery.sh ] && [ ! -f /system/bin/install-recovery.sh.stock ]; then
    if cp -p /system/bin/install-recovery.sh /system/bin/install-recovery.sh.stock 2>/dev/null; then
        log "backed up stock install-recovery.sh -> .stock"
    else
        log "WARNING: could not back up stock install-recovery.sh"
    fi
fi

# --- install ---------------------------------------------------------------
cp "$BOOT_SRC" /system/bin/le1-boot.sh || die "copy le1-boot.sh failed"
chown 0:0 /system/bin/le1-boot.sh; chmod 0755 /system/bin/le1-boot.sh

cp "$HOOK_SRC" /system/bin/install-recovery.sh || die "copy install-recovery.sh failed"
chown 0:0 /system/bin/install-recovery.sh; chmod 0750 /system/bin/install-recovery.sh

# Belt-and-suspenders: keep the (ignored) init .rc too, in case a future build
# does honour /system/etc/init/*.rc. Only the daemon here — the boot hook is
# started by install-recovery.sh, and duplicating it would run two supervisors.
cat > /system/etc/init/sudaemon.rc <<'RC'
service sudaemon /system/bin/sudaemon --daemon
    class main
    user root

on property:sys.boot_completed=1
    start sudaemon
RC
chown 0:0 /system/etc/init/sudaemon.rc; chmod 0644 /system/etc/init/sudaemon.rc

log "installed /system/bin/le1-boot.sh + install-recovery.sh"

# --- bring it up now (no reboot needed to get root) -----------------------
if [ "$sudaemon_ok" = 1 ]; then
    if ! /system/xbin/su -c true >/dev/null 2>&1; then
        /system/bin/sudaemon --daemon </dev/null >/dev/null 2>&1 &
    fi
    sleep 1
    if /system/xbin/su -c true >/dev/null 2>&1; then
        log "su daemon RUNNING"
    else
        log "WARNING: su daemon did not answer yet"
    fi
fi

log "DONE — reboot to verify: after boot run  su -c id  and  getprop init.svc.flash_recovery"
