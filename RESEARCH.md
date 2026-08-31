# LE1 Root — Research & Exploitation Plan (non-flashing)

## Goal
Root the LE1 car head unit (MT6580M, Android 8.1, kernel 3.18.79) **without SP Flash Tool / hardware flashing**.
Permanent root = once we get uid 0, remount /system rw (no dm-verity active) + drop `su` (6755) → survives reboot.

## Device security posture (all verified live)
- SELinux **Permissive** (ro.boot.selinux=disabled) → any kernel LPE = full root, no SELinux policy to bypass
- **No KASLR** (PAGE_OFFSET=0xC0000000, VMSPLIT_3G, no CONFIG_RANDOMIZE_BASE) → kernel text base **0xC0008000** fixed
- **No active dm-verity** (no /dev/block/dm-*; /system = plain ext4 mmcblk0p22, ro)
- **Security patch 2018-10-05** → CVE-2019-2215 (binder UAF, fixed Oct-2019) VULNERABLE
- Binder: CONFIG_ANDROID_BINDER_IPC=y + _32BIT=y, devices "binder,hwbinder,vndbinder", /dev/binder exists
- adbd = production build (`adb root` → "cannot run as root in production builds"). ALLOW_ADBD_ROOT not defined.
- kallsyms present (38262 syms) but kptr_restrict=2 → addresses zeroed for us. dmesg_restrict=0 (only leaks wifi vmalloc addrs).
- No su binary. Only setuid-root: /system/bin/jbset (MCU config writer — NOT exploitable, reverse-engineered).
- ro.boot.verifiedbootstate=green, ro.boot.flash.locked=1.

## THE PATH: CVE-2019-2215 binder UAF (ARM32 3.18 port)

### Reference material (saved in ~/le1-root/poc/)
- `android-kernel-exploitation/` (cloudfuzz) — full PoC + gitbook methodology (x86_64/4.14)
- `CVE-2019-2215/` (c3r34lk1ll3r) — minimal PoC.cpp (leaks task_struct + clobbers addr_limit)
- `AndroidKernelVulnerability/` (sharif-dev)
- `grant_hernandez.html` — "Tailoring CVE-2019-2215 to Achieve Root" (cred patch details)

### Exploit flow (from cloudfuzz gitbook)
1. **UAF trigger**: open /dev/binder → epoll_ctl(EPOLL_CTL_ADD, binder_fd) → ioctl(binder_fd, BINDER_THREAD_EXIT=0x40046208) frees binder_thread → the epoll waitqueue still references the freed chunk.
2. **Leak task_struct** (stage 1): reclaim freed binder_thread with an iovec array (writev on a full pipe, blocks). Trigger unlink (EPOLL_CTL_DEL in child) → clobbers iov[WQ].iov_len and iov[WQ+1].iov_base with wait.head pointers → read back PAGE_SIZE → leak `binder_thread->task` (task_struct ptr).
3. **Arbitrary write** (stage 2): repeat UAF, reclaim with iovec via recvmsg(MSG_WAITALL) on socketpair. Unlink clobbers iov chain → write `0xFFFFFFFE` (or -1) to `addr_limit`.
4. **Arbitrary R/W**: with addr_limit = KERNEL_DS, use read()/write() on a pipe to read/write kernel memory.
5. **Patch cred**: read current task_struct->cred, overwrite uid/gid/euid/...=0, cap_effective=0x3FFFFFFFFF, security=NULL (SELinux already permissive so optional) → root. Spawn shell.

