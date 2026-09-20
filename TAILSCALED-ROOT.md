# LE1 — root `tailscaled` on Android: research, theory and plan

Status: **WORKING (2026-09-20) and boot-tested.** After a real reboot the root
OpenSSH sshd came up on 8022 by itself (no Termux), the supervisor started, the
`ip rule` was applied, and root `tailscaled` logged in as node `le1-1`
(`100.122.21.101`) with direct peer connectivity (tailscale ping to the phone:
pong in 86 ms; phone ping to it 2/2). Three gotchas were found at boot and are
fixed in `apply-autostart.sh` / `boot/le1-boot.sh` (see Step 3 and below).

Goal: run the official static `tailscaled` as **root** on the LE1 (LeTV/MT6580,
Android 8.1) so Tailscale comes up at boot with **no app and no Termux**, keeping
the node IP `100.124.251.81`. Today we depend on the Tailscale *app's* always-on
VpnService.

---

## TL;DR

Two separate problems, both caused by Android (not by Tailscale or our setup):

| # | Symptom in `tailscaled.log` | Cause | Fix |
|---|---|---|---|
| 1 | `failed to resolve "controlplane.tailscale.com"` / `no DNS fallback candidates remain` | Android has **no `/etc/resolv.conf`**; Go's pure resolver falls back to `127.0.0.1:53` -> `connection refused` | use tailscale **>= 1.103** (androiddns/queries `/dev/socket/dnsproxyd`), or write `/etc/resolv.conf` |
| 2 | `dial tcp <ip>:443: connect: network is unreachable` | Android policy routing sends sockets with the **bypass mark `0x80000`** to the **`main`** table, which has an explicit **`unreachable default`** | add an `ip rule` with priority **< 5210** sending `fwmark 0x80000/0xff0000` to the **interface's own table**, re-applied on every network change |

Neither is fixed by `--netfilter-mode=off` (tried on the LE1 and on the reference
module issue).

---

## Evidence (all checked, not guessed)

### On our own binaries
```
$ strings -a dist/tailscale_1.102.4_arm/tailscaled | grep -c dnsproxyd      # 0
$ strings -a /tmp/.../tailscale_1.103.229_arm/tailscaled | grep -c dnsproxyd # 4
$ strings -a <1.103.229> | grep -o '/dev/socket/dnsproxyd' | sort -u
 /dev/socket/dnsproxyd
```
So the DNS fix exists in **1.103** (unstable `1.103.229` today) and is **absent
from our 1.102.4**.

### Upstream
- **PR tailscale/tailscale#21139** "feature/androiddns: add dnsproxyd DNS
  resolution for standalone Android binaries" — **MERGED 2026-09-08**
  (`merge_commit_sha 86b3cd5`), by Brad Fitzpatrick. Body: *"Android doesn't have
  /etc/resolv.conf. This causes problems for people running ... binaries in
  Termux, adb shell, etc. ... just query the DNS server like bionic does."*
  Disable with build tag `ts_omit_androiddns`. **Not in the 1.102.x release
  branch** (v1.102.4 was cut 2026-09-10).
- **PR tailscale/tailscale#18695** "ipn,router: support configurable Linux packet
  marks" — **OPEN**. Its diff contains the per-OS mark profiles; the **Android**
  one is `FwmarkMask 0xff0000, SubnetRouteMark 0x40000, BypassMark 0x80000`
  (Linux default `BypassMark 0x80000000`). This is where our `0x80000` comes from
  and why we cannot change it yet.

### Community reference
- **`anasfanani/magisk-tailscaled`** — the de-facto Magisk module. Its daemon
  command is literally `tailscaled -no-logs-no-support`
  (`tailscale/settings.sh:18`); it has **no** DNS/route workaround, which is why
  people file issues like the one below.
