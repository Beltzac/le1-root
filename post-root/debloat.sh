#!/system/bin/sh
# debloat.sh — LE1 app cleanup. REVERSIBLE by default: freezes with
# `pm disable-user` (undo with restore.sh or `pm enable`).
# Full removal from /system is opt-in only:  debloat.sh --remove <pkg>
#
# TODO (verify live list first): pm list packages -s | sort
_self_dir="$(cd "$(dirname "$0")" && pwd)"
. "$_self_dir/common.sh"

banner "debloat: freeze unused apps (reversible)"

require_root

# ---- SAFE list: well-known AOSP/MTK bloat. Freeze-only, never delete. -------
# Each entry is "package|note". Unknown/missing packages are skipped gracefully.
SAFE_FREEZE="
com.android.chrome|old Chrome on 8.1 (security risk if unused)
com.android.protips|Protips tips widget
com.android.calculator2|ExactCalculator (replaceable)
com.android.soundrecorder|SoundRecorder
com.android.stk|SIM toolkit (no SIM)
com.android.stk2|SIM toolkit 2 (no SIM)
com.android.dreams.phototable|PhotoTable screensaver
com.android.bookmarkprovider|Bookmark provider
com.android.printspooler|Print spooler
com.android.wallpaper.livepicker|Live wallpaper picker
jp.co.omronsoft.openwnn|OpenWnn IME
"

# ---- VERIFY list: likely bloat but confirm before freezing ------------------
VERIFY_FREEZE="
com.alensw.PicFolder|quickpic 4.5.2 (old, known CVEs)
com.mediatek.omacp|Omacp provisioning
com.mediatek.mms.service|MtkMmsService (WiFi-only unit?)
com.kingroot.kinguser|kingroot remnant from failed prior root
"

freeze_list() {
    _label="$1"; _list="$2"
    info "$_label"
    echo "$_list" | while IFS='|' read -r _pkg _note; do
        [ -z "$_pkg" ] && continue
        if pm list packages 2>/dev/null | grep -q "^package:$_pkg$"; then
            disable_app "$_pkg"
        else
            info "not installed (skip): $_pkg  ($_note)"
        fi
    done
}

if [ "$1" = "--remove" ]; then
    # opt-in FULL removal: move /system app dir to .bak (reversible via restore.sh)
    shift
    [ -z "$1" ] && die "--remove needs a package name"
    _pkg="$1"
    _path="$(pm path "$_pkg" 2>/dev/null | sed 's/^package://' | head -1)"
    [ -z "$_path" ] && die "no path for $_pkg"
    _dir="$(dirname "$_path")"
    sys_rw
    backup "$_dir"
    mv "$_dir" "$_dir.bak" && { ok "moved to .bak: $_dir"; record "disable_apk" "$_dir"; }
    sys_ro
    warn "wiped dalvik-cache recommended: rm -rf /data/dalvik-cache/* (manual)"
    exit 0
fi

if [ "$1" = "--undo" ]; then
    info "re-freezing nothing; use restore.sh or: pm enable --user 0 <pkg>"
    exit 0
fi

# default: freeze SAFE list, report VERIFY list
freeze_list "freezing SAFE list..." "$SAFE_FREEZE"
info "VERIFY list (not auto-frozen — confirm then run):"
echo "$VERIFY_FREEZE" | while IFS='|' read -r _pkg _note; do
    [ -z "$_pkg" ] && continue
    if pm list packages 2>/dev/null | grep -q "^package:$_pkg$"; then
        warn "  present: $_pkg  ($_note)"
    fi
done

banner "debloat done — undo with restore.sh"
