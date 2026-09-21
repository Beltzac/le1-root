# LE1 — Next steps / backlog

Created 2026-09-21 from the on-device review. Items marked DONE are only coded in
the repo; they still need deploying to the unit when it is online.

Context (review snapshot 2026-09-21): root OK, our OpenSSH sshd on 8022 wins at
boot, root tailscaled node `le1-1` online, clock chain (cache -> NTP -> GPS) works,
`/data` 41%, `/system` 89%, zram 740 MB, load ~11 (Spotify 50% CPU / 238 MB),
27 packages debloated.

---

## 1. Deploy + verify the ip-rule accumulation fix  [coded, needs deploy]

Problem: `ip rule 5200` had **4 copies** (`1006, 1010, 1016, wlan0`) because the
wrapper only deleted the rule for the interface detected at that moment. A stale
rule pointing at a table with no default breaks tailscaled's marked control path.

Fix (already in `post-root/apply-autostart.sh` + `ntp`... no, the tailscale
wrapper): delete **every** rule at pref 5200 first, then add one.

Deploy when online:
```bash
WAIT=0 bash ~/le1-root/apply-gps-clock.sh       # stages le1-boot.sh (unchanged) -- or:
ssh -p 8022 root@172.26.39.132 'sh /data/le1-tailscale/start.sh'
# then verify only ONE rule remains:
ssh -p 8022 root@172.26.39.132 'ip rule show | grep 5200'
```
Note: the wrapper on the device (`/data/le1-tailscale/start.sh`) must also be
updated. It is written by `apply-autostart.sh`; add a small step to
`apply-gps-clock.sh` (or run the full autostart apply) to refresh it.

---

## 2. Debloat GMS and related  [plan]

The unit does not use Play apps; GMS is the biggest remaining background consumer
(`com.google.android.gms.persistent` 162 MB + `com.google.android.gms` 110 MB).
Goal: stop the Google stack phoning home / holding RAM.

**Method (reversible):**
```bash
su -c 'pm disable-user --user 0 <pkg>; am force-stop <pkg>'
# revert: pm enable --user 0 <pkg>
```
Back up the APKs first (`/sdcard/le1-app-backup/`), one change per reboot test.

**Candidates (verify each is present first):**
| Package | Note |
|---|---|
| `com.google.android.gms` | core Play Services -- biggest win, biggest risk |
| `com.google.android.gms.persistent` | same apk, persistent proc |
| `com.google.android.gsf` | Services Framework |
| `com.android.vending` | Play Store |
| `com.google.android.googlequicksearchbox` | Google app (if present) |
| `com.google.android.syncadapters.contacts` / `.calendar` | sync |
| `com.google.android.feedback` | crash reports |
| `com.google.android.setupwizard` / `com.google.android.onetimeinitializer` | setup (latter already disabled) |
| `com.google.android.apps.turbo` / `com.google.android.gms.location.history` | battery/location history |

**KEEP (do not disable):**
- `com.google.android.webview` -- stays disabled now, but do **not** remove it;
  if any needed app uses WebView, this is what breaks. Consider re-enabling.
- `com.google.android.tts` -- currently disabled. Re-enable if the carhome voice
  path turns out to use Android TTS (its `SAY` works today, so verify first).
- `com.google.android.syncadapters` only if contacts/calendar are wanted.
- System/MTK/vendor: SystemUI, MtkSettings, MtkLatinIME, providers, MtkNlp,
  FileManager, Bluetooth, `com.wwc2.*` (except already-disabled ones).

**Risks:** disabling GMS core can make some apps crash or log loop; the network
validation (`VALIDATED`) does not depend on GMS, so connectivity is unaffected.
Test with one reboot after each batch; keep `/sdcard/le1-app-backup/` current.

**Tooling:** the existing `post-root/debloat.sh` + `wait-and-apply.sh` already do
backup + `pm disable-user`; extend its list rather than doing it by hand.

---

## 3. Remove the Microsoft launcher as HOME  [plan]

Step 1 -- identify it (device was offline when this was written):
```bash
ssh -p 8022 root@172.26.39.132 'pm list packages | grep -iE "microsoft|launcher"'
ssh -p 8022 root@172.26.39.132 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
ssh -p 8022 root@172.26.39.132 'pm query-activities -a android.intent.action.MAIN -c android.intent.category.HOME | grep packageName'
```
Step 2 -- pick the replacement HOME. carhome already registers
`com.beltzac.carhome/.Home` (category HOME). Options:
- (a) make **carhome** the default home (it is the point of the project), or
- (b) leave only the vendor launcher / none.

Step 3 -- set + disable (verify a HOME still resolves before disabling):
```bash
# must print a package first, or the unit ends up with no launcher:
su -c 'cmd package resolve-activity --brief -c android.intent.category.HOME'
su -c 'pm disable-user --user 0 <microsoft.launcher.pkg>'
# set carhome as home (Android 8.1):
su -c 'cmd package set-home-activity com.beltzac.carhome/.Home'   # if supported
# fallback if not supported: HOME picker appears on next Home press
```
**Guard:** never disable the current HOME without another HOME resolving, or the
device boots to a black/no-launcher state. `pm enable --user 0 <pkg>` reverts.

---

## 4. Keep YGPS active  [plan; was disabled in the debloat]

`com.mediatek.ygps` was disabled in the 2026-09-13 debloat, but it is the UI that
can toggle the GPS `nmea2socket` (our offline clock fallback depends on that
stream). Re-enable it and remove it from the debloat list:
```bash
su -c 'pm enable --user 0 com.mediatek.ygps'
su -c 'pm list packages -d | grep ygps'    # must be empty
```
Update `DEBLOAT-PLAN.md` so future applies do not disable it again.

---

## 5. Other pending items (from the review)

- **Reboot test** -- validates: our sshd wins 8022 from init, `flash_recovery`
  comes back (it is currently `stopped` because the supervisor was restarted by
  hand), `clock_sync` (NTP/GPS) runs, the ip rule is single.
- **Quiet the tailscaled log** -- `ensure_tailscale` logs `tailscaled (re)started`
  every 60 s even when nothing restarted. Log only on an actual start.
- **Spotify** -- `com.spotify.music` was 50% CPU / 238 MB. Decide: keep, update, or
  disable (`pm disable-user`), then re-check load.
- **`/system` 89%** -- 146 MB free. Review deleted/renamed `.bak` files and any
  unnecessary `/system` additions.
- **Tailscale identity** -- two nodes exist (`le1-1` root/online, `le1` app/offline
  14 h). Pick one; if root wins, retire the app's always-on VPN.
- **Cleanup** -- stale `/data/le1-ssh/{dropbearmulti,host_ed25519,sshd2_config}`
  from the dropbear attempt; the `~/.le1-*.sh` helper scripts.