### ARM32 (our target) adaptations required
- `sizeof(struct iovec)` = 8 (not 16). `sizeof(struct binder_thread)` ≈ 0x7C-ish (not 408).
- `binder_thread->wait` offset & `->task` offset differ (compute from kernel).
- **addr_limit is NOT in task_struct** (3.18 ARM has thread_info on the 8KB kernel stack, no THREAD_INFO_IN_TASK).
  - thread_info->addr_limit = 0x8, thread_info->task = 0xC (struct thread_info, ARM 3.18).
  - Need the kernel stack/thread_info address. Options:
    a. Leak a stack pointer from the reclaimed chunk (read 4096 bytes past binder_thread — adjacent heap may contain stack ptrs).
    b. Use arbitrary WRITE (stage 2) to overwrite thread_info->addr_limit directly IF stack known.
    c. Alternative: patch cred WITHOUT addr_limit — but need cred ADDRESS (requires read of task_struct->cred).
  - Since SELinux is permissive and we only need cred patch, another route: use stage-1 leak repeatedly to also leak `task_struct->cred` (binder_thread chunk is in kmalloc cache; task_struct is in a different cache — not directly adjacent).
- `dummy_page` mmap: on ARM32 use e.g. 0x10000000-aligned user page (spinlock lower-32-bits must be 0 — on 32-bit, need iov_base with low 4 bytes == 0; use mmap hint at a 4KB-aligned address).
- BINDER_THREAD_EXIT ioctl = 0x40046208 (same, _IOW('b', 8)).

### Struct offsets needed (compute & verify on device)
- binder_thread: wait, task offsets (disassemble binder_thread_release / binder_poll from kernel.elf, or get Android 8.1 binder.c)
- task_struct: cred, pid, real_cred offsets (3.18 ARM)
- thread_info: addr_limit (0x8), task (0xC)
- cred: uid=0x4, gid=0x8, euid=0x14, cap_effective=0x38, security=0x60-ish (verify; 3.18 has no cap_ambient)

### Build
- On-device clang 21.1.8 (armv7a-linux-android24) can compile. Or NDK cross-compile here.
- Compile with `-DNDEBUG -O2 -march=armv7-a -m32`.

### Risk
- Kernel panic → reboot (recoverable). Not bricking. But iterate carefully.

## Alternative paths (lower priority)

