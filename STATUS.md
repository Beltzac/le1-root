# LE1 Root Attempt — Session Log & Findings

## ⚠️ 2026-09-10 — the 2026-09-06 "persistent" claim was WRONG; fixed properly

Root survived *within a boot* but **not across a reboot**. On-device check after
reboot: `init.svc.sudaemon` empty, `le1-loadtime.log` stale — although
`/system/etc/init/sudaemon.rc` and `sudaemon` exist and are correct.

Cause: the `.rc` files were written correctly, but nothing started at boot
(`init.svc.sudaemon` empty, `le1-loadtime.log` stale). The session concluded
"MTK init ignores custom `/system/etc/init/*.rc`" — **unconfirmed**: `lk.bin`
only sets `androidboot.init_rc` for meta/factory modes, so normal boot *should*
parse `/system/etc/init`. Either way the fix does not depend on it (see below).

Fix: `post-root/persist.sh` installs a hook into **`/system/bin/install-recovery.sh`**,
which the *ramdisk* init.rc runs as root via `service flash_recovery` (always
parsed). It execs `/system/bin/le1-boot.sh`, a supervisor that restores the cached
clock, keeps `sudaemon` alive and keeps Android `auto_time=1`. See
`FIXES-2026-09-10.md`. Verified in an Alpine/proot VM: `test/test-persist.sh`
(install + boot chain) and `test/test-boot.sh` (supervisor) both ALL PASS. The exploit now hardens the blocking `readv` (SIGALRM),
throttles `fsync`, and installs the hook; `root-loop.sh` no longer hammers the
exploit at every boot.

## ✅ ROOT ACHIEVED (in-boot) (2026-09-06)

CVE-2019-2215 (binder UAF) exploit **succeeded**. Full chain completed:
- phase1 leaked task_struct `0xc4700680`; phase2 leaked stack `0xd277a000`,
  clobbered addr_limit; cred recovered via `find_cred` (offset 0x39C is wrong
  on this 3.18.79 build — fallback scan found it, `0xdb12ab00`).
- `getuid()=0` confirmed. Remounted /system rw (auto-detected device).
- Installed: `/system/bin/sudaemon` (daemon, root), `/system/xbin/su` (client),
  `/system/etc/init/sudaemon.rc` (auto-start at boot).
- `su daemon RUNNING` (PID ~10819, socket `/data/local/tmp/.su.sock`).
- `/system/xbin/su -c 'id'` → `uid=0(root) gid=0(root)`. **Survives reboots.**

### The two fixes that made it work (vs. the prior "~95%" state)
1. **Clobber regression**: the earlier "deterministic pipe-blocking handshake"
   rewrite of `clobber_data` (preUafBytes=1, 28-byte chunk, wait_pipe_bytes) NEVER
   landed the arbitrary write. Reverted to the proven ARM32 reference (su.c):
   3-process model (helper/child/parent) + signal-pipe + `busy_wait_ns` +
   `preUafBytes=12` + `clobberSize=16` + 40 retries (50µs→830µs).
2. **cred offset 0x39C wrong**: `leak_phase2` was requiring `cred` to be a valid
   kernel pointer and bailing. Relaxed it to only require `stack`; `main()` already
   falls back to `find_cred()` after addr_limit bypass, which found the real cred.

## Device state (when online)
- Tailscale `le1` → 100.124.251.81, SSH `u0_a50@... -p 8022` (works)
- Local adb: `adb connect 127.0.0.1:5555` → uid 2000 (shell)
- Android 8.1.0, kernel `3.18.79 #8 SMP PREEMPT Mon Aug 24 15:11:49 CST 2020` armv7l
- Build fingerprint: `LeTV/Le1/Le1:8.1.0/O11019/1598252866:user/release-keys`
- Display ID: OS_v2.0.5 (LeTV-branded k80_bsp MT6580M head unit)

