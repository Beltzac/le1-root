# LE1 — Clock & NTP: wrong time, broken TLS (and the fix)

Status: **FIXED (2026-09-20)**. Written after the carhome app failed every
OpenRouter call with a certificate error.

---

## Symptom (what it looks like from the outside)

- The carhome agent never answers. `diag.log` shows:
  ```
  wire-agent ERROR Unacceptable certificate: CN=WE1, O=Google Trust Services, C=US
  ```
- It *looks* like DNS ("Unable to resolve host openrouter.ai") but it is not:
  names resolve, plain HTTP returns 200, raw TCP connects.
- The device clock reads **2007-02-04**, and the log line is timestamped `02-04`.

## Root cause — two separate things

1. **The RTC is dead.** `/proc/driver/rtc` reports `rtc_date: 2007-02-04`. There is
   no battery/supercap, so every full power-off boots with the MTK default clock.
2. **Android's built-in NTP does not work on this vendor ROM**, and worse:
   with `auto_time=1` the system **re-syncs the system clock from the dead RTC**
   about a minute after boot, so any manual correction is reverted.

**NTP itself is fine.** UDP 123 is open and servers answer (see evidence).

The failure chain: wrong clock -> every TLS handshake rejected
("certificate is not yet valid") -> HTTPS apps (carhome/OpenRouter, browsers,
weather) fail. It reads like a network/DNS problem but is purely the clock.

## Evidence (all reproduced on the device)

Clock and RTC:
```
$ date
Sun Feb  4 19:11:45 -02 2007
$ cat /proc/driver/rtc
rtc_time : 21:11:45   rtc_date : 2007-02-04   alrm_time : 17:30:58
$ settings get global auto_time
1
```

Android's NTP settings are ignored (auto_time=1 + ntp_server set, still 2007).

NTP works from the device (python3):
```
OK pool.ntp.org     -> 2026-09-20 22:19:16 (utc)
OK a.st1.ntp.br     -> 2026-09-20 22:19:17
OK time.google.com  -> 2026-09-20 22:19:17
OK 200.160.7.186    -> 2026-09-20 22:19:17
OK 162.159.200.1    -> 2026-09-20 22:19:17
```

TLS is what fails — not DNS (as u0_a50, correct clock):
```
$ ping google.com        -> 172.217.28.206            (DNS ok)
$ bash /dev/tcp/1.1.1.1/443  -> TCP_OK                (TCP ok)
$ curl http://neverssl.com   -> 200                   (plain HTTP ok)
$ curl https://example.com
  * SSL certificate OpenSSL verify result: certificate is not yet valid
    or the system clock is incorrect (9)
  curl: (60)
```

The carhome log proves the same, and the successful call after the fix:
```
02-04 19:12:52 wire-agent ERROR Unacceptable certificate: CN=WE1 ...   (clock 2007)
...
09-20 19:20:18 wire-agent SAY   ntp ok
09-20 19:20:18 wire-agent REPLY ntp ok                                  (fixed)
```

## What did NOT work

- `settings put global auto_time 1` + `settings put global ntp_server pool.ntp.org`
  — Android never applies it on this ROM.
- `date -u "@<epoch>"` via `su` — it sets the clock, but with `auto_time=1` it was
  reverted to 2007 within ~1 minute.

## The fix

1. **Turn Android time management off**: `auto_time=0` (and `auto_time_zone=0`).
   With no working NTP and a dead RTC, `auto_time=1` can only revert the clock.
   The supervisor (`boot/le1-boot.sh`, `enforce_autotime`) pins this every loop.
2. **Own NTP client** at `/data/le1-ntp/`:
   - `sync.py` — minimal NTP query (UDP 123), prints the UTC epoch; tries
     `a.st1.ntp.br, pool.ntp.org, time.google.com, 200.160.7.186, 162.159.200.1`.
   - `sync.sh` — runs it with Termux's `python3`, and if the clock is off by >3 s
     calls `date -u "@<epoch>"`; also refreshes the cache
     `/data/misc/le1-time/last`.
3. **Supervisor integration**: `clock_sync` runs at startup and at most every
   30 min (no-ops until a source answers, so the loop retries for free).
4. **GPS fallback (offline, no internet needed)**: the MTK GPS exposes NMEA on
   `127.0.0.1:7000` (mnld `nmea2socket`, on by default on this platform; YGPS can
   re-enable it).
   - `gps.py` — minimal NMEA reader (python3); takes the UTC epoch from the first
     valid `RMC` (status A, has date) or `ZDA` sentence.
   - `gpstime.sh` — sets the clock from it and refreshes the cache.
   `clock_sync` tries NTP first, then GPS (GPS rate-limited to every 5 min).

Boot order: `restore_clock` (cache, approximate) -> `clock_sync` (NTP, then GPS)
-> `enforce_autotime` (keep auto_time=0).

## Verification

```
$ sh /data/le1-ntp/sync.sh
clock ok (off 1s)
$ date
2026-09-20 19:20:08        # stable, no revert
$ am broadcast -n com.beltzac.carhome/.CommandReceiver \
    -a com.beltzac.carhome.PROMPT --es prompt "responda apenas: ntp ok"
$ tail files/diag.log
09-20 19:20:18 wire-agent SAY   ntp ok
09-20 19:20:18 wire-agent REPLY ntp ok    # OpenRouter call succeeded
```

## Gotchas / notes

- `date` on the device is toybox: **no `-s`, no `-D`**. Set with
  `date -u "@<epoch>"`.
- **Never derive the epoch from the device's own `date +%s` while the clock is
  wrong** — you will set it to 2007 again. Take the epoch from a sane host.
- Termux's python3 run as root needs
  `LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib:/system/lib`.
- The cached time lives at `/data/misc/le1-time/last`; `/data/misc/le1-time/boot.log`
  is the supervisor log.
- The RTC itself is unrepairable in software (no backup cell). If the RTC could be
  written (`hwclock -w`; toybox has no `hwclock`), soft reboots would keep the time,
  but full power-offs never will — hence the boot NTP sync.

## Files

- `ntp/sync.py`, `ntp/sync.sh` — the NTP client
- `ntp/gps.py`, `ntp/gpstime.sh` — the GPS (NMEA) clock fallback
- `boot/le1-boot.sh` — `clock_sync`, `restore_clock`, `enforce_autotime`
- `post-root/apply-autostart.sh` — installs `/data/le1-ntp/`
- `/data/le1-ntp/` on the device

> Status of the GPS layer: implemented 2026-09-20, **not yet tested on the device**
> (the unit was powered off when it landed). Next time it is on, deploy the files
> and run `/data/le1-ntp/gpstime.sh 20` to confirm the port-7000 NMEA stream yields
> a fix.

## Related

- `TAILSCALED-ROOT.md` — the same clock issue also broke root tailscaled's TLS.
- `POST-ROOT-PLAN.md` section 1 (clock fix) now points here.