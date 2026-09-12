#!/usr/bin/env bash
# =============================================================================
# LE1 root — one-shot deploy + run.
#
# Stages the ARM32 su daemon, the exploit and the boot-persistence files,
# then either:
#   * runs the exploit (only if root is not already available), or
#   * skips straight to installing persistence when `su` already works.
#
# Usage:
#   ./deploy.sh                 # full: stage, then exploit-or-persist
#   ./deploy.sh --force-exploit  # always run the exploit even if su works
#   ./deploy.sh --stage-only     # only stage files
#   ./deploy.sh --run            # assume already staged; exploit-or-persist
#
# Prereqs: device reachable via Tailscale SSH (u0_a50:8022), clang on device.
# =============================================================================
set -euo pipefail

SSH_HOST="u0_a50@100.124.251.81"
SSH_PORT=8022
REPO="$(cd "$(dirname "$0")" && pwd)"

ssh_cmd() { ssh -p "$SSH_PORT" "$SSH_HOST" "$@"; }

MODE="full"
FORCE_EXPLOIT=0
for a in "$@"; do
    case "$a" in
        --run)           MODE="run" ;;
        --stage-only)    MODE="stage" ;;
        --force-exploit) FORCE_EXPLOIT=1 ;;
        *) echo "usage: $0 [--stage-only|--run] [--force-exploit]" >&2; exit 2 ;;
    esac
done

echo "=== LE1 root deploy ==="
echo "[*] Checking device reachable..."
if ! ssh_cmd 'id' >/dev/null 2>&1; then
    echo "[!] device OFFLINE — retry when LE1 is up (Tailscale: $SSH_HOST:$SSH_PORT)"
    exit 1
fi
echo "[*] device online: $(ssh_cmd 'whoami')"

# --- is root already available? -------------------------------------------
# NEVER probe with /system/xbin/su here: that binary IS the exploit and
# self-triggers when the daemon is down, freezing the unit before we stage
# anything. Use the init service state instead (world-readable via getprop).
ROOT_ACTIVE=0
SVC_STATE=$(ssh_cmd 'getprop init.svc.sudaemon; getprop init.svc.le1boot' 2>/dev/null | tr -d '\r' || true)
if printf '%s\n' "$SVC_STATE" | grep -qx running; then
    # daemon is up, so calling su is safe now — confirm it really is root
    if ssh_cmd '/system/xbin/su -c id 2>/dev/null | grep -q "uid=0"'; then
        ROOT_ACTIVE=1
        echo "[*] root is ALREADY active (init service running) — exploit not needed"
    else
        echo "[!] init service running but su check failed — will run the exploit"
    fi
elif [ "$FORCE_EXPLOIT" = 1 ]; then
    echo "[*] root not active; --force-exploit set"
else
    echo "[*] root not active — will run the exploit"
fi

if [ "$MODE" != "run" ]; then
    echo "[*] Staging sudaemon (ARM32 prebuilt su) -> ~/sudaemon"
    scp -P "$SSH_PORT" "$REPO/poc/root-sonim-xp3800/assets/su" "$SSH_HOST:sudaemon"
    ssh_cmd 'chmod 755 ~/sudaemon'

    echo "[*] Staging exploit source"
    ssh_cmd 'cat > le1_root.c' < "$REPO/exploit/le1_root.c"

    echo "[*] Staging boot persistence -> ~/.le1/"
    ssh_cmd 'mkdir -p ~/.le1'
    scp -P "$SSH_PORT" "$REPO/boot/le1-boot.sh"          "$SSH_HOST:.le1/le1-boot.sh"
    scp -P "$SSH_PORT" "$REPO/boot/install-recovery.sh"  "$SSH_HOST:.le1/install-recovery.sh"
    scp -P "$SSH_PORT" "$REPO/post-root/persist.sh"      "$SSH_HOST:.le1/persist.sh"
    scp -P "$SSH_PORT" "$REPO/post-root/verify-boot.sh"  "$SSH_HOST:.le1/verify-boot.sh"
    ssh_cmd 'chmod 755 ~/.le1/*.sh'
fi

if [ "$MODE" = "stage" ]; then
    echo "[*] Staged. Run later with: ./deploy.sh --run"
    exit 0
fi

# --- run path: persist if rooted, else exploit ----------------------------
if [ "$ROOT_ACTIVE" = 1 ] && [ "$FORCE_EXPLOIT" != 1 ]; then
    echo "[*] Installing/re-asserting boot persistence via su (no exploit)"
    ssh_cmd '/system/xbin/su -c "sh $HOME/.le1/persist.sh $HOME/.le1" 2>&1'
    echo "[*] Verifying:"
    ssh_cmd 'sh ~/.le1/verify-boot.sh 2>&1 | head -40'
    echo "[*] Done. Reboot to confirm the hook is live."
    exit 0
fi

echo "[*] Compiling on device (clang -O2, armv7)"
ssh_cmd 'clang -O2 -o le1_root le1_root.c' || {
    echo "[!] compile failed — check device clang + transferred source"
    exit 1
}
echo "[*] compiled ok: $(ssh_cmd 'ls -la le1_root')"

echo "[*] Running exploit (log -> ~/le1_root.log, NOT /data/local/tmp: Termux uid cannot write there)"
ssh_cmd './le1_root > ~/le1_root.log 2>&1; echo "exploit exit=$?"; echo "--- last 40 log lines ---"; tail -40 ~/le1_root.log'
echo
echo "[*] Post-run verify:"
ssh_cmd 'sh ~/.le1/verify-boot.sh 2>&1 | head -40' || true
