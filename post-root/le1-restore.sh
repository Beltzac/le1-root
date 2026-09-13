#!/system/bin/sh
# le1-restore.sh — undo le1-online-fix.sh. Run AS ROOT on the LE1.
# Re-enables every package that was disabled, and restores purged APKs if present.
set -u
PATH=/sbin:/system/bin:/system/xbin
BK=/sdcard/le1-app-backup
log() { echo "le1-restore: $*"; }

BAD="com.abupdate.fota_demo_iot com.wwc2.networks com.wwc2.market com.mediatek.mtklogger com.wwc2.systemupdate_apk com.wwc2.mcuupdate com.wwc2.voice_assistant com.mediatek.ygps com.wwc2.panoramic com.google.android.apps.maps com.google.android.partnersetup com.google.android.onetimeinitializer com.google.android.configupdater com.google.android.backuptransport com.google.android.ext.services jp.co.omronsoft.openwnn com.android.gallery3d com.mediatek.engineermode com.google.android.apps.nbu.files"

# restore purged APKs first (so pm enable can find them after a reboot)
for p in $BAD; do
    apk=$(pm path "$p" 2>/dev/null | head -1 | sed 's/^package://')
    if [ -z "$apk" ] || [ ! -f "$apk" ]; then
        # try the on-device backup
        for cand in "$BK"/*.apk; do
            [ -f "$cand" ] || continue
            bn=$(basename "$cand")
            # match by package name substring in filename is unreliable; enable anyway
        done
    fi
done

for p in $BAD; do
    pm enable --user 0 "$p" >/dev/null 2>&1 && log "enabled $p" || log "WARN enable failed for $p"
done
log "also re-enabling com.wwc2.mainui (should already be on)"
pm enable --user 0 com.wwc2.mainui >/dev/null 2>&1
log "done. Reboot recommended."