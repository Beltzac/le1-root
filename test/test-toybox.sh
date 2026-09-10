#!/usr/bin/env bash
# test-toybox.sh — run the LE1 boot scripts against the DEVICE'S OWN toybox/mksh.
#
# The Alpine/proot test (test-persist.sh) uses busybox. Android actually ships
# toybox + mksh, and some applet semantics differ in ways that matter:
#
#   toybox  `date -u @EPOCH`  -> SETS the clock (needs root; EPERM as a user)
#   busybox `date -u @EPOCH`  -> just PRINTS the date, exit 0
#
# If that ever flips, our clock restore silently becomes a no-op. This test
# extracts toybox + mksh + bionic libs from the stock system.img and runs the
# real scripts under qemu-arm, so applet/semantics drift is caught offline.
#
# Requires: qemu-arm + a stock system.img (default ~/rootkit/Firmware for SPFT/system.img).
# Usage: bash test/test-toybox.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

SYSTEM_IMG="${SYSTEM_IMG:-$HOME/rootkit/Firmware for SPFT/system.img}"
SYS="${LE1_SYSROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/le1-sysroot}"

command -v qemu-arm >/dev/null 2>&1 || { echo "SKIP: qemu-arm not installed (pkg install qemu-user-arm)"; exit 0; }
command -v debugfs  >/dev/null 2>&1 || { echo "SKIP: debugfs not installed (pkg install e2fsprogs)"; exit 0; }
[ -f "$SYSTEM_IMG" ] || { echo "SKIP: system.img not found (set SYSTEM_IMG=...)"; exit 0; }

T="$(mktemp -d)/t"; mkdir -p "$T/bin" "$T/work"
trap 'rm -rf "$(dirname "$T")"' EXIT

# --- one-time extraction of toybox + mksh + bionic libs -------------------
if [ ! -f "$SYS/.ok" ]; then
    echo "[*] extracting toybox/mksh/libs from $(basename "$SYSTEM_IMG") -> $SYS"
    mkdir -p "$SYS/system/bin" "$SYS/system/lib"
    ext() { debugfs -R "dump -p $1 $SYS$2" "$SYSTEM_IMG" >/dev/null 2>&1; [ -s "$SYS$2" ]; }
    ext /bin/toybox /system/bin/toybox || { echo "SKIP: no /bin/toybox in image"; exit 0; }
    ext /bin/linker  /system/bin/linker  || { echo "SKIP: no /bin/linker in image"; exit 0; }
    ext /bin/sh      /system/bin/sh      || { echo "SKIP: no /bin/sh in image"; exit 0; }
    for lib in libc.so libm.so libdl.so liblog.so libselinux.so libcutils.so \
               libcrypto.so libz.so libpcre2.so libpackagelistparser.so \
               libc++.so libstdc++.so libunwind.so libbase.so libutils.so; do
        ext "/lib/$lib" "/system/lib/$lib" || true
    done
    chmod +x "$SYS/system/bin/"* 2>/dev/null
    touch "$SYS/.ok"
fi

QEMU="$(command -v qemu-arm)"
RUNARM() { env -u LD_PRELOAD -u LD_LIBRARY_PATH QEMU_LD_PREFIX="$SYS" "$QEMU" "$@"; }
MSH="$SYS/system/bin/sh"
TOY="$SYS/system/bin/toybox"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2' want '$3')"; fail=1; fi; }
cnt() { c=$(grep -c "$2" "$1" 2>/dev/null); printf '%s' "${c:-0}"; }

echo "=== 0. device shell (mksh) parses the scripts ==="
for s in boot/le1-boot.sh boot/install-recovery.sh post-root/persist.sh post-root/verify-boot.sh; do
    if RUNARM "$MSH" -n "$REPO/$s" >/dev/null 2>&1; then echo "PASS  mksh -n $s"
    else echo "FAIL  mksh -n $s"; fail=1; fi
done

# --- per-applet wrappers that dispatch to the device's toybox -------------
for a in date tr cat mv chmod mkdir sleep id cp chown rm dirname echo touch ln grep tail cut head; do
    cat >"$T/bin/$a" <<EOF
#!$PREFIX/bin/sh
unset LD_PRELOAD LD_LIBRARY_PATH
export QEMU_LD_PREFIX="$SYS"
exec "$QEMU" "$TOY" $a "\$@"
EOF
    chmod +x "$T/bin/$a"
done

