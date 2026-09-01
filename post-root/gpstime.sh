#!/system/bin/sh
# gpstime.sh — LE1 boot clock sync via GPS (offline atomic-clock source).
# Runs as root via init (see timefix.rc) OR standalone. Self-bounded.
#
# TODO (verify on-device, see POST-ROOT-PLAN.md §8):
#   - NMEA route: YGPS "nmea2socket" -> 127.0.0.1:7000 is the standard MTK port
#     but CONFIRM with `nc 127.0.0.1 7000` after toggling the button once.
#   - Alternative: setprop mtk_gps_debug <mask> to enable debug_nmea, or read
#     mnld's NMEA file (/data/misc/gps/*) instead of the socket.
#   - busybox nc / timeout applets present?
LOG_FILE=/data/local/tmp/le1-gpstime.log
TAG=LE1-gpstime
. /system/bin/le1-common.sh 2>/dev/null || { echo "gpstime: le1-common.sh missing" >&2; exit 1; }

banner "gpstime: GPS clock sync"

TIMEOUT="${1:-120}"
NMEA_HOST=127.0.0.1
NMEA_PORT=7000        # TODO: confirm on-device
NMEA_FILE="/data/local/tmp/le1-nmea.$$"

# parse_one <NMEA line> — set clock if it's a valid-fix GPRMC/ZDA. returns 0 on success.
parse_one() {
    _line="$1"
    case "$_line" in
        '$GPRMC,'*|'$GNRMC,'*)
            _fix="$(echo "$_line" | cut -d',' -f3)"
            _time="$(echo "$_line" | cut -d',' -f2)"
            _date="$(echo "$_line" | cut -d',' -f10)"
            [ "$_fix" = "A" ] || return 1
            [ ${#_time} -ge 6 ] && [ ${#_date} -ge 6 ] || return 1
            _ts="20$(echo "$_date" | cut -c5-6)-$(echo "$_date" | cut -c3-4)-$(echo "$_date" | cut -c1-2) $(echo "$_time" | cut -c1-2):$(echo "$_time" | cut -c3-4):$(echo "$_time" | cut -c5-6)"
            ;;
        '$GPZDA,'*|'$GNZDA,'*)
            # $GPZDA,hhmmss.ss,dd,mm,yyyy,...
            _t="$(echo "$_line" | cut -d',' -f2)"
            _d="$(echo "$_line" | cut -d',' -f3)"
            _m="$(echo "$_line" | cut -d',' -f4)"
            _y="$(echo "$_line" | cut -d',' -f5)"
            [ "$_y" != "0000" ] && [ -n "$_y" ] || return 1
            _ts="$_y-$_m-$_d $(echo "$_t" | cut -c1-2):$(echo "$_t" | cut -c3-4):$(echo "$_t" | cut -c5-6)"
            ;;
        *) return 1 ;;
    esac

    info "GPS time candidate: $_ts (UTC)"
    if have busybox && busybox date -u -s "$_ts" >/dev/null 2>&1; then
        ok "clock set from GPS"
        busybox hwclock -w 2>/dev/null && ok "hwclock -w ok"
        # refresh the last-known-time cache for the next boot
        [ -x /system/bin/savetime.sh ] && /system/bin/savetime.sh
        return 0
    fi
    warn "date -u -s failed"
    return 1
}

if ! have busybox; then
    warn "no busybox (need nc + date + hwclock) — GPS sync skipped"
    banner "gpstime done (no busybox)"
    exit 0
fi

# capture NMEA for TIMEOUT seconds (bounded), then parse in the main shell
info "capturing NMEA from $NMEA_HOST:$NMEA_PORT for ${TIMEOUT}s..."
if busybox timeout 1 true 2>/dev/null; then
    busybox timeout "$TIMEOUT" busybox nc "$NMEA_HOST" "$NMEA_PORT" > "$NMEA_FILE" 2>/dev/null
else
    busybox nc "$NMEA_HOST" "$NMEA_PORT" > "$NMEA_FILE" 2>/dev/null &
    _nc_pid=$!
    sleep "$TIMEOUT"
    kill "$_nc_pid" 2>/dev/null
fi

_found=0
while read -r _line; do
    if parse_one "$_line"; then
        _found=1
        break
    fi
done < "$NMEA_FILE"
rm -f "$NMEA_FILE"

if [ "$_found" = 1 ]; then
    banner "gpstime done (fix acquired)"
else
    warn "no GPS fix within ${TIMEOUT}s (underground? NMEA route needs on-device verify — see §8)"
    banner "gpstime done (no fix)"
fi
