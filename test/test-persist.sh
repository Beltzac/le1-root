#!/usr/bin/env bash
# test-persist.sh — VM integration test for the LE1 root+clock persistence.
#
# Runs the real post-root/persist.sh + boot/le1-boot.sh + boot/install-recovery.sh
# inside an Alpine Linux rootfs under proot (fake root), with:
#   * a fake /system (stock install-recovery.sh, sudaemon/su/settings stubs)
#   * the actual scripts from this repo
# and verifies the install + the boot supervisor end to end.
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

# --- fake /system ---------------------------------------------------------
mkdir -p "$WORK"/system/{bin,xbin,etc/init,src} "$WORK"/data/local/tmp "$WORK"/sbin

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

cat >"$WORK/system/xbin/su" <<'EOF'
#!/bin/sh
[ -f /data/su_ok ] && exit 0 || exit 1
EOF

printf '#!/bin/sh\nexit 0\n' >"$WORK/sbin/mount"   # /system remount always OK

chmod +x "$WORK/system/bin/"* "$WORK/system/xbin/"* "$WORK/sbin/"*
# toybox-style core utils on /system/bin (busybox applets; PATH is /sbin:/system/bin:/system/xbin)
for a in sh cat tr mv chmod mkdir sleep date id cp chown rm dirname echo touch ln; do
    ln -sf /bin/busybox "$WORK/system/bin/$a"
done

# --- the code under test --------------------------------------------------
# Sources live in a separate dir (persist.sh takes it as $1) so the stock
# /system/bin/install-recovery.sh is not clobbered before persist.sh backs it up.
cp "$REPO/post-root/persist.sh"     "$WORK/system/bin/persist.sh"
cp "$REPO/boot/le1-boot.sh"         "$WORK/system/src/le1-boot.sh"
cp "$REPO/boot/install-recovery.sh" "$WORK/system/src/install-recovery.sh"

# --- run inside the Alpine VM --------------------------------------------
mkdir -p "$ALPINE/system" "$ALPINE/data" 2>/dev/null
BINDS=(--bind "$WORK/system:/system" --bind "$WORK/data:/data" --bind "$WORK/sbin:/sbin")
RUN() {
    PROOT_NO_SECCOMP=1 proot-distro login --isolated alpine "${BINDS[@]}" -- /bin/sh -c "$1"
}

echo "=== 1. install (persist.sh) ==="
RUN "sh /system/bin/persist.sh /system/src 2>&1"

echo
echo "=== 2. results ==="
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2' want '$3')"; fail=1; fi; }

chk "stock backed up"        "$(grep -c 'echo STOCK' "$WORK/system/bin/install-recovery.sh.stock" 2>/dev/null || echo 0)" "1"
chk "hook installed"         "$(grep -c 'exec /system/bin/le1-boot.sh' "$WORK/system/bin/install-recovery.sh" 2>/dev/null || echo 0)" "1"
chk "supervisor installed"   "$(grep -c 'le1-boot start' "$WORK/system/bin/le1-boot.sh" 2>/dev/null || echo 0)" "1"
chk "init .rc written"       "$(grep -c 'service sudaemon' "$WORK/system/etc/init/sudaemon.rc" 2>/dev/null || echo 0)" "1"

echo
echo "=== 3. boot (init runs install-recovery.sh -> le1-boot.sh) ==="
# LE1_PATH adds /bin so the Alpine coreutils are reachable; LE1_LOOP_SECS=1 bounds the test.
PROOT_NO_SECCOMP=1 timeout 8 proot-distro login --isolated alpine "${BINDS[@]}" -- \
    /usr/bin/env LE1_PATH=/sbin:/system/bin:/system/xbin:/bin LE1_LOOP_SECS=1 \
    /system/bin/install-recovery.sh >/dev/null 2>&1

chk "sudaemon started"       "$(grep -c -- '--daemon' "$WORK/data/sudaemon.args" 2>/dev/null || echo 0)" "1"
chk "clock cache written"    "$([ -s "$WORK/data/misc/le1-time/last" ] && echo yes || echo no)" "yes"
chk "supervisor logged"      "$(grep -c 'le1-boot start' "$WORK/data/misc/le1-time/boot.log" 2>/dev/null || echo 0)" "1"
chk "auto_time enforced"     "$(cat "$WORK/data/auto_time" 2>/dev/null)" "1"
chk "ntp_server set"         "$(grep -c 'ntp_server pool.ntp.org' "$WORK/data/settings.calls" 2>/dev/null || echo 0)" "1"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
