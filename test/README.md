# LE1 tests

All run offline, no device needed.

| Test | What it proves | Requires |
|---|---|---|
| `bash test/test-boot.sh` | `boot/le1-boot.sh` supervisor logic: cached-clock restore, sudaemon start, `auto_time` + `ntp_server` enforcement, cache refresh, logging | POSIX sh + coreutils |
| `bash test/test-persist.sh` | VM integration: `persist.sh` installs the **vendor** hook and leaves `install-recovery.sh` alone; boot chain starts sudaemon + clock; `--with-recovery-hook` backs up the stock script; `verify-boot.sh` verdict | proot + proot-distro + `proot-distro install alpine` |
| `bash test/test-toybox.sh` | **Device-accurate** applet/shell compatibility: extracts the unit's own `toybox`, `mksh` and bionic libs from `system.img` and runs the scripts under `qemu-arm` | qemu-user-arm + e2fsprogs + `system.img` |

`test-boot.sh` uses stub `date`/`settings`/`su`/`sudaemon` and overrides
`LE1_TIME_DIR`, `LE1_SU`, `LE1_SUDAEMON`, `LE1_SETTINGS`, `LE1_PATH`, `LE1_LOOP_SECS`.

`test-persist.sh` binds a fake `/system` and `/vendor` into an Alpine rootfs
(busybox). Fast, but busybox is *not* what the device runs.

`test-toybox.sh` is the one that matters for on-device correctness. It builds
per-applet wrappers around the extracted ARM `toybox`, `mksh -n`-parses every
script with the device shell, and asserts the critical semantic:

```
toybox  date -u @EPOCH  -> SETS the clock (EPERM as a user)
busybox date -u @EPOCH  -> prints the date, exit 0
```

If that ever flips, the clock restore becomes a silent no-op — this test catches
it. Cache: `${XDG_CACHE_HOME:-~/.cache}/le1-sysroot` (override with `LE1_SYSROOT=`).
`system.img` defaults to `~/rootkit/Firmware for SPFT/system.img` (override with `SYSTEM_IMG=`).

None of these can exercise the MTK init itself — see `FIXES-2026-09-10.md` (the
unit's `init` runs under `qemu-arm`, but proot can't provide a writable
`selinuxfs`, so Android PID1 boot can't complete in-VM). The one device-online
check is `/system/bin/verify-boot.sh` after a reboot.
