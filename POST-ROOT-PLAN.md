# LE1 Post-Root Plan — Clock Fix & Optimization

Written before root was achieved; execute in order once `le1_root` succeeds and `id` returns uid=0.

---

## 0. Root cause: why the clock resets

Evidence from the device:
- Factory-flash-era files show `2009-12-31 22:00` (classic MTK dead-RTC default).
- Files created during runtime sessions get correct timestamps (the Termux `time-watchdog`
  fixes system time *during runtime* via HTTPS Date headers with `curl -k`).
- Only root can call `settimeofday()` — Termux (u0_a50) and adb shell (uid 2000) both
  get "only root user can change date/time".

**Conclusion:** the RTC has no battery/supercap backup (or dead cell). Every full power-off
(car ACC off) resets RTC to a default date. At boot the clock is wrong until something syncs it.
Wrong boot clock ⇒ TLS cert validation fails (certs "not yet valid") ⇒ why the time bootstrap
needs `curl -k`.

---

## 1. Clock fix (in order of preference)

### 1a. Android-native auto-time (try first — 5 min, no custom scripts)
```bash
su
settings put global auto_time 1
settings put global ntp_server pool.ntp.org
```
Android's own NTP client is UDP-based → works even with a wrong clock (no TLS).
If the vendor build hasn't crippled it, this alone fixes it: boot wrong → network up → synced.

### 1b. Custom init service (robust fix, independent of Termux)
Requires `/system` remounted rw.

`/system/bin/timefix.sh` (chmod 755, chown root:root):
```sh
#!/system/bin/sh
# wait for network (max ~3 min)
i=0
until ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 90 ] && break; sleep 2
done
# NTP sync (busybox is at /system/bin/busybox — verify applets first)
/system/bin/busybox ntpd -q -p pool.ntp.org
# fallback: HTTP Date header if NTP blocked
[ $? -ne 0 ] && {
  D=$(/system/bin/curl -k -sI https://www.google.com | grep -i '^date:' | cut -d' ' -f2-)
  [ -n "$D" ] && /system/bin/busybox date -s "$D"
}
# persist to RTC (helps soft reboots; won't survive full power-off without backup cell)
/system/bin/busybox hwclock -w 2>/dev/null
```