echo
echo "=== 1. applet smoke matrix (device toybox) ==="
mkdir -p "$T/work/smoke"; cd "$T/work/smoke"
printf 'a b\tc\r\n' >in
chk "echo"       "$("$T/bin/echo" hello 2>/dev/null)" "hello"
chk "cat"        "$("$T/bin/cat" in 2>/dev/null | od -An -c | tr -d ' ')" "ab\\tc\\r\\n"
chk "tr"         "$("$T/bin/tr" -d ' \t\r\n' <in 2>/dev/null)" "abc"
chk "date +%s"   "$(printf '%s' "$("$T/bin/date" +%s 2>/dev/null)" | grep -cE '^[0-9]{9,}$')" "1"
chk "date fmt"   "$("$T/bin/date" '+%F %T' 2>/dev/null | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')" "1"
chk "dirname"    "$("$T/bin/dirname" /a/b/c 2>/dev/null)" "/a/b"
chk "grep"       "$(printf 'x\ny\n' | "$T/bin/grep" y 2>/dev/null)" "y"
chk "tail -1"    "$(printf '1\n2\n3\n' | "$T/bin/tail" -1 2>/dev/null)" "3"
chk "head -1"    "$(printf '1\n2\n' | "$T/bin/head" -1 2>/dev/null)" "1"
chk "cut -d: -f2" "$(printf 'a:b\n' | "$T/bin/cut" -d: -f2 2>/dev/null)" "b"
chk "id -u"      "$(printf '%s' "$("$T/bin/id" -u 2>/dev/null)" | grep -cE '^[0-9]+$')" "1"
chk "mkdir"      "$("$T/bin/mkdir" -p d1 && [ -d d1 ] && echo ok)" "ok"
touch f1; "$T/bin/chmod" 0644 f1 2>/dev/null; "$T/bin/cp" f1 f2 2>/dev/null
"$T/bin/mv" f2 f3 2>/dev/null; "$T/bin/ln" -s f3 f4 2>/dev/null
chk "file ops"   "$([ -f f1 ] && [ -f f3 ] && [ -L f4 ] && echo yes)" "yes"
"$T/bin/rm" -f f1 f3 f4 2>/dev/null
chk "sleep 0"    "$("$T/bin/sleep" 0 && echo ok)" "ok"

echo
echo "=== 2. CRITICAL: toybox 'date -u @EPOCH' is the SET form, not display ==="
out=$("$T/bin/date" -u @1600000000 2>/dev/null); rc=$?
err=$("$T/bin/date" -u @1600000000 2>&1 >/dev/null)
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    echo "FAIL  date -u @epoch PRINTED a date (rc=0) — that is the busybox/GNU"
    echo "      display form; clock restore would be a silent no-op on-device."
    fail=1
elif [ "$rc" -eq 0 ]; then
    echo "FAIL  date -u @epoch returned 0 unexpectedly"; fail=1
else
    case "$err" in
        *nknown*|*sage:*|*usage*) echo "FAIL  date -u @epoch not understood: $err"; fail=1 ;;
        *) echo "PASS  date -u @epoch is the SET form (rc=$rc as a user, no output)" ;;
    esac
fi

echo
echo "=== 3. supervisor under device mksh + toybox ==="
# host-side stubs (executed by the host sh when mksh execs them)
cat >"$T/work/sudaemon" <<EOF
#!$PREFIX/bin/sh
echo "\$@" > "$T/work/sudaemon.args"; : > "$T/work/su_ok"; exit 0
EOF
cat >"$T/work/su" <<EOF
#!$PREFIX/bin/sh
[ -f "$T/work/su_ok" ] && exit 0 || exit 1
EOF
cat >"$T/work/settings" <<EOF
#!$PREFIX/bin/sh
case "\$*" in
  "get global auto_time") [ -f "$T/work/auto_time" ] && cat "$T/work/auto_time" || echo 0 ;;
  "put global auto_time 1") echo 1 > "$T/work/auto_time" ;;
esac
echo "\$*" >> "$T/work/settings.calls"
exit 0
EOF
chmod +x "$T/work/"*
mkdir -p "$T/work/time"; echo 2000000000 >"$T/work/time/last"   # future -> forces a restore attempt

env -u LD_PRELOAD -u LD_LIBRARY_PATH QEMU_LD_PREFIX="$SYS" \
    LE1_PATH="$T/bin" \
    LE1_TIME_DIR="$T/work/time" LE1_SU="$T/work/su" \
    LE1_SUDAEMON="$T/work/sudaemon" LE1_SETTINGS="$T/work/settings" \
    LE1_LOOP_SECS=1 \
    timeout 8 "$QEMU" "$MSH" "$REPO/boot/le1-boot.sh" toybox-test >/dev/null 2>&1

BL="$T/work/time/boot.log"
chk "supervisor started (device mksh)" "$(cnt "$BL" 'le1-boot start')" "1"
chk "hook tag logged"                  "$(cnt "$BL" 'hook=toybox-test')" "1"
chk "clock restore attempted"          "$(cnt "$BL" 'clock restore')" "1"
chk "sudaemon started"                 "$(cnt "$T/work/sudaemon.args" '\-\-daemon')" "1"
chk "auto_time enforced"               "$(cat "$T/work/auto_time" 2>/dev/null)" "1"
chk "ntp_server set"                   "$(cnt "$T/work/settings.calls" 'ntp_server pool.ntp.org')" "1"
chk "cache rewritten"                  "$([ -s "$T/work/time/last" ] && echo yes)" "yes"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
