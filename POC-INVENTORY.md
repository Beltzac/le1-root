# LE1 PoC Inventory — kernel 3.18.79 / MT6580 / Android 8.1

Generated for the LE1 head unit. All PoCs live under `~/le1-root/poc/`.
"Config on LE1" is verified against `arch/arm/configs/k80_bsp_defconfig` from
`obraxys/kernel_3.18.79` (the exact board kernel source).

Legend:
- **Config:** ✅ compiled in  ·  ❌ not compiled  ·  ⚠️ partial/uncertain (module)
- **Arch:** ✅ ARMv7-32 ready  ·  🔧 needs port  ·  ❌ x86/ARM64 only
- **Type:** LPE = local privilege escalation (root path) · REMOTE · HW = needs hardware

---

## Local Privilege Escalation (root candidates — primary)

| # | CVE | Path | Subsystem | Config | Arch | Status | Notes |
|---|-----|------|-----------|--------|------|--------|-------|
| 1 | **CVE-2019-2215** | `cve-2019-2215-3.18/` `cve2019-2215-3.18/` `CVE-2019-2215/` `cve-2019-2215_SH-M08/` | binder UAF | ✅ `BINDER_IPC=y` | 🔧 32-bit port **in progress** (`~/le1-root/exploit/le1_root.c`) | ⭐ **~95% done, last blocker 1-byte leak fix** | See SKILL.md + RESEARCH.md. Working ARM32 technique from `root-sonim-xp3800/` |
| 2 | **CVE-2020-0041** | `CVE-2020-0041/` | binder (Bad Binder) | ✅ `BINDER_IPC=y` | 🔧 port needed (bluefrost x86/ARM64) | untested | `PORT.md` in repo; Android Security Bulletin Mar-2020 |
| 3 | **CVE-2016-8655** | `CVE-2016-8655/` + `kernel-exploits-bcoles/CVE-2016-8655/` | AF_PACKET (packet_sock chokepoint) | ✅ `PACKET=y` | 🔧 x86 PoC, port to ARM32 | untested | Android variant exists (`martinmullins/CVE-2016-8655_Android`) |
| 4 | **CVE-2017-7308** | `CVE-2017-7308/` + `kernel-exploits-xairy/CVE-2017-7308/` | AF_PACKET (packet_set_ring heap overflow) | ✅ `PACKET=y` | 🔧 port to ARM32 | untested | xairy PoC is x86-64 |
| 5 | **CVE-2016-9793** | `CVE-2016-9793/` + `kernel-exploits-xairy/CVE-2016-9793/` | AF_PACKET / SO_SNDBUFFORCE (net/ipv4) | ✅ `PACKET=y` | 🔧 port | untested | |
| 6 | **CVE-2017-1000112** | `CVE-2017-1000112/` `CVE-2017-1000112-Spydomain/` `kernel-exploits-xairy/CVE-2017-1000112/` | UDP fragmentation (ip_ufo_append_data) | ✅ `INET=y` | 🔧 port | untested | Also `CVE-2017-1000112-Adpated` variant |
| 7 | **CVE-2016-0728** | `CVE-2016-0728/` `CVE-2016-0728-testbed/` | keyrings refcount overflow | ❌ `CONFIG_KEYS` **not set** | 🔧 | **NOT applicable** | Saved for completeness; keyrings not compiled |
| 8 | CVE-2017-1000111 | *(no standalone repo — see below)* | AF_PACKET (packet_set_ring) | ✅ `PACKET=y` | 🔧 | not found | No public standalone PoC; adapt from CVE-2016-8655 PoC (same surface) |
| 9 | CVE-2018-18955 | `kernel-exploits-bcoles/CVE-2018-18955/` | userns map_write | ❌ `USER_NS` **not set** | — | **NOT applicable** | |
| 10 | CVE-2019-13272 | `kernel-exploits-bcoles/CVE-2019-13272/` | ptrace PTRACE_TRACEME | ✅ core (ptrace) | 🔧 | untested | Worth a try; affects 3.18 |
| 11 | CVE-2017-6074 | `kernel-exploits-xairy/CVE-2017-6074/` | DCCP double-free | ❌ no DCCP protocol | — | **NOT applicable** | only conntrack helper compiled |
| 12 | CVE-2018-5333 | `kernel-exploits-bcoles/CVE-2018-5333/` | RDS | ❌ `RDS` **not set** | — | **NOT applicable** | |

