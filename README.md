# LE1 Root — CVE-2019-2215 exploit research (MT6580 / Android 8.1)

Root exploit development for the **LE1 car head unit** (LeTV-branded `gwi_dnyb`, MediaTek
MT6580M, Android 8.1.0, Linux kernel 3.18.79 armv7l 32-bit).

## Status: ready to run — offsets verified, deterministic UAF timing, full logging

The full ARM32 CVE-2019-2215 root chain is implemented in `exploit/le1_root.c`.
Device offsets are derived and verified (`taskOff=0xDB`, `stack@0x004`, `addr_limit@0x008`
confirmed against the actual kernel source). The 1-byte leak bug is fixed. The UAF
timing now uses a **deterministic FIONREAD pipe handshake** (no fixed sleeps) so it can't
fire too early and panic the kernel / trip the MTK watchdog. Every phase is logged.
One device run should complete phase1 → root.

## Quick start (when device is online)

**One-liner (recommended):** `./deploy.sh` — stages the su daemon + exploit, compiles on-device, runs, tails the log.

**Manual:**
```bash
# device: Le1 on Tailscale, SSH u0_a50@100.124.251.81 -p 8022

# 1. stage the ARM32 su daemon (the exploit copies ~/sudaemon -> /system/bin/sudaemon)
scp -P 8022 poc/root-sonim-xp3800/assets/su u0_a50@100.124.251.81:sudaemon

# 2. stage + compile + run the exploit
cat exploit/le1_root.c | ssh u0_a50@100.124.251.81 -p 8022 'cat > le1_root.c'
ssh u0_a50@100.124.251.81 -p 8022 'clang -O2 -o le1_root le1_root.c && ./le1_root > ~/le1_root.log 2>&1'
# NOTE: log to ~/ (Termux home) — /data/local/tmp is 0771 shell:shell, u0_a50 cannot
# write it pre-root. After root the exploit can copy the log there itself.
# on success: /system/bin/sudaemon + /system/xbin/su installed; root survives reboots via init service
```

**Prerequisite — `~/sudaemon`:** the exploit's post-root step reads `$HOME/sudaemon`
and installs it as the persistent root daemon (`/system/bin/sudaemon`, started by
init `user root`) plus the `/system/xbin/su` client. Use the prebuilt ARM32 su from
`poc/root-sonim-xp3800/assets/su` (bionic-linked libc+libdl, verified 32-bit ARM),
or compile `reference/su_sonim.c` on-device. It MUST be at `~/sudaemon` on the device
BEFORE running `le1_root.c` (daemon arg is `--daemon`).

## Device facts (verified)

| Property | Value |
|---|---|
| SoC | MediaTek MT6580M (ARMv7, 32-bit) |
| OS / kernel | Android 8.1.0 / 3.18.79 #8 (Aug 2020), armv7l |
| Build | `full_gwi_dnyb` (Le1 / gwi_dnyb), incremental 1598252866 |
| Security patch | 2018-10-05 (CVE-2019-2215 unpatched) |
| SELinux | Permissive |
| KASLR | none (kernel base fixed) |
| dm-verity | not active (can remount /system rw once root) |
| adbd | production build (no `adb root`) |
| Kernel lowmem | 0xC0000000+ (VMSPLIT_3G, p2v offset 0x40000000) |
| kallsyms | 41312 symbols, but kptr_restrict=2 (addresses zeroed) |

## Correct binder_thread offsets (ARM32) — the key finding

`struct binder_error { struct binder_work work; uint32_t cmd; }` where
`binder_work = {list_head(8) + enum(4)} = 12 bytes` → **binder_error = 16 bytes** (not 8).

```
struct binder_thread {                       // sizeof = 0x134 (308)
    struct binder_proc *proc;                // 0x00
    struct rb_node rb_node;                  // 0x04 (12)
    struct list_head waiting_thread_node;    // 0x10 (8)
    int pid;                                 // 0x18
    int looper;                              // 0x1C
    bool looper_need_return;                 // 0x20 (1,pad)
    struct binder_transaction *transaction_stack; // 0x24
    struct list_head todo;                   // 0x28 (8)
    struct binder_error return_error;        // 0x30 (16)
    struct binder_error reply_error;         // 0x40 (16)
    wait_queue_head_t wait;                  // 0x50 (12)  <-- WAITQUEUE_OFFSET
    struct binder_stats stats;               // 0x5C (0xCC=204)
    atomic_t tmp_ref;                        // 0x128
    bool is_dead;                            // 0x12C
    struct task_struct *task;                // 0x130  <-- survives iovec reclaim
};
```

