#!/usr/bin/env bash
# wait-online.sh — poll LE1 until reachable, then optionally run deploy.
# Fixes the "LE1 offline, car off" workflow: instead of retrying by hand,
#   ./wait-online.sh            # wait until SSH works, then exit 0
#   ./wait-online.sh --deploy   # wait, then run ./deploy.sh automatically
# Env: LE1_HOST (default u0_a50@100.124.251.81), LE1_PORT (default 8022),
#      INTERVAL (default 60s), TIMEOUT (default 0 = forever).
set -u
LE1_HOST="${LE1_HOST:-u0_a50@100.124.251.81}"
LE1_PORT="${LE1_PORT:-8022}"
INTERVAL="${INTERVAL:-60}"
TIMEOUT="${TIMEOUT:-0}"
ELAPSED=0
echo "[*] waiting for LE1 ($LE1_HOST:$LE1_PORT), poll every ${INTERVAL}s (TIMEOUT=$TIMEOUT, 0=forever)..."
while true; do
    if ssh -p "$LE1_PORT" -o ConnectTimeout=8 -o BatchMode=yes "$LE1_HOST" 'id' >/dev/null 2>&1; then
        echo "[+] LE1 ONLINE: $(ssh -p "$LE1_PORT" "$LE1_HOST" 'whoami')"
        break
    fi
    echo "[.] offline after ${ELAPSED}s — retry in ${INTERVAL}s (power on the car)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
    if [ "$TIMEOUT" != "0" ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "[!] timeout after ${ELAPSED}s"; exit 1
    fi
done
if [ "${1:-}" = "--deploy" ]; then
    exec "$(cd "$(dirname "$0")" && pwd)/deploy.sh"
fi