## MediaTek-specific root

| # | CVE | Path | Config | Arch | Status | Notes |
|---|-----|------|--------|------|--------|-------|
| 13 | CVE-2020-0069 (mtk-su) | `mtk-su/` `mtk-easy-su/` `AutomatedRoot/` | MTK CMDQ driver UAF | ✅ `MTK_CMDQ=y` | ❌ **ARM64 only** (MT6580 = ARMv7) | **fails on MT6580/M** | JunioJsv/mtk-easy-su (1168★) = Magisk+mtk-su combo; R0rt1z2/AutomatedRoot automates. Both hit the same 64-bit wall |

## Remote (no-auth) — lower priority for root, saved for completeness

| # | CVE | Path | Config | Type | Notes |
|---|-----|------|--------|------|-------|
| 14 | CVE-2017-1000251 (BlueBorne) | `CVE-2017-1000251-blueborne/` `CVE-2017-1000251-blueborne2/` | L2CAP (BT) | ⚠️ `MTK_COMBO_BT=y`; `bt_drv` module | REMOTE RCE | Confirm `net/bluetooth` present on-device (CONFIG_BT not in defconfig but bt_drv module exists) |
| 15 | CVE-2016-5696 | `CVE-2016-5696-rover/` `CVE-2016-5696-challack/` | TCP challenge ACK side-channel | ✅ `INET=y` | REMOTE (off-path) | Hard to weaponize; low value for root |
| 16 | CVE-2019-15215 | *(not cloned — no clean public PoC)* | snd-usb-audio UAF | ✅ `SND_USB_AUDIO=y` | LPE via USB | Needs physical/OTG USB audio device |

## Reference collections (non-direct PoCs)

| Path | What |
|------|------|
| `kernel-exploits-xairy/` | Andrey Konovalov's PoCs: CVE-2016-2384 (usb-midi, ❌), 2016-9793, 2017-1000112, 2017-18344, 2017-6074 (❌), 2017-7308, 2025-38494, prefetch side-channel |
| `kernel-exploits-bcoles/` | bcoles collection: 2016-8655, 2016-9793, 2017-1000112, 2017-7308, 2018-18955 (❌), 2018-5333 (❌), 2019-13272, 2021-22555 |
| `android-kernel-exploitation/` | cloudfuzz/AndroidKernelVulnerability + android-kernel-exploitation (4.14-dev emulator lab, ARM64/x86 reference) |
| `root-sonim-xp3800/` | flipphoneguy root for Sonim XP3800 — **the working ARM32 binder technique** used as template for le1_root.c |

---

## What's actually worth trying next (ranked)

1. **Finish CVE-2019-2215** (`~/le1-root/exploit/le1_root.c`) — 1-byte leak fix already applied, just re-run on device (~30s, device online).
2. **CVE-2019-13272** (ptrace) — pure core-kernel, no module deps, plausible on 3.18. Quick port.
3. **CVE-2016-8655 / CVE-2017-7308** (AF_PACKET) — `PACKET=y` confirmed, need ARM32 port (xairy PoC is x86).
4. **CVE-2017-1000112** (UDP frag) — `INET=y`, port needed.
5. BlueBorne / USB-audio — remote/physical, last resort.

### Not applicable (config-verified, don't waste time)
CVE-2016-0728 (no KEYS), CVE-2017-6074 (no DCCP), CVE-2018-5333 (no RDS),
CVE-2018-18955 (no USER_NS), CVE-2016-2384 (no usb-midi), mtk-su/CVE-2020-0069 (ARM64-only).