- **`WayneShao/KernelSU-Tailscaled` issue #1** — "Initial login fails on Android
  without resolv.conf and a main-table route". Exact diagnosis:
  ```
  lookup controlplane.tailscale.com on [::1]:53: read udp [::1]:...->[::1]:53: connection refused
  ip route get <control-plane-IP> mark 0x80000
  # RTNETLINK answers: Network is unreachable
  ```
  Their temporary fix: hosts mapping for `controlplane.tailscale.com` + add the
  Wi-Fi default route to the `main` table. They note it is **lost on reboot or
  network change**, and that `--netfilter-mode=off` alone did not help.

### Observed on the LE1 itself (2026-09-20)
`/data/le1-tailscale/tailscaled.log`:
```
bootstrapDNS("derp1c.tailscale.com", "104.248.8.210") ... dial tcp 104.248.8.210:443: connect: network is unreachable
bootstrapDNS("derp4d.tailscale.com", "2a03:...")      ... connect: network is unreachable
Received error: fetch control key: Get "https://controlplane.tailscale.com/key?v=142":
  failed to resolve "controlplane.tailscale.com": no DNS fallback candidates remain
```
Note it **did resolve some IPs** (104.248.8.210) before failing on DNS — consistent
with DNS being partly cached/answered while the **route** is the hard blocker.
Also confirmed on the LE1: root has a working ICMP path (`ping 8.8.8.8` OK) and
`net.dns1=172.26.39.235`, but no `/etc/resolv.conf`.

---

## Theory: why Android breaks native daemons

### Routing (the real blocker)
Android's `netd` does **policy routing**: every network gets its own table
(wlan0 ~ `1004`) with its own default route, and the kernel picks a table from
the socket's **fwmark** / uid. The global `main` table is intentionally *empty of
defaults*. Two consequences for a native root daemon:

- **unmarked** sockets (uid 0) hit a rule that falls through to `main` -> no
  default -> `network is unreachable`;
- Tailscale's own **bypass-marked** sockets (`0x80000` on Android) are *also*
  steered to `main` by netd's rules -> same failure.

So `tailscaled` can neither reach the control plane nor a DERP, no matter how
good DNS is. This is why "it resolved the IP and still said unreachable".

### DNS
Bionic apps ask `netd`'s **`dnsproxyd`** over `/dev/socket/dnsproxyd`; there is no
file-based resolver config. Static Go binaries bypass bionic and read
`/etc/resolv.conf`, which does not exist, so Go uses the `127.0.0.1:53` default
-> refused. Tailscale's androiddns patch makes the Go side speak the
`dnsproxyd` protocol too, closing the gap without any file.

### Why the app "just works"
The Android **app** is a `VpnService`: it runs inside the app uid, so netd gives
it a normal network, and it uses bionic (with `dnsproxyd`). It therefore never
sees either problem. Running the same code as a **root native daemon** removes
both of those Android guarantees.

---

## Plan (in order)

### Step 1 — DNS: use tailscale >= 1.103
Ship the **unstable 1.103.229** arm build (staged at `dist/tailscale_1.103.229_arm/`)
until 1.103 is stable:
```
https://pkgs.tailscale.com/unstable/tailscale_1.103.229_arm.tgz
```
(Architecture: SoC is Cortex-A7 / armv7l; the `_arm` tarball is correct.)
Keep `--accept-dns=false` so tailscaled never fights Android's own DNS.

Fallback if we must stay on 1.102.4: the supervisor writes a live
`/etc/resolv.conf` (see Step 2).

### Step 2 — Route: re-point the bypass mark (this is the real fix)

The observed LE1 rules:
```
5210: from all fwmark 0x80000/0xff0000 lookup main      <- main has "unreachable default"
5230: from all fwmark 0x80000/0xff0000 lookup default
5250: from all fwmark 0x80000/0xff0000 unreachable
```
So a marked socket is dead-ended. Add our own rule with a **lower** priority number
so it wins, pointing at the interface table (which holds the real default):

