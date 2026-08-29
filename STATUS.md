# LE1 Root Attempt — Session Log & Findings

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
   c. Symbol-free exploit (addr_limit overwrite via list_del write-what-where, then dynamic symbol scan) — more engineering.
2. **SP Flash Tool flash of Magisk boot.img (PROVEN, hardware)** — needs USB debug-port mod
   (remove 2x 2.75Ω resistors on DEBUG header, solder VBUS/D+/D-/GND) + Windows/Linux PC.
   Everything downloaded. mtkclient alt: `python3 mtk da seccfg unlock; mtk r boot; mtk d boot magisk_patched.img`.
3. **update.zip via test-keys recovery (untested)** — ro.build.tags=test-keys → recovery may accept
   test-key-signed update.zip that writes su to /system/xbin. Some brick risk. Needs verification
   that MTK stock recovery auto-applies /sdcard/update.zip.

## Next session actions (when device online)
1. Reconnect SSH + adb.
2. Revert persist.adb.tcp.port.
3. Get ro.build.display.id / incremental / description / flavor to search for exact firmware.
4. Decide exploit path with user.
