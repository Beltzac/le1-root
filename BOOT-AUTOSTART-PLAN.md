# LE1 — Boot autostart for SSH + Tailscale (no apps, no Termux runtime)

Status: **PLAN ONLY — do not apply until user says go.** Device off at time of writing.

## Problem
After a reboot the unit is unreachable until the user manually opens **two apps**:
- **Termux** (or Termux:Boot running `~/.termux/boot/start-sshd.sh`) → starts
  `runsvdir` → `sshd`. No Termux ⇒ no SSH.
- **Tailscale** (`com.tailscale.ipn`) → the app's `VpnService` comes up only when the
  app is opened (always-on VPN was set but not yet boot-tested).

Wanted: **sshd + Tailscale up automatically after boot, with zero app interaction and
no runtime dependency on Termux.**

## Design
Use the one hook this ROM actually honours and that is already proven:
`/system/bin/install-recovery.sh` → `le1-boot.sh`, started by the stock init service
`flash_recovery` (class main, oneshot). It runs **as root**, never exits, sleeps 60 s.
We add two **supervised units** to its loop; each is (re)started if its process is gone:

| Unit | Process it supervises | Binary |
|---|---|---|
| `le1-sshd` | `sshd` / `dropbear` | standalone SSH daemon, **root**, port 8022 |
| `le1-tailscaled` | `tailscaled` | static Linux/arm Tailscale, **root**, real tun |

Hard rule (unchanged): **never call `/system/xbin/su` from the boot path** — it is the
CVE-2019-2215 exploit and self-triggers when the daemon is down → WDT bootloop.

---

## Part 1 — SSH without Termux

Pick one at apply time (test on device, then bake into the supervisor).

### A1 — static Dropbear (preferred)
- Get an **armv7 static** `dropbearmulti` (or build one). Place at
  `/data/le1-ssh/dropbear`.
- Host key: `/data/le1-ssh/dropbear_ed25519_host_key` (generate once:
  `dropbearkey -t ed25519 -f …`).
- Authorized keys: copy the existing key(s) from
  `/data/data/com.termux/files/home/.ssh/authorized_keys` → `/data/le1-ssh/authorized_keys`
  (this is a one-time copy, not a runtime dependency).
- Wrapper `/data/le1-ssh/start-sshd.sh`:
  ```sh
  #!/system/bin/sh
  D=/data/le1-ssh
  exec "$D/dropbear" -F -E -s -g \
       -r "$D/dropbear_ed25519_host_key" \
       -p 0.0.0.0:8022 \
       -c /system/bin/sh \
       -D "$D" >>/data/misc/le1-time/sshd.log 2>&1
  ```
  (`-s` = no passwords, `-g` = root only, `-c` = forced shell.)

### A2 — reuse the on-device Termux `sshd` binary (fallback, quick)
Termux's armv7 `sshd` already exists on the LE1. Copy it **and its libs** out, then run
it as root — **no Termux app, no runsvdir**:
```sh
SRC=/data/data/com.termux/files/usr
mkdir -p /data/le1-ssh/lib
cp "$SRC/bin/sshd" /data/le1-ssh/sshd
cp "$SRC/lib/libcrypto.so"* "$SRC/lib/libssl.so"* "$SRC/lib/libcrypt.so"* \
   "$SRC/lib/libz.so"* "$SRC/lib/libedit.so"* "$SRC/lib/libncursesw.so"* \
   /data/le1-ssh/lib/ 2>/dev/null
```
Wrapper sets `LD_LIBRARY_PATH=/data/le1-ssh/lib` and runs
`sshd -D -e -f /data/le1-ssh/sshd_config`.
`sshd_config` (key-only, root):
```
Port 8022
HostKey /data/le1-ssh/ssh_host_ed25519_key
AuthorizedKeysFile /data/le1-ssh/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile /data/le1-ssh/sshd.pid
```
Generate host key once: `ssh-keygen -t ed25519 -f /data/le1-ssh/ssh_host_ed25519_key -N ''`.

