#!/usr/bin/env bash
# =============================================================================
# LE1 root — one-shot deploy + run.
#
# Stages the ARM32 su daemon (prebuilt from root-sonim-xp3800) and the exploit,
# compiles on-device (clang), runs it, and tails the panic-durable log.
#
# Usage:
#   ./deploy.sh              # full deploy + run
#   ./deploy.sh --stage-only # only stage files, don't run
#   ./deploy.sh --run        # assume already staged, just compile + run
#
# Prereqs (already true): device reachable via Tailscale SSH (u0_a50:8022),
# clang available in device Termux.
# =============================================================================
set -euo pipefail

SSH_HOST="u0_a50@100.124.251.81"
SSH_PORT=8022
REPO="$(cd "$(dirname "$0")" && pwd)"

ssh_cmd() { ssh -p "$SSH_PORT" "$SSH_HOST" "$@"; }

MODE="${1:-full}"

echo "=== LE1 root deploy ==="
echo "[*] Checking device reachable..."
if ! ssh_cmd 'id' >/dev/null 2>&1; then
    echo "[!] device OFFLINE — retry when LE1 is up (Tailscale: $SSH_HOST:$SSH_PORT)"
    exit 1
fi
echo "[*] device online: $(ssh_cmd 'whoami')"

if [ "$MODE" != "--run" ]; then
    echo "[*] Staging sudaemon (ARM32 prebuilt su) -> ~/sudaemon"
    scp -P "$SSH_PORT" "$REPO/poc/root-sonim-xp3800/assets/su" "$SSH_HOST:sudaemon"
    ssh_cmd 'chmod 755 ~/sudaemon'

    echo "[*] Staging exploit source"
    ssh_cmd 'cat > le1_root.c' < "$REPO/exploit/le1_root.c"
fi

if [ "$MODE" = "--stage-only" ]; then
    echo "[*] Staged. Run later with: ./deploy.sh --run"
    exit 0
fi

echo "[*] Compiling on device (clang -O2, armv7)"
ssh_cmd 'clang -O2 -o le1_root le1_root.c' || {
    echo "[!] compile failed — check device clang + transferred source"
    exit 1
}
echo "[*] compiled ok: $(ssh_cmd 'ls -la le1_root')"

echo "[*] Running exploit (log -> /data/local/tmp/le1_root.log)"
ssh_cmd './le1_root > /data/local/tmp/le1_root.log 2>&1; echo "exploit exit=$?"; echo "--- last 40 log lines ---"; tail -40 /data/local/tmp/le1_root.log'
