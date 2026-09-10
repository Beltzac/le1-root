#!/system/bin/sh
# persist.sh — install LE1 root + clock boot persistence. MUST RUN AS ROOT.
#
#   sh persist.sh [--with-recovery-hook] [--uninstall] [SRC_DIR]
#
# Default hook: /vendor/etc/init/le1-boot.rc
# ------------------------------------------
# Android init parses /vendor/etc/init unconditionally in second stage; unlike
# /system/etc/init it is not gated by ro.boot.init_rc. This is the primary
# autostart path and — unlike the old approach — it does NOT overwrite a stock
# system file, because we do not touch /system/bin/install-recovery.sh by
# default.
#
# Also installed (belt-and-suspenders, harmless if ignored):
#   /system/etc/init/sudaemon.rc  — daemon autostart if /system/etc/init *is* parsed
#   /system/bin/le1-boot.sh       — the supervisor both hooks run
#
# --with-recovery-hook additionally installs the /system/bin/install-recovery.sh
# wrapper (the ramdisk `flash_recovery` service). The stock script is preserved
# as install-recovery.sh.stock. Use it if /vendor/etc/init turns out not to be
# parsed on a given ROM.
#
# /system and /vendor are both remounted read-write; every write is idempotent.
set -u
PATH=/sbin:/system/bin:/system/xbin

SRC=""
MODE="install"
for a in "$@"; do
    case "$a" in
        --with-recovery-hook) RECOVERY_HOOK=1 ;;
        --uninstall)          MODE="uninstall" ;;
        --*)                  echo "persist: unknown option: $a" >&2; exit 1 ;;
        *)                    SRC="$a" ;;
    esac
done
RECOVERY_HOOK="${RECOVERY_HOOK:-0}"
[ -n "$SRC" ] || SRC="$(dirname "$0")"

log() { echo "persist: $*"; }
die() { echo "persist: ERROR: $*" >&2; exit 1; }

BOOT_SRC="$SRC/le1-boot.sh"
HOOK_SRC="$SRC/install-recovery.sh"
[ -f "$BOOT_SRC" ] || BOOT_SRC=/sdcard/le1/le1-boot.sh
[ -f "$HOOK_SRC" ] || HOOK_SRC=/sdcard/le1/install-recovery.sh

[ "$(id -u 2>/dev/null)" = "0" ] || die "must run as root (got uid $(id -u 2>/dev/null))"

# --- /system and /vendor read-write ---------------------------------------
rw_dir() {
    _d="$1"
    for _m in 1 2 3; do
        mount -o rw,remount "$_d"        >/dev/null 2>&1
        mount -o rw,remount "$_d" "$_d"  >/dev/null 2>&1
        if touch "$_d/.rwtest" 2>/dev/null; then rm -f "$_d/.rwtest"; return 0; fi
        sleep 1
    done
    return 1
}
rw_dir /system || die "could not remount /system rw"
log "/system rw"
if rw_dir /vendor; then VENDOR_RW=1; log "/vendor rw"; else VENDOR_RW=0; log "WARNING: /vendor not writable — vendor hook skipped"; fi

# ==========================================================================
if [ "$MODE" = "uninstall" ]; then
    log "uninstalling boot persistence"
    rm -f /vendor/etc/init/le1-boot.rc
    rm -f /system/etc/init/sudaemon.rc
    rm -f /system/bin/le1-boot.sh /system/bin/verify-boot.sh
    if [ -f /system/bin/install-recovery.sh.stock ]; then
        cp -p /system/bin/install-recovery.sh.stock /system/bin/install-recovery.sh \
            && rm -f /system/bin/install-recovery.sh.stock \
            && log "restored stock install-recovery.sh"
    fi
    log "DONE (reboot to drop the init services)"
    exit 0
fi

# --- supervisor binary + sources ------------------------------------------
[ -f "$BOOT_SRC" ] || die "le1-boot.sh not found (looked in $SRC and /sdcard/le1)"

