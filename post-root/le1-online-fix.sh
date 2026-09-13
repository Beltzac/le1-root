#!/system/bin/sh
# le1-online-fix.sh — run AS ROOT on the LE1.
#   1) restores the volume/brightness OSD (re-enables MainUI)
#   2) backs up + disables the telemetry/remote-update apps
#
# Reversible: every app is backed up (APK) before being disabled.
# Usage:  sh le1-online-fix.sh [--purge]
#   --purge  ALSO rename the /system APK to .bak (true removal). Off by default.
set -u
PATH=/sbin:/system/bin:/system/xbin
BK=/sdcard/le1-app-backup
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

BAD="com.abupdate.fota_demo_iot com.wwc2.networks com.wwc2.market com.mediatek.mtklogger com.wwc2.systemupdate_apk com.wwc2.mcuupdate com.wwc2.voice_assistant com.mediatek.ygps com.wwc2.panoramic com.google.android.apps.maps com.google.android.partnersetup com.google.android.onetimeinitializer com.google.android.configupdater com.google.android.backuptransport com.google.android.ext.services jp.co.omronsoft.openwnn com.android.gallery3d com.mediatek.engineermode com.google.android.apps.nbu.files"

log() { echo "le1-fix: $*"; }
mkdir -p "$BK" 2>/dev/null

# --- Part A: restore the volume OSD ---------------------------------------
log "enabling com.wwc2.mainui (volume/brightness OSD)"
pm enable --user 0 com.wwc2.mainui >/dev/null 2>&1
am force-stop com.wwc2.mainui 2>/dev/null

# --- Part B: back up + disable the bad set --------------------------------
for p in $BAD; do
    apk=$(pm path "$p" 2>/dev/null | head -1 | sed 's/^package://')
    if [ -n "$apk" ] && [ -f "$apk" ]; then
        base="${p}.apk"
        if [ ! -f "$BK/$base" ]; then
            if cp "$apk" "$BK/$base" 2>/dev/null; then
                log "backed up $apk -> $BK/$base ($(stat -c%s "$BK/$base" 2>/dev/null) bytes)"
            else
                log "WARN could not back up $apk — SKIPPING disable of $p"
                continue
            fi
        else
            log "backup already present for $p"
        fi
    else
        log "WARN no apk path for $p — disabling anyway (path unknown)"
    fi

    pm disable-user --user 0 "$p" >/dev/null 2>&1 && log "disabled $p" || log "WARN disable failed for $p"
    am force-stop "$p" 2>/dev/null

    if [ "$PURGE" = 1 ] && [ -n "${apk:-}" ] && [ -f "$apk" ]; then
        if [ ! -f "$apk.bak" ]; then
            if mount -o remount,rw /system 2>/dev/null; then
                mv "$apk" "$apk.bak" 2>/dev/null && log "purged (renamed) $apk -> $apk.bak"
            else
                log "WARN /system remount failed — purge skipped for $p"
            fi
        fi
    fi
done

# --- report ---------------------------------------------------------------
log "--- result ---"
log "mainui disabled? $(pm list packages -d | grep -c 'com.wwc2.mainui') (want 0)"
for p in $BAD; do
    log "$p disabled? $(pm list packages -d | grep -c "$p") (want 1)"
done
log "root: $(/system/xbin/su -c id 2>/dev/null | head -1)"
log "done."