`/system/etc/init/timefix.rc` (Android 8.1 init imports /system/etc/init/*.rc):
```
service timefix /system/bin/timefix.sh
    user root
    oneshot
    disabled

on property:sys.boot_completed=1
    start timefix
```
Runs at native boot as root — independent of Termux:Boot (which is unreliable on this unit:
SSH keeps dying, suggesting Termux autostart doesn't always fire).

### 1c. Update the existing Termux `time-watchdog`
Change it to apply time via `su` instead of only logging:
```bash
su -c "date -u -s @<epoch>"        # or busybox date -s
su -c "busybox ntpd -q -p pool.ntp.org"
```

### 1d. RTC reality check (do once rooted)
```bash
ls -la /dev/rtc* /proc/driver/rtc 2>&1
busybox hwclock -r 2>&1
# set time correctly, then: busybox hwclock -w; power-cycle; hwclock -r again
# → determines whether RTC persists full power-off (likely not — hardware limitation)
```
Note: `hwclock -w` persists across *soft* reboots. If no backup cell exists, the boot-time
sync (1b) is the real fix; RTC write is just a bonus.

### Verify busybox applets before writing scripts
```bash
/system/bin/busybox --list | grep -E "^(ntpd|hwclock|date|ping)$"
```
(If `ntpd` is missing, use the HTTP-Date fallback in the script.)

---

## 2. Optimization (priority order, stability-first)

| # | Optimization | How | Impact |
|---|---|---|---|
| 1 | Kill MTK logging daemons | rename/disable `.rc` entries in `/system/etc/init/` for: mtklogger, mobile_log_d, emdlogger1/5, aee_aed, atcid | Big — frees CPU/RAM/IO constantly |
| 2 | Install permanent su | static ARM32 su → `/system/xbin/su`, chmod 6755, chown root:root | No exploit re-runs per boot |
| 3 | fstrim eMMC | `vdc fstrim dotrim` (also schedule weekly via timefix.sh) | Prevents storage slowdown |
| 4 | Shrink logd buffers | `setprop persist.log.size 256k` (+ ro.logd.size in build.prop) | RAM savings |
| 5 | CPU governor check | `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`; hotplug→interactive if laggy | Responsiveness |
| 6 | zRAM/swap check | `cat /proc/swaps`; inspect `/fstab.enableswap` | 1GB RAM device |
| 7 | Vendor telemetry/update checkers | `pm list packages -s`, freeze via `pm disable-user` | Less background noise |

### Debloat candidate list (from init .rc analysis of this platform)
Services safe to disable (pure logging/diagnostic):
`mtklogger`, `mobile_log_d`, `emdlogger1`, `emdlogger5`, `mdlogger`, `aee_aed`, `aee_aedv`,
`atcid`, `netdiag`, `cmddumper`, `thermalindicator`(careful), `bootlogoupdater`.
Do NOT touch: anything MCU/audio/thermal-sensor related (`jbset`, `mtktz`, `thermal_manager`,
McuCodecService, audio HALs).

### Method for disabling an init service without deleting files
```bash
mount -o rw,remount /system
cd /system/etc/init
mv atcid.rc atcid.rc.disabled          # rename = easily reversible
mount -o ro,remount /system
reboot
```

---

## 3. Deliberate avoid-list (car-unit stability)

- **jbset / /custom partition flags** — MCU (CW32F030) config; car CAN bus integration.
- **Thermal settings (mtktz, thermal_manager)** — cooked eMMC risk in a hot car.
- **Audio HAL / McuCodecService** — reverse camera + amp routing depend on it.
- **ro.adb.secure=0 / build.prop auth changes** — network ADB without auth = exposure on WiFi.
- **Aggressive debloat of anything unclear** — head unit stability > everything.

---

## 4. Execution sequence after root

```
1. id  (confirm uid=0)
2. mount -o rw,remount /system
3. install /system/xbin/su (chmod 6755)          ← permanent root
4. clock fix (try 1a → 1b if needed)
5. mount -o ro,remount /system
6. reboot test → verify: su works, clock correct after boot
7. debloat step 1 (loggers) → reboot test
8. fstrim + logd + governor → reboot test
```
One change per reboot test. Keep `/system` ro except during edits.

---

## 5. Safety net

- Full SP-Flash-Tool firmware dump + scatter file already on hand (`~/rootkit/`,
  `Firmware for SPFT/`) — bad `/system` edits are recoverable via hardware flash path.
- Pre-root: `tar` backup of any `/system` file before modifying it.
- `/vendor/protect_f`, `/vendor/protect_s`, `/vendor/nvdata` are rw but nosuid/nodev —
  not usable for persistence; `/system` + `/data` are the only persistence targets.

---

## 6. Open items to verify on-device (once rooted)

- [ ] busybox applets: ntpd / hwclock / date present?
- [ ] `/proc/driver/rtc` exists? Does RTC hold time across full power-off?
- [ ] Does `settings put global auto_time 1` survive reboot & actually sync?
- [ ] Android 8.1 toybox `date` supports `-s`? (fallback: busybox date)
- [ ] Which MTK logger daemons are actually running & consuming resources? (`top`)
- [ ] CPU governor currently active? Any thermal throttling in normal car use?

---

## 7. App management (from /system/app, /system/priv-app, /system/preinstall_apks analysis)

Source: extracted `system.img` (k80_bsp Oct-2025 — app set is representative of this platform;
verify live list with `pm list packages -s` / `-3` / `-d` before acting).

### Inventory (78 system apps + ~45 priv-apps + 1 preinstalled APK)

**Preinstalled vendor APK (in /system/preinstall_apks):**
- `Auto_V4_5.5.5.600402_C04010001307_WIFI.apk` — vendor car app. Check if user-facing;
  if unused, remove APK + verify no init service depends on it.

**Vendor/car-specific apps in /system/app (review each):**
- `HiSight_sig_nodex`, `HiViewLite_sig`, `HwDMSDPDevice_sig`, `HwNearbyCar_sig` — Huawei
  HiSight/car cast stack. If the unit's mirror-link isn't used → removable.
- `TXZCore`, `tasvoice` — voice assistant (科大讯飞/TXZ 语音). Disable if voice control unused.
- `SogoInput` (搜狗输入法) — third-party Chinese IME. Replace with MtkLatinIME or keep.
- `quickpic_4.5.2` — third-party gallery (old, has known CVEs). Remove if gallery unused.
- `vehicleinfo-debug`, `wifiap-debug` — DEBUG builds of core vehicle/WiFi-AP apps!
  (build flavor is user/debug mix). Verify what registers them; likely duplicates.
- `reglink3rdsdkhost`, `reglink_settings`, `reglinkbluetoothservice`, `reglinkdata`,
  `reglinkota`, `reglink_services` (priv-app) — the vendor's framework ("reglink" = the
  kernel builder hostname too). **This is the vendor glue layer — likely boots critical
  services (BT/OTA/settings). Investigate before touching; reglinkota also handles updates.**
- `MDMConfig`, `MDMLSample` — MDM (Mobile Device Management) sample + config.
  `MDMLSample` is a SAMPLE → removable. `MDMConfig` verify.
- `CallRecorderService` (priv) — recording; personal choice.
- `FMRadio`, `DuraSpeed`, `HiSight` — DuraSpeed is vendor "keep alive" manager; it may
  AUTO-KILL Termux background services! If Termux watchdog/SSH dies at runtime,
  whitelist Termux in DuraSpeed or disable it.

**Safe AOSP/MTK cleanup (standard debloat):**
- `Chrome` (priv, old version on 8.1 — security risk if unused), `Protips`, `ExactCalculator`,
  `SoundRecorder`, `MtkGallery2`, `OpenWnn`, `Stk`/`Stk1` (SIM toolkit, no SIM), `Omacp`,
  `MtkMmsService`, `MtkSimProcessor`, `MtkTeleService`+`MtkTelecom` (unit likely has no
  cellular modem use — VERIFY, MT6580 here may be WiFi-only variant), `Phonesky` (Play Store
  if unused), `GooglePartnerSetup`, `GoogleOneTimeInitializer`, `ConfigUpdater`,
  `CtsShim*`, `HTMLViewer`, `BookmarkProvider`, `CalendarImporter`, `CompanionDeviceManager`,
  `PrintRecommendationService`, `SmartcardService`, `PacProcessor`, `Uicc1/2Terminal`.
- KEEP: `MtkLatinIME` (keyboard!), `SystemUI`, `systembar` (vendor system bar!), `MtkSettings`,
  `WebViewStub`+current WebView, `GoogleServicesFramework`+`GmsCore` if any GMS app used,
  `MtkNlp` (location), `FileManager` (useful), `GoogleTTS` (if TTS announcements used),
  `EngineerMode` (useful for diagnostics, hidden).

### Method (reversible, per app)
```bash
su
# freeze (preferred — no /system write, reversible):
pm disable-user --user 0 <package.name>
# or fully remove from /system (after backup):
mount -o rw,remount /system
mv /system/app/Protips /system/app/Protips.bak   # or tar backup first
mount -o ro,remount /system
```

### Watch-outs
- **DuraSpeed kills background apps** (vendor battery manager) — this likely explains any
  Termux sshd/agent dying while driving. Whitelist Termux or `pm disable-user com.duraspeed`.
- **reglink*** = vendor framework — do NOT batch-remove; map dependencies first
  (dumpsys activity services | grep reglink).
- **SystemUI vs systembar** — vendor uses BOTH; never remove either without testing.
- After `/system` app removal, wipe `/data/dalvik-cache` once (or it may keep stale odex).
- Verify each change with one reboot before the next (same rule as everything else).

### Live-list verification commands (once device online)
```bash
pm list packages -s | sort            # all system packages
pm list packages -3 | sort            # third-party (kingroot remnants etc.)
pm list packages -d                   # already disabled
pm path com.kingroot.kinguser         # kingroot remnant → remove (dead root mgr)
dumpsys package <pkg> | grep -A2 "Activity Resolver"   # find entry activity
```
Note: `com.kingroot.kinguser` (package) + `/sdcard/kinguserdown` are leftover from a failed
prior root attempt — remove after we have working su.