## Hard facts (verified)
- **SELinux: Permissive** (`getenforce` → Permissive, ro.boot.selinux=disabled)
- **No KASLR**: PAGE_OFFSET=0xC0000000, VMSPLIT_3G, no CONFIG_RANDOMIZE_BASE → kernel text base **0xC0008000** (fixed)
- **No active dm-verity**: no /dev/block/dm-*, /system mounts directly from mmcblk0p22 (ext4 ro). → if we get root once, remount rw + drop su = PERMANENT
- **Security patch: 2018-10-05** → CVE-2019-2215 (binder UAF, fixed Oct 2019) almost certainly VULNERABLE
- Binder: CONFIG_ANDROID_BINDER_IPC=y + 32BIT=y, devices "binder,hwbinder,vndbinder"
- **adbd production build** (`adb root` → "cannot run as root in production builds"). Setting service.adb.root=1 / persist.adb.root=1 / sys.rkadb.root=1 + restart adbd → STILL uid 2000. Vendor props ignored (Rockchip semantics, not honored by MTK adbd).
- kallsyms present (1.3MB) but addresses zeroed (kptr_restrict=2). dmesg_restrict=0.
- `/proc/iomem`, `/proc/cmdline`: permission denied.
- No `su` anywhere. Only setuid-root binary: `/system/bin/jbset`.
- `ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`, `ro.boot.veritymode=enforcing` (verity prop is a lie — no dm devices).

## jbset reverse-engineered (dead end)
- `/system/bin/jbset` setuid root (6755), SELinux domain jbset_27_0, service `jbset` (disabled oneshot).
- init.project.rc comment: "HuangZeming add for set raw value 20180330" → NOT "jailbreak", it's an MCU raw-value writer.
- main(): `jbset <index> [value]` opens `/dev/block/platform/mtk-msdc.0/11120000.msdc0/by-name/custom` (mmcblk0p13) O_RDWR, lseek+write:
  - idx 0 → 1 byte @0xfe; idx 1 → @0xfd; idx 2 → @0xfc; idx 3 → @0xfa; idx 4 → 8 bytes @0xc8 (+ioctl 0x40046402 on a device)
- Sets `persist.jbset.running=false`. No arbitrary file write, no command exec, path hardcoded. NOT exploitable for root.