### Both options: user lookup shim
Android has no `/etc/passwd`, so `sshd`/`dropbear` may fail to resolve `root`.
If login is denied, add a shim (Remount `/system` rw — no dm-verity on this unit):
```sh
mount -o rw,remount /system
printf 'root:x:0:0:root:/:/system/bin/sh\n' >> /system/etc/passwd
printf 'root:x:0:\n'                        >> /system/etc/group
mount -o ro,remount /system
```
(Verify `/system/etc/passwd` didn't already exist before appending; back it up.)

---

## Part 2 — Tailscale without the app

> **STATUS 2026-09-20 — read `TAILSCALED-ROOT.md` first.** Two Android-specific
> blockers were confirmed on the device; the original plan below is otherwise fine:
> 1. **DNS** — no `/etc/resolv.conf`; Go's resolver falls back to `127.0.0.1:53`.
>    Fixed natively by tailscale **>= 1.103** (`dnsproxyd`), absent from 1.102.4.
> 2. **Route** — the control socket's Android bypass mark `0x80000` lands in the
>    **`main`** table, which has **no default route** -> `network is unreachable`.
>    The supervisor must mirror the active network's default route into `main`.

Run **root `tailscaled`** using the official static **Linux/arm (GOARM7)** build — the SoC
is Cortex-A7 / armv7l. **Use >= 1.103** (see 2.1).

### 2.1 Get the binary
`https://pkgs.tailscale.com/stable/tailscale_<VER>_arm.tgz` → extract `tailscale` +
`tailscaled` to `/data/le1-tailscale/bin/`. (Download on the LE1 itself, or fetch on the
phone and `scp`; the phone is aarch64 so it cannot build armv7.)

**Version floor: 1.103.** 1.102.4 (stable at the time of writing) has no `dnsproxyd`
support (`strings tailscaled | grep -c dnsproxyd` -> 0) and cannot resolve the control
plane. Use the unstable build until 1.103 is stable:
`https://pkgs.tailscale.com/unstable/tailscale_1.103.229_arm.tgz`
(staged at `dist/tailscale_1.103.229_arm/`; verified: 4 `dnsproxyd` strings).

### 2.2 Reuse the existing node identity (avoid a second node / new IP)
Try to copy the app's tailscaled state so the node keeps IP `100.124.251.81`:
```sh
find /data/data/com.tailscale.ipn -type f \( -name 'tailscaled.state' -o -name '*.state' \)
mkdir -p /data/misc/le1-tailscale
cp <found-state> /data/misc/le1-tailscale/tailscaled.state
```
If no usable state exists, authenticate **once**:
`tailscale --socket=… up --authkey=tskey-… ` (or the interactive login URL), then the
state persists in `/data/misc/le1-tailscale`.

### 2.3 tun device
```sh
ls /dev/net/tun || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun; }
```

### 2.4 Wrapper `/data/le1-tailscale/start.sh`
```sh
#!/system/bin/sh
B=/data/le1-tailscale
# netd routes tailscaled's bypass mark (0x80000) to `main`, which has an explicit
# `unreachable default`. Re-point the mark at the active interface table.
# (Verified fix -- mirroring a default into main does NOT work.)
IFACE=$(ip route show table all 2>/dev/null | grep -m1 '^default via' | grep -oE 'dev [a-z0-9]+' | head -1 | cut -d' ' -f2)
[ -n "$IFACE" ] || IFACE=wlan0
# drop every stale copy at pref 5200 (they accumulate when the table changes)
ip rule show 2>/dev/null | grep '^5200:' | while read -r a b c d e f tbl; do
    [ -n "$tbl" ] && ip rule del fwmark 0x80000/0xff0000 lookup "$tbl" pref 5200 2>/dev/null
done
ip rule add fwmark 0x80000/0xff0000 lookup "$IFACE" pref 5200 2>/dev/null
# 1.102.x only: give Go a resolver (1.103+ uses /dev/socket/dnsproxyd instead)
D=$(getprop net.dns1 2>/dev/null)
if [ -n "$D" ]; then
    mount -o rw,remount /system 2>/dev/null
    printf 'nameserver %s\n' "$D" > /system/etc/resolv.conf 2>/dev/null
    mount -o ro,remount /system 2>/dev/null
fi
"$B/bin/tailscaled" \
  --statedir=/data/misc/le1-tailscale \
  --socket="$B/tailscaled.sock" \
  --tun=tailscale0 --port=0 \
  --no-logs-no-support \
  >>/data/misc/le1-time/tailscaled.log 2>&1 &
sleep 3
"$B/bin/tailscale" --socket="$B/tailscaled.sock" up \
  --accept-dns=false --accept-routes=false --hostname=le1
```
Real tun mode is required so **inbound** SSH to the Tailscale IP reaches the local socket
(userspace-networking cannot accept inbound).

### 2.5 Stop the app from fighting the daemon
If the app's VPN and root tailscaled both register, clear Android always-on VPN so the
system does not start the app's VpnService:
```sh
settings delete secure always_on_vpn_app
settings delete secure always_on_vpn_lockdown
```
(Optionally `pm disable-user com.tailscale.ipn` with an APK backup, for full decoupling.)

### 2.6 Verify (device on)
```sh
ip addr show tailscale0                     # 100.x.y.z/32
ip route | grep 100.64                      # default via tailscale0
"$B/bin/tailscale" --socket="$B/tailscaled.sock" status
ping -c1 <pi-tailscale-ip>
# from another tailnet node:
ssh -p 8022 root@<le1-tailscale-ip> 'id'    # uid=0(root)
```

---

## Part 3 — Supervisor changes (`boot/le1-boot.sh`)
Add, after `start_daemon` in the 60 s loop:
```sh
ensure_sshd()      { pidof sshd >/dev/null 2>&1 || pidof dropbear >/dev/null 2>&1 \
                     || { [ -x /data/le1-ssh/start-sshd.sh ] && /data/le1-ssh/start-sshd.sh; log "sshd started"; }; }
ensure_tailscale() { pidof tailscaled >/dev/null 2>&1 \
                     || { [ -x /data/le1-tailscale/start.sh ] && /data/le1-tailscale/start.sh; log "tailscaled started"; }; }
```
Run `ensure_sshd; ensure_tailscale` once at startup and each loop pass. Logs go to
`/data/misc/le1-time/boot.log` (already the supervisor log).

---

## Part 4 — Fallback (Track B) if root daemons don't work on this ROM
Keep the apps but make them start with no user action:
- `settings put secure always_on_vpn_app com.tailscale.ipn` (+ `always_on_vpn_lockdown 0`)
  and deviceidle whitelist `+com.tailscale.ipn`.
- Let Termux:Boot run `start-sshd.sh` (already exists) — but this reintroduces the
  app dependency the user wants gone; only use if Part 1/2 fail.

---

## Part 5 — Risks / must-verify on device
1. **`CONFIG_TUN`** — repo defconfigs are stale (they say `CONFIG_SWAP` unset, yet the
   device has zram swap). Verify live: `zcat /proc/config.gz | grep CONFIG_TUN` and
   `ls -l /dev/net/tun`. Without TUN, root Tailscale can't offer inbound.
2. **User lookup for root SSH** — `getpwnam("root")`; needs the `/system/etc/passwd` shim.
3. **tailscaled on Android 8.1 / kernel 3.18** — static Go binary usually runs; routing/DNS
   quirks possible. `--accept-dns=false` avoids DNS fights.
4. **Node identity** — new node vs copying app state; may need a fresh auth key (user must
   supply one from the admin console).
5. **SELinux** is Permissive → domain restrictions won't block; still keep SELinux context
   stock.
6. **Never call `su`** in any of these scripts.

## Part 6 — Rollback
- Remove the two `ensure_*` calls from `le1-boot.sh`; `rm -rf /data/le1-ssh /data/le1-tailscale`.
- Restore `/system/etc/passwd`/`group` from backup if the shim was added.
- Re-enable `com.tailscale.ipn`, re-set always_on_vpn_app, `sv start sshd` from Termux.

## Apply order (when user says go)
1. Verify device on, `flash_recovery` running, root OK.
2. SSH: drop binary/libs/keys → test `start-sshd.sh` by hand → confirm key login on 8022.
3. Tailscale: drop binary → copy state or auth once → test tun + `status` + inbound SSH.
4. Patch `le1-boot.sh`, push, confirm the loop keeps both alive (kill one, watch restart).
5. Record in STATUS.md + skill; commit. Full test = next reboot.