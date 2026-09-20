# LE1 — root `tailscaled` on Android: research, theory and plan

Status: **researched + theorised (2026-09-20). Not yet working. Two independent
Android-isms block it; both have concrete fixes.**

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
| 2 | `dial tcp <ip>:443: connect: network is unreachable` | Android policy routing sends sockets with the **bypass mark `0x80000`** to the **`main`** table, which has **no default route** (the default lives in the per-network table) | mirror the active network's default route into `main`, re-applied on every network change |

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

### Step 2 — Route: mirror the active default into `main`
The supervisor must (re)do this on **every** boot and **every** network change
(the tables are rebuilt from scratch and our route is wiped):

```sh
# current default network + gateway (LE1 has no awk in /system/bin -- use cut)
GW=$(getprop dhcp.wlan0.gateway 2>/dev/null)
[ -n "$GW" ] || GW=$(ip route show table 1004 2>/dev/null | grep '^default' | cut -d' ' -f3)
ip route replace default via "$GW" dev wlan0 table main
```

`ip route replace` is idempotent. The 60 s supervisor loop is a good enough
cadence; optionally also trigger on `net.dns1`/`dhcp.wlan0.gateway` change.

DNS fallback (only needed on 1.102.x), also refreshed each loop:
```sh
D=$(getprop net.dns1); [ -n "$D" ] && printf 'nameserver %s\n' "$D" > /system/etc/resolv.conf
```
(`/etc` -> `/system/etc`; needs `/system` rw once, then it persists.)

### Step 3 — daemon flags
```sh
tailscaled --statedir=/data/misc/le1-tailscale \
  --socket=/data/le1-tailscale/tailscaled.sock \
  --tun=tailscale0 --port=0 --netfilter-mode=off --no-logs-no-support
```
`--netfilter-mode=off` keeps Tailscale from editing Android's iptables.

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