**Constants:** `BINDER_THREAD_SZ=0x134`, `WAITQUEUE_OFFSET=0x50`,
`IOVEC_ARRAY_SZ=38`, `IOVEC_INDX_FOR_WQ=10`, task@0x130.

Other offsets (architecture-standard, 3.18 ARM32):
- `task_struct->stack = 0x004` (→ thread_info)
- `thread_info->addr_limit = 0x008`
- cred: uid@0x004, securebits@0x024, caps@0x028/0x030/0x038/0x040/0x048

## Exploit technique (ARM32-specific)

Based on **flipphoneguy/root-sonim-xp3800** (reference in `reference/`). Key ARM32 gotchas:
1. **Spinlock on iov_base**: on 32-bit, wait.lock lands on `iov[10].iov_base` (a pointer).
   The UAF writes 0x10001 there → iov_iter derefs 0x10001 → panic.
   **Fix**: NULL guard `iov[WQ] = {NULL, 0}` (iov_iter skips it).
2. **Timing**: UAF must fire after iov_iter passes iov[WQ] but while on iov[WQ+1].
   **Fix**: deterministic `wait_pipe_bytes()` handshake — poll FIONREAD until the pipe
   proves the parent is parked at iov[11] (empty for readv/clobber, full for writev/leak),
   settle 20ms, re-confirm, *then* fire `EPOLL_CTL_DEL`. Timeout → abort safely (no DEL).
3. **Two-phase leak**: task_struct ptr survives in binder_thread's last 4 bytes (0x130).
   Phase1 leaks it; phase2 uses a secondary clobber to read task_struct->stack.
4. **Clobber (readv)**: pipe-blocking (deterministic) — the helper fills the pipe, waits
   for the parent to drain it and park at iov[11], fires the UAF, then delivers a 28-byte
   crafted iovec + payload + canary. No busy-wait race, no signal pipe.

Chain: leak task_struct → read stack (thread_info) → clobber addr_limit=0xFFFFFFFF →
arbitrary R/W via pipe → find cred (scan task_struct for uid==myuid) → zero cred + set caps →
root shell.

## Files

- `exploit/le1_root.c` — the adapted exploit (offsets fixed, taskOff fixed, deterministic
  handshake + logging, ready to run)
- `deploy.sh` — one-shot staging + compile + run over Tailscale SSH
- `backup-emmc.sh` — full/critical eMMC backup pulled to the Pi disk (run as the
  FIRST root command, before any debloat)
- `post-root/` — modular, **reversible** post-root scripts (clock fix, GPS time,
  optimize, debloat, restore) with manifest-based undo
- `poc/root-sonim-xp3800/assets/su` — prebuilt ARM32 su daemon (the `~/sudaemon` prerequisite)
- `exploit/leak_debug2.c` — dumps raw leaked kernel data (for offset tuning)
- `exploit/leak_debug.c`, `leak_test.c`, `dump_leak.c`, `brute_leak.c` — earlier debug tools
- `reference/su_sonim.c` — full ARM32 reference exploit (Sonim XP3800)
- `reference/arm32-port.md` — ARM32 technique documentation
- `reference/CVE-2019-2215.md` — vulnerability + escalation background
- `reference/binder_mtk318.c` — Android 8.1 binder source (offset source of truth)
- `reference/binder_318.c` — mainline 3.18 binder (older, no task field)
- `reference/sched_318.h` — task_struct layout source (stack@0x4)
- `RESEARCH.md` — full session log + all findings
- `STATUS.md` — earlier session log

## Next steps

1. Re-run `le1_root.c` on device — log to ~/ (NOT /data/local/tmp pre-root):
   `./le1_root > ~/le1_root.log 2>&1`
2. Read the log breadcrumb (`[handshake] PARKED`, `firing UAF`, `UAF fired`, `readv returned`)
   — the last line before any freeze/reboot pinpoints the failing stage.
3. If phase1 leaks a non-kernel pointer → run `leak_debug2.c` (set `minimumLeak=0x200`).
4. On root: the exploit remounts /system itself (auto-detects device, no hardcoded
   mmcblk0pXX) → installs `/system/bin/sudaemon` + `/system/xbin/su` (0755 daemon
   model, NOT setuid 6755) → root survives reboots via init service.