```sh
# LE1 has no awk in /system/bin -- grep/cut only
IFACE=$(ip route show table all 2>/dev/null | grep -m1 '^default via' | grep -oE 'dev [a-z0-9]+' | head -1 | cut -d' ' -f2)
[ -n "$IFACE" ] || IFACE=wlan0
ip rule del fwmark 0x80000/0xff0000 lookup "$IFACE" pref 5200 2>/dev/null
ip rule add fwmark 0x80000/0xff0000 lookup "$IFACE" pref 5200 2>/dev/null
```

Verified on device: `ip route get 8.8.8.8 mark 0x80000` ->
`8.8.8.8 via 172.26.39.235 dev wlan0 src 172.26.39.132 mark 0x80000 uid 0`.

`del`+`add` is idempotent. netd rebuilds the rules on network changes, so the
supervisor must redo this **every loop** (60 s is fine) and on boot.

NOTE: mirroring the default into `main` (`ip route replace default ... table main`)
was tried and **does not work** -- netd installs an explicit `unreachable default`
there. Use the rule above.

DNS fallback (only needed on 1.102.x), also refreshed each loop:
```sh
D=$(getprop net.dns1)
[ -n "$D" ] && { mount -o rw,remount /system; printf 'nameserver %s\n' "$D" > /system/etc/resolv.conf; mount -o ro,remount /system; }
```
(`/etc` -> `/system/etc`, read-only by default; needs a remount.)

### Step 3 — daemon flags
```sh
tailscaled --statedir=/data/misc/le1-tailscale \
  --socket=/data/le1-tailscale/tailscaled.sock \
  --tun=tailscale0 --port=0 --no-logs-no-support
```
**Gotchas (hit on the LE1):**
- **1.103 removed `--netfilter-mode`** — passing it is a hard startup error
  (`flag provided but not defined`). 1.102.x accepted it.
- `--accept-dns` is a **`tailscale up`** flag, never a `tailscaled` flag.
- The auth key must be passed as `--authkey=`; a stale/one-time key silently
  falls back to an interactive login URL.
- **1.103's `logpolicy` panics at startup** — `panic: no safe place found to store
  log state` — unless `<statedir>/logs` exists and is mode **0700**, root-owned.
  1.102.x did not need this. The wrapper now does
  `mkdir -p "$S/logs"; chmod 700 "$S" "$S/logs"`.
- **The clock reverts to the dead-RTC default (~2007) a few minutes after boot.**
  The supervisor restores it from `/data/misc/le1-time/last` at startup, but Android
  slams it back. Fix: `restore_clock` now also runs **every 60 s loop** (and
  `auto_time` was set to 0 in testing). Without a correct clock every TLS handshake
  fails (`certificate ... not yet valid`).

### Step 4 — login and handover
```sh
TS_AUTHKEY=$(cat /data/le1-tailscale/authkey) \
  tailscale --socket=/data/le1-tailscale/tailscaled.sock up \
    --accept-dns=false --accept-routes=false --hostname=le1
```
Then, **only if** `ip addr show tailscale0` has an `inet` address, clear
`always_on_vpn_app` and (optionally) `pm disable-user com.tailscale.ipn` with an
APK backup. **Keep** the current guard: if the address is absent, leave the app's
always-on VPN in place so the unit can never be stranded (it has no LAN path
from us).

### Step 5 — persistence
`boot/le1-boot.sh` already has `ensure_tailscale` (currently **disabled**). Re-enable
it once Steps 1-2 are proven, with the route refresh inside the loop.

---

## Verify (device on)

```sh
# the mark and where Android sends it (this is the crux)
ip rule show
ip route get 8.8.8.8 mark 0x80000          # before: "Network is unreachable"
ip route show table main | grep default     # before: nothing

