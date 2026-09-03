#!/system/bin/sh
# restore.sh — undo every reversible change recorded in the manifest.
# Applies the inverse of each action, newest first.
_self_dir="$(cd "$(dirname "$0")" && pwd)"
. "$_self_dir/common.sh"

banner "restore: undoing manifest ($MANIFEST)"

require_root
[ -f "$MANIFEST" ] || { warn "no manifest at $MANIFEST — nothing to undo"; exit 0; }

sys_rw

# undo_one <action> <arg1> <arg2>
undo_one() {
    _action="$1"; _a1="$2"; _a2="$3"
    case "$_action" in
        disable_rc)
            if [ -f "$_a1.disabled" ]; then
                mv "$_a1.disabled" "$_a1" && ok "re-enabled: $_a1"
            else
                info "already restored: $_a1"
            fi ;;
        disable_apk)
            if [ -d "$_a1.bak" ]; then
                mv "$_a1.bak" "$_a1" && ok "restored apk dir: $_a1"
            else
                info "no .bak for: $_a1"
            fi ;;
        disable_app)
            pm enable --user 0 "$_a1" >/dev/null 2>&1 \
                && ok "unfroze: $_a1" || info "unfreeze skipped: $_a1" ;;
        create_file)
            if [ -e "$_a1" ]; then
                rm -f "$_a1" && ok "removed created file: $_a1"
            else
                info "already gone: $_a1"
            fi ;;
        setprop)
            if [ "$_a2" = "<unset>" ] || [ -z "$_a2" ]; then
                # value was unset before: delete the prop (Android: empty setprop deletes)
                setprop "$_a1" "" && ok "setprop $_a1 cleared (was unset)"
            else
                setprop "$_a1" "$_a2" && ok "setprop $_a1 -> $_a2 (restored)"
            fi ;;
        governor)
            echo "$_a1" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null \
                && ok "governor -> $_a1 (restored)" ;;
        enable_rc|enable_app)
            info "skip (already undone): $_action $_a1" ;;
        *)
            info "unknown action (skipped): $_action $_a1" ;;
    esac
}

# reverse the manifest (newest first) and undo each line
if have tac; then
    _cat="tac"
elif busybox tac "$MANIFEST" >/dev/null 2>&1; then
    _cat="busybox tac"
else
    warn "no tac — undoing in forward order (usually fine)"
    _cat="cat"
fi

"$_cat" "$MANIFEST" | while IFS='|' read -r _ts _action _a1 _a2; do
    [ -n "$_action" ] || continue
    undo_one "$_action" "$_a1" "$_a2"
done

sys_ro
banner "restore done — reboot to apply"