### A. META / factory mode adbd --root_seclabel (TEST, cheap)
- vendor init has `service adbd /system/bin/adbd --root_seclabel=u:r:su:s0` in meta_init.rc + factory_init.rc.
- BUT adbd is production build (no ALLOW_ADBD_ROOT) → --root_seclabel is a no-op. Likely still shell uid.
- Still worth ONE test when online: `adb reboot meta` → check `adb shell id`. Risk: loses SSH (Termux won't run in meta) — recover via `adb reboot` if adb works in meta, else power-cycle.
- Also `permission_check` (vendor/bin, root service), `factory`, `meta_tst` binaries — inspect for IPC/injection.

### B. recovery update.zip (needs vendor signing key)
- recovery has `--root_seclabel=u:r:su:s0` too, but production adbd.
- recovery accepts signed update.zip ("Verifying update package...", /cache/recovery/command, "Choose a package to install", mt_install.cpp, adb_install.cpp).
- **Blocker**: recovery res/keys is a CUSTOM key (verified: NOT AOSP testkey; n0inv=0xc926ad21). Need vendor private key to sign → unlikely.
- If key obtained: craft update.zip (updater-script mounts /system rw + writes su + chmod 6755), sign, place /sdcard/update.zip, write /cache/recovery/command `--update_package=...`, `adb reboot recovery`.

### C. boot.img flash (PROVEN but hardware — user wants to avoid)
- Have Magisk-patched boot.img + full SPFT firmware (Oct-2025 build) in ~/rootkit/.
- META-mode root shell (if A works) could `dd` Magisk boot.img to mmcblk0p8 — that's a *software* flash (no SPFT), but boot.img is a different build (Oct 2025 vs our Aug 2020) — risk.

## Key facts about the firmware (extracted, in ~/rootkit/)
- `stock_dump.bin` (1.3GB) = full SPFT firmware for **Oct-2025 build** (CMDAZX80-U1_R8010_S5.50, kernel "3.18.79+ #2 Oct 14 2025").
- Our device = **Aug-2020 build** (LeTV/Le1, "3.18.79 #8 Aug 24 2020"). Symbol ADDRESSES differ between builds (need our kernel for exact symbols), but STRUCT offsets (same 3.18.79 base) likely match.
- `kernel.elf` = extracted symbols from Oct-2025 kernel: commit_creds=0xc0146cf0, prepare_kernel_cred=0xc014717c, binder_thread_release=0xc07e7fec, binder_thread_read=0xc07e6cbc, binder_thread_dec_tmpref=0xc07e5a48 (reference only).
- Extracted: system.img (2.1G), vendor.img (512M), custom.img (256M), recovery.img, lk.bin, boot.img ramdisk, all init *.rc, adbd, factory, flashloader binaries.
- `~/rootkit/extracted/init/` — all init scripts. `~/rootkit/recovery_rd/` — recovery ramdisk.

## Next steps when LE1 online
1. Reconnect SSH+adb. Revert `persist.adb.tcp.port` (cleanup I set earlier).
2. Save /proc/config.gz locally (for exact struct offsets).
3. Get exact build IDs (ro.build.display.id etc.) → search for our exact firmware (for our kernel symbols) — still valuable.
4. Test META mode root (path A) — cheap.
5. Start CVE-2019-2215 ARM32 PoC: compute offsets (disassemble binder from kernel.elf + get 3.18 ARM thread_info/task_struct offsets), write PoC, test iteratively on device.

## Files location
- ~/le1-root/STATUS.md (previous session log)
- ~/le1-root/poc/ (PoC repos + grant_hernandez blog)
- ~/rootkit/ (firmware + kernel.elf + extracted)
- ~/le1-root/binder_318.c (mainline 3.18 binder ref — NOT android version)

## SESSION 2 UPDATE — CVE-2019-2215 EXPLOIT IN PROGRESS (confirmed working!)

### Live testing results (device = gwi_dnyb, kernel "3.18.79 #8 Aug 2020")
- Build: `full_gwi_dnyb` (Le1/gwi_dnyb), incremental 1598252866. NOT the k80_bsp firmware.
- Our kernel has **41312 kallsyms** (vs 38262 in k80_bsp) → different build confirmed.
- Config (from /proc/config.gz): **no THREAD_INFO_IN_TASK**, **CONFIG_ARM_THUMB=y but THUMB2_KERNEL NOT set (kernel is ARM!)**, SLUB, CONFIG_KEYS=y, no DEBUG_CREDENTIALS, SECURITY_SELINUX=y, no KASLR.
- **Kernel lowmem observed at 0x80000000+ (not 0xc0000000!)** — leaked slab addrs like 0xaad52xxx / 0xb0b44xxx. The config said VMSPLIT_3G/PAGE_OFFSET=0xC0000000 but reality is ~0x80000000+ (VMSPLIT_2G-style). VERIFY on next session.

### ✅ CVE-2019-2215 UAF + writev leak WORKS on the device
- `leak_test.c` / `dump_leak.c` in ~/le1-root/exploit/ compiled on-device (clang 21, armv7) and RAN.
- writev returned 8192 (2*PAGE), leak read 4096 bytes of KERNEL memory successfully.
- Termux (u0_a50) can open /dev/binder (0666), setprop, mmap — no adb needed.

### ARM32 leak technique (SOLVED the spinlock problem)
- wait.lock (spinlock) lands on iov[8].iov_base (0x40) on ARM32 → must be 0.
- FIX: set iov[8].iov_base=NULL, iov[8].iov_len=0 (writev skips it), and make the BLOCK happen at the leak iovec iov[9] (iov_len=2*PAGE) so iov[8] is processed before the clobber.
- This worked (no hang, clean leak).

### ⚠️ REMAINING: exact binder offsets
- My computed offsets (wait=0x40, task=0x120, binder_thread_sz=0x124) give a leak that shows a SLUB freelist of **48-byte (0x30) objects**, not the binder_thread chunk. → the device's binder_thread layout differs from my assumption (likely mainline-3.18-style binder, wait at 0x2C, or a dedicated small cache).
- Need to: dump full leak (/sdcard/leak.bin) + find the actual `wait` and `task` offsets empirically (scan leak for task_struct pointer, or disassemble device kernel).
- task_struct->stack = 0x4 (ARM32, confirmed from 3.18 source line 1237). thread_info->addr_limit = 0x8. This is the ARM32 path to arbitrary R/W (read stack from task_struct, then clobber addr_limit).

### Full exploit plan (port of su98.c / c3r34lk1ll3r to ARM32)
1. Leak task_struct (working, needs correct TASK offset).
2. Extra-leak task_struct->stack (offset 0x4) → thread_info.
3. Clobber thread_info->addr_limit (0x8) = 0xFFFFFFFF (KERNEL_DS).
4. Arbitrary R/W → find cred offset dynamically → patch uid/gid/caps=0 → root.

### Device access note
- SSH drops after device reboot (Termux:Boot may NOT auto-start on this head unit). Need user to reopen Termux or confirm autostart.
- persist.adb.tcp.port=5555 restored (was pre-set; I cleared it by mistake then restored).

## SESSION 3 UPDATE — FOUND THE COMPLETE ARM32 EXPLOIT

### ✅ KEY RESOURCE: flipphoneguy/root-sonim-xp3800 (cloned to ~/le1-root/poc/root-sonim-xp3800/)
This is a **complete working ARM32 (armv7l) CVE-2019-2215 root exploit** (su.c, 946 lines) for kernel 3.18.71.
- `docs/arm32-port.md` — full explanation of ARM32-specific challenges & fixes.
- `su.c` — the full exploit (leak → clobber addr_limit → arbitrary R/W → root).

### ARM32 challenges & solutions (from arm32-port.md)
1. **Alignment problem**: iovec=8 bytes on ARM32, so wait.lock (spinlock) lands on iov[WQ].iov_base (a POINTER, not a length like ARM64). The spinlock writes 0x10001 to iov_base → iov_iter derefs 0x10001 → KERNEL PANIC.
   - **Fix**: NULL guard — `iov[WQ].iov_base = NULL; iov[WQ].iov_len = 0;` (iov_iter skips it with no memory access).
2. **Timing problem**: UAF must fire after iov_iter passes iov[WQ] but while on iov[WQ+1].
   - **Fix (leak)**: pipe blocking — fill pipe to capacity-1 before iov[WQ], then iov[WQ+1] blocks in pipe_wait().
   - **Fix (clobber)**: signal pipe + busy_wait_ns + retry loop (40 attempts, 50-830µs delay).
3. **Two-phase leak** (chicken-and-egg: need stack ptr for addr_limit, need R/W for stack ptr):
   - Phase 1: leak task_struct from binder_thread's LAST 4 bytes (offset BINDER_THREAD_SZ-4), which SURVIVE the iovec reclaim (IOVEC_ARRAY_SZ = BINDER_THREAD_SZ/8, leaving last 4 bytes intact).
   - Phase 2: secondary clobber (clobber_with_retry) to overwrite iov[12]/iov[13] to read task_struct->stack (0x004) + task_struct->cred.

### Sonim XP3800 constants (DEVICE-SPECIFIC, must re-derive for LE1):
- BINDER_THREAD_SZ = 0x134 (308), WAITQUEUE_OFFSET = 0x50, IOVEC_INDX_FOR_WQ = 10
- OFFSET__task_struct__stack = 0x004 (STANDARD for 3.18 ARM, confirmed from sched.h line 1237)
- OFFSET__task_struct__cred = 0x39C (device/config-specific)
- OFFSET__thread_info__addr_limit = 0x008 (STANDARD ARM 3.18)
- cred offsets: uid=0x004, securebits=0x024, caps at 0x028/0x030/0x038/0x040/0x048 (STANDARD)
- SELINUX_ENFORCING = 0xc1310ae8 (NOT needed for LE1 — SELinux already Permissive!)
- isKernelPointer: 0xc0008000 <= p < 0xf0000000

### LE1 device-specific unknowns (MUST determine):
1. **BINDER_THREAD_SZ + WAITQUEUE_OFFSET** — candidates: my calc 0x124/0x40 (AKB0N 3.18.117 src), agent-r1 0x124/0x48 (Pixi4 3.18.79 src), Sonim 0x134/0x50 (3.18.71). Our device = 3.18.79, likely closer to agent-r1's 0x124/0x48.
2. **task_struct->cred offset** — can AVOID: modify phase 2 to only read stack (0x004), then after addr_limit clobber use arbitrary R/W to scan task_struct for cred (like su98.c getCredOffset).

### PLAN (next session, device online):
1. Check /proc/slabinfo for binder_thread size.
2. Adapt su.c: replace constants, remove SELinux part + denylist/daemon complexity (make a minimal root PoC).
3. Modify phase 2 to skip cred read (read only stack). After addr_limit, scan for cred dynamically.
4. Compile on-device (clang armv7), run, iterate on BINDER_THREAD_SZ/WAITQUEUE_OFFSET.
5. On success: remount /system rw, drop su binary → PERMANENT root.

### Note on kernel address range
- Config says VMSPLIT_3G PAGE_OFFSET=0xC0000000, CONFIG_HIGHMEM=y. Leaked "kernel" addrs appeared 0x80000000-0xBFFFFFFF but those were actually USER HEAP (my leak was broken — reading past dummy into my malloc arena). Kernel IS at 0xC0000000+ (dmesg showed vmalloc 0xe2xxxxxx). isKernelPointer 0xc0008000-0xf0000000 is correct.

## SESSION 4 — CORRECT OFFSETS FOUND (exploit nearly working)

### ✅ FOUND THE BUG: binder_error = 16 bytes, not 8
`struct binder_error { struct binder_work work; uint32_t cmd; }` where binder_work = {list_head(8) + enum(4)} = 12 bytes. So binder_error = 16 bytes.
Correct layout (ARM32, from binder_mtk318.c AKB0N 3.18.117, matches Sonim 3.18.71):
- proc@0x00, rb_node@0x04(12), waiting_thread_node@0x10(8), pid@0x18, looper@0x1C,
  looper_need_return@0x20(1,pad), transaction_stack@0x24, todo@0x28(8),
  return_error@0x30(16), reply_error@0x40(16), **wait@0x50(12)**,
  stats@0x5C(0xCC=204), tmp_ref@0x128, is_dead@0x12C, **task@0x130**, sizeof=**0x134**(308).

**FINAL CORRECT CONSTANTS: BINDER_THREAD_SZ=0x134, WAITQUEUE_OFFSET=0x50, IOVEC_ARRAY_SZ=38, IOVEC_INDX_FOR_WQ=10, task@0x130.**

### Progress + remaining 1-byte fix
- With 0x134/0x50, le1_root leak now returns task=0x00dbd3e1 (non-zero!) — a task pointer read **1 byte early** (preUafBytes=1 not subtracted).
- **FIXED in le1_root.c**: `taskOff = (BINDER_THREAD_SZ-4) - (WAITQUEUE_OFFSET+4) - preUafBytes` = 0x130 - 0x54 - 1 = **0xDB**.
- (Before fix taskOff=0xDC → read 0x00dbd3e1 = misaligned. After fix → 0xDB → should read the real 0xc??????? task pointer.)

### NEXT (device online): just re-run
1. `cat le1_root.c | ssh ... 'cat > le1_root.c'` then `clang -O2 -o le1_root le1_root.c && ./le1_root`
2. If task pointer now leaks (0xc0...), phase1 succeeds → phase2 → addr_limit → root.
3. If task still wrong, dump leak via leak_debug2 (change minimumLeak to 0x200) to see actual layout.

### Files
- ~/le1-root/exploit/le1_root.c  (adapted exploit, offsets FIXED, taskOff FIXED)
- ~/le1-root/exploit/leak_debug2.c (dump leaked kernel data)
- ~/le1-root/poc/root-sonim-xp3800/su.c (reference, full ARM32 exploit)
- ~/le1-root/poc/root-sonim-xp3800/docs/arm32-port.md (technique docs)

## SESSION 5 — firmware hunt for exact gwi_dnyb image (result: NOT published)

### Conclusion on finding the exact firmware online
- Bing/DDG/Google: **zero results** for "gwi_dnyb" — this exact build is NOT published.
- 4PDA threads (977360, 1080165) are anti-bot blocked (r.jina.ai returns "Just a moment").
- XDA Alidesheng thread (4033175) mentions firmware exists on 4PDA but no direct links extractable.
- The k80_bsp firmware I have (Oct 2025) ≠ our build (Aug 2020). Symbol counts differ (38262 vs 41312).

### Prebuilt kernel images found (agent f2)
- `Mysteryagr/Mystery-Kernel-3.18` release zImage-dtb (3.18.44, Apr 2017) — downloaded to
  ~/le1-root/kernels/{zImage-dtb, mystery.elf}. **BUT it has the OLD mainline binder**
  (disassembly of binder_get_thread shows wait at offset **0x2C**, no task field —
  __init_waitqueue_head called with r0 = thread+44). NOT representative of our device
  (Android 8.1 backported binder). Symbol count 50315 ≠ our 41312.

### Offset verification status
- Our binder_thread layout (wait=0x50, task=0x130, size=0x134) rests on:
  1. binder_error = binder_work(12) + cmd(4) = 16 bytes (from AKB0N 3.18.117 source, verbatim struct).
  2. Matches Sonim XP3800 (3.18.71) exactly — a real working exploit.
  3. Empirical: WAITQUEUE_OFFSET=0x40 gave all-zeros leak (no clobber redirect); 0x50 gave
     non-zero leak (0x00dbd3e1). Consistent with wait=0x50 being correct.
- Remaining ambiguity: 0x00dbd3e1 is not a clean kernel pointer. Could be misaligned task read
  (1-byte off due to preUafBytes) — the applied fix reads kern+0xDB. Needs one device run
  (or leak_debug2 dump) to confirm.

### Model note for agents
- herdr agents MUST use `--model "openrouter/deepseek/deepseek-v4-flash"` — the plain
  `deepseek-v4-flash` fails with 402 Insufficient Balance (OpenRouter key is the funded one).

## SESSION 6 — CVE-2020-0041 (binder OOB write) added as alternative path

Cloned `bluefrostsecurity/CVE-2020-0041` (official exploit, arm64/Pixel3/4.9 hardcoded)
into `poc/CVE-2020-0041/`. Full port plan: `poc/CVE-2020-0041/PORT.md`.

- CVE-2020-0041 = binder_transaction OOB write (bad bounds check, A-145988638, fixed 2020-03).
  Our patch 2018-10-05 -> vulnerable.
- Advantage vs our CVE-2019-2215: the BUG is not a race (no crash loops). Exploitation
  still uses sendmmsg heap-grooming (retry-safe, unlike 2215's kmalloc reclaim race).
- Port: (a) 32-bit binder struct sizes (computed in PORT.md), (b) 3.18 struct-file/
  task_struct/epitem offsets (dump on-device via our 2215 kernel R/W), (c) drop SELinux
  steps (already permissive), (d) drop KASLR steps (fixed base 0xC0008000).