sudaemon_ok=0
[ -x /system/bin/sudaemon ] && sudaemon_ok=1
[ -x /system/xbin/su ]      || log "WARNING: /system/xbin/su missing (client)"
[ "$sudaemon_ok" = 1 ]      || log "WARNING: /system/bin/sudaemon missing (root will not persist)"

cp "$BOOT_SRC" /system/bin/le1-boot.sh || die "copy le1-boot.sh failed"
chown 0:0 /system/bin/le1-boot.sh; chmod 0755 /system/bin/le1-boot.sh
log "installed /system/bin/le1-boot.sh"

for extra in verify-boot.sh; do
    [ -f "$SRC/$extra" ] || [ -f "/sdcard/le1/$extra" ] || continue
    cp "$SRC/$extra" "/system/bin/$extra" 2>/dev/null || cp "/sdcard/le1/$extra" "/system/bin/$extra"
    chown 0:0 "/system/bin/$extra"; chmod 0755 "/system/bin/$extra"
    log "installed /system/bin/$extra"
done

# --- primary hook: /vendor/etc/init/le1-boot.rc ---------------------------
if [ "$VENDOR_RW" = 1 ]; then
    mkdir -p /vendor/etc/init 2>/dev/null
    cat > /vendor/etc/init/le1-boot.rc <<'RC'
# LE1 root + clock persistence (installed by persist.sh).
# /vendor/etc/init is parsed unconditionally by Android init.
service le1boot /system/bin/le1-boot.sh vendor-rc
    class main
    user root
    group root

service sudaemon /system/bin/sudaemon --daemon
    class main
    user root

on property:sys.boot_completed=1
    start le1boot
    start sudaemon
RC
    chown 0:0 /vendor/etc/init/le1-boot.rc; chmod 0644 /vendor/etc/init/le1-boot.rc
    log "installed /vendor/etc/init/le1-boot.rc (primary hook)"
fi

# --- secondary hook: /system/etc/init/sudaemon.rc -------------------------
cat > /system/etc/init/sudaemon.rc <<'RC'
service sudaemon /system/bin/sudaemon --daemon
    class main
    user root

on property:sys.boot_completed=1
    start sudaemon
RC
chown 0:0 /system/etc/init/sudaemon.rc; chmod 0644 /system/etc/init/sudaemon.rc
log "installed /system/etc/init/sudaemon.rc (secondary hook)"

# --- optional fallback: /system/bin/install-recovery.sh -------------------
if [ "$RECOVERY_HOOK" = 1 ]; then
    [ -f "$HOOK_SRC" ] || die "install-recovery.sh not found (looked in $SRC and /sdcard/le1)"
    if [ -f /system/bin/install-recovery.sh ] && [ ! -f /system/bin/install-recovery.sh.stock ]; then
        cp -p /system/bin/install-recovery.sh /system/bin/install-recovery.sh.stock 2>/dev/null \
            && log "backed up stock install-recovery.sh -> .stock"
    fi
    cp "$HOOK_SRC" /system/bin/install-recovery.sh || die "copy install-recovery.sh failed"
    chown 0:0 /system/bin/install-recovery.sh; chmod 0750 /system/bin/install-recovery.sh
    log "installed /system/bin/install-recovery.sh (recovery fallback hook)"
fi

# --- bring it up now (no reboot needed to get root) -----------------------
if [ "$sudaemon_ok" = 1 ]; then
    if ! /system/xbin/su -c true >/dev/null 2>&1; then
        /system/bin/sudaemon --daemon </dev/null >/dev/null 2>&1 &
    fi
    sleep 1
    if /system/xbin/su -c true >/dev/null 2>&1; then log "su daemon RUNNING"
    else log "WARNING: su daemon did not answer yet"; fi
fi

log "DONE — verify after reboot with: sh /system/bin/verify-boot.sh  (or post-root/verify-boot.sh)"
