#!/usr/bin/env bash
# wait-and-apply.sh — wait for LE1 to come back, then apply the fix/debloat on-device.
#   - restores the volume OSD (re-enable com.wwc2.mainui)
#   - backs up + disables the telemetry apps (abupdate, networks, market, mtklogger)
#
# Safe: it only runs su AFTER the boot supervisor is confirmed up
# (init.svc.flash_recovery=running), so it never fires the exploit by accident.
#
#   bash ~/le1-root/wait-and-apply.sh            # disable (default)
#   bash ~/le1-root/wait-and-apply.sh --purge    # also rename /system APKs to .bak
set -uo pipefail
SSH_HOST="u0_a50@100.124.251.81"; SSH_PORT=8022
REPO="$(cd "$(dirname "$0")" && pwd)"
LOG="$REPO/wait-and-apply.log"
MODE="${1:-}"
ssh_cmd() { ssh -o ConnectTimeout=8 -p "$SSH_PORT" "$SSH_HOST" "$@"; }
say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

say "waiting for LE1 (Tailscale u0_a50@100.124.251.81:8022) ..."
until ssh_cmd 'echo ok' >/dev/null 2>&1; do sleep 20; done
say "device reachable."

# wait for the boot supervisor (which starts the su daemon) — avoids triggering the exploit
for i in $(seq 1 40); do
    FR=$(ssh_cmd 'getprop init.svc.flash_recovery' 2>/dev/null | tr -d "\r")
    if [ "$FR" = "running" ]; then say "flash_recovery=running (root daemon path up)"; break; fi
    say "waiting for boot supervisor... ($i) flash_recovery='${FR:-}'"
    sleep 15
done
if [ "${FR:-}" != "running" ]; then
    say "ABORT: boot supervisor not running — refusing to invoke su (would trigger the exploit)."
    say "Investigate manually: ssh ... 'getprop init.svc.flash_recovery; cat /data/misc/le1-time/boot.log'"
    exit 1
fi

say "staging on-device scripts -> ~/.le1/"
ssh_cmd 'mkdir -p ~/.le1' >/dev/null 2>&1
scp -q -P "$SSH_PORT" "$REPO/post-root/le1-online-fix.sh" "$REPO/post-root/le1-restore.sh" "$SSH_HOST:.le1/" \
  && ssh_cmd 'chmod 755 ~/.le1/le1-online-fix.sh ~/.le1/le1-restore.sh'

say "applying (mode: ${MODE:-disable}) ..."
if [ "$MODE" = "--purge" ]; then
    OUT=$(ssh_cmd '/system/xbin/su -c "sh /data/data/com.termux/files/home/.le1/le1-online-fix.sh --purge"' 2>&1)
else
    OUT=$(ssh_cmd '/system/xbin/su -c "sh /data/data/com.termux/files/home/.le1/le1-online-fix.sh"' 2>&1)
fi
echo "$OUT" | tee -a "$LOG"

say "verifying root is still sticky:"
ssh_cmd '/system/xbin/su -c "id; getprop init.svc.flash_recovery"' 2>&1 | tee -a "$LOG"
say "done. Press a volume button to confirm the OSD is back."