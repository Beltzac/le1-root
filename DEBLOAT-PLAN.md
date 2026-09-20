# LE1 — volume OSD restore + debloat plan (apply when online)

Created 2026-09-12. Read this before running anything. **APPLIED 2026-09-13**
(`post-root/le1-online-fix.sh`, 19 packages disabled, 2nd perf batch included —
see `STATUS.md`). This document is kept as the reference/rollback list.

## Goal
1. Bring back the **volume / brightness OSD** (lost because `com.wwc2.mainui` was disabled).
2. Remove the **telemetry / remote-update** apps, **with backups**, so they stop phoning home.
3. Keep the **user's home launcher** (Microsoft Launcher) and not let the vendor launcher steal it.

---

## Part A — restore the volume OSD (KEEP list)
Disabling `com.wwc2.mainui` ("MainUI") is what killed the volume bar. Re-enable it:

```sh
su -c "pm enable --user 0 com.wwc2.mainui"
su -c "killall com.wwc2.mainui"     # persistent process restarts
```

MainUI also owns: **brightness OSD, the physical source buttons** (NAV/MEDIA/BT/CAM/RADIO),
power/reboot menu, clock/GPS handling, float-view/skin framework. It is **load-bearing**.

### KEEP (never disable)
`com.wwc2.mainui`, `com.wwc2.main`, `com.android.systemui` (MtkSystemUI),
`com.android.settings` (MtkSettings), `com.android.inputmethod.latin`,
`com.android.providers.*`, `com.goodocom.gocsdk` (MCU serial), `com.ms89jk5c` (car info).

---

## Part B — home launcher: who steals it
- The vendor HOME app is **`com.wwc2.launcher`** (WYD_Launcher) — currently **disabled** (good).
- **`com.wwc2.main` (WMain)** manages it: it has `com.wwc2.main.launcher.LauncherLogic`
  (targets `com.wwc2.launcher` / `com.wwc2.launcher.ui.MainActivity`, and lists
  `com.android.launcher`/`launcher3`) and `ApkUtils.setEnable(...)` →
  `PackageManager.setComponentEnabledSetting(...)`, i.e. it *can* enable/disable launcher components.
- `com.wwc2.mainui` does **not** force a home — when asked to open the launcher it fires a
  generic `MAIN + CATEGORY_HOME` intent (goes to *your* chosen home).
- `com.wwc2.mainui` `InstallsyncTask` runs `pm install -r <apk>` — a reinstall path that could
  refresh a bundled launcher.

**Rule:** keep `com.wwc2.launcher` disabled. If home flips again, catch it with:

```sh
su -c "dumpsys package com.wwc2.launcher | grep -m1 enabled="
su -c "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1"
```

---

## Part C — remove the bad set (with backup)
Targets (all OEM-signed, system-UID, autostart, remote/telemetry):

| Package | Label | Why |
|---|---|---|
| `com.abupdate.fota_demo_iot` | FOTA Update | ADUPS — `iotapi.adups.com`; can push firmware; `RECOVERY`; exposed `OtaAidlService` |
| `com.wwc2.networks` | "Android GPS Service" | JPush push + Qiniu upload; IMEI/contacts/installed-apps; **silent APK install**; obfuscated |
| `com.wwc2.market` | "Tools" | disguised store; `INSTALL_PACKAGES`; cleartext HTTP mall at `119.23.61.10:8081` |
| `com.mediatek.mtklogger` | MTKLogger | `READ_LOGS` + `READ_FRAME_BUFFER` (screen capture) |
| `com.wwc2.systemupdate_apk` | System_update | OTA updater; `MOUNT_UNMOUNT_FILESYSTEMS` |
| `com.wwc2.mcuupdate` | MCU Update | MCU firmware updater |
| `com.wwc2.voice_assistant` | Voice Assistant | always-on mic/system proc (AISpeech AIOS) |
| `com.mediatek.ygps` | YGPS | MTK GPS factory test app |
| `com.wwc2.panoramic` | WPanoramic | 360° surround-view camera app (only if no 360-cam hardware) |
| `com.google.android.apps.maps` | Maps | 106 MB resident, unused in-car |

### Perf batch (2nd wave, applied 2026-09-13)
| Package | Note |
|---|---|
| `com.google.android.partnersetup` | Play setup, background |
| `com.google.android.onetimeinitializer` | one-shot, useless after |
| `com.google.android.configupdater` | background |
| `com.google.android.backuptransport` | background |
| `com.google.android.ext.services` | GMS support svc |
| `jp.co.omronsoft.openwnn` | unused IME (LatinIME is default) |
| `com.android.gallery3d` | gallery (FileManager covers) |
| `com.mediatek.engineermode` | MTK factory test tool |
| `com.google.android.apps.nbu.files` | Files by Google (unused) |

**Note:** `com.wwc2.panoramic` (WPanoramic) is the **360° surround-view camera app**
(bird's-eye stitcher), controlled by `WMain`'s `PanoramicManager` (`sendTouchXY`,
`sendCMDToPanoramic`, MCU). Disabling it removes the surround/parking view — restore it if
you have 360 cameras and want it back.

**Method (reversible, matches the repo's own POST-ROOT-PLAN):**
1. Back up each APK to `/sdcard/le1-app-backup/` (and copy of originals already local at `~/le1-apks/`).
2. `pm disable-user --user 0 <pkg>` + `am force-stop <pkg>`.
3. (optional, later) `--purge` renames the `/system` APK to `.bak` — a true removal. Needs a second OK.

To run: `bash ~/le1-root/wait-and-apply.sh` (waits for the unit, then runs
`post-root/le1-online-fix.sh` on-device as root).

Restore any time: `su -c "sh /data/data/com.termux/files/home/.le1/le1-restore.sh"`.

---

## Verification (after apply)
```sh
su -c "for p in com.abupdate.fota_demo_iot com.wwc2.networks com.wwc2.market com.mediatek.mtklogger; do echo \"\$p=\$(pm list packages -d | grep -c \$p)\"; done"
su -c "getprop init.svc.sudaemon; su -c id | head -1"     # root still sticky
# press a volume button -> OSD should appear; then:
su -c "pm list packages -d | grep mainui"                  # must be empty
```

## Risk / rollback
- Disabling is reversible with `pm enable`. APKs are backed up first.
- Disabling `com.abupdate.*` / `com.wwc2.market` / `com.wwc2.systemupdate_apk` **may stop vendor OTA**.
  That is intended; re-enable to restore.
- Do **not** touch `com.wwc2.main` / `mainui` / systemui / settings.