## Persistence set up
- `com.termux.boot` installed + RECEIVE_BOOT_COMPLETED granted.
- Created `~/.termux/boot/start-sshd.sh` (starts runsvdir + sshd -p 8022). SSH should now survive reboots (IF the head unit's autostart lets Termux:Boot run — unverified).

## ⚠️ Cleanup needed when online
- I set `persist.adb.tcp.port=5555` (network ADB) + `debug.adb.root=1` + `persist.adb.root=1` + `sys.rkadb.root=1`.
- Revert `persist.adb.tcp.port` (exposes ADB over TCP, ro.adb.secure=1 so needs auth, but still):
  `adb shell setprop persist.adb.tcp.port ""` (or `-1`). Leave others (harmless).

## Firmware obtained (in ~/rootkit/)
- `stock_dump.bin` (1.3GB ZIP) = full SPFT firmware: system.img(2.1G), vendor.img(512M), boot.img(7.4M), recovery.img, lk.bin, preloader_k80_bsp.bin, MT6580_Android_scatter.txt, custom.img, build.prop files.
- `patched_boot.img` = "Hippcron JS7 alps_k80_bsp - ROOT via Magisk.zip" (7.6MB) → Root/boot.img (Magisk), scatter, preloader.
- **IMPORTANT: both are the Oct-2025 build** (CMDAZX80-U1_R8010_S5.50, incremental 1760445918, kernel "3.18.79+ #2 Oct 14 2025").
- Our device is Aug-2020 build (#8). **Symbol addresses differ between builds.**

## Independent JS7 V4 reference (online-verified 2026-09-03)
- Repo: BenGeorgie55/JS7-V4-mostly-stock-backup-firmware (created 2026-08-30) —
  JS7 V4 MT6580 8.1, partition artifacts + recovery.img + getprop/dmesg/logcat (no boot/system img).
- Same platform, NEWER build: `alps/full_k80_bsp/k80_bsp:8.1.0/O11019/1676628720:user/release-keys`,
  display CMDAZX80-U1_R8010_S6.14, patch **2019-01-05** (still pre-Oct-2019 → 2215 unpatched there too).
- **Partition map CONFIRMS ours**: system=mmcblk0p22, boot=p8, recovery=p9, odmdtbo=p12 (DTBO exists),
  custom=p13 (matches jbset path), vendor=p15, userdata=p24. Validates backup-emmc.sh critical list.
- **cmdline CONFIRMS ours**: `androidboot.selinux=permissive androidboot.veritymode=enforcing`,
  `verifiedbootstate=green`, console `ttyMT0,921600n1`, `gpt=1`. The verity-lie signature repeats across builds.
- **eMCP differs**: `DDR_MCP_PartNum=KMQX10013M_B419` (XDA thread unit: KMFE60012M-B214) → board variants exist.
- **`ro.build.tags=test-keys` + release-keys fingerprint** → STATUS path-3 (test-keys recovery update.zip)
  gains credibility; check our recovery the same way when online (`getprop ro.build.tags`).
- Do NOT mix-match images across incrementals (1598252866 vs 1676628720 vs 1760445918).

## Kernel symbols (Oct-2025 build — reference only, NOT our kernel)
From vmlinux-to-elf (kernel.elf):
- commit_creds = 0xc0146cf0
- prepare_kernel_cred = 0xc014717c
- start_kernel = 0xc0f009cc
- base guessed 0xc0100000 (need to confirm vs 0xc0008000)

## Paths to root
1. **CVE-2019-2215 (software, current firmware)** — best software path. Needs OUR kernel's exact
   commit_creds/prepare_kernel_cred addresses. Options:
   a. Find Le1 OS_v2.0.5 (Aug 2020) firmware online → extract symbols → build 32-bit PoC.
   b. Use Oct-2025 symbols as gamble (low probability, kernel panic→reboot = recoverable).
   c. **In-memory kallsyms recovery (RECOMMENDED, template on file)** — `poc/cve-2019-2215-3.18/su98-memory-kallsyms.c`
      defeats kptr_restrict=2: after the UAF gives arbitrary R/W, scan kernel memory for the
      kallsyms format string, locate kallsyms_addresses, parse compressed symbols in RAM →
      resolve commit_creds dynamically. No firmware hunt needed. CAVEAT: template is ARM64
      (base 0xffffffc0, 8-byte pointers) — port the scanner to ARM32 (base 0xC0000000, 4-byte).
      Core format strings are identical (shared kernel code). This replaces the cred@0x39C guess.
   NOTE (online-verified 2026-09-03): the famous XDA `su98` binary / arpruss/cve2019-2215-3.18
   is GONE (repo deleted; Karma2424 fork survives) and is **ARM64-only** (KERNEL_BASE
   0xffffffc0, WAITQUEUE 0x98, stack@0x008) — useless on our ARM32 MT6580 (base 0xC0000000,
   WAITQUEUE 0x50, stack@0x004). Our Sonim-based ARM32 port (`exploit/le1_root.c`) stays
   the correct base; do NOT chase su98.
2. **SP Flash Tool flash of Magisk boot.img (PROVEN, hardware)** — needs USB debug-port mod
   (remove 2x 2.75Ω resistors on DEBUG header, solder VBUS/D+/D-/GND) + Windows/Linux PC.
   Everything downloaded. mtkclient alt: `python3 mtk da seccfg unlock; mtk r boot; mtk d boot magisk_patched.img`.
   BROM entry (Hovatek, verified 2026-09-03): try Vol-down / both-vol / both-vol+power
   while plugging USB first; if preloader grabs the port and drops it, use the
   crash-preloader-to-BROM trick (SPFT Download with scatter loaded → expected error
   leaves the device stuck as Mediatek USB Port) or `mtkclient`'s crash feature.
   Head unit with no buttons → test point is the fallback, crash trick first.
   XDA cross-check (thread 4791038, ExtremeMOD Jun 2026, single post = unconfirmed by 2nd unit):
   exact eMCP Samsung KMFE60012M-B214; SoC printed MT6580A (our MT6580M family);
   unit advertised as Android 12, real 8.1; multimeter-check D+/D− before touching
   resistors; vendor FW is lightweight (fast for 1GB — freeze less, not more).
3. **update.zip via test-keys recovery (untested)** — ro.build.tags=test-keys → recovery may accept
   test-key-signed update.zip that writes su to /system/xbin. Some brick risk. Needs verification
   that MTK stock recovery auto-applies /sdcard/update.zip.

## Next session actions (when device online)
1. Reconnect SSH + adb.
2. Revert persist.adb.tcp.port.
3. Get ro.build.display.id / incremental / description / flavor to search for exact firmware.
4. Decide exploit path with user.
