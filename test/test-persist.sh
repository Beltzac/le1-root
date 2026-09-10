#!/usr/bin/env bash
# test-persist.sh — VM integration test for the LE1 root+clock persistence.
#
# Runs the real post-root/persist.sh + boot/le1-boot.sh + boot/install-recovery.sh
# + post-root/verify-boot.sh inside an Alpine Linux rootfs under proot (fake
# root), with a fake /system and /vendor and stubs for the Android-only pieces
# (sudaemon, su, settings, getprop).
#
# Verifies:
#   1. default install writes the VENDOR hook and leaves install-recovery.sh alone
#   2. supervisor boot chain: sudaemon start, clock restore attempt, auto_time,
#      ntp, time cache, logging
#   3. --with-recovery-hook installs the fallback and backs up the stock script
#   4. verify-boot.sh reports the live hook
#
# Requires: proot + proot-distro + an Alpine rootfs (`proot-distro install alpine`).
# Usage: bash test/test-persist.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

ALPINE=""
for d in "$PREFIX/var/lib/proot-distro/containers/alpine/rootfs" \
         "$PREFIX/var/lib/proot-distro/installed-rootfs/alpine"; do
    [ -d "$d" ] && ALPINE="$d" && break
done

missing=""
command -v proot        >/dev/null 2>&1 || missing="proot"
command -v proot-distro >/dev/null 2>&1 || missing="$missing proot-distro"
[ -n "$ALPINE" ] || missing="$missing alpine-rootfs"
if [ -n "$missing" ]; then
    echo "SKIP: need:$missing"
    echo "      pkg install proot proot-distro && proot-distro install alpine"
    exit 0
fi

WORK="$(mktemp -d)/g"; mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

# --- fake /system and /vendor --------------------------------------------
mkdir -p "$WORK"/system/{bin,xbin,etc/init,src} "$WORK"/vendor/etc/init \
         "$WORK"/data/local/tmp "$WORK"/sbin

printf '#!/system/bin/sh\necho STOCK\n' >"$WORK/system/bin/install-recovery.sh"

cat >"$WORK/system/bin/sudaemon" <<'EOF'
#!/bin/sh
echo "$@" > /data/sudaemon.args
touch /data/su_ok
exit 0
EOF

cat >"$WORK/system/bin/settings" <<'EOF'
#!/bin/sh
case "$*" in
  "get global auto_time") [ -f /data/auto_time ] && cat /data/auto_time || echo 0 ;;
  "put global auto_time 1") echo 1 > /data/auto_time ;;
esac
echo "$*" >> /data/settings.calls
exit 0
EOF

cat >"$WORK/system/bin/getprop" <<'EOF'
#!/bin/sh
line=$(grep "^$1=" /data/props 2>/dev/null)
echo "${line#*=}"
EOF

cat >"$WORK/system/xbin/su" <<'EOF'
#!/bin/sh
[ -f /data/su_ok ] && exit 0 || exit 1
EOF

printf '#!/bin/sh\nexit 0\n' >"$WORK/sbin/mount"   # remounts always OK

chmod +x "$WORK/system/bin/"* "$WORK/system/xbin/"* "$WORK/sbin/"*
# toybox-style core utils on /system/bin (busybox applets; PATH is /sbin:/system/bin:/system/xbin)
for a in sh cat tr mv chmod mkdir sleep date id cp chown rm dirname echo touch ln grep tail cut head; do
    ln -sf /bin/busybox "$WORK/system/bin/$a"
done

# --- the code under test --------------------------------------------------
cp "$REPO/post-root/persist.sh"     "$WORK/system/bin/persist.sh"
cp "$REPO/post-root/verify-boot.sh" "$WORK/system/src/verify-boot.sh"
cp "$REPO/boot/le1-boot.sh"         "$WORK/system/src/le1-boot.sh"
cp "$REPO/boot/install-recovery.sh" "$WORK/system/src/install-recovery.sh"

# --- run inside the Alpine VM --------------------------------------------
mkdir -p "$ALPINE/system" "$ALPINE/data" "$ALPINE/vendor" 2>/dev/null
BINDS=(--bind "$WORK/system:/system" --bind "$WORK/vendor:/vendor"
       --bind "$WORK/data:/data" --bind "$WORK/sbin:/sbin")
