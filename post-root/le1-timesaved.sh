#!/system/bin/sh
# le1-timesaved.sh — daemon that keeps the last-known-time cache fresh.
#
# Cars cut power abruptly (ACC off), so there's no reliable shutdown hook.
# This periodically re-saves the clock so that at any power-off the cache is at
# most INTERVAL seconds stale -> next boot starts from a nearly-correct time.
LOG_FILE=/data/local/tmp/le1-timesaved.log
TAG=LE1-timesaved
. /system/bin/le1-common.sh 2>/dev/null || { echo "timesaved: le1-common.sh missing" >&2; exit 1; }

INTERVAL="${INTERVAL:-300}"    # 5 minutes

require_root
info "time-save daemon started (interval ${INTERVAL}s)"

while :; do
    sleep "$INTERVAL"
    if [ -x /system/bin/savetime.sh ]; then
        /system/bin/savetime.sh >/dev/null 2>&1
    else
        err "savetime.sh missing — daemon exiting"
        exit 1
    fi
done
