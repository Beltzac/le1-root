#!/system/bin/sh
# apply-autostart.sh — LE1: make sshd + tailscaled run at boot with NO app and
# no Termux runtime dependency. Runs as ROOT on the device.
#
# Usage:  apply-autostart.sh <stage_dir>
#   <stage_dir> must contain:  bundle.tgz   (from ~/le1-root/dist/bundle.tgz)
#                              authkey      (Tailscale auth key, optional if state reused)
#
# Idempotent. Never calls /system/xbin/su. Logs to /data/misc/le1-time/autostart.log
set -u
PATH=/sbin:/system/bin:/system/xbin
D=/data/misc/le1-time
LOG=$D/autostart.log
STAGE=${1:-/data/local/tmp/le1-stage}
SSHDIR=/data/le1-ssh
TSDIR=/data/le1-tailscale
TSS=/data/misc/le1-tailscale
mkdir -p "$D"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
die(){ log "FATAL: $*"; exit 1; }

log "===== apply-autostart start ====="
[ "$(id -u 2>/dev/null)" = "0" ] || die "not root"
[ -f "$STAGE/bundle.tgz" ] || die "missing $STAGE/bundle.tgz"

# ------------------------------------------------------------------ 0. sanity
case "$(getprop init.svc.flash_recovery 2>/dev/null)" in
  running) log "flash_recovery=running (safe: boot supervisor is up)";;
  *) log "WARN: flash_recovery not running — do NOT probe su";;
esac
if zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_TUN=y'; then log "kernel CONFIG_TUN=y"; else log "WARN: CONFIG_TUN not confirmed"; fi
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 2>/dev/null && chmod 600 /dev/net/tun 2>/dev/null
  log "created /dev/net/tun: $([ -c /dev/net/tun ] && echo ok || echo FAILED)"
else log "/dev/net/tun present"; fi

