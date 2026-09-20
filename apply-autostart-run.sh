#!/data/data/com.termux/files/usr/bin/bash
# apply-autostart-run.sh — local runner: wait for LE1, stage bundle + scripts,
# apply as root, then verify. Safe to re-run (idempotent apply script).
#
#   bash apply-autostart-run.sh            # wait up to 30 min, then apply
#   WAIT=0 bash apply-autostart-run.sh     # apply immediately if online
set -u
H="u0_a50@100.124.251.81"
P=${P:-8022}
STAGE=${STAGE:-/data/data/com.termux/files/home/.le1-stage}
cd "$(dirname "$0")"

SSH() { timeout 30 ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -p "$P" "$H" "$@"; }
SCP() { timeout 120 scp -P "$P" -o StrictHostKeyChecking=accept-new "$@"; }
ROOT() { SSH "/system/xbin/su -c \"$1\""; }

WAIT=${WAIT:-1}
if [ "$WAIT" = "1" ]; then
  echo "waiting for $H ..."
  ok=0
  for i in $(seq 1 120); do
    if SSH true 2>/dev/null; then ok=1; break; fi
    printf '.'; sleep 15
  done
  [ "$ok" = "1" ] || { echo; echo "OFFLINE — aborting"; exit 1; }
  echo " online"
fi
SSH true 2>/dev/null || { echo "OFFLINE — aborting"; exit 1; }

echo "== staging =="
SSH "mkdir -p $STAGE"
SCP dist/bundle.tgz post-root/apply-autostart.sh boot/le1-boot.sh "$H:$STAGE/" || exit 1
if [ -f "$HOME/.le1-secrets/tailscale-authkey" ]; then
  SCP "$HOME/.le1-secrets/tailscale-authkey" "$H:$STAGE/authkey" || exit 1
  echo "authkey staged"
fi

echo "== applying (root) =="
ROOT "sh $STAGE/apply-autostart.sh $STAGE" 2>&1 | tee /tmp/le1-autostart-apply.log

echo; echo "== verify =="
ROOT 'echo "-- dropbear --"; pidof dropbear; \
      echo "-- tailscaled --"; pidof tailscaled; \
      echo "-- tailscale status --"; /data/le1-tailscale/bin/tailscale --socket=/data/le1-tailscale/tailscaled.sock status 2>&1 | head -6; \
      echo "-- tailscale0 --"; ip addr show tailscale0 2>&1 | head -4; \
      echo "-- sshd log --"; tail -4 /data/le1-ssh/sshd.log 2>/dev/null' 2>&1 | tee /tmp/le1-autostart-verify.log

echo; echo "logs: /data/misc/le1-time/autostart.log  (local: /tmp/le1-autostart-apply.log)"