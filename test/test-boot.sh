#!/usr/bin/env bash
# test-boot.sh — offline test of boot/le1-boot.sh using stub binaries.
# Verifies: cached clock restore, sudaemon supervision, auto_time enforcement.
# Usage: bash test/test-boot.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../boot/le1-boot.sh"
T="$(mktemp -d)"
STATE="$T/state"; mkdir -p "$STATE" "$T/data" "$T/bin"

# --- stubs ---------------------------------------------------------------
cat >"$T/bin/date" <<EOF
#!/bin/sh
case "\$*" in
  *"-u @"*) echo "\$*" >>"$STATE/date_set"; exit 0 ;;
  *"+%s"*)  echo 1600000000 ;;            # "now" == MIN_EPOCH (before cache)
  *)        echo "TEST-TIME" ;;
esac
EOF

cat >"$T/bin/settings" <<EOF
#!/bin/sh
echo "\$*" >>"$STATE/settings"
case "\$*" in
  "get global auto_time") [ -f "$STATE/autotime" ] && cat "$STATE/autotime" || echo 0 ;;
  "put global auto_time 1") echo 1 >"$STATE/autotime" ;;
esac
exit 0
EOF

cat >"$T/bin/su" <<EOF
#!/bin/sh
[ -f "$STATE/su_ok" ] || exit 1
exit 0
EOF

cat >"$T/bin/sudaemon" <<EOF
#!/bin/sh
echo "started \$*" >>"$STATE/sudaemon"
touch "$STATE/su_ok"
exit 0
EOF

chmod +x "$T/bin/"*

# --- fixture: a cached time older than "now" but >= MIN_EPOCH -------------
CACHE_DIR="$T/data"; echo 1699999999 >"$CACHE_DIR/last"

# --- run (bounded; script is an infinite supervisor) ---------------------
env LE1_PATH="$T/bin:$PATH" \
    LE1_TIME_DIR="$CACHE_DIR" LE1_SU="$T/bin/su" \
    LE1_SUDAEMON="$T/bin/sudaemon" LE1_SETTINGS="$T/bin/settings" \
    LE1_LOOP_SECS=1 \
    timeout 4 sh "$SCRIPT" >/dev/null 2>&1
rc=$?

echo "=== results (rc=$rc, 124=timeout-as-expected) ==="
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2' want '$3')"; fail=1; fi; }

chk "clock restored from cache" "$(grep -c -- '-u @1699999999' "$STATE/date_set" 2>/dev/null || echo 0)" "1"
chk "sudaemon started"          "$(grep -c 'started --daemon' "$STATE/sudaemon" 2>/dev/null || echo 0)" "1"
chk "auto_time forced to 1"     "$(cat "$STATE/autotime" 2>/dev/null)" "1"
chk "ntp_server set"            "$(grep -c 'ntp_server pool.ntp.org' "$STATE/settings" 2>/dev/null || echo 0)" "1"
chk "cache refreshed"           "$(cat "$CACHE_DIR/last")" "1600000000"
chk "boot log written"          "$(grep -c 'le1-boot start' "$CACHE_DIR/boot.log" 2>/dev/null || echo 0)" "1"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
rm -rf "$T"
exit "$fail"