# ------------------------------------------------------------------ 1. unpack
cd "$STAGE" || die "cd $STAGE"
rm -rf ./bundle
tar xzf bundle.tgz || die "tar failed"
[ -d ./bundle/le1-ssh ] || die "bundle layout wrong"
mkdir -p "$SSHDIR/lib" "$TSDIR/bin"
cp -f bundle/le1-ssh/dropbearmulti "$SSHDIR/"
cp -f bundle/le1-ssh/lib/* "$SSHDIR/lib/"
chmod 755 "$SSHDIR/dropbearmulti"
chmod 644 "$SSHDIR/lib/"*.so*
cp -f bundle/le1-tailscale/bin/tailscale bundle/le1-tailscale/bin/tailscaled "$TSDIR/bin/"
chmod 755 "$TSDIR/bin/tailscale" "$TSDIR/bin/tailscaled"
mkdir -p "$TSS"
log "binaries installed"

# ------------------------------------------------------------------ 2. ssh keys
export LD_LIBRARY_PATH="$SSHDIR/lib"
if [ ! -f "$SSHDIR/host_ed25519" ]; then
  "$SSHDIR/dropbearmulti" dropbearkey -t ed25519 -f "$SSHDIR/host_ed25519" >>"$LOG" 2>&1 \
    && log "host key generated" || log "WARN: dropbearkey failed"
fi

AK="$SSHDIR/authorized_keys"
: > "$AK"
cat /data/data/com.termux/files/home/.ssh/authorized_keys >>"$AK" 2>/dev/null
cat /.ssh/authorized_keys >>"$AK" 2>/dev/null
grep -v '^[[:space:]]*$' "$AK" 2>/dev/null | sort -u > "$AK.tmp" && mv "$AK.tmp" "$AK"
chmod 600 "$AK"
log "authorized_keys: $(wc -l < "$AK" 2>/dev/null) key(s)"

# root passwd entry (Android may lack /etc/passwd). Keep an existing one.
PW=/system/etc/passwd
if [ -f "$PW" ] && grep -q '^root:' "$PW"; then
  HOME_DIR=$(awk -F: '$1=="root"{print $6}' "$PW")
  log "existing root passwd entry, home='$HOME_DIR'"
else
  mount -o rw,remount /system 2>/dev/null
  [ -f "$PW" ] && cp -f "$PW" "$PW.le1bak" 2>/dev/null
  echo 'root:x:0:0:root:/data/le1-ssh:/system/bin/sh' >> "$PW"
  mount -o ro,remount /system 2>/dev/null
  HOME_DIR=/data/le1-ssh
  log "appended root entry to $PW"
fi
[ -n "$HOME_DIR" ] || HOME_DIR=/data/le1-ssh

# ------------------------------------------------------------------ 3. ssh wrapper
cat > "$SSHDIR/start-sshd.sh" <<'EOF'
#!/system/bin/sh
D=/data/le1-ssh
export LD_LIBRARY_PATH="$D/lib"
PW=/system/etc/passwd
H=$(awk -F: '$1=="root"{print $6}' "$PW" 2>/dev/null)
[ -n "$H" ] || H=/data/le1-ssh
for d in "$H" /; do
  mkdir -p "$d/.ssh" 2>/dev/null
  cp -f "$D/authorized_keys" "$d/.ssh/authorized_keys" 2>/dev/null
  chmod 700 "$d/.ssh" 2>/dev/null
  chmod 600 "$d/.ssh/authorized_keys" 2>/dev/null
done
exec "$D/dropbearmulti" dropbear -F -E -s -r "$D/host_ed25519" \
     -p 0.0.0.0:8022 -P "$D/dropbear.pid" >>"$D/sshd.log" 2>&1
EOF
chmod 755 "$SSHDIR/start-sshd.sh"
log "ssh wrapper written"

# preliminary placement of keys at root home + /
for d in "$HOME_DIR" /; do
  mkdir -p "$d/.ssh" 2>/dev/null
  cp -f "$AK" "$d/.ssh/authorized_keys" 2>/dev/null
  chmod 700 "$d/.ssh" 2>/dev/null; chmod 600 "$d/.ssh/authorized_keys" 2>/dev/null
done

# ------------------------------------------------------------------ 4. tailscale
if [ -f "$STAGE/authkey" ]; then
  cp -f "$STAGE/authkey" "$TSDIR/authkey"; chmod 600 "$TSDIR/authkey"
fi

# try to reuse the app's node state so the node keeps its Tailscale IP
if [ ! -f "$TSS/tailscaled.state" ]; then
  ST=$(find /data/data/com.tailscale.ipn -type f -name 'tailscaled.state*' 2>/dev/null | head -1)
  if [ -n "$ST" ]; then
    cp -f "$ST" "$TSS/tailscaled.state" && log "reused app tailscaled state: $ST" || log "WARN: state copy failed"
  else
    log "no app state found (will authenticate with authkey)"
  fi
fi

cat > "$TSDIR/start.sh" <<'EOF'
#!/system/bin/sh
B=/data/le1-tailscale
S=/data/misc/le1-tailscale
[ -c /dev/net/tun ] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun; }
pidof tailscaled >/dev/null 2>&1 && exit 0
"$B/bin/tailscaled" --statedir="$S" --socket="$B/tailscaled.sock" \
    --tun=tailscale0 --port=0 --accept-dns=false --no-logs-no-support \
    >>"$B/tailscaled.log" 2>&1 &
i=0
while [ $i -lt 30 ]; do [ -S "$B/tailscaled.sock" ] && break; sleep 1; i=$((i+1)); done
if [ -f "$B/authkey" ]; then
    TS_AUTHKEY=$(cat "$B/authkey") "$B/bin/tailscale" --socket="$B/tailscaled.sock" up \
        --accept-dns=false --accept-routes=false --hostname=le1 >>"$B/up.log" 2>&1
fi
EOF
chmod 755 "$TSDIR/start.sh"
log "tailscale wrapper written"

# stop the Android app's VPN so it does not fight the daemon
settings delete secure always_on_vpn_app >/dev/null 2>&1
settings delete secure always_on_vpn_lockdown >/dev/null 2>&1
log "cleared always_on_vpn settings"

# ------------------------------------------------------------------ 5. run + verify
"$SSHDIR/start-sshd.sh" &
sleep 3
pidof dropbear >/dev/null 2>&1 && log "SSH: dropbear running" || { log "SSH: FAILED (see $SSHDIR/sshd.log)"; tail -5 "$SSHDIR/sshd.log" 2>/dev/null | sed 's/^/  sshd: /'; }

"$TSDIR/start.sh" &
sleep 8
if pidof tailscaled >/dev/null 2>&1; then
  log "TS: tailscaled running"
  "$TSDIR/bin/tailscale" --socket="$TSDIR/tailscaled.sock" status 2>&1 | head -8 | sed 's/^/  ts: /'
  ip addr show tailscale0 2>&1 | head -4 | sed 's/^/  ts: /'
else
  log "TS: FAILED (see $TSDIR/tailscaled.log)"
  tail -8 "$TSDIR/tailscaled.log" 2>/dev/null | sed 's/^/  ts: /'
  [ -s "$TSDIR/up.log" ] && tail -5 "$TSDIR/up.log" | sed 's/^/  ts-up: /'
fi

log "===== apply-autostart done ====="