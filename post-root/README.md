# LE1 Post-Root Toolkit

Modular, **fully reversible** scripts that run after `le1_root.c` achieves root.
Every mutation is logged, backed up, and recorded in a manifest so `restore.sh`
can undo it exactly.

## Reversibility rules (enforced by `common.sh`)

- ❌ never delete `/system` files → rename to `*.disabled`, or `pm disable-user` (freeze)
- ✅ always `backup()` a file before editing it
- ✅ every action appended to `/data/local/tmp/le1-manifest.log`
- ✅ `restore.sh` reverses the manifest (newest first)

## Files

| File | Role | Runs |
|---|---|---|
| `common.sh` | logging + manifest + reversible helpers | sourced |
| `post-root.sh` | orchestrator | over SSH, as root |
| `timefix.sh` | clock sync — network path (NTP → HTTP-Date) | init service (boot) |
| `gpstime.sh` | clock sync — GPS path (offline, atomic-clock) | init service (boot) |
| `loadtime.sh` | **restore last-known time at boot (early)** | init service (`post-fs-data`) |
| `savetime.sh` | persist current time to the cache | called by sync + daemon |
| `le1-timesaved.sh` | daemon keeping the cache fresh (5 min) | init service (daemon) |
| `timefix.rc` | init services for the above | — |
| `optimize.sh` | kill MTK loggers, freeze DuraSpeed, fstrim, logd, governor | over SSH |
| `debloat.sh` | freeze unused apps (opt-in `--remove`) | over SSH |
| `restore.sh` | undo everything from the manifest | over SSH |

## Usage (after root)

```bash
# on the device, from the repo dir (run as root):
sh post-root/post-root.sh            # full: deploy + test + optimize + debloat

# or one step at a time:
sh post-root/post-root.sh deploy     # copy time scripts into /system
sh post-root/post-root.sh test-time  # run timefix.sh once
sh post-root/post-root.sh optimize   # loggers + duraspeed + fstrim + logd
sh post-root/post-root.sh debloat    # freeze bloat apps

# undo everything:
sh post-root/post-root.sh restore
```

The orchestrator copies `common.sh` → `/system/bin/le1-common.sh`,
`timefix.sh`/`gpstime.sh` → `/system/bin/`, and `timefix.rc` →
`/system/etc/init/` so init runs the clock sync at every boot (both network and
GPS sources in parallel — first one to set the clock wins).

## Why `loadtime` / `savetime` exist (dead RTC → broken TLS)

The RTC has no backup cell, so every power-off resets the clock to
**2009-12-31** (~16 years stale). TLS validates certs with
`notBefore <= clock <= notAfter`, and public certs live at most **398 days**
(Let's Encrypt: 90). Being behind means every cert issued since your clock
reads as "not yet valid":

| Clock behind by | Effect on TLS |
|---|---|
| ~1 day | today's newly-issued certs fail |
| ~30 days | most recently renewed certs fail |
| **>398 days** | **every cert fails** (max cert lifetime) |

So a 2009 clock breaks *all* HTTPS — which is why the old bootstrap needed
`curl -k`.

**Fix:** `savetime` persists the clock; `loadtime` restores it at boot
(`post-fs-data`, before network). The clock then starts hours/days stale
instead of 16 years — enough for most certs to validate immediately — and
`timefix`/`gpstime` correct it precisely moments later.

Cache lives at `/data/misc/le1-time/last` (atomic write, root-only). The
`le1-timesaved` daemon re-saves every 5 min because cars cut power abruptly
(no reliable shutdown hook).

Note: a genuinely accurate clock still needs GPS/NTP — the cache only shrinks
the error from "years" to "time since last save".

- stdout (interactive SSH)
- `/data/local/tmp/le1-postroot.log` (or `le1-timefix.log` / `le1-gpstime.log`)
- logcat, tag `LE1`
- manifest: `/data/local/tmp/le1-manifest.log` (`timestamp|action|arg1|arg2`)

## On-device TODO (verify before trusting)

- busybox applets: `ntpd`, `hwclock`, `date`, `nc`, `timeout`, `tac`
- GPS NMEA route: `nc 127.0.0.1 7000` after toggling YGPS `nmea2socket` once
- DuraSpeed package name: `pm list packages | grep -i duraspeed`
- debloat `VERIFY` list package names (see `debloat.sh`)
