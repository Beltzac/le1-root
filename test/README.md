# LE1 tests

Both run offline, no device needed.

| Test | What it proves | Requires |
|---|---|---|
| `bash test/test-boot.sh` | `boot/le1-boot.sh` supervisor logic: cached-clock restore, sudaemon start/supervise, `auto_time` + `ntp_server` enforcement, cache refresh, logging | POSIX sh + coreutils |
| `bash test/test-persist.sh` | VM integration: `post-root/persist.sh` installs the ramdisk hook, backs up the stock `install-recovery.sh`, writes the rc, and the `install-recovery.sh -> le1-boot.sh` boot chain actually starts the daemon + clock logic | proot + proot-distro + `proot-distro install alpine` |

`test-boot.sh` uses stub `date`/`settings`/`su`/`sudaemon` and overrides
`LE1_TIME_DIR`, `LE1_SU`, `LE1_SUDAEMON`, `LE1_SETTINGS`, `LE1_PATH`, `LE1_LOOP_SECS`.

`test-persist.sh` binds a fake `/system` and `/data` into an Alpine rootfs:
real scripts, stub kernel surface (`mount` always succeeds; `sudaemon`/`su`/
`settings` are markers). It cannot exercise the MTK init itself — see
`FIXES-2026-09-10.md` (the unit's static ARM `init` runs under `qemu-arm`, but
proot can't provide a writable `selinuxfs`, so Android PID1 boot can't complete
in-VM).
