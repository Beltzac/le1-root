#!/system/bin/sh
# post-root.sh — LE1 post-root orchestrator. Every change is reversible.
#   sh post-root.sh [deploy|test-time|optimize|debloat|restore|full]
#   (default: full = deploy + test-time + optimize + debloat)
_self_dir="$(cd "$(dirname "$0")" && pwd)"
. "$_self_dir/common.sh"

banner "LE1 post-root orchestrator"
require_root

# deploy_file <src> <dst> <mode> — copy into /system, backup old, record for restore
deploy_file() {
    _src="$1"; _dst="$2"; _mode="$3"
    [ -e "$_dst" ] && backup "$_dst"
    cp "$_src" "$_dst" || { warn "copy failed: $_src -> $_dst"; return 1; }
    chmod "$_mode" "$_dst"
    chown 0:0 "$_dst" 2>/dev/null
    record "create_file" "$_dst"
    ok "deployed $_dst"
}

deploy_time() {
    banner "deploy time-fix scripts -> /system"
    sys_rw
    deploy_file "$_self_dir/common.sh"          /system/bin/le1-common.sh       644
    deploy_file "$_self_dir/loadtime.sh"        /system/bin/loadtime.sh         755
    deploy_file "$_self_dir/savetime.sh"        /system/bin/savetime.sh         755
    deploy_file "$_self_dir/le1-timesaved.sh"   /system/bin/le1-timesaved.sh    755
    deploy_file "$_self_dir/timefix.sh"         /system/bin/timefix.sh          755
    deploy_file "$_self_dir/gpstime.sh"         /system/bin/gpstime.sh          755
    deploy_file "$_self_dir/timefix.rc"         /system/etc/init/timefix.rc     644
    sys_ro
    ok "time-fix deployed: loadtime (early restore) + timesave daemon + timefix/gpstime"
}

test_timefix() {
    banner "test: run /system/bin/timefix.sh once"
    if [ -x /system/bin/timefix.sh ]; then
        /system/bin/timefix.sh
    else
        warn "not deployed — run: sh $0 deploy"
    fi
}

case "${1:-full}" in
    deploy)     deploy_time ;;
    test-time)  test_timefix ;;
    optimize)   sh "$_self_dir/optimize.sh" ;;
    debloat)    sh "$_self_dir/debloat.sh" ;;
    restore)    sh "$_self_dir/restore.sh" ;;
    full)
        deploy_time
        test_timefix
        sh "$_self_dir/optimize.sh"
        sh "$_self_dir/debloat.sh"
        banner "full post-root done — REBOOT to apply; undo: sh $_self_dir/restore.sh"
        ;;
    *)
        echo "usage: $0 [deploy|test-time|optimize|debloat|restore|full]" >&2
        exit 1 ;;
esac