RUN() {
    PROOT_NO_SECCOMP=1 proot-distro login --isolated alpine "${BINDS[@]}" -- /bin/sh -c "$1"
}

echo "=== 1. install, default (vendor hook) ==="
RUN "sh /system/bin/persist.sh /system/src 2>&1"

echo
echo "=== 2. install results ==="
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2' want '$3')"; fail=1; fi; }
cnt() { c=$(grep -c "$2" "$1" 2>/dev/null); printf '%s' "${c:-0}"; }

chk "vendor hook installed"     "$(cnt "$WORK/vendor/etc/init/le1-boot.rc" 'service le1boot')" "1"
chk "supervisor installed"      "$(cnt "$WORK/system/bin/le1-boot.sh" 'le1-boot start')" "1"
chk "secondary rc installed"    "$(cnt "$WORK/system/etc/init/sudaemon.rc" 'service sudaemon')" "1"
chk "verify-boot installed"     "$([ -x "$WORK/system/bin/verify-boot.sh" ] && echo yes || echo no)" "yes"
chk "install-recovery UNTOUCHED" "$(cat "$WORK/system/bin/install-recovery.sh")" "$(printf '#!/system/bin/sh\necho STOCK')"
chk "no stock backup made"      "$([ -e "$WORK/system/bin/install-recovery.sh.stock" ] && echo exists || echo absent)" "absent"

echo
echo "=== 3. boot (init runs the vendor rc service -> le1-boot.sh) ==="
# Seed a FUTURE cache so restore_clock actually attempts the set (fails as non-root
# in the VM, which is exactly what we want to observe).
mkdir -p "$WORK/data/misc/le1-time"; echo 2000000000 >"$WORK/data/misc/le1-time/last"
# LE1_PATH adds /bin for the Alpine coreutils; LE1_LOOP_SECS=1 bounds the test.
PROOT_NO_SECCOMP=1 timeout 8 proot-distro login --isolated alpine "${BINDS[@]}" -- \
    /usr/bin/env LE1_PATH=/sbin:/system/bin:/system/xbin:/bin LE1_LOOP_SECS=1 \
    /system/bin/le1-boot.sh vendor-rc >/dev/null 2>&1

BL="$WORK/data/misc/le1-time/boot.log"
chk "sudaemon started"          "$(cnt "$WORK/data/sudaemon.args" '\-\-daemon')" "1"
chk "clock restore attempted"   "$(cnt "$BL" 'clock restore')" "1"
chk "supervisor logged hook"    "$(cnt "$BL" 'hook=vendor-rc')" "1"
chk "auto_time enforced"        "$(cat "$WORK/data/auto_time" 2>/dev/null)" "1"
chk "ntp_server set"            "$(cnt "$WORK/data/settings.calls" 'ntp_server pool.ntp.org')" "1"
chk "time cache written"        "$([ -s "$WORK/data/misc/le1-time/last" ] && echo yes || echo no)" "yes"

echo
echo "=== 4. --with-recovery-hook fallback ==="
RUN "sh /system/bin/persist.sh --with-recovery-hook /system/src 2>&1 | tail -2"
chk "recovery hook installed"   "$(cnt "$WORK/system/bin/install-recovery.sh" 'exec /system/bin/le1-boot.sh recovery')" "1"
chk "stock backed up"           "$(cnt "$WORK/system/bin/install-recovery.sh.stock" 'echo STOCK')" "1"

echo
echo "=== 5. verify-boot.sh verdict ==="
printf 'init.svc.le1boot=running\ninit.svc.sudaemon=running\n' >"$WORK/data/props"
RUN "LE1_PATH=/sbin:/system/bin:/system/xbin:/bin sh /system/bin/verify-boot.sh 2>&1" >"$WORK/verify.out" 2>&1
cat "$WORK/verify.out"
chk "verify reports vendor hook LIVE" "$(cnt "$WORK/verify.out" 'vendor hook')" "1"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