# after the fix
ip addr show tailscale0 | grep inet        # expect 100.x.y.z/32
tailscale --socket=/data/le1-tailscale/tailscaled.sock status
ping -c1 <pi-tailnet-ip>
curl -s -o /dev/null -w '%{http_code}\n' https://controlplane.tailscale.com/key
```

## Risks / open questions

1. **Unstable binary** — 1.103.229 is an unstable build; 1.102.4 is stable. We can
   pin the tarball (already on disk) and upgrade to 1.103 stable when released.
2. **Mark not configurable yet** — until PR #18695 lands we depend on the
   `main`-table route mirror; if Google changes the rule, it breaks again.
3. **MagicDNS** stays off (`--accept-dns=false`); tailnet names would need
   dnsproxyd wiring we are not doing.
4. **Two Tailscales** — while the app is enabled both register. Sequence the
   handover (Step 4) so only one is up once root ts has an address.
5. **`ip rule`/table ids** are vendor-specific; confirm `table 1004` on the LE1
   rather than assuming (it is the AOSP default for the first Wi-Fi network).

## References
- tailscale/tailscale#21139 (androiddns, merged) — https://github.com/tailscale/tailscale/pull/21139
- tailscale/tailscale#18695 (configurable marks, open) — https://github.com/tailscale/tailscale/pull/18695
- WayneShao/KernelSU-Tailscaled#1 (exact diagnosis) — https://github.com/WayneShao/KernelSU-Tailscaled/issues/1
- anasfanani/Magisk-Tailscaled (reference module) — https://github.com/anasfanani/magisk-tailscaled

---

## Verified working recipe (LE1, 2026-09-20)

```sh
# 0. clock must be right or every TLS handshake fails ("certificate ... not yet
#    valid"). /system/bin/date is toybox: `date -u "@<epoch>"` (no -s).
#    WARNING: never derive the epoch from the device's own `date +%s` while its
#    clock is wrong -- that re-sets it to 2007. Take the epoch from a sane host.
date -u "@$(date +%s)"            # epoch supplied from outside

# 1. route the Android bypass mark out the real interface table
IFACE=$(ip route show table all | grep -m1 '^default via' | grep -oE 'dev [a-z0-9]+' | head -1 | cut -d' ' -f2)
[ -n "$IFACE" ] || IFACE=wlan0
ip rule del fwmark 0x80000/0xff0000 lookup "$IFACE" pref 5200 2>/dev/null
ip rule add fwmark 0x80000/0xff0000 lookup "$IFACE" pref 5200 2>/dev/null

# 2. daemon (1.103.229 arm; no --netfilter-mode, no --accept-dns)
/data/le1-tailscale/bin/tailscaled --statedir=/data/misc/le1-tailscale \
  --socket=/data/le1-tailscale/tailscaled.sock \
  --tun=tailscale0 --port=0 --no-logs-no-support &

# 3. login
tailscale --socket=/data/le1-tailscale/tailscaled.sock up \
  --authkey="$(cat /data/le1-tailscale/authkey)" \
  --accept-dns=false --accept-routes=false --hostname=le1
```

Observed result:
```
ip route get 8.8.8.8 mark 0x80000 -> via 172.26.39.235 dev wlan0  (ok)
ip addr show tailscale0           -> inet 100.122.21.101/32
tailscale status                  -> sees the whole tailnet (moto-g54-5g idle)
tailscale ping moto-g54-5g        -> pong via 179.68.107.16:3118 in 63ms
phone -> ping 100.122.21.101      -> 2/2
```

### Open items
- **Node identity**: the root daemon registered a *new* node (`le1-1` /
  100.122.21.101) because the app's state was not reused; the app's node `le1`
  (100.124.251.81) still exists. Decide: keep `le1-1` and drop the app, or copy
  the app's `tailscaled.state` to reuse the original IP.
- **Boot clock**: the supervisor restores the clock from `/data/misc/le1-time/last`;
  a dead RTC means a wrong clock at boot until that runs. Keep the app's always-on
  VPN until a full reboot proves root `tailscaled` comes up on its own.
- **`--accept-dns=false`** means no MagicDNS; tailnet names are not resolvable on
  the device (IPs work).
